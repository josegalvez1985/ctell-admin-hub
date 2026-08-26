--------------------------------------------------------------------------------
-- CTELL · CANALES DE PAGOS
--
-- Catálogo global de canales disponibles para pagos y cobros.
-- Requiere ejecutar antes db/auth.sql. El DDL de CANALES_PAGOS se administra
-- aparte; este archivo contiene el paquete y la publicación ORDS.
--
--   GET    /canales-pagos/listar
--   POST   /canales-pagos/crear
--   PUT    /canales-pagos/actualizar/:id
--   DELETE /canales-pagos/eliminar/:id
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_CANALES_PAGOS AS
  PROCEDURE LISTAR (
    p_authorization IN VARCHAR2,
    p_status_code OUT NUMBER,
    p_resultado OUT CLOB
  );

  PROCEDURE INSERTAR (
    p_authorization IN VARCHAR2,
    p_nombre_canal IN VARCHAR2,
    p_descripcion IN VARCHAR2,
    p_status_code OUT NUMBER,
    p_resultado OUT CLOB
  );

  PROCEDURE ACTUALIZAR (
    p_authorization IN VARCHAR2,
    p_id IN VARCHAR2,
    p_nombre_canal IN VARCHAR2,
    p_descripcion IN VARCHAR2,
    p_activo IN VARCHAR2,
    p_status_code OUT NUMBER,
    p_resultado OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization IN VARCHAR2,
    p_id IN VARCHAR2,
    p_status_code OUT NUMBER,
    p_resultado OUT CLOB
  );

  PROCEDURE PUBLICAR_ENDPOINTS;
