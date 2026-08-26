--------------------------------------------------------------------------------
-- CTELL · COBROS DEL PUNTO DE VENTA
-- Requiere PKG_AUTH, PKG_VENTAS y las tablas VENTAS_COBROS, VENTAS_CABECERAS,
-- VENTAS_CUOTAS, CANALES_PAGOS, MONEDAS y CUENTAS_BANCARIAS.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

DECLARE
  l_existe NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_existe FROM USER_TAB_COLUMNS WHERE TABLE_NAME = 'VENTAS_COBROS' AND COLUMN_NAME = 'ID_CUENTA_BANCARIA';
  IF l_existe = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE VENTAS_COBROS ADD (ID_CUENTA_BANCARIA NUMBER)';
  END IF;
  SELECT COUNT(*) INTO l_existe FROM USER_CONSTRAINTS WHERE TABLE_NAME = 'VENTAS_COBROS' AND CONSTRAINT_NAME = 'VENTAS_COBROS_FK_CUENTA';
  IF l_existe = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE VENTAS_COBROS ADD CONSTRAINT VENTAS_COBROS_FK_CUENTA FOREIGN KEY (ID_CUENTA_BANCARIA) REFERENCES CUENTAS_BANCARIAS (ID_CUENTA_BANCARIA)';
  END IF;
END;
/

