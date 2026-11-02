--------------------------------------------------------------------------------
-- CTELL · ARTICULOS x UBICACIONES
--
-- Un paquete (PKG_ARTICULOS_UBICACIONES) con LISTAR, ASIGNAR y QUITAR, y la
-- publicacion de los endpoints ORDS. Todo vive dentro del paquete: no hay
-- procedimientos sueltos ni PL/SQL embebido como texto dentro de los handlers.
--
--   1. LISTAR   GET    /articulos-ubicaciones/listar   (?idEmpresa= &idArticulo= &idUbicacion=)
--   2. ASIGNAR  POST   /articulos-ubicaciones/crear
--   3. QUITAR   DELETE /articulos-ubicaciones/eliminar/:id/:idEmpresa
--   4. REPORTE  GET    /articulos-ubicaciones/reporte  (?idEmpresa= &idSucursal=
--                                                       &situacion=CON|SIN
--                                                       &pagina= &tamanio=)
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/articulos-ubicaciones/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   ARTICULOS_UBICACIONES  ID_ARTICULO_UBICACION, ID_ARTICULO, ID_UBICACION,
--                          FECHA_ACTUALIZACION
--
-- QUE ES: en que ubicaciones del deposito puede estar cada articulo. Es una
-- tabla de CRUCE pura — un articulo esta en varias ubicaciones y una ubicacion
-- tiene varios articulos.
--
-- NO HAY "ACTUALIZAR", Y ES A PROPOSITO. La fila no tiene datos propios: solo
-- une un articulo con una ubicacion. Cambiar cualquiera de los dos ids es, en la
-- practica, otra asignacion — asi que se quita la vieja y se crea la nueva. Un
-- PUT que cambiara los dos ids seria indistinguible de un DELETE + POST, con el
-- riesgo extra de pisar una fila existente.
--
-- (La tabla tuvo una columna CANTIDAD_UBICADA que se elimino del DDL. Con ella
-- esto habria sido stock por ubicacion y SI habria hecho falta un ACTUALIZAR
-- para corregir la cantidad. Sin ella es una relacion de asignacion y nada mas.)
--
-- COHERENCIA DE EMPRESA: NADA EN EL DDL LA GARANTIZA. ARTICULOS cuelga de
-- EMPRESAS y UBICACIONES tambien, pero las dos FK de esta tabla apuntan a sus
-- propias tablas sin mirar la empresa: la base acepta asignar un articulo de la
-- empresa A a una ubicacion de la empresa B. ASIGNAR lo valida a mano
-- comparando las dos empresas y devuelve 400 si no coinciden. Es el mismo
-- problema que db/ubicaciones.sql resuelve con SUCURSAL_ES_DE_EMPRESA, pero aca
-- cruzando dos tablas en vez de una.
--
-- Y ESO SOLO NO ALCANZA: comparar el articulo con la ubicacion garantiza que
-- sean coherentes ENTRE SI, no que sean del que llama. Dos filas ajenas
-- coherentes entre si pasaban la validacion, asi que una sesion de la empresa A
-- podia crear asignaciones dentro de la B con solo conocer dos ids. Por eso
-- ASIGNAR recibe idEmpresa y exige que las dos sean de esa empresa. El QUITAR
-- ya lo hacia; era el alta la que faltaba.
--
-- CON JOIN, A DIFERENCIA DE LAS TABLAS POR EMPRESA: el listado SI trae el nombre
-- del articulo y los datos de la ubicacion (zona, estante, nivel). No es la
-- misma constante repetida — cada fila cruza un articulo distinto con una
-- ubicacion distinta, asi que sin el JOIN el frontend tendria que pedir las dos
-- tablas enteras para mostrar una lista legible.
--
-- El UNIQUE (ID_ARTICULO, ID_UBICACION) impide asignar dos veces el mismo par.
-- El DUP_VAL_ON_INDEX se traduce a 409.
--
-- BAJA FISICA: la tabla no tiene columna ACTIVO. Quitar una asignacion es
-- borrarla — no hay estado que conservar.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_ARTICULOS_UBICACIONES
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_ARTICULOS_UBICACIONES.LISTAR('Bearer TU_TOKEN', '21', '1', NULL,
--                                      l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_ARTICULOS_UBICACIONES AS

  -- Los dos filtros son opcionales y se combinan:
  --   ?idArticulo=   -> donde esta ese articulo (la vista del ABM de articulos)
  --   ?idUbicacion=  -> que hay en ese estante
  -- Sin ninguno devuelve el cruce entero DE LA EMPRESA, que es la vista de
  -- /articulos-ubicaciones.
  ----------------------------------------------------------------------------
  -- idEmpresa es OBLIGATORIO, y no es una formalidad.
  --
  -- ARTICULOS_UBICACIONES no tiene ID_EMPRESA —es un cruce— asi que la consulta
  -- NO se acota sola: sin este parametro devolvia el cruce COMPLETO, de todas
  -- las empresas del sistema. La pantalla /articulos-ubicaciones lo llamaba sin
  -- filtros para mostrar "todo el deposito", y mostraba el de todos.
  --
  -- El recorte se hace CONTRA EL PADRE, como en MANUALES: JOIN a ARTICULOS y
  -- WHERE sobre su ID_EMPRESA. Es el articulo el que define de quien es la
  -- fila; la ubicacion tambien tiene empresa, pero filtrar por las dos
  -- ESCONDERIA las filas cruzadas entre empresas, que es justamente lo que la
  -- consulta de control del final del archivo existe para encontrar.
  ----------------------------------------------------------------------------
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_id_ubicacion  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- p_id_empresa es OBLIGATORIO. El ASIGNAR comprobaba que el articulo y la
  -- ubicacion fueran de la MISMA empresa, pero no de la del que llama: una
  -- sesion de la empresa A podia crear una asignacion entre dos filas de la B
  -- con solo conocer sus ids. El QUITAR si lo validaba; el alta no.
  PROCEDURE ASIGNAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_id_ubicacion  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- NO hay ACTUALIZAR: ver la nota del encabezado. La fila no tiene datos
  -- propios, asi que reasignar es quitar y volver a asignar.

  PROCEDURE QUITAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  ----------------------------------------------------------------------------
  -- REPORTE: los articulos por ubicacion de UNA sucursal, y los que no tienen
  -- ninguna, en el mismo listado.
  --
  -- No es el LISTAR con otro nombre, por dos motivos:
  --   - LISTAR recorre el CRUCE, asi que un articulo sin asignar no aparece
  --     nunca: no hay fila de la que salir. Este recorre el CATALOGO con un
  --     LEFT JOIN al cruce, y el articulo sin ubicacion sale con la ubicacion
  --     en null.
  --   - LISTAR no pagina, y el reporte trae el deposito entero: sin paginar
  --     choca con el techo de 4000 bytes del bind de ORDS.
  --
  -- POR SUCURSAL, Y OBLIGATORIA. Las ubicaciones son de una sucursal, y "sin
  -- ubicacion" sin sucursal no significa nada: un articulo ubicado en la casa
  -- central esta SIN ubicar en el local. Por eso idSucursal es 400 si falta, y
  -- tiene que ser de la empresa.
  --
  -- situacion: 'CON' (las asignaciones), 'SIN' (los articulos sin ninguna en
  -- esta sucursal) o vacio (las dos). Otro valor es 400.
  --
  -- QUE CUENTA COMO "SIN UBICACION": un articulo ACTIVO y que NO es gasto. Un
  -- flete o un honorario no van en un estante, y un articulo dado de baja no se
  -- va a ubicar: listarlos llenaria el reporte de faltas que no son faltas. Los
  -- que SI tienen ubicacion salen siempre, inactivos y gastos incluidos —un
  -- inactivo que sigue ocupando un estante es justamente lo que hay que ver—.
  --
  -- Una fila por ASIGNACION: un articulo en tres estantes sale tres veces, que
  -- es lo que se busca al recorrer el deposito. Los contadores del resumen
  -- distinguen asignaciones de articulos para que eso no confunda.
  ----------------------------------------------------------------------------
  PROCEDURE REPORTE (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_situacion     IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /articulos-ubicaciones/.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_ARTICULOS_UBICACIONES;
/

CREATE OR REPLACE PACKAGE BODY PKG_ARTICULOS_UBICACIONES AS

  ------------------------------------------------------------------------------
  -- Privado: borra el modulo ORDS si existe, reintentando ante un interbloqueo.
  --
  -- Nunca usar `WHEN OTHERS THEN NULL` aca: se tragaria tambien un ORA-00060,
  -- el DELETE fallaria en silencio, y el DEFINE_MODULE de despues moriria con
  -- ORA-00001 (nombre duplicado) contra el modulo que nunca se llego a borrar.
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
         WHERE NAME = 'articulos-ubicaciones';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'articulos-ubicaciones');
        COMMIT;  -- Libera los locks antes de que DEFINE_MODULE los vuelva a pedir.
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
          -- ORA-00060 (interbloqueo) y ORA-04020 (lock de objeto) son
          -- transitorios: la otra sesion termina y el reintento pasa.
          IF SQLCODE IN (-60, -4020) AND i < C_INTENTOS THEN
            ROLLBACK;
            DBMS_SESSION.SLEEP(2);
          ELSE
            RAISE;
          END IF;
      END;
    END LOOP;
  END BORRAR_MODULO;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_id_ubicacion  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion       NUMBER;
    l_id_empresa   NUMBER;
    l_id_articulo  NUMBER;
    l_id_ubicacion NUMBER;
    l_total        NUMBER;
    l_items        CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van aca, dentro del BEGIN: en el DECLARE se ejecutarian
    -- antes de que exista el EXCEPTION y el error escaparia del procedimiento.
    -- NULLIF convierte la cadena vacia del parametro ausente en NULL antes de
    -- que TO_NUMBER la toque (si no, ORA-01722).
    l_id_empresa   := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_articulo  := TO_NUMBER(NULLIF(p_id_articulo, ''));
    l_id_ubicacion := TO_NUMBER(NULLIF(p_id_ubicacion, ''));

    -- Sin empresa NO se devuelve nada. El default de "todas" que tenia antes es
    -- el error: un olvido en el cliente pasaba desapercibido justamente porque
    -- la pantalla se llenaba de datos.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- El COUNT lleva el MISMO JOIN que el SELECT: si contara sobre la tabla
    -- pelada, `total` diria cuantas filas hay en todas las empresas mientras la
    -- lista muestra las de una.
    SELECT COUNT(*)
      INTO l_total
      FROM ARTICULOS_UBICACIONES au
      JOIN ARTICULOS a ON a.ID_ARTICULO = au.ID_ARTICULO
     WHERE a.ID_EMPRESA = l_id_empresa
       AND (l_id_articulo IS NULL OR au.ID_ARTICULO = l_id_articulo)
       AND (l_id_ubicacion IS NULL OR au.ID_UBICACION = l_id_ubicacion);

    -- CON JOIN, al reves que las tablas por empresa: cada fila cruza un articulo
    -- distinto con una ubicacion distinta, asi que sus nombres no son una
    -- constante repetida. Sin el JOIN el frontend tendria que traerse las dos
    -- tablas enteras para mostrar una lista legible.
    --
    -- Los JOIN son INTERNOS y no LEFT: las dos FK son NOT NULL, asi que no puede
    -- haber una fila sin articulo o sin ubicacion. Un LEFT aca solo escondaria
    -- una violacion de integridad.
    --
    -- ORDEN: zona, estante, nivel — el recorrido fisico del deposito, que es lo
    -- que sirve cuando se listan las ubicaciones de UN articulo. Cuando se filtra
    -- por ubicacion, el nombre del articulo desempata.
    --
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: el listado anda con pocas filas y devuelve 500 cuando crece.
    SELECT JSON_ARRAYAGG(fila ORDER BY zona, estante, nivel, nombre_articulo
                         RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'             VALUE au.ID_ARTICULO_UBICACION,
                 'idArticulo'     VALUE au.ID_ARTICULO,
                 'idUbicacion'    VALUE au.ID_UBICACION,
                 -- Del articulo: lo minimo para identificarlo en una lista.
                 'codigoArticulo' VALUE a.CODIGO_ARTICULO,
                 'nombreArticulo' VALUE a.NOMBRE_ARTICULO,
                 -- De la ubicacion: los tres datos que la componen, sueltos para
                 -- que el frontend arme la etiqueta como quiera.
                 'zona'           VALUE u.ZONA,
                 'estante'        VALUE u.ESTANTE,
                 'nivel'          VALUE u.NIVEL,
                 'descripcion'    VALUE u.DESCRIPCION,
                 -- La sucursal de la ubicacion: un articulo puede estar en
                 -- ubicaciones de varias sucursales, y ahi el nombre SI aporta
                 -- un dato distinto por fila.
                 'idSucursal'     VALUE u.ID_SUCURSAL,
                 'sucursal'       VALUE s.NOMBRE_SUCURSAL
                 RETURNING CLOB
               ) AS fila,
               u.ZONA             AS zona,
               u.ESTANTE          AS estante,
               u.NIVEL            AS nivel,
               a.NOMBRE_ARTICULO  AS nombre_articulo
          FROM ARTICULOS_UBICACIONES au
          JOIN ARTICULOS   a ON a.ID_ARTICULO  = au.ID_ARTICULO
          JOIN UBICACIONES u ON u.ID_UBICACION = au.ID_UBICACION
          JOIN SUCURSALES  s ON s.ID_SUCURSAL  = u.ID_SUCURSAL
         WHERE a.ID_EMPRESA = l_id_empresa
           AND (l_id_articulo IS NULL OR au.ID_ARTICULO = l_id_articulo)
           AND (l_id_ubicacion IS NULL OR au.ID_UBICACION = l_id_ubicacion)
      );

    p_status_code := 200;
    -- JSON_OBJECT(... RETURNING CLOB) como asignacion PL/SQL directa (sin
    -- SELECT) falla con PLS-00684 dentro de un package body.
    --
    -- JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un array vacio: sin
    -- el NVL el frontend recibiria "items":null y reventaria al iterarlo.
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
      APEX_DEBUG.ERROR('PKG_ARTICULOS_UBICACIONES.LISTAR: [' || SQLCODE || '] ' || SQLERRM ||
                       ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las ubicaciones del articulo"}';
  END LISTAR;

  -- p_id_empresa es OBLIGATORIO. El ASIGNAR comprobaba que el articulo y la
  -- ubicacion fueran de la MISMA empresa, pero no de la del que llama: una
  -- sesion de la empresa A podia crear una asignacion entre dos filas de la B
  -- con solo conocer sus ids. El QUITAR si lo validaba; el alta no.
  PROCEDURE ASIGNAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_id_ubicacion  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion        NUMBER;
    l_id_empresa    NUMBER;
    l_id_articulo   NUMBER;
    l_id_ubicacion  NUMBER;
    l_emp_articulo  NUMBER;
    l_emp_ubicacion NUMBER;
    l_id            NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_empresa   := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_articulo  := TO_NUMBER(NULLIF(p_id_articulo, ''));
    l_id_ubicacion := TO_NUMBER(NULLIF(p_id_ubicacion, ''));

    IF l_id_empresa IS NULL OR l_id_articulo IS NULL OR l_id_ubicacion IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, idArticulo e idUbicacion son obligatorios"}';
      RETURN;
    END IF;

    -- COHERENCIA DE EMPRESA. Las dos FK validan contra su propia tabla y
    -- ninguna mira la empresa: sin esto se puede asignar un articulo de una
    -- empresa a una ubicacion de otra, y ningun indice lo detecta.
    --
    -- Se leen las dos empresas por separado para poder distinguir "no existe"
    -- (404) de "no coinciden" (400) — con un solo SELECT que las cruzara, los
    -- dos casos darian NO_DATA_FOUND y el mensaje no podria ser especifico.
    BEGIN
      SELECT ID_EMPRESA INTO l_emp_articulo
        FROM ARTICULOS WHERE ID_ARTICULO = l_id_articulo;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_status_code := 404;
        p_resultado := '{"error":"El articulo no existe"}';
        RETURN;
    END;

    BEGIN
      SELECT ID_EMPRESA INTO l_emp_ubicacion
        FROM UBICACIONES WHERE ID_UBICACION = l_id_ubicacion;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_status_code := 404;
        p_resultado := '{"error":"La ubicacion no existe"}';
        RETURN;
    END;

    IF l_emp_articulo != l_emp_ubicacion THEN
      p_status_code := 400;
      p_resultado := '{"error":"El articulo y la ubicacion son de empresas distintas"}';
      RETURN;
    END IF;

    -- Y las dos tienen que ser de LA EMPRESA DE LA SESION. Sin esta linea, la
    -- comprobacion de arriba solo garantiza coherencia entre ellas: dos filas
    -- ajenas coherentes entre si pasaban igual. 404 y no 403, para no confirmar
    -- que el id existe en otra empresa.
    IF l_emp_articulo != l_id_empresa THEN
      p_status_code := 404;
      p_resultado := '{"error":"El articulo no existe"}';
      RETURN;
    END IF;

    INSERT INTO ARTICULOS_UBICACIONES (
      ID_ARTICULO, ID_UBICACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_articulo, l_id_ubicacion, SYSTIMESTAMP
    )
    RETURNING ID_ARTICULO_UBICACION INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- El UNIQUE es (ID_ARTICULO, ID_UBICACION): ya estaba asignado.
      p_status_code := 409;
      p_resultado := '{"error":"El articulo ya esta asignado a esa ubicacion"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: alguna FK no encontro el padre. No deberia llegar aca —los
      -- SELECT de arriba ya lo cubren— pero si la fila se borra entre la
      -- verificacion y el INSERT, es un dato invalido (400), no un 500.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El articulo o la ubicacion indicada no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_ARTICULOS_UBICACIONES.ASIGNAR: [' || SQLCODE || '] ' || SQLERRM ||
                         ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al asignar la ubicacion"}';
      END IF;
  END ASIGNAR;

  PROCEDURE QUITAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id         NUMBER;
    l_id_empresa NUMBER;
    l_existe     PLS_INTEGER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id         := TO_NUMBER(NULLIF(p_id, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- AISLAMIENTO POR EMPRESA, via el articulo padre.
    --
    -- ARTICULOS_UBICACIONES **no tiene columna ID_EMPRESA**: es una tabla de
    -- cruce y la empresa se deduce del articulo. Sin este chequeo, un DELETE
    -- con el id de una asignacion de otra empresa la borraba igual.
    --
    -- Se mira contra ARTICULOS y no contra UBICACIONES porque ASIGNAR ya
    -- garantiza que los dos lados sean de la misma empresa.
    SELECT COUNT(*)
      INTO l_existe
      FROM ARTICULOS_UBICACIONES au
      JOIN ARTICULOS             a ON a.ID_ARTICULO = au.ID_ARTICULO
     WHERE au.ID_ARTICULO_UBICACION = l_id
       AND a.ID_EMPRESA             = l_id_empresa;

    -- 404 y no 403: responder "existe pero no es tuya" confirmaria el id.
    IF l_existe = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La asignacion no existe"}';
      RETURN;
    END IF;

    -- Baja FISICA: la tabla no tiene columna ACTIVO. Se borra la asignacion, no
    -- el articulo ni la ubicacion.
    DELETE FROM ARTICULOS_UBICACIONES WHERE ID_ARTICULO_UBICACION = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La asignacion no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_ARTICULOS_UBICACIONES.QUITAR: [' || SQLCODE || '] ' || SQLERRM ||
                       ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al quitar la asignacion"}';
  END QUITAR;

  ------------------------------------------------------------------------------
  -- REPORTE
  ------------------------------------------------------------------------------
  PROCEDURE REPORTE (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_situacion     IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    -- 50 de techo, como /existencias: el JSON vuelve por un bind STRING de
    -- ORDS, y una pagina mas grande lo pasa y muere con un 500 mudo.
    C_TAMANIO_DEFECTO CONSTANT PLS_INTEGER := 20;
    C_TAMANIO_MAXIMO  CONSTANT PLS_INTEGER := 50;

    l_sesion        NUMBER;
    l_empresa       NUMBER;
    l_sucursal      NUMBER;
    l_situacion     VARCHAR2(3);
    l_pagina        PLS_INTEGER;
    l_tamanio       PLS_INTEGER;
    l_desplaza      PLS_INTEGER;
    l_existe        PLS_INTEGER;
    l_asignaciones  NUMBER;
    l_ubicaciones   NUMBER;
    l_ubicados      NUMBER;
    l_sin_ubicacion NUMBER;
    l_total         NUMBER;
    l_items         CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa   := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_sucursal  := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    l_situacion := UPPER(NULLIF(TRIM(p_situacion), ''));

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    IF l_sucursal IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idSucursal es obligatorio: las ubicaciones son de una sucursal"}';
      RETURN;
    END IF;

    IF l_situacion IS NOT NULL AND l_situacion NOT IN ('CON', 'SIN') THEN
      p_status_code := 400;
      p_resultado := '{"error":"situacion tiene que ser CON, SIN o vacia"}';
      RETURN;
    END IF;

    -- Una sucursal de otra empresa no filtraria nada ajeno —las ubicaciones se
    -- acotan tambien por empresa—, pero devolveria el catalogo entero como "sin
    -- ubicacion", que es un reporte falso con cara de verdadero.
    SELECT COUNT(*)
      INTO l_existe
      FROM SUCURSALES
     WHERE ID_SUCURSAL = l_sucursal
       AND ID_EMPRESA  = l_empresa;

    IF l_existe = 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La sucursal no es de esta empresa"}';
      RETURN;
    END IF;

    l_pagina   := GREATEST(NVL(TO_NUMBER(NULLIF(p_pagina, '')), 1), 1);
    l_tamanio  := LEAST(GREATEST(NVL(TO_NUMBER(NULLIF(p_tamanio, '')), C_TAMANIO_DEFECTO), 1),
                        C_TAMANIO_MAXIMO);
    l_desplaza := (l_pagina - 1) * l_tamanio;

    -- EL RESUMEN, sobre las dos mitades y sin mirar `situacion`: son los
    -- numeros de la sucursal, no de lo filtrado. Con ellos la pantalla dice
    -- "faltan ubicar 37" aunque este mirando solo los ubicados.
    --
    -- `total` sale de aca mismo y no de otro COUNT: es la suma de las mitades
    -- que pide `situacion`, contadas sobre EXACTAMENTE la misma consulta base
    -- que el listado de abajo. Dos COUNT con dos WHERE escritos a mano son la
    -- forma de que el total diga una cosa y las filas otra.
    SELECT COUNT(b.id_ubicacion),
           COUNT(DISTINCT b.id_ubicacion),
           COUNT(DISTINCT CASE WHEN b.id_ubicacion IS NOT NULL THEN b.id_articulo END),
           COUNT(CASE WHEN b.id_ubicacion IS NULL THEN 1 END)
      INTO l_asignaciones, l_ubicaciones, l_ubicados, l_sin_ubicacion
      FROM (
        -- LA CONSULTA BASE. Esta repetida abajo, identica: si se cambia una,
        -- se cambia la otra.
        SELECT a.ID_ARTICULO  AS id_articulo,
               ub.ID_UBICACION AS id_ubicacion
          FROM ARTICULOS a
          -- El cruce y la ubicacion se juntan ANTES del LEFT JOIN, en una
          -- vista: asi un articulo ubicado SOLO en otra sucursal no trae una
          -- fila del cruce con la ubicacion en null, sino que queda como lo que
          -- es aca — sin ubicar.
          LEFT JOIN (SELECT au.ID_ARTICULO, u.ID_UBICACION
                       FROM ARTICULOS_UBICACIONES au
                       JOIN UBICACIONES u ON u.ID_UBICACION = au.ID_UBICACION
                      WHERE u.ID_EMPRESA  = l_empresa
                        AND u.ID_SUCURSAL = l_sucursal) ub
                 ON ub.ID_ARTICULO = a.ID_ARTICULO
         WHERE a.ID_EMPRESA = l_empresa
           AND (ub.ID_UBICACION IS NOT NULL
                OR (CASE UPPER(TRIM(a.ACTIVO)) WHEN 'I' THEN 'I' WHEN '0' THEN 'I' ELSE 'A' END = 'A'
                    AND CASE UPPER(TRIM(a.ES_GASTO)) WHEN 'S' THEN 'S' ELSE 'N' END = 'N'))
      ) b;

    l_total := CASE l_situacion
                 WHEN 'CON' THEN l_asignaciones
                 WHEN 'SIN' THEN l_sin_ubicacion
                 ELSE l_asignaciones + l_sin_ubicacion
               END;

    -- ORDEN: primero los ubicados, por el recorrido fisico del deposito (zona,
    -- estante, nivel); despues los sin ubicacion, por nombre. El id del
    -- articulo desempata: sin una clave unica al final, OFFSET/FETCH puede
    -- repetir o saltear filas entre paginas.
    --
    -- El JSON_OBJECT va en la subconsulta y el JSON_ARRAYAGG agrega esa columna
    -- ya tipada como CLOB: anidado, el intermedio se materializa como VARCHAR2
    -- y revienta a los 4000 bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY sin_ubicacion, zona, estante, nivel,
                                       nombre_orden, id_articulo
                         RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'idArticulo'         VALUE a.ID_ARTICULO,
                 'codigoArticulo'     VALUE a.CODIGO_ARTICULO,
                 'nombreArticulo'     VALUE a.NOMBRE_ARTICULO,
                 'idCategoria'        VALUE a.ID_CATEGORIA,
                 'categoria'          VALUE c.NOMBRE_CATEGORIA,
                 'idMarca'            VALUE a.ID_MARCA,
                 'marca'              VALUE m.DESCRIPCION,
                 -- Toda la ubicacion en null cuando no tiene: es la marca de
                 -- "sin ubicacion" que lee la pantalla.
                 'idUbicacion'        VALUE ub.ID_UBICACION,
                 'zona'               VALUE ub.ZONA,
                 'estante'            VALUE ub.ESTANTE,
                 'nivel'              VALUE ub.NIVEL,
                 'descripcionUbicacion' VALUE ub.DESCRIPCION,
                 -- La existencia en ESTA sucursal. La fila puede no existir
                 -- (nunca tuvo movimiento): eso es 0, no null.
                 'cantidadStock'      VALUE NVL(e.CANTIDAD_DISPONIBLE, 0),
                 'esGasto'            VALUE CASE UPPER(TRIM(a.ES_GASTO))
                                              WHEN 'S' THEN 'S'
                                              ELSE 'N'
                                            END,
                 'activo'             VALUE CASE UPPER(TRIM(a.ACTIVO))
                                              WHEN 'I' THEN 'I'
                                              WHEN '0' THEN 'I'
                                              ELSE 'A'
                                            END
                 RETURNING CLOB
               ) AS fila,
               CASE WHEN ub.ID_UBICACION IS NULL THEN 1 ELSE 0 END AS sin_ubicacion,
               ub.ZONA                  AS zona,
               ub.ESTANTE               AS estante,
               ub.NIVEL                 AS nivel,
               UPPER(a.NOMBRE_ARTICULO) AS nombre_orden,
               a.ID_ARTICULO            AS id_articulo
          FROM ARTICULOS a
          -- LA MISMA CONSULTA BASE del resumen de arriba, con mas columnas.
          LEFT JOIN (SELECT au.ID_ARTICULO, u.ID_UBICACION, u.ZONA, u.ESTANTE, u.NIVEL,
                            u.DESCRIPCION
                       FROM ARTICULOS_UBICACIONES au
                       JOIN UBICACIONES u ON u.ID_UBICACION = au.ID_UBICACION
                      WHERE u.ID_EMPRESA  = l_empresa
                        AND u.ID_SUCURSAL = l_sucursal) ub
                 ON ub.ID_ARTICULO = a.ID_ARTICULO
          -- LEFT en las tres: categoria y marca son FK nullables, y la
          -- existencia puede no tener fila. Con un JOIN interno el articulo
          -- desapareceria del reporte sin ningun error.
          LEFT JOIN CATEGORIAS c ON c.ID_CATEGORIA = a.ID_CATEGORIA
          LEFT JOIN MARCAS     m ON m.ID_MARCA     = a.ID_MARCA
          LEFT JOIN EXISTENCIAS e ON e.ID_EMPRESA  = l_empresa
                                 AND e.ID_SUCURSAL = l_sucursal
                                 AND e.ID_ARTICULO = a.ID_ARTICULO
         WHERE a.ID_EMPRESA = l_empresa
           AND (ub.ID_UBICACION IS NOT NULL
                OR (CASE UPPER(TRIM(a.ACTIVO)) WHEN 'I' THEN 'I' WHEN '0' THEN 'I' ELSE 'A' END = 'A'
                    AND CASE UPPER(TRIM(a.ES_GASTO)) WHEN 'S' THEN 'S' ELSE 'N' END = 'N'))
           -- La situacion se aplica SOLO aca: el resumen cuenta las dos mitades.
           AND (l_situacion IS NULL
                OR (l_situacion = 'CON' AND ub.ID_UBICACION IS NOT NULL)
                OR (l_situacion = 'SIN' AND ub.ID_UBICACION IS NULL))
         -- El ORDER BY de la subconsulta es el que decide QUE filas entran en
         -- la pagina; el del JSON_ARRAYAGG solo el orden dentro de ella. Con
         -- las expresiones y no los alias: `id_articulo` chocaria con la
         -- columna ID_ARTICULO de la vista `ub` (ORA-00918).
         ORDER BY CASE WHEN ub.ID_UBICACION IS NULL THEN 1 ELSE 0 END,
                  ub.ZONA, ub.ESTANTE, ub.NIVEL, UPPER(a.NOMBRE_ARTICULO), a.ID_ARTICULO
         OFFSET l_desplaza ROWS FETCH NEXT l_tamanio ROWS ONLY
      );

    p_status_code := 200;
    -- SELECT ... INTO y no asignacion: RETURNING CLOB suelto es PLS-00684.
    -- NVL: JSON_ARRAYAGG sin filas da NULL, no un array vacio.
    SELECT JSON_OBJECT(
             'items'               VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON,
             'total'               VALUE l_total,
             'pagina'              VALUE l_pagina,
             'tamanio'             VALUE l_tamanio,
             'asignaciones'        VALUE l_asignaciones,
             'ubicacionesOcupadas' VALUE l_ubicaciones,
             'articulosUbicados'   VALUE l_ubicados,
             'sinUbicacion'        VALUE l_sin_ubicacion
             RETURNING CLOB
           )
      INTO p_resultado
      FROM DUAL;
  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_ARTICULOS_UBICACIONES.REPORTE: [' || SQLCODE || '] ' || SQLERRM ||
                       ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al generar el reporte de ubicaciones"}';
  END REPORTE;

  ------------------------------------------------------------------------------
  -- Publica el modulo ORDS /articulos-ubicaciones/.
  --
  -- Cada handler es una sola linea: invoca al procedimiento del paquete pasando
  -- los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parametro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin
  -- esto, toda peticion cross-origin a /articulos-ubicaciones/* la rechaza ORDS
  -- antes de llegar a los handlers. Ver la explicacion en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'articulos-ubicaciones',
      p_base_path      => '/articulos-ubicaciones/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'En que ubicaciones del deposito esta cada articulo'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'articulos-ubicaciones',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /articulos-ubicaciones/listar?idArticulo=&idUbicacion=
    --
    -- Los query params no se declaran con DEFINE_PARAMETER: se vinculan solos
    -- al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'articulos-ubicaciones', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'articulos-ubicaciones',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ARTICULOS_UBICACIONES.LISTAR(:authorization, :idEmpresa, :idArticulo, :idUbicacion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos-ubicaciones', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos-ubicaciones', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos-ubicaciones', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /articulos-ubicaciones/reporte?idEmpresa=&idSucursal=&situacion=
    --                                   &pagina=&tamanio=
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'articulos-ubicaciones', p_pattern => 'reporte');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'articulos-ubicaciones',
      p_pattern     => 'reporte',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ARTICULOS_UBICACIONES.REPORTE(:authorization, :idEmpresa, :idSucursal, :situacion, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos-ubicaciones', p_pattern => 'reporte', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos-ubicaciones', p_pattern => 'reporte', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos-ubicaciones', p_pattern => 'reporte', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /articulos-ubicaciones/crear
    -- Body: { idArticulo, idUbicacion }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'articulos-ubicaciones', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'articulos-ubicaciones',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ARTICULOS_UBICACIONES.ASIGNAR(:authorization, :idEmpresa, :idArticulo, :idUbicacion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos-ubicaciones', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos-ubicaciones', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos-ubicaciones', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /articulos-ubicaciones/eliminar/:id/:idEmpresa
    --
    -- El :id es el de la ASIGNACION (ID_ARTICULO_UBICACION), no el del articulo
    -- ni el de la ubicacion. El listado lo devuelve como `id`.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'articulos-ubicaciones', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'articulos-ubicaciones',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ARTICULOS_UBICACIONES.QUITAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos-ubicaciones', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos-ubicaciones', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos-ubicaciones', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_ARTICULOS_UBICACIONES;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_ARTICULOS_UBICACIONES.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_ARTICULOS_UBICACIONES'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_ARTICULOS_UBICACIONES'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'articulos-ubicaciones';

-- Rutas publicadas: listar (GET), crear (POST), eliminar/:id (DELETE).
-- NO hay PUT: reasignar es quitar y volver a asignar (ver el encabezado).
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'articulos-ubicaciones'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- Que hay asignado hoy.
SELECT au.ID_ARTICULO_UBICACION, a.NOMBRE_ARTICULO,
       s.NOMBRE_SUCURSAL, u.ZONA, u.ESTANTE, u.NIVEL
  FROM ARTICULOS_UBICACIONES au
  JOIN ARTICULOS   a ON a.ID_ARTICULO  = au.ID_ARTICULO
  JOIN UBICACIONES u ON u.ID_UBICACION = au.ID_UBICACION
  JOIN SUCURSALES  s ON s.ID_SUCURSAL  = u.ID_SUCURSAL
 ORDER BY a.NOMBRE_ARTICULO, u.ZONA, u.ESTANTE, u.NIVEL;

-- COHERENCIA DE EMPRESA: tiene que devolver CERO filas. Si devuelve alguna, hay
-- un articulo asignado a una ubicacion de OTRA empresa — el DDL lo permite y
-- solo el paquete lo evita, asi que las filas cargadas a mano pueden violarlo.
SELECT au.ID_ARTICULO_UBICACION, a.NOMBRE_ARTICULO,
       a.ID_EMPRESA AS EMPRESA_ARTICULO,
       u.ID_EMPRESA AS EMPRESA_UBICACION
  FROM ARTICULOS_UBICACIONES au
  JOIN ARTICULOS   a ON a.ID_ARTICULO  = au.ID_ARTICULO
  JOIN UBICACIONES u ON u.ID_UBICACION = au.ID_UBICACION
 WHERE a.ID_EMPRESA != u.ID_EMPRESA;
