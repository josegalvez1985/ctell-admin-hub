--------------------------------------------------------------------------------
-- CTELL · VEHICULOS
--
-- Un paquete (PKG_VEHICULOS) con el ABM de la cabecera —el vehiculo— y la
-- publicacion de los endpoints ORDS. Su detalle, los repuestos, es
-- VEHICULO_PARTES y vive en db/vehiculo-partes.sql.
--
--   1. LISTAR      GET    /vehiculos/listar
--                         (?idEmpresa= OBLIGATORIO, &codigo= &busqueda= &pagina=
--                          &tamanio=)
--   2. INSERTAR    POST   /vehiculos/crear          (con sus repuestos, opcional)
--   3. ACTUALIZAR  PUT    /vehiculos/actualizar/:id (solo el nombre)
--   4. ELIMINAR    DELETE /vehiculos/eliminar/:id/:idEmpresa (se lleva los repuestos)
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX. REQUIERE, en este
-- orden: db/auth.sql (PKG_AUTH) y db/vehiculo-partes.sql (el alta usa
-- PKG_VEHICULO_PARTES.GUARDAR_LINEAS). Al reves, este paquete compila INVALID
-- con PLS-00201 y todos sus endpoints devuelven un 500 mudo.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/vehiculos/
--
-- Tablas (no las crea ni las altera; el DDL se administra aparte):
--   VEHICULOS        ID, ID_EMPRESA, NOMBRE
--   VEHICULO_PARTES  ID, ID_EMPRESA, VEHICULO_ID, CODIGO_EQUIVALENTE, DESCRIPCION
--
--------------------------------------------------------------------------------
-- CABECERA Y DETALLE, PERO NO COMO UNA FACTURA
--
-- El alta SI sigue la regla de la seccion 3.3 de docs/GUIA-IMPLEMENTACION.md:
-- el vehiculo y sus repuestos llegan en el mismo request y entran en una
-- transaccion, sin que un corte de red deje la cabecera sin sus lineas.
--
-- Lo que NO sigue es el resto del patron de facturas, y por el volumen:
--
--   - ACTUALIZAR no reemplaza el detalle entero. Una factura tiene cinco
--     lineas; un vehiculo puede llevar cientos de repuestos, y reenviarlos
--     todos para corregir una descripcion obligaria al cliente a traerse el
--     detalle completo antes de guardar. Despues del alta, las lineas se
--     agregan, editan y borran de a una en /vehiculo-partes.
--   - No hay OBTENER con el detalle anidado. Con cien repuestos la respuesta
--     pasa el techo de 4000 bytes del bind de ORDS y no sale nunca: el detalle
--     se pide paginado a /vehiculo-partes/listar?idVehiculo=.
--
-- Un vehiculo SIN repuestos se acepta: se puede crear el nombre ahora y
-- cargarle las lineas despues. El listado devuelve `cantidadPartes` para que la
-- pantalla lo muestre.
--
--------------------------------------------------------------------------------
-- LOS DOS SENTIDOS DE LA RELACION
--
-- Vehiculo -> repuestos es /vehiculo-partes/listar?idVehiculo=. El inverso,
-- repuesto -> vehiculos, es ?codigo= aca: los vehiculos que llevan ESE codigo,
-- sin repetir. Coincidencia EXACTA contra el codigo normalizado —"W-71" no
-- trae los que llevan el W-712—; para buscar a medias esta ?busqueda=, que mira
-- el nombre y los codigos con LIKE. Es un EXISTS y no un JOIN: con el JOIN, un
-- vehiculo que lleva el codigo dos veces saldria dos veces.
--
--------------------------------------------------------------------------------
-- UN NOMBRE POR EMPRESA
--
-- El DDL no trae UNIQUE sobre el nombre, y el paquete lo exige igual: dos
-- "Hilux 2015" en la misma empresa reparten los repuestos entre dos cabeceras
-- y nadie sabe en cual buscar. Se compara sin distinguir mayusculas ni los
-- espacios de los bordes, pero el nombre se GUARDA como se escribio:
-- "HILUX 2.8 SRV" no tiene por que pasar a "Hilux 2.8 Srv".
--
-- Lo cubre un COUNT antes del INSERT/UPDATE, con la limitacion conocida de que
-- dos altas simultaneas del mismo nombre lo pasan las dos. El indice que lo
-- vuelve garantia esta al pie, y el DUP_VAL_ON_INDEX ya se traduce al 409.
--
--------------------------------------------------------------------------------
-- FILTRO POR EMPRESA
--
-- ID_EMPRESA es NOT NULL en el DDL: filtro directo, sin filas heredadas. Las
-- subconsultas contra VEHICULO_PARTES no miran la ID_EMPRESA de la parte (es
-- una copia, ver db/vehiculo-partes.sql): correlacionan por VEHICULO_ID contra
-- un vehiculo que ya paso el filtro.
--
--------------------------------------------------------------------------------
-- NO TIENE COLUMNA ACTIVO: baja fisica. Borra el detalle PRIMERO: el DDL no
-- declara ON DELETE CASCADE y al reves da ORA-02292.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_VEHICULOS AS

  ------------------------------------------------------------------------------
  -- Vehiculos de la empresa, paginados, con `cantidadPartes`.
  --
  -- p_codigo: solo los que llevan ESE repuesto (exacto). "A que vehiculos va
  -- el W-712" se contesta desde aca, sin entrar a cada uno.
  -- p_busqueda: texto parcial sobre el nombre Y los codigos de sus repuestos.
  ------------------------------------------------------------------------------
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_codigo        IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  ------------------------------------------------------------------------------
  -- Alta del vehiculo con sus repuestos, en una transaccion.
  --
  -- Body: { idEmpresa, nombre, partes: [{ codigoEquivalente, descripcion }] }
  -- `partes` puede venir vacio (`[]`). Cada linea se valida con las reglas de
  -- PKG_VEHICULO_PARTES.GUARDAR_LINEAS —las mismas del alta de a una—, y una
  -- linea invalida o un codigo repetido deshacen el alta entera con un 400 que
  -- nombra la linea. Devuelve { id, ok, partes }.
  ------------------------------------------------------------------------------
  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_partes        IN  CLOB,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Solo el nombre: los repuestos se editan en /vehiculo-partes.
  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Baja fisica con sus repuestos. Devuelve { ok, partesEliminadas }.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_VEHICULOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_VEHICULOS AS

  -- 20 por pagina, con techo de 50: el JSON sale por un bind STRING de ORDS
  -- con techo de 4000 bytes. Ver la seccion 3 de docs/GUIA-IMPLEMENTACION.md.
  C_TAMANIO_DEFECTO CONSTANT PLS_INTEGER := 20;
  C_TAMANIO_MAXIMO  CONSTANT PLS_INTEGER := 50;

  -- VEHICULOS.NOMBRE es VARCHAR2(200).
  C_MAX_NOMBRE CONSTANT PLS_INTEGER := 200;

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
         WHERE NAME = 'vehiculos';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'vehiculos');
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
  -- Privado: true si la empresa ya tiene otro vehiculo con ese nombre, sin
  -- distinguir mayusculas ni espacios de los bordes. p_excluir es el que se
  -- esta editando: renombrarlo a si mismo no es un choque.
  ------------------------------------------------------------------------------
  FUNCTION NOMBRE_REPETIDO (
    p_id_empresa IN NUMBER,
    p_nombre     IN VARCHAR2,
    p_excluir    IN NUMBER DEFAULT NULL
  ) RETURN BOOLEAN IS
    l_cuenta PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_cuenta
      FROM VEHICULOS
     WHERE ID_EMPRESA         = p_id_empresa
       AND UPPER(TRIM(NOMBRE)) = UPPER(p_nombre)
       AND (p_excluir IS NULL OR ID <> p_excluir);

    RETURN l_cuenta > 0;
  END NOMBRE_REPETIDO;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_codigo        IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_empresa  NUMBER;
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
    -- que exista el EXCEPTION y el error escaparia del procedimiento.
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    -- En MAYUSCULAS: los codigos de las partes se guardan asi, y el nombre se
    -- compara en UPPER. El codigo exacto se normaliza IGUAL que al guardarlo
    -- (PKG_VEHICULO_PARTES.NORMALIZAR), o la igualdad no encontraria nada.
    l_codigo   := UPPER(NULLIF(TRIM(p_codigo), ''));
    l_busqueda := UPPER(NULLIF(TRIM(p_busqueda), ''));

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    l_pagina   := GREATEST(NVL(TO_NUMBER(NULLIF(p_pagina, '')), 1), 1);
    l_tamanio  := LEAST(GREATEST(NVL(TO_NUMBER(NULLIF(p_tamanio, '')), C_TAMANIO_DEFECTO), 1),
                        C_TAMANIO_MAXIMO);
    l_desplaza := (l_pagina - 1) * l_tamanio;

    -- EL COUNT REPITE EXACTAMENTE EL MISMO WHERE que la consulta de abajo. Si
    -- filtran distinto, el total dice una cosa y las filas otra.
    --
    -- Los dos filtros por codigo son EXISTS y no JOIN: con el JOIN, un
    -- vehiculo con tres repuestos que coinciden saldria tres veces.
    SELECT COUNT(*)
      INTO l_total
      FROM VEHICULOS v
     WHERE v.ID_EMPRESA = l_empresa
       AND (l_codigo IS NULL
            OR EXISTS (SELECT 1
                         FROM VEHICULO_PARTES p
                        WHERE p.VEHICULO_ID        = v.ID
                          AND p.CODIGO_EQUIVALENTE = l_codigo))
       AND (l_busqueda IS NULL
            OR UPPER(v.NOMBRE) LIKE '%' || l_busqueda || '%'
            OR EXISTS (SELECT 1
                         FROM VEHICULO_PARTES p
                        WHERE p.VEHICULO_ID = v.ID
                          AND p.CODIGO_EQUIVALENTE LIKE '%' || l_busqueda || '%'));

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, ya tipada como CLOB: anidado, el intermedio se materializa como
    -- VARCHAR2 y revienta al pasar los 4000 bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden, id RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'             VALUE pg.ID,
                 'idEmpresa'      VALUE pg.ID_EMPRESA,
                 'nombre'         VALUE pg.NOMBRE,
                 -- Contado sobre la pagina ya recortada, no antes: la
                 -- subconsulta corre por fila, y asi corre veinte veces y no
                 -- una por vehiculo de la empresa.
                 'cantidadPartes' VALUE (SELECT COUNT(*)
                                           FROM VEHICULO_PARTES p
                                          WHERE p.VEHICULO_ID = pg.ID)
                 RETURNING CLOB
               ) AS fila,
               UPPER(pg.NOMBRE) AS orden,
               pg.ID            AS id
          FROM (
            SELECT v.ID, v.ID_EMPRESA, v.NOMBRE
              FROM VEHICULOS v
             WHERE v.ID_EMPRESA = l_empresa
               AND (l_codigo IS NULL
                    OR EXISTS (SELECT 1
                                 FROM VEHICULO_PARTES p
                                WHERE p.VEHICULO_ID        = v.ID
                                  AND p.CODIGO_EQUIVALENTE = l_codigo))
               AND (l_busqueda IS NULL
                    OR UPPER(v.NOMBRE) LIKE '%' || l_busqueda || '%'
                    OR EXISTS (SELECT 1
                                 FROM VEHICULO_PARTES p
                                WHERE p.VEHICULO_ID = v.ID
                                  AND p.CODIGO_EQUIVALENTE LIKE '%' || l_busqueda || '%'))
             -- EL ORDER BY VA ACA, ademas de en el JSON_ARRAYAGG: es el que
             -- decide QUE filas entran en la pagina. El ID desempata dos
             -- nombres iguales en mayusculas, o OFFSET/FETCH podria repetirlos.
             ORDER BY UPPER(v.NOMBRE), v.ID
             OFFSET l_desplaza ROWS FETCH NEXT l_tamanio ROWS ONLY
          ) pg
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
      APEX_DEBUG.ERROR('PKG_VEHICULOS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los vehiculos"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_partes        IN  CLOB,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion    NUMBER;
    l_empresa   NUMBER;
    l_nombre    VARCHAR2(4000);
    l_id        NUMBER;
    l_lineas    NUMBER := 0;
    l_error     VARCHAR2(4000);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_nombre  := NULLIF(TRIM(p_nombre), '');

    IF l_empresa IS NULL OR l_nombre IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa y nombre son obligatorios"}';
      RETURN;
    END IF;

    IF LENGTH(l_nombre) > C_MAX_NOMBRE THEN
      p_status_code := 400;
      p_resultado := '{"error":"El nombre no puede superar los 200 caracteres"}';
      RETURN;
    END IF;

    IF NOMBRE_REPETIDO(l_empresa, l_nombre) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya hay un vehiculo con ese nombre. Agregale los repuestos a ese en vez de crear otro."}';
      RETURN;
    END IF;

    -- La FK a EMPRESAS valida que exista; que sea la de la sesion no se puede
    -- comprobar aca porque el token no la lleva —es el mismo criterio del resto
    -- de los ABM por empresa—.
    INSERT INTO VEHICULOS (ID_EMPRESA, NOMBRE)
    VALUES (l_empresa, l_nombre)
    RETURNING ID INTO l_id;

    -- El detalle es opcional: un vehiculo puede nacer sin repuestos y recibirlos
    -- despues. Nadie mas ve la fila todavia (no hay COMMIT), asi que no hace
    -- falta bloquearla para el control de repetidos.
    IF p_partes IS NOT NULL AND DBMS_LOB.GETLENGTH(p_partes) > 0 THEN
      PKG_VEHICULO_PARTES.GUARDAR_LINEAS(l_id, l_empresa, p_partes, l_lineas, l_error);

      IF l_error IS NOT NULL THEN
        ROLLBACK;   -- Deshace TAMBIEN la cabecera.
        p_status_code := 400;
        SELECT JSON_OBJECT('error' VALUE l_error RETURNING CLOB) INTO p_resultado FROM DUAL;
        RETURN;
      END IF;
    END IF;

    COMMIT;
    p_status_code := 201;
    SELECT JSON_OBJECT(
             'id'     VALUE l_id,
             'ok'     VALUE 'true' FORMAT JSON,
             'partes' VALUE l_lineas
             RETURNING CLOB
           )
      INTO p_resultado
      FROM DUAL;
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      -- El indice del pie, si ya se creo: la carrera que el COUNT no cubre
      -- termina aca, con el mismo 409.
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya hay un vehiculo con ese nombre. Agregale los repuestos a ese en vez de crear otro."}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_VEHICULOS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al crear el vehiculo"}';
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_id      NUMBER;
    l_empresa NUMBER;
    l_nombre  VARCHAR2(4000);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id      := TO_NUMBER(NULLIF(p_id, ''));
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_nombre  := NULLIF(TRIM(p_nombre), '');

    -- El idEmpresa no es un dato mas a guardar: acota A CUAL fila se aplica el
    -- cambio. Sin el, un PUT con el id de otra empresa la modificaria igual.
    IF l_id IS NULL OR l_empresa IS NULL OR l_nombre IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id, idEmpresa y nombre son obligatorios"}';
      RETURN;
    END IF;

    IF LENGTH(l_nombre) > C_MAX_NOMBRE THEN
      p_status_code := 400;
      p_resultado := '{"error":"El nombre no puede superar los 200 caracteres"}';
      RETURN;
    END IF;

    IF NOMBRE_REPETIDO(l_empresa, l_nombre, l_id) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya hay otro vehiculo con ese nombre"}';
      RETURN;
    END IF;

    -- ID_EMPRESA no va en el SET: poder cambiarla permitiria mover el vehiculo
    -- a otra empresa desde el endpoint que deberia impedirlo.
    UPDATE VEHICULOS
       SET NOMBRE = l_nombre
     WHERE ID         = l_id
       AND ID_EMPRESA = l_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      -- 404 y no 403: decir "existe pero es de otra empresa" confirmaria que el
      -- id existe, que es lo que no deberia poder averiguarse.
      p_status_code := 404;
      p_resultado := '{"error":"El vehiculo no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya hay otro vehiculo con ese nombre"}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_VEHICULOS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al actualizar el vehiculo"}';
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
    l_partes  NUMBER;
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

    -- DETALLE PRIMERO: sin ON DELETE CASCADE, al reves da ORA-02292.
    --
    -- El subselect acota por empresa: sin eso, mandar el id de un vehiculo
    -- ajeno le borraria los repuestos aunque el DELETE de la cabecera no
    -- hiciera nada.
    DELETE FROM VEHICULO_PARTES
     WHERE VEHICULO_ID IN (SELECT ID
                             FROM VEHICULOS
                            WHERE ID         = l_id
                              AND ID_EMPRESA = l_empresa);

    l_partes := SQL%ROWCOUNT;

    DELETE FROM VEHICULOS
     WHERE ID         = l_id
       AND ID_EMPRESA = l_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El vehiculo no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    SELECT JSON_OBJECT(
             'ok'               VALUE 'true' FORMAT JSON,
             'partesEliminadas' VALUE l_partes
             RETURNING CLOB
           )
      INTO p_resultado
      FROM DUAL;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_VEHICULOS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al eliminar el vehiculo"}';
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'vehiculos',
      p_base_path      => '/vehiculos/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Vehiculos (cabecera de VEHICULO_PARTES)'
    );

    -- ORIGINS_ALLOWED es POR MODULO, no del workspace: sin esto ORDS rechaza la
    -- peticion cross-origin ANTES del handler, con un "Service Unavailable" que
    -- ningun WHEN OTHERS puede capturar.
    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'vehiculos',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    -- Las llamadas a DEFINE_PARAMETER van escritas UNA POR UNA, con literales:
    -- envueltas en un helper, ORDS rechaza la primera con ORA-02290 y deja el
    -- modulo sin ningun endpoint (ver db/reportes-actividades.sql).

    ----------------------------------------------------------------------------
    -- GET /vehiculos/listar?idEmpresa=&codigo=&busqueda=&pagina=&tamanio=
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'vehiculos', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'vehiculos',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_VEHICULOS.LISTAR(:authorization, :idEmpresa, :codigo, :busqueda, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculos', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculos', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculos', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /vehiculos/crear
    --
    -- Body: { idEmpresa, nombre, partes: [...] }. Los campos llegan SUELTOS,
    -- no como :body (ese bind es el payload crudo como BLOB). `partes` es un
    -- array: ORDS lo vincula como texto JSON y el paquete lo recibe como CLOB.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'vehiculos', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'vehiculos',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_VEHICULOS.INSERTAR(:authorization, :idEmpresa, :nombre, :partes, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculos', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculos', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculos', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /vehiculos/actualizar/:id
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'vehiculos', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'vehiculos',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_VEHICULOS.ACTUALIZAR(:authorization, :id, :idEmpresa, :nombre, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /vehiculos/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'vehiculos', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'vehiculos',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_VEHICULOS.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculos', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculos', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'vehiculos', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_VEHICULOS;
/

BEGIN
  PKG_VEHICULOS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- VERIFICACION — mirar la salida, no alcanza con ejecutar.
-- Un paquete INVALID devuelve un 500 mudo: el WHEN OTHERS no captura errores de
-- compilacion porque el PL/SQL nunca llega a ejecutarse.
--------------------------------------------------------------------------------

-- Tiene que decir VALID las dos veces (PACKAGE y PACKAGE BODY). Si el BODY
-- sale INVALID con PLS-00201 sobre PKG_VEHICULO_PARTES, falta ejecutar antes
-- db/vehiculo-partes.sql.
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME IN ('PKG_VEHICULOS', 'PKG_VEHICULO_PARTES')
 ORDER BY OBJECT_NAME, OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo. Tiene que volver VACIO.
SELECT LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_VEHICULOS'
 ORDER BY SEQUENCE;

-- El modulo, con su CORS.
SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'vehiculos';

-- Cuatro filas: actualizar/:id PUT, crear POST, eliminar/:id/:idEmpresa
-- DELETE, listar GET.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'vehiculos'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

--------------------------------------------------------------------------------
-- AUDITORIA — tiene que volver VACIA.
--------------------------------------------------------------------------------

-- Nombres repetidos en la misma empresa (sin distinguir mayusculas ni los
-- espacios de los bordes), de una carga anterior a este paquete. Hay que
-- unificarlos ANTES de crear el indice de abajo, o falla con ORA-01452: mover
-- los repuestos de uno al otro y borrar el que queda vacio.
SELECT ID_EMPRESA, UPPER(TRIM(NOMBRE)) AS NOMBRE, COUNT(*) AS VECES
  FROM VEHICULOS
 GROUP BY ID_EMPRESA, UPPER(TRIM(NOMBRE))
HAVING COUNT(*) > 1;

-- Los vehiculos SIN repuestos. No es un error —se pueden crear antes de cargar
-- sus lineas—, pero uno que quedo asi hace semanas es una carga olvidada.
SELECT v.ID, v.ID_EMPRESA, v.NOMBRE
  FROM VEHICULOS v
 WHERE NOT EXISTS (SELECT 1 FROM VEHICULO_PARTES p WHERE p.VEHICULO_ID = v.ID)
 ORDER BY v.ID_EMPRESA, UPPER(v.NOMBRE);

--------------------------------------------------------------------------------
-- PENDIENTE DE DDL (se corre aparte, una vez, con la auditoria en cero)
--
-- Convierte "un nombre por empresa" en garantia. Es un indice de funcion y no
-- un UNIQUE comun porque la comparacion es sin mayusculas: un UNIQUE sobre
-- NOMBRE dejaria pasar "Hilux" y "HILUX". El paquete ya traduce el
-- DUP_VAL_ON_INDEX al mismo 409.
--
--   CREATE UNIQUE INDEX UX_VEHICULOS_EMPRESA_NOMBRE
--     ON VEHICULOS (ID_EMPRESA, UPPER(TRIM(NOMBRE)));
--------------------------------------------------------------------------------
