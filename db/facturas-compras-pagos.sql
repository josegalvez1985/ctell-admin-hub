--------------------------------------------------------------------------------
-- CTELL · PAGOS A PROVEEDORES
-- Registra pagos contra facturas de compra. Cuando se indica la cuota, actualiza
-- MONTO_PAGADO y ESTADO en FACTURAS_COMPRAS_CUOTAS.
-- Requiere PKG_AUTH, FACTURAS_COMPRAS_CAB, FACTURAS_COMPRAS_DET,
-- FACTURAS_COMPRAS_CUOTAS, CANALES_PAGOS, CUENTAS_BANCARIAS, BANCOS y MONEDAS.
--
-- Es el espejo de db/ventas-cobros.sql: mismo criterio, dinero saliendo en vez
-- de entrando. Si cambia uno, mirar el otro.
--
-- NO SE PAGA MAS QUE EL SALDO. El saldo es la SUMA DEL DETALLE menos la suma de
-- los pagos: ninguno de los dos se guarda en la cabecera. Se lee con la cabecera
-- bloqueada (FOR UPDATE) para que dos usuarios pagando a la vez no vean ambos
-- saldo suficiente y terminen sobre-pagando la misma factura.
-- Se rechaza: una factura ya saldada (409), un monto mayor al saldo (409), una
-- cuota de otra factura (404) y una cuota ya pagada (409).
--
-- EL ESTADO DE LA CUOTA usa los valores del CHECK del DDL —PENDIENTE, PARCIAL,
-- PAGADA, VENCIDA—, que NO son los mismos que en ventas ('PAGADO' masculino).
-- Ojo al copiar entre los dos archivos.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_FACTURAS_COMPRAS_PAGOS AS
  PROCEDURE LISTAR (p_authorization IN VARCHAR2, p_id_factura IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE INSERTAR (
    p_authorization IN VARCHAR2,
    p_id_factura IN VARCHAR2, p_id_cuota IN VARCHAR2, p_id_empresa IN VARCHAR2,
    p_id_canal_pago IN VARCHAR2, p_id_moneda IN VARCHAR2, p_id_cuenta_bancaria IN VARCHAR2,
    p_monto IN VARCHAR2, p_fecha_pago IN VARCHAR2, p_referencia IN VARCHAR2, p_observacion IN VARCHAR2,
    p_status_code OUT NUMBER, p_resultado OUT CLOB
  );
  PROCEDURE ELIMINAR (p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE PUBLICAR_ENDPOINTS;
END PKG_FACTURAS_COMPRAS_PAGOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_FACTURAS_COMPRAS_PAGOS AS

  PROCEDURE BORRAR_MODULO IS l_existe PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. 3 LOOP
      BEGIN
        SELECT COUNT(*) INTO l_existe FROM USER_ORDS_MODULES WHERE NAME = 'compras-pagos';
        IF l_existe = 0 THEN RETURN; END IF;
        ORDS.DELETE_MODULE(p_module_name => 'compras-pagos'); COMMIT; RETURN;
      EXCEPTION WHEN OTHERS THEN
        IF SQLCODE IN (-60, -4020) AND i < 3 THEN ROLLBACK; DBMS_SESSION.SLEEP(2); ELSE RAISE; END IF;
      END;
    END LOOP;
  END BORRAR_MODULO;

  -- Privado: el estado que le corresponde a una cuota segun lo que lleva pagado.
  -- Centralizado para que el alta y la baja de un pago no se contradigan.
  --
  -- OJO AL USARLA: una funcion privada del BODY no se puede llamar desde una
  -- sentencia SQL —da PLS-00231, solo valen las declaradas en el spec—. Por eso
  -- el resultado se calcula en una variable PL/SQL y en el UPDATE va la
  -- variable, no la llamada. Declararla en el spec tambien funcionaria, pero
  -- publicaria un detalle interno en la interfaz del paquete.
  FUNCTION ESTADO_CUOTA (p_pagado IN NUMBER, p_cuota IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF p_pagado >= p_cuota THEN RETURN 'PAGADA';
    ELSIF p_pagado > 0    THEN RETURN 'PARCIAL';
    ELSE                       RETURN 'PENDIENTE';
    END IF;
  END ESTADO_CUOTA;

  PROCEDURE LISTAR (p_authorization IN VARCHAR2, p_id_factura IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion NUMBER; l_id_factura NUMBER; l_id_empresa NUMBER; l_items CLOB;
  BEGIN
    l_sesion     := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_id_factura := TO_NUMBER(NULLIF(p_id_factura, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_id_factura IS NULL OR l_id_empresa IS NULL THEN p_status_code := 400; p_resultado := '{"error":"idFactura e idEmpresa son obligatorios"}'; RETURN; END IF;
    SELECT JSON_ARRAYAGG(
      JSON_OBJECT(
        'id'               VALUE p.ID_PAGO,
        'idFactura'        VALUE p.ID_FACTURA,
        'idCuota'          VALUE p.ID_CUOTA,
        'nroCuota'         VALUE q.NRO_CUOTA,
        'idCanalPago'      VALUE p.ID_CANAL_PAGO,
        'canalPago'        VALUE cp.NOMBRE_CANAL,
        'idMoneda'         VALUE p.ID_MONEDA,
        'idCuentaBancaria' VALUE p.ID_CUENTA_BANCARIA,
        'banco'            VALUE b.NOMBRE_BANCO,
        'numeroCuenta'     VALUE cb.NUMERO_CUENTA,
        'monto'            VALUE p.MONTO,
        'fechaPago'        VALUE TO_CHAR(p.FECHA_PAGO, 'YYYY-MM-DD"T"HH24:MI:SS'),
        'referencia'       VALUE p.REFERENCIA,
        'observacion'      VALUE p.OBSERVACION
        RETURNING CLOB
      ) ORDER BY p.FECHA_PAGO DESC RETURNING CLOB
    ) INTO l_items
    FROM FACTURAS_COMPRAS_PAGOS p
    -- TODOS los JOIN son LEFT a proposito. Un pago EXISTIO: si despues borran el
    -- canal, la cuenta o el banco, tiene que seguir apareciendo en el historial.
    -- Con JOIN interno el pago desaparecia sin ningun error y la factura
    -- mostraba menos pagado de lo que realmente se pago.
    LEFT JOIN CANALES_PAGOS           cp ON cp.ID_CANAL_PAGO      = p.ID_CANAL_PAGO
    LEFT JOIN CUENTAS_BANCARIAS       cb ON cb.ID_CUENTA_BANCARIA = p.ID_CUENTA_BANCARIA
    LEFT JOIN BANCOS                  b  ON b.ID_BANCO            = cb.ID_BANCO
    LEFT JOIN FACTURAS_COMPRAS_CUOTAS q  ON q.ID_CUOTA            = p.ID_CUOTA
    WHERE p.ID_FACTURA = l_id_factura
      AND EXISTS (SELECT 1 FROM FACTURAS_COMPRAS_CAB f WHERE f.ID_FACTURA = p.ID_FACTURA AND f.ID_EMPRESA = l_id_empresa);
    p_status_code := 200;
    SELECT JSON_OBJECT('items' VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON RETURNING CLOB) INTO p_resultado FROM DUAL;
  EXCEPTION WHEN OTHERS THEN
    p_status_code := 500; APEX_DEBUG.ERROR('PKG_FACTURAS_COMPRAS_PAGOS.LISTAR: ' || SQLERRM); p_resultado := '{"error":"Error al listar los pagos"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization IN VARCHAR2,
    p_id_factura IN VARCHAR2, p_id_cuota IN VARCHAR2, p_id_empresa IN VARCHAR2,
    p_id_canal_pago IN VARCHAR2, p_id_moneda IN VARCHAR2, p_id_cuenta_bancaria IN VARCHAR2,
    p_monto IN VARCHAR2, p_fecha_pago IN VARCHAR2, p_referencia IN VARCHAR2, p_observacion IN VARCHAR2,
    p_status_code OUT NUMBER, p_resultado OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id_factura  NUMBER;
    l_id_cuota    NUMBER;
    l_id_empresa  NUMBER;
    l_canal       NUMBER;
    l_moneda      NUMBER;
    l_cuenta      NUMBER;
    l_monto       NUMBER;
    l_fecha       TIMESTAMP;
    l_id          NUMBER;
    l_existe      NUMBER;
    l_total       NUMBER;
    l_pagado      NUMBER;
    l_saldo       NUMBER;
    l_saldo_cuota NUMBER;
    l_monto_cuota NUMBER;
    l_pagado_cuota NUMBER;
    l_nuevo_pagado NUMBER;
    l_estado      VARCHAR2(20);
  BEGIN
    l_sesion     := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_id_factura := TO_NUMBER(NULLIF(p_id_factura, ''));
    l_id_cuota   := TO_NUMBER(NULLIF(p_id_cuota, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_canal      := TO_NUMBER(NULLIF(p_id_canal_pago, ''));
    l_moneda     := TO_NUMBER(NULLIF(p_id_moneda, ''));
    l_cuenta     := TO_NUMBER(NULLIF(p_id_cuenta_bancaria, ''));
    l_monto      := TO_NUMBER(NULLIF(p_monto, ''));
    l_fecha      := TO_TIMESTAMP(NULLIF(p_fecha_pago, ''), 'YYYY-MM-DD"T"HH24:MI:SS');
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_id_factura IS NULL OR l_id_empresa IS NULL OR l_canal IS NULL OR l_moneda IS NULL OR l_monto IS NULL OR l_monto <= 0 THEN
      p_status_code := 400; p_resultado := '{"error":"Faltan datos obligatorios del pago"}'; RETURN;
    END IF;
    -- FOR UPDATE, no un COUNT suelto: entre leer el saldo y grabar el pago, otro
    -- usuario podria pagar la misma factura y los dos verian saldo suficiente.
    BEGIN
      SELECT ID_FACTURA INTO l_existe
        FROM FACTURAS_COMPRAS_CAB
       WHERE ID_FACTURA = l_id_factura AND ID_EMPRESA = l_id_empresa
         FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      ROLLBACK; p_status_code := 404; p_resultado := '{"error":"La factura no existe"}'; RETURN;
    END;
    SELECT NVL(SUM(SUBTOTAL), 0) INTO l_total  FROM FACTURAS_COMPRAS_DET   WHERE ID_FACTURA = l_id_factura;
    SELECT NVL(SUM(MONTO), 0)    INTO l_pagado FROM FACTURAS_COMPRAS_PAGOS WHERE ID_FACTURA = l_id_factura;
    l_saldo := l_total - l_pagado;
    IF l_saldo <= 0 THEN
      ROLLBACK; p_status_code := 409; p_resultado := '{"error":"La factura ya esta pagada por completo"}'; RETURN;
    END IF;
    IF l_monto > l_saldo THEN
      ROLLBACK; p_status_code := 409; p_resultado := '{"error":"El monto supera el saldo pendiente de la factura"}'; RETURN;
    END IF;
    -- Imputar a una cuota exige que sea de ESTA factura y que le quede saldo. El
    -- DDL ademas tiene un CHECK (MONTO_PAGADO <= MONTO_CUOTA): sin esta guarda,
    -- pasarse daria ORA-02290 y llegaria al usuario como un 500 sin explicacion.
    IF l_id_cuota IS NOT NULL THEN
      BEGIN
        SELECT MONTO_CUOTA, MONTO_PAGADO, SALDO_PENDIENTE
          INTO l_monto_cuota, l_pagado_cuota, l_saldo_cuota
          FROM FACTURAS_COMPRAS_CUOTAS
         WHERE ID_CUOTA = l_id_cuota AND ID_FACTURA = l_id_factura
           FOR UPDATE;
      EXCEPTION WHEN NO_DATA_FOUND THEN
        ROLLBACK; p_status_code := 404; p_resultado := '{"error":"La cuota no existe o no pertenece a esta factura"}'; RETURN;
      END;
      IF l_saldo_cuota <= 0 THEN
        ROLLBACK; p_status_code := 409; p_resultado := '{"error":"La cuota ya esta pagada"}'; RETURN;
      END IF;
      IF l_monto > l_saldo_cuota THEN
        ROLLBACK; p_status_code := 409; p_resultado := '{"error":"El monto supera el saldo pendiente de la cuota"}'; RETURN;
      END IF;
    END IF;
    INSERT INTO FACTURAS_COMPRAS_PAGOS (ID_FACTURA, ID_CUOTA, ID_CANAL_PAGO, ID_MONEDA, ID_CUENTA_BANCARIA, MONTO, FECHA_PAGO, REFERENCIA, OBSERVACION)
      VALUES (l_id_factura, l_id_cuota, l_canal, l_moneda, l_cuenta, l_monto, NVL(l_fecha, SYSTIMESTAMP), NULLIF(TRIM(p_referencia), ''), NULLIF(TRIM(p_observacion), ''))
      RETURNING ID_PAGO INTO l_id;
    IF l_id_cuota IS NOT NULL THEN
      l_nuevo_pagado := l_pagado_cuota + l_monto;
      l_estado       := ESTADO_CUOTA(l_nuevo_pagado, l_monto_cuota);
      UPDATE FACTURAS_COMPRAS_CUOTAS
         SET MONTO_PAGADO        = l_nuevo_pagado,
             ESTADO              = l_estado,
             FECHA_ACTUALIZACION = SYSTIMESTAMP
       WHERE ID_CUOTA = l_id_cuota AND ID_FACTURA = l_id_factura;
    END IF;
    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK; p_status_code := 500; APEX_DEBUG.ERROR('PKG_FACTURAS_COMPRAS_PAGOS.INSERTAR: ' || SQLERRM); p_resultado := '{"error":"Error al registrar el pago"}';
  END INSERTAR;

  -- Borra un pago y DEVUELVE EL SALDO A LA FACTURA.
  --
  -- El saldo se deriva de la suma de pagos, asi que borrar la fila ya lo
  -- devuelve solo. Lo que NO se arregla solo es la cuota: MONTO_PAGADO es una
  -- columna real y hay que restarle el pago a mano, o la cuota queda figurando
  -- como pagada sin ningun pago que la respalde.
  PROCEDURE ELIMINAR (p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion     NUMBER;
    l_id         NUMBER;
    l_id_empresa NUMBER;
    l_id_factura NUMBER;
    l_id_cuota   NUMBER;
    l_monto      NUMBER;
    l_nuevo      NUMBER;
    l_monto_cuota NUMBER;
    l_estado     VARCHAR2(20);
  BEGIN
    l_sesion     := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_id         := TO_NUMBER(NULLIF(p_id, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_id IS NULL OR l_id_empresa IS NULL THEN p_status_code := 400; p_resultado := '{"error":"id e idEmpresa son obligatorios"}'; RETURN; END IF;
    -- El EXISTS sobre la cabecera es el aislamiento por empresa: sin el, un token
    -- de otra empresa podria borrar pagos con solo acertar el id.
    BEGIN
      SELECT p.ID_FACTURA, p.ID_CUOTA, p.MONTO INTO l_id_factura, l_id_cuota, l_monto
        FROM FACTURAS_COMPRAS_PAGOS p
       WHERE p.ID_PAGO = l_id
         AND EXISTS (SELECT 1 FROM FACTURAS_COMPRAS_CAB f WHERE f.ID_FACTURA = p.ID_FACTURA AND f.ID_EMPRESA = l_id_empresa)
         FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      ROLLBACK; p_status_code := 404; p_resultado := '{"error":"El pago no existe"}'; RETURN;
    END;
    DELETE FROM FACTURAS_COMPRAS_PAGOS WHERE ID_PAGO = l_id;
    IF l_id_cuota IS NOT NULL THEN
      SELECT MONTO_CUOTA, GREATEST(MONTO_PAGADO - l_monto, 0)
        INTO l_monto_cuota, l_nuevo
        FROM FACTURAS_COMPRAS_CUOTAS WHERE ID_CUOTA = l_id_cuota FOR UPDATE;
      l_estado := ESTADO_CUOTA(l_nuevo, l_monto_cuota);
      UPDATE FACTURAS_COMPRAS_CUOTAS
         SET MONTO_PAGADO        = l_nuevo,
             ESTADO              = l_estado,
             FECHA_ACTUALIZACION = SYSTIMESTAMP
       WHERE ID_CUOTA = l_id_cuota AND ID_FACTURA = l_id_factura;
    END IF;
    COMMIT;
    p_status_code := 200;
    p_resultado := JSON_OBJECT('ok' VALUE 'true' FORMAT JSON, 'idFactura' VALUE l_id_factura);
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK; p_status_code := 500; APEX_DEBUG.ERROR('PKG_FACTURAS_COMPRAS_PAGOS.ELIMINAR: ' || SQLERRM); p_resultado := '{"error":"Error al eliminar el pago"}';
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;
    ORDS.DEFINE_MODULE(p_module_name => 'compras-pagos', p_base_path => '/compras-pagos/', p_items_per_page => 0, p_status => 'PUBLISHED', p_comments => 'Pagos a proveedores');
    ORDS.SET_MODULE_ORIGINS_ALLOWED(p_module_name => 'compras-pagos', p_origins_allowed => 'https://www.ctell.online,http://localhost:8080');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'compras-pagos', p_pattern => 'listar/:idFactura/:idEmpresa');
    ORDS.DEFINE_HANDLER(p_module_name => 'compras-pagos', p_pattern => 'listar/:idFactura/:idEmpresa', p_method => 'GET', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_FACTURAS_COMPRAS_PAGOS.LISTAR(:authorization, :idFactura, :idEmpresa, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'compras-pagos', p_pattern => 'listar/:idFactura/:idEmpresa', p_method => 'GET', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'compras-pagos', p_pattern => 'listar/:idFactura/:idEmpresa', p_method => 'GET', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'compras-pagos', p_pattern => 'listar/:idFactura/:idEmpresa', p_method => 'GET', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'compras-pagos', p_pattern => 'crear');
    ORDS.DEFINE_HANDLER(p_module_name => 'compras-pagos', p_pattern => 'crear', p_method => 'POST', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_FACTURAS_COMPRAS_PAGOS.INSERTAR(:authorization, :idFactura, :idCuota, :idEmpresa, :idCanalPago, :idMoneda, :idCuentaBancaria, :monto, :fechaPago, :referencia, :observacion, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'compras-pagos', p_pattern => 'crear', p_method => 'POST', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'compras-pagos', p_pattern => 'crear', p_method => 'POST', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'compras-pagos', p_pattern => 'crear', p_method => 'POST', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'compras-pagos', p_pattern => 'eliminar/:id/:idEmpresa');
    ORDS.DEFINE_HANDLER(p_module_name => 'compras-pagos', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_FACTURAS_COMPRAS_PAGOS.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'compras-pagos', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'compras-pagos', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'compras-pagos', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');
    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_FACTURAS_COMPRAS_PAGOS;
/
BEGIN PKG_FACTURAS_COMPRAS_PAGOS.PUBLICAR_ENDPOINTS; END;
/

--------------------------------------------------------------------------------
-- Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS FROM USER_OBJECTS WHERE OBJECT_NAME = 'PKG_FACTURAS_COMPRAS_PAGOS' ORDER BY OBJECT_TYPE;

SELECT NAME, LINE, POSITION, TEXT FROM USER_ERRORS WHERE NAME = 'PKG_FACTURAS_COMPRAS_PAGOS' ORDER BY SEQUENCE;

-- Ninguna factura puede estar pagada de mas. Cero filas es lo correcto.
SELECT f.ID_FACTURA, f.NUMERO_FACTURA,
       (SELECT NVL(SUM(SUBTOTAL), 0) FROM FACTURAS_COMPRAS_DET   d WHERE d.ID_FACTURA = f.ID_FACTURA) AS TOTAL,
       (SELECT NVL(SUM(MONTO), 0)    FROM FACTURAS_COMPRAS_PAGOS p WHERE p.ID_FACTURA = f.ID_FACTURA) AS PAGADO
  FROM FACTURAS_COMPRAS_CAB f
 WHERE (SELECT NVL(SUM(MONTO), 0) FROM FACTURAS_COMPRAS_PAGOS p WHERE p.ID_FACTURA = f.ID_FACTURA)
     > (SELECT NVL(SUM(SUBTOTAL), 0) FROM FACTURAS_COMPRAS_DET d WHERE d.ID_FACTURA = f.ID_FACTURA);

-- El MONTO_PAGADO de cada cuota tiene que coincidir con sus pagos imputados.
SELECT q.ID_CUOTA, q.ID_FACTURA, q.NRO_CUOTA, q.MONTO_PAGADO,
       NVL((SELECT SUM(MONTO) FROM FACTURAS_COMPRAS_PAGOS p WHERE p.ID_CUOTA = q.ID_CUOTA), 0) AS SUMA_PAGOS
  FROM FACTURAS_COMPRAS_CUOTAS q
 WHERE q.MONTO_PAGADO != NVL((SELECT SUM(MONTO) FROM FACTURAS_COMPRAS_PAGOS p WHERE p.ID_CUOTA = q.ID_CUOTA), 0);

SELECT NAME, STATUS, ORIGINS_ALLOWED FROM USER_ORDS_MODULES WHERE NAME = 'compras-pagos';
