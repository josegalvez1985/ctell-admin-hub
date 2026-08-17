--------------------------------------------------------------------------------
-- CTELL · MODULOS
--
-- Un paquete (PKG_MODULOS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR —, y 4 bloques ORDS.DEFINE_HANDLER independientes que
-- solo invocan al procedimiento correspondiente. Cada handler es una línea:
-- toda la lógica vive en el paquete, no en texto embebido dentro del handler.
--
-- Cada endpoint tiene nombre propio en la URL — nada de patrones '.' sueltos,
-- que ORDS resuelve como "la raíz del módulo" pero se ven ambiguos en el
-- árbol de APEX y en cualquier lector del código:
--
--   1. LISTAR      GET    /modulos/listar
--   2. INSERTAR    POST   /modulos/crear
--   3. ACTUALIZAR  PUT    /modulos/actualizar/:id
--   4. ELIMINAR    DELETE /modulos/eliminar/:id
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES (usa PKG_AUTH
-- para validar el token). El borrado/republicación del módulo ORDS vive
-- DENTRO de este mismo paquete (PKG_MODULOS.PUBLICAR_ENDPOINTS) — no depende
-- de ningún procedimiento externo como BORRAR_MODULO_ORDS.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/modulos/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   MODULOS  ID_MODULO, NOMBRE, ICONO, ORDEN, ACTIVO
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_MODULOS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_MODULOS.LISTAR('Bearer TU_TOKEN', l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_MODULOS AS

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_icono         IN  VARCHAR2,
    p_orden         IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Los parámetros ausentes (NULL) no modifican la columna correspondiente.
  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_icono         IN  VARCHAR2,
    p_orden         IN  VARCHAR2,
    p_activo        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y vuelve a publicar el módulo ORDS /modulos/ con sus 4 endpoints.
  -- Se llama una sola vez, al final de este archivo. Está acá adentro para que
  -- el paquete sea autocontenido: no depende de ningún procedimiento suelto.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_MODULOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_MODULOS AS

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
         WHERE NAME = 'modulos';

        IF l_existe = 0 THEN
          RETURN;  -- No existía: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'modulos');
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
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_total  NUMBER;
    l_items  CLOB;
  BEGIN
    -- SOLO ADMINISTRADORES: la estructura del menu se administra desde la
    -- pantalla de Administracion, que ya es exclusiva de admins. El menu que ve
    -- cada usuario NO sale de aca sino de /usuario-paginas/listar, asi que
    -- restringir este modulo no deja a nadie sin menu.
    l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 403;
      p_resultado := '{"error":"Se requieren permisos de administrador"}';
      RETURN;
    END IF;

    SELECT COUNT(*) INTO l_total FROM MODULOS;

    SELECT JSON_ARRAYAGG(
             JSON_OBJECT(
               'id'     VALUE ID_MODULO,
               'nombre' VALUE NOMBRE,
               'icono'  VALUE ICONO,
               'orden'  VALUE ORDEN,
               'activo' VALUE UPPER(TRIM(ACTIVO))
               RETURNING CLOB
             )
             ORDER BY ORDEN, NOMBRE
             RETURNING CLOB
           )
      INTO l_items
      FROM MODULOS;

    p_status_code := 200;
    -- JSON_OBJECT(... RETURNING CLOB) como asignación PL/SQL directa (sin
    -- SELECT) falla con PLS-00684 dentro de un package body. Envuelto en un
    -- SELECT ... FROM DUAL sí es válido — mismo patrón que usa auth.sql y
    -- usuarios.sql para armar la respuesta final.
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
      APEX_DEBUG.ERROR('PKG_MODULOS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los modulos"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_icono         IN  VARCHAR2,
    p_orden         IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_id     NUMBER;
  BEGIN
    -- SOLO ADMINISTRADORES: la estructura del menu se administra desde la
    -- pantalla de Administracion, que ya es exclusiva de admins. El menu que ve
    -- cada usuario NO sale de aca sino de /usuario-paginas/listar, asi que
    -- restringir este modulo no deja a nadie sin menu.
    l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 403;
      p_resultado := '{"error":"Se requieren permisos de administrador"}';
      RETURN;
    END IF;

    IF TRIM(p_nombre) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"nombre es obligatorio"}';
      RETURN;
    END IF;

    INSERT INTO MODULOS (NOMBRE, ICONO, ORDEN, ACTIVO)
    VALUES (
      TRIM(p_nombre),
      TRIM(p_icono),
      NVL(TO_NUMBER(NULLIF(p_orden, '')), 0),
      'A'
    )
    RETURNING ID_MODULO INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_MODULOS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al crear el modulo"}';
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_icono         IN  VARCHAR2,
    p_orden         IN  VARCHAR2,
    p_activo        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_estado VARCHAR2(1);
  BEGIN
    -- SOLO ADMINISTRADORES: la estructura del menu se administra desde la
    -- pantalla de Administracion, que ya es exclusiva de admins. El menu que ve
    -- cada usuario NO sale de aca sino de /usuario-paginas/listar, asi que
    -- restringir este modulo no deja a nadie sin menu.
    l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 403;
      p_resultado := '{"error":"Se requieren permisos de administrador"}';
      RETURN;
    END IF;

    -- Valor invalido = NULL = no cambiar: es preferible ignorar un codigo que
    -- no entendemos a escribir basura en la columna.
    l_estado := CASE UPPER(TRIM(p_activo))
                  WHEN 'A' THEN 'A'
                  WHEN 'I' THEN 'I'
                  ELSE NULL
                END;

    UPDATE MODULOS
       SET NOMBRE = NVL(TRIM(p_nombre), NOMBRE),
           ICONO  = NVL(TRIM(p_icono), ICONO),
           ORDEN  = NVL(TO_NUMBER(NULLIF(p_orden, '')), ORDEN),
           ACTIVO = NVL(l_estado, ACTIVO)
     WHERE ID_MODULO = TO_NUMBER(NULLIF(p_id, ''));

    -- Sin esto, actualizar un ID inexistente devuelve 200 y quien lo usó cree
    -- que guardó.
    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El modulo no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_MODULOS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al actualizar el modulo"}';
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
  BEGIN
    -- SOLO ADMINISTRADORES: la estructura del menu se administra desde la
    -- pantalla de Administracion, que ya es exclusiva de admins. El menu que ve
    -- cada usuario NO sale de aca sino de /usuario-paginas/listar, asi que
    -- restringir este modulo no deja a nadie sin menu.
    l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 403;
      p_resultado := '{"error":"Se requieren permisos de administrador"}';
      RETURN;
    END IF;

    DELETE FROM MODULOS WHERE ID_MODULO = TO_NUMBER(NULLIF(p_id, ''));

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El modulo no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_MODULOS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al eliminar el modulo"}';
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Publica el módulo ORDS /modulos/ con sus 4 endpoints.
  --
  -- Cada handler es una sola línea: invoca al procedimiento del paquete
  -- pasando los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parámetro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahí). Sin
  -- esto, toda petición cross-origin a /modulos/* la rechaza ORDS antes de
  -- llegar a cualquiera de los 4 handlers. Ver la explicación en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
    p_module_name    => 'modulos',
    p_base_path      => '/modulos/',
    p_items_per_page => 0,
    p_status         => 'PUBLISHED',
    p_comments       => 'ABM de modulos del sistema'
  );

  ORDS.SET_MODULE_ORIGINS_ALLOWED(
    p_module_name     => 'modulos',
    p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
  );

  ------------------------------------------------------------------------------
  -- GET /modulos/listar
  ------------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'modulos', p_pattern => 'listar');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'modulos',
    p_pattern     => 'listar',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => 'BEGIN PKG_MODULOS.LISTAR(:authorization, :status_code, :resultado); END;'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'modulos', p_pattern => 'listar', p_method => 'GET',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'modulos', p_pattern => 'listar', p_method => 'GET',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'modulos', p_pattern => 'listar', p_method => 'GET',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ------------------------------------------------------------------------------
  -- POST /modulos/crear
  -- Body: { nombre, icono?, orden? }
  ------------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'modulos', p_pattern => 'crear');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'modulos',
    p_pattern     => 'crear',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => 'BEGIN PKG_MODULOS.INSERTAR(:authorization, :nombre, :icono, :orden, :status_code, :resultado); END;'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'modulos', p_pattern => 'crear', p_method => 'POST',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'modulos', p_pattern => 'crear', p_method => 'POST',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'modulos', p_pattern => 'crear', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ------------------------------------------------------------------------------
  -- PUT /modulos/actualizar/:id
  -- Body: { nombre?, icono?, orden?, activo? }  (ausentes = no cambia)
  ------------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'modulos', p_pattern => 'actualizar/:id');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'modulos',
    p_pattern     => 'actualizar/:id',
    p_method      => 'PUT',
    p_source_type => ORDS.source_type_plsql,
    p_source      => 'BEGIN PKG_MODULOS.ACTUALIZAR(:authorization, :id, :nombre, :icono, :orden, :activo, :status_code, :resultado); END;'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'modulos', p_pattern => 'actualizar/:id', p_method => 'PUT',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'modulos', p_pattern => 'actualizar/:id', p_method => 'PUT',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'modulos', p_pattern => 'actualizar/:id', p_method => 'PUT',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ------------------------------------------------------------------------------
  -- DELETE /modulos/eliminar/:id
  ------------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'modulos', p_pattern => 'eliminar/:id');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'modulos',
    p_pattern     => 'eliminar/:id',
    p_method      => 'DELETE',
    p_source_type => ORDS.source_type_plsql,
    p_source      => 'BEGIN PKG_MODULOS.ELIMINAR(:authorization, :id, :status_code, :resultado); END;'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'modulos', p_pattern => 'eliminar/:id', p_method => 'DELETE',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'modulos', p_pattern => 'eliminar/:id', p_method => 'DELETE',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'modulos', p_pattern => 'eliminar/:id', p_method => 'DELETE',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_MODULOS;
/

--------------------------------------------------------------------------------
-- 2. Publicación de los endpoints
--
-- Única sentencia fuera del paquete: la llamada que publica el módulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_MODULOS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificación
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_MODULOS'
 ORDER BY OBJECT_TYPE;

-- Si algo salió INVALID arriba, acá está el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_MODULOS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'modulos';

SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'modulos'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

SELECT ID_MODULO, NOMBRE, ICONO, ORDEN, ACTIVO
  FROM MODULOS
 ORDER BY ORDEN, NOMBRE;
