--------------------------------------------------------------------------------
-- CTELL · AUTENTICACION
--
-- Script único: paquete PL/SQL + endpoints ORDS. Se ejecuta de una sola vez en
-- la hoja de trabajo SQL de APEX, conectado con el esquema del workspace.
--
-- Alcance: SOLO autenticación. Acá no hay ABM de usuarios — el alta, la baja y
-- la modificación viven en db/usuarios.sql. Este archivo se limita a:
--
--   POST /auth/login    { usuario, password }        -> token + datos de sesion
--   POST /auth/logout   Authorization: Bearer <tok>  -> revoca el token
--   GET  /auth/me       Authorization: Bearer <tok>  -> usuario de la sesion
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/auth/
--
-- Tablas que usa (no las crea ni las altera; el DDL se administra aparte):
--   USUARIOS  ID_USUARIO, USUARIO, NOMBRE_APELLIDO, CORREO, CONTRASENA_HASH,
--             SALT, ACTIVO, ES_ADMIN, FECHA_CREACION, FECHA_ACTUALIZACION
--   TOKENS    ID_TOKEN, ID_USUARIO, TOKEN, FECHA_CREACION, FECHA_EXPIRACION,
--             ACTIVO
--
-- ESTADO: 'A'/'I' EN LAS DOS TABLAS.
--   USUARIOS.ACTIVO  VARCHAR2(1)  -> 'A' activo    / 'I' inactivo
--   TOKENS.ACTIVO    VARCHAR2(1)  -> 'A' vigente   / 'I' revocado
--
-- El código de estado es el mismo en toda la base, sin excepciones y sin
-- traducción a 1/0 en ningún punto. Este script compara ACTIVO como texto en
-- las dos tablas y asume que TOKENS.ACTIVO ya es VARCHAR2(1) — se cambió a
-- mano junto con el vaciado de la tabla. Contra la definición anterior
-- (NUMBER(1,0) con 1/0) cada login moriría con ORA-01722.
--
-- HASH: SHA-256 sobre (SALT || password), con salt aleatorio de 32 hex por
-- usuario derivado de SYS_GUID(). No se usa DBMS_CRYPTO porque no está
-- concedido en este workspace. STANDARD_HASH es una función SQL, no PL/SQL:
-- se invoca desde un SELECT ... FROM DUAL. Llamarla como expresión PL/SQL
-- directa falla con PLS-00201, que parece falta de grants pero no lo es.
--
-- Limitación conocida: SHA-256 es de una sola pasada, sin factor de trabajo.
-- Si más adelante se consigue
--     GRANT EXECUTE ON SYS.DBMS_CRYPTO TO WKSP_CTELL;
-- conviene migrar HASH_PASSWORD a PBKDF2 (ver la nota dentro de la función).
--
-- CORS: por defecto ORDS no manda Access-Control-Allow-Origin, así que el
-- navegador bloquea llamadas a estos endpoints desde otro origen.
--
-- ORIGINS_ALLOWED ES POR MODULO, NO A NIVEL DE WORKSPACE. La pantalla de APEX
-- se llama "Administración del Workspace -> RESTful Services -> orígenes
-- permitidos", lo que sugiere un ajuste global — no lo es. Cargarlo ahí para
-- un módulo (o vía p_origins_allowed en DEFINE_MODULE) NO lo propaga a los
-- demás. Confirmado en producción: auth tenía los orígenes cargados y
-- usuarios no, y toda petición cross-origin a /usuarios/ (por ejemplo desde
-- www.ctell.online) volvía un "Service Unavailable" genérico de ORDS —el
-- handler ni llegaba a ejecutarse, así que el WHEN OTHERS con SQLERRM tampoco
-- ayudaba— hasta que se cargó ORIGINS_ALLOWED también en ese módulo.
--
-- Por eso cada módulo lo declara con p_origins_allowed en su propio
-- DEFINE_MODULE (ver más abajo), en vez de asumir que alcanza con configurarlo
-- una vez en la UI. Orígenes vigentes hoy:
--   https://www.ctell.online   producción
--   http://localhost:8080      desarrollo (solo hace falta si se prueba
--                               pegándole directo a ORDS sin el proxy de
--                               Vite; con el proxy, Vite nunca necesita CORS)
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_AUTH — credenciales y sesiones
--
-- El paquete resuelve tres cosas y nada más: verificar un usuario contra su
-- hash, emitir un token, y decir a quién pertenece un token.
--
-- El token es un valor aleatorio de 64 hex (dos SYS_GUID concatenados, que dan
-- exactamente el largo de la columna TOKEN). No lleva datos adentro: se valida
-- siempre contra la base, así que revocar una sesión tiene efecto inmediato.
-- Un JWT no permitiría eso sin una lista de revocación aparte.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_AUTH AS

  -- Códigos de error de negocio, en el rango que Oracle reserva al usuario.
  -- Los handlers los traducen a 400/404; cualquier otro código se oculta como
  -- 500 para no filtrar detalles internos.
  C_ERR_NO_EXISTE       CONSTANT PLS_INTEGER := -20002;
  C_ERR_DATOS_INVALIDOS CONSTANT PLS_INTEGER := -20004;

  -- Código de estado, el mismo para USUARIOS.ACTIVO y TOKENS.ACTIVO: las dos
  -- son VARCHAR2(1). En un token 'A' significa vigente e 'I' revocado.
  C_ESTADO_ACTIVO   CONSTANT VARCHAR2(1) := 'A';
  C_ESTADO_INACTIVO CONSTANT VARCHAR2(1) := 'I';

  -- Vigencia de la sesión. Al vencer, el frontend recibe 401 y limpia su token.
  C_HORAS_VIGENCIA CONSTANT NUMBER := 8;

  -- Largo exacto de TOKENS.TOKEN. Se valida antes de ir a la base.
  C_LARGO_TOKEN CONSTANT PLS_INTEGER := 64;

  FUNCTION GENERAR_SALT RETURN VARCHAR2;

  -- Expuesta porque el alta de usuarios (db/usuarios.sql) necesita generar el
  -- hash con exactamente el mismo algoritmo que usa el login para verificarlo.
  -- Si cada lado calculara el suyo, el usuario se crearía sin poder entrar.
  FUNCTION HASH_PASSWORD (
    p_password IN VARCHAR2,
    p_salt     IN VARCHAR2
  ) RETURN VARCHAR2;

  -- Devuelve el ID si las credenciales son correctas, NULL si no.
  -- No distingue "no existe" de "clave incorrecta": informarlo permitiría
  -- enumerar cuentas válidas.
  FUNCTION VERIFICAR_CREDENCIALES (
    p_usuario  IN VARCHAR2,
    p_password IN VARCHAR2
  ) RETURN NUMBER;

  PROCEDURE CREAR_TOKEN (
    p_id_usuario       IN  NUMBER,
    p_horas            IN  NUMBER DEFAULT C_HORAS_VIGENCIA,
    p_token            OUT VARCHAR2,
    p_fecha_expiracion OUT TIMESTAMP
  );

  -- Devuelve el ID del usuario si el token está vigente Y su cuenta sigue
  -- activa; NULL en cualquier otro caso. Es la función que todo handler
  -- protegido debe llamar antes de hacer nada.
  FUNCTION VALIDAR_TOKEN (p_token IN VARCHAR2) RETURN NUMBER;

  -- Quita el prefijo "Bearer " del header Authorization y devuelve el token
  -- limpio. Centralizado acá para que cada handler no repita el REPLACE.
  FUNCTION TOKEN_DE_HEADER (p_authorization IN VARCHAR2) RETURN VARCHAR2;

  PROCEDURE REVOCAR_TOKEN (p_token IN VARCHAR2);

  -- La usa el ABM al inactivar o eliminar un usuario: sin esto, la persona
  -- inactivada sigue navegando con la sesión que ya tenía abierta.
  PROCEDURE REVOCAR_TOKENS_USUARIO (p_id_usuario IN NUMBER);

  -- Mantenimiento opcional: marca como revocados los tokens ya vencidos.
  -- No es necesaria para la seguridad (VALIDAR_TOKEN ya compara la fecha),
  -- sirve para que la tabla no crezca con filas activas que no lo están.
  PROCEDURE LIMPIAR_TOKENS_VENCIDOS (p_afectados OUT NUMBER);

