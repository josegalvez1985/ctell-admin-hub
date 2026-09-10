--------------------------------------------------------------------------------
-- CTELL · STOCK
--
-- PKG_STOCK: el UNICO camino por el que una transaccion mueve EXISTENCIAS.
-- Vender descuenta, comprar ingresa, y borrar cualquiera de las dos revierte.
--
-- ESTE ARCHIVO ROMPE LA REGLA DE "UN ARCHIVO POR TABLA" A PROPOSITO, igual que
-- db/auth.sql: no publica ningun modulo ORDS y no es el ABM de EXISTENCIAS —eso
-- es db/existencias.sql, que la lee—. Es un paquete INTERNO que llaman otros
-- paquetes. Por eso tampoco valida token: quien lo llama ya valido el suyo, y
-- pedirlo dos veces solo agregaria una firma que nadie puede satisfacer desde
-- adentro de una transaccion ya autenticada.
--
-- ORDEN DE EJECUCION EN APEX:
--
--   1. db/stock.sql              (este archivo)
--   2. db/ventas.sql             (ahora llama a PKG_STOCK)
--   3. db/facturas-compras.sql   (idem)
--
-- Si se ejecuta ventas.sql sin este archivo, PKG_VENTAS compila INVALID con
-- PLS-00201 ("PKG_STOCK must be declared") y todo el modulo devuelve 500 mudo.
--
--------------------------------------------------------------------------------
-- QUE ES UNA EXISTENCIA, Y QUE NO
--
-- EXISTENCIAS tiene UNA fila por (ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO), con su
-- UNIQUE, y una sola columna de cantidad: CANTIDAD_DISPONIBLE. No hay lotes, no
-- hay partidas, no hay costo. Reemplaza al modelo por lotes, que se discontinuo
-- porque obligaba al cajero a elegir de que partida salia cada linea y hacia
-- imposible el conteo fisico —en el estante las unidades son identicas—.
--
-- LA FILA PUEDE NO EXISTIR. Un articulo que nunca se compro ni se conto no tiene
-- fila en ninguna sucursal, y eso NO es un error: es stock cero. Por eso una
-- SALIDA sobre un articulo sin fila da "sin existencia suficiente" (0 < lo
-- pedido) y una ENTRADA la crea.
--
--------------------------------------------------------------------------------
-- FOR UPDATE: LA CARRERA ENTRE DOS CAJAS
--
-- Con el stock por lotes esta carrera existia y se resolvia bloqueando el lote.
-- Volvio con este paquete, ahora sobre la fila de EXISTENCIAS.
--
-- Sin FOR UPDATE, dos cajas vendiendo la ultima unidad al mismo tiempo leen 1
-- las dos, las dos concluyen que alcanza, y las dos restan: la fila queda en -1
-- y se vendio una unidad que no existia. El SELECT ... FOR UPDATE hace que la
-- segunda espere a que la primera termine, y entonces lee 0 y rechaza.
--
-- El bloqueo se toma ANTES de decidir, no despues: leer sin bloquear y bloquear
-- para escribir tiene exactamente el mismo problema, porque entre las dos
-- sentencias la otra sesion ya cambio el numero.
--
--------------------------------------------------------------------------------
-- SIN COMMIT NI ROLLBACK, NUNCA
--
-- Estos procedimientos se llaman DENTRO de la transaccion de la venta o de la
-- compra. Un COMMIT aca confirmaria el movimiento de stock antes de que la
-- cabecera y el detalle esten completos: si una linea posterior falla, el
-- llamador hace ROLLBACK y se encuentra con que el stock ya se movio y no vuelve.
--
-- Es el mismo criterio de GUARDAR_DETALLE en facturas-compras.sql, y por eso
-- tambien devuelven el error en p_error en vez de lanzar: el llamador tiene que
-- poder hacer ROLLBACK de todo y decidir que mensaje ve el usuario. Un RAISE le
-- sacaria el control del texto.
--
--------------------------------------------------------------------------------
-- NO SE VENDE SIN EXISTENCIA: 409
--
-- Si la cantidad disponible no alcanza, la SALIDA falla y la venta ENTERA se
-- rechaza — no se vende parcial ni se deja negativo. Es la regla que tenia el
-- modelo por lotes y que se perdio con el.
--
-- La contracara, que hay que saberla: una existencia mal cargada TRABA LA CAJA.
-- Si el sistema dice 0 y en el estante hay 12, no se puede vender hasta cargar
-- la compra que falta o hacer un conteo fisico. Por eso el mensaje NOMBRA el
-- articulo y da los dos numeros —lo que hay y lo que se pidio—: "no hay stock" a
-- secas deja a quien esta en el mostrador sin saber que hacer.
--
--------------------------------------------------------------------------------
-- LOS SERVICIOS NO TIENEN EXISTENCIA
--
-- ARTICULOS.ES_GASTO = 'S' marca lo que no es un bien de stock: un flete, una
-- comision, una hora de trabajo. Mover existencias de un servicio dejaria filas
-- en -40 que no significan nada y ensuciarian el reporte de stock critico.
--
-- El filtro NO va en este paquete: va en quien llama, que ya lee ES_GASTO por
-- otros motivos. Aca el articulo llega o no llega — poner la regla en los dos
-- lados invita a que se desincronicen.
--
--------------------------------------------------------------------------------
-- LO QUE ESTE PAQUETE TODAVIA NO HACE
--
-- 1. NO GUARDA COSTO. EXISTENCIAS no tiene columna de costo promedio ponderado,
--    asi que el VALOR de stock del dashboard sigue en cero. El costo de cada
--    compra vive en FACTURAS_COMPRAS_DET.PRECIO_UNITARIO; derivar el promedio de
--    ahi necesita el libro de movimientos, que es el punto 2.
--
-- 2. NO HAY LIBRO DE MOVIMIENTOS. Cada llamada cambia el numero y no deja
--    asiento: un CANTIDAD_DISPONIBLE en 3 que deberia ser 5 no se puede
--    explicar. Se decidio dejarlo para un paso siguiente (MOVIMIENTOS_STOCK, con
--    su DDL). Cuando exista, el asiento va DENTRO de MOVER —un solo lugar— y no
--    en cada llamador.
--
-- 3. EL CIERRE DE INVENTARIO NO PASA POR ACA. Lo escribe el trigger
--    TRG_INVENTARIOS_AU_EXISTENCIAS, que es el segundo escritor de la tabla. Ver
--    la nota de db/inventarios-triggers-ddl.sql: con ventas y compras moviendo
--    stock, ese cierre tiene que ajustar POR DIFERENCIA contra CANTIDAD_SISTEMA
--    y no fijar la cantidad, o un cierre tardio borra las ventas ocurridas entre
--    el conteo y el cierre.
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   EXISTENCIAS  ID_EXISTENCIA, ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO,
--                CANTIDAD_DISPONIBLE, FECHA_ULTIMO_MOVIMIENTO,
--                FECHA_CREACION, FECHA_ACTUALIZACION
--                UNIQUE (ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO)
--
-- CANTIDAD_DISPONIBLE ES NULLABLE, con DEFAULT 0: se lee siempre con NVL.
--------------------------------------------------------------------------------

