--------------------------------------------------------------------------------
-- CTELL · DETALLE DE MONEDAS
--
-- Un paquete (PKG_DETALLE_MONEDAS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — más GUARDAR_FOTO, y la publicación de los endpoints
-- ORDS. Todo vive dentro del paquete: no hay procedimientos sueltos ni PL/SQL
-- embebido como texto dentro de los handlers.
--
--   1. LISTAR      GET    /detalle-monedas/listar        (?idMoneda= opcional)
--   2. INSERTAR    POST   /detalle-monedas/crear
--   3. ACTUALIZAR  PUT    /detalle-monedas/actualizar/:id
--   4. ELIMINAR    DELETE /detalle-monedas/eliminar/:id/:idEmpresa
--   5. FOTO        GET    /detalle-monedas/foto/:id      (publico)
--                  PUT    /detalle-monedas/foto/:id      (con token)
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/detalle-monedas/
--
-- Tabla (no la crea; el DDL se administra aparte, salvo FOTO_MIME — ver paso 0):
--   DETALLE_MONEDAS  ID_DETALLE_MONEDA, ID_MONEDA, DENOMINACION, FOTO,
--                    FOTO_MIME, FECHA_CREACION, FECHA_ACTUALIZACION
--
-- CABECERA / DETALLE. MONEDAS es la cabecera y esta tabla el detalle: cada
-- moneda tiene sus denominaciones (el billete de 50.000, el de 100.000) con la
-- foto de cada una. Sirve para los cierres de caja, donde se cuenta por
-- denominacion y ver la imagen ayuda a identificarla.
--
-- CUELGA DE MONEDAS, NO DE EMPRESAS. No tiene ID_EMPRESA: la empresa se deduce
-- por la moneda padre. El listado se filtra por ?idMoneda= —la moneda que se
-- eligio en la pantalla— y no por empresa.
--
-- SIN JOIN CONTRA MONEDAS: el listado no devuelve el nombre de la moneda. Viene
-- filtrado por una sola —la de la cabecera— asi que seria la misma constante
-- repetida en cada fila, y el frontend ya la tiene. Mismo criterio que
-- db/monedas.sql con EMPRESAS.
--
-- DENOMINACION GUARDA DIGITOS PELADOS: '50000', no '50.000' ni 'Billete de 50'.
-- La columna es VARCHAR2(50) y acepta cualquier texto, pero el frontend valida
-- que sean solo digitos y el separador de miles se agrega recien al mostrar. El
-- motivo es el orden: como texto, '10000' se ordena antes que '2000'.
--
-- El LISTAR ordena de menor a mayor convirtiendo la columna a numero, con
-- DEFAULT NULL ON CONVERSION ERROR para que las filas cargadas a mano con texto
-- no tumben la consulta. Esas van al final.
--
-- Si el cierre de caja necesita CALCULAR (cantidad x valor), conviene agregar
-- una columna VALOR NUMBER en vez de parsear este VARCHAR2 en cada consulta.
--
-- NO TIENE COLUMNA ACTIVO, a diferencia del resto de las tablas del proyecto.
-- Es deliberado y viene del DDL: una denominacion existe o no existe. No hay
-- baja logica, solo fisica — por eso no hay estado 'A'/'I' en el JSON ni
-- endpoints de activar/inactivar.
--
-- FOTO (BLOB) NO viaja en el JSON del CRUD —un binario no entra en un
-- JSON_OBJECT— sino por dos endpoints propios:
--
--   GET /detalle-monedas/foto/:id  devuelve la imagen cruda con su content-type,
--     para usarla directo como src de un <img>. Es PUBLICO porque lo consume un
--     <img>, y el navegador no manda el header Authorization al descargar una
--     imagen. No pasa por el paquete: se publica con ORDS.source_type_media.
--
--   PUT /detalle-monedas/foto/:id  recibe el binario en el body y lo guarda.
--     Este SI pide token: escribir nunca es publico.
--
-- El listado devuelve `tieneFoto` (true/false) en vez del binario, asi el
-- frontend sabe si pedir la imagen o dibujar el respaldo, sin traerse los BLOB
-- de todas las denominaciones para averiguarlo.
--
-- El camino "normal" para servir un BLOB —un OUT BLOB como parametro RESPONSE—
-- NO funciona: el check REST_PARAMS_PARAM_TYPE_CK rechaza tanto 'BLOB' como
-- 'RESOURCE' y aborta la publicacion entera con ORA-02290, dejando el modulo
-- SIN NINGUN endpoint. Ver la explicacion completa en db/empresas.sql.
--
-- CONTENT-TYPE: se guarda junto al BLOB en FOTO_MIME. Sin eso habria que
-- adivinar el formato al servirlo, y un PNG servido como image/jpeg no lo
-- renderiza ningun navegador. Ver el ALTER TABLE del paso 0.
--
-- La FK contra MONEDAS obliga a que la moneda exista: mandar un idMoneda
-- inexistente da ORA-02291 en el INSERT/UPDATE, que se traduce a 400 en vez de
-- 500 — el dato es invalido, no fallo el servidor.
--
-- El UNIQUE (ID_MONEDA, DENOMINACION) impide dos denominaciones con el mismo
-- nombre dentro de la misma moneda, pero si permite repetirlo entre monedas
-- distintas (el "50" del guarani y el "50" del dolar). El DUP_VAL_ON_INDEX se
-- traduce a 409 con ese matiz en el mensaje.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 0. Columna FOTO_MIME
--
-- UNICA excepcion a la regla de que estos archivos no tocan el DDL. Es una
-- columna nueva y opcional que el paquete necesita para servir la foto con el
-- content-type correcto, asi que se agrega aca en vez de dejar el archivo sin
-- poder ejecutarse hasta que alguien la cree a mano.
--
-- El bloque consulta USER_TAB_COLUMNS antes de agregarla: sin eso, la segunda
-- ejecucion del archivo fallaria con ORA-01430 (la columna ya existe) y todo lo
-- que viene despues no llegaria a ejecutarse.
--------------------------------------------------------------------------------

DECLARE
  l_existe PLS_INTEGER;
BEGIN
  SELECT COUNT(*)
    INTO l_existe
    FROM USER_TAB_COLUMNS
   WHERE TABLE_NAME = 'DETALLE_MONEDAS'
     AND COLUMN_NAME = 'FOTO_MIME';

  IF l_existe = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE DETALLE_MONEDAS ADD (FOTO_MIME VARCHAR2(100))';
  END IF;
END;
/

--------------------------------------------------------------------------------
-- 1. PKG_DETALLE_MONEDAS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_DETALLE_MONEDAS.LISTAR('Bearer TU_TOKEN', NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_DETALLE_MONEDAS AS

  -- p_id_moneda NULL o vacio devuelve las denominaciones de todas las monedas.
  -- En la app siempre viaja con la moneda de la cabecera.
  -- idEmpresa es OBLIGATORIO: DETALLE_MONEDAS no tiene columna de empresa
  -- —cuelga de MONEDAS— asi que la consulta no se acota sola. Sin el, bastaba
  -- con conocer un idMoneda ajeno para leer las denominaciones de otra empresa.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_moneda     IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- p_id_empresa es OBLIGATORIO aunque la tabla no tenga esa columna: acota la
  -- moneda padre. Sin el, una sesion de la empresa A podia agregarle una
  -- denominacion a una moneda de la B con solo conocer su id — el ACTUALIZAR y
  -- el ELIMINAR ya lo validaban, el alta no.
  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_moneda     IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_denominacion  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Los parametros ausentes (NULL) no modifican la columna correspondiente.
  --
  -- p_id_empresa es OBLIGATORIO aunque la tabla no tenga esa columna: acota la
  -- operacion a las denominaciones de las monedas de esa empresa. Ver
  -- ES_DE_EMPRESA en el body.
  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_moneda     IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_denominacion  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- NO hay procedimiento para SERVIR la foto: el GET /detalle-monedas/foto/:id
  -- se publica con ORDS.source_type_media, que arma la respuesta binaria desde
  -- una consulta sin pasar por PL/SQL. Ver el detalle en PUBLICAR_ENDPOINTS.

  -- Guarda la foto. CON token: escribir nunca es publico.
  -- p_foto llega como el cuerpo crudo del PUT; p_content_type, del header.
  PROCEDURE GUARDAR_FOTO (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_foto          IN  BLOB,
    p_content_type  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /detalle-monedas/ con sus endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_DETALLE_MONEDAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_DETALLE_MONEDAS AS

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
         WHERE NAME = 'detalle-monedas';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'detalle-monedas');
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
  -- Privado: esa denominacion pertenece a una moneda de esa empresa.
  --
  -- DETALLE_MONEDAS **no tiene columna ID_EMPRESA**: cuelga de MONEDAS, y es la
  -- moneda la que sabe de que empresa es. El aislamiento se resuelve entonces
  -- con un JOIN contra el padre, no con una condicion sobre la fila.
  --
  -- Sin esto, un PUT o un DELETE con el id de una denominacion de otra empresa
  -- la modificaba o la borraba igual: el endpoint solo miraba el id.
  ------------------------------------------------------------------------------
  FUNCTION ES_DE_EMPRESA (
    p_id_detalle IN NUMBER,
    p_id_empresa IN NUMBER
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    IF p_id_detalle IS NULL OR p_id_empresa IS NULL THEN
      RETURN FALSE;
    END IF;

    SELECT COUNT(*)
      INTO l_existe
      FROM DETALLE_MONEDAS d
      JOIN MONEDAS         m ON m.ID_MONEDA = d.ID_MONEDA
     WHERE d.ID_DETALLE_MONEDA = p_id_detalle
       AND m.ID_EMPRESA        = p_id_empresa;

    RETURN l_existe > 0;
  END ES_DE_EMPRESA;

  -- idEmpresa es OBLIGATORIO: DETALLE_MONEDAS no tiene columna de empresa
  -- —cuelga de MONEDAS— asi que la consulta no se acota sola. Sin el, bastaba
  -- con conocer un idMoneda ajeno para leer las denominaciones de otra empresa.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_moneda     IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_empresa NUMBER;
    l_id_moneda  NUMBER;
    l_total     NUMBER;
    l_items     CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- La conversion va aca, dentro del BEGIN: en el DECLARE se ejecutaria antes
    -- de que exista el EXCEPTION y el error escaparia del procedimiento.
    -- NULLIF convierte la cadena vacia del parametro ausente en NULL antes de
    -- que TO_NUMBER la toque (si no, ORA-01722).
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_moneda  := TO_NUMBER(NULLIF(p_id_moneda, ''));

    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    SELECT COUNT(*)
      INTO l_total
      FROM DETALLE_MONEDAS d
      JOIN MONEDAS m ON m.ID_MONEDA = d.ID_MONEDA
     WHERE m.ID_EMPRESA = l_id_empresa
       AND (l_id_moneda IS NULL OR d.ID_MONEDA = l_id_moneda);

    -- Sin JOIN: la consulta sale de DETALLE_MONEDAS y nada mas. El nombre de la
    -- moneda no se devuelve porque el listado ya viene filtrado por una sola.
    --
    -- FOTO no se selecciona: es un BLOB y no entra en el JSON. En su lugar va
    -- `tieneFoto`, para que el frontend sepa si pedir la imagen sin traerse
    -- todos los binarios.
    --
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: el listado anda con pocas filas y devuelve 500 cuando crece.
    -- ORDEN: de MENOR A MAYOR por el valor de la denominacion, no alfabetico.
    -- DENOMINACION es VARCHAR2, y como texto "10000" va antes que "2000" — el
    -- listado saldria con los billetes desordenados.
    --
    -- La conversion usa DEFAULT NULL ON CONVERSION ERROR: sin eso, una sola
    -- fila con texto (las cargadas antes de que el alta exigiera solo digitos)
    -- mataria el listado entero con ORA-01722. Las no numericas quedan NULL y
    -- el NULLS LAST las manda al final, ordenadas por texto entre si.
    SELECT JSON_ARRAYAGG(fila ORDER BY valor NULLS LAST, denominacion RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'           VALUE d.ID_DETALLE_MONEDA,
                 'idMoneda'     VALUE d.ID_MONEDA,
                 'denominacion' VALUE d.DENOMINACION,
                 'tieneFoto'    VALUE CASE
                                        WHEN d.FOTO IS NOT NULL
                                         AND DBMS_LOB.GETLENGTH(d.FOTO) > 0
                                        THEN 'true' ELSE 'false'
                                      END FORMAT JSON
                 RETURNING CLOB
               ) AS fila,
               d.DENOMINACION AS denominacion,
               TO_NUMBER(
                 -- Se limpia todo lo que no sea digito antes de convertir, para
                 -- que un "50.000" cargado a mano igual ordene como 50000.
                 REGEXP_REPLACE(d.DENOMINACION, '[^0-9]', '')
                 DEFAULT NULL ON CONVERSION ERROR
               ) AS valor
          FROM DETALLE_MONEDAS d
          JOIN MONEDAS m ON m.ID_MONEDA = d.ID_MONEDA
         WHERE m.ID_EMPRESA = l_id_empresa
           AND (l_id_moneda IS NULL OR d.ID_MONEDA = l_id_moneda)
      );

    p_status_code := 200;
    -- JSON_OBJECT(... RETURNING CLOB) como asignacion PL/SQL directa (sin
    -- SELECT) falla con PLS-00684 dentro de un package body.
    --
    -- JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un array vacio: sin
    -- el NVL el frontend recibiria "items":null y reventaria al iterarlo.
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
      APEX_DEBUG.ERROR('PKG_DETALLE_MONEDAS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las denominaciones"}';
  END LISTAR;

  -- p_id_empresa es OBLIGATORIO aunque la tabla no tenga esa columna: acota la
  -- moneda padre. Sin el, una sesion de la empresa A podia agregarle una
  -- denominacion a una moneda de la B con solo conocer su id — el ACTUALIZAR y
  -- el ELIMINAR ya lo validaban, el alta no.
  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_moneda     IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_denominacion  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_moneda  NUMBER;
    l_id_empresa NUMBER;
    l_cuenta     PLS_INTEGER;
    l_id         NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_moneda  := TO_NUMBER(NULLIF(p_id_moneda, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    IF l_id_moneda IS NULL OR l_id_empresa IS NULL OR TRIM(p_denominacion) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idMoneda, idEmpresa y denominacion son obligatorios"}';
      RETURN;
    END IF;

    -- La moneda tiene que ser de esta empresa. 404 y no 403: responder "existe
    -- pero no es tuya" confirmaria que el id es valido en otra.
    SELECT COUNT(*) INTO l_cuenta
      FROM MONEDAS
     WHERE ID_MONEDA  = l_id_moneda
       AND ID_EMPRESA = l_id_empresa;

    IF l_cuenta = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"Moneda no encontrada"}';
      RETURN;
    END IF;

    -- La FOTO no se carga aca: el alta crea la fila y despues el frontend sube
    -- la imagen con PUT /detalle-monedas/foto/:id, que ya tiene el id.
    INSERT INTO DETALLE_MONEDAS (
      ID_MONEDA, DENOMINACION, FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_moneda,
      TRIM(p_denominacion),
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_DETALLE_MONEDA INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- El UNIQUE es (ID_MONEDA, DENOMINACION): el choque es dentro de la misma
      -- moneda, no global. El mensaje lo dice para que no parezca que la
      -- denominacion esta tomada en todas las monedas.
      p_status_code := 409;
      p_resultado := '{"error":"Esta moneda ya tiene una denominacion con ese nombre"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: la FK contra MONEDAS no encontro el padre. Es un dato
      -- invalido del cliente (400), no un fallo del servidor.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La moneda indicada no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_DETALLE_MONEDAS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear la denominacion"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_moneda     IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_denominacion  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id         NUMBER;
    l_id_moneda  NUMBER;
    l_id_empresa NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id         := TO_NUMBER(NULLIF(p_id, ''));
    l_id_moneda  := TO_NUMBER(NULLIF(p_id_moneda, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- AISLAMIENTO POR EMPRESA, via la moneda padre. 404 y no 403: responder
    -- "existe pero no es tuya" confirmaria que el id existe.
    IF NOT ES_DE_EMPRESA(l_id, l_id_empresa) THEN
      p_status_code := 404;
      p_resultado := '{"error":"La denominacion no existe"}';
      RETURN;
    END IF;

    -- La moneda DESTINO tambien tiene que ser de la misma empresa: sin este
    -- control se podria mover una denominacion a una moneda ajena, que es la
    -- puerta de atras al mismo problema que el chequeo de arriba cierra.
    IF l_id_moneda IS NOT NULL THEN
      DECLARE
        l_ok PLS_INTEGER;
      BEGIN
        SELECT COUNT(*)
          INTO l_ok
          FROM MONEDAS
         WHERE ID_MONEDA  = l_id_moneda
           AND ID_EMPRESA = l_id_empresa;

        IF l_ok = 0 THEN
          p_status_code := 400;
          p_resultado := '{"error":"La moneda indicada no pertenece a esta empresa"}';
          RETURN;
        END IF;
      END;
    END IF;

    -- La FOTO no se toca aca: tiene su propio PUT. Un UPDATE que la pusiera en
    -- NULL borraria la imagen cada vez que se corrige el nombre.
    UPDATE DETALLE_MONEDAS
       SET ID_MONEDA           = NVL(l_id_moneda, ID_MONEDA),
           DENOMINACION        = NVL(TRIM(p_denominacion), DENOMINACION),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_DETALLE_MONEDA = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La denominacion no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Esta moneda ya tiene una denominacion con ese nombre"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La moneda indicada no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_DETALLE_MONEDAS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar la denominacion"}';
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

    l_id         := TO_NUMBER(NULLIF(p_id, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- AISLAMIENTO POR EMPRESA, via la moneda padre: sin esto, un DELETE con el
    -- id de una denominacion ajena la borraba.
    IF NOT ES_DE_EMPRESA(l_id, l_id_empresa) THEN
      p_status_code := 404;
      p_resultado := '{"error":"La denominacion no existe"}';
      RETURN;
    END IF;

    -- Baja FISICA: la tabla no tiene columna ACTIVO. La foto se va con la fila
    -- (el BLOB vive en la misma), no hace falta borrarla aparte.
    DELETE FROM DETALLE_MONEDAS WHERE ID_DETALLE_MONEDA = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La denominacion no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos (los conteos de un cierre de caja, por ejemplo)
      -- apuntando a esta fila. Es un conflicto de estado (409), no un error del
      -- servidor: el dato que mandaron era valido.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de esta denominacion"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_DETALLE_MONEDAS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar la denominacion"}';
      END IF;
  END ELIMINAR;

  PROCEDURE GUARDAR_FOTO (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_foto          IN  BLOB,
    p_content_type  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_id     NUMBER;
    l_mime   VARCHAR2(100);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id := TO_NUMBER(NULLIF(p_id, ''));

    IF p_foto IS NULL OR DBMS_LOB.GETLENGTH(p_foto) = 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"No se recibio ninguna imagen"}';
      RETURN;
    END IF;

    -- El header puede venir con parametros ("image/png; charset=..."), asi que
    -- se corta en el punto y coma antes de guardarlo.
    l_mime := LOWER(TRIM(REGEXP_SUBSTR(p_content_type, '^[^;]+')));

    IF l_mime IS NULL OR l_mime NOT LIKE 'image/%' THEN
      p_status_code := 400;
      p_resultado := '{"error":"El archivo debe ser una imagen"}';
      RETURN;
    END IF;

    UPDATE DETALLE_MONEDAS
       SET FOTO                = p_foto,
           FOTO_MIME           = l_mime,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_DETALLE_MONEDA = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La denominacion no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_DETALLE_MONEDAS.GUARDAR_FOTO: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al guardar la foto"}';
  END GUARDAR_FOTO;

  ------------------------------------------------------------------------------
  -- Publica el modulo ORDS /detalle-monedas/ con sus endpoints.
  --
  -- Cada handler es una sola linea: invoca al procedimiento del paquete pasando
  -- los binds de ORDS como argumentos. Nada de PL/SQL embebido — salvo el GET
  -- de la foto, que por diseno de ORDS es una consulta (ver mas abajo).
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parametro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin
  -- esto, toda peticion cross-origin a /detalle-monedas/* la rechaza ORDS antes
  -- de llegar a cualquiera de los handlers. Ver la explicacion en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'detalle-monedas',
      p_base_path      => '/detalle-monedas/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Denominaciones de cada moneda, con foto'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'detalle-monedas',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /detalle-monedas/listar?idMoneda=
    --
    -- idMoneda no se declara con DEFINE_PARAMETER: los query params se vinculan
    -- solos al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'detalle-monedas', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'detalle-monedas',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_DETALLE_MONEDAS.LISTAR(:authorization, :idEmpresa, :idMoneda, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /detalle-monedas/crear
    -- Body: { idMoneda, denominacion }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'detalle-monedas', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'detalle-monedas',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_DETALLE_MONEDAS.INSERTAR(:authorization, :idMoneda, :idEmpresa, :denominacion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /detalle-monedas/actualizar/:id
    -- Body: { idMoneda?, denominacion? }  (ausentes = no cambia)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'detalle-monedas', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'detalle-monedas',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_DETALLE_MONEDAS.ACTUALIZAR(:authorization, :id, :idMoneda, :idEmpresa, :denominacion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /detalle-monedas/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'detalle-monedas', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'detalle-monedas',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_DETALLE_MONEDAS.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /detalle-monedas/foto/:id — PUBLICO, sin token
    --
    -- Lo consume un <img>, y el navegador no manda el header Authorization al
    -- descargar una imagen: con token, la foto no cargaria nunca.
    --
    -- La forma "natural" seria un procedimiento con un OUT BLOB declarado como
    -- p_source_type => 'RESPONSE'. No funciona: DEFINE_PARAMETER valida
    -- p_param_type contra REST_PARAMS_PARAM_TYPE_CK, y ni 'BLOB' ni 'RESOURCE'
    -- pasan esa restriccion. El ORA-02290 aborta PUBLICAR_ENDPOINTS a la mitad
    -- y deja el modulo SIN NINGUN endpoint, no solo sin este.
    --
    -- LA FORMA QUE SI FUNCIONA: source_type_media. ORDS toma una consulta que
    -- devuelve DOS columnas —content-type y BLOB, en ese orden— y arma la
    -- respuesta binaria el mismo, sin parametros de salida que declarar.
    --
    -- El 404 de la foto faltante sale solo: si la consulta no devuelve filas,
    -- ORDS responde 404 sin manejar un status code a mano. Por eso el WHERE
    -- filtra los BLOB vacios en vez de devolverlos — asi el <img> cae al
    -- respaldo en lugar de mostrar una imagen rota.
    --
    -- El mismo template lleva tambien el PUT que guarda la foto, mas abajo. Ese
    -- si es un handler PL/SQL normal: recibe el binario, no lo devuelve.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'detalle-monedas', p_pattern => 'foto/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'detalle-monedas',
      p_pattern     => 'foto/:id',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_media,
      p_source      => 'SELECT NVL(FOTO_MIME, ''image/png''), FOTO
                          FROM DETALLE_MONEDAS
                         WHERE ID_DETALLE_MONEDA = :id
                           AND FOTO IS NOT NULL
                           AND DBMS_LOB.GETLENGTH(FOTO) > 0'
    );

    ----------------------------------------------------------------------------
    -- PUT /detalle-monedas/foto/:id — con token
    -- Body: la imagen cruda. Content-Type: image/png, image/jpeg, etc.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_HANDLER(
      p_module_name   => 'detalle-monedas',
      p_pattern       => 'foto/:id',
      p_method        => 'PUT',
      p_source_type   => ORDS.source_type_plsql,
      p_mimes_allowed => 'image/png,image/jpeg,image/gif,image/webp,image/svg+xml',
      p_source        => 'BEGIN PKG_DETALLE_MONEDAS.GUARDAR_FOTO(:authorization, :id, :body, :content_type, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'foto/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    -- El Content-Type de entrada: de ahi sale el formato que se guarda.
    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'foto/:id', p_method => 'PUT',
      p_name => 'Content-Type', p_bind_variable_name => 'content_type',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'foto/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'detalle-monedas', p_pattern => 'foto/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_DETALLE_MONEDAS;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_DETALLE_MONEDAS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_DETALLE_MONEDAS'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_DETALLE_MONEDAS'
 ORDER BY SEQUENCE;

-- La columna FOTO_MIME tiene que aparecer aca (la agrega el paso 0).
SELECT COLUMN_NAME, DATA_TYPE, DATA_LENGTH
  FROM USER_TAB_COLUMNS
 WHERE TABLE_NAME = 'DETALLE_MONEDAS'
 ORDER BY COLUMN_ID;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'detalle-monedas';

-- Rutas publicadas: listar (GET), crear (POST), actualizar/:id (PUT),
-- eliminar/:id (DELETE), foto/:id (GET y PUT).
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'detalle-monedas'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

SELECT d.ID_DETALLE_MONEDA, d.ID_MONEDA, m.NOMBRE_MONEDA, d.DENOMINACION,
       CASE WHEN d.FOTO IS NOT NULL AND DBMS_LOB.GETLENGTH(d.FOTO) > 0
            THEN 'SI' ELSE 'NO' END AS TIENE_FOTO,
       d.FOTO_MIME
  FROM DETALLE_MONEDAS d
  JOIN MONEDAS         m ON m.ID_MONEDA = d.ID_MONEDA
 ORDER BY m.NOMBRE_MONEDA, d.DENOMINACION;