END PKG_AUTH;
/

CREATE OR REPLACE PACKAGE BODY PKG_AUTH AS

  ------------------------------------------------------------------------------
  -- Privados
  ------------------------------------------------------------------------------

  -- Compara dos cadenas recorriéndolas enteras siempre.
  --
  -- Un `=` corta en la primera diferencia, y ese tiempo distinto es medible:
  -- permite ir adivinando el hash carácter por carácter. Acá el costo de
  -- recorrer 64 caracteres es irrelevante y elimina el canal lateral.
  FUNCTION COMPARAR_SEGURO (p_a IN VARCHAR2, p_b IN VARCHAR2) RETURN BOOLEAN IS
    l_diferencia PLS_INTEGER := 0;
  BEGIN
    IF p_a IS NULL OR p_b IS NULL THEN
      RETURN FALSE;
    END IF;

    -- El largo sí se compara de entrada: no es secreto y evita el bucle.
    IF LENGTH(p_a) != LENGTH(p_b) THEN
      RETURN FALSE;
    END IF;

    FOR i IN 1 .. LENGTH(p_a) LOOP
      l_diferencia := l_diferencia
        + ABS(ASCII(SUBSTR(p_a, i, 1)) - ASCII(SUBSTR(p_b, i, 1)));
    END LOOP;

    RETURN l_diferencia = 0;
  END COMPARAR_SEGURO;

  ------------------------------------------------------------------------------
  -- Públicos
  ------------------------------------------------------------------------------

  FUNCTION GENERAR_SALT RETURN VARCHAR2 IS
  BEGIN
    -- SYS_GUID() da 16 bytes -> 32 hex, el largo exacto de la columna SALT.
    RETURN RAWTOHEX(SYS_GUID());
  END GENERAR_SALT;

  FUNCTION HASH_PASSWORD (
    p_password IN VARCHAR2,
    p_salt     IN VARCHAR2
  ) RETURN VARCHAR2 IS
    l_hash VARCHAR2(256);
  BEGIN
    IF p_password IS NULL OR p_salt IS NULL THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS,
        'Password y salt son obligatorios');
    END IF;

    -- El salt va ADELANTE de la clave: así dos usuarios con la misma
    -- contraseña producen hashes distintos y una tabla precalculada no sirve.
    -- Salida: 64 hex, holgado dentro de los 256 de CONTRASENA_HASH.
    --
    -- El SELECT ... FROM DUAL no es adorno: STANDARD_HASH es SQL, no PL/SQL.
    -- Como expresión directa da PLS-00201.
    --
    -- Con el grant de DBMS_CRYPTO, reemplazar el SELECT por:
    --   RETURN RAWTOHEX(DBMS_CRYPTO.PBKDF2(
    --     UTL_I18N.STRING_TO_RAW(p_password, 'AL32UTF8'),
    --     HEXTORAW(p_salt), 100000, DBMS_CRYPTO.HMAC_SH512, 64));
    SELECT STANDARD_HASH(p_salt || p_password, 'SHA256')
      INTO l_hash
      FROM DUAL;

    RETURN l_hash;
  END HASH_PASSWORD;

  FUNCTION VERIFICAR_CREDENCIALES (
    p_usuario  IN VARCHAR2,
    p_password IN VARCHAR2
  ) RETURN NUMBER IS
    l_id           NUMBER;
    l_hash_guardado VARCHAR2(256);
    l_salt         VARCHAR2(32);
  BEGIN
    -- USUARIO se guarda en minúscula, así que se busca en minúscula.
    --
    -- ACTIVO guarda 'A'/'I'. Escribir `ACTIVO = 1` hace que Oracle intente
    -- convertir la columna a número y mate el login con ORA-01722 — que llega
    -- al handler como un 500 genérico, sin ninguna pista de que era tipos.
    SELECT ID_USUARIO, CONTRASENA_HASH, SALT
      INTO l_id, l_hash_guardado, l_salt
      FROM USUARIOS
     WHERE USUARIO = LOWER(TRIM(p_usuario))
       AND UPPER(TRIM(ACTIVO)) = C_ESTADO_ACTIVO;

    IF COMPARAR_SEGURO(HASH_PASSWORD(p_password, l_salt), l_hash_guardado) THEN
      RETURN l_id;
    END IF;

    RETURN NULL;

  EXCEPTION
    -- Usuario inexistente o inactivo: misma respuesta que clave incorrecta.
    -- Quien llama no puede distinguir los casos, y esa es la intención.
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END VERIFICAR_CREDENCIALES;

  PROCEDURE CREAR_TOKEN (
    p_id_usuario       IN  NUMBER,
    p_horas            IN  NUMBER DEFAULT C_HORAS_VIGENCIA,
    p_token            OUT VARCHAR2,
    p_fecha_expiracion OUT TIMESTAMP
  ) IS
    -- VARCHAR2 y no NUMBER: ACTIVO guarda el código 'A'/'I'. Leerlo en una
    -- variable numérica provoca ORA-01722.
    l_activo VARCHAR2(1);
  BEGIN
    -- No se emiten sesiones para cuentas inactivas o inexistentes. El login ya
    -- lo filtra, pero esta función es pública: se revalida acá.
    BEGIN
      SELECT UPPER(TRIM(ACTIVO))
        INTO l_activo
        FROM USUARIOS
       WHERE ID_USUARIO = p_id_usuario;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(C_ERR_NO_EXISTE, 'El usuario no existe');
    END;

    IF l_activo IS NULL OR l_activo != C_ESTADO_ACTIVO THEN
      RAISE_APPLICATION_ERROR(C_ERR_NO_EXISTE, 'El usuario esta inactivo');
    END IF;

    -- Dos SYS_GUID dan 64 hex, el largo exacto de TOKENS.TOKEN.
    p_token := RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID());
    p_fecha_expiracion := SYSTIMESTAMP
      + NUMTODSINTERVAL(NVL(p_horas, C_HORAS_VIGENCIA), 'HOUR');

    INSERT INTO TOKENS (
      ID_USUARIO, TOKEN, FECHA_CREACION, FECHA_EXPIRACION, ACTIVO
    ) VALUES (
      p_id_usuario, p_token, SYSTIMESTAMP, p_fecha_expiracion, C_ESTADO_ACTIVO
    );
  END CREAR_TOKEN;

  FUNCTION VALIDAR_TOKEN (p_token IN VARCHAR2) RETURN NUMBER IS
    l_id_usuario NUMBER;
  BEGIN
    -- Descarte barato antes de tocar la base: nada que no mida 64 hex puede
    -- ser un token emitido por CREAR_TOKEN.
    IF p_token IS NULL OR LENGTH(p_token) != C_LARGO_TOKEN THEN
      RETURN NULL;
    END IF;

    -- El JOIN contra USUARIOS no es opcional: inactivar una cuenta tiene que
    -- cortar el acceso aunque su token todavía no haya vencido.
    --
    -- Las dos columnas ACTIVO son VARCHAR2(1) con 'A'/'I' y se comparan igual.
    SELECT t.ID_USUARIO
      INTO l_id_usuario
      FROM TOKENS t
      JOIN USUARIOS u ON u.ID_USUARIO = t.ID_USUARIO
     WHERE t.TOKEN = p_token
       AND UPPER(TRIM(t.ACTIVO)) = C_ESTADO_ACTIVO
       AND t.FECHA_EXPIRACION > SYSTIMESTAMP
       AND UPPER(TRIM(u.ACTIVO)) = C_ESTADO_ACTIVO;

    RETURN l_id_usuario;

  EXCEPTION
    -- Token inexistente, revocado, vencido o de un usuario inactivo: todos
    -- terminan acá y valen lo mismo — no hay sesión.
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END VALIDAR_TOKEN;

  FUNCTION TOKEN_DE_HEADER (p_authorization IN VARCHAR2) RETURN VARCHAR2 IS
    l_token VARCHAR2(200);
  BEGIN
    IF p_authorization IS NULL THEN
      RETURN NULL;
    END IF;

    -- REGEXP y no REPLACE: el esquema es case-insensitive por RFC ("bearer",
    -- "Bearer") y puede venir con espacios de más. Un REPLACE literal de
    -- 'Bearer ' deja pasar "bearer xxx" con el prefijo pegado al token, que
    -- después falla el control de largo y da un 401 imposible de explicar.
    l_token := REGEXP_REPLACE(TRIM(p_authorization), '^[Bb]earer[[:space:]]+', '');

    RETURN NULLIF(TRIM(l_token), '');
  END TOKEN_DE_HEADER;

  PROCEDURE REVOCAR_TOKEN (p_token IN VARCHAR2) IS
  BEGIN
    UPDATE TOKENS
       SET ACTIVO = C_ESTADO_INACTIVO
     WHERE TOKEN = p_token
       AND UPPER(TRIM(ACTIVO)) = C_ESTADO_ACTIVO;

    -- A propósito sin verificar SQL%ROWCOUNT: cerrar sesión es idempotente.
    -- Que el token ya estuviera revocado o no existiera no es un error — el
    -- resultado que el cliente pidió (no tener sesión) se cumple igual.
  END REVOCAR_TOKEN;

  PROCEDURE REVOCAR_TOKENS_USUARIO (p_id_usuario IN NUMBER) IS
  BEGIN
    UPDATE TOKENS
       SET ACTIVO = C_ESTADO_INACTIVO
     WHERE ID_USUARIO = p_id_usuario
       AND UPPER(TRIM(ACTIVO)) = C_ESTADO_ACTIVO;
  END REVOCAR_TOKENS_USUARIO;

  PROCEDURE LIMPIAR_TOKENS_VENCIDOS (p_afectados OUT NUMBER) IS
  BEGIN
    UPDATE TOKENS
       SET ACTIVO = C_ESTADO_INACTIVO
     WHERE UPPER(TRIM(ACTIVO)) = C_ESTADO_ACTIVO
       AND FECHA_EXPIRACION <= SYSTIMESTAMP;

    p_afectados := SQL%ROWCOUNT;
    COMMIT;
  END LIMPIAR_TOKENS_VENCIDOS;