CREATE OR REPLACE PACKAGE PKG_VENTAS_COBROS AS
  PROCEDURE LISTAR (p_authorization IN VARCHAR2, p_id_venta IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE INSERTAR (
    p_authorization IN VARCHAR2, p_id_venta IN VARCHAR2, p_id_cuota IN VARCHAR2,
    p_id_empresa IN VARCHAR2, p_id_canal_pago IN VARCHAR2, p_id_moneda IN VARCHAR2,
    p_id_cuenta_bancaria IN VARCHAR2, p_monto IN VARCHAR2, p_fecha_cobro IN VARCHAR2,
    p_referencia IN VARCHAR2, p_observacion IN VARCHAR2,
    p_status_code OUT NUMBER, p_resultado OUT CLOB
  );
  PROCEDURE PUBLICAR_ENDPOINTS;
END PKG_VENTAS_COBROS;
/

CREATE OR REPLACE PACKAGE BODY PKG_VENTAS_COBROS AS
  PROCEDURE BORRAR_MODULO IS l_existe PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. 3 LOOP
      BEGIN
        SELECT COUNT(*) INTO l_existe FROM USER_ORDS_MODULES WHERE NAME = 'ventas-cobros';
        IF l_existe = 0 THEN RETURN; END IF;
        ORDS.DELETE_MODULE(p_module_name => 'ventas-cobros'); COMMIT; RETURN;
      EXCEPTION WHEN OTHERS THEN
        IF SQLCODE IN (-60, -4020) AND i < 3 THEN ROLLBACK; DBMS_SESSION.SLEEP(2); ELSE RAISE; END IF;
      END;
    END LOOP;
  END BORRAR_MODULO;

  PROCEDURE LISTAR (p_authorization IN VARCHAR2, p_id_venta IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion NUMBER; l_venta NUMBER; l_empresa NUMBER; l_items CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization)); l_venta := TO_NUMBER(NULLIF(p_id_venta, '')); l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    SELECT JSON_ARRAYAGG(JSON_OBJECT('id' VALUE c.ID_COBRO, 'idVenta' VALUE c.ID_VENTA, 'idCuota' VALUE c.ID_CUOTA, 'idCanalPago' VALUE c.ID_CANAL_PAGO, 'canalPago' VALUE cp.NOMBRE_CANAL, 'idMoneda' VALUE c.ID_MONEDA, 'monto' VALUE c.MONTO, 'fechaCobro' VALUE TO_CHAR(c.FECHA_COBRO, 'YYYY-MM-DD"T"HH24:MI:SS'), 'referencia' VALUE c.REFERENCIA, 'observacion' VALUE c.OBSERVACION, 'idCuentaBancaria' VALUE c.ID_CUENTA_BANCARIA RETURNING CLOB) ORDER BY c.FECHA_COBRO RETURNING CLOB)
      INTO l_items FROM VENTAS_COBROS c JOIN VENTAS_CABECERAS v ON v.ID_VENTA = c.ID_VENTA JOIN CANALES_PAGOS cp ON cp.ID_CANAL_PAGO = c.ID_CANAL_PAGO WHERE c.ID_VENTA = l_venta AND v.ID_EMPRESA = l_empresa;
    p_status_code := 200; SELECT JSON_OBJECT('items' VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON RETURNING CLOB) INTO p_resultado FROM DUAL;
  EXCEPTION WHEN OTHERS THEN p_status_code := 500; p_resultado := '{"error":"Error al listar los cobros"}';
  END LISTAR;

  PROCEDURE INSERTAR (p_authorization IN VARCHAR2, p_id_venta IN VARCHAR2, p_id_cuota IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_canal_pago IN VARCHAR2, p_id_moneda IN VARCHAR2, p_id_cuenta_bancaria IN VARCHAR2, p_monto IN VARCHAR2, p_fecha_cobro IN VARCHAR2, p_referencia IN VARCHAR2, p_observacion IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion NUMBER; l_venta NUMBER; l_cuota NUMBER; l_empresa NUMBER; l_canal NUMBER; l_moneda NUMBER; l_cuenta NUMBER; l_monto NUMBER; l_fecha TIMESTAMP; l_total NUMBER; l_pagado NUMBER; l_id NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization)); l_venta := TO_NUMBER(NULLIF(p_id_venta, '')); l_cuota := TO_NUMBER(NULLIF(p_id_cuota, '')); l_empresa := TO_NUMBER(NULLIF(p_id_empresa, '')); l_canal := TO_NUMBER(NULLIF(p_id_canal_pago, '')); l_moneda := TO_NUMBER(NULLIF(p_id_moneda, '')); l_cuenta := TO_NUMBER(NULLIF(p_id_cuenta_bancaria, '')); l_monto := TO_NUMBER(NULLIF(p_monto, '')); l_fecha := TO_TIMESTAMP(NULLIF(p_fecha_cobro, ''), 'YYYY-MM-DD"T"HH24:MI:SS');
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_empresa IS NULL OR l_venta IS NULL OR l_canal IS NULL OR l_moneda IS NULL OR l_monto IS NULL OR l_monto <= 0 OR l_fecha IS NULL THEN p_status_code := 400; p_resultado := '{"error":"Faltan datos validos del cobro"}'; RETURN; END IF;
    SELECT MONTO_TOTAL INTO l_total FROM VENTAS_CABECERAS WHERE ID_VENTA = l_venta AND ID_EMPRESA = l_empresa;
    SELECT NVL(SUM(MONTO), 0) INTO l_pagado FROM VENTAS_COBROS WHERE ID_VENTA = l_venta;
    IF l_pagado + l_monto > l_total THEN p_status_code := 409; p_resultado := '{"error":"El cobro supera el saldo pendiente de la venta"}'; RETURN; END IF;
    IF l_cuota IS NOT NULL THEN
      SELECT NVL(MONTO_CUOTA, 0), NVL(MONTO_PAGADO, 0) INTO l_total, l_pagado FROM VENTAS_CUOTAS WHERE ID_CUOTA = l_cuota AND ID_VENTA = l_venta;
      IF l_pagado + l_monto > l_total THEN p_status_code := 409; p_resultado := '{"error":"El cobro supera el saldo de la cuota"}'; RETURN; END IF;
    END IF;
    INSERT INTO VENTAS_COBROS (ID_VENTA, ID_CUOTA, ID_CANAL_PAGO, ID_MONEDA, ID_CUENTA_BANCARIA, MONTO, FECHA_COBRO, REFERENCIA, OBSERVACION) VALUES (l_venta, l_cuota, l_canal, l_moneda, l_cuenta, l_monto, l_fecha, NULLIF(TRIM(p_referencia), ''), NULLIF(TRIM(p_observacion), '')) RETURNING ID_COBRO INTO l_id;
    IF l_cuota IS NOT NULL THEN UPDATE VENTAS_CUOTAS SET MONTO_PAGADO = MONTO_PAGADO + l_monto, ESTADO = CASE WHEN MONTO_PAGADO + l_monto >= MONTO_CUOTA THEN 'PAGADA' ELSE 'PARCIAL' END, FECHA_ACTUALIZACION = SYSTIMESTAMP WHERE ID_CUOTA = l_cuota; END IF;
    COMMIT; p_status_code := 201; p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION WHEN NO_DATA_FOUND THEN ROLLBACK; p_status_code := 404; p_resultado := '{"error":"La venta o cuota no existe"}';
  WHEN OTHERS THEN ROLLBACK; p_status_code := 500; p_resultado := '{"error":"Error al registrar el cobro"}';
  END INSERTAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO; ORDS.DEFINE_MODULE(p_module_name => 'ventas-cobros', p_base_path => '/ventas-cobros/', p_items_per_page => 0, p_status => 'PUBLISHED', p_comments => 'Cobros del punto de venta'); ORDS.SET_MODULE_ORIGINS_ALLOWED(p_module_name => 'ventas-cobros', p_origins_allowed => 'https://www.ctell.online,http://localhost:8080');
    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas-cobros', p_pattern => 'listar/:idVenta/:idEmpresa'); ORDS.DEFINE_HANDLER(p_module_name => 'ventas-cobros', p_pattern => 'listar/:idVenta/:idEmpresa', p_method => 'GET', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_VENTAS_COBROS.LISTAR(:authorization, :idVenta, :idEmpresa, :status_code, :resultado); END;'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'listar/:idVenta/:idEmpresa', p_method => 'GET', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'listar/:idVenta/:idEmpresa', p_method => 'GET', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'listar/:idVenta/:idEmpresa', p_method => 'GET', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');
    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas-cobros', p_pattern => 'crear'); ORDS.DEFINE_HANDLER(p_module_name => 'ventas-cobros', p_pattern => 'crear', p_method => 'POST', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_VENTAS_COBROS.INSERTAR(:authorization, :idVenta, :idCuota, :idEmpresa, :idCanalPago, :idMoneda, :idCuentaBancaria, :monto, :fechaCobro, :referencia, :observacion, :status_code, :resultado); END;'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'crear', p_method => 'POST', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'crear', p_method => 'POST', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'crear', p_method => 'POST', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT'); COMMIT;
  END PUBLICAR_ENDPOINTS;
END PKG_VENTAS_COBROS;
/
BEGIN PKG_VENTAS_COBROS.PUBLICAR_ENDPOINTS; END;
/