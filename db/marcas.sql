--------------------------------------------------------------------------------
-- CTELL · MARCAS
--
-- Un paquete (PKG_MARCAS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicacion de los endpoints ORDS.
--
--   1. LISTAR      GET    /marcas/listar        (?busqueda= opcional)
--   2. INSERTAR    POST   /marcas/crear
--   3. ACTUALIZAR  PUT    /marcas/actualizar/:id
--   4. ELIMINAR    DELETE /marcas/eliminar/:id
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/marcas/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   MARCAS  ID_MARCA, DESCRIPCION, FECHA_CREACION, FECHA_ACTUALIZACION
--
--------------------------------------------------------------------------------
-- ES UN CATALOGO GLOBAL: NO CUELGA DE NINGUNA EMPRESA
--
-- La tabla no tiene ID_EMPRESA, asi que "Sony" o "Nike" es la misma marca para
-- todas las empresas del sistema. Por eso sus endpoints NO reciben idEmpresa ni
-- acotan por el, igual que PAISES, DEPARTAMENTOS, CIUDADES, IVA o
-- CONDICIONES_PAGO.
--
-- La contrapartida: una marca que da de alta una empresa la ven todas. Es lo
-- correcto para un catalogo de fabricantes, pero conviene tenerlo presente
-- antes de agregar cualquier dato que sea propio de una sola.
--
--------------------------------------------------------------------------------
-- NO TIENE COLUMNA ACTIVO, Y ESO CAMBIA EL ABM
--
-- Es la primera tabla del proyecto sin estado: el DDL no trae ACTIVO. En
-- consecuencia NO hay baja logica ni endpoints /activar e /inactivar, y el
-- ELIMINAR es un DELETE fisico.
--
-- Lo que trae eso: no se puede "archivar" una marca que ya no se usa. Si algun
-- dia hace falta, la solucion es agregar ACTIVO VARCHAR2(1) al DDL con 'A'/'I'
-- —como el resto del sistema— y no inventar un estado por otro camino.
--
--------------------------------------------------------------------------------
-- LA DESCRIPCION ES UNICA, PERO EL DDL NO LO IMPONE
--
-- El DDL no declara UNIQUE sobre DESCRIPCION, asi que hoy se pueden cargar dos
-- veces "Sony". El paquete lo verifica a mano antes de insertar y devuelve 409,
-- comparando en MAYUSCULAS y sin espacios de sobra: para Oracle 'Sony' y 'SONY '
-- son distintos, y sin normalizar el control no sirve de nada.
--
-- Es un control de aplicacion, no una restriccion: dos sesiones simultaneas
-- podrian pasar las dos. Si el duplicado importa de verdad, va un
--   CREATE UNIQUE INDEX UX_MARCAS_DESC ON MARCAS (UPPER(TRIM(DESCRIPCION)));
-- en el DDL, y aca se captura el DUP_VAL_ON_INDEX.
--
--------------------------------------------------------------------------------
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_MARCAS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_MARCAS.LISTAR('Bearer TU_TOKEN', NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_MARCAS AS

  -- p_busqueda NULL o vacio devuelve todas. El catalogo es acotado (decenas de
  -- marcas, no miles), asi que no se pagina: ver la nota del final sobre cuando
  -- habria que hacerlo.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_MARCAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_MARCAS AS

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
         WHERE NAME = 'marcas';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'marcas');
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
  -- Privado: true si ya hay otra marca con esa descripcion.
  --
  -- Compara en MAYUSCULAS y sin espacios de sobra: sin normalizar, 'Sony' y
  -- 'SONY ' pasarian como distintas y el control no serviria.
  --
  -- p_id_excluir permite reusarla en el ACTUALIZAR, donde la fila que se esta
  -- editando no debe chocar consigo misma.
  ------------------------------------------------------------------------------
  FUNCTION YA_EXISTE (p_descripcion IN VARCHAR2, p_id_excluir IN NUMBER DEFAULT NULL)
    RETURN BOOLEAN IS
    l_cuenta PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_cuenta
      FROM MARCAS
     WHERE UPPER(TRIM(DESCRIPCION)) = UPPER(TRIM(p_descripcion))
       AND (p_id_excluir IS NULL OR ID_MARCA <> p_id_excluir);

    RETURN l_cuenta > 0;
  END YA_EXISTE;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_busqueda VARCHAR2(200);
    l_total    NUMBER;
    l_items    CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Un parametro ausente llega como cadena vacia, no como NULL: NULLIF lo
    -- convierte antes de que el LIKE lo tome como un filtro real.
    l_busqueda := NULLIF(TRIM(p_busqueda), '');

    SELECT COUNT(*)
      INTO l_total
      FROM MARCAS
     WHERE (l_busqueda IS NULL
            OR UPPER(DESCRIPCION) LIKE '%' || UPPER(l_busqueda) || '%');

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'          VALUE ID_MARCA,
                 'descripcion' VALUE DESCRIPCION
                 RETURNING CLOB
               ) AS fila,
               UPPER(DESCRIPCION) AS orden
          FROM MARCAS
         WHERE (l_busqueda IS NULL
                OR UPPER(DESCRIPCION) LIKE '%' || UPPER(l_busqueda) || '%')
      );

    p_status_code := 200;
    -- SELECT ... INTO y no una asignacion directa: `RETURNING CLOB` no se
    -- acepta en una expresion PL/SQL suelta (PLS-00684).
    --
    -- NVL sobre l_items: JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un
    -- array vacio, y el frontend reventaria al iterar "items":null.
    SELECT JSON_OBJECT(
             'items' VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON,
             'total' VALUE l_total
             RETURNING CLOB
           )
      INTO p_resultado
      FROM DUAL;
  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_MARCAS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las marcas"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_id     NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    IF TRIM(p_descripcion) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"descripcion es obligatoria"}';
      RETURN;
    END IF;

    -- La columna es VARCHAR2(100): se verifica antes para devolver un 400 con
    -- mensaje en vez de un ORA-12899 convertido en 500.
    IF LENGTH(TRIM(p_descripcion)) > 100 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La descripcion no puede superar los 100 caracteres"}';
      RETURN;
    END IF;

    -- Se llama en un IF y no dentro del INSERT: una funcion privada del BODY no
    -- se puede usar en una sentencia SQL (PLS-00231).
    IF YA_EXISTE(p_descripcion) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una marca con esa descripcion"}';
      RETURN;
    END IF;

    INSERT INTO MARCAS (DESCRIPCION)
    VALUES (TRIM(p_descripcion))
    RETURNING ID_MARCA INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      -- Solo salta si algun dia se agrega el UNIQUE al DDL. Se contempla igual:
      -- sin esto, el duplicado que YA_EXISTE no llegue a ver por una carrera
      -- entre dos sesiones saldria como un 500 sin explicacion.
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una marca con esa descripcion"}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_MARCAS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al crear la marca"}';
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_id     NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van DENTRO del BEGIN, nunca en el DECLARE: alli correrian
    -- antes de que exista el EXCEPTION y el error escaparia del procedimiento.
    l_id := TO_NUMBER(NULLIF(p_id, ''));

    IF l_id IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id es obligatorio"}';
      RETURN;
    END IF;

    IF TRIM(p_descripcion) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"descripcion es obligatoria"}';
      RETURN;
    END IF;

    IF LENGTH(TRIM(p_descripcion)) > 100 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La descripcion no puede superar los 100 caracteres"}';
      RETURN;
    END IF;

    -- Excluyendo la propia fila: sin eso, guardar sin cambiar el nombre daria
    -- 409 contra si misma.
    IF YA_EXISTE(p_descripcion, l_id) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otra marca con esa descripcion"}';
      RETURN;
    END IF;

    UPDATE MARCAS
       SET DESCRIPCION         = TRIM(p_descripcion),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_MARCA = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La marca no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otra marca con esa descripcion"}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_MARCAS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al actualizar la marca"}';
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_id     NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id := TO_NUMBER(NULLIF(p_id, ''));

    IF l_id IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id es obligatorio"}';
      RETURN;
    END IF;

    -- Baja FISICA: la tabla no tiene columna de estado, asi que no hay baja
    -- logica posible. Ver la nota del encabezado.
    DELETE FROM MARCAS WHERE ID_MARCA = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La marca no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay filas hijas (una FK apuntando a esta marca). Se traduce a
      -- 409 con un mensaje que dice que hacer, en vez de un 500 mudo. Hoy
      -- ninguna tabla referencia a MARCAS, pero ARTICULOS es el candidato
      -- natural y conviene que el dia que se agregue la FK esto ya funcione.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay articulos que usan esta marca"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_MARCAS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar la marca"}';
      END IF;
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'marcas',
      p_base_path      => '/marcas/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Catalogo global de marcas de articulos'
    );

    -- ORIGINS_ALLOWED es POR MODULO, no del workspace: sin esto ORDS rechaza la
    -- peticion cross-origin ANTES del handler, con un "Service Unavailable" que
    -- ningun WHEN OTHERS puede capturar.
    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'marcas',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /marcas/listar?busqueda=
    --
    -- Los query params se vinculan solos al bind del mismo nombre; no se
    -- declaran con DEFINE_PARAMETER.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'marcas', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'marcas',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MARCAS.LISTAR(:authorization, :busqueda, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /marcas/crear
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'marcas', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'marcas',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MARCAS.INSERTAR(:authorization, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /marcas/actualizar/:id
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'marcas', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'marcas',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MARCAS.ACTUALIZAR(:authorization, :id, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /marcas/eliminar/:id
    --
    -- Sin idEmpresa: es un catalogo global, no cuelga de ninguna empresa.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'marcas', p_pattern => 'eliminar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'marcas',
      p_pattern     => 'eliminar/:id',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MARCAS.ELIMINAR(:authorization, :id, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_MARCAS;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_MARCAS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion — mirar la salida, no alcanza con ejecutar.
--
-- Un paquete INVALID devuelve un 500 mudo: el WHEN OTHERS no captura errores de
-- compilacion porque el PL/SQL nunca llega a ejecutarse.
--------------------------------------------------------------------------------

-- Tiene que decir VALID las dos veces (PACKAGE y PACKAGE BODY).
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_MARCAS'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo. Tiene que volver VACIO.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_MARCAS'
 ORDER BY SEQUENCE;

-- El modulo, con su CORS.
SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'marcas';

-- Cuatro filas: listar GET, crear POST, actualizar/:id PUT, eliminar/:id DELETE.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'marcas'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- Duplicados que hayan entrado antes de que existiera el control del paquete.
-- Tiene que volver VACIO; si trae filas, hay que unificarlas a mano antes de
-- agregar el UNIQUE al DDL.
SELECT UPPER(TRIM(DESCRIPCION)) AS DESCRIPCION, COUNT(*) AS VECES
  FROM MARCAS
 GROUP BY UPPER(TRIM(DESCRIPCION))
HAVING COUNT(*) > 1
 ORDER BY VECES DESC;

-- El catalogo, para confirmar que el listado devuelve lo esperado.
SELECT ID_MARCA, DESCRIPCION, FECHA_CREACION
  FROM MARCAS
 ORDER BY UPPER(DESCRIPCION);