END PKG_AUTH;
/

--------------------------------------------------------------------------------
-- 2. Utilidad: borrar un módulo ORDS si existe
--
-- Hace falta para que el script sea reejecutable: DEFINE_MODULE falla con
-- ORA-00001 si el módulo ya está.
--
-- Lo que NO se puede hacer es un `WHEN OTHERS THEN NULL` inline. Parece
-- inofensivo —"si no existe, seguí"— pero se traga cualquier error, incluido
-- el ORA-00060 (interbloqueo) que aparece cuando otra sesión tiene tomadas las
-- filas de metadatos de ORDS: típicamente el propio ORDS sirviendo peticiones
-- del `npm run dev` mientras se reejecuta esto. El DELETE falla en silencio, el
-- DEFINE_MODULE muere con ORA-00001, y el módulo viejo sigue publicado mientras
-- el script parece haber andado.
--
-- Por eso: se consulta antes de borrar, se reintenta el interbloqueo (es
-- transitorio) y cualquier otro error se re-lanza.
--
-- Aun así: frená `npm run dev` antes de reejecutar este archivo.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE BORRAR_MODULO_ORDS (p_modulo IN VARCHAR2) AS
  C_INTENTOS CONSTANT PLS_INTEGER := 3;
  l_existe   PLS_INTEGER;
