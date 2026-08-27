--------------------------------------------------------------------------------
-- CTELL · FACTURAS DE COMPRA (cabecera + detalle)
--
-- Un paquete (PKG_FACTURAS_COMPRAS) que maneja las DOS tablas juntas, y la
-- publicacion de los endpoints ORDS.
--
--   1. LISTAR      GET    /facturas-compras/listar  (?idEmpresa= &idSucursal=
--                                                    &idProveedor= &desde= &hasta=)
--   2. OBTENER     GET    /facturas-compras/obtener/:id/:idEmpresa
--   3. INSERTAR    POST   /facturas-compras/crear
--   4. ACTUALIZAR  PUT    /facturas-compras/actualizar/:id
--   5. ELIMINAR    DELETE /facturas-compras/eliminar/:id/:idEmpresa
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX.
--
-- REQUIERE, EN ESTE ORDEN:
--   1. db/auth.sql              (PKG_AUTH: valida el token)
--   2. db/personas.sql          (el proveedor sale de PERSONAS)
--   3. db/iva.sql               (las tasas del detalle)
--   4. db/condiciones-pago.sql  (la condicion de pago de la cabecera)
--   ...y que existan EMPRESAS, SUCURSALES, MONEDAS y ARTICULOS, que ya estan.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/facturas-compras/
--
-- Tablas (no las crea ni las altera; el DDL se administra aparte):
--   FACTURAS_COMPRAS_CAB    ID_FACTURA, ID_EMPRESA, ID_SUCURSAL, ID_PROVEEDOR,
--                           NUMERO_FACTURA, FECHA_FACTURA, ID_MONEDA,
--                           TIP_CAMBIO, ID_CONDICION, OBSERVACION,
--                           FECHA_CREACION, FECHA_ACTUALIZACION
--   FACTURAS_COMPRAS_DET    ID_DETALLE, ID_FACTURA, ID_ARTICULO, CANTIDAD,
--                           PRECIO_UNITARIO, SUBTOTAL (VIRTUAL), ID_IVA,
--                           ID_LOTE, FECHA_CREACION
--   FACTURAS_COMPRAS_CUOTAS ID_CUOTA, ID_FACTURA, NRO_CUOTA, FECHA_VENCIMIENTO,
--                           MONTO_CUOTA, MONTO_PAGADO, SALDO_PENDIENTE (VIRTUAL),
--                           ESTADO, FECHA_CREACION, FECHA_ACTUALIZACION
--   FACTURAS_COMPRAS_PAGOS  ID_PAGO, ID_FACTURA, ID_CUOTA, ID_CANAL_PAGO,
--                           ID_CUENTA_BANCARIA, ID_MONEDA, MONTO, FECHA_PAGO,
--                           REFERENCIA, OBSERVACION, FECHA_CREACION,
--                           FECHA_ACTUALIZACION
--
--------------------------------------------------------------------------------
-- LA COMPRA ES LO QUE HACE ENTRAR EL STOCK
--
-- Cada linea del detalle crea SU PROPIO lote, con la cantidad comprada y el
-- precio unitario como costo. No se suma a un lote existente: cada compra entro
-- a un precio distinto, y mezclarlas perderia a cuanto entro cada unidad.
--
-- El lote nace sin NUMERO_LOTE ni FECHA_VENCIMIENTO —las dos columnas son
-- nullable y esos datos no vienen en la factura—. Se completan editando el lote
-- si hacen falta; el FIFO de ventas ordena por vencimiento y los deja al final
-- (NULLS LAST) mientras esten vacios.
--
-- FACTURAS_COMPRAS_DET.ID_LOTE es lo que ata la linea con el lote que creo. Sin
-- esa columna, borrar la factura no sabria que lote sacar del stock. Es la misma
-- solucion que VENTAS_DETALLES.ID_LOTE, en el otro sentido.
--
-- CORRER UNA VEZ EN APEX antes que este archivo:
--
--   ALTER TABLE FACTURAS_COMPRAS_DET ADD (ID_LOTE NUMBER);
--   ALTER TABLE FACTURAS_COMPRAS_DET ADD CONSTRAINT FCD_FK_LOTES
--     FOREIGN KEY (ID_LOTE) REFERENCES LOTES (ID_LOTE);
--
-- SI ALGO YA SALIO, LA FACTURA SE CONGELA. Editar el detalle o borrar la factura
-- rehace o elimina esos lotes, y eso no se puede si la mercaderia ya se vendio:
-- el stock quedaria por debajo del fisico, o habria unidades vendidas sin
-- ninguna compra que respalde su costo. Se detecta con CANTIDAD_DISPON <
-- CANTIDAD y se rechaza con 409. Igual que una factura con pagos registrados.
--
-- Las facturas cargadas ANTES de este cambio no tienen ID_LOTE ni trajeron
-- stock: borrarlas no saca nada, que es lo correcto para ellas.
--
--------------------------------------------------------------------------------
-- ES LA PRIMERA TRANSACCION DEL PROYECTO, Y ESO CAMBIA VARIAS COSAS
--
-- Hasta aca todas las tablas eran fichas independientes: un articulo, una
-- moneda, una persona. Una factura NO es una fila, es una CABECERA CON SUS
-- LINEAS, y las dos partes solo tienen sentido juntas. Eso obliga a tres
-- decisiones que ninguna tabla anterior necesito:
--
-- 1. EL DETALLE VIAJA COMO ARRAY JSON EN EL BODY, no como llamadas sueltas.
--    Guardar la cabecera y despues las lineas de a una permitiria que la red se
--    corte en el medio y quede una factura sin detalle —que no es una factura,
--    es basura—. Con el array, INSERTAR hace todo en UNA transaccion: o entra
--    completa o no entra nada.
--
--    Se parsea con JSON_TABLE. Si el JSON viene mal formado, el error se traduce
--    a 400 en vez de dejar salir un ORA-40441 crudo.
--
-- 2. ACTUALIZAR REEMPLAZA EL DETALLE ENTERO: borra las lineas y las vuelve a
--    insertar. Es deliberado, y la alternativa —comparar linea por linea cual
--    cambio, cual es nueva y cual se borro— es mucho codigo para el mismo
--    resultado. Una factura tiene cinco o diez lineas, no mil.
--
--    CONSECUENCIA: los ID_DETALLE cambian en cada edicion. No importa hoy
--    porque nada apunta al detalle; si algun dia algo lo hiciera, esta decision
--    hay que revisarla.
--
-- 3. ELIMINAR BORRA LAS DOS TABLAS, detalle primero. Al reves da ORA-02292: la
--    FK del detalle apunta a la cabecera, asi que mientras existan lineas la
--    cabecera no se puede borrar. El DDL no declara ON DELETE CASCADE, asi que
--    el orden lo tiene que poner el paquete.
--
--------------------------------------------------------------------------------
-- SUBTOTAL ES UNA COLUMNA VIRTUAL: NO SE PUEDE INSERTAR
--
-- El DDL la declara GENERATED ALWAYS AS (CANTIDAD*PRECIO_UNITARIO) VIRTUAL. La
-- calcula la base sola en cada lectura, y mencionarla en un INSERT o UPDATE da
-- ORA-54013 ("no se permite la operacion INSERT en una columna virtual").
--
-- Por eso el INSERT del detalle nombra solo CANTIDAD y PRECIO_UNITARIO. Esta
-- bien que sea asi: no hay forma de que el subtotal quede desincronizado de sus
-- factores, que es exactamente el problema que tendria una columna comun.
--
--------------------------------------------------------------------------------
-- LOS PRECIOS INCLUYEN IVA: EL IMPUESTO SE DESGLOSA, NO SE SUMA
--
-- Es como se factura en Paraguay, y es la razon de que la tabla IVA tenga DOS
-- divisores en vez de solo el porcentaje.
--
-- EL METODO ACTUAL: GRAVADO POR DIVISION, IVA POR RESTA
--
--     GRAVADO = ROUND(SUBTOTAL / GRAVADA_DIVISION, 2)   (1.1 al 10%, 1.05 al 5%)
--     IVA     = SUBTOTAL - GRAVADO
--
-- Con una linea de 110.000 al 10%:  gravado 100.000, IVA 10.000.
--
-- POR QUE EL IVA SE RESTA EN VEZ DE DIVIDIRSE POR IVA_DIVISION: las dos
-- divisiones redondean por separado, y sus redondeos son independientes — su
-- suma no tiene por que dar el subtotal. Con una division y una resta,
-- gravado + iva = total SIEMPRE, exacto. En un libro de compras una diferencia
-- de un guarani por linea se acumula y no cuadra contra el papel.
--
-- Y NUNCA `SUBTOTAL * PORCENTAJE / 100`, que cobraria impuesto sobre impuesto:
--     correcto:   110.000 - 110.000/1.1 = 10.000
--     incorrecto: 110.000 * 10 / 100    = 11.000
--
-- EL METODO ANTERIOR, PARA LAS TASAS SIN GRAVADA_DIVISION: esa columna es
-- NULLABLE y las tasas cargadas antes de que existiera la tienen vacia. Ahi se
-- cae al calculo viejo —IVA por division, gravado por resta— para que las
-- facturas cargadas antes sigan mostrando exactamente lo mismo:
--
--     IVA     = SUBTOTAL / IVA_DIVISION
--     GRAVADO = SUBTOTAL - IVA
--
-- La eleccion es POR FILA, con un CASE sobre GRAVADA_DIVISION, no global.
--
-- CONSECUENCIA PARA EL TOTAL: el total de la factura es la SUMA DE SUBTOTALES,
-- sin sumarle el IVA aparte — ya esta adentro. El desglose (gravado / impuesto)
-- se calcula para mostrarlo y para el libro de compras, no para totalizar.
--
-- TODA DIVISION VA PROTEGIDA CON NULLIF(..., 0): la tasa exenta tiene
-- IVA_DIVISION en 0, y sin el NULLIF cada factura con una linea exenta moriria
-- con ORA-01476 ("divisor igual a cero"). Con el NULLIF da NULL, y el NVL de
-- afuera lo convierte en 0 impuesto, que es lo correcto para una exenta.
--
-- OJO: en GRAVADA_DIVISION la exenta va en 1, NO en 0 — el monto entero es
-- gravado. Los dos divisores usan criterios opuestos para el mismo caso.
--
--------------------------------------------------------------------------------
-- LOS TOTALES NO SE GUARDAN: SE CALCULAN
--
-- La cabecera no tiene columna TOTAL, y esta bien. El total es la suma del
-- detalle, y guardarlo ademas permitiria que la cabecera diga 500.000 mientras
-- sus lineas suman 480.000 — una inconsistencia que nadie detecta hasta que
-- alguien cuadra la caja.
--
-- Es el mismo criterio que el stock de un articulo (SUM sobre sus lotes) y que
-- la diferencia de un inventario: si se puede derivar, se deriva.
--
--------------------------------------------------------------------------------
-- AISLAMIENTO POR EMPRESA
--
-- La cabecera tiene ID_EMPRESA, asi que se aplica la regla de siempre: OBTENER,
-- ACTUALIZAR y ELIMINAR lo exigen y lo llevan EN EL WHERE. La respuesta es 404 y
-- no 403: decir "existe pero no es tuya" ya confirma que el id existe.
--
-- EL DETALLE NO TIENE ID_EMPRESA y hereda la de su cabecera, como DETALLE_MONEDAS
-- con su moneda. Por eso ninguna operacion toca el detalle directamente: siempre
-- se llega a el a traves de la factura, que ya esta acotada por empresa.
--
-- CINCO FK QUE NO SE VALIDAN ENTRE SI. El DDL declara ID_EMPRESA, ID_SUCURSAL,
-- ID_PROVEEDOR e ID_MONEDA por separado, y ninguna mira a las otras: la base
-- acepta una factura de la empresa A con la sucursal y la moneda de la B. Se
-- valida a mano antes de escribir. El articulo del detalle, igual.
--
-- EL PROVEEDOR ES LA EXCEPCION: PERSONAS es un catalogo GLOBAL (no tiene
-- ID_EMPRESA), asi que cualquier empresa puede facturarle a cualquier persona.
-- Ahi solo se verifica que exista.
--
--------------------------------------------------------------------------------
-- EL UNIQUE ES (ID_PROVEEDOR, NUMERO_FACTURA, FECHA_FACTURA), SIN LA EMPRESA
--
-- Es correcto: el numero lo emite el PROVEEDOR, asi que dos facturas suyas con
-- el mismo numero y fecha son la misma factura, sin importar quien la recibio.
-- Impide cargar dos veces el mismo documento, que es el error mas comun.
--
-- CONSECUENCIA A TENER PRESENTE: si dos empresas del sistema le compran al mismo
-- proveedor y por algun motivo reciben el mismo numero de factura el mismo dia,
-- la segunda da 409. Es raro pero posible; el mensaje lo explica.
--
--------------------------------------------------------------------------------
-- ID_CONDICION: COMO SE PAGA LA FACTURA
--
-- FK a CONDICIONES_PAGO —contado, 30 dias, 3 cuotas—, y es NULLABLE: una factura
-- sin condicion cargada es valida. No se pone obligatoria porque el DDL no lo
-- exige y porque hay facturas cargadas antes de que la columna existiera.
--
-- CONDICIONES_PAGO ES UN CATALOGO GLOBAL (no tiene ID_EMPRESA), asi que solo se
-- verifica que la condicion exista — a diferencia de la sucursal y la moneda,
-- que ademas tienen que ser de la misma empresa que la factura.
--
-- EL VENCIMIENTO NO SE GUARDA, SE CALCULA: es FECHA_FACTURA + DIAS_PAGO, y el
-- listado lo devuelve ya resuelto como `fechaVencimiento`. Guardarlo dejaria una
-- columna que queda desfasada si despues se corrige la fecha de la factura o los
-- dias de la condicion — el mismo criterio que el total, que tampoco se guarda.
--
-- Con la condicion en NULL el vencimiento tambien viaja en NULL, no la fecha de
-- la factura: "no se sabe cuando vence" es distinto de "vence el mismo dia".
--
--------------------------------------------------------------------------------
-- LA FACTURA NO MUEVE STOCK
--
-- Guardar una factura de compra NO crea lotes ni toca CANTIDAD_DISPON. Es
-- deliberado y coincide con lo que el DDL sugiere: no hay FK a LOTES ni columna
-- de estado que distinga "ingresada" de "pendiente".
--
-- La factura es el DOCUMENTO; el ingreso al deposito se carga aparte en Lotes.
-- Si mañana se quiere que una cosa dispare la otra, el lugar es un procedimiento
-- nuevo (INGRESAR_A_STOCK) con su propio estado en la cabecera — no meterlo
-- adentro de INSERTAR, que dejaria sin forma de cargar una factura de servicios
-- o una nota de credito.
--
--------------------------------------------------------------------------------
-- COMO EJECUTAR
--
--   1. Frena `npm run dev` (evita ORA-00060 al borrar el modulo).
--   2. Corre db/iva.sql si todavia no lo hiciste, y carga las tasas.
--   3. Pega este archivo entero en la hoja SQL de APEX y ejecutalo.
--   4. Revisa que PKG_FACTURAS_COMPRAS quede VALID y USER_ERRORS vacio.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_FACTURAS_COMPRAS AS

  -- Todos los filtros son opcionales y se combinan. p_desde y p_hasta acotan por
  -- FECHA_FACTURA en ISO ("2026-08-19"), inclusive los dos extremos.
  --
  -- Devuelve las CABECERAS con su total calculado, sin el detalle: un listado de
  -- cien facturas con todas sus lineas seria un CLOB enorme para mostrar una
  -- tabla que solo necesita el encabezado. El detalle se pide con OBTENER.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_id_proveedor  IN  VARCHAR2,
    p_desde         IN  VARCHAR2,
    p_hasta         IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Una factura CON su detalle y sus totales desglosados. Es lo que pide la
  -- pantalla al abrir una factura para verla o editarla.
  PROCEDURE OBTENER (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Crea la cabecera y su detalle en UNA transaccion.
  --
  -- p_detalle es un array JSON:
  --   [{"idArticulo":1,"cantidad":10,"precioUnitario":5500,"idIva":1}, ...]
  --
  -- Una factura SIN lineas se rechaza con 400: no es una factura.
  PROCEDURE INSERTAR (
    p_authorization   IN  VARCHAR2,
    p_id_empresa      IN  VARCHAR2,
    p_id_sucursal     IN  VARCHAR2,
    p_id_proveedor    IN  VARCHAR2,
    p_numero_factura  IN  VARCHAR2,
    p_fecha_factura   IN  VARCHAR2,
    p_id_moneda       IN  VARCHAR2,
    p_tip_cambio      IN  VARCHAR2,
    p_id_condicion    IN  VARCHAR2,
    p_observacion     IN  VARCHAR2,
    p_detalle         IN  CLOB,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  );

  -- Modifica la cabecera y REEMPLAZA el detalle entero (ver la cabecera del
  -- archivo). Los campos ausentes de la cabecera no se modifican; p_detalle
  -- ausente deja el detalle como estaba.
  PROCEDURE ACTUALIZAR (
    p_authorization   IN  VARCHAR2,
    p_id              IN  VARCHAR2,
    p_id_empresa      IN  VARCHAR2,
    p_id_sucursal     IN  VARCHAR2,
    p_id_proveedor    IN  VARCHAR2,
    p_numero_factura  IN  VARCHAR2,
    p_fecha_factura   IN  VARCHAR2,
    p_id_moneda       IN  VARCHAR2,
    p_tip_cambio      IN  VARCHAR2,
    p_id_condicion    IN  VARCHAR2,
    p_observacion     IN  VARCHAR2,
    p_detalle         IN  CLOB,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  );

  -- Borra la factura y su detalle. Baja fisica: las tablas no tienen estado.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /facturas-compras/ con sus endpoints.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_FACTURAS_COMPRAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_FACTURAS_COMPRAS AS

  -- Una sola constante para TO_DATE y TO_CHAR: si las dos mascaras se
  -- desincronizaran, lo que se guarda y lo que se devuelve dejarian de coincidir
  -- y el bug seria invisible hasta que alguien compare fechas.
  C_FORMATO_FECHA CONSTANT VARCHAR2(20) := 'YYYY-MM-DD';

  ------------------------------------------------------------------------------
  -- Privado: borra el modulo ORDS si existe, reintentando ante un interbloqueo.
  ------------------------------------------------------------------------------
  PROCEDURE BORRAR_MODULO IS
    C_INTENTOS CONSTANT PLS_INTEGER := 3;
    l_existe   PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. C_INTENTOS LOOP
      BEGIN
        SELECT COUNT(*)
          INTO l_existe
          FROM USER_ORDS_MODULES
         WHERE NAME = 'facturas-compras';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'facturas-compras');
        COMMIT;
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
          IF SQLCODE IN (-60, -4020) AND i < C_INTENTOS THEN
            ROLLBACK;
            DBMS_SESSION.SLEEP(2);
          ELSE
            RAISE;
          END IF;
      END;
    END LOOP;
  END BORRAR_MODULO;

  ------------------------------------------------------------------------------
  -- Privado: "2026-08-19" -> DATE. NULL si el texto no es una fecha valida.
  --
  -- SUBSTR a 10 para aceptar tambien un ISO con hora ("2026-08-19T00:00:00"),
  -- que es lo que manda un input de fecha en algunos navegadores.
  ------------------------------------------------------------------------------
  FUNCTION A_FECHA (p_texto IN VARCHAR2) RETURN DATE IS
  BEGIN
    IF TRIM(p_texto) IS NULL THEN
      RETURN NULL;
    END IF;

    RETURN TO_DATE(SUBSTR(TRIM(p_texto), 1, 10), C_FORMATO_FECHA);
  EXCEPTION
    WHEN OTHERS THEN
      RETURN NULL;
  END A_FECHA;

  ------------------------------------------------------------------------------
  -- Privado: la sucursal existe y es de esa empresa.
  ------------------------------------------------------------------------------
  FUNCTION SUCURSAL_ES_DE_EMPRESA (
    p_id_sucursal IN NUMBER,
    p_id_empresa  IN NUMBER
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO l_existe
      FROM SUCURSALES
     WHERE ID_SUCURSAL = p_id_sucursal
       AND ID_EMPRESA  = p_id_empresa;

    RETURN l_existe > 0;
  END SUCURSAL_ES_DE_EMPRESA;

  ------------------------------------------------------------------------------
  -- Privado: la moneda existe y es de esa empresa.
  ------------------------------------------------------------------------------
  FUNCTION MONEDA_ES_DE_EMPRESA (
    p_id_moneda  IN NUMBER,
    p_id_empresa IN NUMBER
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO l_existe
      FROM MONEDAS
     WHERE ID_MONEDA  = p_id_moneda
       AND ID_EMPRESA = p_id_empresa;

    RETURN l_existe > 0;
  END MONEDA_ES_DE_EMPRESA;

  ------------------------------------------------------------------------------
  -- Privado: guarda el detalle de una factura a partir del array JSON.
  --
  -- Lo comparten INSERTAR y ACTUALIZAR. Devuelve el error en p_error (NULL si
  -- salio bien) en vez de lanzar una excepcion: el llamador tiene que poder
  -- hacer ROLLBACK de la cabecera tambien, y con un RAISE se perderia el control
  -- del mensaje que ve el usuario.
  --
  -- NO HACE COMMIT NI ROLLBACK: la transaccion la maneja quien lo llama, que es
  -- justamente el punto de que cabecera y detalle entren juntos.
  ------------------------------------------------------------------------------
  -- Privado: TRUE si algun lote que trajo esta factura ya tuvo salidas.
  --
  -- Se detecta con CANTIDAD_DISPON < CANTIDAD: el lote nace con las dos iguales,
  -- y toda venta baja la primera. Es la condicion que bloquea editar y borrar —
  -- deshacer una compra cuya mercaderia ya se vendio dejaria el stock por debajo
  -- de lo fisico, o un lote huerfano sin factura que respalde su costo.
  FUNCTION TIENE_SALIDAS (p_id_factura IN NUMBER) RETURN BOOLEAN IS
    l_con_salidas PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO l_con_salidas
      FROM FACTURAS_COMPRAS_DET d
      JOIN LOTES lo ON lo.ID_LOTE = d.ID_LOTE
     WHERE d.ID_FACTURA = p_id_factura
       AND NVL(lo.CANTIDAD_DISPON, lo.CANTIDAD) < lo.CANTIDAD;
    RETURN l_con_salidas > 0;
  END TIENE_SALIDAS;

  -- Privado: borra los lotes que trajo la factura, junto con sus lineas.
  --
  -- El orden es al reves de la FK: primero las lineas que apuntan al lote, y
  -- recien despues el lote. Al reves da ORA-02292.
  PROCEDURE BORRAR_DETALLE_Y_LOTES (p_id_factura IN NUMBER) IS
    TYPE t_ids IS TABLE OF NUMBER;
    l_lotes t_ids;
  BEGIN
    SELECT ID_LOTE BULK COLLECT INTO l_lotes
      FROM FACTURAS_COMPRAS_DET WHERE ID_FACTURA = p_id_factura AND ID_LOTE IS NOT NULL;
    DELETE FROM FACTURAS_COMPRAS_DET WHERE ID_FACTURA = p_id_factura;
    FORALL i IN 1 .. l_lotes.COUNT
      DELETE FROM LOTES WHERE ID_LOTE = l_lotes(i);
  END BORRAR_DETALLE_Y_LOTES;

  -- Privado: rehace las cuotas de la factura segun su condicion de pago.
  --
  -- Se borran y se generan de nuevo en vez de ajustarse: el total pudo cambiar
  -- al editar el detalle, y repartir un total nuevo sobre cuotas viejas deja
  -- montos que no suman la factura. Sin condicion de pago no hay cuotas — es una
  -- factura al contado.
  PROCEDURE REGENERAR_CUOTAS (p_id_factura IN NUMBER) IS
    l_condicion NUMBER; l_dias NUMBER := 0; l_cuotas NUMBER := 1;
    l_total NUMBER; l_fecha DATE;
  BEGIN
    SELECT ID_CONDICION, FECHA_FACTURA INTO l_condicion, l_fecha
      FROM FACTURAS_COMPRAS_CAB WHERE ID_FACTURA = p_id_factura;
    DELETE FROM FACTURAS_COMPRAS_CUOTAS WHERE ID_FACTURA = p_id_factura;
    IF l_condicion IS NULL THEN RETURN; END IF;
    SELECT NVL(SUM(SUBTOTAL), 0) INTO l_total FROM FACTURAS_COMPRAS_DET WHERE ID_FACTURA = p_id_factura;
    -- El CHECK del DDL exige MONTO_CUOTA > 0: una factura en cero no lleva cuotas.
    IF l_total <= 0 THEN RETURN; END IF;
    SELECT NVL(DIAS_PAGO, 0), NVL(CANTIDAD_CUOTAS, 1) INTO l_dias, l_cuotas
      FROM CONDICIONES_PAGO WHERE ID_CONDICION = l_condicion;
    IF l_cuotas < 1 THEN l_cuotas := 1; END IF;
    FOR n IN 1 .. l_cuotas LOOP
      INSERT INTO FACTURAS_COMPRAS_CUOTAS (ID_FACTURA, NRO_CUOTA, FECHA_VENCIMIENTO, MONTO_CUOTA, MONTO_PAGADO, ESTADO)
        VALUES (p_id_factura, n, l_fecha + (l_dias * n), ROUND(l_total / l_cuotas, 2), 0, 'PENDIENTE');
    END LOOP;
  END REGENERAR_CUOTAS;

  PROCEDURE GUARDAR_DETALLE (
    p_id_factura  IN  NUMBER,
    p_id_empresa  IN  NUMBER,
    p_id_sucursal IN  NUMBER,
    p_detalle     IN  CLOB,
    p_lineas      OUT NUMBER,
    p_error       OUT VARCHAR2
  ) IS
    l_lineas PLS_INTEGER := 0;
    l_id_lote NUMBER;
  BEGIN
    p_error  := NULL;
    p_lineas := 0;

    -- Se recorre el JSON con JSON_TABLE y se valida CADA linea antes de
    -- insertarla. Validar dentro del bucle y no despues es lo que permite decir
    -- QUE linea esta mal: "la cantidad de la linea 3 es negativa" se corrige,
    -- "hay una cantidad negativa" obliga a buscarla.
    FOR linea IN (
      SELECT d.nro, d.idArticulo, d.cantidad, d.precioUnitario, d.idIva
        FROM JSON_TABLE(
               p_detalle, '$[*]'
               COLUMNS (
                 -- FOR ORDINALITY y no ROWNUM: da la posicion REAL dentro del
                 -- array, que es la que el usuario ve en el formulario. ROWNUM
                 -- se asigna al leer y puede no coincidir con el orden del JSON,
                 -- asi que un mensaje de error apuntaria a la linea equivocada.
                 nro            FOR ORDINALITY,
                 idArticulo     NUMBER PATH '$.idArticulo',
                 cantidad       NUMBER PATH '$.cantidad',
                 precioUnitario NUMBER PATH '$.precioUnitario',
                 idIva          NUMBER PATH '$.idIva'
               )
             ) d
    ) LOOP
      l_lineas := l_lineas + 1;

      IF linea.idArticulo IS NULL THEN
        p_error := 'La linea ' || linea.nro || ' no tiene articulo';
        RETURN;
      END IF;

      -- CANTIDAD y PRECIO_UNITARIO son NOT NULL en el DDL: sin este chequeo el
      -- INSERT falla con ORA-01400, que llega al usuario como un 500 sin decir
      -- cual de las dos falto.
      IF linea.cantidad IS NULL OR linea.precioUnitario IS NULL THEN
        p_error := 'La linea ' || linea.nro || ' necesita cantidad y precio unitario';
        RETURN;
      END IF;

      -- Cantidad CERO no es valida: una linea que no compra nada no deberia
      -- existir. El precio SI puede ser 0 (una bonificacion, un articulo sin
      -- cargo), asi que solo se rechaza el negativo.
      IF linea.cantidad <= 0 THEN
        p_error := 'La cantidad de la linea ' || linea.nro || ' tiene que ser mayor a cero';
        RETURN;
      END IF;

      IF linea.precioUnitario < 0 THEN
        p_error := 'El precio de la linea ' || linea.nro || ' no puede ser negativo';
        RETURN;
      END IF;

      -- EL ARTICULO TIENE QUE SER DE LA MISMA EMPRESA QUE LA FACTURA. El DDL no
      -- lo impide: la FK del detalle apunta a ARTICULOS sin mirar la empresa, y
      -- la factura tiene la suya en la cabecera. Sin esto se podria facturar un
      -- articulo de otra empresa mandando su id a mano.
      DECLARE
        l_existe PLS_INTEGER;
      BEGIN
        SELECT COUNT(*) INTO l_existe
          FROM ARTICULOS
         WHERE ID_ARTICULO = linea.idArticulo
           AND ID_EMPRESA  = p_id_empresa;

        IF l_existe = 0 THEN
          p_error := 'El articulo de la linea ' || linea.nro || ' no existe en esta empresa';
          RETURN;
        END IF;
      END;

      -- LA COMPRA ES LO QUE HACE ENTRAR EL STOCK: cada linea crea SU PROPIO
      -- lote. No se suma a un lote existente porque cada compra tiene su costo,
      -- y mezclarlas perderia a que precio entro cada unidad.
      --
      -- Sin numero de lote ni vencimiento: las dos columnas son nullable y esos
      -- datos no viajan en la factura. Se completan editando el lote si hace
      -- falta —el FIFO de ventas los ordena por vencimiento, y sin el quedan al
      -- final (NULLS LAST)—.
      --
      -- CANTIDAD_DISPON arranca igual a CANTIDAD: nada se consumio todavia. Esa
      -- igualdad es despues la que dice si el lote tuvo salidas, y por lo tanto
      -- si la factura se puede editar o borrar.
      INSERT INTO LOTES (
        ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO, CANTIDAD, CANTIDAD_DISPON, COSTO,
        FECHA_ENTRADA, FECHA_CREACION, FECHA_ACTUALIZACION
      ) VALUES (
        p_id_empresa, p_id_sucursal, linea.idArticulo, linea.cantidad, linea.cantidad,
        linea.precioUnitario, SYSDATE, SYSTIMESTAMP, SYSTIMESTAMP
      ) RETURNING ID_LOTE INTO l_id_lote;

      -- SUBTOTAL NO SE MENCIONA: es una columna virtual y mencionarla da
      -- ORA-54013. La calcula la base como CANTIDAD*PRECIO_UNITARIO.
      INSERT INTO FACTURAS_COMPRAS_DET (
        ID_FACTURA, ID_ARTICULO, CANTIDAD, PRECIO_UNITARIO, ID_IVA, ID_LOTE, FECHA_CREACION
      ) VALUES (
        p_id_factura,
        linea.idArticulo,
        linea.cantidad,
        linea.precioUnitario,
        linea.idIva,
        l_id_lote,
        SYSTIMESTAMP
      );
    END LOOP;

    p_lineas := l_lineas;
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      -- El UNIQUE es (ID_FACTURA, ID_ARTICULO): el mismo articulo dos veces en
      -- la misma factura. Es un error de carga tipico y el mensaje lo dice.
      p_error := 'Hay un articulo repetido en el detalle: cada articulo va una sola vez';
    WHEN OTHERS THEN
      IF SQLCODE = -2291 THEN
        -- ORA-02291: el articulo o la tasa de IVA no existen.
        p_error := 'Algun articulo o tasa de IVA del detalle no existe';
      ELSIF SQLCODE IN (-40441, -40442, -40444) THEN
        -- Errores de parseo de JSON_TABLE: el array vino mal formado.
        p_error := 'El detalle no tiene un formato valido';
      ELSE
        APEX_DEBUG.ERROR('PKG_FACTURAS_COMPRAS.GUARDAR_DETALLE: [' || SQLCODE || '] ' ||
                         SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_error := 'Error al guardar el detalle de la factura';
      END IF;
  END GUARDAR_DETALLE;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_id_proveedor  IN  VARCHAR2,
    p_desde         IN  VARCHAR2,
    p_hasta         IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion       NUMBER;
    l_id_empresa   NUMBER;
    l_id_sucursal  NUMBER;
    l_id_proveedor NUMBER;
    l_desde        DATE;
    l_hasta        DATE;
    l_total        NUMBER;
    l_items        CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van dentro del BEGIN: en el DECLARE se ejecutarian antes
    -- de que exista el EXCEPTION y el error escaparia del procedimiento.
    l_id_empresa   := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_sucursal  := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    l_id_proveedor := TO_NUMBER(NULLIF(p_id_proveedor, ''));
    l_desde        := A_FECHA(p_desde);
    l_hasta        := A_FECHA(p_hasta);

    SELECT COUNT(*)
      INTO l_total
      FROM FACTURAS_COMPRAS_CAB
     WHERE (l_id_empresa   IS NULL OR ID_EMPRESA   = l_id_empresa)
       AND (l_id_sucursal  IS NULL OR ID_SUCURSAL  = l_id_sucursal)
       AND (l_id_proveedor IS NULL OR ID_PROVEEDOR = l_id_proveedor)
       AND (l_desde        IS NULL OR FECHA_FACTURA >= l_desde)
       AND (l_hasta        IS NULL OR FECHA_FACTURA <= l_hasta);

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- se materializa como VARCHAR2 y revienta al pasar los 4000 bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY fecha DESC, id DESC RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'             VALUE f.ID_FACTURA,
                 'idEmpresa'      VALUE f.ID_EMPRESA,
                 'idSucursal'     VALUE f.ID_SUCURSAL,
                 'nombreSucursal' VALUE s.NOMBRE_SUCURSAL,
                 'idProveedor'    VALUE f.ID_PROVEEDOR,
                 -- El nombre que corresponde segun el tipo de persona, con la
                 -- misma regla que usa PKG_PERSONAS. Se resuelve aca para que la
                 -- pantalla no la repita —ni la olvide.
                 'proveedor'      VALUE CASE
                                          WHEN NVL(UPPER(TRIM(pr.TIPO_PERSONA)), 'F') = 'J'
                                          THEN NVL(pr.RAZON_SOCIAL, pr.NOMBRE)
                                          ELSE TRIM(pr.NOMBRE || ' ' ||
                                                    CASE WHEN TRIM(pr.APELLIDO) = '-'
                                                         THEN NULL ELSE pr.APELLIDO END)
                                        END,
                 'rucProveedor'   VALUE pr.RUC,
                 'numeroFactura'  VALUE f.NUMERO_FACTURA,
                 -- TO_CHAR y no la columna pelada: una DATE cruda sale en el
                 -- JSON con el formato NLS de la sesion ('19-AGO-26'), que
                 -- `new Date()` no parsea y deja "Invalid Date" en pantalla.
                 'fechaFactura'   VALUE TO_CHAR(f.FECHA_FACTURA, C_FORMATO_FECHA),
                 'idMoneda'       VALUE f.ID_MONEDA,
                 'moneda'         VALUE m.NOMBRE_MONEDA,
                 'simboloMoneda'  VALUE m.SIMBOLO,
                 'tipoCambio'     VALUE f.TIP_CAMBIO,
                 'idCondicion'    VALUE f.ID_CONDICION,
                 'condicionPago'  VALUE cp.NOMBRE_CONDICION,
                 'diasPago'       VALUE cp.DIAS_PAGO,
                 -- VENCIMIENTO CALCULADO, no una columna: fecha + dias. Guardarlo
                 -- dejaria un dato que queda desfasado si se corrige la fecha de
                 -- la factura o los dias de la condicion.
                 --
                 -- Sin condicion queda NULL, no la fecha de la factura: "no se
                 -- sabe cuando vence" es distinto de "vence el mismo dia".
                 'fechaVencimiento' VALUE TO_CHAR(f.FECHA_FACTURA + cp.DIAS_PAGO,
                                                  C_FORMATO_FECHA),
                 'observacion'    VALUE f.OBSERVACION,
                 -- TOTAL CALCULADO, no una columna: la suma del detalle. Ver la
                 -- nota de la cabecera sobre por que no se guarda.
                 --
                 -- Los precios YA INCLUYEN IVA, asi que el total es la suma de
                 -- subtotales y no se le suma el impuesto aparte.
                 --
                 -- NVL a 0: una factura sin lineas no deberia existir (INSERTAR
                 -- lo impide) pero si alguna quedo asi, SUM devuelve NULL y el
                 -- frontend recibiria null en vez de un numero.
                 'total'          VALUE NVL((SELECT SUM(d.SUBTOTAL)
                                               FROM FACTURAS_COMPRAS_DET d
                                              WHERE d.ID_FACTURA = f.ID_FACTURA), 0),
                 -- Cuantas lineas tiene, para mostrarlo en el listado sin
                 -- traerse el detalle entero.
                 'lineas'         VALUE (SELECT COUNT(*)
                                           FROM FACTURAS_COMPRAS_DET d
                                          WHERE d.ID_FACTURA = f.ID_FACTURA)
                 RETURNING CLOB
               ) AS fila,
               f.FECHA_FACTURA AS fecha,
               f.ID_FACTURA    AS id
          FROM FACTURAS_COMPRAS_CAB f
          JOIN SUCURSALES s  ON s.ID_SUCURSAL = f.ID_SUCURSAL
          JOIN PERSONAS   pr ON pr.ID_PERSONA = f.ID_PROVEEDOR
          JOIN MONEDAS    m  ON m.ID_MONEDA   = f.ID_MONEDA
          -- LEFT en la condicion, interno en los otros tres: ID_CONDICION es
          -- NULLABLE. Con JOIN interno, las facturas sin condicion —incluidas
          -- todas las cargadas antes de que existiera la columna— desaparecerian
          -- del listado sin ningun error visible.
          LEFT JOIN CONDICIONES_PAGO cp ON cp.ID_CONDICION = f.ID_CONDICION
         WHERE (l_id_empresa   IS NULL OR f.ID_EMPRESA   = l_id_empresa)
           AND (l_id_sucursal  IS NULL OR f.ID_SUCURSAL  = l_id_sucursal)
           AND (l_id_proveedor IS NULL OR f.ID_PROVEEDOR = l_id_proveedor)
           AND (l_desde        IS NULL OR f.FECHA_FACTURA >= l_desde)
           AND (l_hasta        IS NULL OR f.FECHA_FACTURA <= l_hasta)
      );

    p_status_code := 200;
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
      APEX_DEBUG.ERROR('PKG_FACTURAS_COMPRAS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las facturas"}';
  END LISTAR;

  PROCEDURE OBTENER (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id         NUMBER;
    l_id_empresa NUMBER;
    l_existe     PLS_INTEGER;
    l_detalle    CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id         := TO_NUMBER(NULLIF(p_id, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    IF l_id IS NULL OR l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    -- El AND ID_EMPRESA es el aislamiento. 404 y no 403: decir "existe pero no
    -- es tuya" ya confirma que el id existe.
    SELECT COUNT(*) INTO l_existe
      FROM FACTURAS_COMPRAS_CAB
     WHERE ID_FACTURA = l_id
       AND ID_EMPRESA = l_id_empresa;

    IF l_existe = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La factura no existe"}';
      RETURN;
    END IF;

    -- El detalle se arma aparte y se inyecta con FORMAT JSON: anidar un
    -- JSON_ARRAYAGG dentro del JSON_OBJECT de la cabecera vuelve a caer en el
    -- limite de 4000 bytes del resultado intermedio.
    SELECT JSON_ARRAYAGG(fila ORDER BY id RETURNING CLOB)
      INTO l_detalle
      FROM (
        SELECT JSON_OBJECT(
                 'id'                VALUE d.ID_DETALLE,
                 'idArticulo'        VALUE d.ID_ARTICULO,
                 'nombreArticulo'    VALUE a.NOMBRE_ARTICULO,
                 'codigoArticulo'    VALUE a.CODIGO_ARTICULO,
                 'cantidad'          VALUE d.CANTIDAD,
                 'precioUnitario'    VALUE d.PRECIO_UNITARIO,
                 -- COLUMNA VIRTUAL: la calcula la base. No se puede insertar,
                 -- pero se lee como cualquier otra.
                 'subtotal'          VALUE d.SUBTOTAL,
                 'idIva'             VALUE d.ID_IVA,
                 'porcentajeIva'     VALUE iv.PORCENTAJE,
                 'descripcionIva'    VALUE iv.DESCRIPCION,
                 -- EL DESGLOSE. Ver la nota de la cabecera: con GRAVADA_DIVISION
                 -- cargada, el GRAVADO se divide y el IVA sale por RESTA —asi
                 -- gravado + iva da el subtotal exacto—. Sin ella (tasas viejas)
                 -- se cae al metodo anterior, invertido.
                 --
                 -- NULLIF protege las dos divisiones: la exenta tiene
                 -- IVA_DIVISION en 0, y sin el NULLIF seria ORA-01476.
                 'montoGravado'      VALUE CASE
                                             WHEN iv.GRAVADA_DIVISION IS NOT NULL
                                             THEN ROUND(d.SUBTOTAL /
                                                        NULLIF(iv.GRAVADA_DIVISION, 0), 2)
                                             ELSE d.SUBTOTAL -
                                                  NVL(ROUND(d.SUBTOTAL /
                                                      NULLIF(iv.IVA_DIVISION, 0), 2), 0)
                                           END,
                 'montoIva'          VALUE CASE
                                             WHEN iv.GRAVADA_DIVISION IS NOT NULL
                                             THEN d.SUBTOTAL -
                                                  ROUND(d.SUBTOTAL /
                                                        NULLIF(iv.GRAVADA_DIVISION, 0), 2)
                                             ELSE NVL(ROUND(d.SUBTOTAL /
                                                      NULLIF(iv.IVA_DIVISION, 0), 2), 0)
                                           END
                 RETURNING CLOB
               ) AS fila,
               d.ID_DETALLE AS id
          FROM FACTURAS_COMPRAS_DET d
          JOIN ARTICULOS a ON a.ID_ARTICULO = d.ID_ARTICULO
          -- LEFT en IVA: la columna ID_IVA es NULLABLE en el DDL, asi que una
          -- linea sin tasa asignada existe. Con JOIN interno esa linea
          -- desapareceria del detalle y la factura mostraria menos de lo que
          -- tiene, sin ningun error.
          LEFT JOIN IVA iv ON iv.ID_IVA = d.ID_IVA
         WHERE d.ID_FACTURA = l_id
      );

    SELECT JSON_OBJECT(
             'id'             VALUE f.ID_FACTURA,
             'idEmpresa'      VALUE f.ID_EMPRESA,
             'idSucursal'     VALUE f.ID_SUCURSAL,
             'nombreSucursal' VALUE s.NOMBRE_SUCURSAL,
             'idProveedor'    VALUE f.ID_PROVEEDOR,
             'proveedor'      VALUE CASE
                                      WHEN NVL(UPPER(TRIM(pr.TIPO_PERSONA)), 'F') = 'J'
                                      THEN NVL(pr.RAZON_SOCIAL, pr.NOMBRE)
                                      ELSE TRIM(pr.NOMBRE || ' ' ||
                                                CASE WHEN TRIM(pr.APELLIDO) = '-'
                                                     THEN NULL ELSE pr.APELLIDO END)
                                    END,
             'rucProveedor'   VALUE pr.RUC,
             'numeroFactura'  VALUE f.NUMERO_FACTURA,
             'fechaFactura'   VALUE TO_CHAR(f.FECHA_FACTURA, C_FORMATO_FECHA),
             'idMoneda'       VALUE f.ID_MONEDA,
             'moneda'         VALUE m.NOMBRE_MONEDA,
             'simboloMoneda'  VALUE m.SIMBOLO,
             'tipoCambio'     VALUE f.TIP_CAMBIO,
             'idCondicion'    VALUE f.ID_CONDICION,
             'condicionPago'  VALUE cp.NOMBRE_CONDICION,
             'diasPago'       VALUE cp.DIAS_PAGO,
             'cantidadCuotas' VALUE cp.CANTIDAD_CUOTAS,
             'fechaVencimiento' VALUE TO_CHAR(f.FECHA_FACTURA + cp.DIAS_PAGO,
                                              C_FORMATO_FECHA),
             'observacion'    VALUE f.OBSERVACION,
             -- Los tres totales, calculados sobre el detalle. Se devuelven ya
             -- resueltos para que la pantalla no repita la formula del IVA —que
             -- es justo donde es facil equivocarse.
             'total'          VALUE NVL((SELECT SUM(d.SUBTOTAL)
                                           FROM FACTURAS_COMPRAS_DET d
                                          WHERE d.ID_FACTURA = f.ID_FACTURA), 0),
             -- Los dos totales usan el MISMO CASE que cada linea, no una formula
             -- propia: si divergieran, la suma de las lineas no coincidiria con
             -- el total del pie y el desglose dejaria de cuadrar contra si mismo.
             'totalGravado'   VALUE NVL((SELECT SUM(CASE
                                                      WHEN i2.GRAVADA_DIVISION IS NOT NULL
                                                      THEN ROUND(d.SUBTOTAL /
                                                           NULLIF(i2.GRAVADA_DIVISION, 0), 2)
                                                      ELSE d.SUBTOTAL -
                                                           NVL(ROUND(d.SUBTOTAL /
                                                           NULLIF(i2.IVA_DIVISION, 0), 2), 0)
                                                    END)
                                           FROM FACTURAS_COMPRAS_DET d
                                           LEFT JOIN IVA i2 ON i2.ID_IVA = d.ID_IVA
                                          WHERE d.ID_FACTURA = f.ID_FACTURA), 0),
             'totalIva'       VALUE NVL((SELECT SUM(CASE
                                                      WHEN i2.GRAVADA_DIVISION IS NOT NULL
                                                      THEN d.SUBTOTAL -
                                                           ROUND(d.SUBTOTAL /
                                                           NULLIF(i2.GRAVADA_DIVISION, 0), 2)
                                                      ELSE NVL(ROUND(d.SUBTOTAL /
                                                           NULLIF(i2.IVA_DIVISION, 0), 2), 0)
                                                    END)
                                           FROM FACTURAS_COMPRAS_DET d
                                           LEFT JOIN IVA i2 ON i2.ID_IVA = d.ID_IVA
                                          WHERE d.ID_FACTURA = f.ID_FACTURA), 0),
             'detalle'        VALUE NVL(l_detalle, TO_CLOB('[]')) FORMAT JSON
             RETURNING CLOB
           )
      INTO p_resultado
      FROM FACTURAS_COMPRAS_CAB f
      JOIN SUCURSALES s  ON s.ID_SUCURSAL = f.ID_SUCURSAL
      JOIN PERSONAS   pr ON pr.ID_PERSONA = f.ID_PROVEEDOR
      JOIN MONEDAS    m  ON m.ID_MONEDA   = f.ID_MONEDA
      -- LEFT: la condicion es opcional. Con JOIN interno, abrir una factura sin
      -- condicion devolveria NO_DATA_FOUND y la pantalla diria que no existe.
      LEFT JOIN CONDICIONES_PAGO cp ON cp.ID_CONDICION = f.ID_CONDICION
     WHERE f.ID_FACTURA = l_id
       AND f.ID_EMPRESA = l_id_empresa;

    p_status_code := 200;
  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_FACTURAS_COMPRAS.OBTENER: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al obtener la factura"}';
  END OBTENER;

  PROCEDURE INSERTAR (
    p_authorization   IN  VARCHAR2,
    p_id_empresa      IN  VARCHAR2,
    p_id_sucursal     IN  VARCHAR2,
    p_id_proveedor    IN  VARCHAR2,
    p_numero_factura  IN  VARCHAR2,
    p_fecha_factura   IN  VARCHAR2,
    p_id_moneda       IN  VARCHAR2,
    p_tip_cambio      IN  VARCHAR2,
    p_id_condicion    IN  VARCHAR2,
    p_observacion     IN  VARCHAR2,
    p_detalle         IN  CLOB,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  ) IS
    l_sesion       NUMBER;
    l_id_empresa   NUMBER;
    l_id_sucursal  NUMBER;
    l_id_proveedor NUMBER;
    l_id_moneda    NUMBER;
    l_tip_cambio   NUMBER;
    l_id_condicion NUMBER;
    l_fecha        DATE;
    l_existe       PLS_INTEGER;
    l_id           NUMBER;
    l_lineas       NUMBER;
    l_error        VARCHAR2(500);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_empresa   := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_sucursal  := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    l_id_proveedor := TO_NUMBER(NULLIF(p_id_proveedor, ''));
    l_id_moneda    := TO_NUMBER(NULLIF(p_id_moneda, ''));
    l_tip_cambio   := TO_NUMBER(NULLIF(p_tip_cambio, ''));
    l_id_condicion := TO_NUMBER(NULLIF(p_id_condicion, ''));
    l_fecha        := A_FECHA(p_fecha_factura);

    -- Las seis columnas NOT NULL de la cabecera. Se validan juntas para que el
    -- mensaje las nombre todas de una vez en vez de que el usuario descubra una
    -- por intento.
    IF l_id_empresa IS NULL OR l_id_sucursal IS NULL OR l_id_proveedor IS NULL
       OR TRIM(p_numero_factura) IS NULL OR l_fecha IS NULL OR l_id_moneda IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"Empresa, sucursal, proveedor, numero, fecha y moneda son obligatorios"}';
      RETURN;
    END IF;

    -- TIP_CAMBIO es NOT NULL en el DDL. Cae en 1 si no lo mandan, que es el
    -- valor correcto para la moneda local: una factura en guaranies no tiene
    -- "cotizacion", y obligar a escribir 1 en cada carga seria ruido.
    l_tip_cambio := NVL(l_tip_cambio, 1);

    -- Un tipo de cambio de 0 o negativo convertiria los importes en 0 o en
    -- numeros negativos al valorizar.
    IF l_tip_cambio <= 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"El tipo de cambio tiene que ser mayor a cero"}';
      RETURN;
    END IF;

    -- UNA FACTURA SIN LINEAS NO ES UNA FACTURA. Se rechaza antes de insertar la
    -- cabecera: sin esto quedaria un encabezado huerfano que el listado muestra
    -- con total 0 y que nadie sabe si esta a medio cargar o es un error.
    IF p_detalle IS NULL OR DBMS_LOB.GETLENGTH(p_detalle) = 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La factura necesita al menos una linea de detalle"}';
      RETURN;
    END IF;

    -- LAS TRES VALIDACIONES DE COHERENCIA. El DDL declara las FK por separado y
    -- ninguna mira a las otras (ver la cabecera del archivo).
    IF NOT SUCURSAL_ES_DE_EMPRESA(l_id_sucursal, l_id_empresa) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La sucursal no pertenece a la empresa indicada"}';
      RETURN;
    END IF;

    IF NOT MONEDA_ES_DE_EMPRESA(l_id_moneda, l_id_empresa) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La moneda no pertenece a la empresa indicada"}';
      RETURN;
    END IF;

    -- El proveedor SOLO se verifica que exista: PERSONAS es un catalogo global
    -- sin ID_EMPRESA, asi que cualquier empresa puede facturarle a cualquiera.
    SELECT COUNT(*) INTO l_existe
      FROM PERSONAS WHERE ID_PERSONA = l_id_proveedor;

    IF l_existe = 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"El proveedor indicado no existe"}';
      RETURN;
    END IF;

    -- La condicion de pago es OPCIONAL, asi que solo se verifica si vino. Y como
    -- CONDICIONES_PAGO tambien es un catalogo global, alcanza con que exista.
    IF l_id_condicion IS NOT NULL THEN
      SELECT COUNT(*) INTO l_existe
        FROM CONDICIONES_PAGO WHERE ID_CONDICION = l_id_condicion;

      IF l_existe = 0 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La condicion de pago indicada no existe"}';
        RETURN;
      END IF;
    END IF;

    -- El UNIQUE se consulta antes de insertar para poder explicar el choque:
    -- DUP_VAL_ON_INDEX no dice cual indice fallo, y "ya existe" a secas no
    -- aclara que el duplicado es del PROVEEDOR, no de la empresa.
    SELECT COUNT(*) INTO l_existe
      FROM FACTURAS_COMPRAS_CAB
     WHERE ID_PROVEEDOR  = l_id_proveedor
       AND UPPER(TRIM(NUMERO_FACTURA)) = UPPER(TRIM(p_numero_factura))
       AND FECHA_FACTURA = l_fecha;

    IF l_existe > 0 THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ese proveedor ya tiene cargada una factura con ese numero y fecha"}';
      RETURN;
    END IF;

    INSERT INTO FACTURAS_COMPRAS_CAB (
      ID_EMPRESA, ID_SUCURSAL, ID_PROVEEDOR, NUMERO_FACTURA, FECHA_FACTURA,
      ID_MONEDA, TIP_CAMBIO, ID_CONDICION, OBSERVACION,
      FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_empresa,
      l_id_sucursal,
      l_id_proveedor,
      TRIM(p_numero_factura),
      l_fecha,
      l_id_moneda,
      l_tip_cambio,
      -- Puede quedar NULL: la condicion es opcional.
      l_id_condicion,
      TRIM(p_observacion),
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_FACTURA INTO l_id;

    -- SIN COMMIT ENTRE MEDIO: si el detalle falla, el ROLLBACK deshace tambien
    -- la cabecera. Es todo el punto de recibir el detalle en el mismo request.
    GUARDAR_DETALLE(l_id, l_id_empresa, l_id_sucursal, p_detalle, l_lineas, l_error);

    IF l_error IS NOT NULL THEN
      ROLLBACK;
      p_status_code := 400;
      p_resultado := JSON_OBJECT('error' VALUE l_error);
      RETURN;
    END IF;

    -- Un array JSON vacio ("[]") pasa el chequeo de longitud de arriba pero no
    -- inserta ninguna linea. Se detecta aca, con la cabecera ya insertada pero
    -- todavia sin confirmar.
    IF l_lineas = 0 THEN
      ROLLBACK;
      p_status_code := 400;
      p_resultado := '{"error":"La factura necesita al menos una linea de detalle"}';
      RETURN;
    END IF;

    -- Despues del detalle: las cuotas se reparten sobre el total, que recien
    -- existe cuando las lineas estan grabadas.
    REGENERAR_CUOTAS(l_id);

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT(
      'id'     VALUE l_id,
      'lineas' VALUE l_lineas,
      'ok'     VALUE 'true' FORMAT JSON
    );
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ese proveedor ya tiene cargada una factura con ese numero y fecha"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La empresa, sucursal, proveedor o moneda indicada no existe"}';
      ELSIF SQLCODE = -1722 THEN
        p_status_code := 400;
        p_resultado := '{"error":"Alguno de los importes no es numerico"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_FACTURAS_COMPRAS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear la factura"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization   IN  VARCHAR2,
    p_id              IN  VARCHAR2,
    p_id_empresa      IN  VARCHAR2,
    p_id_sucursal     IN  VARCHAR2,
    p_id_proveedor    IN  VARCHAR2,
    p_numero_factura  IN  VARCHAR2,
    p_fecha_factura   IN  VARCHAR2,
    p_id_moneda       IN  VARCHAR2,
    p_tip_cambio      IN  VARCHAR2,
    p_id_condicion    IN  VARCHAR2,
    p_observacion     IN  VARCHAR2,
    p_detalle         IN  CLOB,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  ) IS
    l_sesion       NUMBER;
    l_id           NUMBER;
    l_id_empresa   NUMBER;
    l_id_sucursal  NUMBER;
    l_id_proveedor NUMBER;
    l_id_moneda    NUMBER;
    l_tip_cambio   NUMBER;
    l_id_condicion NUMBER;
    l_fecha        DATE;
    l_existe       PLS_INTEGER;
    l_lineas       NUMBER;
    l_error        VARCHAR2(500);
    l_sucursal_lote NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id           := TO_NUMBER(NULLIF(p_id, ''));
    l_id_empresa   := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_sucursal  := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    l_id_proveedor := TO_NUMBER(NULLIF(p_id_proveedor, ''));
    l_id_moneda    := TO_NUMBER(NULLIF(p_id_moneda, ''));
    l_tip_cambio   := TO_NUMBER(NULLIF(p_tip_cambio, ''));
    l_id_condicion := TO_NUMBER(NULLIF(p_id_condicion, ''));
    l_fecha        := A_FECHA(p_fecha_factura);

    IF l_id IS NULL OR l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    IF l_tip_cambio IS NOT NULL AND l_tip_cambio <= 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"El tipo de cambio tiene que ser mayor a cero"}';
      RETURN;
    END IF;

    -- La factura tiene que existir Y ser de esta empresa. Se verifica antes de
    -- validar el resto para poder devolver 404 en vez de un 400 confuso sobre
    -- una factura que ni siquiera es visible.
    SELECT COUNT(*) INTO l_existe
      FROM FACTURAS_COMPRAS_CAB
     WHERE ID_FACTURA = l_id
       AND ID_EMPRESA = l_id_empresa;

    IF l_existe = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La factura no existe"}';
      RETURN;
    END IF;

    -- Las coherencias se validan SOLO si el campo viene: un PUT que cambia la
    -- observacion no tiene por que mandar la sucursal.
    IF l_id_sucursal IS NOT NULL
       AND NOT SUCURSAL_ES_DE_EMPRESA(l_id_sucursal, l_id_empresa) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La sucursal no pertenece a la empresa indicada"}';
      RETURN;
    END IF;

    IF l_id_moneda IS NOT NULL
       AND NOT MONEDA_ES_DE_EMPRESA(l_id_moneda, l_id_empresa) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La moneda no pertenece a la empresa indicada"}';
      RETURN;
    END IF;

    IF l_id_condicion IS NOT NULL THEN
      SELECT COUNT(*) INTO l_existe
        FROM CONDICIONES_PAGO WHERE ID_CONDICION = l_id_condicion;

      IF l_existe = 0 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La condicion de pago indicada no existe"}';
        RETURN;
      END IF;
    END IF;

    -- UNA FACTURA CON PAGOS NO SE EDITA. Cambiar el detalle mueve el total, y
    -- las cuotas se rehacen sobre ese total nuevo: borrar cuotas que ya tienen
    -- pagos apuntando romperia la FK, y ajustarlas dejaria montos que no suman
    -- la factura. Hay que anular los pagos primero, uno por uno.
    SELECT COUNT(*) INTO l_existe FROM FACTURAS_COMPRAS_PAGOS WHERE ID_FACTURA = l_id;
    IF l_existe > 0 THEN
      p_status_code := 409;
      p_resultado := '{"error":"La factura tiene pagos registrados: anulalos antes de modificarla"}';
      RETURN;
    END IF;

    -- NVL en cada columna: un parametro ausente conserva el valor actual.
    --
    -- ID_EMPRESA sale del SET a proposito: mover una factura a otra empresa es
    -- lo que el WHERE de abajo busca impedir.
    UPDATE FACTURAS_COMPRAS_CAB
       SET ID_SUCURSAL         = NVL(l_id_sucursal, ID_SUCURSAL),
           ID_PROVEEDOR        = NVL(l_id_proveedor, ID_PROVEEDOR),
           NUMERO_FACTURA      = NVL(TRIM(p_numero_factura), NUMERO_FACTURA),
           FECHA_FACTURA       = NVL(l_fecha, FECHA_FACTURA),
           ID_MONEDA           = NVL(l_id_moneda, ID_MONEDA),
           TIP_CAMBIO          = NVL(l_tip_cambio, TIP_CAMBIO),
           -- Ausente = no cambia, como el resto. Ojo: eso significa que NO hay
           -- forma de QUITARLE la condicion a una factura que ya la tiene —
           -- mandarla vacia se interpreta como "no la toques". Haria falta un
           -- centinela explicito, igual que con las FK de articulos.
           ID_CONDICION        = NVL(l_id_condicion, ID_CONDICION),
           OBSERVACION         = NVL(TRIM(p_observacion), OBSERVACION),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_FACTURA = l_id
       AND ID_EMPRESA = l_id_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La factura no existe"}';
      RETURN;
    END IF;

    -- EL DETALLE SE REEMPLAZA ENTERO, y solo si vino. Sin p_detalle, la
    -- actualizacion es solo de la cabecera y las lineas quedan como estaban —
    -- que es lo que espera un PUT que cambia unicamente la observacion.
    IF p_detalle IS NOT NULL AND DBMS_LOB.GETLENGTH(p_detalle) > 0 THEN
      -- Rehacer el detalle implica rehacer los lotes que trajo la factura, y eso
      -- no se puede si la mercaderia ya salio: borrar un lote a medio vender
      -- dejaria el stock por debajo del fisico.
      IF TIENE_SALIDAS(l_id) THEN
        ROLLBACK;
        p_status_code := 409;
        p_resultado := '{"error":"Ya se vendio mercaderia de esta factura: no se puede cambiar el detalle"}';
        RETURN;
      END IF;

      -- La sucursal sale de la cabecera ya actualizada: `l_id_sucursal` puede
      -- venir NULL en un PUT que no la toca, y el lote la necesita si o si.
      SELECT ID_SUCURSAL INTO l_sucursal_lote FROM FACTURAS_COMPRAS_CAB WHERE ID_FACTURA = l_id;

      BORRAR_DETALLE_Y_LOTES(l_id);

      GUARDAR_DETALLE(l_id, l_id_empresa, l_sucursal_lote, p_detalle, l_lineas, l_error);

      IF l_error IS NOT NULL THEN
        -- El ROLLBACK devuelve tambien el DELETE: la factura queda con su
        -- detalle original, no vacia.
        ROLLBACK;
        p_status_code := 400;
        p_resultado := JSON_OBJECT('error' VALUE l_error);
        RETURN;
      END IF;

      IF l_lineas = 0 THEN
        ROLLBACK;
        p_status_code := 400;
        p_resultado := '{"error":"La factura necesita al menos una linea de detalle"}';
        RETURN;
      END IF;
    END IF;

    -- Siempre, no solo cuando vino el detalle: cambiar la CONDICION de pago sin
    -- tocar las lineas tambien cambia el plan de cuotas.
    REGENERAR_CUOTAS(l_id);

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ese proveedor ya tiene cargada una factura con ese numero y fecha"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La sucursal, proveedor o moneda indicada no existe"}';
      ELSIF SQLCODE = -1722 THEN
        p_status_code := 400;
        p_resultado := '{"error":"Alguno de los importes no es numerico"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_FACTURAS_COMPRAS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM ||
                         ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar la factura"}';
      END IF;
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id         NUMBER;
    l_id_empresa NUMBER;
    l_existe     NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id         := TO_NUMBER(NULLIF(p_id, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    IF l_id IS NULL OR l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    -- EL DETALLE PRIMERO, SIEMPRE. La FK del detalle apunta a la cabecera y el
    -- DDL no declara ON DELETE CASCADE: al reves da ORA-02292.
    --
    -- El DELETE del detalle se acota por empresa a traves de un subselect sobre
    -- la cabecera: sin eso, mandar el id de una factura ajena le borraria las
    -- lineas aunque el DELETE de la cabecera despues no hiciera nada.
    -- La factura tiene que existir Y ser de esta empresa ANTES de tocar nada.
    -- Antes los DELETE salian a ciegas y el 404 se deducia del SQL%ROWCOUNT del
    -- ultimo; ahora hay lotes y pagos de por medio y eso ya no alcanza.
    BEGIN
      SELECT ID_FACTURA INTO l_existe
        FROM FACTURAS_COMPRAS_CAB
       WHERE ID_FACTURA = l_id AND ID_EMPRESA = l_id_empresa
         FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La factura no existe"}';
      RETURN;
    END;

    -- BORRAR LA FACTURA SACA DEL STOCK lo que trajo, asi que no se puede si algo
    -- ya salio: el lote quedaria por debajo de lo fisico, o —peor— habria
    -- mercaderia vendida sin ninguna compra que justifique su costo.
    IF TIENE_SALIDAS(l_id) THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya se vendio mercaderia de esta factura: anula esas ventas antes de eliminarla"}';
      RETURN;
    END IF;

    -- Mismo criterio que en ventas con los cobros: el DELETE en cascada se
    -- llevaria plata que salio de la caja sin dejar rastro.
    SELECT COUNT(*) INTO l_existe FROM FACTURAS_COMPRAS_PAGOS WHERE ID_FACTURA = l_id;
    IF l_existe > 0 THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"La factura tiene pagos registrados: anulalos antes de eliminarla"}';
      RETURN;
    END IF;

    DELETE FROM FACTURAS_COMPRAS_CUOTAS WHERE ID_FACTURA = l_id;

    -- Borra el detalle y, detras, los lotes que esas lineas hicieron entrar:
    -- la existencia que trajo la factura se va con ella.
    BORRAR_DETALLE_Y_LOTES(l_id);

    DELETE FROM FACTURAS_COMPRAS_CAB
     WHERE ID_FACTURA = l_id
       AND ID_EMPRESA = l_id_empresa;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2292 THEN
        -- Hoy nada cuelga de la factura, asi que no puede pasar. Queda
        -- contemplado para cuando existan pagos o notas de credito apuntando
        -- aca: es un conflicto de estado (409), no un fallo del servidor.
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de esta factura"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_FACTURAS_COMPRAS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM ||
                         ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar la factura"}';
      END IF;
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'facturas-compras',
      p_base_path      => '/facturas-compras/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Facturas de compra: cabecera y detalle, por empresa y sucursal'
    );

    -- ORIGINS_ALLOWED ES POR MODULO, no por workspace. Sin esto, ORDS rechaza la
    -- peticion cross-origin ANTES de llegar al handler.
    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'facturas-compras',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /facturas-compras/listar?idEmpresa=&idSucursal=&idProveedor=&desde=&hasta=
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'facturas-compras', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'facturas-compras',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_FACTURAS_COMPRAS.LISTAR(:authorization, :idEmpresa, :idSucursal, :idProveedor, :desde, :hasta, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /facturas-compras/obtener/:id/:idEmpresa
    --
    -- La factura CON su detalle. Endpoint aparte porque el listado no lo trae:
    -- cien facturas con todas sus lineas serian un CLOB enorme para dibujar una
    -- tabla que solo muestra encabezados.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'facturas-compras',
                         p_pattern => 'obtener/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'facturas-compras',
      p_pattern     => 'obtener/:id/:idEmpresa',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_FACTURAS_COMPRAS.OBTENER(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /facturas-compras/crear
    -- Body: { idEmpresa, idSucursal, idProveedor, numeroFactura, fechaFactura,
    --         idMoneda, tipoCambio?, idCondicion?, observacion?,
    --         detalle: [{ idArticulo, cantidad, precioUnitario, idIva? }, ...] }
    --
    -- El detalle va en el MISMO request que la cabecera: es lo que permite que
    -- las dos entren en una transaccion.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'facturas-compras', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'facturas-compras',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_FACTURAS_COMPRAS.INSERTAR(:authorization, :idEmpresa, :idSucursal, :idProveedor, :numeroFactura, :fechaFactura, :idMoneda, :tipoCambio, :idCondicion, :observacion, :detalle, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /facturas-compras/actualizar/:id
    -- Body: los mismos campos, todos opcionales (ausentes = no cambia).
    --       `detalle` ausente deja las lineas como estaban; presente las
    --       REEMPLAZA por completo.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'facturas-compras', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'facturas-compras',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_FACTURAS_COMPRAS.ACTUALIZAR(:authorization, :id, :idEmpresa, :idSucursal, :idProveedor, :numeroFactura, :fechaFactura, :idMoneda, :tipoCambio, :idCondicion, :observacion, :detalle, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /facturas-compras/eliminar/:id/:idEmpresa
    --
    -- Borra la cabecera Y su detalle, en ese orden inverso.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'facturas-compras',
                         p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'facturas-compras',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_FACTURAS_COMPRAS.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'eliminar/:id/:idEmpresa',
      p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'eliminar/:id/:idEmpresa',
      p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'facturas-compras', p_pattern => 'eliminar/:id/:idEmpresa',
      p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_FACTURAS_COMPRAS;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--------------------------------------------------------------------------------

BEGIN
  PKG_FACTURAS_COMPRAS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_FACTURAS_COMPRAS'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_FACTURAS_COMPRAS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'facturas-compras';

-- Deben aparecer 5 filas: listar GET, obtener GET, crear POST, actualizar PUT,
-- eliminar DELETE.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'facturas-compras'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- LAS TASAS DE IVA TIENEN QUE ESTAR CARGADAS, o el detalle no va a poder
-- asignarlas. Ver db/iva.sql.
SELECT ID_IVA, PORCENTAJE, IVA_DIVISION, GRAVADA_DIVISION, DESCRIPCION
  FROM IVA
 ORDER BY PORCENTAJE DESC;

--------------------------------------------------------------------------------
-- Auditoria: las cinco consultas que tienen que devolver CERO filas
--
-- El DDL declara las FK por separado y ninguna mira a las otras. Solo el paquete
-- mantiene la coherencia, asi que esto verifica que nada se haya colado por otro
-- camino.
--------------------------------------------------------------------------------

-- 1. Facturas cuya sucursal es de otra empresa.
SELECT f.ID_FACTURA, f.ID_EMPRESA AS EMPRESA_FACTURA, s.ID_EMPRESA AS EMPRESA_SUCURSAL
  FROM FACTURAS_COMPRAS_CAB f
  JOIN SUCURSALES s ON s.ID_SUCURSAL = f.ID_SUCURSAL
 WHERE f.ID_EMPRESA != s.ID_EMPRESA;

-- 2. Facturas cuya moneda es de otra empresa.
SELECT f.ID_FACTURA, f.ID_EMPRESA AS EMPRESA_FACTURA, m.ID_EMPRESA AS EMPRESA_MONEDA
  FROM FACTURAS_COMPRAS_CAB f
  JOIN MONEDAS m ON m.ID_MONEDA = f.ID_MONEDA
 WHERE f.ID_EMPRESA != m.ID_EMPRESA;

-- 3. Lineas cuyo articulo es de otra empresa que la factura.
SELECT d.ID_DETALLE, d.ID_FACTURA, f.ID_EMPRESA AS EMPRESA_FACTURA,
       a.ID_EMPRESA AS EMPRESA_ARTICULO, a.NOMBRE_ARTICULO
  FROM FACTURAS_COMPRAS_DET d
  JOIN FACTURAS_COMPRAS_CAB f ON f.ID_FACTURA  = d.ID_FACTURA
  JOIN ARTICULOS           a ON a.ID_ARTICULO = d.ID_ARTICULO
 WHERE f.ID_EMPRESA != a.ID_EMPRESA;

-- 4. Cabeceras SIN detalle. INSERTAR lo impide, pero una factura que quedo asi
--    aparece en el listado con total 0 y nadie sabe si esta a medio cargar.
SELECT f.ID_FACTURA, f.NUMERO_FACTURA,
       TO_CHAR(f.FECHA_FACTURA, 'YYYY-MM-DD') AS FECHA
  FROM FACTURAS_COMPRAS_CAB f
 WHERE NOT EXISTS (SELECT 1 FROM FACTURAS_COMPRAS_DET d
                    WHERE d.ID_FACTURA = f.ID_FACTURA);

-- 5. Lineas con cantidad o precio invalidos. El paquete los rechaza; una fila
--    aca entro por fuera de la API.
SELECT ID_DETALLE, ID_FACTURA, ID_ARTICULO, CANTIDAD, PRECIO_UNITARIO
  FROM FACTURAS_COMPRAS_DET
 WHERE CANTIDAD <= 0
    OR PRECIO_UNITARIO < 0;

--------------------------------------------------------------------------------
-- Consultas utiles
--------------------------------------------------------------------------------

-- Las facturas con su total y su vencimiento, como las ve el listado.
SELECT f.ID_FACTURA,
       e.NOMBRE_EMPRESA,
       s.NOMBRE_SUCURSAL,
       CASE WHEN NVL(UPPER(TRIM(pr.TIPO_PERSONA)), 'F') = 'J'
            THEN NVL(pr.RAZON_SOCIAL, pr.NOMBRE)
            ELSE pr.APELLIDO || ', ' || pr.NOMBRE END AS PROVEEDOR,
       f.NUMERO_FACTURA,
       TO_CHAR(f.FECHA_FACTURA, 'YYYY-MM-DD') AS FECHA,
       NVL(cp.NOMBRE_CONDICION, 'Sin condicion') AS CONDICION,
       TO_CHAR(f.FECHA_FACTURA + cp.DIAS_PAGO, 'YYYY-MM-DD') AS VENCE,
       m.SIMBOLO,
       (SELECT SUM(d.SUBTOTAL) FROM FACTURAS_COMPRAS_DET d
         WHERE d.ID_FACTURA = f.ID_FACTURA) AS TOTAL
  FROM FACTURAS_COMPRAS_CAB f
  JOIN EMPRESAS   e  ON e.ID_EMPRESA   = f.ID_EMPRESA
  JOIN SUCURSALES s  ON s.ID_SUCURSAL  = f.ID_SUCURSAL
  JOIN PERSONAS   pr ON pr.ID_PERSONA  = f.ID_PROVEEDOR
  JOIN MONEDAS    m  ON m.ID_MONEDA    = f.ID_MONEDA
  LEFT JOIN CONDICIONES_PAGO cp ON cp.ID_CONDICION = f.ID_CONDICION
 ORDER BY f.FECHA_FACTURA DESC, f.ID_FACTURA DESC;

-- FACTURAS VENCIDAS O POR VENCER, que es para lo que existe la condicion de
-- pago. Las que no tienen condicion NO aparecen: sin plazo no hay vencimiento
-- que calcular, y asumirle uno seria inventar un dato.
SELECT f.ID_FACTURA,
       f.NUMERO_FACTURA,
       CASE WHEN NVL(UPPER(TRIM(pr.TIPO_PERSONA)), 'F') = 'J'
            THEN NVL(pr.RAZON_SOCIAL, pr.NOMBRE)
            ELSE pr.APELLIDO || ', ' || pr.NOMBRE END AS PROVEEDOR,
       TO_CHAR(f.FECHA_FACTURA, 'YYYY-MM-DD') AS FECHA,
       cp.NOMBRE_CONDICION,
       TO_CHAR(f.FECHA_FACTURA + cp.DIAS_PAGO, 'YYYY-MM-DD') AS VENCE,
       TRUNC(f.FECHA_FACTURA + cp.DIAS_PAGO) - TRUNC(SYSDATE) AS DIAS_RESTANTES,
       (SELECT SUM(d.SUBTOTAL) FROM FACTURAS_COMPRAS_DET d
         WHERE d.ID_FACTURA = f.ID_FACTURA) AS TOTAL
  FROM FACTURAS_COMPRAS_CAB f
  JOIN PERSONAS         pr ON pr.ID_PERSONA  = f.ID_PROVEEDOR
  JOIN CONDICIONES_PAGO cp ON cp.ID_CONDICION = f.ID_CONDICION
 ORDER BY f.FECHA_FACTURA + cp.DIAS_PAGO;

-- LIBRO DE COMPRAS: el desglose por factura, con el mismo CASE que usan los
-- endpoints — gravado por division cuando hay GRAVADA_DIVISION, y el IVA por
-- resta. Ver la nota de la cabecera.
SELECT f.ID_FACTURA,
       f.NUMERO_FACTURA,
       TO_CHAR(f.FECHA_FACTURA, 'YYYY-MM-DD') AS FECHA,
       pr.RUC,
       SUM(d.SUBTOTAL) AS TOTAL,
       SUM(CASE WHEN iv.GRAVADA_DIVISION IS NOT NULL
                THEN ROUND(d.SUBTOTAL / NULLIF(iv.GRAVADA_DIVISION, 0), 2)
                ELSE d.SUBTOTAL - NVL(ROUND(d.SUBTOTAL /
                     NULLIF(iv.IVA_DIVISION, 0), 2), 0) END) AS GRAVADO,
       SUM(CASE WHEN iv.GRAVADA_DIVISION IS NOT NULL
                THEN d.SUBTOTAL - ROUND(d.SUBTOTAL / NULLIF(iv.GRAVADA_DIVISION, 0), 2)
                ELSE NVL(ROUND(d.SUBTOTAL /
                     NULLIF(iv.IVA_DIVISION, 0), 2), 0) END) AS IVA
  FROM FACTURAS_COMPRAS_CAB f
  JOIN FACTURAS_COMPRAS_DET  d  ON d.ID_FACTURA = f.ID_FACTURA
  JOIN PERSONAS             pr ON pr.ID_PERSONA = f.ID_PROVEEDOR
  LEFT JOIN IVA             iv ON iv.ID_IVA = d.ID_IVA
 GROUP BY f.ID_FACTURA, f.NUMERO_FACTURA, f.FECHA_FACTURA, pr.RUC
 ORDER BY f.FECHA_FACTURA DESC;

-- Que el desglose CUADRE: gravado + iva tiene que dar el total, exacto. CERO
-- filas.
--
-- Es la consulta que justifica todo el metodo nuevo: con las dos divisiones
-- independientes (el metodo viejo), esta consulta devolvia filas con diferencias
-- de un guarani, y esas diferencias se acumulan en el libro de compras.
SELECT f.ID_FACTURA, f.NUMERO_FACTURA,
       SUM(d.SUBTOTAL) AS TOTAL,
       SUM(CASE WHEN iv.GRAVADA_DIVISION IS NOT NULL
                THEN ROUND(d.SUBTOTAL / NULLIF(iv.GRAVADA_DIVISION, 0), 2)
                ELSE d.SUBTOTAL - NVL(ROUND(d.SUBTOTAL /
                     NULLIF(iv.IVA_DIVISION, 0), 2), 0) END)
     + SUM(CASE WHEN iv.GRAVADA_DIVISION IS NOT NULL
                THEN d.SUBTOTAL - ROUND(d.SUBTOTAL / NULLIF(iv.GRAVADA_DIVISION, 0), 2)
                ELSE NVL(ROUND(d.SUBTOTAL /
                     NULLIF(iv.IVA_DIVISION, 0), 2), 0) END) AS GRAVADO_MAS_IVA
  FROM FACTURAS_COMPRAS_CAB f
  JOIN FACTURAS_COMPRAS_DET  d  ON d.ID_FACTURA = f.ID_FACTURA
  LEFT JOIN IVA             iv ON iv.ID_IVA = d.ID_IVA
 GROUP BY f.ID_FACTURA, f.NUMERO_FACTURA
HAVING SUM(d.SUBTOTAL) !=
       SUM(CASE WHEN iv.GRAVADA_DIVISION IS NOT NULL
                THEN ROUND(d.SUBTOTAL / NULLIF(iv.GRAVADA_DIVISION, 0), 2)
                ELSE d.SUBTOTAL - NVL(ROUND(d.SUBTOTAL /
                     NULLIF(iv.IVA_DIVISION, 0), 2), 0) END)
     + SUM(CASE WHEN iv.GRAVADA_DIVISION IS NOT NULL
                THEN d.SUBTOTAL - ROUND(d.SUBTOTAL / NULLIF(iv.GRAVADA_DIVISION, 0), 2)
                ELSE NVL(ROUND(d.SUBTOTAL /
                     NULLIF(iv.IVA_DIVISION, 0), 2), 0) END);

-- Cuanto se le compro a cada proveedor.
SELECT CASE WHEN NVL(UPPER(TRIM(pr.TIPO_PERSONA)), 'F') = 'J'
            THEN NVL(pr.RAZON_SOCIAL, pr.NOMBRE)
            ELSE pr.APELLIDO || ', ' || pr.NOMBRE END AS PROVEEDOR,
       COUNT(DISTINCT f.ID_FACTURA) AS FACTURAS,
       SUM(d.SUBTOTAL)              AS TOTAL
  FROM FACTURAS_COMPRAS_CAB f
  JOIN FACTURAS_COMPRAS_DET  d  ON d.ID_FACTURA  = f.ID_FACTURA
  JOIN PERSONAS             pr ON pr.ID_PERSONA = f.ID_PROVEEDOR
 GROUP BY pr.ID_PERSONA, pr.TIPO_PERSONA, pr.RAZON_SOCIAL, pr.NOMBRE, pr.APELLIDO
 ORDER BY TOTAL DESC;
