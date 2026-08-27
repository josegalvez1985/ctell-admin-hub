--------------------------------------------------------------------------------
-- CTELL · VENTAS COBROS
-- Registra cobros contra ventas. Cuando se indica la cuota, actualiza
-- MONTO_PAGADO y ESTADO en VENTAS_CUOTAS.
-- Requiere PKG_AUTH, VENTAS_CABECERAS, VENTAS_DETALLES, VENTAS_CUOTAS,
-- CANALES_PAGOS, CUENTAS_BANCARIAS, BANCOS y MONEDAS.
--
-- NO SE COBRA MAS QUE EL SALDO. El saldo es la SUMA DEL DETALLE menos la suma
-- de los cobros: ninguno de los dos se guarda en la cabecera, que ya no tiene
-- MONTO_TOTAL. Se lee con la cabecera bloqueada (FOR UPDATE) para que dos cajas
-- cobrando a la vez no vean ambas saldo suficiente y sobre-cobren la venta.
-- Se rechaza: una venta ya saldada (409), un monto mayor al saldo (409), una
-- cuota de otra venta (404) y una cuota ya pagada (409).
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_VENTAS_COBROS AS
  PROCEDURE LISTAR (p_authorization IN VARCHAR2, p_id_venta IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE INSERTAR (
    p_authorization IN VARCHAR2,
    p_id_venta IN VARCHAR2, p_id_cuota IN VARCHAR2, p_id_empresa IN VARCHAR2,
    p_id_canal_pago IN VARCHAR2, p_id_moneda IN VARCHAR2, p_id_cuenta_bancaria IN VARCHAR2,
    p_monto IN VARCHAR2, p_fecha_cobro IN VARCHAR2, p_referencia IN VARCHAR2, p_observacion IN VARCHAR2,
    p_status_code OUT NUMBER, p_resultado OUT CLOB
  );
  PROCEDURE ELIMINAR (p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
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
    l_sesion NUMBER; l_id_venta NUMBER; l_id_empresa NUMBER; l_items CLOB;
  BEGIN
    l_sesion     := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_id_venta   := TO_NUMBER(NULLIF(p_id_venta, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_id_venta IS NULL OR l_id_empresa IS NULL THEN p_status_code := 400; p_resultado := '{"error":"idVenta e idEmpresa son obligatorios"}'; RETURN; END IF;
    SELECT JSON_ARRAYAGG(
      JSON_OBJECT(
        'id'               VALUE c.ID_COBRO,
        'idVenta'          VALUE c.ID_VENTA,
        'idCuota'          VALUE c.ID_CUOTA,
        'idCanalPago'      VALUE c.ID_CANAL_PAGO,
        'canalPago'        VALUE cp.NOMBRE_CANAL,
        'idMoneda'         VALUE c.ID_MONEDA,
        'idCuentaBancaria' VALUE c.ID_CUENTA_BANCARIA,
        -- Banco y numero resueltos aca: el historial tiene que decir A DONDE
        -- entro la plata, y un id suelto no se lo dice a nadie.
        'banco'            VALUE b.NOMBRE_BANCO,
        'numeroCuenta'     VALUE cb.NUMERO_CUENTA,
        -- El numero de cuota, no solo su id, para no tener que cruzarlo contra
        -- el detalle de la venta solo para escribir "Cuota 2".
        'nroCuota'         VALUE q.NRO_CUOTA,
        'monto'            VALUE c.MONTO,
        'fechaCobro'       VALUE TO_CHAR(c.FECHA_COBRO, 'YYYY-MM-DD"T"HH24:MI:SS'),
        'referencia'       VALUE c.REFERENCIA,
        'observacion'      VALUE c.OBSERVACION
        RETURNING CLOB
      ) ORDER BY c.FECHA_COBRO DESC RETURNING CLOB
    ) INTO l_items
    FROM VENTAS_COBROS c
    -- TODOS los JOIN son LEFT a proposito. Un cobro EXISTIO: si despues borran
    -- el canal, la cuenta o el banco, tiene que seguir apareciendo en el
    -- historial. Con JOIN interno el cobro desaparecia sin ningun error y la
    -- venta mostraba menos cobrado de lo que realmente se cobro.
    LEFT JOIN CANALES_PAGOS     cp ON cp.ID_CANAL_PAGO      = c.ID_CANAL_PAGO
    LEFT JOIN CUENTAS_BANCARIAS cb ON cb.ID_CUENTA_BANCARIA = c.ID_CUENTA_BANCARIA
    LEFT JOIN BANCOS            b  ON b.ID_BANCO            = cb.ID_BANCO
    LEFT JOIN VENTAS_CUOTAS     q  ON q.ID_CUOTA            = c.ID_CUOTA
    WHERE c.ID_VENTA = l_id_venta
      AND EXISTS (SELECT 1 FROM VENTAS_CABECERAS v WHERE v.ID_VENTA = c.ID_VENTA AND v.ID_EMPRESA = l_id_empresa);
    p_status_code := 200;
    SELECT JSON_OBJECT('items' VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON RETURNING CLOB) INTO p_resultado FROM DUAL;
  EXCEPTION WHEN OTHERS THEN
    p_status_code := 500; APEX_DEBUG.ERROR('PKG_VENTAS_COBROS.LISTAR: ' || SQLERRM); p_resultado := '{"error":"Error al listar los cobros"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization IN VARCHAR2,
    p_id_venta IN VARCHAR2, p_id_cuota IN VARCHAR2, p_id_empresa IN VARCHAR2,
    p_id_canal_pago IN VARCHAR2, p_id_moneda IN VARCHAR2, p_id_cuenta_bancaria IN VARCHAR2,
    p_monto IN VARCHAR2, p_fecha_cobro IN VARCHAR2, p_referencia IN VARCHAR2, p_observacion IN VARCHAR2,
    p_status_code OUT NUMBER, p_resultado OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_venta   NUMBER;
    l_id_cuota   NUMBER;
    l_id_empresa NUMBER;
    l_canal      NUMBER;
    l_moneda     NUMBER;
    l_cuenta     NUMBER;
    l_monto      NUMBER;
    l_fecha      TIMESTAMP;
    l_id         NUMBER;
    l_total      NUMBER;
    l_existe     NUMBER;
    l_cobrado    NUMBER;
    l_saldo      NUMBER;
    l_saldo_cuota NUMBER;
  BEGIN
    l_sesion     := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_id_venta   := TO_NUMBER(NULLIF(p_id_venta, ''));
    l_id_cuota   := TO_NUMBER(NULLIF(p_id_cuota, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_canal      := TO_NUMBER(NULLIF(p_id_canal_pago, ''));
    l_moneda     := TO_NUMBER(NULLIF(p_id_moneda, ''));
    l_cuenta     := TO_NUMBER(NULLIF(p_id_cuenta_bancaria, ''));
    l_monto      := TO_NUMBER(NULLIF(p_monto, ''));
    l_fecha      := TO_TIMESTAMP(NULLIF(p_fecha_cobro, ''), 'YYYY-MM-DD"T"HH24:MI:SS');
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_id_venta IS NULL OR l_id_empresa IS NULL OR l_canal IS NULL OR l_moneda IS NULL OR l_monto IS NULL OR l_monto <= 0 THEN
      p_status_code := 400; p_resultado := '{"error":"Faltan datos obligatorios del cobro"}'; RETURN;
    END IF;
    -- FOR UPDATE, no un COUNT suelto: entre leer el saldo y grabar el cobro,
    -- otra caja podria cobrar la misma venta y las dos verian saldo suficiente.
    -- El lock sobre la cabecera serializa los cobros de esa venta.
    BEGIN
      SELECT ID_VENTA INTO l_existe
        FROM VENTAS_CABECERAS
       WHERE ID_VENTA = l_id_venta AND ID_EMPRESA = l_id_empresa
         FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      ROLLBACK; p_status_code := 404; p_resultado := '{"error":"La venta no existe"}'; RETURN;
    END;
    -- El total sale del DETALLE: la cabecera ya no guarda MONTO_TOTAL. El lock
    -- de arriba igual sirve, porque es lo que serializa los cobros de la venta.
    SELECT NVL(SUM(TOTAL), 0) INTO l_total FROM VENTAS_DETALLES WHERE ID_VENTA = l_id_venta;
    SELECT NVL(SUM(MONTO), 0) INTO l_cobrado FROM VENTAS_COBROS WHERE ID_VENTA = l_id_venta;
    l_saldo := l_total - l_cobrado;
    IF l_saldo <= 0 THEN
      ROLLBACK; p_status_code := 409; p_resultado := '{"error":"La venta ya esta cobrada por completo"}'; RETURN;
    END IF;
    IF l_monto > l_saldo THEN
      ROLLBACK; p_status_code := 409; p_resultado := '{"error":"El monto supera el saldo pendiente de la venta"}'; RETURN;
    END IF;
    -- Imputar a una cuota exige que sea de ESTA venta y que le quede saldo:
    -- sin esto se podia pagar dos veces la misma cuota, o una cuota ajena.
    IF l_id_cuota IS NOT NULL THEN
      BEGIN
        SELECT SALDO_PENDIENTE INTO l_saldo_cuota
          FROM VENTAS_CUOTAS
         WHERE ID_CUOTA = l_id_cuota AND ID_VENTA = l_id_venta
           FOR UPDATE;
      EXCEPTION WHEN NO_DATA_FOUND THEN
        ROLLBACK; p_status_code := 404; p_resultado := '{"error":"La cuota no existe o no pertenece a esta venta"}'; RETURN;
      END;
      IF l_saldo_cuota <= 0 THEN
        ROLLBACK; p_status_code := 409; p_resultado := '{"error":"La cuota ya esta pagada"}'; RETURN;
      END IF;
      IF l_monto > l_saldo_cuota THEN
        ROLLBACK; p_status_code := 409; p_resultado := '{"error":"El monto supera el saldo pendiente de la cuota"}'; RETURN;
      END IF;
    END IF;
    INSERT INTO VENTAS_COBROS (ID_VENTA, ID_CUOTA, ID_CANAL_PAGO, ID_MONEDA, ID_CUENTA_BANCARIA, MONTO, FECHA_COBRO, REFERENCIA, OBSERVACION)
      VALUES (l_id_venta, l_id_cuota, l_canal, l_moneda, l_cuenta, l_monto, NVL(l_fecha, SYSTIMESTAMP), NULLIF(TRIM(p_referencia), ''), NULLIF(TRIM(p_observacion), ''))
      RETURNING ID_COBRO INTO l_id;
    -- Actualiza saldo y estado de la cuota cuando se indica una cuota especifica
    IF l_id_cuota IS NOT NULL THEN
      UPDATE VENTAS_CUOTAS
         SET MONTO_PAGADO        = MONTO_PAGADO + l_monto,
             ESTADO              = CASE WHEN MONTO_PAGADO + l_monto >= MONTO_CUOTA THEN 'PAGADO' ELSE ESTADO END,
             FECHA_ACTUALIZACION = SYSTIMESTAMP
       WHERE ID_CUOTA = l_id_cuota AND ID_VENTA = l_id_venta;
    END IF;
    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN OTHERS THEN ROLLBACK; p_status_code := 500; APEX_DEBUG.ERROR('PKG_VENTAS_COBROS.INSERTAR: ' || SQLERRM); p_resultado := '{"error":"Error al registrar el cobro"}';
  END INSERTAR;

  -- Borra un cobro y DEVUELVE EL SALDO A LA VENTA.
  --
  -- El saldo de la venta se deriva de la suma de cobros, asi que borrar la fila
  -- ya lo devuelve solo. Lo que NO se arregla solo es la cuota: MONTO_PAGADO es
  -- una columna real y hay que restarle el cobro a mano, o la cuota queda
  -- figurando como pagada sin ningun cobro que la respalde.
  --
  -- El ESTADO vuelve a 'PENDIENTE' si al restar deja de estar cubierta. No se
  -- pone 'PENDIENTE' siempre: borrar uno de varios cobros de una cuota que
  -- sigue saldada tiene que dejarla en 'PAGADO'.
  PROCEDURE ELIMINAR (p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion     NUMBER;
    l_id         NUMBER;
    l_id_empresa NUMBER;
    l_id_venta   NUMBER;
    l_id_cuota   NUMBER;
    l_monto      NUMBER;
  BEGIN
    l_sesion     := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_id         := TO_NUMBER(NULLIF(p_id, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_id IS NULL OR l_id_empresa IS NULL THEN p_status_code := 400; p_resultado := '{"error":"id e idEmpresa son obligatorios"}'; RETURN; END IF;
    -- El EXISTS sobre la cabecera es el aislamiento por empresa: sin el, un
    -- token de otra empresa podria borrar cobros con solo acertar el id.
    BEGIN
      SELECT c.ID_VENTA, c.ID_CUOTA, c.MONTO INTO l_id_venta, l_id_cuota, l_monto
        FROM VENTAS_COBROS c
       WHERE c.ID_COBRO = l_id
         AND EXISTS (SELECT 1 FROM VENTAS_CABECERAS v WHERE v.ID_VENTA = c.ID_VENTA AND v.ID_EMPRESA = l_id_empresa)
         FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      ROLLBACK; p_status_code := 404; p_resultado := '{"error":"El cobro no existe"}'; RETURN;
    END;
    DELETE FROM VENTAS_COBROS WHERE ID_COBRO = l_id;
    IF l_id_cuota IS NOT NULL THEN
      UPDATE VENTAS_CUOTAS
         SET MONTO_PAGADO        = GREATEST(MONTO_PAGADO - l_monto, 0),
             ESTADO              = CASE WHEN GREATEST(MONTO_PAGADO - l_monto, 0) >= MONTO_CUOTA THEN 'PAGADO' ELSE 'PENDIENTE' END,
             FECHA_ACTUALIZACION = SYSTIMESTAMP
       WHERE ID_CUOTA = l_id_cuota AND ID_VENTA = l_id_venta;
    END IF;
    COMMIT;
    p_status_code := 200;
    p_resultado := JSON_OBJECT('ok' VALUE 'true' FORMAT JSON, 'idVenta' VALUE l_id_venta);
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK; p_status_code := 500; APEX_DEBUG.ERROR('PKG_VENTAS_COBROS.ELIMINAR: ' || SQLERRM); p_resultado := '{"error":"Error al eliminar el cobro"}';
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;
    ORDS.DEFINE_MODULE(p_module_name => 'ventas-cobros', p_base_path => '/ventas-cobros/', p_items_per_page => 0, p_status => 'PUBLISHED', p_comments => 'Cobros de ventas');
    ORDS.SET_MODULE_ORIGINS_ALLOWED(p_module_name => 'ventas-cobros', p_origins_allowed => 'https://www.ctell.online,http://localhost:8080');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas-cobros', p_pattern => 'listar/:idVenta/:idEmpresa');
    ORDS.DEFINE_HANDLER(p_module_name => 'ventas-cobros', p_pattern => 'listar/:idVenta/:idEmpresa', p_method => 'GET', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_VENTAS_COBROS.LISTAR(:authorization, :idVenta, :idEmpresa, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'listar/:idVenta/:idEmpresa', p_method => 'GET', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'listar/:idVenta/:idEmpresa', p_method => 'GET', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'listar/:idVenta/:idEmpresa', p_method => 'GET', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas-cobros', p_pattern => 'crear');
    ORDS.DEFINE_HANDLER(p_module_name => 'ventas-cobros', p_pattern => 'crear', p_method => 'POST', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_VENTAS_COBROS.INSERTAR(:authorization, :idVenta, :idCuota, :idEmpresa, :idCanalPago, :idMoneda, :idCuentaBancaria, :monto, :fechaCobro, :referencia, :observacion, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'crear', p_method => 'POST', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'crear', p_method => 'POST', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'crear', p_method => 'POST', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas-cobros', p_pattern => 'eliminar/:id/:idEmpresa');
    ORDS.DEFINE_HANDLER(p_module_name => 'ventas-cobros', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_VENTAS_COBROS.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas-cobros', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');
    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_VENTAS_COBROS;
/
BEGIN PKG_VENTAS_COBROS.PUBLICAR_ENDPOINTS; END;
/