BEGIN
  FOR i IN 1 .. C_INTENTOS LOOP
    BEGIN
      -- Se consulta en vez de capturar el error de "no existe": así el
      -- EXCEPTION queda libre para los fallos que sí importan.
      SELECT COUNT(*)
        INTO l_existe
        FROM USER_ORDS_MODULES
       WHERE NAME = p_modulo;

      IF l_existe = 0 THEN
        RETURN;  -- No existía: nada que borrar.
      END IF;

      ORDS.DELETE_MODULE(p_module_name => p_modulo);
      COMMIT;  -- Libera los locks antes de que DEFINE_MODULE los vuelva a pedir.
      RETURN;

    EXCEPTION
      WHEN OTHERS THEN
        -- ORA-00060 (interbloqueo) y ORA-04020 (lock de objeto) son
        -- transitorios: la otra sesión termina y el reintento pasa.
        IF SQLCODE IN (-60, -4020) AND i < C_INTENTOS THEN
          ROLLBACK;
          DBMS_SESSION.SLEEP(2);
        ELSE
          RAISE;
        END IF;
    END;
  END LOOP;
END BORRAR_MODULO_ORDS;
/

--------------------------------------------------------------------------------
-- 3. ORDS · MÓDULO /auth/
--
--   POST /auth/login    público
--   POST /auth/logout   requiere token
--   GET  /auth/me       requiere token
--
-- No se llama a ORDS.ENABLE_SCHEMA: en APEX el esquema del workspace ya está
-- habilitado y esa llamada falla con ORA-01031 (privilegios insuficientes).
--
-- Cada handler declara sus parámetros con ORDS.DEFINE_PARAMETER:
--   resultado           RESPONSE / OUT   -> el cuerpo de la respuesta
--   X-APEX-STATUS-CODE  HEADER   / OUT   -> el código HTTP (bind status_code)
--   authorization       HEADER   / IN    -> solo en los que piden token
--
-- El cuerpo del POST NO se declara. En un handler plsql/block ORDS parsea el
-- JSON del body y lo vincula solo a los binds del mismo nombre. No existe un
-- p_source_type para el cuerpo: los válidos son HEADER, RESPONSE, URI y QUERY,
-- y pasar 'BODY' aborta el script entero con ORA-02290
-- (REST_PARAMS_SOURCE_TYPE_CK), dejando el módulo sin crear.
--------------------------------------------------------------------------------

