--------------------------------------------------------------------------------
-- CTELL · PKG_CLOUDINARY
--
-- Borra archivos de Cloudinary cuando se borra la fila que los referenciaba.
--
-- Es un paquete INTERNO, como PKG_STOCK: no publica módulo ORDS ni valida
-- token — quien lo llama ya validó el suyo. Rompe la regla de "un archivo por
-- tabla" por lo mismo que auth.sql y stock.sql.
--
-- ORDEN DE EJECUCIÓN EN APEX:
--   auth.sql -> cloudinary-ddl.sql (una vez) -> cloudinary.sql
--            -> articulos.sql, reportes-multimedia.sql, reportes-actividades.sql
-- Al revés, esos tres compilan INVALID con PLS-00201 y devuelven 500 mudo.
--
-- DESPUÉS, A MANO, EN SQL COMMANDS (los datos están en el panel de Cloudinary,
-- Settings -> API Keys):
--   BEGIN PKG_CLOUDINARY.FIJAR_CREDENCIALES('cayve9bx', '<api_key>', '<api_secret>'); END;
--   BEGIN PKG_CLOUDINARY.PROBAR; END;
-- Sin credenciales nada falla: los archivos quedan en Cloudinary como antes.
--
-- POR QUÉ LO HACE ORACLE Y NO EL NAVEGADOR: borrar exige firmar el pedido con
-- la API_SECRET, y el frontend es estático — lo que se ponga ahí lo lee
-- cualquiera, y con esa clave se borra la cuenta entera. La subida sí va desde
-- el navegador, porque un preset "unsigned" no necesita secreto.
--
-- EL BORRADO ES "BEST EFFORT" Y VA DESPUÉS DEL COMMIT. Nunca deshace la
-- operación que lo pidió: si Cloudinary no responde, la fila ya se borró y el
-- archivo queda huérfano, que es exactamente lo que pasaba antes. Al revés
-- —borrar el archivo y que después falle el COMMIT— dejaría una fila apuntando
-- a una foto que ya no existe, que es peor. BORRAR nunca lanza: registra el
-- motivo con APEX_DEBUG y sigue.
--
-- SÓLO BORRA ARCHIVOS DE ESTA CUENTA. Una URL pegada a mano desde otro lado
-- (las evidencias aceptan cualquier https://) no se toca: no es nuestra.
--
-- EL PUBLIC_ID SE SACA DE LA URL. Una URL de entrega es
--   https://res.cloudinary.com/<cloud>/<image|video|raw>/upload/v<n>/<public_id>.<ext>
-- En imagen y video la extensión NO es parte del id (es el formato de
-- entrega); en raw sí. Sirve para las dos formas de nombrar que conviven: la
-- del hub (src/lib/cloudinary.ts, public_id propio) y la de la app del
-- profesor (use_filename del preset: 'foto-m8x2k1-4f9a.jpg' queda con id
-- 'foto-m8x2k1-4f9a').
--
-- SE BORRA CON LA UPLOAD API (/destroy) Y NO CON LA ADMIN API: la Admin API
-- tiene un tope de pedidos por hora en el plan gratuito, la de subida no. Va
-- con invalidate=true para que el CDN deje de servir la copia en caché.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_CLOUDINARY AS

  -- Borra el archivo de una URL de esta cuenta. NUNCA lanza: si no puede, lo
  -- registra con APEX_DEBUG. NULL, URL ajena o sin credenciales -> no hace nada.
  -- Llamarlo DESPUÉS del COMMIT de la operación que soltó la URL.
  PROCEDURE BORRAR (p_url IN VARCHAR2);

  -- A mano, en SQL Commands.
  PROCEDURE FIJAR_CREDENCIALES (
    p_cloud_name IN VARCHAR2,
    p_api_key    IN VARCHAR2,
    p_api_secret IN VARCHAR2
  );

  -- Sin URL: muestra qué credenciales hay (la secreta, sólo sus 4 últimos).
  -- Con URL: intenta borrarla y muestra la respuesta entera de Cloudinary, en
  -- vez de tragársela como BORRAR.
  PROCEDURE PROBAR (p_url IN VARCHAR2 DEFAULT NULL);

END PKG_CLOUDINARY;
/

CREATE OR REPLACE PACKAGE BODY PKG_CLOUDINARY AS

  c_api CONSTANT VARCHAR2(60) := 'https://api.cloudinary.com/v1_1/';

  FUNCTION CONFIG (p_clave IN VARCHAR2) RETURN VARCHAR2 IS
    l_v CLOUDINARY_CONFIG.VALOR%TYPE;
  BEGIN
    SELECT VALOR INTO l_v FROM CLOUDINARY_CONFIG WHERE CLAVE = p_clave;
    RETURN TRIM(l_v);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END CONFIG;

  PROCEDURE GUARDAR_CONFIG (p_clave IN VARCHAR2, p_valor IN VARCHAR2) IS
  BEGIN
    MERGE INTO CLOUDINARY_CONFIG t
    USING (SELECT p_clave AS clave, TRIM(p_valor) AS valor FROM DUAL) s
       ON (t.CLAVE = s.clave)
     WHEN MATCHED THEN UPDATE SET t.VALOR = s.valor, t.MODIFICADO_EL = SYSDATE
     WHEN NOT MATCHED THEN INSERT (CLAVE, VALOR) VALUES (s.clave, s.valor);
  END GUARDAR_CONFIG;

  -- Tipo de recurso y public_id de una URL de entrega de esta cuenta, o los
  -- dos en NULL si la URL no es de acá.
  PROCEDURE DESARMAR_URL (
    p_url     IN  VARCHAR2,
    p_cloud   IN  VARCHAR2,
    p_recurso OUT VARCHAR2,
    p_id      OUT VARCHAR2
  ) IS
    l_resto VARCHAR2(1000);
  BEGIN
    p_recurso := NULL;
    p_id      := NULL;

    p_recurso := REGEXP_SUBSTR(p_url,
                   '^https://res\.cloudinary\.com/' || p_cloud || '/(image|video|raw)/upload/',
                   1, 1, 'i', 1);
    IF p_recurso IS NULL THEN
      RETURN;
    END IF;
    p_recurso := LOWER(p_recurso);

    l_resto := REGEXP_SUBSTR(p_url, '/upload/(.+)$', 1, 1, NULL, 1);
    -- Sin query string ni fragmento, y sin el segmento de versión ("v1730...").
    l_resto := REGEXP_REPLACE(l_resto, '[?#].*$', '');
    l_resto := REGEXP_REPLACE(l_resto, '^v[0-9]+/', '');

    -- En raw la extensión es parte del id.
    IF p_recurso IN ('image', 'video') THEN
      l_resto := REGEXP_REPLACE(l_resto, '\.[^./]+$', '');
    END IF;

    p_id := UTL_URL.UNESCAPE(l_resto, 'UTF-8');
  END DESARMAR_URL;

  -- Pide el borrado y devuelve el estado HTTP y el cuerpo de la respuesta.
  -- Puede lanzar: los que lo llaman deciden si tragarse el error.
  FUNCTION DESTRUIR (
    p_url    IN  VARCHAR2,
    p_status OUT NUMBER
  ) RETURN CLOB IS
    l_cloud   VARCHAR2(200) := CONFIG('CLOUD_NAME');
    l_key     VARCHAR2(200) := CONFIG('API_KEY');
    l_secret  VARCHAR2(200) := CONFIG('API_SECRET');
    l_recurso VARCHAR2(10);
    l_id      VARCHAR2(1000);
    l_ts      VARCHAR2(20);
    l_firma   VARCHAR2(40);
    l_cuerpo  VARCHAR2(4000);
    l_resp    CLOB;
  BEGIN
    p_status := NULL;

    IF l_cloud IS NULL OR l_key IS NULL OR l_secret IS NULL THEN
      RETURN 'Sin credenciales: cargarlas con PKG_CLOUDINARY.FIJAR_CREDENCIALES';
    END IF;

    DESARMAR_URL(p_url, l_cloud, l_recurso, l_id);
    IF l_id IS NULL THEN
      RETURN 'La URL no es de la cuenta ' || l_cloud || ': no se toca';
    END IF;

    -- Segundos Unix en UTC: Cloudinary rechaza una firma de más de una hora.
    l_ts := TO_CHAR(ROUND((CAST(SYS_EXTRACT_UTC(SYSTIMESTAMP) AS DATE) - DATE '1970-01-01') * 86400));

    -- La firma: SHA-1 de los parámetros en orden alfabético, SIN escapar, más
    -- el secreto pegado al final. STANDARD_HASH porque DBMS_CRYPTO no está
    -- otorgado en este esquema (ver HASH_PASSWORD en db/auth.sql); sólo se
    -- puede usar desde SQL, de ahí el SELECT.
    SELECT LOWER(RAWTOHEX(STANDARD_HASH(
             'invalidate=true&public_id=' || l_id || '&timestamp=' || l_ts || l_secret, 'SHA1')))
      INTO l_firma
      FROM DUAL;

    l_cuerpo := 'public_id='  || UTL_URL.ESCAPE(l_id, TRUE, 'UTF-8')
             || '&invalidate=true'
             || '&timestamp=' || l_ts
             || '&api_key='   || l_key
             || '&signature=' || l_firma;

    -- APEX_WEB_SERVICE necesita un workspace, y un handler de ORDS no corre
    -- dentro de ninguno: el mismo problema que APEX_MAIL en db/auth.sql.
    BEGIN
      APEX_UTIL.SET_SECURITY_GROUP_ID(
        APEX_UTIL.FIND_SECURITY_GROUP_ID(p_workspace => PKG_AUTH.C_WORKSPACE_MAIL));
    EXCEPTION
      WHEN OTHERS THEN NULL;  -- en SQL Workshop ya hay workspace
    END;

    APEX_WEB_SERVICE.g_request_headers.DELETE;
    APEX_WEB_SERVICE.g_request_headers(1).name  := 'Content-Type';
    APEX_WEB_SERVICE.g_request_headers(1).value := 'application/x-www-form-urlencoded';

    -- Timeout corto: esto corre dentro del pedido de quien borró, y una foto
    -- huérfana no justifica dejarlo esperando.
    l_resp := APEX_WEB_SERVICE.MAKE_REST_REQUEST(
                p_url              => c_api || l_cloud || '/' || l_recurso || '/destroy',
                p_http_method      => 'POST',
                p_body             => l_cuerpo,
                p_transfer_timeout => 10);
    p_status := APEX_WEB_SERVICE.g_status_code;
    APEX_WEB_SERVICE.g_request_headers.DELETE;

    RETURN l_resp;
  END DESTRUIR;

  PROCEDURE BORRAR (p_url IN VARCHAR2) IS
    l_status    NUMBER;
    l_resp      CLOB;
    l_resultado VARCHAR2(100);
  BEGIN
    IF TRIM(p_url) IS NULL THEN
      RETURN;
    END IF;

    l_resp := DESTRUIR(p_url, l_status);

    IF l_status = 200 THEN
      BEGIN
        l_resultado := JSON_OBJECT_T.parse(l_resp).get_string('result');
      EXCEPTION
        WHEN OTHERS THEN l_resultado := NULL;
      END;
    END IF;

    -- "not found" también es éxito: el archivo ya no está, que es lo que se
    -- quería (lo borró alguien desde el panel, o la otra app).
    IF NVL(l_resultado, '-') NOT IN ('ok', 'not found') THEN
      APEX_DEBUG.WARN('PKG_CLOUDINARY.BORRAR: ' || SUBSTR(p_url, 1, 300) || ' -> '
                      || NVL(TO_CHAR(l_status), '-') || ' ' || DBMS_LOB.SUBSTR(l_resp, 500, 1));
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      APEX_WEB_SERVICE.g_request_headers.DELETE;
      APEX_DEBUG.WARN('PKG_CLOUDINARY.BORRAR: ' || SUBSTR(p_url, 1, 300) || ' -> ' || SQLERRM);
  END BORRAR;

  PROCEDURE FIJAR_CREDENCIALES (
    p_cloud_name IN VARCHAR2,
    p_api_key    IN VARCHAR2,
    p_api_secret IN VARCHAR2
  ) IS
  BEGIN
    GUARDAR_CONFIG('CLOUD_NAME', p_cloud_name);
    GUARDAR_CONFIG('API_KEY',    p_api_key);
    GUARDAR_CONFIG('API_SECRET', p_api_secret);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('[OK]   Credenciales guardadas. Probalas con: BEGIN PKG_CLOUDINARY.PROBAR; END;');
  END FIJAR_CREDENCIALES;

  PROCEDURE PROBAR (p_url IN VARCHAR2 DEFAULT NULL) IS
    l_status NUMBER;
    l_resp   CLOB;
  BEGIN
    DBMS_OUTPUT.PUT_LINE('CLOUD_NAME: ' || NVL(CONFIG('CLOUD_NAME'), '(falta)'));
    DBMS_OUTPUT.PUT_LINE('API_KEY:    ' || NVL(CONFIG('API_KEY'), '(falta)'));
    DBMS_OUTPUT.PUT_LINE('API_SECRET: ' || CASE WHEN CONFIG('API_SECRET') IS NULL THEN '(falta)'
                                                ELSE '...' || SUBSTR(CONFIG('API_SECRET'), -4) END);

    IF p_url IS NULL THEN
      DBMS_OUTPUT.PUT_LINE('Para probar un borrado de verdad: BEGIN PKG_CLOUDINARY.PROBAR(''https://res.cloudinary.com/...''); END;');
      RETURN;
    END IF;

    l_resp := DESTRUIR(p_url, l_status);
    DBMS_OUTPUT.PUT_LINE('HTTP ' || NVL(TO_CHAR(l_status), '-') || ': ' || DBMS_LOB.SUBSTR(l_resp, 2000, 1));
    -- {"result":"ok"} = borrado; {"result":"not found"} = la firma anduvo pero
    -- el id no existe; 401 "Invalid Signature" = el API_SECRET está mal.
  EXCEPTION
    WHEN OTHERS THEN
      APEX_WEB_SERVICE.g_request_headers.DELETE;
      DBMS_OUTPUT.PUT_LINE('[ERROR] ' || SQLERRM);
  END PROBAR;

END PKG_CLOUDINARY;
/

-- Si algo salió INVALID arriba, acá está el motivo.
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_CLOUDINARY';

SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_CLOUDINARY'
 ORDER BY SEQUENCE;
