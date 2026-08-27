--------------------------------------------------------------------------------
-- CTELL · PUNTO DE VENTA
-- Maneja VENTAS_CABECERAS, VENTAS_DETALLES y VENTAS_CUOTAS en una transaccion.
-- Requiere PKG_AUTH, ARTICULOS, LOTES, IVA, PERSONAS, LISTAS_DESCUENTOS,
-- CONDICIONES_PAGO, MONEDAS, TALONARIOS, EMPRESAS y SUCURSALES.
-- Precio manual por linea. Cuotas: 30/60/90 dias son vencimientos acumulados.
--
--------------------------------------------------------------------------------
-- LOS TOTALES NO SE GUARDAN: SE CALCULAN
--
-- VENTAS_CABECERAS no tiene MONTO_SUBTOTAL, MONTO_DESCUENTO, MONTO_IVA ni
-- MONTO_TOTAL. Son la SUMA DEL DETALLE y se derivan en cada consulta.
--
-- Guardarlos ademas permitiria que la cabecera diga 500.000 mientras sus lineas
-- suman 480.000 —una inconsistencia que nadie detecta hasta que alguien cuadra
-- la caja—. Es el mismo criterio de facturas-compras.sql, del stock de un
-- articulo (SUM sobre sus lotes) y del saldo de una venta (total menos cobros):
-- si se puede derivar, se deriva.
--
--------------------------------------------------------------------------------
-- LOS PRECIOS INCLUYEN IVA: EL IMPUESTO SE DESGLOSA, NO SE SUMA
--
-- Es como se factura en Paraguay, y el mismo criterio que compras. El precio que
-- carga el cajero es el de la etiqueta: 11.000 la unidad, no 10.000 + IVA.
--
--   MONTO_GRAVADO = ROUND(neto / GRAVADA_DIVISION, 2)   (1,1 al 10%; 1,05 al 5%)
--   MONTO_IVA     = neto - MONTO_GRAVADO
--
-- donde neto = cantidad * precio - descuento. Con una linea de 110.000 al 10%:
-- gravado 100.000, IVA 10.000, y el cliente paga 110.000.
--
-- EL IVA SALE POR RESTA y no por su propia division: dos divisiones redondean
-- por separado y su suma no tiene por que dar el neto. Con una division y una
-- resta, gravado + iva = neto SIEMPRE, exacto. En un libro de ventas un guarani
-- por linea se acumula y no cuadra contra el papel.
--
-- Las tasas viejas sin GRAVADA_DIVISION caen al metodo anterior (IVA por
-- division, gravado por resta), para que lo cargado antes siga dando lo mismo.
--
-- NUNCA `neto * porcentaje / 100`: eso cobraria impuesto sobre impuesto —
-- 110.000 al 10% CONTIENE 10.000, no 11.000.
--
-- Toda division va protegida con NULLIF(..., 0): la tasa exenta tiene
-- IVA_DIVISION en 0 y sin el NULLIF seria ORA-01476. En GRAVADA_DIVISION la
-- exenta va en 1, NO en 0 — los dos divisores usan criterios opuestos.
--
--------------------------------------------------------------------------------
-- CADA LINEA SALE DE UN SOLO LOTE, Y LO ELIGE EL CAJERO
--
-- VENTAS_DETALLES.ID_LOTE es UNA columna y la tabla tiene UNIQUE (ID_VENTA,
-- ID_ARTICULO). Juntas significan que una linea no se reparte entre lotes: si se
-- venden 10 unidades, las 10 salen del mismo lote.
--
-- Por eso el lote VIENE EN EL DETALLE en vez de elegirlo el backend por FIFO.
-- Con FIFO automatico, un stock de 10 partido en lotes de 6 y 4 haria fracasar
-- una venta de 10 sin que el cajero entienda por que —la pantalla dice que hay
-- 10—. Eligiendolo el, ve el disponible de cada lote y decide.
--
-- NO SE VENDE SIN EXISTENCIA. Al insertar se valida que el lote exista, sea de
-- esta empresa y sucursal, sea del articulo de la linea, y tenga
-- CANTIDAD_DISPON suficiente. Se lee con FOR UPDATE para que dos cajas
-- vendiendo el mismo lote a la vez no vean ambas existencia de sobra.
--
-- Los articulos con ES_GASTO distinto de 'N' no llevan lote: un servicio no
-- tiene stock que descontar.
--
-- Al ELIMINAR, cada linea devuelve su cantidad a su ID_LOTE. Es exacto porque el
-- lote quedo guardado; sin esa columna el stock se perdia para siempre, ya que
-- CANTIDAD_DISPON es una columna real y no se deriva de nada.
--
--------------------------------------------------------------------------------
-- Tablas (no las crea ni las altera; el DDL se administra aparte):
--   VENTAS_CABECERAS  ID_VENTA, ID_EMPRESA, ID_SUCURSAL, ID_USUARIO, ID_CLIENTE,
--                     ID_LISTA_DESCUENTOS, ID_CONDICION_PAGO, ID_MONEDA,
--                     NUMERO_VENTA, FECHA_VENTA, OBSERVACION, TIPO_COMPROBANTE,
--                     ID_TALONARIO, NRO_TIMBRADO, ESTABLECIMIENTO,
--                     PUNTO_EXPEDICION, NRO_COMPROBANTE, FECHA_CREACION,
--                     FECHA_ACTUALIZACION
--   VENTAS_DETALLES   ID_DETALLE, ID_VENTA, ID_ARTICULO, ID_IVA, ID_LOTE,
--                     CANTIDAD, PRECIO_UNITARIO, SUBTOTAL (VIRTUAL),
--                     PORCENTAJE_DESCUENTO, MONTO_DESCUENTO, MONTO_GRAVADO,
--                     MONTO_IVA, TOTAL (VIRTUAL), FECHA_CREACION
--   VENTAS_CUOTAS     ID_CUOTA, ID_VENTA, NRO_CUOTA, FECHA_VENCIMIENTO,
--                     MONTO_CUOTA, MONTO_PAGADO, SALDO_PENDIENTE (VIRTUAL),
--                     ESTADO, FECHA_ACTUALIZACION
--
-- CORREGIR LA COLUMNA VIRTUAL "TOTAL" ANTES DE VENDER. El DDL la define como
--     CANTIDAD * PRECIO_UNITARIO - MONTO_DESCUENTO + MONTO_IVA
-- y eso SUMA un impuesto que el precio ya contiene: cada linea daria mas que la
-- suma que se le cobra al cliente. No se notaba porque MONTO_IVA se guardaba
-- siempre en 0. Correr UNA VEZ en APEX:
--
--   ALTER TABLE VENTAS_DETALLES DROP COLUMN TOTAL;
--   ALTER TABLE VENTAS_DETALLES ADD (
--     TOTAL AS ("CANTIDAD"*"PRECIO_UNITARIO"-"MONTO_DESCUENTO")
--   );
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_VENTAS AS
  PROCEDURE LISTAR (p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_sucursal IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE OBTENER (p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE INSERTAR (
    p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_sucursal IN VARCHAR2, p_id_usuario IN VARCHAR2, p_id_cliente IN VARCHAR2,
    p_id_lista_descuentos IN VARCHAR2, p_id_condicion_pago IN VARCHAR2, p_id_moneda IN VARCHAR2,
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
    -- Los montos salen de los dos LEFT JOIN agrupados, no de la cabecera: ver la
    -- nota de arriba. LEFT y no JOIN interno para que una venta sin detalle o
    -- sin cobros aparezca igual, en 0, en vez de desaparecer del listado.
    SELECT JSON_ARRAYAGG(fila ORDER BY fecha_venta DESC RETURNING CLOB) INTO l_items FROM (
      SELECT JSON_OBJECT('id' VALUE v.ID_VENTA, 'idEmpresa' VALUE v.ID_EMPRESA, 'idSucursal' VALUE v.ID_SUCURSAL,
        'idCliente' VALUE v.ID_CLIENTE, 'cliente' VALUE CASE WHEN p.ID_PERSONA IS NULL THEN NULL ELSE p.NOMBRE || NVL2(p.APELLIDO, ' ' || p.APELLIDO, '') END,
        'numeroVenta' VALUE v.NUMERO_VENTA, 'fechaVenta' VALUE TO_CHAR(v.FECHA_VENTA, 'YYYY-MM-DD"T"HH24:MI:SS'),
        'tipoComprobante' VALUE v.TIPO_COMPROBANTE, 'idTalonario' VALUE v.ID_TALONARIO, 'nroTimbrado' VALUE v.NRO_TIMBRADO,
        'establecimiento' VALUE v.ESTABLECIMIENTO, 'puntoExpedicion' VALUE v.PUNTO_EXPEDICION, 'nroComprobante' VALUE v.NRO_COMPROBANTE,
        'idMoneda' VALUE v.ID_MONEDA, 'observacion' VALUE v.OBSERVACION,
        'montoSubtotal' VALUE NVL(t.subtotal, 0), 'montoDescuento' VALUE NVL(t.descuento, 0),
        'montoGravado' VALUE NVL(t.gravado, 0), 'montoIva' VALUE NVL(t.iva, 0), 'montoTotal' VALUE NVL(t.total, 0),
        'lineas' VALUE NVL(t.lineas, 0),
        'montoCobrado' VALUE NVL(c.cobrado, 0),
        'saldoPendiente' VALUE NVL(t.total, 0) - NVL(c.cobrado, 0)
        RETURNING CLOB) AS fila, v.FECHA_VENTA fecha_venta
      FROM VENTAS_CABECERAS v
      LEFT JOIN PERSONAS p ON p.ID_PERSONA = v.ID_CLIENTE
      LEFT JOIN (SELECT ID_VENTA, COUNT(*) lineas, SUM(SUBTOTAL) subtotal, SUM(MONTO_DESCUENTO) descuento,
                        SUM(MONTO_GRAVADO) gravado, SUM(MONTO_IVA) iva, SUM(TOTAL) total
                   FROM VENTAS_DETALLES GROUP BY ID_VENTA) t ON t.ID_VENTA = v.ID_VENTA
      LEFT JOIN (SELECT ID_VENTA, SUM(MONTO) cobrado FROM VENTAS_COBROS GROUP BY ID_VENTA) c ON c.ID_VENTA = v.ID_VENTA
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
      'observacion' VALUE v.OBSERVACION,
      'montoSubtotal' VALUE NVL(t.subtotal, 0), 'montoDescuento' VALUE NVL(t.descuento, 0),
      'montoGravado' VALUE NVL(t.gravado, 0), 'montoIva' VALUE NVL(t.iva, 0), 'montoTotal' VALUE NVL(t.total, 0),
      'montoCobrado' VALUE NVL(c.cobrado, 0),
      'saldoPendiente' VALUE NVL(t.total, 0) - NVL(c.cobrado, 0) RETURNING CLOB)
      INTO l_cab
      FROM VENTAS_CABECERAS v
      LEFT JOIN (SELECT ID_VENTA, SUM(SUBTOTAL) subtotal, SUM(MONTO_DESCUENTO) descuento,
                        SUM(MONTO_GRAVADO) gravado, SUM(MONTO_IVA) iva, SUM(TOTAL) total
                   FROM VENTAS_DETALLES GROUP BY ID_VENTA) t ON t.ID_VENTA = v.ID_VENTA
      LEFT JOIN (SELECT ID_VENTA, SUM(MONTO) cobrado FROM VENTAS_COBROS GROUP BY ID_VENTA) c ON c.ID_VENTA = v.ID_VENTA
     WHERE v.ID_VENTA = l_id AND v.ID_EMPRESA = l_empresa;
    -- LEFT JOIN en LOTES: ID_LOTE es nullable (los articulos ES_GASTO no llevan),
    -- y con JOIN interno esas lineas desaparecerian del detalle sin ningun error.
    SELECT JSON_ARRAYAGG(JSON_OBJECT('id' VALUE d.ID_DETALLE, 'idArticulo' VALUE d.ID_ARTICULO, 'articulo' VALUE a.NOMBRE_ARTICULO,
      'idIva' VALUE d.ID_IVA, 'cantidad' VALUE d.CANTIDAD, 'precioUnitario' VALUE d.PRECIO_UNITARIO, 'subtotal' VALUE d.SUBTOTAL,
      'porcentajeDescuento' VALUE d.PORCENTAJE_DESCUENTO, 'montoDescuento' VALUE d.MONTO_DESCUENTO,
      'montoGravado' VALUE d.MONTO_GRAVADO, 'montoIva' VALUE d.MONTO_IVA, 'total' VALUE d.TOTAL,
      -- El lote de la linea: la trazabilidad que da la columna. Ante un
      -- vencimiento o un recall, esto dice a quien se le vendio cual.
      'idLote' VALUE d.ID_LOTE, 'numeroLote' VALUE lo.NUMERO_LOTE,
      'loteVence' VALUE TO_CHAR(lo.FECHA_VENCIMIENTO, 'YYYY-MM-DD') RETURNING CLOB) ORDER BY d.ID_DETALLE RETURNING CLOB)
      INTO l_det
      FROM VENTAS_DETALLES d
      LEFT JOIN ARTICULOS a ON a.ID_ARTICULO = d.ID_ARTICULO
      LEFT JOIN LOTES     lo ON lo.ID_LOTE   = d.ID_LOTE
     WHERE d.ID_VENTA = l_id;
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
    p_fecha_venta IN VARCHAR2, p_observacion IN VARCHAR2, p_id_talonario IN VARCHAR2, p_detalle IN CLOB,
    p_status_code OUT NUMBER, p_resultado OUT CLOB
  ) IS
    l_sesion NUMBER; l_empresa NUMBER; l_sucursal NUMBER; l_usuario NUMBER; l_cliente NUMBER; l_lista NUMBER; l_condicion NUMBER; l_moneda NUMBER; l_talonario NUMBER; l_id NUMBER; l_lineas NUMBER := 0;
    l_fecha TIMESTAMP; l_porcentaje NUMBER := 0; l_dias NUMBER := 0; l_cuotas NUMBER := 1; l_es_gasto VARCHAR2(1); l_disponible NUMBER;
    l_bruto NUMBER; l_desc NUMBER; l_neto NUMBER; l_gravado NUMBER; l_iva_linea NUMBER; l_total NUMBER := 0;
    l_nro NUMBER; l_final_talonario NUMBER; l_tipo VARCHAR2(3); l_timbrado VARCHAR2(20); l_establecimiento VARCHAR2(3); l_punto VARCHAR2(3); l_numero VARCHAR2(50);
  BEGIN
    l_sesion    := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_empresa   := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_sucursal  := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    l_usuario   := TO_NUMBER(NULLIF(p_id_usuario, ''));
    l_cliente   := TO_NUMBER(NULLIF(p_id_cliente, ''));
    l_lista     := TO_NUMBER(NULLIF(p_id_lista_descuentos, ''));
    l_condicion := TO_NUMBER(NULLIF(p_id_condicion_pago, ''));
    l_moneda    := TO_NUMBER(NULLIF(p_id_moneda, ''));
    l_talonario := TO_NUMBER(NULLIF(p_id_talonario, ''));
    l_fecha     := TO_TIMESTAMP(NULLIF(p_fecha_venta, ''), 'YYYY-MM-DD"T"HH24:MI:SS');
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_empresa IS NULL OR l_sucursal IS NULL OR l_usuario IS NULL OR l_condicion IS NULL OR l_moneda IS NULL OR l_talonario IS NULL OR l_lista IS NULL OR p_detalle IS NULL THEN
      p_status_code := 400; p_resultado := '{"error":"Faltan datos obligatorios de la venta"}'; RETURN;
    END IF;

    -- El talonario se toma FOR UPDATE: es la fuente del numero de comprobante y
    -- dos ventas simultaneas no pueden llevarse el mismo.
    SELECT TIPO_COMPROBANTE, NRO_TIMBRADO, ESTABLECIMIENTO, PUNTO_EXPEDICION, NRO_ACTUAL, NRO_FINAL
      INTO l_tipo, l_timbrado, l_establecimiento, l_punto, l_nro, l_final_talonario
      FROM TALONARIOS
     WHERE ID_TALONARIO = l_talonario AND ID_EMPRESA = l_empresa AND ID_SUCURSAL = l_sucursal
       AND ACTIVO = 'A' AND (FECHA_INICIO IS NULL OR TRUNC(FECHA_INICIO) <= TRUNC(CAST(l_fecha AS DATE)))
       AND (FECHA_VENCIMIENTO IS NULL OR TRUNC(FECHA_VENCIMIENTO) >= TRUNC(CAST(l_fecha AS DATE)))
     FOR UPDATE;
    IF l_nro > l_final_talonario THEN p_status_code := 409; p_resultado := '{"error":"El talonario no tiene numeros disponibles"}'; ROLLBACK; RETURN; END IF;
    l_numero := l_establecimiento || '-' || l_punto || '-' || LPAD(TO_CHAR(l_nro), 7, '0');

    SELECT PORCENTAJE_DESCUENTO INTO l_porcentaje FROM LISTAS_DESCUENTOS
     WHERE ID_LISTA_PRECIOS = l_lista AND ID_EMPRESA = l_empresa
       AND FECHA_VIGENCIA_DESDE <= l_fecha AND (FECHA_VIGENCIA_HASTA IS NULL OR FECHA_VIGENCIA_HASTA >= l_fecha);
    SELECT NVL(DIAS_PAGO, 0), NVL(CANTIDAD_CUOTAS, 1) INTO l_dias, l_cuotas FROM CONDICIONES_PAGO WHERE ID_CONDICION = l_condicion;

    -- La cabecera va sin montos: son la suma del detalle y se derivan al leer.
    INSERT INTO VENTAS_CABECERAS (ID_EMPRESA, ID_SUCURSAL, ID_USUARIO, ID_CLIENTE, ID_LISTA_DESCUENTOS, ID_CONDICION_PAGO, ID_MONEDA, NUMERO_VENTA, FECHA_VENTA, OBSERVACION, TIPO_COMPROBANTE, ID_TALONARIO, NRO_TIMBRADO, ESTABLECIMIENTO, PUNTO_EXPEDICION, NRO_COMPROBANTE)
      VALUES (l_empresa, l_sucursal, l_usuario, l_cliente, l_lista, l_condicion, l_moneda, l_numero, l_fecha, NULLIF(TRIM(p_observacion), ''), l_tipo, l_talonario, l_timbrado, l_establecimiento, l_punto, l_nro)
      RETURNING ID_VENTA INTO l_id;
    UPDATE TALONARIOS SET NRO_ACTUAL = CASE WHEN NRO_ACTUAL = NRO_FINAL THEN NRO_ACTUAL ELSE NRO_ACTUAL + 1 END,
                          ACTIVO = CASE WHEN NRO_ACTUAL = NRO_FINAL THEN 'I' ELSE ACTIVO END,
                          FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_TALONARIO = l_talonario;

    FOR linea IN (SELECT idArticulo, cantidad, precioUnitario, idIva, idLote
                    FROM JSON_TABLE(p_detalle, '$[*]' COLUMNS (
                           idArticulo NUMBER PATH '$.idArticulo', cantidad NUMBER PATH '$.cantidad',
                           precioUnitario NUMBER PATH '$.precioUnitario', idIva NUMBER PATH '$.idIva',
                           idLote NUMBER PATH '$.idLote'))) LOOP
      IF linea.idArticulo IS NULL OR linea.cantidad IS NULL OR linea.cantidad <= 0 OR linea.precioUnitario IS NULL OR linea.precioUnitario < 0 THEN
        ROLLBACK; p_status_code := 400; p_resultado := '{"error":"Los datos de una linea son invalidos"}'; RETURN;
      END IF;

      BEGIN SELECT NVL(ES_GASTO, 'N') INTO l_es_gasto FROM ARTICULOS WHERE ID_ARTICULO = linea.idArticulo;
      EXCEPTION WHEN NO_DATA_FOUND THEN ROLLBACK; p_status_code := 400; p_resultado := '{"error":"Un articulo del detalle no existe"}'; RETURN; END;

      -- NO SE VENDE SIN EXISTENCIA. El lote se bloquea antes de mirarle el
      -- disponible: sin el FOR UPDATE, dos cajas leen el mismo saldo y las dos
      -- creen tener stock.
      IF l_es_gasto = 'N' THEN
        IF linea.idLote IS NULL THEN
          ROLLBACK; p_status_code := 400; p_resultado := '{"error":"Falta elegir el lote de un articulo"}'; RETURN;
        END IF;
        BEGIN
          SELECT NVL(CANTIDAD_DISPON, CANTIDAD) INTO l_disponible
            FROM LOTES
           WHERE ID_LOTE = linea.idLote AND ID_EMPRESA = l_empresa AND ID_SUCURSAL = l_sucursal AND ID_ARTICULO = linea.idArticulo
             FOR UPDATE;
        EXCEPTION WHEN NO_DATA_FOUND THEN
          ROLLBACK; p_status_code := 400; p_resultado := '{"error":"El lote elegido no corresponde al articulo o a esta sucursal"}'; RETURN;
        END;
        IF l_disponible < linea.cantidad THEN
          ROLLBACK; p_status_code := 409; p_resultado := '{"error":"El lote elegido no tiene existencia suficiente"}'; RETURN;
        END IF;
        UPDATE LOTES SET CANTIDAD_DISPON = l_disponible - linea.cantidad, FECHA_ACTUALIZACION = SYSTIMESTAMP WHERE ID_LOTE = linea.idLote;
      END IF;

      -- El desglose sale del NETO (ya descontado), que es lo que se cobra.
      -- Sin tasa asignada el impuesto es 0 y todo el neto es gravado.
      l_bruto   := linea.cantidad * linea.precioUnitario;
      l_desc    := ROUND(l_bruto * l_porcentaje / 100, 2);
      l_neto    := l_bruto - l_desc;
      l_gravado := l_neto;
      l_iva_linea := 0;
      IF linea.idIva IS NOT NULL THEN
        BEGIN
          SELECT NVL(CASE WHEN GRAVADA_DIVISION IS NOT NULL THEN ROUND(l_neto / NULLIF(GRAVADA_DIVISION, 0), 2)
                          ELSE l_neto - NVL(ROUND(l_neto / NULLIF(IVA_DIVISION, 0), 2), 0) END, l_neto)
            INTO l_gravado FROM IVA WHERE ID_IVA = linea.idIva;
        EXCEPTION WHEN NO_DATA_FOUND THEN
          ROLLBACK; p_status_code := 400; p_resultado := '{"error":"Una linea tiene una tasa de IVA que no existe"}'; RETURN;
        END;
        -- Por RESTA, para que gravado + iva de el neto exacto. Ver la cabecera.
        l_iva_linea := l_neto - l_gravado;
      END IF;

      INSERT INTO VENTAS_DETALLES (ID_VENTA, ID_ARTICULO, ID_IVA, ID_LOTE, CANTIDAD, PRECIO_UNITARIO, PORCENTAJE_DESCUENTO, MONTO_DESCUENTO, MONTO_GRAVADO, MONTO_IVA)
        VALUES (l_id, linea.idArticulo, linea.idIva, CASE WHEN l_es_gasto = 'N' THEN linea.idLote END, linea.cantidad, linea.precioUnitario, l_porcentaje, l_desc, l_gravado, l_iva_linea);
      l_total  := l_total + l_neto;
      l_lineas := l_lineas + 1;
    END LOOP;

    IF l_lineas = 0 THEN ROLLBACK; p_status_code := 400; p_resultado := '{"error":"La venta no tiene lineas"}'; RETURN; END IF;

    FOR n IN 1 .. l_cuotas LOOP
      INSERT INTO VENTAS_CUOTAS (ID_VENTA, NRO_CUOTA, FECHA_VENCIMIENTO, MONTO_CUOTA, MONTO_PAGADO, ESTADO)
        VALUES (l_id, n, TRUNC(CAST(l_fecha AS DATE)) + (l_dias * n), ROUND(l_total / l_cuotas, 2), 0, 'PENDIENTE');
    END LOOP;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'numeroVenta' VALUE l_numero, 'lineas' VALUE l_lineas, 'total' VALUE l_total, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN ROLLBACK; p_status_code := 409; p_resultado := '{"error":"El numero de venta ya existe o un articulo aparece dos veces en el detalle"}';
    WHEN NO_DATA_FOUND THEN ROLLBACK; p_status_code := 409; p_resultado := '{"error":"El talonario, la lista de descuentos o la condicion de pago no existe"}';
    WHEN OTHERS THEN ROLLBACK; p_status_code := 500; APEX_DEBUG.ERROR('PKG_VENTAS.INSERTAR: ' || SQLERRM); p_resultado := '{"error":"Error al crear la venta"}';
  END INSERTAR;

  -- Borra la venta y DEVUELVE LA EXISTENCIA a los lotes de los que salio.
  --
  -- Primero confirma que la venta existe y es de esta empresa, DESPUES repone.
  -- Antes los DELETE salian a ciegas y el 404 se deducia del SQL%ROWCOUNT del
  -- ultimo, que funcionaba solo porque la cabecera se borraba al final.
  PROCEDURE ELIMINAR (p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion NUMBER; l_id NUMBER; l_empresa NUMBER; l_existe NUMBER; l_repuesto NUMBER := 0; l_cobros NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization)); l_id := TO_NUMBER(NULLIF(p_id, '')); l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_id IS NULL OR l_empresa IS NULL THEN p_status_code := 400; p_resultado := '{"error":"id e idEmpresa son obligatorios"}'; RETURN; END IF;
    BEGIN
      SELECT ID_VENTA INTO l_existe FROM VENTAS_CABECERAS WHERE ID_VENTA = l_id AND ID_EMPRESA = l_empresa FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      ROLLBACK; p_status_code := 404; p_resultado := '{"error":"La venta no existe"}'; RETURN;
    END;
    -- UNA VENTA CON COBROS NO SE BORRA. El DELETE en cascada se llevaria puesta
    -- plata que entro a la caja, sin dejar rastro de que existio: eso ya no es
    -- corregir un error de carga, es un agujero de auditoria. Hay que anular los
    -- cobros uno por uno primero —cada uno devuelve el saldo y reabre su cuota—,
    -- lo que obliga a mirar cada monto antes de que desaparezca.
    SELECT COUNT(*) INTO l_cobros FROM VENTAS_COBROS WHERE ID_VENTA = l_id;
    IF l_cobros > 0 THEN
      ROLLBACK; p_status_code := 409; p_resultado := '{"error":"La venta tiene cobros registrados: anulalos antes de eliminarla"}'; RETURN;
    END IF;
    -- AGRUPADO por lote: aunque el UNIQUE impide repetir un articulo, dos
    -- articulos distintos pueden salir del mismo lote. Sumarlo de a una fila
    -- haria dos UPDATE sobre la misma, leyendo el valor viejo en el segundo.
    FOR reposicion IN (SELECT ID_LOTE, SUM(CANTIDAD) AS cantidad
                         FROM VENTAS_DETALLES WHERE ID_VENTA = l_id AND ID_LOTE IS NOT NULL
                        GROUP BY ID_LOTE) LOOP
      UPDATE LOTES SET CANTIDAD_DISPON = NVL(CANTIDAD_DISPON, CANTIDAD) + reposicion.cantidad,
                       FECHA_ACTUALIZACION = SYSTIMESTAMP
       WHERE ID_LOTE = reposicion.ID_LOTE;
      l_repuesto := l_repuesto + reposicion.cantidad;
    END LOOP;
    DELETE FROM VENTAS_COBROS   WHERE ID_VENTA = l_id;
    DELETE FROM VENTAS_CUOTAS   WHERE ID_VENTA = l_id;
    DELETE FROM VENTAS_DETALLES WHERE ID_VENTA = l_id;
    DELETE FROM VENTAS_CABECERAS WHERE ID_VENTA = l_id AND ID_EMPRESA = l_empresa;
    COMMIT;
    p_status_code := 200;
    p_resultado := JSON_OBJECT('ok' VALUE 'true' FORMAT JSON, 'unidadesRepuestas' VALUE l_repuesto);
  EXCEPTION WHEN OTHERS THEN ROLLBACK; p_status_code := 500; APEX_DEBUG.ERROR('PKG_VENTAS.ELIMINAR: ' || SQLERRM); p_resultado := '{"error":"Error al eliminar la venta"}';
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;
    ORDS.DEFINE_MODULE(p_module_name => 'ventas', p_base_path => '/ventas/', p_items_per_page => 0, p_status => 'PUBLISHED', p_comments => 'Punto de venta');
    ORDS.SET_MODULE_ORIGINS_ALLOWED(p_module_name => 'ventas', p_origins_allowed => 'https://www.ctell.online,http://localhost:8080');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas', p_pattern => 'listar');
    ORDS.DEFINE_HANDLER(p_module_name => 'ventas', p_pattern => 'listar', p_method => 'GET', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_VENTAS.LISTAR(:authorization, :idEmpresa, :idSucursal, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'listar', p_method => 'GET', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'listar', p_method => 'GET', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'listar', p_method => 'GET', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas', p_pattern => 'obtener/:id/:idEmpresa');
    ORDS.DEFINE_HANDLER(p_module_name => 'ventas', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_VENTAS.OBTENER(:authorization, :id, :idEmpresa, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas', p_pattern => 'crear');
    ORDS.DEFINE_HANDLER(p_module_name => 'ventas', p_pattern => 'crear', p_method => 'POST', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_VENTAS.INSERTAR(:authorization, :idEmpresa, :idSucursal, :idUsuario, :idCliente, :idListaDescuentos, :idCondicionPago, :idMoneda, :fechaVenta, :observacion, :idTalonario, :detalle, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'crear', p_method => 'POST', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'crear', p_method => 'POST', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'crear', p_method => 'POST', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'ventas', p_pattern => 'eliminar/:id/:idEmpresa');
    ORDS.DEFINE_HANDLER(p_module_name => 'ventas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_VENTAS.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'ventas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');
    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_VENTAS;
/
BEGIN PKG_VENTAS.PUBLICAR_ENDPOINTS; END;
/

--------------------------------------------------------------------------------
-- Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS FROM USER_OBJECTS WHERE OBJECT_NAME = 'PKG_VENTAS' ORDER BY OBJECT_TYPE;

SELECT NAME, LINE, POSITION, TEXT FROM USER_ERRORS WHERE NAME = 'PKG_VENTAS' ORDER BY SEQUENCE;

-- LAS TASAS DE IVA TIENEN QUE ESTAR CARGADAS: sin ellas el punto de venta no
-- puede asignar tasa a ninguna linea. Ver db/iva.sql.
SELECT ID_IVA, PORCENTAJE, IVA_DIVISION, GRAVADA_DIVISION, DESCRIPCION FROM IVA;

-- LA COLUMNA VIRTUAL "TOTAL" NO DEBE SUMAR MONTO_IVA. Ver la nota de arriba: si
-- el DATA_DEFAULT que sale aca todavia dice + "MONTO_IVA", corre el ALTER.
SELECT COLUMN_NAME, DATA_DEFAULT FROM USER_TAB_COLS
 WHERE TABLE_NAME = 'VENTAS_DETALLES' AND VIRTUAL_COLUMN = 'YES';

-- Que el desglose CUADRE: gravado + iva tiene que dar el total de la linea,
-- exacto. Cero filas es lo correcto.
SELECT ID_VENTA, ID_DETALLE, TOTAL, MONTO_GRAVADO, MONTO_IVA
  FROM VENTAS_DETALLES
 WHERE NVL(MONTO_GRAVADO, 0) + NVL(MONTO_IVA, 0) != TOTAL;

-- Ninguna venta puede haber dejado un lote en negativo.
SELECT ID_LOTE, ID_ARTICULO, CANTIDAD, CANTIDAD_DISPON FROM LOTES WHERE CANTIDAD_DISPON < 0;

SELECT NAME, STATUS, ORIGINS_ALLOWED FROM USER_ORDS_MODULES WHERE NAME = 'ventas';