BEGIN
  BORRAR_MODULO_ORDS('auth');

  ORDS.DEFINE_MODULE(
    p_module_name    => 'auth',
    p_base_path      => '/auth/',
    p_items_per_page => 0,
    p_status         => 'PUBLISHED',
    p_comments       => 'Autenticacion: login, logout y sesion actual'
  );

  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parámetro de DEFINE_MODULE (esta versión de ORDS solo acepta
  -- p_module_name/p_base_path/p_items_per_page/p_status/p_comments — pasarle
  -- p_origins_allowed ahí falla con PLS-00306). Va aparte, con
  -- SET_MODULE_ORIGINS_ALLOWED(p_module_name, p_origins_allowed).
  --
  -- Cargarlo solo en auth y no en usuarios.sql dejó ese otro módulo
  -- bloqueando toda petición cross-origin con un "Service Unavailable"
  -- genérico de ORDS: el handler ni llegaba a ejecutarse, así que el WHEN
  -- OTHERS con SQLERRM tampoco ayudaba a diagnosticarlo. Se declara acá para
  -- que sobreviva a una reejecución del script: antes vivía solo en la
  -- configuración manual de APEX, y un BORRAR_MODULO_ORDS + DEFINE_MODULE sin
  -- esto lo habría borrado.
  ORDS.SET_MODULE_ORIGINS_ALLOWED(
    p_module_name     => 'auth',
    p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
  );

  ------------------------------------------------------------------------------
  -- POST /auth/login
  --
  -- Body: { "usuario": "...", "password": "..." }
  -- 200 -> { token, expira, usuario: { id, usuario, nombreApellido, correo } }
  -- 401 -> credenciales incorrectas (mensaje único, sin distinguir el motivo)
  ------------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'auth', p_pattern => 'login');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'auth',
    p_pattern     => 'login',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_id_usuario NUMBER;
  l_token      VARCHAR2(64);
  l_expira     TIMESTAMP;
  l_usuario    VARCHAR2(50);
  l_nombre     VARCHAR2(200);
  l_correo     VARCHAR2(100);
  l_es_admin   VARCHAR2(1);
