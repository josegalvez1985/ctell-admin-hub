--------------------------------------------------------------------------------
-- CTELL · INVENTARIOS · TRIGGERS
--
-- Dos triggers sobre INVENTARIOS, y nada mas:
--
--   1. TRG_INVENTARIOS_BIUD            Sella lo que decia el sistema al contar,
--                                      y congela el conteo al cerrarlo.
--   2. TRG_INVENTARIOS_AU_EXISTENCIAS  Al cerrar, escribe EXISTENCIAS.
--
-- Es el UNICO archivo de db/ que administra DDL. El resto define paquetes y
-- publica modulos ORDS; aca no hay ninguno de los dos, y es a proposito: la
-- regla tiene que valer aunque alguien toque la tabla por fuera de la API —una
-- correccion a mano en la hoja SQL, un import— y eso solo lo garantiza un
-- trigger. Un paquete despues puede chequear antes para devolver un 409 legible
-- en vez de dejar salir el ORA-20xxx crudo como un 500 mudo.
--
--------------------------------------------------------------------------------
-- LA MAQUINA DE ESTADOS
--
--   ABIERTO ──> CERRADO   escribe EXISTENCIAS y congela la fila
--           └─> ANULADO   descarta el conteo, no toca nada
--
-- Desde un estado terminal no se sale. El cierre se dispara desde otro
-- formulario —un PUT que solo manda ESTADO='CERRADO'—, no desde la pantalla de
-- carga: contar y aplicar son dos actos distintos y conviene que se vean asi.
--
-- PROCESADO queda como valor LEGADO. El COMMENT de la tabla lo describe como
-- "aplicado a LOTES.CANTIDAD", de cuando el stock vivia en partidas; hoy el
-- efecto lo tiene CERRADO y ninguna transicion produce PROCESADO. Las filas
-- historicas que lo tengan quedan congeladas igual, porque no estan ABIERTO.
--
-- BORRAR: se permite solo mientras esta ABIERTO. Un conteo cerrado es evidencia
-- de que alguien fue al deposito y conto —y ya movio el stock—; borrarlo hace
-- desaparecer la explicacion de por que la existencia dice lo que dice. Para
-- deshacerlo hay que contar de nuevo, que es lo correcto.
--
--------------------------------------------------------------------------------
-- EL CONTEO AJUSTA POR DIFERENCIA, NO FIJA LA CANTIDAD
--
--   EXISTENCIAS.CANTIDAD_DISPONIBLE += (CANTIDAD_FISICA - CANTIDAD_SISTEMA)
--
-- ESTO CAMBIO CUANDO APARECIO PKG_STOCK, y el motivo esta escrito completo al
-- pie, sobre el trigger que lo hace. En resumen: mientras el conteo era el unico
-- escritor de la tabla, fijar la cantidad estaba bien —nada mas se movia entre
-- el conteo y el cierre—. Con ventas y compras moviendo existencias, fijarla
-- BORRA todo lo que paso en el medio: un cierre tardio hace reaparecer en el
-- deposito la mercaderia vendida despues del conteo.
--
-- LO QUE NO CAMBIO: lo que hay en el estante sigue mandando. Si el conteo y el
-- cierre son del mismo momento —el caso normal— el resultado es identico al de
-- antes, porque la diferencia se aplica sobre el mismo numero que se conto.
--
-- CANTIDAD_SISTEMA SE SELLA AL CONTAR, NO AL CERRAR. Cumple DOS funciones: deja
-- el rastro de cuanto se corrigio, y es el numero contra el que se calcula la
-- diferencia a aplicar. Por eso tiene que ser lo que el sistema decia cuando se
-- MIRO el estante, no cuando alguien apreto "cerrar" tres dias despues.
--
-- ESTO TAMBIEN CAMBIO. Antes se sellaba en el cierre, y eso hacia que el
-- ajuste por diferencia no protegiera nada: se cuenta el lunes y hay 100, el
-- martes se venden 30 (el sistema dice 70), el miercoles se cierra. Sellado en
-- el cierre, el sistema "decia" 70 y el ajuste era 100 - 70 = +30: la tabla
-- volvia a 100 y las 30 vendidas reaparecian — exactamente lo que el ajuste
-- por diferencia vino a evitar. Sellado al contar, decia 100, el ajuste es
-- 100 - 100 = 0 y queda en 70, que es lo correcto.
--
-- "AL CONTAR" ES CUANDO CAMBIA LA CANTIDAD CONTADA, no cada guardado:
--
--   - CANTIDAD_FISICA pasa de NULL a un numero (se termino de contar), o de un
--     numero a otro (se reconto)  -> se sella con EXISTENCIAS de ese momento.
--   - CANTIDAD_FISICA vuelve a NULL (quedo un estante sin contar) -> NULL:
--     todavia no hay conteo, y un sello viejo seria de otro numero.
--   - Cualquier otro cambio —las observaciones, la fecha— no lo toca. Corregir
--     un comentario el miercoles no convierte en "del miercoles" un conteo que
--     se hizo el lunes.
--
-- LO QUE ESTO NO RESUELVE: el momento de guardar sustituye al de contar. Si se
-- anota en papel a la manana y se carga a la tarde, las ventas de esas horas
-- quedan dentro del ajuste. Hacerlo exacto exige el libro de movimientos (para
-- saber que decia el sistema a la hora de FECHA_INVENTARIO), que no existe.
-- Por eso conviene cargar el conteo desde el celular, parado en el estante.
--
-- Los conteos ABIERTOS de antes de este cambio tienen CANTIDAD_SISTEMA en
-- NULL: se sellan en el cierre, como antes. Es el unico caso.
--
--------------------------------------------------------------------------------
-- ES UNO DE LOS DOS ESCRITORES DE EXISTENCIAS
--
-- El otro es PKG_STOCK (db/stock.sql), por donde pasan ventas y compras. Un
-- conteo fisico no va por ahi a proposito: no es una transaccion, es la
-- CORRECCION de las transacciones, y no tiene un documento del cual colgar.
--
-- CUANDO EXISTA EL LIBRO DE MOVIMIENTOS hay que volver sobre esto: ahi el conteo
-- deberia delegar en PKG_STOCK —como un ajuste de inventario— para que la
-- correccion tambien quede asentada. Hoy el ajuste del conteo es el unico
-- cambio de existencia que no deja mas rastro que esta fila.
--
-- La fila de EXISTENCIAS PUEDE NO EXISTIR: un articulo que nunca tuvo
-- movimiento en esa sucursal no tiene fila, y eso no es lo mismo que tener 0.
-- Por eso el ajuste es un UPDATE y, si no toco ninguna fila, un INSERT.
--
--------------------------------------------------------------------------------
-- ORDEN DE EJECUCION — IMPORTANTE
--
--   1. db/retirar-lotes-inventarios.sql   PRIMERO, si todavia no se corrio.
--   2. este archivo.
--
-- Ese script borra TODOS los triggers de INVENTARIOS, sin mirar el nombre (los
-- viejos ajustaban LOTES y quedaron INVALID, y un trigger INVALID bloquea todo
-- INSERT y UPDATE de su tabla). Corrido despues, se lleva puestos estos dos y la
-- tabla vuelve a quedar sin ninguna regla. Los nombres son distintos de los
-- viejos —_BIUD y _AU_EXISTENCIAS contra _BIU, _AU y _BD— para que un DROP por
-- nombre tampoco los alcance por accidente.
--
-- Requiere que existan INVENTARIOS y EXISTENCIAS. No las crea ni las altera.
--
-- COMO EJECUTAR
--   1. Frena `npm run dev` (no hay modulo ORDS aca, pero la tabla se toca).
--   2. Pega este archivo entero en la hoja SQL de APEX y ejecutalo.
--   3. Revisa que los dos triggers queden ENABLED y VALID (bloque final).
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 0. Chequeo previo
--
-- El INSERT de EXISTENCIAS omite ID_EXISTENCIA y confia en que la columna se
-- llene sola. Si no es IDENTITY ni tiene DEFAULT, el cierre va a morir con
-- ORA-01400 recien cuando alguien cierre un conteo — un error tardio y opaco.
-- Mejor enterarse ahora.
--
-- Se consulta IDENTITY_COLUMN y no DATA_DEFAULT: DATA_DEFAULT es LONG y
-- cualquier funcion aplicada sobre ella da ORA-00932.
--------------------------------------------------------------------------------

