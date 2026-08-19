--------------------------------------------------------------------------------
-- CTELL · INVENTARIOS
--
-- Un paquete (PKG_INVENTARIOS) con la carga de conteos fisicos y su maquina de
-- estados, mas la publicacion de los endpoints ORDS.
--
--   1. LISTAR     GET  /inventarios/listar   (?idEmpresa= &idSucursal= &idArticulo= &estado=)
--   2. INSERTAR   POST /inventarios/crear
--   3. ACTUALIZAR PUT  /inventarios/actualizar/:id
--   4. PROCESAR   POST /inventarios/procesar/:id/:idEmpresa
--   5. ANULAR     POST /inventarios/anular/:id/:idEmpresa
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace.
--
-- REQUIERE, EN ESTE ORDEN:
--   1. db/auth.sql              (PKG_AUTH: valida el token)
--   2. db/lotes.sql             (el conteo cuelga de un lote)
--   3. db/inventarios-triggers-ddl.sql  <-- LOS TRIGGERS CORREGIDOS
--
-- El tercero NO es opcional. Los triggers que vinieron con el DDL original
-- ajustaban la columna equivocada de LOTES y guardaban el usuario de Oracle en
-- vez del de la app; ese archivo los reemplaza y explica por que. Con los
-- triggers viejos este paquete compila igual pero PROCESAR no mueve el stock.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/inventarios/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   INVENTARIOS  ID_INVENTARIO, ID_EMPRESA, ID_SUCURSAL, ID_LOTE, ID_ARTICULO,
--                CANTIDAD_SISTEMA, CANTIDAD_FISICA, ESTADO, ID_USUARIO,
--                FECHA_INVENTARIO, OBSERVACIONES,
--                FECHA_CREACION, FECHA_ACTUALIZACION
--
--------------------------------------------------------------------------------
-- QUE ES UN INVENTARIO ACA: UNA FILA POR LOTE CONTADO
--
-- No es una "cabecera de inventario" con muchas lineas. Cada fila es el conteo
-- fisico de UN lote: cuanto decia el sistema, cuanto se conto de verdad, y la
-- diferencia entre los dos. Es lo que permite la FK a LOTES siendo NOT NULL.
--
-- CANTIDAD_SISTEMA vs CANTIDAD_FISICA:
--   CANTIDAD_SISTEMA  lo que el sistema creia que habia AL MOMENTO DE CONTAR.
--                     Es una FOTO, no un dato vivo: se copia del lote al crear
--                     el conteo y NO se recalcula despues. Si se recalculara, la
--                     diferencia se moveria sola entre que se cuenta y se
--                     procesa, y el registro dejaria de probar nada.
--   CANTIDAD_FISICA   lo que se conto con las manos. Es el unico dato que
--                     aporta la persona.
--
-- La diferencia (FISICA - SISTEMA) se calcula en el listado y no se guarda: una
-- columna calculada que se puede derivar de otras dos es una oportunidad de que
-- las tres queden inconsistentes.
--
--------------------------------------------------------------------------------
-- LA MAQUINA DE ESTADOS VIVE EN LOS TRIGGERS, NO ACA
--
--   ABIERTO    editable, todavia no aplicado. Todo conteo nace asi.
--   PROCESADO  aplicado al lote. Terminal.
--   ANULADO    descartado sin aplicar. Terminal.
--
-- Transiciones permitidas: ABIERTO -> PROCESADO y ABIERTO -> ANULADO. Nada mas.
-- Desde un estado terminal no se sale, y un conteo que ya no esta ABIERTO no
-- deja tocar su CANTIDAD_FISICA.
--
-- Eso lo IMPONE TRG_INVENTARIOS_BIU con RAISE_APPLICATION_ERROR, y esta bien que
-- sea asi: vale aunque alguien toque la tabla por fuera de esta API. Lo que hace
-- este paquete es CHEQUEAR ANTES para devolver un 409 con un mensaje legible en
-- vez de dejar salir un ORA-20002 crudo como error 500. Los dos controles no
-- sobran: el del paquete es para que se entienda, el del trigger es el que de
-- verdad no se puede esquivar.
--
-- POR ESO EL MODULO NO TIENE /eliminar. TRG_INVENTARIOS_BD prohibe el DELETE con
-- ORA-20004 ("use ANULAR"), que es exactamente la decision correcta: un conteo
-- fisico es evidencia de que alguien fue al deposito y conto. Borrarlo hace
-- desaparecer esa evidencia; anularlo la deja asentada junto al motivo por el
-- que se descarto. El /anular de este modulo ocupa el lugar del /eliminar de las
-- demas tablas.
--
--------------------------------------------------------------------------------
-- PROCESAR AJUSTA CANTIDAD_DISPON, NO CANTIDAD
--
-- Lo hace TRG_INVENTARIOS_AU, en la misma transaccion que el cambio de estado.
-- Este paquete NO toca LOTES: si lo hiciera ademas del trigger, el ajuste se
-- aplicaria dos veces.
--
-- El motivo de que sea CANTIDAD_DISPON esta explicado a fondo en
-- db/inventarios-triggers-ddl.sql. En una linea: el stock de un articulo es la
-- SUMA de CANTIDAD_DISPON de sus lotes, asi que ajustar CANTIDAD dejaba el stock
-- de la pantalla sin cambios y el inventario no servia para nada.
--
--------------------------------------------------------------------------------
-- ID_USUARIO LO ESCRIBE ESTE PAQUETE
--
-- Es una FK a USUARIOS y guarda QUIEN PROCESO el conteo. Queda NULL mientras
-- esta ABIERTO, y tambien en los ANULADOS: ahi nadie aplico nada.
--
-- El id sale del token — PKG_AUTH.VALIDAR_TOKEN ya devuelve el ID_USUARIO, asi
-- que no hay que resolver nada. El trigger no puede hacerlo: dentro de un
-- handler de ORDS no hay sesion de base por usuario, y el USER que usaba el
-- trigger viejo devolvia el esquema del workspace, igual para todo el mundo.
--
-- ES UNA FK Y NO UN TEXTO COPIADO, que es lo que hacia la columna anterior
-- (USUARIO_PROCESA VARCHAR2(100)). La diferencia importa: el nombre del listado
-- sale del JOIN, asi que si alguien corrige su nombre en USUARIOS el historico
-- lo refleja en vez de quedar con el texto viejo. Y la base garantiza que el id
-- corresponda a un usuario real.
--
--------------------------------------------------------------------------------
-- AISLAMIENTO POR EMPRESA
--
-- Como toda tabla por empresa: ACTUALIZAR, PROCESAR y ANULAR exigen idEmpresa y
-- lo llevan EN EL WHERE, no solo en los campos. Sin eso, un PUT con el id de una
-- fila de otra empresa la modificaba igual. La respuesta es 404 y no 403: decir
-- "existe pero no es tuya" ya confirma que el id existe.
--
-- ID_EMPRESA, ID_SUCURSAL, ID_LOTE e ID_ARTICULO NO son modificables. Cambiar
-- cualquiera convertiria el conteo en otro conteo distinto — si el lote estaba
-- mal, se anula y se carga de nuevo.
--
-- CUATRO FK QUE NO SE VALIDAN ENTRE SI. El DDL declara las cuatro por separado,
-- asi que por si solo acepta un lote de otra empresa, de otra sucursal, o de un
-- articulo que no es el del lote. INSERTAR lo verifica todo junto contra LOTES,
-- que es la fila que ya tiene las tres relaciones resueltas: el lote manda, y de
-- ahi salen la sucursal y el articulo. El archivo cierra con las consultas de
-- auditoria correspondientes, que deben devolver cero filas.
--
--------------------------------------------------------------------------------
-- COMO EJECUTAR
--
--   1. Frena `npm run dev` (evita ORA-00060 al borrar el modulo).
--   2. Corre db/inventarios-triggers-ddl.sql si todavia no lo hiciste.
--   3. Pega este archivo entero en la hoja SQL de APEX y ejecutalo.
--   4. Revisa que PKG_INVENTARIOS quede VALID y que USER_ERRORS no traiga nada.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_INVENTARIOS AS

  -- Todos los filtros son opcionales y se combinan. En la app siempre viajan al
  -- menos idEmpresa e idSucursal, que salen de los providers de la sesion.
  -- p_estado acepta ABIERTO, PROCESADO o ANULADO; vacio trae todos.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_estado        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Crea el conteo de un lote. La sucursal, el articulo y CANTIDAD_SISTEMA NO se
  -- reciben: salen del lote, que es quien los tiene resueltos. Mandarlos seria
  -- pedirle al cliente un dato que la base ya sabe, y abrir la puerta a que
  -- llegue mal.
  --
  -- Nace ABIERTO siempre: lo fuerza TRG_INVENTARIOS_BIU.
  PROCEDURE INSERTAR (
    p_authorization    IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_id_lote          IN  VARCHAR2,
    p_cantidad_fisica  IN  VARCHAR2,
    p_fecha_inventario IN  VARCHAR2,
    p_observaciones    IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  );

  -- Corrige un conteo TODAVIA ABIERTO. Los parametros ausentes no modifican su
  -- columna. No cambia el estado: para eso estan PROCESAR y ANULAR.
  --
  -- Un conteo que ya no esta ABIERTO devuelve 409.
  PROCEDURE ACTUALIZAR (
    p_authorization    IN  VARCHAR2,
    p_id               IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_cantidad_fisica  IN  VARCHAR2,
    p_fecha_inventario IN  VARCHAR2,
    p_observaciones    IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  );

  -- ABIERTO -> PROCESADO. Aplica el conteo al lote (via TRG_INVENTARIOS_AU) y
  -- sella quien lo hizo. Es IRREVERSIBLE: no hay vuelta a ABIERTO.
  PROCEDURE PROCESAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- ABIERTO -> ANULADO. Descarta el conteo SIN tocar el lote. Ocupa el lugar del
  -- /eliminar de las demas tablas: el DELETE esta prohibido por trigger.
  PROCEDURE ANULAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /inventarios/ con sus endpoints.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_INVENTARIOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_INVENTARIOS AS

  -- Mismo formato ISO que el resto del proyecto. Un TIMESTAMP crudo sale en el
  -- JSON con el formato NLS de la sesion ('17-AGO-26 10.30.00'), que
  -- `new Date()` no parsea y deja "Invalid Date" en pantalla.
  C_FORMATO_FECHA CONSTANT VARCHAR2(30) := 'YYYY-MM-DD"T"HH24:MI:SS';

  ------------------------------------------------------------------------------
  -- Privado: borra el modulo ORDS si existe, reintentando ante un interbloqueo.
  --
  -- Nunca usar `WHEN OTHERS THEN NULL` aca: se tragaria tambien un ORA-00060,
  -- el DELETE fallaria en silencio, y el DEFINE_MODULE de despues moriria con
  -- ORA-00001 (nombre duplicado) contra el modulo que nunca se llego a borrar.
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
         WHERE NAME = 'inventarios';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'inventarios');
        COMMIT;  -- Libera los locks antes de que DEFINE_MODULE los vuelva a pedir.
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
          -- ORA-00060 (interbloqueo) y ORA-04020 (lock de objeto) son
          -- transitorios: la otra sesion termina y el reintento pasa.
          IF SQLCODE IN (-60, -4020) AND i < C_INTENTOS THEN
            ROLLBACK;
            DBMS_SESSION.SLEEP(2);
          ELSE
            RAISE;
          END IF;
      END;
    END LOOP;
  END BORRAR_MODULO;

  -- NO hay funcion para resolver el usuario: ID_USUARIO es una FK y
  -- PKG_AUTH.VALIDAR_TOKEN ya devuelve el ID_USUARIO del token, asi que el valor
  -- que hay que guardar es exactamente el que se tiene. El nombre para mostrar
  -- sale del JOIN en LISTAR.

  ------------------------------------------------------------------------------
  -- Privado: convierte "2026-08-18" o "2026-08-18T14:30:00" a TIMESTAMP.
  --
  -- El frontend manda ISO. Se aceptan las dos formas porque una fecha de conteo
  -- puede venir de un <input type="date"> (solo dia) o llevar la hora.
  -- Devuelve NULL si el texto no es una fecha, y el llamador decide que hacer.
  ------------------------------------------------------------------------------
  FUNCTION A_TIMESTAMP (p_texto IN VARCHAR2) RETURN TIMESTAMP IS
    l_limpio VARCHAR2(40) := TRIM(p_texto);
  BEGIN
    IF l_limpio IS NULL THEN
      RETURN NULL;
    END IF;

    IF LENGTH(l_limpio) <= 10 THEN
      RETURN TO_TIMESTAMP(l_limpio, 'YYYY-MM-DD');
    END IF;

    -- La T de la ISO se reemplaza por un espacio: TO_TIMESTAMP no la interpreta
    -- como separador y fallaria con ORA-01858.
    RETURN TO_TIMESTAMP(REPLACE(l_limpio, 'T', ' '), 'YYYY-MM-DD HH24:MI:SS');
  EXCEPTION
    WHEN OTHERS THEN
      RETURN NULL;
  END A_TIMESTAMP;

  ------------------------------------------------------------------------------
  -- Privado: pasa un conteo ABIERTO a un estado terminal.
  --
  -- PROCESAR y ANULAR hacen exactamente lo mismo salvo el estado destino y si
  -- sellan o no el usuario, asi que comparten cuerpo. Duplicarlo significaba dos
  -- lugares donde arreglar el aislamiento por empresa el dia que cambie.
  --
  -- p_sella_usuario distingue los dos casos: procesar deja constancia de quien
  -- aplico el ajuste; anular no, porque no aplico nada.
  ------------------------------------------------------------------------------
  PROCEDURE CAMBIAR_ESTADO (
    p_authorization  IN  VARCHAR2,
    p_id             IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_estado_destino IN  VARCHAR2,
    p_sella_usuario  IN  BOOLEAN,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id         NUMBER;
    l_id_empresa NUMBER;
    l_estado     VARCHAR2(20);
    l_id_usuario NUMBER;
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

    -- Se lee el estado ANTES de intentar el UPDATE, y acotado por empresa. Dos
    -- motivos: distinguir "no existe / no es tuya" (404) de "ya estaba
    -- procesado" (409), y poder devolver un mensaje que diga QUE estado tenia.
    -- Sin esto, las dos situaciones llegarian como el mismo ORA-20002 o el mismo
    -- ROWCOUNT = 0, y el usuario no sabria cual de las dos le paso.
    BEGIN
      SELECT ESTADO INTO l_estado
        FROM INVENTARIOS
       WHERE ID_INVENTARIO = l_id
         AND ID_EMPRESA    = l_id_empresa;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        -- 404 y no 403 aunque exista en otra empresa: confirmar que el id existe
        -- ya es informacion que no corresponde dar.
        p_status_code := 404;
        p_resultado := '{"error":"El inventario no existe"}';
        RETURN;
    END;

    IF l_estado != 'ABIERTO' THEN
      p_status_code := 409;
      p_resultado := JSON_OBJECT(
        'error' VALUE 'El inventario ya esta ' || LOWER(l_estado) ||
                      ' y no se puede modificar'
      );
      RETURN;
    END IF;

    -- El id del token ES el valor a guardar: VALIDAR_TOKEN devuelve el
    -- ID_USUARIO y la columna es una FK a esa misma tabla.
    IF p_sella_usuario THEN
      l_id_usuario := l_sesion;
    END IF;

    -- El UPDATE repite el AND ID_EMPRESA aunque el SELECT de arriba ya lo
    -- verifico: entre los dos hay una ventana en la que otra sesion pudo tocar
    -- la fila, y el aislamiento tiene que estar en la sentencia que escribe.
    --
    -- ID_USUARIO se escribe en el mismo UPDATE que el estado, no despues: un
    -- segundo UPDATE sobre una fila ya PROCESADA chocaria contra el propio
    -- TRG_INVENTARIOS_BIU.
    --
    -- Este UPDATE dispara TRG_INVENTARIOS_AU cuando el destino es PROCESADO, y
    -- ES ESE TRIGGER el que ajusta LOTES.CANTIDAD_DISPON. Por eso el paquete no
    -- toca LOTES: hacerlo aplicaria el ajuste dos veces.
    UPDATE INVENTARIOS
       SET ESTADO     = p_estado_destino,
           ID_USUARIO = NVL(l_id_usuario, ID_USUARIO)
     WHERE ID_INVENTARIO = l_id
       AND ID_EMPRESA    = l_id_empresa
       AND ESTADO        = 'ABIERTO';

    IF SQL%ROWCOUNT = 0 THEN
      -- Llegar aca significa que otra sesion lo cambio entre el SELECT y el
      -- UPDATE. Es 409 y no 404: la fila existe, lo que ya no vale es el estado.
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"El inventario cambio de estado, volve a cargar la pagina"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- Los tres errores de la maquina de estados llegan si algo se escapo de
      -- los chequeos de arriba (otra sesion, o alguien tocando la tabla a mano).
      -- Se traducen a 409 con el texto del trigger, que ya explica el caso.
      IF SQLCODE BETWEEN -20003 AND -20001 THEN
        p_status_code := 409;
        p_resultado := JSON_OBJECT('error' VALUE SQLERRM);
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_INVENTARIOS.CAMBIAR_ESTADO(' || p_estado_destino || '): [' ||
                         SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al cambiar el estado del inventario"}';
      END IF;
  END CAMBIAR_ESTADO;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_estado        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id_empresa  NUMBER;
    l_id_sucursal NUMBER;
    l_id_articulo NUMBER;
    l_estado      VARCHAR2(20);
    l_total       NUMBER;
    l_items       CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van dentro del BEGIN: en el DECLARE se ejecutarian antes
    -- de que exista el EXCEPTION y el error escaparia del procedimiento. NULLIF
    -- convierte la cadena vacia del parametro ausente en NULL antes de que
    -- TO_NUMBER la toque (si no, ORA-01722).
    l_id_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    l_id_articulo := TO_NUMBER(NULLIF(p_id_articulo, ''));
    -- Un estado desconocido se ignora en vez de filtrar por el: filtrar por algo
    -- que no existe devuelve cero filas y parece que no hay datos cargados.
    l_estado      := CASE UPPER(TRIM(p_estado))
                       WHEN 'ABIERTO'   THEN 'ABIERTO'
                       WHEN 'PROCESADO' THEN 'PROCESADO'
                       WHEN 'ANULADO'   THEN 'ANULADO'
                       ELSE NULL
                     END;

    SELECT COUNT(*)
      INTO l_total
      FROM INVENTARIOS
     WHERE (l_id_empresa  IS NULL OR ID_EMPRESA  = l_id_empresa)
       AND (l_id_sucursal IS NULL OR ID_SUCURSAL = l_id_sucursal)
       AND (l_id_articulo IS NULL OR ID_ARTICULO = l_id_articulo)
       AND (l_estado      IS NULL OR ESTADO      = l_estado);

    -- JOIN interno contra ARTICULOS y LOTES, no LEFT: las dos FK son NOT NULL,
    -- asi que un conteo sin articulo o sin lote no puede existir. Con LEFT JOIN
    -- el codigo diria que ese caso es posible y confundiria al que lo lea.
    --
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: con OBSERVACIONES de hasta 1000 caracteres por fila, ese techo se
    -- alcanza con tres o cuatro conteos.
    SELECT JSON_ARRAYAGG(fila ORDER BY fecha DESC, id DESC RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'               VALUE i.ID_INVENTARIO,
                 'idEmpresa'        VALUE i.ID_EMPRESA,
                 'idSucursal'       VALUE i.ID_SUCURSAL,
                 'idLote'           VALUE i.ID_LOTE,
                 'idArticulo'       VALUE i.ID_ARTICULO,
                 -- Del JOIN: sin esto el frontend tendria que traerse las tablas
                 -- enteras para mostrar una lista legible.
                 'nombreArticulo'   VALUE a.NOMBRE_ARTICULO,
                 'codigoArticulo'   VALUE a.CODIGO_ARTICULO,
                 'numeroLote'       VALUE l.NUMERO_LOTE,
                 'nombreSucursal'   VALUE s.NOMBRE_SUCURSAL,
                 -- La FOTO de lo que decia el sistema al momento de contar. NO
                 -- se recalcula contra el lote: si lo hicieramos, la diferencia
                 -- se moveria sola entre el conteo y el procesado.
                 'cantidadSistema'  VALUE i.CANTIDAD_SISTEMA,
                 'cantidadFisica'   VALUE i.CANTIDAD_FISICA,
                 -- Calculada, no guardada: guardar las tres seria tener tres
                 -- columnas que pueden contradecirse. NVL en las dos para que un
                 -- conteo sin cargar todavia de 0 y no null, que el frontend
                 -- tendria que volver a manejar aparte.
                 'diferencia'       VALUE NVL(i.CANTIDAD_FISICA, 0) -
                                          NVL(i.CANTIDAD_SISTEMA, 0),
                 -- Lo que queda HOY en el lote, para comparar contra la foto: si
                 -- difiere de cantidadSistema, alguien movio el lote despues del
                 -- conteo y la diferencia ya no es solo el ajuste.
                 'cantidadLoteHoy'  VALUE NVL(l.CANTIDAD_DISPON, l.CANTIDAD),
                 'estado'           VALUE i.ESTADO,
                 -- Quien PROCESO el conteo: el id y el nombre. Null en los
                 -- abiertos y en los anulados, que es lo esperado — la columna
                 -- no dice quien conto sino quien aplico el ajuste.
                 --
                 -- El nombre sale del JOIN y no de una copia guardada en la
                 -- fila: si alguien corrige su nombre en USUARIOS, el historico
                 -- lo refleja en vez de quedar con el texto viejo. Es lo que se
                 -- gana con la FK frente al VARCHAR2 que habia antes.
                 'idUsuario'        VALUE i.ID_USUARIO,
                 'usuarioProcesa'   VALUE u.USUARIO,
                 'nombreProcesa'    VALUE u.NOMBRE_APELLIDO,
                 'fechaInventario'  VALUE TO_CHAR(i.FECHA_INVENTARIO, C_FORMATO_FECHA),
                 'observaciones'    VALUE i.OBSERVACIONES
                 RETURNING CLOB
               ) AS fila,
               i.FECHA_INVENTARIO AS fecha,
               i.ID_INVENTARIO    AS id
          FROM INVENTARIOS i
          JOIN ARTICULOS   a ON a.ID_ARTICULO  = i.ID_ARTICULO
          JOIN LOTES       l ON l.ID_LOTE      = i.ID_LOTE
          JOIN SUCURSALES  s ON s.ID_SUCURSAL  = i.ID_SUCURSAL
          -- LEFT en este, interno en los otros tres: ID_USUARIO es NULLABLE y
          -- esta en null en todos los conteos abiertos y anulados. Con un JOIN
          -- interno el listado mostraria SOLO los procesados, que es justo lo
          -- contrario de lo que se mira en esta pantalla — y sin ningun error:
          -- la lista simplemente vendria de menos.
          LEFT JOIN USUARIOS u ON u.ID_USUARIO = i.ID_USUARIO
         WHERE (l_id_empresa  IS NULL OR i.ID_EMPRESA  = l_id_empresa)
           AND (l_id_sucursal IS NULL OR i.ID_SUCURSAL = l_id_sucursal)
           AND (l_id_articulo IS NULL OR i.ID_ARTICULO = l_id_articulo)
           AND (l_estado      IS NULL OR i.ESTADO      = l_estado)
      );

    p_status_code := 200;
    -- JSON_OBJECT(... RETURNING CLOB) como asignacion PL/SQL directa (sin
    -- SELECT) falla con PLS-00684 dentro de un package body.
    --
    -- JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un array vacio: sin el
    -- NVL el frontend recibiria "items":null y reventaria al iterarlo.
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
      APEX_DEBUG.ERROR('PKG_INVENTARIOS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los inventarios"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization    IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_id_lote          IN  VARCHAR2,
    p_cantidad_fisica  IN  VARCHAR2,
    p_fecha_inventario IN  VARCHAR2,
    p_observaciones    IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id_empresa  NUMBER;
    l_id_lote     NUMBER;
    l_fisica      NUMBER;
    l_fecha       TIMESTAMP;
    l_id_sucursal NUMBER;
    l_id_articulo NUMBER;
    l_sistema     NUMBER;
    l_abiertos    PLS_INTEGER;
    l_id          NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_lote    := TO_NUMBER(NULLIF(p_id_lote, ''));
    l_fisica     := TO_NUMBER(NULLIF(p_cantidad_fisica, ''));

    IF l_id_empresa IS NULL OR l_id_lote IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa e idLote son obligatorios"}';
      RETURN;
    END IF;

    -- La cantidad contada SI es obligatoria: un conteo sin numero no es un
    -- conteo. Se distingue de "conte cero", que es un dato valido y frecuente
    -- (el lote se agoto y nadie lo habia descargado).
    IF l_fisica IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"cantidadFisica es obligatoria"}';
      RETURN;
    END IF;

    IF l_fisica < 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La cantidad fisica no puede ser negativa"}';
      RETURN;
    END IF;

    -- EL LOTE MANDA: de el salen la sucursal, el articulo y la cantidad que el
    -- sistema cree que hay. No se reciben del cliente por dos razones: son datos
    -- que la base ya tiene resueltos, y pedirlos abriria la puerta a que lleguen
    -- inconsistentes entre si (un lote de la sucursal A con el articulo de otro
    -- lote), que es justo lo que las cuatro FK sueltas del DDL no impiden.
    --
    -- El AND ID_EMPRESA es el aislamiento: sin el se podria abrir un conteo
    -- sobre un lote de otra empresa mandando su id a mano.
    BEGIN
      SELECT ID_SUCURSAL, ID_ARTICULO, NVL(CANTIDAD_DISPON, CANTIDAD)
        INTO l_id_sucursal, l_id_articulo, l_sistema
        FROM LOTES
       WHERE ID_LOTE    = l_id_lote
         AND ID_EMPRESA = l_id_empresa;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_status_code := 404;
        p_resultado := '{"error":"El lote no existe en esta empresa"}';
        RETURN;
    END;

    -- Un mismo lote no puede tener dos conteos ABIERTOS a la vez: al procesar el
    -- segundo, el primero quedaria aplicando una foto vieja sobre un lote que ya
    -- se ajusto, y el stock terminaria en el valor del conteo que se proceso
    -- ultimo por casualidad. El DDL no tiene UNIQUE que lo impida (no podria:
    -- solo aplica a los ABIERTOS), asi que se verifica aca.
    SELECT COUNT(*)
      INTO l_abiertos
      FROM INVENTARIOS
     WHERE ID_LOTE = l_id_lote
       AND ESTADO  = 'ABIERTO';

    IF l_abiertos > 0 THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ese lote ya tiene un conteo abierto: procesalo o anulalo primero"}';
      RETURN;
    END IF;

    -- Una fecha ilegible se ignora y queda SYSTIMESTAMP, en vez de rechazar el
    -- conteo entero: el dato que importa es cuanto se conto.
    l_fecha := A_TIMESTAMP(p_fecha_inventario);

    -- ESTADO e ID_USUARIO no se mandan: TRG_INVENTARIOS_BIU los fuerza a
    -- 'ABIERTO' y NULL en todo INSERT. Ponerlos aca daria la impresion de que el
    -- valor del cliente se respeta.
    --
    -- Y ID_USUARIO en null es lo correcto aunque sepamos quien esta cargando:
    -- la columna dice quien PROCESO, y en el alta todavia no proceso nadie.
    INSERT INTO INVENTARIOS (
      ID_EMPRESA, ID_SUCURSAL, ID_LOTE, ID_ARTICULO,
      CANTIDAD_SISTEMA, CANTIDAD_FISICA,
      FECHA_INVENTARIO, OBSERVACIONES,
      FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_empresa,
      l_id_sucursal,
      l_id_lote,
      l_id_articulo,
      l_sistema,
      l_fisica,
      NVL(l_fecha, SYSTIMESTAMP),
      TRIM(p_observaciones),
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_INVENTARIO INTO l_id;

    COMMIT;
    p_status_code := 201;
    -- Se devuelve la foto junto al id: la pantalla puede mostrar la diferencia
    -- sin volver a pedir el listado entero.
    p_resultado := JSON_OBJECT(
      'id'              VALUE l_id,
      'cantidadSistema' VALUE l_sistema,
      'diferencia'      VALUE l_fisica - NVL(l_sistema, 0),
      'ok'              VALUE 'true' FORMAT JSON
    );
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        -- Alguna FK no encontro su padre.
        p_status_code := 400;
        p_resultado := '{"error":"La empresa, sucursal, lote o articulo indicado no existe"}';
      ELSIF SQLCODE = -1722 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La cantidad fisica debe ser numerica"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_INVENTARIOS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear el inventario"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization    IN  VARCHAR2,
    p_id               IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_cantidad_fisica  IN  VARCHAR2,
    p_fecha_inventario IN  VARCHAR2,
    p_observaciones    IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id         NUMBER;
    l_id_empresa NUMBER;
    l_fisica     NUMBER;
    l_fecha      TIMESTAMP;
    l_estado     VARCHAR2(20);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id         := TO_NUMBER(NULLIF(p_id, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_fisica     := TO_NUMBER(NULLIF(p_cantidad_fisica, ''));

    IF l_id IS NULL OR l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    IF l_fisica IS NOT NULL AND l_fisica < 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La cantidad fisica no puede ser negativa"}';
      RETURN;
    END IF;

    -- Igual que en CAMBIAR_ESTADO: leer el estado antes permite distinguir "no
    -- existe" (404) de "ya no se puede editar" (409). Sin esto, corregir un
    -- conteo ya procesado devolveria el ORA-20001 del trigger como un 500.
    BEGIN
      SELECT ESTADO INTO l_estado
        FROM INVENTARIOS
       WHERE ID_INVENTARIO = l_id
         AND ID_EMPRESA    = l_id_empresa;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_status_code := 404;
        p_resultado := '{"error":"El inventario no existe"}';
        RETURN;
    END;

    IF l_estado != 'ABIERTO' THEN
      p_status_code := 409;
      p_resultado := JSON_OBJECT(
        'error' VALUE 'El inventario esta ' || LOWER(l_estado) ||
                      ' y ya no se puede modificar'
      );
      RETURN;
    END IF;

    l_fecha := A_TIMESTAMP(p_fecha_inventario);

    -- NVL en cada columna: un parametro ausente conserva el valor actual.
    --
    -- LO QUE NO ESTA ACA ES TAN IMPORTANTE COMO LO QUE ESTA. No se modifican:
    --   ID_EMPRESA, ID_SUCURSAL, ID_LOTE, ID_ARTICULO  cambiarlos convertiria el
    --     conteo en otro conteo distinto. Si el lote estaba mal, se anula y se
    --     carga uno nuevo.
    --   CANTIDAD_SISTEMA  es la foto del momento del conteo. Reescribirla borra
    --     la evidencia de cual era la diferencia.
    --   ESTADO  tiene sus propios endpoints, con sus propias reglas.
    --   ID_USUARIO  lo sella PROCESAR y nadie mas.
    --
    -- El AND ESTADO = 'ABIERTO' repite lo que el SELECT verifico: entre los dos
    -- hay una ventana en la que otra sesion pudo procesar la fila.
    UPDATE INVENTARIOS
       SET CANTIDAD_FISICA  = NVL(l_fisica, CANTIDAD_FISICA),
           FECHA_INVENTARIO = NVL(l_fecha, FECHA_INVENTARIO),
           OBSERVACIONES    = NVL(TRIM(p_observaciones), OBSERVACIONES)
     WHERE ID_INVENTARIO = l_id
       AND ID_EMPRESA    = l_id_empresa
       AND ESTADO        = 'ABIERTO';

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"El inventario cambio de estado, volve a cargar la pagina"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE BETWEEN -20003 AND -20001 THEN
        p_status_code := 409;
        p_resultado := JSON_OBJECT('error' VALUE SQLERRM);
      ELSIF SQLCODE = -1722 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La cantidad fisica debe ser numerica"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_INVENTARIOS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar el inventario"}';
      END IF;
  END ACTUALIZAR;

  PROCEDURE PROCESAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
  BEGIN
    -- El ajuste del lote NO se hace aca: lo dispara TRG_INVENTARIOS_AU con el
    -- cambio de estado, en la misma transaccion. Ver la cabecera del archivo.
    CAMBIAR_ESTADO(
      p_authorization  => p_authorization,
      p_id             => p_id,
      p_id_empresa     => p_id_empresa,
      p_estado_destino => 'PROCESADO',
      p_sella_usuario  => TRUE,
      p_status_code    => p_status_code,
      p_resultado      => p_resultado
    );
  END PROCESAR;

  PROCEDURE ANULAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
  BEGIN
    -- Sin sellar usuario: nadie "proceso" nada, el conteo se descarto.
    -- ID_USUARIO registra quien aplico el ajuste, no quien toco la fila por
    -- ultima vez — un anulado queda con la columna en null a proposito.
    CAMBIAR_ESTADO(
      p_authorization  => p_authorization,
      p_id             => p_id,
      p_id_empresa     => p_id_empresa,
      p_estado_destino => 'ANULADO',
      p_sella_usuario  => FALSE,
      p_status_code    => p_status_code,
      p_resultado      => p_resultado
    );
  END ANULAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'inventarios',
      p_base_path      => '/inventarios/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Conteos fisicos de stock por lote, con maquina de estados'
    );

    -- ORIGINS_ALLOWED ES POR MODULO, no por workspace: la pantalla de APEX
    -- sugiere lo contrario, pero habilitarlo en otro modulo no lo propaga a
    -- este. Sin esto, ORDS rechaza la peticion cross-origin ANTES de llegar al
    -- handler, con un "Service Unavailable" que ningun WHEN OTHERS captura
    -- porque el PL/SQL nunca llega a ejecutarse.
    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'inventarios',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /inventarios/listar?idEmpresa=&idSucursal=&idArticulo=&estado=
    --
    -- Los query params no se declaran con DEFINE_PARAMETER: se vinculan solos al
    -- bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'inventarios', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'inventarios',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INVENTARIOS.LISTAR(:authorization, :idEmpresa, :idSucursal, :idArticulo, :estado, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /inventarios/crear
    -- Body: { idEmpresa, idLote, cantidadFisica, fechaInventario?, observaciones? }
    --
    -- NO recibe idSucursal, idArticulo ni cantidadSistema: salen del lote.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'inventarios', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'inventarios',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INVENTARIOS.INSERTAR(:authorization, :idEmpresa, :idLote, :cantidadFisica, :fechaInventario, :observaciones, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /inventarios/actualizar/:id
    -- Body: { idEmpresa, cantidadFisica?, fechaInventario?, observaciones? }
    --
    -- Solo conteos ABIERTOS. Los ids no se modifican.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'inventarios', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'inventarios',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INVENTARIOS.ACTUALIZAR(:authorization, :id, :idEmpresa, :cantidadFisica, :fechaInventario, :observaciones, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /inventarios/procesar/:id/:idEmpresa
    --
    -- POST y no PUT: no reemplaza el recurso, dispara una accion con efectos
    -- sobre otra tabla (ajusta el lote). Mismo criterio que /usuarios/:id/activar.
    --
    -- El idEmpresa va EN LA RUTA y no en el body: un POST sin cuerpo es mas
    -- simple de llamar, y asi el aislamiento no depende de que el cliente arme
    -- un JSON.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'inventarios', p_pattern => 'procesar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'inventarios',
      p_pattern     => 'procesar/:id/:idEmpresa',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INVENTARIOS.PROCESAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'procesar/:id/:idEmpresa', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'procesar/:id/:idEmpresa', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'procesar/:id/:idEmpresa', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /inventarios/anular/:id/:idEmpresa
    --
    -- Ocupa el lugar del /eliminar de las demas tablas: TRG_INVENTARIOS_BD
    -- prohibe el DELETE, porque un conteo fisico es evidencia y no se borra.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'inventarios', p_pattern => 'anular/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'inventarios',
      p_pattern     => 'anular/:id/:idEmpresa',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INVENTARIOS.ANULAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'anular/:id/:idEmpresa', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'anular/:id/:idEmpresa', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'anular/:id/:idEmpresa', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_INVENTARIOS;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_INVENTARIOS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_INVENTARIOS'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_INVENTARIOS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'inventarios';

-- Deben aparecer 5 filas: listar GET, crear POST, actualizar PUT,
-- procesar POST y anular POST. NO hay DELETE, a proposito.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'inventarios'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- LOS TRIGGERS CORREGIDOS TIENEN QUE ESTAR. Si TRG_INVENTARIOS_AU sale como
-- VIEJO, todavia esta el original y PROCESAR va a ajustar la columna equivocada:
-- corre db/inventarios-triggers-ddl.sql.
--
-- DBMS_METADATA y no TRIGGER_BODY: esa columna es de tipo LONG, y un LONG no se
-- puede pasar por UPPER() ni comparar con LIKE — da ORA-00932 ("tipo de dato
-- LONG incompatible"). GET_DDL devuelve un CLOB, que si soporta las dos cosas.
--
-- El WHERE filtra por TRIGGER_NAME exacto a proposito: Oracle no garantiza el
-- orden de evaluacion, y filtrando por TABLE_NAME la funcion se llegaba a
-- ejecutar sobre triggers de otras tablas, con ORA-31603.
SELECT t.TRIGGER_NAME,
       t.STATUS,
       CASE WHEN UPPER(DBMS_METADATA.GET_DDL('TRIGGER', t.TRIGGER_NAME))
                   LIKE '%CANTIDAD_DISPON%'
            THEN 'CORREGIDO' ELSE 'VIEJO - CORREGIR' END AS VERSION_AU
  FROM USER_TRIGGERS t
 WHERE t.TRIGGER_NAME = 'TRG_INVENTARIOS_AU';

--------------------------------------------------------------------------------
-- Auditoria: las cuatro consultas que tienen que devolver CERO filas
--
-- El DDL declara las cuatro FK por separado y ninguna mira a las otras, asi que
-- la base acepta combinaciones incoherentes. INSERTAR las evita tomando todo del
-- lote; esto verifica que nada se haya colado por otro camino.
--------------------------------------------------------------------------------

-- 1. Conteos cuya sucursal no es la del lote.
SELECT i.ID_INVENTARIO, i.ID_SUCURSAL AS SUCURSAL_CONTEO, l.ID_SUCURSAL AS SUCURSAL_LOTE
  FROM INVENTARIOS i
  JOIN LOTES       l ON l.ID_LOTE = i.ID_LOTE
 WHERE i.ID_SUCURSAL != l.ID_SUCURSAL;

-- 2. Conteos cuyo articulo no es el del lote.
SELECT i.ID_INVENTARIO, i.ID_ARTICULO AS ARTICULO_CONTEO, l.ID_ARTICULO AS ARTICULO_LOTE
  FROM INVENTARIOS i
  JOIN LOTES       l ON l.ID_LOTE = i.ID_LOTE
 WHERE i.ID_ARTICULO != l.ID_ARTICULO;

-- 3. Conteos cuya empresa no es la del lote.
SELECT i.ID_INVENTARIO, i.ID_EMPRESA AS EMPRESA_CONTEO, l.ID_EMPRESA AS EMPRESA_LOTE
  FROM INVENTARIOS i
  JOIN LOTES       l ON l.ID_LOTE = i.ID_LOTE
 WHERE i.ID_EMPRESA != l.ID_EMPRESA;

-- 4. Lotes con MAS DE UN conteo abierto. Es lo que INSERTAR rechaza con 409: dos
--    conteos abiertos sobre el mismo lote terminan aplicando el que se procese
--    ultimo, sin que nadie lo haya decidido.
SELECT ID_LOTE, COUNT(*) AS CONTEOS_ABIERTOS
  FROM INVENTARIOS
 WHERE ESTADO = 'ABIERTO'
 GROUP BY ID_LOTE
HAVING COUNT(*) > 1;

--------------------------------------------------------------------------------
-- Consultas utiles
--------------------------------------------------------------------------------

-- Conteos abiertos: lo que falta procesar o anular.
SELECT i.ID_INVENTARIO,
       e.NOMBRE_EMPRESA,
       s.NOMBRE_SUCURSAL,
       a.NOMBRE_ARTICULO,
       l.NUMERO_LOTE,
       i.CANTIDAD_SISTEMA,
       i.CANTIDAD_FISICA,
       NVL(i.CANTIDAD_FISICA, 0) - NVL(i.CANTIDAD_SISTEMA, 0) AS DIFERENCIA,
       TO_CHAR(i.FECHA_INVENTARIO, 'YYYY-MM-DD') AS FECHA
  FROM INVENTARIOS i
  JOIN EMPRESAS    e ON e.ID_EMPRESA   = i.ID_EMPRESA
  JOIN SUCURSALES  s ON s.ID_SUCURSAL  = i.ID_SUCURSAL
  JOIN ARTICULOS   a ON a.ID_ARTICULO  = i.ID_ARTICULO
  JOIN LOTES       l ON l.ID_LOTE      = i.ID_LOTE
 WHERE i.ESTADO = 'ABIERTO'
 ORDER BY i.FECHA_INVENTARIO DESC;

-- Historial de ajustes aplicados, con quien los proceso. Las diferencias
-- grandes o repetidas en el mismo articulo son lo que hay que mirar.
SELECT i.ID_INVENTARIO,
       a.NOMBRE_ARTICULO,
       l.NUMERO_LOTE,
       i.CANTIDAD_SISTEMA,
       i.CANTIDAD_FISICA,
       i.CANTIDAD_FISICA - NVL(i.CANTIDAD_SISTEMA, 0) AS AJUSTE,
       u.USUARIO         AS PROCESADO_POR,
       u.NOMBRE_APELLIDO AS NOMBRE,
       TO_CHAR(i.FECHA_ACTUALIZACION, 'YYYY-MM-DD HH24:MI') AS PROCESADO_EL
  FROM INVENTARIOS i
  JOIN ARTICULOS   a ON a.ID_ARTICULO = i.ID_ARTICULO
  JOIN LOTES       l ON l.ID_LOTE     = i.ID_LOTE
  -- LEFT aunque el filtro sea PROCESADO: si un conteo llego a procesarse sin
  -- pasar por el paquete, ID_USUARIO quedo en null y con JOIN interno esa fila
  -- —que es justamente la que habria que investigar— desapareceria del reporte.
  LEFT JOIN USUARIOS u ON u.ID_USUARIO = i.ID_USUARIO
 WHERE i.ESTADO = 'PROCESADO'
 ORDER BY i.FECHA_ACTUALIZACION DESC;

-- Conteos procesados SIN usuario registrado. Deberia devolver cero filas: si
-- aparece alguna, se proceso por fuera de la API (o con el trigger viejo, que
-- escribia una columna que ya no existe).
SELECT ID_INVENTARIO, ID_LOTE, ESTADO,
       TO_CHAR(FECHA_ACTUALIZACION, 'YYYY-MM-DD HH24:MI') AS PROCESADO_EL
  FROM INVENTARIOS
 WHERE ESTADO = 'PROCESADO'
   AND ID_USUARIO IS NULL;

-- Que el ajuste haya llegado al lote: para un conteo PROCESADO, la cantidad
-- disponible del lote tiene que ser la que se conto.
--
-- Las filas que aparezcan con DISTINTO no son necesariamente un error: el lote
-- pudo moverse DESPUES de procesar el conteo. Pero si aparecen muchas y todas
-- recien procesadas, es senal de que el trigger viejo sigue activo.
SELECT i.ID_INVENTARIO,
       a.NOMBRE_ARTICULO,
       i.CANTIDAD_FISICA                  AS SE_CONTO,
       NVL(l.CANTIDAD_DISPON, l.CANTIDAD) AS LOTE_HOY,
       CASE WHEN NVL(l.CANTIDAD_DISPON, l.CANTIDAD) = i.CANTIDAD_FISICA
            THEN 'OK' ELSE 'DISTINTO' END AS COINCIDE
  FROM INVENTARIOS i
  JOIN LOTES       l ON l.ID_LOTE     = i.ID_LOTE
  JOIN ARTICULOS   a ON a.ID_ARTICULO = i.ID_ARTICULO
 WHERE i.ESTADO = 'PROCESADO'
 ORDER BY i.FECHA_ACTUALIZACION DESC;