END PKG_CANALES_PAGOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_CANALES_PAGOS AS

  PROCEDURE BORRAR_MODULO IS
    c_intentos CONSTANT PLS_INTEGER := 3;
    l_existe PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. c_intentos LOOP
      BEGIN
        SELECT COUNT(*) INTO l_existe
          FROM USER_ORDS_MODULES
         WHERE NAME = 'canales-pagos';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'canales-pagos');
        COMMIT;
        RETURN;
      EXCEPTION
        WHEN OTHERS THEN
          IF SQLCODE IN (-60, -4020) AND i < c_intentos THEN
            ROLLBACK;
            DBMS_SESSION.SLEEP(2);
          ELSE
            RAISE;
          END IF;
      END;
    END LOOP;
  END BORRAR_MODULO;

  PROCEDURE LISTAR (
    p_authorization IN VARCHAR2,
    p_status_code OUT NUMBER,
    p_resultado OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_total NUMBER;
    l_items CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    SELECT COUNT(*) INTO l_total FROM CANALES_PAGOS;

    SELECT JSON_ARRAYAGG(
             JSON_OBJECT(
               'id' VALUE ID_CANAL_PAGO,
               'nombreCanal' VALUE NOMBRE_CANAL,
               'descripcion' VALUE DESCRIPCION,
               'activo' VALUE UPPER(TRIM(ACTIVO))
               RETURNING CLOB
             ) ORDER BY NOMBRE_CANAL RETURNING CLOB
           )
      INTO l_items
      FROM CANALES_PAGOS;

    p_status_code := 200;
    SELECT JSON_OBJECT(
             'items' VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON,
             'total' VALUE l_total
             RETURNING CLOB
           ) INTO p_resultado FROM DUAL;
  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_CANALES_PAGOS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los canales de pago"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization IN VARCHAR2,
    p_nombre_canal IN VARCHAR2,
    p_descripcion IN VARCHAR2,
    p_status_code OUT NUMBER,
    p_resultado OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_id NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    IF TRIM(p_nombre_canal) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"nombreCanal es obligatorio"}';
      RETURN;
    END IF;

    INSERT INTO CANALES_PAGOS (NOMBRE_CANAL, DESCRIPCION, ACTIVO)
    VALUES (TRIM(p_nombre_canal), NULLIF(TRIM(p_descripcion), ''), 'A')
    RETURNING ID_CANAL_PAGO INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_CANALES_PAGOS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al crear el canal de pago"}';
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization IN VARCHAR2,
    p_id IN VARCHAR2,
    p_nombre_canal IN VARCHAR2,
    p_descripcion IN VARCHAR2,
    p_activo IN VARCHAR2,
    p_status_code OUT NUMBER,
    p_resultado OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_id NUMBER;
    l_estado VARCHAR2(1);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id := TO_NUMBER(NULLIF(p_id, ''));
    l_estado := CASE UPPER(TRIM(p_activo))
                  WHEN 'A' THEN 'A'
                  WHEN 'I' THEN 'I'
                  ELSE NULL
                END;

    UPDATE CANALES_PAGOS
       SET NOMBRE_CANAL = NVL(TRIM(p_nombre_canal), NOMBRE_CANAL),
           DESCRIPCION = NVL(NULLIF(TRIM(p_descripcion), ''), DESCRIPCION),
           ACTIVO = NVL(l_estado, ACTIVO),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_CANAL_PAGO = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El canal de pago no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_CANALES_PAGOS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al actualizar el canal de pago"}';
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization IN VARCHAR2,
    p_id IN VARCHAR2,
    p_status_code OUT NUMBER,
    p_resultado OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_id NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id := TO_NUMBER(NULLIF(p_id, ''));
    DELETE FROM CANALES_PAGOS WHERE ID_CANAL_PAGO = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El canal de pago no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_CANALES_PAGOS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al eliminar el canal de pago"}';
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name => 'canales-pagos', p_base_path => '/canales-pagos/',
      p_items_per_page => 0, p_status => 'PUBLISHED',
      p_comments => 'ABM de canales de pago');

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name => 'canales-pagos',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'canales-pagos', p_pattern => 'listar');
    ORDS.DEFINE_HANDLER(
      p_module_name => 'canales-pagos', p_pattern => 'listar', p_method => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source => 'BEGIN PKG_CANALES_PAGOS.LISTAR(:authorization, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'canales-pagos', p_pattern => 'listar', p_method => 'GET', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'canales-pagos', p_pattern => 'listar', p_method => 'GET', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'canales-pagos', p_pattern => 'listar', p_method => 'GET', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'canales-pagos', p_pattern => 'crear');
    ORDS.DEFINE_HANDLER(
      p_module_name => 'canales-pagos', p_pattern => 'crear', p_method => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source => 'BEGIN PKG_CANALES_PAGOS.INSERTAR(:authorization, :nombreCanal, :descripcion, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'canales-pagos', p_pattern => 'crear', p_method => 'POST', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'canales-pagos', p_pattern => 'crear', p_method => 'POST', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'canales-pagos', p_pattern => 'crear', p_method => 'POST', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'canales-pagos', p_pattern => 'actualizar/:id');
    ORDS.DEFINE_HANDLER(
      p_module_name => 'canales-pagos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source => 'BEGIN PKG_CANALES_PAGOS.ACTUALIZAR(:authorization, :id, :nombreCanal, :descripcion, :activo, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'canales-pagos', p_pattern => 'actualizar/:id', p_method => 'PUT', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'canales-pagos', p_pattern => 'actualizar/:id', p_method => 'PUT', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'canales-pagos', p_pattern => 'actualizar/:id', p_method => 'PUT', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'canales-pagos', p_pattern => 'eliminar/:id');
    ORDS.DEFINE_HANDLER(
      p_module_name => 'canales-pagos', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source => 'BEGIN PKG_CANALES_PAGOS.ELIMINAR(:authorization, :id, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'canales-pagos', p_pattern => 'eliminar/:id', p_method => 'DELETE', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'canales-pagos', p_pattern => 'eliminar/:id', p_method => 'DELETE', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'canales-pagos', p_pattern => 'eliminar/:id', p_method => 'DELETE', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;
END PKG_CANALES_PAGOS;
/

BEGIN
  PKG_CANALES_PAGOS.PUBLICAR_ENDPOINTS;
END;
/

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_CANALES_PAGOS'
 ORDER BY OBJECT_TYPE;

SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_CANALES_PAGOS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'canales-pagos';
