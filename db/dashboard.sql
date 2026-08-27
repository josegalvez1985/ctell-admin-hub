--------------------------------------------------------------------------------
-- CTELL · DASHBOARD
-- Los indicadores de la home, en UNA consulta.
-- Requiere PKG_AUTH, VENTAS_CABECERAS, VENTAS_DETALLES, FACTURAS_COMPRAS_CAB,
-- FACTURAS_COMPRAS_DET y LOTES.
--
-- POR QUE UN ENDPOINT PROPIO Y NO SUMAR EN EL FRONTEND: los listados de ventas y
-- compras estan paginados, asi que sumarlos en el cliente daria el total de la
-- pagina, no del mes. Y traerse el mes entero para mostrar cuatro numeros seria
-- bajar miles de filas por pantalla cargada.
--
-- CADA INDICADOR TRAE SU MES ANTERIOR. La variacion se calcula en el frontend
-- con los dos numeros: mandar solo el porcentaje escondería el caso incomodo —
-- que el mes anterior sea 0, donde la variacion no es "infinito" sino que no
-- existe— y la pantalla no podria distinguirlo de un 0%.
--
-- EL MES ES EL CALENDARIO EN CURSO, de TRUNC(SYSDATE, 'MM') a hoy. No son 30
-- dias moviles: quien mira el dashboard compara contra el cierre del mes pasado,
-- no contra una ventana que se corre sola.
--
-- Los montos se derivan del DETALLE, igual que en el resto del sistema: las
-- cabeceras no guardan totales.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_DASHBOARD AS
  PROCEDURE RESUMEN (p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_sucursal IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE PUBLICAR_ENDPOINTS;
END PKG_DASHBOARD;
/

CREATE OR REPLACE PACKAGE BODY PKG_DASHBOARD AS

  -- A partir de cuantas unidades un articulo entra en "stock critico".
  --
  -- Es un numero fijo y no el CANTIDAD_MINIMA de cada articulo a proposito: el
  -- minimo esta cargado en pocos articulos, asi que un panel que dependiera solo
  -- de el se veria casi vacio. Los dos criterios conviven — el KPI de "bajo
  -- minimo" usa la politica por articulo, este panel usa el umbral parejo.
  C_UMBRAL_CRITICO CONSTANT NUMBER := 5;

  -- Cuantos dias hacia adelante se miran los vencimientos de cuotas.
  C_DIAS_POR_VENCER CONSTANT NUMBER := 7;

  -- Cuantos movimientos entran en el panel de la home.
  C_MOVIMIENTOS CONSTANT NUMBER := 8;

  PROCEDURE BORRAR_MODULO IS l_existe PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. 3 LOOP
      BEGIN
        SELECT COUNT(*) INTO l_existe FROM USER_ORDS_MODULES WHERE NAME = 'dashboard';
        IF l_existe = 0 THEN RETURN; END IF;
        ORDS.DELETE_MODULE(p_module_name => 'dashboard'); COMMIT; RETURN;
      EXCEPTION WHEN OTHERS THEN
        IF SQLCODE IN (-60, -4020) AND i < 3 THEN ROLLBACK; DBMS_SESSION.SLEEP(2); ELSE RAISE; END IF;
      END;
    END LOOP;
  END BORRAR_MODULO;

  PROCEDURE RESUMEN (p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_sucursal IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion NUMBER; l_empresa NUMBER; l_sucursal NUMBER;
    l_desde DATE; l_desde_ant DATE;
    l_ventas NUMBER; l_ventas_ant NUMBER;
    l_compras NUMBER; l_compras_ant NUMBER;
    l_stock NUMBER; l_stock_unidades NUMBER; l_bajo_minimo NUMBER;
    l_cuotas_cantidad NUMBER; l_cuotas_monto NUMBER;
    l_movimientos CLOB; l_criticos CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, '')); l_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    IF l_empresa IS NULL OR l_sucursal IS NULL THEN p_status_code := 400; p_resultado := '{"error":"idEmpresa e idSucursal son obligatorios"}'; RETURN; END IF;

    l_desde     := TRUNC(SYSDATE, 'MM');
    l_desde_ant := ADD_MONTHS(l_desde, -1);

    -- VENTAS: la suma del detalle de las cabeceras del mes. El TOTAL de la linea
    -- ya viene neto de descuento y con el IVA adentro, que es lo que se cobro.
    SELECT NVL(SUM(CASE WHEN v.FECHA_VENTA >= l_desde                              THEN d.TOTAL END), 0),
           NVL(SUM(CASE WHEN v.FECHA_VENTA >= l_desde_ant AND v.FECHA_VENTA < l_desde THEN d.TOTAL END), 0)
      INTO l_ventas, l_ventas_ant
      FROM VENTAS_CABECERAS v
      JOIN VENTAS_DETALLES  d ON d.ID_VENTA = v.ID_VENTA
     WHERE v.ID_EMPRESA = l_empresa AND v.ID_SUCURSAL = l_sucursal
       AND v.FECHA_VENTA >= l_desde_ant;

    -- COMPRAS: mismo criterio contra FACTURAS_COMPRAS. FECHA_FACTURA es DATE,
    -- no TIMESTAMP, asi que la comparacion es directa.
    SELECT NVL(SUM(CASE WHEN f.FECHA_FACTURA >= l_desde                                THEN d.SUBTOTAL END), 0),
           NVL(SUM(CASE WHEN f.FECHA_FACTURA >= l_desde_ant AND f.FECHA_FACTURA < l_desde THEN d.SUBTOTAL END), 0)
      INTO l_compras, l_compras_ant
      FROM FACTURAS_COMPRAS_CAB f
      JOIN FACTURAS_COMPRAS_DET d ON d.ID_FACTURA = f.ID_FACTURA
     WHERE f.ID_EMPRESA = l_empresa AND f.ID_SUCURSAL = l_sucursal
       AND f.FECHA_FACTURA >= l_desde_ant;

    -- VALOR DE STOCK: lo que QUEDA por lo que COSTO, no por lo que entro.
    -- Un lote sin costo cargado vale 0 aca en vez de romper la suma.
    SELECT NVL(SUM(NVL(CANTIDAD_DISPON, CANTIDAD) * NVL(COSTO, 0)), 0),
           NVL(SUM(NVL(CANTIDAD_DISPON, CANTIDAD)), 0)
      INTO l_stock, l_stock_unidades
      FROM LOTES
     WHERE ID_EMPRESA = l_empresa AND ID_SUCURSAL = l_sucursal;

    -- Cuantos articulos estan por debajo de su minimo. Es el unico indicador que
    -- pide una accion, y por eso viaja aparte de los montos.
    SELECT COUNT(*) INTO l_bajo_minimo
      FROM ARTICULOS a
     WHERE a.ID_EMPRESA = l_empresa
       AND NVL(a.CANTIDAD_MINIMA, 0) > 0
       AND NVL((SELECT SUM(NVL(lo.CANTIDAD_DISPON, lo.CANTIDAD)) FROM LOTES lo
                 WHERE lo.ID_ARTICULO = a.ID_ARTICULO AND lo.ID_SUCURSAL = l_sucursal), 0)
           < a.CANTIDAD_MINIMA;

    -- PAGOS A PROVEEDORES QUE VENCEN ESTA SEMANA. Se cuentan las CUOTAS con
    -- saldo, no las facturas: una factura en tres cuotas vence tres veces, y lo
    -- que hay que pagar el viernes es una cuota, no la factura entera.
    -- Incluye las ya vencidas e impagas: si algo se paso de fecha, esconderlo
    -- del aviso es exactamente lo contrario de lo que sirve.
    SELECT COUNT(*), NVL(SUM(q.SALDO_PENDIENTE), 0)
      INTO l_cuotas_cantidad, l_cuotas_monto
      FROM FACTURAS_COMPRAS_CUOTAS q
      JOIN FACTURAS_COMPRAS_CAB f ON f.ID_FACTURA = q.ID_FACTURA
     WHERE f.ID_EMPRESA = l_empresa AND f.ID_SUCURSAL = l_sucursal
       AND q.SALDO_PENDIENTE > 0
       AND q.FECHA_VENCIMIENTO <= TRUNC(SYSDATE) + C_DIAS_POR_VENCER;

    -- ULTIMOS MOVIMIENTOS: ventas, compras e inventarios en una sola lista,
    -- ordenados por fecha. Se unen aca y no en el frontend porque cada origen
    -- esta paginado por su lado: mezclar tres primeras paginas no da los ultimos
    -- ocho movimientos, da los ultimos de cada uno.
    --
    -- El monto de un inventario son UNIDADES, no plata, por eso viaja
    -- `enUnidades`: la pantalla necesita saber que no lleva simbolo de moneda.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden DESC RETURNING CLOB) INTO l_movimientos
      FROM (
        SELECT * FROM (
          SELECT JSON_OBJECT(
                   'tipo'       VALUE 'Venta',
                   'documento'  VALUE v.NUMERO_VENTA,
                   'parte'      VALUE NVL(pe.NOMBRE || NVL2(pe.APELLIDO, ' ' || pe.APELLIDO, ''), 'Cliente ocasional'),
                   'monto'      VALUE (SELECT NVL(SUM(TOTAL), 0) FROM VENTAS_DETALLES d WHERE d.ID_VENTA = v.ID_VENTA),
                   'enUnidades' VALUE 'N',
                   'fecha'      VALUE TO_CHAR(v.FECHA_VENTA, 'YYYY-MM-DD'),
                   'estado'     VALUE CASE WHEN NVL((SELECT SUM(MONTO) FROM VENTAS_COBROS c WHERE c.ID_VENTA = v.ID_VENTA), 0)
                                             >= (SELECT NVL(SUM(TOTAL), 0) FROM VENTAS_DETALLES d WHERE d.ID_VENTA = v.ID_VENTA)
                                           THEN 'Cobrada' ELSE 'Pendiente' END
                   RETURNING CLOB) AS fila,
                 v.FECHA_VENTA AS orden
            FROM VENTAS_CABECERAS v
            LEFT JOIN PERSONAS pe ON pe.ID_PERSONA = v.ID_CLIENTE
           WHERE v.ID_EMPRESA = l_empresa AND v.ID_SUCURSAL = l_sucursal
           ORDER BY v.FECHA_VENTA DESC
        ) WHERE ROWNUM <= C_MOVIMIENTOS
        UNION ALL
        SELECT * FROM (
          SELECT JSON_OBJECT(
                   'tipo'       VALUE 'Compra',
                   'documento'  VALUE f.NUMERO_FACTURA,
                   'parte'      VALUE pr.NOMBRE || NVL2(pr.APELLIDO, ' ' || pr.APELLIDO, ''),
                   'monto'      VALUE (SELECT NVL(SUM(SUBTOTAL), 0) FROM FACTURAS_COMPRAS_DET d WHERE d.ID_FACTURA = f.ID_FACTURA),
                   'enUnidades' VALUE 'N',
                   'fecha'      VALUE TO_CHAR(f.FECHA_FACTURA, 'YYYY-MM-DD'),
                   'estado'     VALUE CASE WHEN NVL((SELECT SUM(MONTO) FROM FACTURAS_COMPRAS_PAGOS p WHERE p.ID_FACTURA = f.ID_FACTURA), 0)
                                             >= (SELECT NVL(SUM(SUBTOTAL), 0) FROM FACTURAS_COMPRAS_DET d WHERE d.ID_FACTURA = f.ID_FACTURA)
                                           THEN 'Pagada' ELSE 'Pendiente' END
                   RETURNING CLOB) AS fila,
                 CAST(f.FECHA_FACTURA AS TIMESTAMP) AS orden
            FROM FACTURAS_COMPRAS_CAB f
            JOIN PERSONAS pr ON pr.ID_PERSONA = f.ID_PROVEEDOR
           WHERE f.ID_EMPRESA = l_empresa AND f.ID_SUCURSAL = l_sucursal
           ORDER BY f.FECHA_FACTURA DESC
        ) WHERE ROWNUM <= C_MOVIMIENTOS
        UNION ALL
        SELECT * FROM (
          SELECT JSON_OBJECT(
                   'tipo'       VALUE 'Inventario',
                   'documento'  VALUE 'INV-' || LPAD(TO_CHAR(i.ID_INVENTARIO), 6, '0'),
                   'parte'      VALUE a.NOMBRE_ARTICULO,
                   -- La DIFERENCIA, no lo contado: un conteo que coincide con el
                   -- sistema no es noticia; lo que importa es el faltante.
                   'monto'      VALUE NVL(i.CANTIDAD_FISICA, 0) - NVL(i.CANTIDAD_SISTEMA, 0),
                   'enUnidades' VALUE 'S',
                   'fecha'      VALUE TO_CHAR(i.FECHA_INVENTARIO, 'YYYY-MM-DD'),
                   'estado'     VALUE i.ESTADO
                   RETURNING CLOB) AS fila,
                 CAST(i.FECHA_INVENTARIO AS TIMESTAMP) AS orden
            FROM INVENTARIOS i
            LEFT JOIN ARTICULOS a ON a.ID_ARTICULO = i.ID_ARTICULO
           WHERE i.ID_EMPRESA = l_empresa AND i.ID_SUCURSAL = l_sucursal
           ORDER BY i.FECHA_INVENTARIO DESC
        ) WHERE ROWNUM <= C_MOVIMIENTOS
      );

    -- STOCK CRITICO: articulos con menos de C_UMBRAL_CRITICO unidades.
    -- Se muestran las UNIDADES, no un porcentaje: "quedan 2" dice que hacer,
    -- "18%" obliga a calcular sobre que.
    SELECT JSON_ARRAYAGG(fila ORDER BY disponible RETURNING CLOB) INTO l_criticos
      FROM (
        SELECT * FROM (
          SELECT JSON_OBJECT(
                   'idArticulo'     VALUE a.ID_ARTICULO,
                   'articulo'       VALUE a.NOMBRE_ARTICULO,
                   'codigo'         VALUE a.CODIGO_ARTICULO,
                   'disponible'     VALUE NVL(s.total, 0),
                   'cantidadMinima' VALUE a.CANTIDAD_MINIMA
                   RETURNING CLOB) AS fila,
                 NVL(s.total, 0) AS disponible
            FROM ARTICULOS a
            LEFT JOIN (SELECT ID_ARTICULO, SUM(NVL(CANTIDAD_DISPON, CANTIDAD)) AS total
                         FROM LOTES WHERE ID_EMPRESA = l_empresa AND ID_SUCURSAL = l_sucursal
                        GROUP BY ID_ARTICULO) s ON s.ID_ARTICULO = a.ID_ARTICULO
           WHERE a.ID_EMPRESA = l_empresa
             AND NVL(a.ES_GASTO, 'N') = 'N'
             AND NVL(s.total, 0) < C_UMBRAL_CRITICO
           ORDER BY NVL(s.total, 0)
        ) WHERE ROWNUM <= 10
      );

    p_status_code := 200;
    -- SELECT ... INTO y no una asignacion directa: `RETURNING CLOB` no se acepta
    -- en una expresion PL/SQL suelta (PLS-00684), solo dentro de una sentencia
    -- SQL. Es el mismo patron que usan los demas paquetes para armar el JSON.
    SELECT JSON_OBJECT(
             'ventasMes'           VALUE l_ventas,
             'ventasMesAnterior'   VALUE l_ventas_ant,
             'comprasMes'          VALUE l_compras,
             'comprasMesAnterior'  VALUE l_compras_ant,
             'valorStock'          VALUE l_stock,
             'unidadesStock'       VALUE l_stock_unidades,
             'articulosBajoMinimo' VALUE l_bajo_minimo,
             'cuotasPorVencer'      VALUE l_cuotas_cantidad,
             'montoPorVencer'       VALUE l_cuotas_monto,
             'diasPorVencer'        VALUE C_DIAS_POR_VENCER,
             'umbralCritico'        VALUE C_UMBRAL_CRITICO,
             'movimientos'          VALUE NVL(l_movimientos, TO_CLOB('[]')) FORMAT JSON,
             'stockCritico'         VALUE NVL(l_criticos, TO_CLOB('[]')) FORMAT JSON
             RETURNING CLOB)
      INTO p_resultado FROM DUAL;
  EXCEPTION WHEN OTHERS THEN
    p_status_code := 500; APEX_DEBUG.ERROR('PKG_DASHBOARD.RESUMEN: ' || SQLERRM); p_resultado := '{"error":"Error al calcular los indicadores"}';
  END RESUMEN;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;
    ORDS.DEFINE_MODULE(p_module_name => 'dashboard', p_base_path => '/dashboard/', p_items_per_page => 0, p_status => 'PUBLISHED', p_comments => 'Indicadores de la home');
    ORDS.SET_MODULE_ORIGINS_ALLOWED(p_module_name => 'dashboard', p_origins_allowed => 'https://www.ctell.online,http://localhost:8080');

    ORDS.DEFINE_TEMPLATE(p_module_name => 'dashboard', p_pattern => 'resumen');
    ORDS.DEFINE_HANDLER(p_module_name => 'dashboard', p_pattern => 'resumen', p_method => 'GET', p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN PKG_DASHBOARD.RESUMEN(:authorization, :idEmpresa, :idSucursal, :status_code, :resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name => 'dashboard', p_pattern => 'resumen', p_method => 'GET', p_name => 'authorization', p_bind_variable_name => 'authorization', p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
    ORDS.DEFINE_PARAMETER(p_module_name => 'dashboard', p_pattern => 'resumen', p_method => 'GET', p_name => 'resultado', p_bind_variable_name => 'resultado', p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
    ORDS.DEFINE_PARAMETER(p_module_name => 'dashboard', p_pattern => 'resumen', p_method => 'GET', p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code', p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');
    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_DASHBOARD;
/
BEGIN PKG_DASHBOARD.PUBLICAR_ENDPOINTS; END;
/

--------------------------------------------------------------------------------
-- Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS FROM USER_OBJECTS WHERE OBJECT_NAME = 'PKG_DASHBOARD' ORDER BY OBJECT_TYPE;

SELECT NAME, LINE, POSITION, TEXT FROM USER_ERRORS WHERE NAME = 'PKG_DASHBOARD' ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED FROM USER_ORDS_MODULES WHERE NAME = 'dashboard';