SET DEFINE OFF;

--------------------------------------------------------------------------------
-- 1. PKG_STOCK
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_STOCK AS
  -- Descuenta p_cantidad del articulo en esa empresa y sucursal.
  -- p_error queda NULL si salio bien; con texto si no habia suficiente o el
  -- articulo no tiene fila. No hace COMMIT: la transaccion es del llamador.
  PROCEDURE SALIDA (
    p_id_empresa  IN  NUMBER,
    p_id_sucursal IN  NUMBER,
    p_id_articulo IN  NUMBER,
    p_cantidad    IN  NUMBER,
    p_error       OUT VARCHAR2
  );

  -- Suma p_cantidad. Crea la fila si el articulo nunca tuvo existencia en esa
  -- sucursal. No hace COMMIT.
  PROCEDURE ENTRADA (
    p_id_empresa  IN  NUMBER,
    p_id_sucursal IN  NUMBER,
    p_id_articulo IN  NUMBER,
    p_cantidad    IN  NUMBER,
    p_error       OUT VARCHAR2
  );

  -- Cantidad disponible de un articulo, 0 si no tiene fila. Solo lectura, sin
  -- bloqueo: sirve para mostrar, NUNCA para decidir si alcanza — entre esta
  -- consulta y el descuento otra caja pudo llevarse la ultima unidad. Para
  -- decidir esta SALIDA, que bloquea.
  FUNCTION DISPONIBLE (
    p_id_empresa  IN NUMBER,
    p_id_sucursal IN NUMBER,
    p_id_articulo IN NUMBER
  ) RETURN NUMBER;
