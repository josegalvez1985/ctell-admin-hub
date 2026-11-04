--------------------------------------------------------------------------------
-- CTELL · VEHICULO PARTES
--
-- Un paquete (PKG_VEHICULO_PARTES) con el ABM del detalle de VEHICULOS —los
-- repuestos de cada vehiculo— y la publicacion de los endpoints ORDS.
--
--   1. LISTAR      GET    /vehiculo-partes/listar
--                         (?idEmpresa= OBLIGATORIO, &idVehiculo= &codigo=
--                          &busqueda= &pagina= &tamanio=)
--   2. INSERTAR    POST   /vehiculo-partes/crear
--   3. ACTUALIZAR  PUT    /vehiculo-partes/actualizar/:id
--   4. ELIMINAR    DELETE /vehiculo-partes/eliminar/:id/:idEmpresa
--
--   GUARDAR_LINEAS es PUBLICO pero INTERNO (sin endpoint ni token): lo usa
--   PKG_VEHICULOS.INSERTAR para el alta del vehiculo con sus lineas, y valida
--   con las mismas reglas que INSERTAR, para que de que es una linea valida
--   haya una sola version.
--
--   LOS DOS SENTIDOS DE LA RELACION
--
--     ?idVehiculo=  -> los repuestos que lleva ese vehiculo.
--     ?codigo=      -> en que vehiculos esta ese repuesto (cada fila trae el
--                      nombre del vehiculo). Es coincidencia EXACTA contra el
--                      codigo normalizado, no un LIKE: "W-71" no tiene que
--                      traer el W-712. Para buscar a medias esta ?busqueda=.
--   /vehiculos/listar?codigo= contesta lo mismo desde la cabecera: los
--   vehiculos, sin repetir, que llevan ese codigo.
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX. REQUIERE
-- db/auth.sql EJECUTADO ANTES (usa PKG_AUTH), y va ANTES que db/vehiculos.sql:
-- al reves, PKG_VEHICULOS compila INVALID con PLS-00201 y el alta devuelve un
-- 500 mudo.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/vehiculo-partes/
--
-- Tablas (no las crea ni las altera; el DDL se administra aparte):
--   VEHICULOS        ID, ID_EMPRESA, NOMBRE
--   VEHICULO_PARTES  ID, ID_EMPRESA, VEHICULO_ID, CODIGO_EQUIVALENTE, DESCRIPCION
--
--------------------------------------------------------------------------------
-- QUE RESUELVE
--
-- El catalogo de un vehiculo: que repuestos lleva y
-- con que codigo se los pide. El codigo es la llave para llegar al stock: se
-- cruza contra los codigos equivalentes y el codigo del fabricante de los
-- ARTICULOS, y el listado devuelve con cuantos articulos coincide cada linea.
-- Asi la pantalla contesta "de lo que lleva este auto, que tenemos".
--
--------------------------------------------------------------------------------
-- LA EMPRESA DE UNA PARTE ES LA DE SU VEHICULO
--
-- La tabla tiene ID_EMPRESA, con su FK y su NOT NULL, y aun asi NO se filtra
-- por ella: es una COPIA de la del vehiculo, y nada en el DDL obliga a que
-- coincidan. Las tres lecturas (listado, COUNT, y el EXISTS del UPDATE/DELETE)
-- van con un JOIN a VEHICULOS por v.ID_EMPRESA, como las marcaciones contra
-- PROFESORES. Ver la seccion 3.1 de docs/GUIA-IMPLEMENTACION.md.
--
-- La columna SE ESCRIBE —es NOT NULL y hay que ponerle algo—, y se le pone la
-- del vehiculo ya validado: el idEmpresa del cliente sirve para AUTORIZAR,
-- nunca como valor a guardar.
--
--------------------------------------------------------------------------------
-- EL CODIGO SE GUARDA NORMALIZADO
--
-- MAYUSCULAS y sin espacios de sobra, igual que CODIGOS_EQUIVALENTES. Dos
-- motivos: que el repetido se detecte ('w-712' y 'W-712 ' son el mismo
-- repuesto), y que el cruce contra los articulos sea una igualdad exacta. Si
-- uno de los dos lados guardara el texto crudo, el cruce fallaria en silencio y
-- la pantalla diria "sin articulo" sobre algo que esta en el deposito.
--
--------------------------------------------------------------------------------
-- UN CODIGO NO SE REPITE EN EL MISMO VEHICULO
--
-- El DDL no trae UNIQUE (VEHICULO_ID, CODIGO_EQUIVALENTE), y deberia: el mismo
-- repuesto dos veces en un vehiculo no dice nada nuevo y ensucia el conteo.
-- Mientras tanto lo cubre el paquete con un COUNT, y el COUNT corre con la fila
-- del VEHICULO bloqueada (FOR UPDATE): dos cargas simultaneas sobre el mismo
-- vehiculo se ordenan en vez de pasar las dos. El ALTER TABLE esta al pie y el
-- DUP_VAL_ON_INDEX ya se traduce al mismo 409.
--
-- De a una (INSERTAR, ACTUALIZAR) el repetido es 409; en el alta del vehiculo
-- (GUARDAR_LINEAS) es un 400 que nombra la linea y deshace el alta entera: en
-- los dos casos es un error de tipeo, y quien lo tipeo lo tiene que saber.
--
--------------------------------------------------------------------------------
-- EL VEHICULO DE UNA PARTE NO SE CAMBIA
--
-- Igual que el articulo de un codigo equivalente: mover una linea de vehiculo
-- es borrarla y crearla, y asi el control de repetidos se evalua contra el
-- vehiculo correcto.
--
--------------------------------------------------------------------------------
-- PAGINADO, Y SIN DETALLE EN EL LISTADO DE VEHICULOS
--
-- Un vehiculo puede llevar cientos de repuestos, asi que esta tabla
-- se lista paginada (20 por pagina, techo de 50: el JSON sale por un bind de
-- ORDS con techo de 4000 bytes). Por lo mismo PKG_VEHICULOS no tiene un
-- OBTENER con el detalle anidado, como facturas: con cien lineas, la respuesta
-- no saldria nunca.
--
--------------------------------------------------------------------------------
-- NO TIENE COLUMNA ACTIVO: baja fisica, nada que archivar.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_VEHICULO_PARTES AS

  ------------------------------------------------------------------------------
  -- Repuestos de la empresa, paginados.
  --
  -- Los dos sentidos de la relacion, combinables:
  --
  --   p_id_vehiculo -> los repuestos de ESE vehiculo.
  --   p_codigo      -> los vehiculos que llevan ESE codigo, exacto ("este
  --                    filtro, a que autos va").
  --   p_busqueda    -> texto parcial sobre codigo, descripcion y vehiculo.
  --
  -- Cada fila trae `articulos`: cuantos articulos de la empresa tienen ese
  -- codigo, como equivalente o como codigo del fabricante. Si es uno solo,
  -- tambien `idArticulo` y `articulo`.
  ------------------------------------------------------------------------------
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_vehiculo   IN  VARCHAR2,
    p_codigo        IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Una linea, desde el formulario. 409 si el codigo ya esta en ese vehiculo.
  PROCEDURE INSERTAR (
    p_authorization      IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_id_vehiculo        IN  VARCHAR2,
    p_codigo_equivalente IN  VARCHAR2,
    p_descripcion        IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  );

  -- El vehiculo NO se cambia (ver cabecera). Una descripcion vacia BORRA: el
  -- cliente manda siempre las dos claves.
  PROCEDURE ACTUALIZAR (
    p_authorization      IN  VARCHAR2,
    p_id                 IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_codigo_equivalente IN  VARCHAR2,
    p_descripcion        IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  ------------------------------------------------------------------------------
  -- INTERNO: guarda un array de lineas en un vehiculo.
  --
  -- Sin token y sin endpoint: QUIEN LLAMA ya valido la sesion y que el vehiculo
  -- sea de p_id_empresa (y lo acaba de crear, asi que nadie mas lo ve). No hace
  -- COMMIT ni ROLLBACK y devuelve el error en un OUT en vez de lanzar: el
  -- llamador tiene que poder deshacer tambien la cabecera.
  --
  -- Un codigo repetido dentro del array es un error (400, nombra la linea), no
  -- algo que se saltea: en un formulario, dos lineas iguales son un tipeo.
  ------------------------------------------------------------------------------
  PROCEDURE GUARDAR_LINEAS (
    p_id_vehiculo IN  NUMBER,
    p_id_empresa  IN  NUMBER,
    p_partes      IN  CLOB,
    p_lineas      OUT NUMBER,
    p_error       OUT VARCHAR2
  );

  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_VEHICULO_PARTES;
/

CREATE OR REPLACE PACKAGE BODY PKG_VEHICULO_PARTES AS

  -- 20 por pagina, con techo de 50: el JSON sale por un bind STRING de ORDS
  -- con techo de 4000 bytes. Ver la seccion 3 de docs/GUIA-IMPLEMENTACION.md.
  C_TAMANIO_DEFECTO CONSTANT PLS_INTEGER := 20;
  C_TAMANIO_MAXIMO  CONSTANT PLS_INTEGER := 50;

  -- Lineas por alta. Es un techo de defensa contra un request armado a mano: el
  -- formulario carga de a una, y despues del alta se siguen agregando desde
  -- /vehiculo-partes sin limite.
  C_MAX_LINEAS CONSTANT PLS_INTEGER := 200;

  -- Los largos de las columnas, para devolver un 400 con mensaje en vez de un
  -- ORA-12899 convertido en 500.
  C_MAX_CODIGO      CONSTANT PLS_INTEGER := 100;
  C_MAX_DESCRIPCION CONSTANT PLS_INTEGER := 200;

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
         WHERE NAME = 'vehiculo-partes';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'vehiculo-partes');
        COMMIT;
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
          -- ORA-00060 (interbloqueo) y ORA-04020 (lock de objeto) son
          -- transitorios: la otra sesion termina y el reintento pasa.
          --
          -- DBMS_SESSION.SLEEP y NO DBMS_LOCK.SLEEP: este workspace no tiene
          -- GRANT EXECUTE sobre SYS.DBMS_LOCK.
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
  -- Privado: el codigo tal como se guarda. MAYUSCULAS y sin espacios de sobra,
  -- el mismo criterio que PKG_CODIGOS_EQUIVALENTES.NORMALIZAR: si los dos lados
  -- no normalizan igual, el cruce contra los articulos no encuentra nada.
  ------------------------------------------------------------------------------
  FUNCTION NORMALIZAR (p_codigo IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN UPPER(TRIM(p_codigo));
  END NORMALIZAR;

  ------------------------------------------------------------------------------
  -- Privado: bloquea el vehiculo, y de paso comprueba que sea de la empresa.
  --
  -- La FK garantiza que el vehiculo exista, NO de quien es: sin este control se
  -- podrian colgar repuestos de la empresa A sobre un vehiculo de la B.
  --
  -- El FOR UPDATE es lo que vuelve confiable el control de repetidos: sin el,
  -- dos cargas del mismo codigo sobre el mismo vehiculo cuentan 0 las dos y
  -- entran las dos. Se suelta con el COMMIT o el ROLLBACK de quien llama.
  ------------------------------------------------------------------------------
  FUNCTION BLOQUEAR_VEHICULO (p_id_vehiculo IN NUMBER, p_id_empresa IN NUMBER)
    RETURN BOOLEAN IS
    l_id NUMBER;
  BEGIN
    SELECT ID
      INTO l_id
      FROM VEHICULOS
     WHERE ID         = p_id_vehiculo
       AND ID_EMPRESA = p_id_empresa
       FOR UPDATE;

    RETURN TRUE;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN FALSE;
  END BLOQUEAR_VEHICULO;

  ------------------------------------------------------------------------------
  -- Privado: true si ese codigo (ya normalizado) esta en el vehiculo, sin
  -- contar la fila p_excluir (la que se esta editando).
  ------------------------------------------------------------------------------
  FUNCTION CODIGO_REPETIDO (
    p_id_vehiculo IN NUMBER,
    p_codigo      IN VARCHAR2,
    p_excluir     IN NUMBER DEFAULT NULL
  ) RETURN BOOLEAN IS
    l_cuenta PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_cuenta
      FROM VEHICULO_PARTES
     WHERE VEHICULO_ID        = p_id_vehiculo
       AND CODIGO_EQUIVALENTE = p_codigo
       AND (p_excluir IS NULL OR ID <> p_excluir);

    RETURN l_cuenta > 0;
  END CODIGO_REPETIDO;

  ------------------------------------------------------------------------------
  -- Privado: el error de una linea, o NULL si se puede guardar.
  --
  -- Lo comparten el formulario (INSERTAR, ACTUALIZAR) y el lote: la regla de
  -- que es una linea valida no puede tener dos versiones. p_donde es "" o
  -- " de la linea N", para que el lote diga cual hay que corregir.
  ------------------------------------------------------------------------------
  FUNCTION ERROR_DE_LINEA (
    p_codigo      IN VARCHAR2,
    p_descripcion IN VARCHAR2,
    p_donde       IN VARCHAR2
  ) RETURN VARCHAR2 IS
  BEGIN
    IF p_codigo IS NULL THEN
      RETURN 'Falta el codigo' || p_donde;
    END IF;

    IF LENGTH(p_codigo) > C_MAX_CODIGO THEN
      RETURN 'El codigo' || p_donde || ' no puede superar los ' || C_MAX_CODIGO ||
             ' caracteres';
    END IF;

    IF LENGTH(p_descripcion) > C_MAX_DESCRIPCION THEN
      RETURN 'La descripcion' || p_donde || ' no puede superar los ' ||
             C_MAX_DESCRIPCION || ' caracteres';
    END IF;

    RETURN NULL;
  END ERROR_DE_LINEA;

  PROCEDURE GUARDAR_LINEAS (
    p_id_vehiculo IN  NUMBER,
    p_id_empresa  IN  NUMBER,
    p_partes      IN  CLOB,
    p_lineas      OUT NUMBER,
    p_error       OUT VARCHAR2
  ) IS
    l_lineas      PLS_INTEGER := 0;
    l_codigo      VARCHAR2(4000);
    l_descripcion VARCHAR2(4000);
  BEGIN
    p_error  := NULL;
    p_lineas := 0;

    FOR linea IN (
      SELECT d.nro, d.codigoEquivalente, d.descripcion
        FROM JSON_TABLE(
               p_partes, '$[*]'
               COLUMNS (
                 -- FOR ORDINALITY y no ROWNUM: da la posicion REAL dentro del
                 -- array, que es la fila que el usuario ve en el formulario.
                 -- ROWNUM se asigna al leer y un mensaje de error apuntaria a
                 -- la linea equivocada.
                 nro               FOR ORDINALITY,
                 codigoEquivalente VARCHAR2(4000) PATH '$.codigoEquivalente',
                 descripcion       VARCHAR2(4000) PATH '$.descripcion'
               )
             ) d
    ) LOOP
      l_lineas := l_lineas + 1;

      IF l_lineas > C_MAX_LINEAS THEN
        p_error := 'No se pueden cargar mas de ' || C_MAX_LINEAS ||
                   ' repuestos de una vez';
        RETURN;
      END IF;

      l_codigo      := NORMALIZAR(linea.codigoEquivalente);
      l_descripcion := NULLIF(TRIM(linea.descripcion), '');

      p_error := ERROR_DE_LINEA(l_codigo, l_descripcion, ' de la linea ' || linea.nro);
      IF p_error IS NOT NULL THEN
        RETURN;
      END IF;

      -- El COUNT ve tambien lo que este mismo array ya inserto (misma sesion):
      -- asi se detectan dos lineas iguales del formulario, incluidas las que
      -- solo difieren en mayusculas o espacios.
      IF CODIGO_REPETIDO(p_id_vehiculo, l_codigo) THEN
        p_error := 'El codigo ' || l_codigo || ' de la linea ' || linea.nro ||
                   ' esta repetido';
        RETURN;
      END IF;

      INSERT INTO VEHICULO_PARTES (
        ID_EMPRESA, VEHICULO_ID, CODIGO_EQUIVALENTE, DESCRIPCION
      ) VALUES (
        p_id_empresa, p_id_vehiculo, l_codigo, l_descripcion
      );
    END LOOP;

    p_lineas := l_lineas;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE IN (-40441, -40442, -40444) THEN
        -- Errores de parseo de JSON_TABLE: el array vino mal formado.
        p_error := 'Los repuestos no tienen un formato valido';
      ELSE
        APEX_DEBUG.ERROR('PKG_VEHICULO_PARTES.GUARDAR_LINEAS: [' || SQLCODE || '] ' ||
                         SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_error := 'Error al guardar los repuestos';
      END IF;
  END GUARDAR_LINEAS;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_vehiculo   IN  VARCHAR2,
    p_codigo        IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_empresa  NUMBER;
    l_vehiculo NUMBER;
    l_codigo   VARCHAR2(4000);
    l_busqueda VARCHAR2(200);
    l_pagina   NUMBER;
    l_tamanio  NUMBER;
    l_desplaza NUMBER;
    l_total    NUMBER;
    l_items    CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van DENTRO del BEGIN: en el DECLARE correrian antes de
    -- que exista el EXCEPTION y el error escaparia del procedimiento. NULLIF
    -- convierte la cadena vacia del parametro ausente en NULL antes de que
    -- TO_NUMBER la toque (si no, ORA-01722).
    l_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_vehiculo := TO_NUMBER(NULLIF(p_id_vehiculo, ''));

    -- El codigo se normaliza IGUAL que al guardarlo: asi la igualdad es exacta
    -- y usa el indice, y 'w-712 ' encuentra el W-712.
    l_codigo   := NORMALIZAR(NULLIF(p_codigo, ''));

    -- El termino se sube a mayusculas UNA vez, no por fila: el codigo ya se
    -- guarda normalizado, y la descripcion y el nombre se comparan en UPPER.
    l_busqueda := NORMALIZAR(NULLIF(p_busqueda, ''));

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    l_pagina   := GREATEST(NVL(TO_NUMBER(NULLIF(p_pagina, '')), 1), 1);
    l_tamanio  := LEAST(GREATEST(NVL(TO_NUMBER(NULLIF(p_tamanio, '')), C_TAMANIO_DEFECTO), 1),
                        C_TAMANIO_MAXIMO);
    l_desplaza := (l_pagina - 1) * l_tamanio;

    -- EL COUNT REPITE EXACTAMENTE EL MISMO WHERE —y el mismo JOIN— que la
    -- consulta de abajo. Sin el JOIN el total contaria las partes de todas las
    -- empresas, y el "Mostrar mas" ofreceria paginas vacias.
    SELECT COUNT(*)
      INTO l_total
      FROM VEHICULO_PARTES p
      JOIN VEHICULOS       v ON v.ID = p.VEHICULO_ID
     WHERE v.ID_EMPRESA = l_empresa
       AND (l_vehiculo IS NULL OR p.VEHICULO_ID = l_vehiculo)
       AND (l_codigo   IS NULL OR p.CODIGO_EQUIVALENTE = l_codigo)
       AND (l_busqueda IS NULL
            OR p.CODIGO_EQUIVALENTE LIKE '%' || l_busqueda || '%'
            OR UPPER(p.DESCRIPCION) LIKE '%' || l_busqueda || '%'
            OR UPPER(v.NOMBRE)      LIKE '%' || l_busqueda || '%');

    -- Tres niveles, y cada uno por algo:
    --
    --   1. El de adentro elige LA PAGINA (con su ORDER BY: sin el, OFFSET/FETCH
    --      recorta en un orden que Oracle no garantiza y una fila puede salir
    --      en dos paginas).
    --   2. El del medio cruza esas filas —y solo esas— contra los articulos.
    --      Puesto antes de paginar, el cruce correria por cada repuesto que
    --      pasa el filtro, para tirar casi todos.
    --   3. El JSON_ARRAYAGG agrega una columna ya armada: el JSON_OBJECT
    --      anidado adentro se materializa como VARCHAR2 y revienta a los 4000.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden_vehiculo, orden_codigo RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'                VALUE m.ID,
                 'idVehiculo'        VALUE m.VEHICULO_ID,
                 -- Del JOIN: buscando un codigo en todos los vehiculos, la fila
                 -- tiene que decir de cual es.
                 'vehiculo'          VALUE m.NOMBRE,
                 'codigoEquivalente' VALUE m.CODIGO_EQUIVALENTE,
                 'descripcion'       VALUE m.DESCRIPCION,
                 'articulos'         VALUE m.ARTICULOS,
                 -- El articulo solo cuando la coincidencia es UNICA: con dos o
                 -- mas, MIN(ID) y MIN(NOMBRE) pueden ser de articulos distintos,
                 -- y mostrar uno esconderia que el vendedor tiene que elegir.
                 'idArticulo'        VALUE CASE WHEN m.ARTICULOS = 1 THEN m.ID_ARTICULO END,
                 'articulo'          VALUE CASE WHEN m.ARTICULOS = 1 THEN m.NOMBRE_ARTICULO END
                 RETURNING CLOB
               ) AS fila,
               UPPER(m.NOMBRE)      AS orden_vehiculo,
               m.CODIGO_EQUIVALENTE AS orden_codigo
          FROM (
            SELECT pg.*,
                   -- EL CRUCE: por codigo equivalente O por el codigo del
                   -- fabricante. Es el mismo criterio con el que busca la lista
                   -- de articulos: si se cargo el OEM, tiene que encontrar
                   -- el articulo igual que si trajera una equivalencia.
                   --
                   -- Acotado a la empresa DEL VEHICULO (pg.ID_EMPRESA_VEH), no
                   -- a la del parametro: el resultado es el mismo y el filtro no
                   -- depende de una variable que alguien pueda olvidar.
                   (SELECT COUNT(*)
                      FROM ARTICULOS a
                     WHERE a.ID_EMPRESA = pg.ID_EMPRESA_VEH
                       AND (UPPER(TRIM(a.CODIGO_ARTICULO)) = pg.CODIGO_EQUIVALENTE
                            OR EXISTS (SELECT 1
                                         FROM CODIGOS_EQUIVALENTES c
                                        WHERE c.ID_ARTICULO        = a.ID_ARTICULO
                                          AND c.ID_EMPRESA         = a.ID_EMPRESA
                                          AND c.CODIGO_EQUIVALENTE = pg.CODIGO_EQUIVALENTE)))
                     AS ARTICULOS,
                   (SELECT MIN(a.ID_ARTICULO)
                      FROM ARTICULOS a
                     WHERE a.ID_EMPRESA = pg.ID_EMPRESA_VEH
                       AND (UPPER(TRIM(a.CODIGO_ARTICULO)) = pg.CODIGO_EQUIVALENTE
                            OR EXISTS (SELECT 1
                                         FROM CODIGOS_EQUIVALENTES c
                                        WHERE c.ID_ARTICULO        = a.ID_ARTICULO
                                          AND c.ID_EMPRESA         = a.ID_EMPRESA
                                          AND c.CODIGO_EQUIVALENTE = pg.CODIGO_EQUIVALENTE)))
                     AS ID_ARTICULO,
                   (SELECT MIN(a.NOMBRE_ARTICULO)
                      FROM ARTICULOS a
                     WHERE a.ID_EMPRESA = pg.ID_EMPRESA_VEH
                       AND (UPPER(TRIM(a.CODIGO_ARTICULO)) = pg.CODIGO_EQUIVALENTE
                            OR EXISTS (SELECT 1
                                         FROM CODIGOS_EQUIVALENTES c
                                        WHERE c.ID_ARTICULO        = a.ID_ARTICULO
                                          AND c.ID_EMPRESA         = a.ID_EMPRESA
                                          AND c.CODIGO_EQUIVALENTE = pg.CODIGO_EQUIVALENTE)))
                     AS NOMBRE_ARTICULO
              FROM (
                SELECT p.ID, p.VEHICULO_ID, p.CODIGO_EQUIVALENTE, p.DESCRIPCION,
                       v.NOMBRE, v.ID_EMPRESA AS ID_EMPRESA_VEH
                  FROM VEHICULO_PARTES p
                  -- JOIN interno: VEHICULO_ID es NOT NULL con FK, y ademas el
                  -- JOIN ES el filtro por empresa.
                  JOIN VEHICULOS       v ON v.ID = p.VEHICULO_ID
                 WHERE v.ID_EMPRESA = l_empresa
                   AND (l_vehiculo IS NULL OR p.VEHICULO_ID = l_vehiculo)
                   AND (l_codigo   IS NULL OR p.CODIGO_EQUIVALENTE = l_codigo)
                   AND (l_busqueda IS NULL
                        OR p.CODIGO_EQUIVALENTE LIKE '%' || l_busqueda || '%'
                        OR UPPER(p.DESCRIPCION) LIKE '%' || l_busqueda || '%'
                        OR UPPER(v.NOMBRE)      LIKE '%' || l_busqueda || '%')
                 ORDER BY UPPER(v.NOMBRE), p.CODIGO_EQUIVALENTE, p.ID
                 OFFSET l_desplaza ROWS FETCH NEXT l_tamanio ROWS ONLY
              ) pg
          ) m
      );

    p_status_code := 200;
    -- SELECT ... INTO y no una asignacion directa: `RETURNING CLOB` no se
    -- acepta en una expresion PL/SQL suelta (PLS-00684).
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
      APEX_DEBUG.ERROR('PKG_VEHICULO_PARTES.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los repuestos"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization      IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_id_vehiculo        IN  VARCHAR2,
    p_codigo_equivalente IN  VARCHAR2,
    p_descripcion        IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_empresa     NUMBER;
    l_vehiculo    NUMBER;
    l_codigo      VARCHAR2(4000);
    l_descripcion VARCHAR2(4000);
    l_error       VARCHAR2(4000);
    l_id          NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_vehiculo := TO_NUMBER(NULLIF(p_id_vehiculo, ''));

    -- Se calcula en variables y no dentro del INSERT: una funcion privada del
    -- BODY no se puede llamar desde una sentencia SQL (PLS-00231).
    l_codigo      := NORMALIZAR(p_codigo_equivalente);
    l_descripcion := NULLIF(TRIM(p_descripcion), '');

    IF l_empresa IS NULL OR l_vehiculo IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa e idVehiculo son obligatorios"}';
      RETURN;
    END IF;

    l_error := ERROR_DE_LINEA(l_codigo, l_descripcion, '');
    IF l_error IS NOT NULL THEN
      p_status_code := 400;
      SELECT JSON_OBJECT('error' VALUE l_error RETURNING CLOB) INTO p_resultado FROM DUAL;
      RETURN;
    END IF;

    IF NOT BLOQUEAR_VEHICULO(l_vehiculo, l_empresa) THEN
      ROLLBACK;
      -- 404 y no 403: decir "existe pero es de otra empresa" confirmaria que el
      -- id existe, que es lo que no deberia poder averiguarse.
      p_status_code := 404;
      p_resultado := '{"error":"El vehiculo no existe"}';
      RETURN;
    END IF;

    IF CODIGO_REPETIDO(l_vehiculo, l_codigo) THEN
      ROLLBACK;   -- Suelta el bloqueo del vehiculo.
      p_status_code := 409;
      p_resultado := '{"error":"Ese codigo ya esta cargado en este vehiculo"}';
      RETURN;
    END IF;

    -- ID_EMPRESA = la del vehiculo, que es l_empresa porque BLOQUEAR_VEHICULO
    -- acaba de comprobar que coinciden. Ver la cabecera.
    INSERT INTO VEHICULO_PARTES (
      ID_EMPRESA, VEHICULO_ID, CODIGO_EQUIVALENTE, DESCRIPCION
    ) VALUES (
      l_empresa, l_vehiculo, l_codigo, l_descripcion
    )
    RETURNING ID INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      -- Si el DDL ya tiene el UNIQUE (VEHICULO_ID, CODIGO_EQUIVALENTE) del pie,
      -- termina aca con el mismo 409 que el COUNT de arriba.
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ese codigo ya esta cargado en este vehiculo"}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_VEHICULO_PARTES.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al crear el repuesto"}';
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization      IN  VARCHAR2,
    p_id                 IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_codigo_equivalente IN  VARCHAR2,
    p_descripcion        IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id          NUMBER;
    l_empresa     NUMBER;
    l_vehiculo    NUMBER;
    l_codigo      VARCHAR2(4000);
    l_descripcion VARCHAR2(4000);
    l_error       VARCHAR2(4000);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id          := TO_NUMBER(NULLIF(p_id, ''));
    l_empresa     := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_codigo      := NORMALIZAR(p_codigo_equivalente);
    l_descripcion := NULLIF(TRIM(p_descripcion), '');

    -- El idEmpresa no es un dato mas a guardar: acota A CUAL fila se aplica el
    -- cambio. Sin el, un PUT con el id de otra empresa la modificaria igual.
    IF l_id IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    l_error := ERROR_DE_LINEA(l_codigo, l_descripcion, '');
    IF l_error IS NOT NULL THEN
      p_status_code := 400;
      SELECT JSON_OBJECT('error' VALUE l_error RETURNING CLOB) INTO p_resultado FROM DUAL;
      RETURN;
    END IF;

    -- De que vehiculo es la linea, y si ese vehiculo es de la empresa: las dos
    -- preguntas en una, contra el padre.
    BEGIN
      SELECT p.VEHICULO_ID
        INTO l_vehiculo
        FROM VEHICULO_PARTES p
        JOIN VEHICULOS       v ON v.ID = p.VEHICULO_ID
       WHERE p.ID         = l_id
         AND v.ID_EMPRESA = l_empresa;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_status_code := 404;
        p_resultado := '{"error":"El repuesto no existe"}';
        RETURN;
    END;

    -- Bloqueado ANTES de contar, igual que en el alta: si no, cambiar un codigo
    -- a uno que otra sesion esta cargando en ese momento pasa los dos COUNT.
    IF NOT BLOQUEAR_VEHICULO(l_vehiculo, l_empresa) THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El repuesto no existe"}';
      RETURN;
    END IF;

    IF CODIGO_REPETIDO(l_vehiculo, l_codigo, l_id) THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ese codigo ya esta cargado en este vehiculo"}';
      RETURN;
    END IF;

    -- VEHICULO_ID e ID_EMPRESA no van en el SET: mover la linea de vehiculo es
    -- borrarla y crearla, y la empresa es la del vehiculo.
    --
    -- DESCRIPCION sin NVL: vacia BORRA. Con el NVL habitual, una descripcion
    -- equivocada no se podria quitar nunca.
    UPDATE VEHICULO_PARTES
       SET CODIGO_EQUIVALENTE = l_codigo,
           DESCRIPCION        = l_descripcion
     WHERE ID          = l_id
       AND VEHICULO_ID = l_vehiculo;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El repuesto no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ese codigo ya esta cargado en este vehiculo"}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_VEHICULO_PARTES.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al actualizar el repuesto"}';
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_id      NUMBER;
    l_empresa NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id      := TO_NUMBER(NULLIF(p_id, ''));
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    IF l_id IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    -- La empresa se mira en el VEHICULO, no en la columna copiada de la fila.
    -- Nada cuelga de una parte, asi que no hay nada que revertir ni rechazar.
    DELETE FROM VEHICULO_PARTES p
     WHERE p.ID = l_id
       AND EXISTS (SELECT 1
                     FROM VEHICULOS v
                    WHERE v.ID         = p.VEHICULO_ID
                      AND v.ID_EMPRESA = l_empresa);

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El repuesto no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_VEHICULO_PARTES.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al eliminar el repuesto"}';
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'vehiculo-partes',
      p_base_path      => '/vehiculo-partes/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Repuestos de cada vehiculo (detalle de VEHICULOS)'
    );

    -- ORIGINS_ALLOWED es POR MODULO, no del workspace: sin esto ORDS rechaza la
    -- peticion cross-origin ANTES del handler, con un "Service Unavailable" que
    -- ningun WHEN OTHERS puede capturar.
    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'vehiculo-partes',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    -- Las llamadas a DEFINE_PARAMETER van escritas UNA POR UNA, con literales:
    -- envueltas en un helper, ORDS rechaza la primera con ORA-02290 y deja el
    -- modulo sin ningun endpoint (ver db/reportes-actividades.sql).

    ----------------------------------------------------------------------------
    -- GET /vehiculo-partes/listar?idEmpresa=&idVehiculo=&codigo=&busqueda=&pagina=&tamanio=
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'vehiculo-partes', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'vehiculo-partes',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_VEHICULO_PARTES.LISTAR(:authorization, :idEmpresa, :idVehiculo, :codigo, :busqueda, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculo-partes', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculo-partes', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculo-partes', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /vehiculo-partes/crear
    --
    -- Los campos del JSON llegan SUELTOS, no como :body — ese bind trae el
    -- payload crudo como BLOB y JSON_VALUE sobre el devuelve NULL en todos los
    -- campos. Ver la seccion 3 de docs/GUIA-IMPLEMENTACION.md.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'vehiculo-partes', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'vehiculo-partes',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_VEHICULO_PARTES.INSERTAR(:authorization, :idEmpresa, :idVehiculo, :codigoEquivalente, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculo-partes', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculo-partes', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculo-partes', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /vehiculo-partes/actualizar/:id
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'vehiculo-partes', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'vehiculo-partes',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_VEHICULO_PARTES.ACTUALIZAR(:authorization, :id, :idEmpresa, :codigoEquivalente, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculo-partes', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculo-partes', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculo-partes', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /vehiculo-partes/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(
      p_module_name => 'vehiculo-partes', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'vehiculo-partes',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_VEHICULO_PARTES.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculo-partes', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculo-partes', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculo-partes', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_VEHICULO_PARTES;
/

BEGIN
  PKG_VEHICULO_PARTES.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- VERIFICACION — mirar la salida, no alcanza con ejecutar.
-- Un paquete INVALID devuelve un 500 mudo: el WHEN OTHERS no captura errores de
-- compilacion porque el PL/SQL nunca llega a ejecutarse.
--------------------------------------------------------------------------------

-- Tiene que decir VALID las dos veces (PACKAGE y PACKAGE BODY).
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_VEHICULO_PARTES'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo. Tiene que volver VACIO.
SELECT LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_VEHICULO_PARTES'
 ORDER BY SEQUENCE;

-- Las tablas tienen que existir, o el SQL estatico que las nombra falla con
-- ORA-00942 y el BODY queda INVALID.
SELECT TABLE_NAME, COLUMN_NAME, NULLABLE, DATA_TYPE, DATA_LENGTH
  FROM USER_TAB_COLUMNS
 WHERE TABLE_NAME IN ('VEHICULOS', 'VEHICULO_PARTES')
 ORDER BY TABLE_NAME, COLUMN_ID;

-- El modulo, con su CORS.
SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'vehiculo-partes';

-- Cuatro filas: actualizar/:id PUT, crear POST, eliminar/:id/:idEmpresa
-- DELETE, listar GET.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'vehiculo-partes'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

--------------------------------------------------------------------------------
-- AUDITORIA — las tres tienen que volver VACIAS.
--------------------------------------------------------------------------------

-- Partes cuya ID_EMPRESA no coincide con la de su vehiculo. El listado sale
-- bien igual (filtra por el vehiculo), pero la columna esta mal guardada y la
-- proxima consulta que alguien escriba contra ella volveria a leerla.
--
-- Para corregirlas:
--   UPDATE VEHICULO_PARTES p
--      SET ID_EMPRESA = (SELECT v.ID_EMPRESA FROM VEHICULOS v WHERE v.ID = p.VEHICULO_ID)
--    WHERE ID_EMPRESA <> (SELECT v.ID_EMPRESA FROM VEHICULOS v WHERE v.ID = p.VEHICULO_ID);
SELECT p.ID, p.ID_EMPRESA AS EMPRESA_PARTE, v.ID_EMPRESA AS EMPRESA_VEHICULO
  FROM VEHICULO_PARTES p
  JOIN VEHICULOS       v ON v.ID = p.VEHICULO_ID
 WHERE p.ID_EMPRESA <> v.ID_EMPRESA;

-- Codigos SIN normalizar, de una carga anterior a este paquete (una
-- una importacion directa a la tabla, por ejemplo). Si trae filas, el cruce contra
-- los articulos no los encuentra y el control de repetidos no los ve.
--
-- Para normalizarlos (si choca contra el UNIQUE, primero la consulta de abajo):
--   UPDATE VEHICULO_PARTES
--      SET CODIGO_EQUIVALENTE = UPPER(TRIM(CODIGO_EQUIVALENTE))
--    WHERE CODIGO_EQUIVALENTE != UPPER(TRIM(CODIGO_EQUIVALENTE));
SELECT ID, VEHICULO_ID, CODIGO_EQUIVALENTE
  FROM VEHICULO_PARTES
 WHERE CODIGO_EQUIVALENTE != UPPER(TRIM(CODIGO_EQUIVALENTE));

-- El mismo codigo dos veces en un vehiculo, incluidos los que solo se
-- diferencian por mayusculas o espacios. Hay que borrar los sobrantes ANTES
-- de agregar el UNIQUE de abajo, o el ALTER falla con ORA-02299.
SELECT VEHICULO_ID, UPPER(TRIM(CODIGO_EQUIVALENTE)) AS CODIGO, COUNT(*) AS VECES
  FROM VEHICULO_PARTES
 GROUP BY VEHICULO_ID, UPPER(TRIM(CODIGO_EQUIVALENTE))
HAVING COUNT(*) > 1;

--------------------------------------------------------------------------------
-- PENDIENTE DE DDL (se corre aparte, una vez, con las auditorias en cero)
--
-- Convierte la regla de "un codigo por vehiculo" en garantia. El paquete ya
-- traduce el DUP_VAL_ON_INDEX al mismo 409, asi que agregarlo no rompe nada.
--
--   ALTER TABLE VEHICULO_PARTES ADD CONSTRAINT UQ_VP_VEHICULO_CODIGO
--     UNIQUE (VEHICULO_ID, CODIGO_EQUIVALENTE);
--
-- Y el indice que usan el listado por vehiculo y el control de repetidos (el
-- UNIQUE de arriba ya lo crea; sin el, va este):
--
--   CREATE INDEX IX_VP_VEHICULO ON VEHICULO_PARTES (VEHICULO_ID);
--------------------------------------------------------------------------------