DECLARE
  l_identity USER_TAB_COLUMNS.IDENTITY_COLUMN%TYPE;
BEGIN
  SELECT IDENTITY_COLUMN
    INTO l_identity
    FROM USER_TAB_COLUMNS
   WHERE TABLE_NAME  = 'EXISTENCIAS'
     AND COLUMN_NAME = 'ID_EXISTENCIA';

  IF l_identity = 'YES' THEN
    DBMS_OUTPUT.PUT_LINE('OK: EXISTENCIAS.ID_EXISTENCIA es IDENTITY.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('ATENCION: EXISTENCIAS.ID_EXISTENCIA no es IDENTITY.');
    DBMS_OUTPUT.PUT_LINE('  Verifica que tenga DEFAULT (una secuencia) o el');
    DBMS_OUTPUT.PUT_LINE('  INSERT del cierre va a fallar con ORA-01400.');
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: no existe EXISTENCIAS.ID_EXISTENCIA. Revisa el DDL.');
END;
/

--------------------------------------------------------------------------------
-- 1. TRG_INVENTARIOS_BIUD — el candado
--
-- Un solo trigger para INSERT, UPDATE y DELETE: las tres responden a la misma
-- pregunta —"esta fila todavia se puede tocar?"— y separarlas obligaria a
-- repetir la comparacion del estado en tres lugares.
--
-- BEFORE porque es el unico momento en que se puede escribir :NEW. Todo lo que
-- este trigger decide se sella aca: el estado normalizado, las fechas y el
-- CANTIDAD_SISTEMA del conteo. La escritura sobre OTRA tabla va en el AFTER.
--------------------------------------------------------------------------------

CREATE OR REPLACE TRIGGER TRG_INVENTARIOS_BIUD
  BEFORE INSERT OR UPDATE OR DELETE ON INVENTARIOS
  FOR EACH ROW
DECLARE
  l_empresa_sucursal SUCURSALES.ID_EMPRESA%TYPE;
  l_empresa_articulo ARTICULOS.ID_EMPRESA%TYPE;

  -- Lo que EXISTENCIAS dice AHORA del articulo del conteo. Sin fila, 0: el
  -- articulo nunca tuvo movimiento en ese deposito. Se lee de :NEW porque en un
  -- INSERT no hay :OLD, y en un UPDATE los ids no cambian (lo impide el paso 2).
  FUNCTION EXISTENCIA_AHORA RETURN NUMBER IS
    l_cantidad NUMBER;
  BEGIN
    SELECT NVL(CANTIDAD_DISPONIBLE, 0)
      INTO l_cantidad
      FROM EXISTENCIAS
     WHERE ID_EMPRESA  = :NEW.ID_EMPRESA
       AND ID_SUCURSAL = :NEW.ID_SUCURSAL
       AND ID_ARTICULO = :NEW.ID_ARTICULO;

    RETURN l_cantidad;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 0;
  END EXISTENCIA_AHORA;
BEGIN

  ------------------------------------------------------------------------------
  -- DELETE: solo se borra un borrador.
  ------------------------------------------------------------------------------
  IF DELETING THEN
    IF NVL(:OLD.ESTADO, 'ABIERTO') != 'ABIERTO' THEN
      RAISE_APPLICATION_ERROR(
        -20103,
        'El inventario ' || :OLD.ID_INVENTARIO || ' esta ' || :OLD.ESTADO ||
        ' y no se puede eliminar. Un conteo cerrado ya movio el stock: ' ||
        'borrarlo dejaria la existencia sin explicacion. Para corregirlo, ' ||
        'carga un conteo nuevo.');
    END IF;

    RETURN;
  END IF;

  ------------------------------------------------------------------------------
  -- INSERT: nace ABIERTO, y con los tres ids de la MISMA empresa.
  --
  -- Las tres FK validan cada una contra su tabla y ninguna mira la empresa: el
  -- DDL por si solo acepta un conteo de la empresa A sobre una sucursal de la
  -- B. Se chequea aca y no en un paquete porque este trigger es, por ahora, lo
  -- unico que hay — y porque la fila que el cierre escribe en EXISTENCIAS
  -- heredaria la misma incoherencia.
  ------------------------------------------------------------------------------
  IF INSERTING THEN
    :NEW.ESTADO := NVL(UPPER(TRIM(:NEW.ESTADO)), 'ABIERTO');

    IF :NEW.ESTADO != 'ABIERTO' THEN
      RAISE_APPLICATION_ERROR(
        -20104,
        'Un inventario nace ABIERTO. Llego "' || :NEW.ESTADO || '". ' ||
        'Cerrarlo o anularlo es un UPDATE posterior, para que el cambio de ' ||
        'estado quede como un acto propio y no escondido en el alta.');
    END IF;

    BEGIN
      SELECT ID_EMPRESA
        INTO l_empresa_sucursal
        FROM SUCURSALES
       WHERE ID_SUCURSAL = :NEW.ID_SUCURSAL;

      IF l_empresa_sucursal != :NEW.ID_EMPRESA THEN
        RAISE_APPLICATION_ERROR(
          -20106,
          'La sucursal ' || :NEW.ID_SUCURSAL || ' es de la empresa ' ||
          l_empresa_sucursal || ', no de la ' || :NEW.ID_EMPRESA || '.');
      END IF;
    EXCEPTION
      -- Sucursal inexistente: que el error lo de la FK, que explica mejor.
      WHEN NO_DATA_FOUND THEN NULL;
    END;

    BEGIN
      SELECT ID_EMPRESA
        INTO l_empresa_articulo
        FROM ARTICULOS
       WHERE ID_ARTICULO = :NEW.ID_ARTICULO;

      IF l_empresa_articulo != :NEW.ID_EMPRESA THEN
        RAISE_APPLICATION_ERROR(
          -20106,
          'El articulo ' || :NEW.ID_ARTICULO || ' es de la empresa ' ||
          l_empresa_articulo || ', no de la ' || :NEW.ID_EMPRESA || '.');
      END IF;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN NULL;
    END;

    -- El sello del conteo. PKG_INVENTARIOS inserta con la cantidad en NULL (la
    -- suma llega despues, con las lineas), pero un INSERT a mano puede traerla:
    -- en ese caso se sella aca, y lo que haya mandado el INSERT en esta columna
    -- no se respeta — es un dato del sistema, no del que carga.
    :NEW.CANTIDAD_SISTEMA := CASE WHEN :NEW.CANTIDAD_FISICA IS NOT NULL
                                  THEN EXISTENCIA_AHORA END;

    :NEW.FECHA_INVENTARIO    := NVL(:NEW.FECHA_INVENTARIO, SYSTIMESTAMP);
    :NEW.FECHA_CREACION      := SYSTIMESTAMP;
    :NEW.FECHA_ACTUALIZACION := SYSTIMESTAMP;

    RETURN;
  END IF;

  ------------------------------------------------------------------------------
  -- UPDATE
  ------------------------------------------------------------------------------

  -- 1. El candado. Cerrado o anulado, no se toca nada: ni la cantidad, ni las
  --    observaciones, ni el estado. Es lo que hace que el numero de EXISTENCIAS
  --    siga teniendo detras el papel que lo justifica.
  IF NVL(:OLD.ESTADO, 'ABIERTO') != 'ABIERTO' THEN
    RAISE_APPLICATION_ERROR(
      -20102,
      'El inventario ' || :OLD.ID_INVENTARIO || ' esta ' || :OLD.ESTADO ||
      ' y ya no se modifica. Un conteo cerrado es evidencia de lo que se ' ||
      'conto ese dia; si el numero cambio, carga un conteo nuevo.');
  END IF;

  -- 2. Los ids no se mueven. Cambiar la empresa moveria el conteo —y el ajuste
  --    de stock que dispara— a otra empresa; cambiar la sucursal o el articulo
  --    lo aplicaria sobre una existencia que nadie conto. Es otro conteo, no
  --    una correccion de este.
  IF    :NEW.ID_EMPRESA  != :OLD.ID_EMPRESA
     OR :NEW.ID_SUCURSAL != :OLD.ID_SUCURSAL
     OR :NEW.ID_ARTICULO != :OLD.ID_ARTICULO THEN
    RAISE_APPLICATION_ERROR(
      -20106,
      'Empresa, sucursal y articulo no se modifican en un conteo. Contar ' ||
      'otro articulo o en otro deposito es cargar otro inventario.');
  END IF;

  -- 3. Transiciones validas desde ABIERTO.
  :NEW.ESTADO := NVL(UPPER(TRIM(:NEW.ESTADO)), 'ABIERTO');

  IF :NEW.ESTADO NOT IN ('ABIERTO', 'CERRADO', 'ANULADO') THEN
    RAISE_APPLICATION_ERROR(
      -20101,
      'Estado "' || :NEW.ESTADO || '" invalido. Desde ABIERTO se va a ' ||
      'CERRADO (aplica el conteo) o a ANULADO (lo descarta). PROCESADO es un ' ||
      'valor legado de cuando el stock vivia en lotes: ninguna transicion lo ' ||
      'produce.');
  END IF;

  -- 4. Cerrar exige un numero contado. Sin esto, un cierre con CANTIDAD_FISICA
  --    en NULL escribiria NULL en EXISTENCIAS — y un NULL ahi no da error: hace
  --    que el articulo desaparezca de los faltantes y anule cualquier suma.
  IF :NEW.ESTADO = 'CERRADO' THEN
    IF :NEW.CANTIDAD_FISICA IS NULL THEN
      RAISE_APPLICATION_ERROR(
        -20105,
        'No se puede cerrar el inventario ' || :OLD.ID_INVENTARIO ||
        ' sin CANTIDAD_FISICA: es el numero que va a quedar como existencia.');
    END IF;

    IF :NEW.CANTIDAD_FISICA < 0 THEN
      RAISE_APPLICATION_ERROR(
        -20105,
        'CANTIDAD_FISICA no puede ser negativa (' || :NEW.CANTIDAD_FISICA ||
        '): es lo que se conto en el estante.');
    END IF;

    -- EL SELLO DEL CONTEO SE CONSERVA: es contra ese numero que el AFTER
    -- calcula la diferencia, y es lo que el sistema decia cuando se conto (ver
    -- el encabezado). Se sella ACA solo en dos casos:
    --
    --   - Esta en NULL: un conteo abierto antes de que el sello pasara a
    --     hacerse al contar. Se comporta como antes.
    --   - El mismo UPDATE que cierra cambia la cantidad (una correccion a mano
    --     en la hoja SQL): el sello viejo es de otro numero.
    IF :NEW.CANTIDAD_SISTEMA IS NULL
       OR :OLD.CANTIDAD_FISICA IS NULL
       OR :NEW.CANTIDAD_FISICA != :OLD.CANTIDAD_FISICA THEN
      :NEW.CANTIDAD_SISTEMA := EXISTENCIA_AHORA;
    END IF;

  -- 4b. Sigue ABIERTO: se sella cuando cambia lo contado, y SOLO entonces. Ver
  --     el encabezado: cambiar las observaciones no mueve el sello.
  ELSIF :NEW.ESTADO = 'ABIERTO' THEN
    IF :NEW.CANTIDAD_FISICA IS NULL THEN
      -- Quedo un estante sin contar: todavia no hay conteo que sellar.
      :NEW.CANTIDAD_SISTEMA := NULL;
    ELSIF :OLD.CANTIDAD_FISICA IS NULL
          OR :NEW.CANTIDAD_FISICA != :OLD.CANTIDAD_FISICA THEN
      :NEW.CANTIDAD_SISTEMA := EXISTENCIA_AHORA;
    ELSE
      -- La cantidad no cambio: el sello queda como estaba aunque el UPDATE
      -- haya mandado otro valor en esta columna.
      :NEW.CANTIDAD_SISTEMA := :OLD.CANTIDAD_SISTEMA;
    END IF;
  END IF;

  -- 5. Sellos de tiempo. FECHA_CREACION se restaura por si el UPDATE la mando:
  --    la fecha de alta de una fila no se corrige.
  :NEW.FECHA_CREACION      := :OLD.FECHA_CREACION;
  :NEW.FECHA_ACTUALIZACION := SYSTIMESTAMP;

END;
/

--------------------------------------------------------------------------------
-- 2. TRG_INVENTARIOS_AU_EXISTENCIAS — el ajuste
--
-- AFTER porque escribe OTRA tabla, y solo tiene sentido hacerlo cuando la fila
-- del conteo ya quedo firme. El WHEN acota el disparo a la unica transicion con
-- efecto: nada de ANULADO, nada de una correccion que deja el estado en ABIERTO.
--
-- NO hay problema de tabla mutante: se escribe EXISTENCIAS, no INVENTARIOS.
--
-- UPDATE primero e INSERT despues, y no un MERGE. El UPDATE bloquea la fila si
-- existe —que es el FOR UPDATE que este modelo pide, gratis— y el MERGE tampoco
-- se salva del ORA-00001 cuando dos sesiones insertan el mismo articulo a la
-- vez. El DUP_VAL_ON_INDEX se captura y se resuelve con el UPDATE que ahora si
-- encuentra la fila.
--
--------------------------------------------------------------------------------
-- AJUSTA POR DIFERENCIA, NO FIJA LA CANTIDAD. ESTO CAMBIO.
--
-- Hasta que existio PKG_STOCK este trigger escribia
--
--     CANTIDAD_DISPONIBLE := CANTIDAD_FISICA
--
-- y estaba bien, porque era el UNICO escritor de la tabla: nada mas se movia
-- entre el conteo y el cierre. Con ventas y compras moviendo stock eso ya no es
-- cierto, y fijar la cantidad BORRA todo lo que paso en el medio.
--
-- El caso concreto: se cuenta el lunes y hay 100. El martes se venden 30, asi
-- que EXISTENCIAS dice 70. El miercoles alguien cierra el conteo del lunes. Con
-- la version anterior la tabla vuelve a 100 y las 30 vendidas reaparecen en el
-- deposito. Con el ajuste por diferencia se aplica (100 - 100) = 0 y queda en
-- 70, que es lo correcto: el conteo del lunes no encontro ninguna diferencia, y
-- las ventas del martes son reales.
--
-- LA DIFERENCIA ES CONTRA CANTIDAD_SISTEMA, que el otro trigger sello con lo que
-- EXISTENCIAS decia CUANDO SE CONTO (cuando cambio CANTIDAD_FISICA por ultima
-- vez), no en el cierre. Sellarla en el cierre era restar contra la existencia
-- de ese instante: el ejemplo de arriba daba 100 - 70 = +30, y el ajuste por
-- diferencia terminaba haciendo lo mismo que fijar la cantidad.
--
-- SI CANTIDAD_SISTEMA VINIERA NULL el ajuste seria la cantidad fisica entera:
-- para un articulo sin fila de existencia eso es correcto (arranca de cero), y
-- el otro trigger garantiza que nunca es NULL en un cierre porque, si falta, la
-- sella ahi mismo. El NVL de aca es defensivo, no decorativo.
--------------------------------------------------------------------------------

CREATE OR REPLACE TRIGGER TRG_INVENTARIOS_AU_EXISTENCIAS
  AFTER UPDATE ON INVENTARIOS
  FOR EACH ROW
  WHEN (NEW.ESTADO = 'CERRADO' AND NVL(OLD.ESTADO, 'ABIERTO') = 'ABIERTO')
DECLARE
  -- Lo que el conteo corrige: cuanto habia de mas o de menos en el estante
  -- respecto de lo que el sistema creia cuando se conto.
  l_ajuste NUMBER := NVL(:NEW.CANTIDAD_FISICA, 0) - NVL(:NEW.CANTIDAD_SISTEMA, 0);
BEGIN

  UPDATE EXISTENCIAS
     SET CANTIDAD_DISPONIBLE     = NVL(CANTIDAD_DISPONIBLE, 0) + l_ajuste,
         FECHA_ULTIMO_MOVIMIENTO = SYSTIMESTAMP,
         FECHA_ACTUALIZACION     = SYSTIMESTAMP
   WHERE ID_EMPRESA  = :NEW.ID_EMPRESA
     AND ID_SUCURSAL = :NEW.ID_SUCURSAL
     AND ID_ARTICULO = :NEW.ID_ARTICULO;

  IF SQL%ROWCOUNT = 0 THEN
    BEGIN
      -- Sin fila previa, el disponible parte de cero y el ajuste ES la cantidad
      -- contada (CANTIDAD_SISTEMA se sello en 0 justamente porque no habia fila).
      INSERT INTO EXISTENCIAS (
        ID_EMPRESA,
        ID_SUCURSAL,
        ID_ARTICULO,
        CANTIDAD_DISPONIBLE,
        FECHA_ULTIMO_MOVIMIENTO,
        FECHA_CREACION,
        FECHA_ACTUALIZACION
      ) VALUES (
        :NEW.ID_EMPRESA,
        :NEW.ID_SUCURSAL,
        :NEW.ID_ARTICULO,
        l_ajuste,
        SYSTIMESTAMP,
        SYSTIMESTAMP,
        SYSTIMESTAMP
      );
    EXCEPTION
      -- Otra sesion creo la fila entre el UPDATE y el INSERT.
      WHEN DUP_VAL_ON_INDEX THEN
        UPDATE EXISTENCIAS
           SET CANTIDAD_DISPONIBLE     = NVL(CANTIDAD_DISPONIBLE, 0) + l_ajuste,
               FECHA_ULTIMO_MOVIMIENTO = SYSTIMESTAMP,
               FECHA_ACTUALIZACION     = SYSTIMESTAMP
         WHERE ID_EMPRESA  = :NEW.ID_EMPRESA
           AND ID_SUCURSAL = :NEW.ID_SUCURSAL
           AND ID_ARTICULO = :NEW.ID_ARTICULO;
    END;
  END IF;

END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--
-- MIRA ESTA SALIDA. Un trigger INVALID no falla al crearse: falla despues, y
-- bloquea TODO INSERT y UPDATE de la tabla. Fue exactamente lo que dejo a
-- INVENTARIOS sin aceptar una fila cuando los viejos quedaron colgando de LOTES.
--------------------------------------------------------------------------------

-- Los dos, ENABLED y VALID.
SELECT TRIGGER_NAME,
       TRIGGER_TYPE,
       TRIGGERING_EVENT,
       STATUS
  FROM USER_TRIGGERS
 WHERE TABLE_NAME = 'INVENTARIOS'
 ORDER BY TRIGGER_NAME;

-- Sin filas. Si hay alguna, el trigger no compilo y la tabla esta bloqueada.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME IN ('TRG_INVENTARIOS_BIUD', 'TRG_INVENTARIOS_AU_EXISTENCIAS')
 ORDER BY NAME, SEQUENCE;

-- Estados presentes en la tabla. PROCESADO solo puede venir de filas viejas;
-- ninguna transicion nueva lo produce.
SELECT ESTADO, COUNT(*) AS CANTIDAD
  FROM INVENTARIOS
 GROUP BY ESTADO
 ORDER BY ESTADO;

-- Conteos cerrados contra la existencia que dejaron. DIFERENCIA es lo que
-- corrigio cada uno. La existencia actual NO tiene por que coincidir con la
-- CANTIDAD_FISICA: el ajuste respeta lo que se vendio y compro entre el conteo
-- y el cierre, y despues siguio moviendose.
SELECT i.ID_INVENTARIO,
       i.ID_SUCURSAL,
       i.ID_ARTICULO,
       i.CANTIDAD_SISTEMA,
       i.CANTIDAD_FISICA,
       i.CANTIDAD_FISICA - NVL(i.CANTIDAD_SISTEMA, 0) AS DIFERENCIA,
       NVL(e.CANTIDAD_DISPONIBLE, 0)                  AS EXISTENCIA_ACTUAL,
       i.FECHA_ACTUALIZACION
  FROM INVENTARIOS i
  LEFT JOIN EXISTENCIAS e
         ON e.ID_EMPRESA  = i.ID_EMPRESA
        AND e.ID_SUCURSAL = i.ID_SUCURSAL
        AND e.ID_ARTICULO = i.ID_ARTICULO
 WHERE i.ESTADO = 'CERRADO'
 ORDER BY i.FECHA_ACTUALIZACION DESC;

-- Filas incoherentes: los tres ids tienen que ser de la misma empresa. El
-- trigger lo impide de ahora en mas; esto muestra lo que haya entrado antes.
-- Cero filas es lo correcto.
SELECT i.ID_INVENTARIO,
       i.ID_EMPRESA AS EMPRESA_CONTEO,
       s.ID_EMPRESA AS EMPRESA_SUCURSAL,
       a.ID_EMPRESA AS EMPRESA_ARTICULO
  FROM INVENTARIOS i
  JOIN SUCURSALES s ON s.ID_SUCURSAL = i.ID_SUCURSAL
  JOIN ARTICULOS  a ON a.ID_ARTICULO = i.ID_ARTICULO
 WHERE i.ID_EMPRESA != s.ID_EMPRESA
    OR i.ID_EMPRESA != a.ID_EMPRESA;