END PKG_STOCK;
/

CREATE OR REPLACE PACKAGE BODY PKG_STOCK AS

  ------------------------------------------------------------------------------
  -- Privado: el nombre del articulo, para que el mensaje de error diga cual es.
  --
  -- Un 409 que dice "no hay stock suficiente" obliga a quien esta en el
  -- mostrador a ir probando linea por linea cual fue. Con diez articulos en el
  -- carrito eso son diez intentos.
  --
  -- Devuelve el id entre parentesis si el articulo no existe, en vez de lanzar:
  -- esto se llama para ARMAR UN MENSAJE DE ERROR, y una excepcion aca taparia el
  -- error real con otro distinto.
  ------------------------------------------------------------------------------
  -- Se llama NOMBRE_DE y no NOMBRE_ARTICULO para no chocar con la COLUMNA del
  -- mismo nombre: adentro del SELECT, Oracle resuelve el identificador a favor
  -- de la columna y la funcion nunca se llamaria — o peor, compilaria distinto
  -- de lo que se lee.
  FUNCTION NOMBRE_DE (p_id_articulo IN NUMBER) RETURN VARCHAR2 IS
    l_nombre VARCHAR2(200);
  BEGIN
    -- NOMBRE_ARTICULO y no DESCRIPCION: la descripcion acepta hasta 1000
    -- caracteres y este texto va dentro de un mensaje de error que se lee en un
    -- toast del mostrador.
    SELECT NOMBRE_ARTICULO INTO l_nombre FROM ARTICULOS WHERE ID_ARTICULO = p_id_articulo;
    RETURN l_nombre;
  EXCEPTION WHEN OTHERS THEN
    RETURN 'articulo #' || TO_CHAR(p_id_articulo);
  END NOMBRE_DE;

  ------------------------------------------------------------------------------
  -- Privado: el motor de los dos sentidos.
  --
  -- p_signo es +1 (entrada) o -1 (salida), y p_exigir_saldo dice si una cantidad
  -- insuficiente es un error. Uno solo y no dos copias porque el bloqueo, el
  -- UPDATE, el INSERT de la fila faltante y la carrera con otra sesion son
  -- identicos en los dos sentidos: duplicarlos garantiza que un dia se arregle un
  -- bug en uno y no en el otro.
  --
  -- EL SELECT ... FOR UPDATE ES LO QUE HACE CORRECTO A TODO ESTO. Ver la nota de
  -- la cabecera: sin el, dos cajas venden la misma ultima unidad.
  ------------------------------------------------------------------------------
  PROCEDURE MOVER (
    p_id_empresa    IN  NUMBER,
    p_id_sucursal   IN  NUMBER,
    p_id_articulo   IN  NUMBER,
    p_cantidad      IN  NUMBER,
    p_signo         IN  NUMBER,
    p_exigir_saldo  IN  BOOLEAN,
    p_error         OUT VARCHAR2
  ) IS
    l_disponible NUMBER;
  BEGIN
    p_error := NULL;

    IF p_id_empresa IS NULL OR p_id_sucursal IS NULL OR p_id_articulo IS NULL THEN
      p_error := 'Falta la empresa, la sucursal o el articulo para mover el stock';
      RETURN;
    END IF;

    -- Una cantidad en cero no es un error: es una linea que no mueve nada. Una
    -- negativa SI lo es — invertiria el sentido del movimiento sin que el
    -- llamador lo haya pedido, y una "salida de -5" seria una entrada disfrazada.
    IF p_cantidad IS NULL OR p_cantidad < 0 THEN
      p_error := 'La cantidad a mover no puede ser negativa';
      RETURN;
    END IF;
    IF p_cantidad = 0 THEN RETURN; END IF;

    -- El bloqueo se toma ACA, antes de decidir nada. A partir de esta linea
    -- ninguna otra sesion puede tocar esta fila hasta que el llamador cierre su
    -- transaccion.
    BEGIN
      SELECT NVL(CANTIDAD_DISPONIBLE, 0)
        INTO l_disponible
        FROM EXISTENCIAS
       WHERE ID_EMPRESA  = p_id_empresa
         AND ID_SUCURSAL = p_id_sucursal
         AND ID_ARTICULO = p_id_articulo
       FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      -- Sin fila el disponible es cero, no un error. Si esto es una salida que
      -- exige saldo, el chequeo de abajo la rechaza igual; si es una entrada, se
      -- crea la fila. Queda en NULL —y no en 0— porque es lo que distingue "no
      -- hay fila" de "hay fila en cero", y de eso depende UPDATE o INSERT.
      l_disponible := NULL;
    END;

    IF p_exigir_saldo AND NVL(l_disponible, 0) < p_cantidad THEN
      -- El mensaje nombra el articulo y da LOS DOS numeros: sin ellos, quien esta
      -- en el mostrador no sabe si le faltan dos unidades o veinte, ni si lo que
      -- hay que hacer es cargar una compra o corregir el pedido.
      p_error := 'No hay stock suficiente de ' || NOMBRE_DE(p_id_articulo) ||
                 ': hay ' || TO_CHAR(NVL(l_disponible, 0)) ||
                 ' y se necesitan ' || TO_CHAR(p_cantidad);
      RETURN;
    END IF;

    IF l_disponible IS NOT NULL THEN
      UPDATE EXISTENCIAS
         SET CANTIDAD_DISPONIBLE     = NVL(CANTIDAD_DISPONIBLE, 0) + (p_signo * p_cantidad),
             FECHA_ULTIMO_MOVIMIENTO = SYSTIMESTAMP,
             FECHA_ACTUALIZACION     = SYSTIMESTAMP
       WHERE ID_EMPRESA  = p_id_empresa
         AND ID_SUCURSAL = p_id_sucursal
         AND ID_ARTICULO = p_id_articulo;
      RETURN;
    END IF;

    -- No habia fila: se crea con el movimiento ya aplicado.
    --
    -- ID_EXISTENCIA se omite y se confia en que la columna es IDENTITY, igual que
    -- en el trigger de inventarios.
    BEGIN
      INSERT INTO EXISTENCIAS (
        ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO, CANTIDAD_DISPONIBLE,
        FECHA_ULTIMO_MOVIMIENTO, FECHA_CREACION, FECHA_ACTUALIZACION
      ) VALUES (
        p_id_empresa, p_id_sucursal, p_id_articulo, p_signo * p_cantidad,
        SYSTIMESTAMP, SYSTIMESTAMP, SYSTIMESTAMP
      );
    EXCEPTION WHEN DUP_VAL_ON_INDEX THEN
      -- Otra sesion creo la fila entre nuestro SELECT y este INSERT: el FOR
      -- UPDATE no puede bloquear una fila que todavia no existe. Ahora si existe,
      -- asi que el UPDATE la encuentra —y esta vez SI la bloquea—.
      --
      -- Es la misma resolucion que usa TRG_INVENTARIOS_AU_EXISTENCIAS, y el
      -- motivo por el que ni alla ni aca va un MERGE: el MERGE tampoco es atomico
      -- contra un UNIQUE y ademas no deja donde poner esta recuperacion.
      UPDATE EXISTENCIAS
         SET CANTIDAD_DISPONIBLE     = NVL(CANTIDAD_DISPONIBLE, 0) + (p_signo * p_cantidad),
             FECHA_ULTIMO_MOVIMIENTO = SYSTIMESTAMP,
             FECHA_ACTUALIZACION     = SYSTIMESTAMP
       WHERE ID_EMPRESA  = p_id_empresa
         AND ID_SUCURSAL = p_id_sucursal
         AND ID_ARTICULO = p_id_articulo;
    END;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -2291 THEN
        -- ORA-02291: la empresa, la sucursal o el articulo no existen. Es un dato
        -- invalido del llamador, no una falla del servidor.
        p_error := 'La empresa, la sucursal o el articulo del movimiento de stock no existen';
      ELSE
        APEX_DEBUG.ERROR('PKG_STOCK.MOVER: [' || SQLCODE || '] ' || SQLERRM ||
                         ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_error := 'Error al mover el stock';
      END IF;
  END MOVER;

  PROCEDURE SALIDA (
    p_id_empresa  IN  NUMBER,
    p_id_sucursal IN  NUMBER,
    p_id_articulo IN  NUMBER,
    p_cantidad    IN  NUMBER,
    p_error       OUT VARCHAR2
  ) IS
  BEGIN
    MOVER(p_id_empresa, p_id_sucursal, p_id_articulo, p_cantidad, -1, TRUE, p_error);
  END SALIDA;

  ------------------------------------------------------------------------------
  -- Una entrada NO exige saldo: sumar siempre se puede.
  --
  -- Ojo que por aca pasa tambien la REVERSA de una salida —borrar una venta
  -- repone—, y ahi es deliberado: si el stock quedo en 0 por un conteo posterior
  -- a la venta, reponer igual es lo correcto. La alternativa —negarse a reponer—
  -- dejaria una venta borrada cuyas unidades no volvieron a ningun lado.
  ------------------------------------------------------------------------------
  PROCEDURE ENTRADA (
    p_id_empresa  IN  NUMBER,
    p_id_sucursal IN  NUMBER,
    p_id_articulo IN  NUMBER,
    p_cantidad    IN  NUMBER,
    p_error       OUT VARCHAR2
  ) IS
  BEGIN
    MOVER(p_id_empresa, p_id_sucursal, p_id_articulo, p_cantidad, 1, FALSE, p_error);
  END ENTRADA;

  FUNCTION DISPONIBLE (
    p_id_empresa  IN NUMBER,
    p_id_sucursal IN NUMBER,
    p_id_articulo IN NUMBER
  ) RETURN NUMBER IS
    l_cantidad NUMBER;
  BEGIN
    SELECT NVL(CANTIDAD_DISPONIBLE, 0)
      INTO l_cantidad
      FROM EXISTENCIAS
     WHERE ID_EMPRESA  = p_id_empresa
       AND ID_SUCURSAL = p_id_sucursal
       AND ID_ARTICULO = p_id_articulo;
    RETURN l_cantidad;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    -- Sin fila es cero, no NULL: un NULL obligaria a cada consumidor a poner su
    -- propio NVL, y el que se olvide compara NULL contra un numero y su IF nunca
    -- entra.
    RETURN 0;
  END DISPONIBLE;

END PKG_STOCK;
/

--------------------------------------------------------------------------------
-- 2. Verificacion
--
-- Un paquete INVALID no se nota hasta que alguien vende: el WHEN OTHERS no
-- captura errores de compilacion, asi que el sintoma es un 500 mudo.
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_STOCK'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_STOCK'
 ORDER BY SEQUENCE;

-- Los dos paquetes que lo llaman tienen que quedar VALID despues de reejecutar
-- ventas.sql y facturas-compras.sql. Si alguno figura INVALID aca, es que se
-- ejecutaron en el orden equivocado.
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME IN ('PKG_VENTAS', 'PKG_FACTURAS_COMPRAS')
 ORDER BY OBJECT_NAME, OBJECT_TYPE;

-- NINGUNA EXISTENCIA DEBERIA QUEDAR NEGATIVA. Con la salida exigiendo saldo, un
-- negativo solo puede venir de datos anteriores a este paquete o de un cierre de
-- inventario que fijo la cantidad. Si aparecen filas aca, hay que corregirlas con
-- un conteo fisico antes de confiar en el reporte de stock.
SELECT e.ID_EMPRESA, e.ID_SUCURSAL, e.ID_ARTICULO, a.NOMBRE_ARTICULO, e.CANTIDAD_DISPONIBLE
  FROM EXISTENCIAS e
  JOIN ARTICULOS   a ON a.ID_ARTICULO = e.ID_ARTICULO
 WHERE NVL(e.CANTIDAD_DISPONIBLE, 0) < 0
 ORDER BY e.ID_EMPRESA, e.ID_SUCURSAL, a.NOMBRE_ARTICULO;
