--------------------------------------------------------------------------------
-- CTELL · PUNTO DE VENTA
-- Maneja VENTAS_CABECERAS, VENTAS_DETALLES y VENTAS_CUOTAS en una transaccion.
-- Requiere PKG_AUTH, ARTICULOS, LOTES, PERSONAS, LISTAS_DESCUENTOS,
-- CONDICIONES_PAGO, MONEDAS, EMPRESAS y SUCURSALES.
-- Precio manual por linea. Los precios incluyen IVA, igual que compras.
-- Cuotas: 30/60/90 dias significa vencimientos acumulados: 30, 60, 90.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_VENTAS AS
  PROCEDURE LISTAR (p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_sucursal IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE OBTENER (p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE INSERTAR (
    p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_sucursal IN VARCHAR2,
    p_id_usuario IN VARCHAR2, p_id_cliente IN VARCHAR2, p_id_lista_descuentos IN VARCHAR2,
    p_id_condicion_pago IN VARCHAR2, p_id_moneda IN VARCHAR2,
    p_fecha_venta IN VARCHAR2, p_observacion IN VARCHAR2, p_id_talonario IN VARCHAR2, p_detalle IN CLOB,
    p_status_code OUT NUMBER, p_resultado OUT CLOB
  );
  PROCEDURE ELIMINAR (p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE PUBLICAR_ENDPOINTS;
END PKG_VENTAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_VENTAS AS
  PROCEDURE BORRAR_MODULO IS l_existe PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. 3 LOOP
      BEGIN
        SELECT COUNT(*) INTO l_existe FROM USER_ORDS_MODULES WHERE NAME = 'ventas';
        IF l_existe = 0 THEN RETURN; END IF;
        ORDS.DELETE_MODULE(p_module_name => 'ventas'); COMMIT; RETURN;
      EXCEPTION WHEN OTHERS THEN
        IF SQLCODE IN (-60, -4020) AND i < 3 THEN ROLLBACK; DBMS_SESSION.SLEEP(2); ELSE RAISE; END IF;
      END;
    END LOOP;
  END BORRAR_MODULO;

  PROCEDURE LISTAR (p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_sucursal IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion NUMBER; l_empresa NUMBER; l_sucursal NUMBER; l_items CLOB; l_total NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, '')); l_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_empresa IS NULL OR l_sucursal IS NULL THEN p_status_code := 400; p_resultado := '{"error":"idEmpresa e idSucursal son obligatorios"}'; RETURN; END IF;
    SELECT COUNT(*) INTO l_total FROM VENTAS_CABECERAS WHERE ID_EMPRESA = l_empresa AND ID_SUCURSAL = l_sucursal;
    SELECT JSON_ARRAYAGG(fila ORDER BY fecha_venta DESC RETURNING CLOB) INTO l_items FROM (
      SELECT JSON_OBJECT('id' VALUE v.ID_VENTA, 'idEmpresa' VALUE v.ID_EMPRESA, 'idSucursal' VALUE v.ID_SUCURSAL,
        'idCliente' VALUE v.ID_CLIENTE, 'cliente' VALUE CASE WHEN p.ID_PERSONA IS NULL THEN NULL ELSE p.NOMBRE || NVL2(p.APELLIDO, ' ' || p.APELLIDO, '') END,
        'numeroVenta' VALUE v.NUMERO_VENTA, 'fechaVenta' VALUE TO_CHAR(v.FECHA_VENTA, 'YYYY-MM-DD"T"HH24:MI:SS'),
        'tipoComprobante' VALUE v.TIPO_COMPROBANTE, 'idTalonario' VALUE v.ID_TALONARIO, 'nroTimbrado' VALUE v.NRO_TIMBRADO,
        'establecimiento' VALUE v.ESTABLECIMIENTO, 'puntoExpedicion' VALUE v.PUNTO_EXPEDICION, 'nroComprobante' VALUE v.NRO_COMPROBANTE,
        'idMoneda' VALUE v.ID_MONEDA, 'montoSubtotal' VALUE v.MONTO_SUBTOTAL, 'montoDescuento' VALUE v.MONTO_DESCUENTO,
        'montoIva' VALUE v.MONTO_IVA, 'montoTotal' VALUE v.MONTO_TOTAL, 'observacion' VALUE v.OBSERVACION,
        'lineas' VALUE (SELECT COUNT(*) FROM VENTAS_DETALLES d WHERE d.ID_VENTA = v.ID_VENTA)
        RETURNING CLOB) AS fila, v.FECHA_VENTA fecha_venta
      FROM VENTAS_CABECERAS v LEFT JOIN PERSONAS p ON p.ID_PERSONA = v.ID_CLIENTE
      WHERE v.ID_EMPRESA = l_empresa AND v.ID_SUCURSAL = l_sucursal
    );
    p_status_code := 200;
    SELECT JSON_OBJECT('items' VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON, 'total' VALUE l_total RETURNING CLOB) INTO p_resultado FROM DUAL;
  EXCEPTION WHEN OTHERS THEN p_status_code := 500; APEX_DEBUG.ERROR('PKG_VENTAS.LISTAR: ' || SQLERRM); p_resultado := '{"error":"Error al listar las ventas"}';
  END LISTAR;

  PROCEDURE OBTENER (p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion NUMBER; l_id NUMBER; l_empresa NUMBER; l_cab CLOB; l_det CLOB; l_cuotas CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization)); l_id := TO_NUMBER(NULLIF(p_id, '')); l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    SELECT JSON_OBJECT('id' VALUE v.ID_VENTA, 'idEmpresa' VALUE v.ID_EMPRESA, 'idSucursal' VALUE v.ID_SUCURSAL,
      'idCliente' VALUE v.ID_CLIENTE, 'idListaDescuentos' VALUE v.ID_LISTA_DESCUENTOS, 'idCondicionPago' VALUE v.ID_CONDICION_PAGO,
      'idMoneda' VALUE v.ID_MONEDA, 'numeroVenta' VALUE v.NUMERO_VENTA, 'fechaVenta' VALUE TO_CHAR(v.FECHA_VENTA, 'YYYY-MM-DD"T"HH24:MI:SS'),
      'tipoComprobante' VALUE v.TIPO_COMPROBANTE, 'idTalonario' VALUE v.ID_TALONARIO, 'nroTimbrado' VALUE v.NRO_TIMBRADO,
      'establecimiento' VALUE v.ESTABLECIMIENTO, 'puntoExpedicion' VALUE v.PUNTO_EXPEDICION, 'nroComprobante' VALUE v.NRO_COMPROBANTE,
      'montoSubtotal' VALUE v.MONTO_SUBTOTAL, 'montoDescuento' VALUE v.MONTO_DESCUENTO, 'montoIva' VALUE v.MONTO_IVA,
      'montoTotal' VALUE v.MONTO_TOTAL, 'observacion' VALUE v.OBSERVACION RETURNING CLOB)
      INTO l_cab FROM VENTAS_CABECERAS v WHERE v.ID_VENTA = l_id AND v.ID_EMPRESA = l_empresa;
    SELECT JSON_ARRAYAGG(JSON_OBJECT('id' VALUE d.ID_DETALLE, 'idArticulo' VALUE d.ID_ARTICULO, 'idIva' VALUE d.ID_IVA,
      'cantidad' VALUE d.CANTIDAD, 'precioUnitario' VALUE d.PRECIO_UNITARIO, 'subtotal' VALUE d.SUBTOTAL,
      'porcentajeDescuento' VALUE d.PORCENTAJE_DESCUENTO, 'montoDescuento' VALUE d.MONTO_DESCUENTO, 'montoIva' VALUE d.MONTO_IVA, 'total' VALUE d.TOTAL RETURNING CLOB) RETURNING CLOB)
      INTO l_det FROM VENTAS_DETALLES d WHERE d.ID_VENTA = l_id;
    SELECT JSON_ARRAYAGG(JSON_OBJECT('id' VALUE q.ID_CUOTA, 'nroCuota' VALUE q.NRO_CUOTA, 'fechaVencimiento' VALUE TO_CHAR(q.FECHA_VENCIMIENTO, 'YYYY-MM-DD'),
      'montoCuota' VALUE q.MONTO_CUOTA, 'montoPagado' VALUE q.MONTO_PAGADO, 'saldoPendiente' VALUE q.SALDO_PENDIENTE, 'estado' VALUE q.ESTADO RETURNING CLOB) ORDER BY q.NRO_CUOTA RETURNING CLOB)
      INTO l_cuotas FROM VENTAS_CUOTAS q WHERE q.ID_VENTA = l_id;
    p_status_code := 200;
    SELECT JSON_OBJECT('cabecera' VALUE l_cab FORMAT JSON, 'detalle' VALUE NVL(l_det, TO_CLOB('[]')) FORMAT JSON, 'cuotas' VALUE NVL(l_cuotas, TO_CLOB('[]')) FORMAT JSON RETURNING CLOB) INTO p_resultado FROM DUAL;
  EXCEPTION WHEN NO_DATA_FOUND THEN p_status_code := 404; p_resultado := '{"error":"La venta no existe"}';
  WHEN OTHERS THEN p_status_code := 500; APEX_DEBUG.ERROR('PKG_VENTAS.OBTENER: ' || SQLERRM); p_resultado := '{"error":"Error al obtener la venta"}';
  END OBTENER;

  PROCEDURE INSERTAR (
    p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_sucursal IN VARCHAR2, p_id_usuario IN VARCHAR2, p_id_cliente IN VARCHAR2,
    p_id_lista_descuentos IN VARCHAR2, p_id_condicion_pago IN VARCHAR2, p_id_moneda IN VARCHAR2,
    p_fecha_venta IN VARCHAR2, p_observacion IN VARCHAR2, p_id_talonario IN VARCHAR2, p_detalle IN CLOB, p_status_code OUT NUMBER, p_resultado OUT CLOB
  ) IS
    l_sesion NUMBER; l_empresa NUMBER; l_sucursal NUMBER; l_usuario NUMBER; l_cliente NUMBER; l_lista NUMBER; l_condicion NUMBER; l_moneda NUMBER; l_id NUMBER; l_lineas NUMBER := 0;
    l_fecha TIMESTAMP; l_descuento NUMBER := 0; l_subtotal NUMBER := 0; l_iva NUMBER := 0; l_total NUMBER := 0; l_porcentaje NUMBER := 0; l_dias NUMBER := 0; l_cuotas NUMBER := 1; l_stock NUMBER; l_cantidad NUMBER;
    l_talonario NUMBER; l_nro NUMBER; l_final_talonario NUMBER; l_tipo VARCHAR2(3); l_timbrado VARCHAR2(20); l_establecimiento VARCHAR2(3); l_punto VARCHAR2(3); l_numero VARCHAR2(50);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, '')); l_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, '')); l_usuario := TO_NUMBER(NULLIF(p_id_usuario, '')); l_cliente := TO_NUMBER(NULLIF(p_id_cliente, ''));
    l_lista := TO_NUMBER(NULLIF(p_id_lista_descuentos, '')); l_condicion := TO_NUMBER(NULLIF(p_id_condicion_pago, '')); l_moneda := TO_NUMBER(NULLIF(p_id_moneda, '')); l_talonario := TO_NUMBER(NULLIF(p_id_talonario, ''));
    l_fecha := TO_TIMESTAMP(NULLIF(p_fecha_venta, ''), 'YYYY-MM-DD"T"HH24:MI:SS');
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_empresa IS NULL OR l_sucursal IS NULL OR l_usuario IS NULL OR l_condicion IS NULL OR l_moneda IS NULL OR l_talonario IS NULL OR p_detalle IS NULL THEN
      p_status_code := 400; p_resultado := '{"error":"Faltan datos obligatorios de la venta"}'; RETURN;
    END IF;
    SELECT TIPO_COMPROBANTE, NRO_TIMBRADO, ESTABLECIMIENTO, PUNTO_EXPEDICION, NRO_ACTUAL, NRO_FINAL
      INTO l_tipo, l_timbrado, l_establecimiento, l_punto, l_nro, l_final_talonario
      FROM TALONARIOS
     WHERE ID_TALONARIO = l_talonario AND ID_EMPRESA = l_empresa AND ID_SUCURSAL = l_sucursal
       AND ACTIVO = 'A' AND (FECHA_INICIO IS NULL OR TRUNC(FECHA_INICIO) <= TRUNC(CAST(l_fecha AS DATE)))
       AND (FECHA_VENCIMIENTO IS NULL OR TRUNC(FECHA_VENCIMIENTO) >= TRUNC(CAST(l_fecha AS DATE)))
     FOR UPDATE;
    IF l_nro > l_final_talonario THEN RAISE_APPLICATION_ERROR(-20010, 'El talonario no tiene numeros disponibles'); END IF;
    l_numero := l_establecimiento || '-' || l_punto || '-' || LPAD(TO_CHAR(l_nro), 7, '0');
    IF l_lista IS NOT NULL THEN
      SELECT PORCENTAJE_DESCUENTO INTO l_porcentaje FROM LISTAS_DESCUENTOS WHERE ID_LISTA_PRECIOS = l_lista AND ID_EMPRESA = l_empresa AND FECHA_VIGENCIA_DESDE <= l_fecha AND (FECHA_VIGENCIA_HASTA IS NULL OR FECHA_VIGENCIA_HASTA >= l_fecha);
    END IF;
    SELECT NVL(DIAS_PAGO, 0), NVL(CANTIDAD_CUOTAS, 1) INTO l_dias, l_cuotas FROM CONDICIONES_PAGO WHERE ID_CONDICION = l_condicion;
    INSERT INTO VENTAS_CABECERAS (ID_EMPRESA, ID_SUCURSAL, ID_USUARIO, ID_CLIENTE, ID_LISTA_DESCUENTOS, ID_CONDICION_PAGO, ID_MONEDA, NUMERO_VENTA, FECHA_VENTA, MONTO_SUBTOTAL, MONTO_DESCUENTO, MONTO_IVA, MONTO_TOTAL, OBSERVACION, TIPO_COMPROBANTE, ID_TALONARIO, NRO_TIMBRADO, ESTABLECIMIENTO, PUNTO_EXPEDICION, NRO_COMPROBANTE)
      VALUES (l_empresa, l_sucursal, l_usuario, l_cliente, l_lista, l_condicion, l_moneda, l_numero, l_fecha, 0, 0, 0, 0, NULLIF(TRIM(p_observacion), ''), l_tipo, l_talonario, l_timbrado, l_establecimiento, l_punto, l_nro) RETURNING ID_VENTA INTO l_id;
    UPDATE TALONARIOS SET NRO_ACTUAL = CASE WHEN NRO_ACTUAL = NRO_FINAL THEN NRO_ACTUAL ELSE NRO_ACTUAL + 1 END, ACTIVO = CASE WHEN NRO_ACTUAL = NRO_FINAL THEN 'I' ELSE ACTIVO END, FECHA_ACTUALIZACION = SYSTIMESTAMP WHERE ID_TALONARIO = l_talonario;
    FOR linea IN (SELECT idArticulo, cantidad, precioUnitario, idIva FROM JSON_TABLE(p_detalle, '$[*]' COLUMNS (idArticulo NUMBER PATH '$.idArticulo', cantidad NUMBER PATH '$.cantidad', precioUnitario NUMBER PATH '$.precioUnitario', idIva NUMBER PATH '$.idIva'))) LOOP
      IF linea.idArticulo IS NULL OR linea.cantidad IS NULL OR linea.cantidad <= 0 OR linea.precioUnitario IS NULL OR linea.precioUnitario < 0 THEN RAISE VALUE_ERROR; END IF;
      l_cantidad := linea.cantidad;
      SELECT NVL(SUM(NVL(CANTIDAD_DISPON, CANTIDAD)), 0) INTO l_stock FROM LOTES WHERE ID_EMPRESA = l_empresa AND ID_SUCURSAL = l_sucursal AND ID_ARTICULO = linea.idArticulo;
      IF l_stock < l_cantidad THEN p_status_code := 409; p_resultado := '{"error":"Stock insuficiente para un articulo"}'; ROLLBACK; RETURN; END IF;
      INSERT INTO VENTAS_DETALLES (ID_VENTA, ID_ARTICULO, ID_IVA, CANTIDAD, PRECIO_UNITARIO, PORCENTAJE_DESCUENTO, MONTO_DESCUENTO, MONTO_IVA)
        VALUES (l_id, linea.idArticulo, linea.idIva, linea.cantidad, linea.precioUnitario, l_porcentaje, ROUND(linea.cantidad * linea.precioUnitario * l_porcentaje / 100, 2), 0);
      l_subtotal := l_subtotal + l_cantidad * linea.precioUnitario;
      l_descuento := l_descuento + ROUND(l_cantidad * linea.precioUnitario * l_porcentaje / 100, 2);
      l_lineas := l_lineas + 1;
      FOR lote IN (SELECT ID_LOTE, NVL(CANTIDAD_DISPON, CANTIDAD) disponible FROM LOTES WHERE ID_EMPRESA = l_empresa AND ID_SUCURSAL = l_sucursal AND ID_ARTICULO = linea.idArticulo AND NVL(CANTIDAD_DISPON, CANTIDAD) > 0 ORDER BY FECHA_VENCIMIENTO NULLS LAST, ID_LOTE) LOOP
        EXIT WHEN l_cantidad <= 0;
        l_stock := LEAST(l_cantidad, lote.disponible);
        UPDATE LOTES SET CANTIDAD_DISPON = lote.disponible - l_stock, FECHA_ACTUALIZACION = SYSTIMESTAMP WHERE ID_LOTE = lote.ID_LOTE;
        l_cantidad := l_cantidad - l_stock;
      END LOOP;
    END LOOP;
    IF l_lineas = 0 THEN RAISE VALUE_ERROR; END IF;
    l_total := l_subtotal - l_descuento + l_iva;
    UPDATE VENTAS_CABECERAS SET MONTO_SUBTOTAL = l_subtotal, MONTO_DESCUENTO = l_descuento, MONTO_IVA = l_iva, MONTO_TOTAL = l_total WHERE ID_VENTA = l_id;
    FOR n IN 1 .. l_cuotas LOOP
      INSERT INTO VENTAS_CUOTAS (ID_VENTA, NRO_CUOTA, FECHA_VENCIMIENTO, MONTO_CUOTA, MONTO_PAGADO, ESTADO)
        VALUES (l_id, n, TRUNC(CAST(l_fecha AS DATE)) + (l_dias * n), ROUND(l_total / l_cuotas, 2), 0, 'PENDIENTE');
    END LOOP;
    COMMIT; p_status_code := 201; p_resultado := JSON_OBJECT('id' VALUE l_id, 'lineas' VALUE l_lineas, 'total' VALUE l_total, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN ROLLBACK; p_status_code := 409; p_resultado := '{"error":"El numero de venta ya existe en esta sucursal"}';
  WHEN NO_DATA_FOUND THEN ROLLBACK; p_status_code := 409; p_resultado := '{"error":"El talonario no existe, esta inactivo, vencido o pertenece a otra sucursal"}';
  WHEN VALUE_ERROR THEN ROLLBACK; p_status_code := 400; p_resultado := '{"error":"Los datos de la venta son invalidos"}';
  WHEN OTHERS THEN ROLLBACK; p_status_code := 500; APEX_DEBUG.ERROR('PKG_VENTAS.INSERTAR: ' || SQLERRM); p_resultado := '{"error":"Error al crear la venta"}';
  END INSERTAR;

  PROCEDURE ELIMINAR (p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS l_sesion NUMBER; l_id NUMBER; l_empresa NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization)); l_id := TO_NUMBER(NULLIF(p_id, '')); l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    DELETE FROM VENTAS_COBROS WHERE ID_VENTA = l_id; DELETE FROM VENTAS_CUOTAS WHERE ID_VENTA = l_id; DELETE FROM VENTAS_DETALLES WHERE ID_VENTA = l_id; DELETE FROM VENTAS_CABECERAS WHERE ID_VENTA = l_id AND ID_EMPRESA = l_empresa;
    IF SQL%ROWCOUNT = 0 THEN ROLLBACK; p_status_code := 404; p_resultado := '{"error":"La venta no existe"}'; RETURN; END IF;
    COMMIT; p_status_code := 200; p_resultado := '{"ok":true}';
  EXCEPTION WHEN OTHERS THEN ROLLBACK; p_status_code := 500; p_resultado := '{"error":"Error al eliminar la venta"}';
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO; ORDS.DEFINE_MODULE(p_module_name => 'ventas', p_base_path => '/ventas/', p_items_per_page => 0, p_status => 'PUBLISHED', p_comments => 'Punto de venta'); ORDS.SET_MODULE_ORIGINS_ALLOWED(p_module_name => 'ventas', p_origins_allowed => 'https://www.ctell.online,http://localhost:8080');
    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas', p_pattern => 'listar'); ORDS.DEFINE_HANDLER(p_module_name => 'ventas', p_pattern => 'listar', p_method => 'GET', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_VENTAS.LISTAR(:authorization, :idEmpresa, :idSucursal, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'listar', p_method => 'GET', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'listar', p_method => 'GET', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'listar', p_method => 'GET', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');
    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas', p_pattern => 'obtener/:id/:idEmpresa'); ORDS.DEFINE_HANDLER(p_module_name => 'ventas', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_VENTAS.OBTENER(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');
    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas', p_pattern => 'crear'); ORDS.DEFINE_HANDLER(p_module_name => 'ventas', p_pattern => 'crear', p_method => 'POST', p_source_type => ORDS.source_type_plsql, p_source => 'DECLARE l_body CLOB := :body; BEGIN PKG_VENTAS.INSERTAR(:authorization, JSON_VALUE(l_body, ''$.idEmpresa'' RETURNING VARCHAR2), JSON_VALUE(l_body, ''$.idSucursal'' RETURNING VARCHAR2), JSON_VALUE(l_body, ''$.idUsuario'' RETURNING VARCHAR2), JSON_VALUE(l_body, ''$.idCliente'' RETURNING VARCHAR2), JSON_VALUE(l_body, ''$.idListaDescuentos'' RETURNING VARCHAR2), JSON_VALUE(l_body, ''$.idCondicionPago'' RETURNING VARCHAR2), JSON_VALUE(l_body, ''$.idMoneda'' RETURNING VARCHAR2), JSON_VALUE(l_body, ''$.fechaVenta'' RETURNING VARCHAR2), JSON_VALUE(l_body, ''$.observacion'' RETURNING VARCHAR2), JSON_VALUE(l_body, ''$.idTalonario'' RETURNING VARCHAR2), JSON_QUERY(l_body, ''$.detalle'' RETURNING CLOB), :status_code, :resultado); END;'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'crear', p_method => 'POST', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'crear', p_method => 'POST', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'crear', p_method => 'POST', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');
    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas', p_pattern => 'eliminar/:id/:idEmpresa'); ORDS.DEFINE_HANDLER(p_module_name => 'ventas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_VENTAS.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT'); ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT'); COMMIT;
  END PUBLICAR_ENDPOINTS;
END PKG_VENTAS;
/
BEGIN PKG_VENTAS.PUBLICAR_ENDPOINTS; END;
/