--------------------------------------------------------------------------------
-- CTELL · CUENTAS BANCARIAS
-- Catálogo de cuentas bancarias por empresa.
-- Requiere db/auth.sql, db/bancos.sql y db/monedas.sql ejecutados previamente.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_CUENTAS_BANCARIAS AS
  PROCEDURE LISTAR (p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE INSERTAR (
    p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_banco IN VARCHAR2,
    p_numero_cuenta IN VARCHAR2, p_tipo_cuenta IN VARCHAR2, p_titular IN VARCHAR2,
    p_saldo_inicial IN VARCHAR2, p_id_moneda IN VARCHAR2,
    p_status_code OUT NUMBER, p_resultado OUT CLOB
  );
  PROCEDURE ACTUALIZAR (
    p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2,
    p_id_banco IN VARCHAR2, p_numero_cuenta IN VARCHAR2, p_tipo_cuenta IN VARCHAR2,
    p_titular IN VARCHAR2, p_saldo_inicial IN VARCHAR2, p_id_moneda IN VARCHAR2,
    p_activo IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB
  );
  PROCEDURE ELIMINAR (p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE PUBLICAR_ENDPOINTS;
END PKG_CUENTAS_BANCARIAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_CUENTAS_BANCARIAS AS
  PROCEDURE BORRAR_MODULO IS
    l_existe PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. 3 LOOP
      BEGIN
        SELECT COUNT(*) INTO l_existe FROM USER_ORDS_MODULES WHERE NAME = 'cuentas-bancarias';
        IF l_existe = 0 THEN RETURN; END IF;
        ORDS.DELETE_MODULE(p_module_name => 'cuentas-bancarias'); COMMIT; RETURN;
      EXCEPTION
        WHEN OTHERS THEN
          IF SQLCODE IN (-60, -4020) AND i < 3 THEN ROLLBACK; DBMS_SESSION.SLEEP(2); ELSE RAISE; END IF;
      END;
    END LOOP;
  END BORRAR_MODULO;

  PROCEDURE LISTAR (p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion NUMBER; l_empresa NUMBER; l_total NUMBER; l_items CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_empresa IS NULL THEN p_status_code := 400; p_resultado := '{"error":"idEmpresa es obligatorio"}'; RETURN; END IF;
    SELECT COUNT(*) INTO l_total FROM CUENTAS_BANCARIAS WHERE ID_EMPRESA = l_empresa;
    SELECT JSON_ARRAYAGG(fila ORDER BY numero_cuenta RETURNING CLOB) INTO l_items FROM (
      SELECT JSON_OBJECT(
        'id' VALUE c.ID_CUENTA_BANCARIA, 'idEmpresa' VALUE c.ID_EMPRESA,
        'idBanco' VALUE c.ID_BANCO, 'banco' VALUE b.NOMBRE_BANCO,
        'numeroCuenta' VALUE c.NUMERO_CUENTA, 'tipoCuenta' VALUE c.TIPO_CUENTA,
        'titular' VALUE c.TITULAR, 'saldoInicial' VALUE c.SALDO_INICIAL,
        'idMoneda' VALUE c.ID_MONEDA, 'moneda' VALUE m.NOMBRE_MONEDA,
        'activo' VALUE CASE WHEN UPPER(TRIM(c.ACTIVO)) = 'I' THEN 'I' ELSE 'A' END
        RETURNING CLOB) AS fila, c.NUMERO_CUENTA AS numero_cuenta
      FROM CUENTAS_BANCARIAS c JOIN BANCOS b ON b.ID_BANCO = c.ID_BANCO
      LEFT JOIN MONEDAS m ON m.ID_MONEDA = c.ID_MONEDA
      WHERE c.ID_EMPRESA = l_empresa
    );
    p_status_code := 200;
    SELECT JSON_OBJECT('items' VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON, 'total' VALUE l_total RETURNING CLOB) INTO p_resultado FROM DUAL;
  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500; APEX_DEBUG.ERROR('PKG_CUENTAS_BANCARIAS.LISTAR: [' || SQLCODE || '] ' || SQLERRM);
      p_resultado := '{"error":"Error al listar las cuentas bancarias"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_banco IN VARCHAR2,
    p_numero_cuenta IN VARCHAR2, p_tipo_cuenta IN VARCHAR2, p_titular IN VARCHAR2,
    p_saldo_inicial IN VARCHAR2, p_id_moneda IN VARCHAR2,
    p_status_code OUT NUMBER, p_resultado OUT CLOB
  ) IS
    l_sesion NUMBER; l_empresa NUMBER; l_banco NUMBER; l_moneda NUMBER; l_saldo NUMBER; l_id NUMBER; l_moneda_valida NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, '')); l_banco := TO_NUMBER(NULLIF(p_id_banco, ''));
    l_moneda := TO_NUMBER(NULLIF(p_id_moneda, '')); l_saldo := TO_NUMBER(NULLIF(p_saldo_inicial, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_empresa IS NULL OR l_banco IS NULL OR TRIM(p_numero_cuenta) IS NULL THEN
      p_status_code := 400; p_resultado := '{"error":"idEmpresa, idBanco y numeroCuenta son obligatorios"}'; RETURN;
    END IF;
    IF l_moneda IS NOT NULL THEN
      SELECT COUNT(*) INTO l_moneda_valida FROM MONEDAS WHERE ID_MONEDA = l_moneda AND ID_EMPRESA = l_empresa;
      IF l_moneda_valida = 0 THEN p_status_code := 400; p_resultado := '{"error":"La moneda no pertenece a la empresa"}'; RETURN; END IF;
    END IF;
    INSERT INTO CUENTAS_BANCARIAS (ID_EMPRESA, ID_BANCO, NUMERO_CUENTA, TIPO_CUENTA, TITULAR, SALDO_INICIAL, ID_MONEDA, ACTIVO)
      VALUES (l_empresa, l_banco, TRIM(p_numero_cuenta), NULLIF(TRIM(p_tipo_cuenta), ''), NULLIF(TRIM(p_titular), ''), l_saldo, l_moneda, 'A')
      RETURNING ID_CUENTA_BANCARIA INTO l_id;
    COMMIT; p_status_code := 201; p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN ROLLBACK; p_status_code := 409; p_resultado := '{"error":"Ya existe una cuenta con ese número para el banco"}';
    WHEN OTHERS THEN ROLLBACK; p_status_code := 500; APEX_DEBUG.ERROR('PKG_CUENTAS_BANCARIAS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM); p_resultado := '{"error":"Error al crear la cuenta bancaria"}';
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2,
    p_id_banco IN VARCHAR2, p_numero_cuenta IN VARCHAR2, p_tipo_cuenta IN VARCHAR2,
    p_titular IN VARCHAR2, p_saldo_inicial IN VARCHAR2, p_id_moneda IN VARCHAR2,
    p_activo IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB
  ) IS
    l_sesion NUMBER; l_id NUMBER; l_empresa NUMBER; l_banco NUMBER; l_moneda NUMBER; l_saldo NUMBER; l_estado VARCHAR2(1);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_id := TO_NUMBER(NULLIF(p_id, '')); l_empresa := TO_NUMBER(NULLIF(p_id_empresa, '')); l_banco := TO_NUMBER(NULLIF(p_id_banco, ''));
    l_moneda := TO_NUMBER(NULLIF(p_id_moneda, '')); l_saldo := TO_NUMBER(NULLIF(p_saldo_inicial, ''));
    l_estado := CASE UPPER(TRIM(p_activo)) WHEN 'A' THEN 'A' WHEN 'I' THEN 'I' ELSE NULL END;
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_empresa IS NULL THEN p_status_code := 400; p_resultado := '{"error":"idEmpresa es obligatorio"}'; RETURN; END IF;
    UPDATE CUENTAS_BANCARIAS SET ID_BANCO = NVL(l_banco, ID_BANCO), NUMERO_CUENTA = NVL(TRIM(p_numero_cuenta), NUMERO_CUENTA),
      TIPO_CUENTA = NVL(NULLIF(TRIM(p_tipo_cuenta), ''), TIPO_CUENTA), TITULAR = NVL(NULLIF(TRIM(p_titular), ''), TITULAR),
      SALDO_INICIAL = NVL(l_saldo, SALDO_INICIAL), ID_MONEDA = NVL(l_moneda, ID_MONEDA), ACTIVO = NVL(l_estado, ACTIVO), FECHA_ACTUALIZACION = SYSTIMESTAMP
      WHERE ID_CUENTA_BANCARIA = l_id AND ID_EMPRESA = l_empresa;
    IF SQL%ROWCOUNT = 0 THEN p_status_code := 404; p_resultado := '{"error":"La cuenta bancaria no existe"}'; RETURN; END IF;
    COMMIT; p_status_code := 200; p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN ROLLBACK; p_status_code := 409; p_resultado := '{"error":"Ya existe una cuenta con ese número para el banco"}';
    WHEN OTHERS THEN ROLLBACK; p_status_code := 500; APEX_DEBUG.ERROR('PKG_CUENTAS_BANCARIAS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM); p_resultado := '{"error":"Error al actualizar la cuenta bancaria"}';
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion NUMBER; l_id NUMBER; l_empresa NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization)); l_id := TO_NUMBER(NULLIF(p_id, '')); l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    DELETE FROM CUENTAS_BANCARIAS WHERE ID_CUENTA_BANCARIA = l_id AND ID_EMPRESA = l_empresa;
    IF SQL%ROWCOUNT = 0 THEN ROLLBACK; p_status_code := 404; p_resultado := '{"error":"La cuenta bancaria no existe"}'; RETURN; END IF;
    COMMIT; p_status_code := 200; p_resultado := '{"ok":true}';
  EXCEPTION WHEN OTHERS THEN ROLLBACK; p_status_code := 500; APEX_DEBUG.ERROR('PKG_CUENTAS_BANCARIAS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM); p_resultado := '{"error":"Error al eliminar la cuenta bancaria"}';
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;
    ORDS.DEFINE_MODULE(p_module_name => 'cuentas-bancarias', p_base_path => '/cuentas-bancarias/', p_items_per_page => 0, p_status => 'PUBLISHED', p_comments => 'ABM de cuentas bancarias');
    ORDS.SET_MODULE_ORIGINS_ALLOWED(p_module_name => 'cuentas-bancarias', p_origins_allowed => 'https://www.ctell.online,http://localhost:8080');
    ORDS.DEFINE_TEMPLATE(p_module_name => 'cuentas-bancarias', p_pattern => 'listar');
    ORDS.DEFINE_HANDLER(p_module_name => 'cuentas-bancarias', p_pattern => 'listar', p_method => 'GET', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_CUENTAS_BANCARIAS.LISTAR(:authorization, :idEmpresa, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'listar', p_method => 'GET', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'listar', p_method => 'GET', p_name => 'idEmpresa', p_bind_variable_name => 'idEmpresa', p_source_type => 'QUERY', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'listar', p_method => 'GET', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'listar', p_method => 'GET', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');
    ORDS.DEFINE_TEMPLATE(p_module_name => 'cuentas-bancarias', p_pattern => 'crear');
    ORDS.DEFINE_HANDLER(p_module_name => 'cuentas-bancarias', p_pattern => 'crear', p_method => 'POST', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_CUENTAS_BANCARIAS.INSERTAR(:authorization, :idEmpresa, :idBanco, :numeroCuenta, :tipoCuenta, :titular, :saldoInicial, :idMoneda, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'crear', p_method => 'POST', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'crear', p_method => 'POST', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'crear', p_method => 'POST', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');
    ORDS.DEFINE_TEMPLATE(p_module_name => 'cuentas-bancarias', p_pattern => 'actualizar/:id');
    ORDS.DEFINE_HANDLER(p_module_name => 'cuentas-bancarias', p_pattern => 'actualizar/:id', p_method => 'PUT', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_CUENTAS_BANCARIAS.ACTUALIZAR(:authorization, :id, :idEmpresa, :idBanco, :numeroCuenta, :tipoCuenta, :titular, :saldoInicial, :idMoneda, :activo, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'actualizar/:id', p_method => 'PUT', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'actualizar/:id', p_method => 'PUT', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'actualizar/:id', p_method => 'PUT', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');
    ORDS.DEFINE_TEMPLATE(p_module_name => 'cuentas-bancarias', p_pattern => 'eliminar/:id/:idEmpresa');
    ORDS.DEFINE_HANDLER(p_module_name => 'cuentas-bancarias', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_CUENTAS_BANCARIAS.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'cuentas-bancarias', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');
    COMMIT;
  END PUBLICAR_ENDPOINTS;
END PKG_CUENTAS_BANCARIAS;
/

BEGIN PKG_CUENTAS_BANCARIAS.PUBLICAR_ENDPOINTS; END;
/