--------------------------------------------------------------------------------
-- CTELL · INVENTARIOS · TRIGGERS
--
-- Dos triggers sobre INVENTARIOS, y nada mas:
--
--   1. TRG_INVENTARIOS_BIUD            Congela el conteo al cerrarlo.
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
-- EL CONTEO FIJA LA CANTIDAD, NO LA AJUSTA
--
--   EXISTENCIAS.CANTIDAD_DISPONIBLE := INVENTARIOS.CANTIDAD_FISICA
--
-- Lo que hay en el estante manda. La alternativa —sumar la diferencia contra
-- CANTIDAD_SISTEMA— sobrevive a los movimientos ocurridos entre el conteo y el
-- cierre, pero hoy NINGUNA transaccion mueve stock (comprar no ingresa, vender
-- no descuenta), asi que no hay nada que sobrevivir y la diferencia seria una
-- indireccion sin efecto.
--
-- CUANDO EXISTA PKG_STOCK HAY QUE VOLVER SOBRE ESTO. Con compras y ventas
-- moviendo la existencia, un cierre tardio pisaria las ventas posteriores al
-- conteo. Ahi el ajuste pasa a ser por diferencia, o el trigger delega en
-- PKG_STOCK para que el movimiento quede asentado en el libro.
--
-- CANTIDAD_SISTEMA se sella EN EL CIERRE, con lo que EXISTENCIAS decia justo
-- antes de que este trigger la pisara. No es lo que el formulario haya cargado
-- al abrir el conteo: el numero que explica el ajuste es el que el ajuste
-- reemplazo. Sin el, la fila no deja rastro de cuanto se corrigio.
--
--------------------------------------------------------------------------------
-- ESTE ES EL PRIMER ESCRITOR DE EXISTENCIAS
--
-- Hasta hoy la tabla era de solo lectura (ver db/existencias.sql) y esta escrito
-- que PKG_STOCK iba a ser su unico escritor. Un conteo fisico es la excepcion
-- razonable —no es una transaccion, es la correccion de las transacciones— pero
-- conviene saberlo: cuando PKG_STOCK exista van a ser dos, y hay que decidir si
-- el cierre pasa a llamarlo en vez de escribir la tabla de frente.
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
-- CANTIDAD_SISTEMA del cierre. La escritura sobre OTRA tabla va en el AFTER.
--------------------------------------------------------------------------------

CREATE OR REPLACE TRIGGER TRG_INVENTARIOS_BIUD
  BEFORE INSERT OR UPDATE OR DELETE ON INVENTARIOS
  FOR EACH ROW
DECLARE
  l_empresa_sucursal SUCURSALES.ID_EMPRESA%TYPE;
  l_empresa_articulo ARTICULOS.ID_EMPRESA%TYPE;
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

    -- Se sella lo que EXISTENCIAS dice AHORA, un instante antes de que el
    -- AFTER la pise. Es el unico rastro de cuanto corrigio este conteo.
    BEGIN
      SELECT NVL(CANTIDAD_DISPONIBLE, 0)
        INTO :NEW.CANTIDAD_SISTEMA
        FROM EXISTENCIAS
       WHERE ID_EMPRESA  = :NEW.ID_EMPRESA
         AND ID_SUCURSAL = :NEW.ID_SUCURSAL
         AND ID_ARTICULO = :NEW.ID_ARTICULO;
    EXCEPTION
      -- Sin fila de existencia, el sistema decia 0: el articulo nunca tuvo
      -- movimiento en ese deposito.
      WHEN NO_DATA_FOUND THEN
        :NEW.CANTIDAD_SISTEMA := 0;
    END;
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
--------------------------------------------------------------------------------

CREATE OR REPLACE TRIGGER TRG_INVENTARIOS_AU_EXISTENCIAS
  AFTER UPDATE ON INVENTARIOS
  FOR EACH ROW
  WHEN (NEW.ESTADO = 'CERRADO' AND NVL(OLD.ESTADO, 'ABIERTO') = 'ABIERTO')
BEGIN

  UPDATE EXISTENCIAS
     SET CANTIDAD_DISPONIBLE     = :NEW.CANTIDAD_FISICA,
         FECHA_ULTIMO_MOVIMIENTO = SYSTIMESTAMP,
         FECHA_ACTUALIZACION     = SYSTIMESTAMP
   WHERE ID_EMPRESA  = :NEW.ID_EMPRESA
     AND ID_SUCURSAL = :NEW.ID_SUCURSAL
     AND ID_ARTICULO = :NEW.ID_ARTICULO;

  IF SQL%ROWCOUNT = 0 THEN
    BEGIN
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
        :NEW.CANTIDAD_FISICA,
        SYSTIMESTAMP,
        SYSTIMESTAMP,
        SYSTIMESTAMP
      );
    EXCEPTION
      -- Otra sesion creo la fila entre el UPDATE y el INSERT.
      WHEN DUP_VAL_ON_INDEX THEN
        UPDATE EXISTENCIAS
           SET CANTIDAD_DISPONIBLE     = :NEW.CANTIDAD_FISICA,
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
-- corrigio cada uno. La existencia de un cerrado deberia coincidir con su
-- CANTIDAD_FISICA, salvo que un conteo posterior la haya vuelto a mover.
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
