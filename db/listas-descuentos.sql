--------------------------------------------------------------------------------
-- CTELL · LISTAS_DESCUENTOS
--
-- Un paquete (PKG_LISTAS_DESCUENTOS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicacion de los endpoints ORDS. Todo vive
-- dentro del paquete: no hay procedimientos sueltos ni PL/SQL embebido como
-- texto dentro de los handlers.
--
--   1. LISTAR      GET    /listas-descuentos/listar        (?idEmpresa= opcional)
--   2. INSERTAR    POST   /listas-descuentos/crear
--   3. ACTUALIZAR  PUT    /listas-descuentos/actualizar/:id
--   4. ELIMINAR    DELETE /listas-descuentos/eliminar/:id/:idEmpresa
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/listas-descuentos/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   LISTAS_DESCUENTOS  ID_LISTA_PRECIOS, ID_EMPRESA, NOMBRE_LISTA,
--                      PORCENTAJE_DESCUENTO, FECHA_VIGENCIA_DESDE,
--                      FECHA_VIGENCIA_HASTA, FECHA_CREACION,
--                      FECHA_ACTUALIZACION
--
-- LA PK SE LLAMA ID_LISTA_PRECIOS, NO ID_LISTA_DESCUENTOS. La tabla se llamaba
-- LISTAS_PRECIOS y al renombrarla las columnas quedaron con el nombre viejo. No
-- es un error de tipeo de este archivo: es como esta declarada en el DDL, y el
-- paquete tiene que nombrarla igual o no compila. Si algun dia se renombra la
-- columna, hay que tocarla aca tambien.
--
-- LA LISTA ES POR EMPRESA. Cada empresa tiene su propio juego de listas: el
-- idEmpresa sale de la empresa que se eligio al iniciar sesion, no de un
-- combobox del formulario. Por eso el listado se filtra por ?idEmpresa= y el
-- alta lo recibe como dato obligatorio.
--
-- SIN JOIN CONTRA EMPRESAS: el listado no devuelve el nombre de la empresa.
-- Viene filtrado por una sola —la de la sesion—, asi que seria la misma
-- constante repetida en cada fila, y el frontend ya lo tiene en la empresa
-- activa. Mismo criterio que db/monedas.sql y db/ciudades.sql.
--
-- NO HAY COLUMNA ACTIVO, Y ESO CAMBIA EL MODELO. El resto de las tablas del
-- proyecto se dan de baja logica con 'A'/'I'; aca la vigencia la determinan las
-- FECHAS. Una lista no se "inactiva": se le pone FECHA_VIGENCIA_HASTA. Por eso
-- el ACTUALIZAR no recibe p_activo y el borrado es fisico, como en
-- DETALLE_MONEDAS.
--
-- La consecuencia practica: el listado devuelve un campo CALCULADO `vigente`
-- que no existe como columna. Ver el comentario en LISTAR.
--
-- LAS FECHAS VIAJAN COMO TEXTO ISO ('YYYY-MM-DD'). ORDS entrega los binds como
-- VARCHAR2, asi que se convierten aca adentro con TO_DATE y un formato
-- EXPLICITO: sin el formato, Oracle usa el NLS de la sesion y el mismo
-- '03-04-2026' se interpreta como 3 de abril o 4 de marzo segun donde corra.
-- Al devolverlas se usa TO_CHAR con el mismo formato, por el mismo motivo — una
-- DATE cruda en el JSON sale como '17-AGO-26' y `new Date()` no la parsea.
--
-- SOLO LA FECHA, SIN HORA. Las columnas son DATE y se manejan a nivel de dia:
-- una vigencia es un dia del calendario, y la hora en que se cargo la lista no
-- cambia ninguna decision.
--
-- FECHA_VIGENCIA_HASTA ES NULLABLE Y SIGNIFICA "SIN VENCIMIENTO": la lista rige
-- indefinidamente. A diferencia de DESDE, que el DDL exige, dejarla vacia es
-- una decision valida y frecuente.
--
-- HASTA >= DESDE se valida en el paquete, no en la base: el DDL no trae CHECK.
-- Se controla contra los valores FINALES en el ACTUALIZAR, porque cambiar una
-- sola de las dos tambien puede invertir el rango.
--
-- EL DESCUENTO ES UN PORCENTAJE, NO UN FACTOR: 10 significa 10%, no 0.10. Se
-- acota a [0, 100) — el 100 queda afuera porque una lista que regala todo es un
-- error de carga, no un caso de negocio. El DDL pone DEFAULT 0 pero el
-- INSERT lo escribe explicito, como en el resto del proyecto.
--
-- El UNIQUE (ID_EMPRESA, NOMBRE_LISTA) impide dos listas con el mismo nombre
-- dentro de la misma empresa, pero si permite repetirlo entre empresas
-- distintas (dos empresas pueden tener su "Lista Mayorista"). El
-- DUP_VAL_ON_INDEX se traduce a 409 con ese matiz en el mensaje.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_LISTAS_DESCUENTOS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_LISTAS_DESCUENTOS.LISTAR('Bearer TU_TOKEN', NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_LISTAS_DESCUENTOS AS

  -- p_id_empresa NULL o vacio devuelve las listas de todas las empresas. En la
  -- app siempre viaja con la empresa de la sesion.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Las fechas llegan como texto ISO 'YYYY-MM-DD'. p_fecha_vigencia_hasta vacia
  -- significa "sin vencimiento" y se guarda NULL.
  PROCEDURE INSERTAR (
    p_authorization        IN  VARCHAR2,
    p_id_empresa           IN  VARCHAR2,
    p_nombre_lista         IN  VARCHAR2,
    p_porcentaje_descuento IN  VARCHAR2,
    p_fecha_vigencia_desde IN  VARCHAR2,
    p_fecha_vigencia_hasta IN  VARCHAR2,
    p_status_code          OUT NUMBER,
    p_resultado            OUT CLOB
  );

  -- Los parametros ausentes (NULL) no modifican la columna correspondiente.
  --
  -- CONSECUENCIA EN FECHA_VIGENCIA_HASTA: mandarla vacia significa "no
  -- cambiar", no "quitarle el vencimiento". Para volver a dejar la lista sin
  -- fin de vigencia se manda el literal 'null' — ver LIMPIA_FECHA en el body.
  PROCEDURE ACTUALIZAR (
    p_authorization        IN  VARCHAR2,
    p_id                   IN  VARCHAR2,
    p_id_empresa           IN  VARCHAR2,
    p_nombre_lista         IN  VARCHAR2,
    p_porcentaje_descuento IN  VARCHAR2,
    p_fecha_vigencia_desde IN  VARCHAR2,
    p_fecha_vigencia_hasta IN  VARCHAR2,
    p_status_code          OUT NUMBER,
    p_resultado            OUT CLOB
  );

  -- p_id_empresa es OBLIGATORIO: acota el borrado a la empresa de la sesion.
  -- Sin el, un DELETE con el id de una lista ajena la borraba igual.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /listas-descuentos/ con sus 4 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_LISTAS_DESCUENTOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_LISTAS_DESCUENTOS AS

  -- Formato UNICO de las fechas, de entrada y de salida. Constante para que no
  -- se desincronicen: si TO_DATE y TO_CHAR usaran mascaras distintas, lo que se
  -- guarda y lo que se devuelve dejarian de ser el mismo dia.
  C_FORMATO_FECHA CONSTANT VARCHAR2(10) := 'YYYY-MM-DD';

  -- Valor que el cliente manda para BORRAR una fecha opcional, distinto de "no
  -- la mando" (que significa no cambiar). Ver ACTUALIZAR.
  C_BORRAR CONSTANT VARCHAR2(4) := 'null';

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
        -- Se consulta en vez de capturar el error de "no existe": asi el
        -- EXCEPTION queda libre para los fallos que si importan.
        SELECT COUNT(*)
          INTO l_existe
          FROM USER_ORDS_MODULES
         WHERE NAME = 'listas-descuentos';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'listas-descuentos');
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

  ------------------------------------------------------------------------------
  -- Privado: texto ISO -> DATE. Vacio, NULL o el literal 'null' devuelve NULL.
  --
  -- Una fecha con formato invalido levanta ORA-01843/ORA-01861, que el WHEN
  -- OTHERS del procedimiento traduce a 400.
  ------------------------------------------------------------------------------
  FUNCTION A_FECHA (p_texto IN VARCHAR2) RETURN DATE IS
  BEGIN
    IF TRIM(p_texto) IS NULL OR LOWER(TRIM(p_texto)) = C_BORRAR THEN
      RETURN NULL;
    END IF;
    -- SUBSTR(1,10): tolera que llegue un ISO completo con hora
    -- ('2026-04-03T00:00:00.000Z') en vez de solo el dia. El frontend manda solo
    -- el dia, pero un cliente cualquiera puede mandar el ISO entero y no hay
    -- razon para rechazarlo.
    RETURN TO_DATE(SUBSTR(TRIM(p_texto), 1, 10), C_FORMATO_FECHA);
  END A_FECHA;

  ------------------------------------------------------------------------------
  -- Privado: true si el cliente pidio explicitamente BORRAR la fecha.
  --
  -- Hace falta porque en el ACTUALIZAR "no mandar nada" ya significa "no
  -- cambiar": sin un valor distinto, quitarle el fin de vigencia a una lista que
  -- ya lo tiene seria imposible por la API.
  ------------------------------------------------------------------------------
  FUNCTION LIMPIA_FECHA (p_texto IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN LOWER(TRIM(p_texto)) = C_BORRAR;
  END LIMPIA_FECHA;

  ------------------------------------------------------------------------------
  -- Privado: texto -> NUMBER, tolerando el vacio.
  --
  -- NULLIF antes de TO_NUMBER: el parametro ausente llega como cadena vacia y
  -- TO_NUMBER('') da ORA-01722.
  ------------------------------------------------------------------------------
  FUNCTION A_NUMERO (p_texto IN VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN TO_NUMBER(NULLIF(TRIM(p_texto), ''));
  END A_NUMERO;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_empresa NUMBER;
    l_total      NUMBER;
    l_items      CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- La conversion va aca, dentro del BEGIN: en el DECLARE se ejecutaria antes
    -- de que exista el EXCEPTION y el error escaparia del procedimiento.
    l_id_empresa := A_NUMERO(p_id_empresa);

    -- Sin empresa NO se devuelve nada. El default de "todas" que tenia antes es
    -- el error: un olvido en el cliente pasaba desapercibido justamente porque
    -- la pantalla se llenaba de datos —y de datos ajenos—.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    SELECT COUNT(*)
      INTO l_total
      FROM LISTAS_DESCUENTOS
     WHERE ID_EMPRESA = l_id_empresa;

    -- Sin JOIN: la consulta sale de LISTAS_DESCUENTOS y nada mas. El nombre de la
    -- empresa no se devuelve porque el listado ya viene filtrado por una sola.
    --
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: el listado anda con pocas filas y devuelve 500 cuando crece.
    --
    -- Orden por vigencia descendente: lo que rige hoy interesa mas que lo que
    -- vencio el año pasado, y en una pantalla que corta de a 20 filas eso
    -- decide que se ve sin desplegar el resto.
    SELECT JSON_ARRAYAGG(fila ORDER BY desde DESC, nombre_lista RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'                  VALUE lp.ID_LISTA_PRECIOS,
                 'idEmpresa'           VALUE lp.ID_EMPRESA,
                 'nombreLista'         VALUE lp.NOMBRE_LISTA,
                 -- NVL a 0: el DDL solo tiene DEFAULT 0, que no se aplica si
                 -- alguien inserta NULL explicito. Sin esto el frontend
                 -- recibiria null y mostraria "—" en vez de "0%", que es lo que
                 -- significa.
                 'porcentajeDescuento' VALUE NVL(lp.PORCENTAJE_DESCUENTO, 0),
                 -- TO_CHAR y no la columna pelada: una DATE cruda sale en el
                 -- formato NLS de la sesion ('17-AGO-26') y `new Date()` no lo
                 -- parsea.
                 'fechaVigenciaDesde'  VALUE TO_CHAR(lp.FECHA_VIGENCIA_DESDE, C_FORMATO_FECHA),
                 'fechaVigenciaHasta'  VALUE TO_CHAR(lp.FECHA_VIGENCIA_HASTA, C_FORMATO_FECHA),
                 -- CALCULADO, NO GUARDADO: si `vigente` fuera una columna habria
                 -- que recalcularla todos los dias a medianoche. Es una funcion
                 -- de las fechas y de HOY, asi que se deriva al leer.
                 --
                 -- Se devuelve 'A'/'I' —el mismo codigo de estado del resto del
                 -- proyecto— para que el frontend lo trate igual que cualquier
                 -- otro estado, aunque aca no salga de una columna ACTIVO.
                 --
                 -- Los limites son INCLUSIVOS en los dos extremos: una lista que
                 -- rige "hasta el 31/12" rige TODO el 31. TRUNC(SYSDATE) descarta
                 -- la hora, si no una lista que arranca hoy no estaria vigente
                 -- hasta la medianoche siguiente.
                 'vigente'             VALUE CASE
                                               WHEN TRUNC(SYSDATE) >= lp.FECHA_VIGENCIA_DESDE
                                                AND (lp.FECHA_VIGENCIA_HASTA IS NULL
                                                     OR TRUNC(SYSDATE) <= lp.FECHA_VIGENCIA_HASTA)
                                               THEN 'A'
                                               ELSE 'I'
                                             END
                 RETURNING CLOB
               ) AS fila,
               lp.FECHA_VIGENCIA_DESDE AS desde,
               lp.NOMBRE_LISTA         AS nombre_lista
          FROM LISTAS_DESCUENTOS lp
         WHERE lp.ID_EMPRESA = l_id_empresa
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
      APEX_DEBUG.ERROR('PKG_LISTAS_DESCUENTOS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las listas de descuentos"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization        IN  VARCHAR2,
    p_id_empresa           IN  VARCHAR2,
    p_nombre_lista         IN  VARCHAR2,
    p_porcentaje_descuento IN  VARCHAR2,
    p_fecha_vigencia_desde IN  VARCHAR2,
    p_fecha_vigencia_hasta IN  VARCHAR2,
    p_status_code          OUT NUMBER,
    p_resultado            OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_empresa NUMBER;
    l_descuento  NUMBER;
    l_desde      DATE;
    l_hasta      DATE;
    l_id         NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_empresa := A_NUMERO(p_id_empresa);
    l_descuento  := A_NUMERO(p_porcentaje_descuento);
    l_desde      := A_FECHA(p_fecha_vigencia_desde);
    l_hasta      := A_FECHA(p_fecha_vigencia_hasta);

    -- FECHA_VIGENCIA_DESDE es NOT NULL en el DDL y no tiene default: si no
    -- viene, el INSERT moriria con ORA-01400 (500). Se valida antes para
    -- devolver un 400 que diga cual falta.
    IF l_id_empresa IS NULL
       OR TRIM(p_nombre_lista) IS NULL
       OR l_desde IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, nombreLista y fechaVigenciaDesde son obligatorios"}';
      RETURN;
    END IF;

    -- El rango tiene que ir hacia adelante. Se valida aca y no con un CHECK
    -- porque el DDL no lo trae: sin esto se guarda una lista que no rige nunca y
    -- nadie se entera hasta que alguien pregunta por que no aparece.
    IF l_hasta IS NOT NULL AND l_hasta < l_desde THEN
      p_status_code := 400;
      p_resultado := '{"error":"La vigencia no puede terminar antes de empezar"}';
      RETURN;
    END IF;

    -- El descuento es un PORCENTAJE: 10 = 10%. El 100 queda afuera porque una
    -- lista que regala todo es un error de carga, no un caso de negocio.
    IF l_descuento IS NOT NULL AND (l_descuento < 0 OR l_descuento >= 100) THEN
      p_status_code := 400;
      p_resultado := '{"error":"El porcentaje de descuento debe estar entre 0 y 100"}';
      RETURN;
    END IF;

    -- Las columnas se escriben SIEMPRE, incluso NULL en HASTA. El DEFAULT 0 del
    -- descuento se replica con NVL en vez de omitir la columna: es el criterio
    -- del proyecto, para no depender de un default que puede cambiar en el DDL.
    INSERT INTO LISTAS_DESCUENTOS (
      ID_EMPRESA, NOMBRE_LISTA, PORCENTAJE_DESCUENTO,
      FECHA_VIGENCIA_DESDE, FECHA_VIGENCIA_HASTA,
      FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_empresa,
      TRIM(p_nombre_lista),
      NVL(l_descuento, 0),
      l_desde,
      l_hasta,
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_LISTA_PRECIOS INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- El UNIQUE es (ID_EMPRESA, NOMBRE_LISTA): el choque es dentro de la misma
      -- empresa, no global. El mensaje lo dice para que no parezca que el nombre
      -- esta tomado en todos lados.
      p_status_code := 409;
      p_resultado := '{"error":"Esta empresa ya tiene una lista con ese nombre"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: la FK contra EMPRESAS no encontro el padre.
      -- ORA-01843/01861/01830/01858: la fecha no vino en formato ISO.
      -- Los dos son datos invalidos del cliente (400), no fallos del servidor.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La empresa indicada no existe"}';
      ELSIF SQLCODE IN (-1843, -1861, -1830, -1858) THEN
        p_status_code := 400;
        p_resultado := '{"error":"Las fechas deben tener el formato AAAA-MM-DD"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_LISTAS_DESCUENTOS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear la lista de descuentos"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization        IN  VARCHAR2,
    p_id                   IN  VARCHAR2,
    p_id_empresa           IN  VARCHAR2,
    p_nombre_lista         IN  VARCHAR2,
    p_porcentaje_descuento IN  VARCHAR2,
    p_fecha_vigencia_desde IN  VARCHAR2,
    p_fecha_vigencia_hasta IN  VARCHAR2,
    p_status_code          OUT NUMBER,
    p_resultado            OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id          NUMBER;
    l_id_empresa  NUMBER;
    l_descuento   NUMBER;
    l_desde       DATE;
    l_hasta       DATE;
    l_borra_hasta BOOLEAN;
    -- Valores FINALES tras aplicar el cambio, para validar el rango completo.
    l_desde_final DATE;
    l_hasta_final DATE;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id          := A_NUMERO(p_id);
    l_id_empresa  := A_NUMERO(p_id_empresa);
    l_descuento   := A_NUMERO(p_porcentaje_descuento);
    l_desde       := A_FECHA(p_fecha_vigencia_desde);
    l_hasta       := A_FECHA(p_fecha_vigencia_hasta);
    l_borra_hasta := LIMPIA_FECHA(p_fecha_vigencia_hasta);

    -- AISLAMIENTO POR EMPRESA: el idEmpresa acota A CUAL fila se le aplica el
    -- cambio, no es solo un campo mas a modificar. Sin el WHERE, un PUT con el
    -- id de una lista de OTRA empresa la modificaba igual — la pantalla no lo
    -- permite, pero el endpoint es publico para cualquiera con sesion.
    --
    -- ID_EMPRESA sale del SET a proposito: mover una fila de empresa es lo que
    -- este control busca impedir, y dejarlo modificable seria la puerta de atras
    -- al mismo problema.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    IF l_descuento IS NOT NULL AND (l_descuento < 0 OR l_descuento >= 100) THEN
      p_status_code := 400;
      p_resultado := '{"error":"El porcentaje de descuento debe estar entre 0 y 100"}';
      RETURN;
    END IF;

    -- El rango se valida contra los valores FINALES, no contra los que llegaron:
    -- mover solo el DESDE de una lista que ya tiene HASTA tambien puede
    -- invertirlo, y ese caso se escaparia comparando solo lo recibido.
    --
    -- El SELECT ademas hace de control de existencia dentro de la empresa: si no
    -- devuelve fila, ya se sabe que el UPDATE no iba a tocar nada.
    BEGIN
      SELECT NVL(l_desde, FECHA_VIGENCIA_DESDE),
             CASE WHEN l_borra_hasta THEN NULL
                  ELSE NVL(l_hasta, FECHA_VIGENCIA_HASTA)
             END
        INTO l_desde_final, l_hasta_final
        FROM LISTAS_DESCUENTOS
       WHERE ID_LISTA_PRECIOS = l_id
         AND ID_EMPRESA       = l_id_empresa;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        -- 404 y no 403 cuando la lista es de otra empresa: responder "existe
        -- pero no es tuya" confirmaria que el id existe, que es informacion que
        -- quien pregunta no deberia obtener.
        p_status_code := 404;
        p_resultado := '{"error":"La lista de descuentos no existe"}';
        RETURN;
    END;

    IF l_hasta_final IS NOT NULL AND l_hasta_final < l_desde_final THEN
      p_status_code := 400;
      p_resultado := '{"error":"La vigencia no puede terminar antes de empezar"}';
      RETURN;
    END IF;

    -- Las dos fechas se escriben con el valor final ya resuelto arriba, no con
    -- NVL sobre la columna: el CASE de l_hasta_final es lo que permite que
    -- 'null' borre el vencimiento y un parametro ausente lo conserve.
    UPDATE LISTAS_DESCUENTOS
       SET NOMBRE_LISTA         = NVL(TRIM(p_nombre_lista), NOMBRE_LISTA),
           PORCENTAJE_DESCUENTO = NVL(l_descuento, PORCENTAJE_DESCUENTO),
           FECHA_VIGENCIA_DESDE = l_desde_final,
           FECHA_VIGENCIA_HASTA = l_hasta_final,
           FECHA_ACTUALIZACION  = SYSTIMESTAMP
     WHERE ID_LISTA_PRECIOS = l_id
       AND ID_EMPRESA       = l_id_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La lista de descuentos no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Esta empresa ya tiene una lista con ese nombre"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La empresa indicada no existe"}';
      ELSIF SQLCODE IN (-1843, -1861, -1830, -1858) THEN
        p_status_code := 400;
        p_resultado := '{"error":"Las fechas deben tener el formato AAAA-MM-DD"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_LISTAS_DESCUENTOS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar la lista de descuentos"}';
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
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id         := A_NUMERO(p_id);
    l_id_empresa := A_NUMERO(p_id_empresa);

    -- Obligatorio: sin empresa el DELETE alcanzaria filas de cualquiera.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- AISLAMIENTO POR EMPRESA: las dos condiciones. Con solo el id, un DELETE
    -- con el id de una lista de otra empresa la borraba.
    --
    -- BAJA FISICA: la tabla no tiene columna ACTIVO. Para "retirar" una lista
    -- sin borrarla se le pone FECHA_VIGENCIA_HASTA, que es como se da de baja en
    -- este modelo.
    DELETE FROM LISTAS_DESCUENTOS
     WHERE ID_LISTA_PRECIOS = l_id
       AND ID_EMPRESA       = l_id_empresa;

    -- 404 tambien cuando existe pero es de otra empresa: no se confirma que el
    -- id exista.
    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La lista de descuentos no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos (precios por articulo, comprobantes) apuntando a
      -- esta fila. Es un conflicto de estado (409), no un error del servidor: el
      -- dato que mandaron era valido.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de esta lista"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_LISTAS_DESCUENTOS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar la lista de descuentos"}';
      END IF;
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Publica el modulo ORDS /listas-descuentos/ con sus 4 endpoints.
  --
  -- Cada handler es una sola linea: invoca al procedimiento del paquete pasando
  -- los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un parametro
  -- de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin esto, toda
  -- peticion cross-origin a /listas-descuentos/* la rechaza ORDS antes de llegar a
  -- cualquiera de los 4 handlers. Ver la explicacion en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'listas-descuentos',
      p_base_path      => '/listas-descuentos/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'ABM de listas de descuentos por empresa'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'listas-descuentos',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /listas-descuentos/listar?idEmpresa=
    --
    -- idEmpresa no se declara con DEFINE_PARAMETER: los query params se vinculan
    -- solos al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'listas-descuentos', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'listas-descuentos',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_LISTAS_DESCUENTOS.LISTAR(:authorization, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'listas-descuentos', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'listas-descuentos', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'listas-descuentos', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /listas-descuentos/crear
    -- Body: { idEmpresa, nombreLista, porcentajeDescuento?,
    --         fechaVigenciaDesde, fechaVigenciaHasta? }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'listas-descuentos', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'listas-descuentos',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_LISTAS_DESCUENTOS.INSERTAR(:authorization, :idEmpresa, :nombreLista, :porcentajeDescuento, :fechaVigenciaDesde, :fechaVigenciaHasta, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'listas-descuentos', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'listas-descuentos', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'listas-descuentos', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /listas-descuentos/actualizar/:id
    -- Body: { idEmpresa, nombreLista?, porcentajeDescuento?,
    --         fechaVigenciaDesde?, fechaVigenciaHasta? }
    --       (ausentes = no cambia; fechaVigenciaHasta: "null" = quitarla)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'listas-descuentos', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'listas-descuentos',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_LISTAS_DESCUENTOS.ACTUALIZAR(:authorization, :id, :idEmpresa, :nombreLista, :porcentajeDescuento, :fechaVigenciaDesde, :fechaVigenciaHasta, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'listas-descuentos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'listas-descuentos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'listas-descuentos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /listas-descuentos/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'listas-descuentos', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'listas-descuentos',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_LISTAS_DESCUENTOS.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'listas-descuentos', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'listas-descuentos', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'listas-descuentos', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_LISTAS_DESCUENTOS;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_LISTAS_DESCUENTOS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_LISTAS_DESCUENTOS'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_LISTAS_DESCUENTOS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'listas-descuentos';

SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'listas-descuentos'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- Las listas cargadas, con la vigencia resuelta igual que en el listado.
SELECT lp.ID_LISTA_PRECIOS, e.NOMBRE_EMPRESA, lp.NOMBRE_LISTA,
       lp.PORCENTAJE_DESCUENTO                        AS DESCUENTO,
       TO_CHAR(lp.FECHA_VIGENCIA_DESDE, 'YYYY-MM-DD') AS DESDE,
       TO_CHAR(lp.FECHA_VIGENCIA_HASTA, 'YYYY-MM-DD') AS HASTA,
       CASE
         WHEN TRUNC(SYSDATE) >= lp.FECHA_VIGENCIA_DESDE
          AND (lp.FECHA_VIGENCIA_HASTA IS NULL
               OR TRUNC(SYSDATE) <= lp.FECHA_VIGENCIA_HASTA)
         THEN 'VIGENTE'
         ELSE 'NO VIGENTE'
       END                                            AS ESTADO
  FROM LISTAS_DESCUENTOS lp
  JOIN EMPRESAS       e ON e.ID_EMPRESA = lp.ID_EMPRESA
 ORDER BY e.NOMBRE_EMPRESA, lp.FECHA_VIGENCIA_DESDE DESC, lp.NOMBRE_LISTA;