BEGIN
  l_id_usuario := PKG_AUTH.VERIFICAR_CREDENCIALES(:usuario, :password);

  IF l_id_usuario IS NULL THEN
    -- Un unico mensaje para "no existe", "clave incorrecta" y "cuenta
    -- inactiva". Distinguirlos permitiria enumerar cuentas validas.
    :status_code := 401;
    :resultado := '{"error":"Usuario o contrasena incorrectos"}';
    RETURN;
  END IF;

  PKG_AUTH.CREAR_TOKEN(
    p_id_usuario       => l_id_usuario,
    p_token            => l_token,
    p_fecha_expiracion => l_expira
  );

  -- Nunca se leen CONTRASENA_HASH ni SALT: no tienen por que salir de la base.
  SELECT USUARIO, NOMBRE_APELLIDO, CORREO, NVL(UPPER(TRIM(ES_ADMIN)), 'N')
    INTO l_usuario, l_nombre, l_correo, l_es_admin
    FROM USUARIOS
   WHERE ID_USUARIO = l_id_usuario;

  COMMIT;

  :status_code := 200;
  :resultado := JSON_OBJECT(
    'token'   VALUE l_token,
    -- ISO 8601 sin zona: el frontend solo lo muestra o lo compara.
    'expira'  VALUE TO_CHAR(l_expira, 'YYYY-MM-DD"T"HH24:MI:SS'),
    'usuario' VALUE JSON_OBJECT(
       'id'             VALUE l_id_usuario,
       'usuario'        VALUE l_usuario,
       'nombreApellido' VALUE l_nombre,
       'correo'         VALUE l_correo,
       -- 'S'/'N' tal como esta en la columna, sin traducir a booleano.
       'esAdmin'        VALUE l_es_admin
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    :status_code := 500;
    -- El detalle va al log del servidor, no a la respuesta. Sin esta linea un
    -- ORA-01722 por tipos se ve como "Error al iniciar sesion" y no hay forma
    -- de saber que fallo realmente.
    APEX_DEBUG.ERROR('auth/login: ' || SQLERRM || ' | ' ||
                     DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    :resultado := '{"error":"Error al iniciar sesion"}';
END;
~'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'auth', p_pattern => 'login', p_method => 'POST',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'auth', p_pattern => 'login', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ------------------------------------------------------------------------------
  -- POST /auth/logout
  --
  -- 200 siempre: revocar es idempotente. Un token ya vencido o inexistente no
  -- es un error — el cliente queria quedarse sin sesion y se queda sin sesion.
  ------------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'auth', p_pattern => 'logout');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'auth',
    p_pattern     => 'logout',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
BEGIN
  PKG_AUTH.REVOCAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(:authorization));
  COMMIT;
  :status_code := 200;
  :resultado := '{"ok":true}';
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    :status_code := 500;
    APEX_DEBUG.ERROR('auth/logout: ' || SQLERRM || ' | ' ||
                     DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    :resultado := '{"error":"Error al cerrar sesion"}';
END;
~'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'auth', p_pattern => 'logout', p_method => 'POST',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'auth', p_pattern => 'logout', p_method => 'POST',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'auth', p_pattern => 'logout', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ------------------------------------------------------------------------------
  -- GET /auth/me
  --
  -- Devuelve el usuario de la sesion. Sirve para rehidratar el estado al
  -- recargar la pagina y para comprobar que el token sigue vivo.
  -- 401 -> token ausente, invalido, vencido o de una cuenta inactivada.
  ------------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'auth', p_pattern => 'me');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'auth',
    p_pattern     => 'me',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_id_usuario NUMBER;
  l_usuario    VARCHAR2(50);
  l_nombre     VARCHAR2(200);
  l_correo     VARCHAR2(100);
  l_activo     VARCHAR2(1);
  l_es_admin   VARCHAR2(1);
BEGIN
  l_id_usuario := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(:authorization));

  IF l_id_usuario IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  SELECT USUARIO, NOMBRE_APELLIDO, CORREO,
         UPPER(TRIM(ACTIVO)), NVL(UPPER(TRIM(ES_ADMIN)), 'N')
    INTO l_usuario, l_nombre, l_correo, l_activo, l_es_admin
    FROM USUARIOS
   WHERE ID_USUARIO = l_id_usuario;

  :status_code := 200;
  :resultado := JSON_OBJECT(
    'id'             VALUE l_id_usuario,
    'usuario'        VALUE l_usuario,
    'nombreApellido' VALUE l_nombre,
    'correo'         VALUE l_correo,
    -- El codigo 'A'/'I' tal cual esta en la columna, sin traducir a 1/0.
    'activo'         VALUE l_activo,
    'esAdmin'        VALUE l_es_admin
  );
EXCEPTION
  WHEN OTHERS THEN
    :status_code := 500;
    APEX_DEBUG.ERROR('auth/me: ' || SQLERRM || ' | ' ||
                     DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    :resultado := '{"error":"Error al obtener la sesion"}';
END;
~'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'auth', p_pattern => 'me', p_method => 'GET',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'auth', p_pattern => 'me', p_method => 'GET',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'auth', p_pattern => 'me', p_method => 'GET',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 4. Verificación
--
-- Nota: en USER_OBJECTS la columna es OBJECT_NAME, no NAME. Usar NAME da
-- ORA-00904.
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME IN ('PKG_AUTH', 'BORRAR_MODULO_ORDS')
 ORDER BY OBJECT_NAME, OBJECT_TYPE;

-- Si la consulta anterior muestra algún INVALID, acá está el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME IN ('PKG_AUTH', 'BORRAR_MODULO_ORDS')
 ORDER BY NAME, SEQUENCE;

-- Rutas publicadas: deben aparecer login (POST), logout (POST) y me (GET).
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'auth'
 ORDER BY t.URI_TEMPLATE, h.METHOD;
