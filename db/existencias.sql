--------------------------------------------------------------------------------
-- CTELL · EXISTENCIAS
--
-- Un paquete (PKG_EXISTENCIAS) con la CONSULTA del stock, y la publicacion de
-- su modulo ORDS.
--
--   1. LISTAR  GET /existencias/listar
--              (?idEmpresa= &idSucursal= &idArticulo= &busqueda= &pagina= &tamanio=)
--
--------------------------------------------------------------------------------
-- SOLO LECTURA, Y ES A PROPOSITO
--
-- No hay crear, actualizar ni eliminar. NADIE escribe esta tabla todavia — ni
-- este paquete ni ningun otro—, asi que las cantidades son las que se hayan
-- cargado a mano.
--
-- El motivo: el stock se mueve con las TRANSACCIONES, no editandolo. Comprar
-- suma, vender resta, un conteo lo ajusta. Un endpoint que permita escribir la
-- cantidad directamente convierte el stock en un campo editable y deja de haber
-- forma de explicar por que dice lo que dice — que es exactamente el problema
-- que el modelo nuevo viene a resolver.
--
-- Cuando se implemente PKG_STOCK, va a ser el UNICO que escriba aca: con
-- SELECT ... FOR UPDATE sobre la fila antes de moverla, porque entre leer una
-- cantidad y grabar la nueva puede entrar otra caja vendiendo lo mismo.
--
--------------------------------------------------------------------------------
-- UNA FILA POR (EMPRESA, SUCURSAL, ARTICULO)
--
-- Es el UNIQUE de la tabla, y es lo que reemplaza al stock repartido en lotes.
-- La cantidad es UNA sola por articulo y deposito: en el estante las unidades
-- son identicas y nadie sabe de que compra vino cada una, asi que partirlas por
-- partida hacia imposible el conteo fisico.
--
-- POR SUCURSAL Y NO GLOBAL: dos depositos no comparten numero. Un articulo
-- puede tener 12 en la casa central y 0 en el local, y son dos filas.
--
-- LA FILA PUEDE NO EXISTIR. Un articulo que nunca tuvo movimiento en esa
-- sucursal no tiene fila —no es lo mismo que tener 0, aunque se muestre igual—,
-- asi que TODA lectura va con LEFT JOIN y NVL. El listado de articulos lo hace
-- justamente asi.
--
--------------------------------------------------------------------------------
-- LO QUE ESTA TABLA NO TIENE: EL COSTO
--
-- El DDL guarda la CANTIDAD, no a cuanto entro. Por eso el valor de stock del
-- dashboard sigue en cero: multiplicar unidades por un costo que no existe no se
-- puede, y devolver la cantidad como si fuera plata seria peor que un cero.
--
-- Para que vuelva hace falta una columna de costo promedio ponderado movil
-- —recalculada en cada compra— o una tabla de movimientos que lo derive. Es la
-- pieza que falta del modelo, no un olvido de este archivo.
--
--------------------------------------------------------------------------------
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/existencias/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   EXISTENCIAS  ID_EXISTENCIA, ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO,
--                CANTIDAD_DISPONIBLE, FECHA_ULTIMO_MOVIMIENTO,
--                FECHA_CREACION, FECHA_ACTUALIZACION
--   UNIQUE (ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO)
--   FK a EMPRESAS, SUCURSALES y ARTICULOS
--   Indices IDX_EXISTENCIAS_ARTICULO / _SUCURSAL / _EMPRESA
--
-- CANTIDAD_DISPONIBLE ES NULLABLE, con DEFAULT 0. El default cubre los INSERT
-- que la omiten, pero un UPDATE puede dejarla en NULL: toda lectura va con NVL,
-- porque un NULL en una suma la anula entera y en una comparacion no es ni
-- verdadera ni falsa —el articulo desapareceria del listado de faltantes—.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO ORDS, no del workspace. Ver db/auth.sql.
--
-- COMO EJECUTAR
--   1. Frena `npm run dev` (evita ORA-00060 al borrar el modulo).
--   2. Pega este archivo entero en la hoja SQL de APEX y ejecutalo.
--   3. Revisa que PKG_EXISTENCIAS quede VALID y USER_ERRORS vacio.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_EXISTENCIAS
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_EXISTENCIAS AS

  -- Consulta del stock por articulo y sucursal.
  --
  -- idEmpresa es OBLIGATORIO; el resto de los filtros son opcionales y se
  -- combinan. Sin idSucursal trae todas las sucursales de la empresa, una fila
  -- por cada una — no las suma: sumarlas escondería que 12 unidades estan en
  -- otro deposito, que es justo lo que hay que ver antes de prometer una venta.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /existencias/ con su unico endpoint.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_EXISTENCIAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_EXISTENCIAS AS

  -- 20 por pagina, con techo de 50.
  --
  -- EL TECHO NO ES CAPRICHO: ORDS devuelve el JSON por un parametro tipado
  -- STRING con limite de 4000 bytes, y una pagina grande —con el nombre y la
  -- descripcion de cada articulo— lo pasa y muere con un 500 que el WHEN OTHERS
  -- ni llega a registrar, porque el PL/SQL ya termino bien.
  C_TAMANIO_DEFECTO CONSTANT PLS_INTEGER := 20;
  C_TAMANIO_MAXIMO  CONSTANT PLS_INTEGER := 50;

  ------------------------------------------------------------------------------
  -- Privado: borra el modulo ORDS si existe, reintentando ante un interbloqueo.
  -- Nunca `WHEN OTHERS THEN NULL`: se tragaria un ORA-00060 y el DEFINE_MODULE
  -- de despues moriria con ORA-00001 contra el modulo que no se llego a borrar.
  ------------------------------------------------------------------------------
  PROCEDURE BORRAR_MODULO IS
    C_INTENTOS CONSTANT PLS_INTEGER := 3;
    l_existe   PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. C_INTENTOS LOOP
      BEGIN
        SELECT COUNT(*)
          INTO l_existe
          FROM USER_ORDS_MODULES
         WHERE NAME = 'existencias';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'existencias');
        COMMIT;
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
          -- ORA-00060 (interbloqueo) y ORA-04020 (lock de objeto) son
          -- transitorios: la otra sesion termina y el reintento pasa.
          --
          -- DBMS_SESSION.SLEEP y NO DBMS_LOCK.SLEEP: este workspace no tiene
          -- GRANT EXECUTE sobre SYS.DBMS_LOCK, y usarlo hace que el BODY no
          -- compile con PLS-00201.
          IF SQLCODE IN (-60, -4020) AND i < C_INTENTOS THEN
            ROLLBACK;
            DBMS_SESSION.SLEEP(2);
          ELSE
            RAISE;
          END IF;
      END;
    END LOOP;
  END BORRAR_MODULO;

  ------------------------------------------------------------------------------
  -- LISTAR
  ------------------------------------------------------------------------------
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_empresa     NUMBER;
    l_sucursal    NUMBER;
    l_articulo    NUMBER;
    l_busqueda    VARCHAR2(200);
    l_pagina      PLS_INTEGER;
    l_tamanio     PLS_INTEGER;
    l_desplaza    PLS_INTEGER;
    l_total       NUMBER;
    l_items       CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Un parametro ausente llega como cadena vacia, no como NULL: NULLIF lo
    -- convierte antes de que el filtro lo tome como un valor real.
    l_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    l_articulo := TO_NUMBER(NULLIF(p_id_articulo, ''));
    l_busqueda := LOWER(NULLIF(TRIM(p_busqueda), ''));

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    l_pagina  := GREATEST(NVL(TO_NUMBER(NULLIF(p_pagina, '')), 1), 1);
    l_tamanio := LEAST(NVL(TO_NUMBER(NULLIF(p_tamanio, '')), C_TAMANIO_DEFECTO),
                       C_TAMANIO_MAXIMO);
    l_desplaza := (l_pagina - 1) * l_tamanio;

    -- EL COUNT REPITE EXACTAMENTE EL MISMO WHERE que la consulta de abajo. Si
    -- filtran distinto, el total dice una cosa y las filas otra, y el "Mostrar
    -- mas" de la pantalla ofrece paginas vacias.
    SELECT COUNT(*)
      INTO l_total
      FROM EXISTENCIAS e
      JOIN ARTICULOS   a ON a.ID_ARTICULO = e.ID_ARTICULO
     WHERE e.ID_EMPRESA = l_empresa
       AND (l_sucursal IS NULL OR e.ID_SUCURSAL = l_sucursal)
       AND (l_articulo IS NULL OR e.ID_ARTICULO = l_articulo)
       AND (l_busqueda IS NULL
            OR LOWER(a.NOMBRE_ARTICULO) LIKE '%' || l_busqueda || '%'
            OR LOWER(a.CODIGO_ARTICULO) LIKE '%' || l_busqueda || '%');

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'                 VALUE e.ID_EXISTENCIA,
                 'idEmpresa'          VALUE e.ID_EMPRESA,
                 'idSucursal'         VALUE e.ID_SUCURSAL,
                 'sucursal'           VALUE s.NOMBRE_SUCURSAL,
                 'idArticulo'         VALUE e.ID_ARTICULO,
                 -- Del JOIN: sin el nombre, el listado son numeros sueltos y la
                 -- pantalla tendria que pedir el catalogo entero para leerlo.
                 'nombreArticulo'     VALUE a.NOMBRE_ARTICULO,
                 'codigoArticulo'     VALUE a.CODIGO_ARTICULO,
                 -- NVL: la columna es nullable y un NULL no es "sin dato" para
                 -- quien mira una existencia, es cero.
                 'cantidadDisponible' VALUE NVL(e.CANTIDAD_DISPONIBLE, 0),
                 'cantidadMinima'     VALUE a.CANTIDAD_MINIMA,
                 -- Cuando se movio por ultima vez. Es lo unico que distingue una
                 -- existencia viva de una que quedo quieta hace meses.
                 'fechaUltimoMovimiento' VALUE TO_CHAR(e.FECHA_ULTIMO_MOVIMIENTO,
                                                       'YYYY-MM-DD"T"HH24:MI:SS')
                 RETURNING CLOB
               ) AS fila,
               UPPER(a.NOMBRE_ARTICULO) AS orden
          FROM EXISTENCIAS e
          JOIN ARTICULOS   a ON a.ID_ARTICULO  = e.ID_ARTICULO
          -- LEFT en SUCURSALES aunque la FK sea NOT NULL: si la sucursal se
          -- borrara, el interno haria desaparecer la fila del listado sin ningun
          -- error, y una existencia que no se ve es peor que una sin nombre.
          LEFT JOIN SUCURSALES s ON s.ID_SUCURSAL = e.ID_SUCURSAL
         WHERE e.ID_EMPRESA = l_empresa
           AND (l_sucursal IS NULL OR e.ID_SUCURSAL = l_sucursal)
           AND (l_articulo IS NULL OR e.ID_ARTICULO = l_articulo)
           AND (l_busqueda IS NULL
                OR LOWER(a.NOMBRE_ARTICULO) LIKE '%' || l_busqueda || '%'
                OR LOWER(a.CODIGO_ARTICULO) LIKE '%' || l_busqueda || '%')
         -- EL ORDER BY VA ACA, en la subconsulta, ademas de en el
         -- JSON_ARRAYAGG: es el que decide QUE filas entran en la pagina. Sin
         -- el, OFFSET/FETCH recorta en un orden que Oracle no garantiza y la
         -- misma fila puede aparecer en dos paginas.
         ORDER BY UPPER(a.NOMBRE_ARTICULO)
         OFFSET l_desplaza ROWS FETCH NEXT l_tamanio ROWS ONLY
      );

    p_status_code := 200;
    -- SELECT ... INTO y no una asignacion directa: `RETURNING CLOB` no se acepta
    -- en una expresion PL/SQL suelta (PLS-00684).
    --
    -- NVL sobre l_items: JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un
    -- array vacio, y el frontend reventaria al iterar "items":null.
    SELECT JSON_OBJECT(
             'items'   VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON,
             'total'   VALUE l_total,
             'pagina'  VALUE l_pagina,
             'tamanio' VALUE l_tamanio
             RETURNING CLOB
           )
      INTO p_resultado
      FROM DUAL;
  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_EXISTENCIAS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las existencias"}';
  END LISTAR;

  ------------------------------------------------------------------------------
  -- Publica el modulo ORDS /existencias/ con su unico endpoint.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no del workspace, y NO es un parametro de
  -- DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin esto, toda
  -- peticion cross-origin la rechaza ORDS ANTES de llegar al handler, con un
  -- "Service Unavailable" que ningun WHEN OTHERS puede capturar.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'existencias',
      p_base_path      => '/existencias/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Consulta de stock por articulo y sucursal (solo lectura)'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'existencias',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /existencias/listar?idEmpresa=&idSucursal=&idArticulo=&busqueda=
    --                        &pagina=&tamanio=
    --
    -- Los query params se vinculan solos al bind del mismo nombre; no se
    -- declaran con DEFINE_PARAMETER.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'existencias', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'existencias',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_EXISTENCIAS.LISTAR(:authorization, :idEmpresa, :idSucursal, :idArticulo, :busqueda, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'existencias', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'existencias', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'existencias', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_EXISTENCIAS;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_EXISTENCIAS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_EXISTENCIAS'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo. Un paquete INVALID da un 500
-- mudo: el WHEN OTHERS no captura errores de compilacion.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_EXISTENCIAS'
 ORDER BY LINE, POSITION;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'existencias';

--------------------------------------------------------------------------------
-- 4. Consultas utiles
--------------------------------------------------------------------------------

-- La estructura que el paquete da por sentada. Tienen que estar la PK, el UNIQUE
-- de (ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO) y las tres FK.
SELECT CONSTRAINT_NAME, CONSTRAINT_TYPE, R_CONSTRAINT_NAME, STATUS
  FROM USER_CONSTRAINTS
 WHERE TABLE_NAME = 'EXISTENCIAS'
   AND CONSTRAINT_TYPE IN ('P', 'U', 'R')
 ORDER BY CONSTRAINT_TYPE, CONSTRAINT_NAME;

-- El stock de una empresa, sucursal por sucursal.
SELECT s.NOMBRE_SUCURSAL,
       a.NOMBRE_ARTICULO,
       a.CODIGO_ARTICULO,
       NVL(e.CANTIDAD_DISPONIBLE, 0) AS DISPONIBLE,
       a.CANTIDAD_MINIMA,
       TO_CHAR(e.FECHA_ULTIMO_MOVIMIENTO, 'YYYY-MM-DD HH24:MI') AS ULTIMO_MOVIMIENTO
  FROM EXISTENCIAS e
  JOIN ARTICULOS   a ON a.ID_ARTICULO  = e.ID_ARTICULO
  JOIN SUCURSALES  s ON s.ID_SUCURSAL  = e.ID_SUCURSAL
 ORDER BY s.NOMBRE_SUCURSAL, a.NOMBRE_ARTICULO;

-- Lo que esta por debajo de su minimo: lo que hay que reponer.
--
-- NVL a 0 en la cantidad: sin el, la comparacion contra CANTIDAD_MINIMA da NULL
-- —ni verdadera ni falsa— y el articulo que no tiene NADA queda justamente
-- afuera de la lista de faltantes.
SELECT s.NOMBRE_SUCURSAL,
       a.NOMBRE_ARTICULO,
       NVL(e.CANTIDAD_DISPONIBLE, 0) AS DISPONIBLE,
       a.CANTIDAD_MINIMA
  FROM EXISTENCIAS e
  JOIN ARTICULOS   a ON a.ID_ARTICULO = e.ID_ARTICULO
  JOIN SUCURSALES  s ON s.ID_SUCURSAL = e.ID_SUCURSAL
 WHERE NVL(a.CANTIDAD_MINIMA, 0) > 0
   AND NVL(e.CANTIDAD_DISPONIBLE, 0) < a.CANTIDAD_MINIMA
 ORDER BY s.NOMBRE_SUCURSAL, a.NOMBRE_ARTICULO;

-- ARTICULOS ACTIVOS SIN FILA DE EXISTENCIA en una sucursal. No es un error —una
-- fila se crea con el primer movimiento— pero explica por que el listado de
-- articulos los muestra en 0. Reemplazar <sucursal>.
--
-- SELECT a.ID_ARTICULO, a.NOMBRE_ARTICULO
--   FROM ARTICULOS a
--  WHERE UPPER(TRIM(a.ACTIVO)) != 'I'
--    AND NOT EXISTS (SELECT 1 FROM EXISTENCIAS e
--                     WHERE e.ID_ARTICULO = a.ID_ARTICULO
--                       AND e.ID_SUCURSAL = <sucursal>)
--  ORDER BY a.NOMBRE_ARTICULO;

-- Filas incoherentes: la existencia tiene que ser de la MISMA empresa que su
-- sucursal y que su articulo. El DDL declara las tres FK por separado, asi que
-- por si solo acepta la mezcla. Cero filas es lo correcto.
SELECT e.ID_EXISTENCIA,
       e.ID_EMPRESA  AS EMPRESA_EXISTENCIA,
       s.ID_EMPRESA  AS EMPRESA_SUCURSAL,
       a.ID_EMPRESA  AS EMPRESA_ARTICULO
  FROM EXISTENCIAS e
  JOIN SUCURSALES s ON s.ID_SUCURSAL = e.ID_SUCURSAL
  JOIN ARTICULOS  a ON a.ID_ARTICULO = e.ID_ARTICULO
 WHERE e.ID_EMPRESA != s.ID_EMPRESA
    OR e.ID_EMPRESA != a.ID_EMPRESA;

-- Cantidades negativas. Hoy nada las escribe, asi que una fila aca entro a mano.
SELECT ID_EXISTENCIA, ID_SUCURSAL, ID_ARTICULO, CANTIDAD_DISPONIBLE
  FROM EXISTENCIAS
 WHERE CANTIDAD_DISPONIBLE < 0;
