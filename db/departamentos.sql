--------------------------------------------------------------------------------
-- CTELL · DEPARTAMENTOS
--
-- Un paquete (PKG_DEPARTAMENTOS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicación de los endpoints ORDS. Todo vive
-- dentro del paquete: no hay procedimientos sueltos ni PL/SQL embebido como
-- texto dentro de los handlers.
--
--   1. LISTAR      GET    /departamentos/listar        (?idPais= opcional)
--   2. INSERTAR    POST   /departamentos/crear
--   3. ACTUALIZAR  PUT    /departamentos/actualizar/:id
--   4. ELIMINAR    DELETE /departamentos/eliminar/:id
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/departamentos/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   DEPARTAMENTOS  ID_DEPARTAMENTO, ID_PAIS, NOMBRE_DEPARTAMENTO, ACTIVO
--
-- La FK contra PAISES obliga a que el país exista: mandar un idPais inexistente
-- da ORA-02291 en el INSERT/UPDATE, que se traduce a 400 en vez de 500 — el
-- dato es inválido, no falló el servidor.
--
-- UQ_DEPTO_PAIS impide dos departamentos con el mismo nombre dentro del mismo
-- país, pero sí permite repetir el nombre entre países distintos. El
-- DUP_VAL_ON_INDEX se traduce a 409 con ese matiz en el mensaje.
--
-- ESTADO: ACTIVO es VARCHAR2(1) con 'A' (activo) / 'I' (inactivo). Ese mismo
-- código viaja en el JSON y lo consume el frontend, sin traducirse a 1/0.
--
-- OJO con el DEFAULT de la columna: el DDL declara `ACTIVO VARCHAR2(1)
-- DEFAULT 1`, que guarda el literal '1' y no 'A'. Por eso el INSERT de acá
-- escribe 'A' explícitamente en vez de dejar que actúe el default, y el
-- listado normaliza cualquier valor viejo a 'A'/'I' antes de devolverlo.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicación completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_DEPARTAMENTOS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_DEPARTAMENTOS.LISTAR('Bearer TU_TOKEN', NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_DEPARTAMENTOS AS

  -- p_id_pais NULL o vacío devuelve los departamentos de todos los países.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_pais       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE INSERTAR (
    p_authorization       IN  VARCHAR2,
    p_id_pais             IN  VARCHAR2,
    p_nombre_departamento IN  VARCHAR2,
    p_status_code         OUT NUMBER,
    p_resultado           OUT CLOB
  );

  -- Los parámetros ausentes (NULL) no modifican la columna correspondiente.
  PROCEDURE ACTUALIZAR (
    p_authorization       IN  VARCHAR2,
    p_id                  IN  VARCHAR2,
    p_id_pais             IN  VARCHAR2,
    p_nombre_departamento IN  VARCHAR2,
    p_activo              IN  VARCHAR2,
    p_status_code         OUT NUMBER,
    p_resultado           OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el módulo ORDS /departamentos/ con sus 4 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_DEPARTAMENTOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_DEPARTAMENTOS AS

  ------------------------------------------------------------------------------
  -- Privado: borra el módulo ORDS si existe, reintentando ante un interbloqueo.
  --
  -- Nunca usar `WHEN OTHERS THEN NULL` acá: se tragaría también un ORA-00060,
  -- el DELETE fallaría en silencio, y el DEFINE_MODULE de después moriría con
  -- ORA-00001 (nombre duplicado) contra el módulo que nunca se llegó a borrar.
  ------------------------------------------------------------------------------
  PROCEDURE BORRAR_MODULO IS
    C_INTENTOS CONSTANT PLS_INTEGER := 3;
    l_existe   PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. C_INTENTOS LOOP
      BEGIN
        -- Se consulta en vez de capturar el error de "no existe": así el
        -- EXCEPTION queda libre para los fallos que sí importan.
        SELECT COUNT(*)
          INTO l_existe
          FROM USER_ORDS_MODULES
         WHERE NAME = 'departamentos';

        IF l_existe = 0 THEN
          RETURN;  -- No existía: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'departamentos');
        COMMIT;  -- Libera los locks antes de que DEFINE_MODULE los vuelva a pedir.
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
          -- ORA-00060 (interbloqueo) y ORA-04020 (lock de objeto) son
          -- transitorios: la otra sesión termina y el reintento pasa.
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
    p_id_pais       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_id_pais NUMBER;
    l_total   NUMBER;
    l_items   CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- La conversión va acá, dentro del BEGIN: en el DECLARE se ejecutaría
    -- antes de que exista el EXCEPTION y el error escaparía del procedimiento.
    -- NULLIF convierte la cadena vacía del parámetro ausente en NULL antes de
    -- que TO_NUMBER la toque (si no, ORA-01722).
    l_id_pais := TO_NUMBER(NULLIF(p_id_pais, ''));

    SELECT COUNT(*)
      INTO l_total
      FROM DEPARTAMENTOS
     WHERE l_id_pais IS NULL OR ID_PAIS = l_id_pais;

    -- El JOIN trae nombre y código del país: el frontend los muestra en la
    -- lista y no tendría cómo resolverlos sin otra petición.
    --
    -- ACTIVO se normaliza a 'A'/'I': el DEFAULT del DDL es 1, así que puede
    -- haber filas viejas con '1'. Cualquier valor que no sea 'I' se considera
    -- activo, que es lo que ese default quería decir.
    SELECT JSON_ARRAYAGG(
             JSON_OBJECT(
               'id'                 VALUE d.ID_DEPARTAMENTO,
               'idPais'             VALUE d.ID_PAIS,
               'pais'               VALUE p.NOMBRE_PAIS,
               'codigoPais'         VALUE p.CODIGO_PAIS,
               'nombreDepartamento' VALUE d.NOMBRE_DEPARTAMENTO,
               'activo'             VALUE CASE UPPER(TRIM(d.ACTIVO))
                                            WHEN 'I' THEN 'I'
                                            WHEN '0' THEN 'I'
                                            ELSE 'A'
                                          END
               RETURNING CLOB
             )
             ORDER BY p.NOMBRE_PAIS, d.NOMBRE_DEPARTAMENTO
             RETURNING CLOB
           )
      INTO l_items
      FROM DEPARTAMENTOS d
      JOIN PAISES p ON p.ID_PAIS = d.ID_PAIS
     WHERE l_id_pais IS NULL OR d.ID_PAIS = l_id_pais;

    p_status_code := 200;
    -- JSON_OBJECT(... RETURNING CLOB) como asignación PL/SQL directa (sin
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
      APEX_DEBUG.ERROR('PKG_DEPARTAMENTOS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los departamentos"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization       IN  VARCHAR2,
    p_id_pais             IN  VARCHAR2,
    p_nombre_departamento IN  VARCHAR2,
    p_status_code         OUT NUMBER,
    p_resultado           OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_id_pais NUMBER;
    l_id      NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_pais := TO_NUMBER(NULLIF(p_id_pais, ''));

    IF l_id_pais IS NULL OR TRIM(p_nombre_departamento) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idPais y nombreDepartamento son obligatorios"}';
      RETURN;
    END IF;

    -- 'A' explícito: el DEFAULT de la columna es 1, que guardaría el literal
    -- '1' y rompería la comparación contra 'A'/'I' de todo el resto.
    INSERT INTO DEPARTAMENTOS (ID_PAIS, NOMBRE_DEPARTAMENTO, ACTIVO)
    VALUES (
      l_id_pais,
      TRIM(p_nombre_departamento),
      'A'
    )
    RETURNING ID_DEPARTAMENTO INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- UQ_DEPTO_PAIS es (ID_PAIS, NOMBRE_DEPARTAMENTO): el choque es dentro
      -- del mismo país, no global. El mensaje lo dice para que no parezca que
      -- el nombre está tomado en todos lados.
      p_status_code := 409;
      p_resultado := '{"error":"Ese pais ya tiene un departamento con ese nombre"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: la FK contra PAISES no encontró el padre. Es un dato
      -- inválido del cliente (400), no un fallo del servidor.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El pais indicado no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_DEPARTAMENTOS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear el departamento"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization       IN  VARCHAR2,
    p_id                  IN  VARCHAR2,
    p_id_pais             IN  VARCHAR2,
    p_nombre_departamento IN  VARCHAR2,
    p_activo              IN  VARCHAR2,
    p_status_code         OUT NUMBER,
    p_resultado           OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_id      NUMBER;
    l_id_pais NUMBER;
    l_estado  VARCHAR2(1);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id      := TO_NUMBER(NULLIF(p_id, ''));
    l_id_pais := TO_NUMBER(NULLIF(p_id_pais, ''));

    -- Un valor inválido se ignora en vez de escribirse: es preferible
    -- conservar el estado actual a dejar basura en la columna.
    l_estado := CASE UPPER(TRIM(p_activo))
                  WHEN 'A' THEN 'A'
                  WHEN 'I' THEN 'I'
                  ELSE NULL
                END;

    UPDATE DEPARTAMENTOS
       SET ID_PAIS             = NVL(l_id_pais, ID_PAIS),
           NOMBRE_DEPARTAMENTO = NVL(TRIM(p_nombre_departamento), NOMBRE_DEPARTAMENTO),
           ACTIVO              = NVL(l_estado, ACTIVO)
     WHERE ID_DEPARTAMENTO = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El departamento no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ese pais ya tiene un departamento con ese nombre"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El pais indicado no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_DEPARTAMENTOS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar el departamento"}';
      END IF;
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

    DELETE FROM DEPARTAMENTOS WHERE ID_DEPARTAMENTO = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El departamento no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos (ciudades, direcciones, lo que cuelgue del
      -- departamento) apuntando a esta fila. Es un conflicto de estado (409),
      -- no un error del servidor: el dato que mandaron era válido.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de este departamento"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_DEPARTAMENTOS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar el departamento"}';
      END IF;
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Publica el módulo ORDS /departamentos/ con sus 4 endpoints.
  --
  -- Cada handler es una sola línea: invoca al procedimiento del paquete
  -- pasando los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parámetro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahí). Sin
  -- esto, toda petición cross-origin a /departamentos/* la rechaza ORDS antes
  -- de llegar a cualquiera de los 4 handlers. Ver la explicación en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'departamentos',
      p_base_path      => '/departamentos/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'ABM de departamentos'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'departamentos',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /departamentos/listar?idPais=
    --
    -- idPais no se declara con DEFINE_PARAMETER: los query params se vinculan
    -- solos al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'departamentos', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'departamentos',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_DEPARTAMENTOS.LISTAR(:authorization, :idPais, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'departamentos', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'departamentos', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'departamentos', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /departamentos/crear
    -- Body: { idPais, nombreDepartamento }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'departamentos', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'departamentos',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_DEPARTAMENTOS.INSERTAR(:authorization, :idPais, :nombreDepartamento, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'departamentos', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'departamentos', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'departamentos', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /departamentos/actualizar/:id
    -- Body: { idPais?, nombreDepartamento?, activo? }  (ausentes = no cambia)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'departamentos', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'departamentos',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_DEPARTAMENTOS.ACTUALIZAR(:authorization, :id, :idPais, :nombreDepartamento, :activo, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'departamentos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'departamentos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'departamentos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /departamentos/eliminar/:id
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'departamentos', p_pattern => 'eliminar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'departamentos',
      p_pattern     => 'eliminar/:id',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_DEPARTAMENTOS.ELIMINAR(:authorization, :id, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'departamentos', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'departamentos', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'departamentos', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_DEPARTAMENTOS;
/

--------------------------------------------------------------------------------
-- 2. Publicación de los endpoints
--
-- Única sentencia fuera del paquete: la llamada que publica el módulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_DEPARTAMENTOS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Normalización del estado
--
-- El DDL declara ACTIVO con DEFAULT 1, así que las filas cargadas a mano antes
-- de este paquete pueden tener '1' en vez de 'A'. El listado ya lo normaliza al
-- devolverlo, pero conviene dejar la columna consistente con el resto de las
-- tablas para que los filtros por 'A'/'I' funcionen directo contra la base.
--------------------------------------------------------------------------------

UPDATE DEPARTAMENTOS
   SET ACTIVO = CASE UPPER(TRIM(ACTIVO))
                  WHEN 'I' THEN 'I'
                  WHEN '0' THEN 'I'
                  ELSE 'A'
                END
 WHERE ACTIVO IS NULL
    OR UPPER(TRIM(ACTIVO)) NOT IN ('A', 'I');

COMMIT;

--------------------------------------------------------------------------------
-- 4. Verificación
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_DEPARTAMENTOS'
 ORDER BY OBJECT_TYPE;

-- Si algo salió INVALID arriba, acá está el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_DEPARTAMENTOS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'departamentos';

SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'departamentos'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

SELECT d.ID_DEPARTAMENTO, d.ID_PAIS, p.NOMBRE_PAIS, d.NOMBRE_DEPARTAMENTO, d.ACTIVO
  FROM DEPARTAMENTOS d
  JOIN PAISES p ON p.ID_PAIS = d.ID_PAIS
 ORDER BY p.NOMBRE_PAIS, d.NOMBRE_DEPARTAMENTO;
