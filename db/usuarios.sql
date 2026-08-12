--------------------------------------------------------------------------------
-- CTELL · USUARIOS
--
-- Script único: paquetes PL/SQL + endpoints ORDS. Se ejecuta de una sola vez
-- en la hoja de trabajo SQL de APEX, conectado con el esquema del workspace.
--
-- Contenido:
--   1. PKG_USUARIOS    — ABM de usuarios, hash y verificación de credenciales
--   2. PKG_TOKENS      — sesiones: emisión, validación y revocación
--   3. ORDS /auth/     — login, logout, sesión actual  (públicos)
--   4. ORDS /usuarios/ — ABM  (requieren token)
--   5. Usuario administrador inicial
--   6. Verificación
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/
--
-- Hash: STANDARD_HASH SHA-256 sobre (SALT || password), con salt aleatorio de
-- 32 hex por usuario derivado de SYS_GUID(). Se usa STANDARD_HASH y no
-- DBMS_CRYPTO.PBKDF2 porque DBMS_CRYPTO no está concedido en este workspace.
--
-- STANDARD_HASH es una función SQL, no PL/SQL: se invoca desde un
-- SELECT ... FROM DUAL dentro de HASH_PASSWORD. Llamarla como expresión PL/SQL
-- directa falla con PLS-00201, que parece un problema de grants pero no lo es.
--
-- Limitación conocida: SHA-256 es de una sola pasada, sin factor de trabajo.
-- Si más adelante conseguís el grant
--     GRANT EXECUTE ON SYS.DBMS_CRYPTO TO WKSP_CTELL;
-- conviene migrar HASH_PASSWORD a PBKDF2 (ver nota al pie del paquete).
--
-- No se modifica ninguna tabla: se usan USUARIOS y TOKENS tal como están.
--
-- ESTADO DE LOS USUARIOS
-- USUARIOS.ACTIVO es VARCHAR2(1) y guarda un código: 'A' activo, 'I' inactivo.
-- Ese mismo código viaja en el JSON y lo consume el frontend (tipo `Estado` en
-- src/lib/api.ts). No hay traducción a 1/0 en ningún punto: la había, y cada
-- conversión de ida y vuelta era una oportunidad de ORA-01722 — un TO_NUMBER
-- sobre una columna de texto tiraba abajo el listado entero.
--
-- TOKENS.ACTIVO sí es NUMBER(1,0) con 1/0. Se llama igual pero NO es del mismo
-- tipo: es interna del manejo de sesiones y no se expone en ninguna API.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_USUARIOS
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_USUARIOS AS

  -- Códigos de error de negocio (rango reservado por Oracle para el usuario).
  C_ERR_USUARIO_DUPLICADO CONSTANT PLS_INTEGER := -20001;
  C_ERR_USUARIO_NO_EXISTE CONSTANT PLS_INTEGER := -20002;
  C_ERR_PASSWORD_DEBIL    CONSTANT PLS_INTEGER := -20003;
  C_ERR_DATOS_INVALIDOS   CONSTANT PLS_INTEGER := -20004;

  -- USUARIOS.ACTIVO es VARCHAR2(1) y guarda un CODIGO DE ESTADO, no un
  -- booleano: 'A' = activo, 'I' = inactivo. Ese mismo codigo viaja en el JSON
  -- y lo consume el frontend (tipo `Estado` en src/lib/api.ts): no se traduce
  -- a 1/0 en ningun punto.
  --
  -- Ojo: TOKENS.ACTIVO SI es NUMBER(1,0) con 1/0. Las dos columnas se
  -- llaman igual y son de tipos distintos.
  C_ESTADO_ACTIVO   CONSTANT VARCHAR2(1) := 'A';
  C_ESTADO_INACTIVO CONSTANT VARCHAR2(1) := 'I';

  FUNCTION GENERAR_SALT RETURN VARCHAR2;

  FUNCTION HASH_PASSWORD (
    p_password IN VARCHAR2,
    p_salt     IN VARCHAR2
  ) RETURN VARCHAR2;

  PROCEDURE CREAR_USUARIO (
    p_usuario         IN  VARCHAR2,
    p_nombre_apellido IN  VARCHAR2,
    p_correo          IN  VARCHAR2 DEFAULT NULL,
    p_password        IN  VARCHAR2,
    p_id_usuario      OUT NUMBER
  );

  -- Los parámetros NULL no se modifican. Para la clave usar CAMBIAR_PASSWORD.
  -- p_activo es el código de la columna: 'A' o 'I'. NULL = no cambiar.
  PROCEDURE ACTUALIZAR_USUARIO (
    p_id_usuario      IN NUMBER,
    p_nombre_apellido IN VARCHAR2 DEFAULT NULL,
    p_correo          IN VARCHAR2 DEFAULT NULL,
    p_activo          IN VARCHAR2 DEFAULT NULL
  );

  PROCEDURE CAMBIAR_PASSWORD (
    p_id_usuario IN NUMBER,
    p_password   IN VARCHAR2
  );

  -- Baja lógica: ACTIVO = 'I' y se revocan los tokens vigentes.
  PROCEDURE INACTIVAR_USUARIO (p_id_usuario IN NUMBER);

  PROCEDURE ACTIVAR_USUARIO (p_id_usuario IN NUMBER);

  -- Baja física. Preferí INACTIVAR_USUARIO salvo que quieras borrar el rastro.
  PROCEDURE ELIMINAR_USUARIO (p_id_usuario IN NUMBER);

  -- p_activo es el código de la columna: 'A' o 'I'. NULL = sin filtro.
  FUNCTION CONTAR_USUARIOS (
    p_busqueda IN VARCHAR2 DEFAULT NULL,
    p_activo   IN VARCHAR2 DEFAULT NULL
  ) RETURN NUMBER;

  -- Devuelve el ID si las credenciales son correctas, NULL si no.
  -- No distingue "no existe" de "clave incorrecta": informarlo permitiría
  -- enumerar cuentas válidas.
  FUNCTION VERIFICAR_CREDENCIALES (
    p_usuario  IN VARCHAR2,
    p_password IN VARCHAR2
  ) RETURN NUMBER;

END PKG_USUARIOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_USUARIOS AS

  --------------------------------------------------------------------------
  -- Privados
  --------------------------------------------------------------------------

  -- Compara en tiempo constante: cortar en la primera diferencia filtra
  -- información por temporización.
  FUNCTION COMPARAR_SEGURO (p_a IN VARCHAR2, p_b IN VARCHAR2) RETURN BOOLEAN IS
    l_dif PLS_INTEGER := 0;
  BEGIN
    IF p_a IS NULL OR p_b IS NULL THEN
      RETURN FALSE;
    END IF;

    IF LENGTH(p_a) != LENGTH(p_b) THEN
      RETURN FALSE;
    END IF;

    FOR i IN 1 .. LENGTH(p_a) LOOP
      l_dif := l_dif + ABS(ASCII(SUBSTR(p_a, i, 1)) - ASCII(SUBSTR(p_b, i, 1)));
    END LOOP;

    RETURN l_dif = 0;
  END COMPARAR_SEGURO;

  PROCEDURE VALIDAR_PASSWORD (p_password IN VARCHAR2) IS
  BEGIN
    IF p_password IS NULL OR LENGTH(p_password) < 8 THEN
      RAISE_APPLICATION_ERROR(C_ERR_PASSWORD_DEBIL,
        'La contrasena debe tener al menos 8 caracteres');
    END IF;

    IF LENGTH(p_password) > 128 THEN
      RAISE_APPLICATION_ERROR(C_ERR_PASSWORD_DEBIL,
        'La contrasena no puede superar los 128 caracteres');
    END IF;
  END VALIDAR_PASSWORD;

  --------------------------------------------------------------------------
  -- Públicos
  --------------------------------------------------------------------------

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

    -- El salt va adelante para que dos usuarios con la misma clave produzcan
    -- hashes distintos. Salida: 64 hex, dentro de los 256 de la columna.
    --
    -- STANDARD_HASH es una funcion SQL, no PL/SQL: invocarla como expresion
    -- directa da PLS-00201 ("el identificador se debe declarar"). Por eso va
    -- dentro de un SELECT ... FROM DUAL. No es un problema de privilegios.
    --
    -- Con el grant de DBMS_CRYPTO, reemplazar el SELECT por:
    --   RETURN RAWTOHEX(DBMS_CRYPTO.PBKDF2(
    --     UTL_I18N.STRING_TO_RAW(p_password,'AL32UTF8'),
    --     HEXTORAW(p_salt), 100000, DBMS_CRYPTO.HMAC_SH512, 64));
    SELECT STANDARD_HASH(p_salt || p_password, 'SHA256')
      INTO l_hash
      FROM DUAL;

    RETURN l_hash;
  END HASH_PASSWORD;

  PROCEDURE CREAR_USUARIO (
    p_usuario         IN  VARCHAR2,
    p_nombre_apellido IN  VARCHAR2,
    p_correo          IN  VARCHAR2 DEFAULT NULL,
    p_password        IN  VARCHAR2,
    p_id_usuario      OUT NUMBER
  ) IS
    l_salt    VARCHAR2(32);
    l_hash    VARCHAR2(256);
    l_usuario VARCHAR2(50);
  BEGIN
    l_usuario := LOWER(TRIM(p_usuario));

    IF l_usuario IS NULL OR LENGTH(l_usuario) < 3 THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS,
        'El usuario debe tener al menos 3 caracteres');
    END IF;

    IF TRIM(p_nombre_apellido) IS NULL THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS,
        'El nombre y apellido es obligatorio');
    END IF;

    IF p_correo IS NOT NULL
       AND NOT REGEXP_LIKE(p_correo, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS, 'El correo no es valido');
    END IF;

    VALIDAR_PASSWORD(p_password);

    l_salt := GENERAR_SALT();
    l_hash := HASH_PASSWORD(p_password, l_salt);

    INSERT INTO USUARIOS (
      USUARIO, NOMBRE_APELLIDO, CORREO, CONTRASENA_HASH, SALT,
      ACTIVO, FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_usuario, TRIM(p_nombre_apellido), LOWER(TRIM(p_correo)), l_hash, l_salt,
      C_ESTADO_ACTIVO, SYSTIMESTAMP, SYSTIMESTAMP
    )
    RETURNING ID_USUARIO INTO p_id_usuario;

  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      RAISE_APPLICATION_ERROR(C_ERR_USUARIO_DUPLICADO,
        'Ya existe un usuario con ese nombre');
  END CREAR_USUARIO;

  PROCEDURE ACTUALIZAR_USUARIO (
    p_id_usuario      IN NUMBER,
    p_nombre_apellido IN VARCHAR2 DEFAULT NULL,
    p_correo          IN VARCHAR2 DEFAULT NULL,
    p_activo          IN VARCHAR2 DEFAULT NULL
  ) IS
    -- Solo 'A' o 'I' son estados validos. Cualquier otra cosa se descarta
    -- como NULL, y el NVL de abajo conserva el estado actual: es preferible
    -- ignorar un valor invalido a escribirlo en la columna.
    l_estado VARCHAR2(1) := CASE UPPER(TRIM(p_activo))
                              WHEN 'A' THEN 'A'
                              WHEN 'I' THEN 'I'
                              ELSE NULL
                            END;
  BEGIN
    IF p_correo IS NOT NULL
       AND NOT REGEXP_LIKE(p_correo, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS, 'El correo no es valido');
    END IF;

    UPDATE USUARIOS
       SET NOMBRE_APELLIDO     = NVL(TRIM(p_nombre_apellido), NOMBRE_APELLIDO),
           CORREO              = NVL(LOWER(TRIM(p_correo)), CORREO),
           -- NULL = no cambiar: un parametro ausente no pisa el estado.
           ACTIVO              = NVL(l_estado, ACTIVO),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_USUARIO = p_id_usuario;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(C_ERR_USUARIO_NO_EXISTE, 'El usuario no existe');
    END IF;

    -- Si se inactivó por esta vía, hay que cortar las sesiones abiertas.
    IF p_activo = 0 THEN
      UPDATE TOKENS
         SET ACTIVO = 0
       WHERE ID_USUARIO = p_id_usuario
         AND ACTIVO = 1;
    END IF;
  END ACTUALIZAR_USUARIO;

  PROCEDURE CAMBIAR_PASSWORD (
    p_id_usuario IN NUMBER,
    p_password   IN VARCHAR2
  ) IS
    l_salt VARCHAR2(32);
    l_hash VARCHAR2(256);
  BEGIN
    VALIDAR_PASSWORD(p_password);

    -- Salt nuevo en cada cambio: reutilizarlo permitiría comparar el hash
    -- viejo con el nuevo y detectar si la contraseña cambió realmente.
    l_salt := GENERAR_SALT();
    l_hash := HASH_PASSWORD(p_password, l_salt);

    UPDATE USUARIOS
       SET CONTRASENA_HASH     = l_hash,
           SALT                = l_salt,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_USUARIO = p_id_usuario;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(C_ERR_USUARIO_NO_EXISTE, 'El usuario no existe');
    END IF;

    -- Cambiar la clave invalida las sesiones abiertas en otros dispositivos.
    UPDATE TOKENS
       SET ACTIVO = 0
     WHERE ID_USUARIO = p_id_usuario
       AND ACTIVO = 1;
  END CAMBIAR_PASSWORD;

  PROCEDURE INACTIVAR_USUARIO (p_id_usuario IN NUMBER) IS
  BEGIN
    UPDATE USUARIOS
       SET ACTIVO              = C_ESTADO_INACTIVO,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_USUARIO = p_id_usuario;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(C_ERR_USUARIO_NO_EXISTE, 'El usuario no existe');
    END IF;

    -- Sin esto el usuario inactivo seguiría navegando con su token vigente.
    UPDATE TOKENS
       SET ACTIVO = 0
     WHERE ID_USUARIO = p_id_usuario
       AND ACTIVO = 1;
  END INACTIVAR_USUARIO;

  PROCEDURE ACTIVAR_USUARIO (p_id_usuario IN NUMBER) IS
  BEGIN
    UPDATE USUARIOS
       SET ACTIVO              = C_ESTADO_ACTIVO,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_USUARIO = p_id_usuario;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(C_ERR_USUARIO_NO_EXISTE, 'El usuario no existe');
    END IF;
  END ACTIVAR_USUARIO;

  PROCEDURE ELIMINAR_USUARIO (p_id_usuario IN NUMBER) IS
  BEGIN
    -- La FK de TOKENS bloquearía el DELETE; se limpian primero.
    DELETE FROM TOKENS WHERE ID_USUARIO = p_id_usuario;

    DELETE FROM USUARIOS WHERE ID_USUARIO = p_id_usuario;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(C_ERR_USUARIO_NO_EXISTE, 'El usuario no existe');
    END IF;
  END ELIMINAR_USUARIO;

  FUNCTION CONTAR_USUARIOS (
    p_busqueda IN VARCHAR2 DEFAULT NULL,
    p_activo   IN VARCHAR2 DEFAULT NULL
  ) RETURN NUMBER IS
    l_total  NUMBER;
    l_busca  VARCHAR2(200) := '%' || LOWER(TRIM(p_busqueda)) || '%';
    -- Ya es 'A'/'I': se normaliza y se compara como texto, sin conversiones.
    l_estado VARCHAR2(1) := UPPER(TRIM(p_activo));
  BEGIN
    SELECT COUNT(*)
      INTO l_total
      FROM USUARIOS
     WHERE (p_busqueda IS NULL
            OR LOWER(USUARIO) LIKE l_busca
            OR LOWER(NOMBRE_APELLIDO) LIKE l_busca
            OR LOWER(CORREO) LIKE l_busca)
       AND (l_estado IS NULL OR UPPER(TRIM(ACTIVO)) = l_estado);

    RETURN l_total;
  END CONTAR_USUARIOS;

  FUNCTION VERIFICAR_CREDENCIALES (
    p_usuario  IN VARCHAR2,
    p_password IN VARCHAR2
  ) RETURN NUMBER IS
    l_id         NUMBER;
    l_hash_guard VARCHAR2(256);
    l_salt       VARCHAR2(32);
  BEGIN
    -- ACTIVO guarda 'A'/'I', no 1/0. Con `ACTIVO = 1` Oracle intentaba
    -- convertir la columna a numero y moria con ORA-01722 en cada login.
    -- Ese error subia hasta el WHEN OTHERS del handler y se veia como un 500
    -- "Error al iniciar sesion", sin pista de que era un problema de tipos.
    SELECT ID_USUARIO, CONTRASENA_HASH, SALT
      INTO l_id, l_hash_guard, l_salt
      FROM USUARIOS
     WHERE USUARIO = LOWER(TRIM(p_usuario))
       AND UPPER(TRIM(ACTIVO)) = C_ESTADO_ACTIVO;

    IF COMPARAR_SEGURO(HASH_PASSWORD(p_password, l_salt), l_hash_guard) THEN
      RETURN l_id;
    END IF;

    RETURN NULL;

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END VERIFICAR_CREDENCIALES;

END PKG_USUARIOS;
/

--------------------------------------------------------------------------------
-- 2. PKG_TOKENS
--
-- El token es un valor aleatorio de 64 hex (dos SYS_GUID concatenados y
-- recortados al largo de la columna TOKEN). Al validarse siempre contra la
-- base, una sesión se puede revocar al instante.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_TOKENS AS

  C_HORAS_VIGENCIA CONSTANT NUMBER := 8;

  PROCEDURE CREAR_TOKEN (
    p_id_usuario       IN  NUMBER,
    p_horas            IN  NUMBER DEFAULT C_HORAS_VIGENCIA,
    p_token            OUT VARCHAR2,
    p_fecha_expiracion OUT TIMESTAMP
  );

  -- Devuelve el ID del usuario si el token está activo y vigente; NULL si no.
  FUNCTION VALIDAR_TOKEN (p_token IN VARCHAR2) RETURN NUMBER;

  PROCEDURE REVOCAR_TOKEN (p_token IN VARCHAR2);

  PROCEDURE REVOCAR_TOKENS_USUARIO (p_id_usuario IN NUMBER);

  PROCEDURE LIMPIAR_TOKENS_VENCIDOS (p_afectados OUT NUMBER);

END PKG_TOKENS;
/

CREATE OR REPLACE PACKAGE BODY PKG_TOKENS AS

  PROCEDURE CREAR_TOKEN (
    p_id_usuario       IN  NUMBER,
    p_horas            IN  NUMBER DEFAULT C_HORAS_VIGENCIA,
    p_token            OUT VARCHAR2,
    p_fecha_expiracion OUT TIMESTAMP
  ) IS
    -- VARCHAR2 y no NUMBER: USUARIOS.ACTIVO guarda el codigo 'A'/'I'.
    -- Leerlo en una variable numerica provoca ORA-01722.
    l_activo VARCHAR2(1);
  BEGIN
    -- No se emiten sesiones para cuentas inactivas o inexistentes.
    BEGIN
      SELECT UPPER(TRIM(ACTIVO)) INTO l_activo
        FROM USUARIOS
       WHERE ID_USUARIO = p_id_usuario;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(PKG_USUARIOS.C_ERR_USUARIO_NO_EXISTE,
          'El usuario no existe');
    END;

    IF l_activo IS NULL OR l_activo != PKG_USUARIOS.C_ESTADO_ACTIVO THEN
      RAISE_APPLICATION_ERROR(PKG_USUARIOS.C_ERR_USUARIO_NO_EXISTE,
        'El usuario esta inactivo');
    END IF;

    -- Dos SYS_GUID dan 64 hex, el largo exacto de la columna TOKEN.
    p_token := RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID());
    p_fecha_expiracion := SYSTIMESTAMP
      + NUMTODSINTERVAL(NVL(p_horas, C_HORAS_VIGENCIA), 'HOUR');

    INSERT INTO TOKENS (
      ID_USUARIO, TOKEN, FECHA_CREACION, FECHA_EXPIRACION, ACTIVO
    ) VALUES (
      p_id_usuario, p_token, SYSTIMESTAMP, p_fecha_expiracion, 1
    );
  END CREAR_TOKEN;

  FUNCTION VALIDAR_TOKEN (p_token IN VARCHAR2) RETURN NUMBER IS
    l_id_usuario NUMBER;
  BEGIN
    IF p_token IS NULL OR LENGTH(p_token) != 64 THEN
      RETURN NULL;
    END IF;

    -- Se verifica también que el usuario siga activo: inactivarlo debe cortar
    -- el acceso aunque el token todavía no haya vencido.
    -- Ojo con los tipos: TOKENS.ACTIVO es NUMBER(1,0) (1/0) y USUARIOS.ACTIVO
    -- es VARCHAR2(1) con el codigo 'A'/'I'. Se comparan distinto a proposito;
    -- unificarlos a numero rompe el login con ORA-01722.
    SELECT t.ID_USUARIO
      INTO l_id_usuario
      FROM TOKENS t
      JOIN USUARIOS u ON u.ID_USUARIO = t.ID_USUARIO
     WHERE t.TOKEN = p_token
       AND t.ACTIVO = 1
       AND UPPER(TRIM(u.ACTIVO)) = PKG_USUARIOS.C_ESTADO_ACTIVO
       AND t.FECHA_EXPIRACION > SYSTIMESTAMP;

    RETURN l_id_usuario;

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END VALIDAR_TOKEN;

  PROCEDURE REVOCAR_TOKEN (p_token IN VARCHAR2) IS
  BEGIN
    UPDATE TOKENS
       SET ACTIVO = 0
     WHERE TOKEN = p_token
       AND ACTIVO = 1;
    -- Sin error si no existe: cerrar sesión debe ser idempotente.
  END REVOCAR_TOKEN;

  PROCEDURE REVOCAR_TOKENS_USUARIO (p_id_usuario IN NUMBER) IS
  BEGIN
    UPDATE TOKENS
       SET ACTIVO = 0
     WHERE ID_USUARIO = p_id_usuario
       AND ACTIVO = 1;
  END REVOCAR_TOKENS_USUARIO;

  PROCEDURE LIMPIAR_TOKENS_VENCIDOS (p_afectados OUT NUMBER) IS
  BEGIN
    UPDATE TOKENS
       SET ACTIVO = 0
     WHERE ACTIVO = 1
       AND FECHA_EXPIRACION <= SYSTIMESTAMP;

    p_afectados := SQL%ROWCOUNT;
    COMMIT;
  END LIMPIAR_TOKENS_VENCIDOS;

END PKG_TOKENS;
/

--------------------------------------------------------------------------------
-- 3. ORDS · MÓDULO /auth/   (endpoints públicos)
--
--   POST /auth/login    { usuario, password }        -> token + datos
--   POST /auth/logout   Authorization: Bearer <tok>  -> cierra la sesión
--   GET  /auth/me       Authorization: Bearer <tok>  -> usuario actual
--
-- No se llama a ORDS.ENABLE_SCHEMA: en APEX el esquema del workspace ya está
-- habilitado y esa llamada falla con ORA-01031 (privilegios insuficientes).
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Borra un módulo ORDS si existe, reintentando ante un interbloqueo.
--
-- Antes esto era un `WHEN OTHERS THEN NULL` inline, pensado para tragarse el
-- caso "el módulo no existía todavía". El problema es que se tragaba TODO,
-- incluido un ORA-00060: el DELETE fallaba en silencio, la ejecución seguía, y
-- el DEFINE_MODULE de abajo moría con ORA-00001 (nombre duplicado) contra el
-- módulo que nunca se llegó a borrar.
--
-- El interbloqueo aparece cuando otra sesión tiene tomadas las filas de
-- metadatos de ORDS: típicamente el propio ORDS sirviendo peticiones de la app
-- mientras se reejecuta este script. Es transitorio, así que se reintenta; lo
-- que no se puede hacer es ignorarlo.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE BORRAR_MODULO_ORDS (p_modulo IN VARCHAR2) AS
  C_INTENTOS CONSTANT PLS_INTEGER := 3;
  l_existe   PLS_INTEGER;
BEGIN
  FOR i IN 1 .. C_INTENTOS LOOP
    BEGIN
      -- Se consulta antes de borrar en vez de capturar el error de "no
      -- existe": así el EXCEPTION queda libre para los fallos que sí importan.
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
          -- Cualquier otro error, o se acabaron los reintentos: que se vea.
          -- Seguir de largo dejaría el módulo viejo publicado y el script
          -- terminaría "bien" sin haber aplicado ningún cambio.
          RAISE;
        END IF;
    END;
  END LOOP;
END BORRAR_MODULO_ORDS;
/

BEGIN
  BORRAR_MODULO_ORDS('auth');

  ORDS.DEFINE_MODULE(
    p_module_name    => 'auth',
    p_base_path      => '/auth/',
    p_items_per_page => 25,
    p_status         => 'PUBLISHED',
    p_comments       => 'Autenticacion: login, logout y sesion actual'
  );

  ----------------------------------------------------------------------------
  -- POST /auth/login
  ----------------------------------------------------------------------------
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
BEGIN
  l_id_usuario := PKG_USUARIOS.VERIFICAR_CREDENCIALES(:usuario, :password);

  IF l_id_usuario IS NULL THEN
    -- Mensaje generico a proposito: distinguir "no existe" de "clave
    -- incorrecta" permitiria enumerar cuentas validas.
    :status_code := 401;
    :resultado := '{"error":"Usuario o contrasena incorrectos"}';
    RETURN;
  END IF;

  PKG_TOKENS.CREAR_TOKEN(
    p_id_usuario       => l_id_usuario,
    p_token            => l_token,
    p_fecha_expiracion => l_expira
  );

  SELECT USUARIO, NOMBRE_APELLIDO, CORREO
    INTO l_usuario, l_nombre, l_correo
    FROM USUARIOS
   WHERE ID_USUARIO = l_id_usuario;

  COMMIT;

  :status_code := 200;
  :resultado := JSON_OBJECT(
    'token'   VALUE l_token,
    'expira'  VALUE TO_CHAR(l_expira, 'YYYY-MM-DD"T"HH24:MI:SS'),
    'usuario' VALUE JSON_OBJECT(
       'id'             VALUE l_id_usuario,
       'usuario'        VALUE l_usuario,
       'nombreApellido' VALUE l_nombre,
       'correo'         VALUE l_correo
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    :status_code := 500;
    -- El detalle del error va al log del servidor, no a la respuesta: al
    -- cliente se le sigue dando un mensaje generico. Sin esta linea un
    -- ORA-01722 por tipos se veia como "Error al iniciar sesion" y no habia
    -- forma de saber que habia fallado realmente.
    APEX_DEBUG.ERROR('auth/login: ' || SQLERRM || ' | ' ||
                     DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    :resultado := '{"error":"Error al iniciar sesion"}';
END;
~'
  );

  -- :usuario y :password NO se declaran con DEFINE_PARAMETER. En un handler
  -- plsql/block ORDS toma el JSON del body y lo vincula solo a los binds del
  -- mismo nombre. No hay un p_source_type para el cuerpo: los validos son
  -- HEADER, RESPONSE, URI y QUERY, y pasar 'BODY' aborta el script entero con
  -- ORA-02290 (REST_PARAMS_SOURCE_TYPE_CK), dejando el modulo sin crear.
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'auth', p_pattern => 'login', p_method => 'POST',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'auth', p_pattern => 'login', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- POST /auth/logout
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'auth', p_pattern => 'logout');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'auth',
    p_pattern     => 'logout',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
BEGIN
  PKG_TOKENS.REVOCAR_TOKEN(REPLACE(:authorization, 'Bearer ', ''));
  COMMIT;
  :status_code := 200;
  :resultado := '{"ok":true}';
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    :status_code := 500;
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

  ----------------------------------------------------------------------------
  -- GET /auth/me
  ----------------------------------------------------------------------------
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
BEGIN
  l_id_usuario := PKG_TOKENS.VALIDAR_TOKEN(REPLACE(:authorization, 'Bearer ', ''));

  IF l_id_usuario IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  SELECT USUARIO, NOMBRE_APELLIDO, CORREO
    INTO l_usuario, l_nombre, l_correo
    FROM USUARIOS
   WHERE ID_USUARIO = l_id_usuario;

  :status_code := 200;
  :resultado := JSON_OBJECT(
    'id'             VALUE l_id_usuario,
    'usuario'        VALUE l_usuario,
    'nombreApellido' VALUE l_nombre,
    'correo'         VALUE l_correo
  );
EXCEPTION
  WHEN OTHERS THEN
    :status_code := 500;
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
-- 4. ORDS · MÓDULO /usuarios/   (requieren token de sesión)
--
--   GET    /usuarios/              ?busqueda=&activo=&pagina=&tamanio=
--   POST   /usuarios/              { usuario, nombreApellido, correo, password }
--   GET    /usuarios/:id
--   PUT    /usuarios/:id           { nombreApellido, correo, activo }
--   DELETE /usuarios/:id           baja física
--   POST   /usuarios/:id/inactivar
--   POST   /usuarios/:id/activar
--   POST   /usuarios/:id/password  { password }
--
-- Cada handler valida el header Authorization contra PKG_TOKENS.VALIDAR_TOKEN.
-- Sin esa comprobación el ABM quedaría abierto a internet.
--------------------------------------------------------------------------------

BEGIN
  BORRAR_MODULO_ORDS('usuarios');

  ORDS.DEFINE_MODULE(
    p_module_name    => 'usuarios',
    p_base_path      => '/usuarios/',
    p_items_per_page => 25,
    p_status         => 'PUBLISHED',
    p_comments       => 'ABM de usuarios (requiere token)'
  );

  ----------------------------------------------------------------------------
  -- GET /usuarios/  · listado paginado
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'usuarios', p_pattern => '.');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => '.',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion   NUMBER;
  l_items    CLOB;
  l_total    NUMBER;
  l_tamanio  NUMBER;
  l_pagina   NUMBER;
  l_estado   VARCHAR2(1);
  l_busqueda VARCHAR2(200);
  l_busca    VARCHAR2(200);
BEGIN
  l_sesion := PKG_TOKENS.VALIDAR_TOKEN(REPLACE(:authorization, 'Bearer ', ''));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  -- Los TO_NUMBER van DENTRO del BEGIN, no en el DECLARE.
  --
  -- El DECLARE se ejecuta antes que el bloque EXCEPTION exista, asi que una
  -- excepcion ahi no la captura el WHEN OTHERS: escapa del handler y ORDS
  -- responde 500 sin dejar rastro de por que.
  --
  -- Y pasaba: un parametro que el cliente no manda no llega NULL sino como
  -- cadena vacia, y TO_NUMBER('') es ORA-01722. El listado de usuarios pide
  -- ?tamanio=100 sin pagina, y ese solo caso tiraba abajo el endpoint entero.
  -- Por eso NULLIF(..., '') antes de convertir: cadena vacia -> NULL -> NVL
  -- aplica el valor por defecto.
  l_tamanio := LEAST(GREATEST(NVL(TO_NUMBER(NULLIF(:tamanio, '')), 20), 1), 100);
  l_pagina  := GREATEST(NVL(TO_NUMBER(NULLIF(:pagina, '')), 1), 1);

  -- El estado es texto en todo el sistema: 'A' o 'I', igual que la columna.
  -- Nada de TO_NUMBER acá — es lo que hacía morir el endpoint con ORA-01722.
  -- Cualquier valor que no sea A o I se trata como "sin filtro".
  l_estado := CASE UPPER(TRIM(NULLIF(:activo, '')))
                WHEN 'A' THEN 'A'
                WHEN 'I' THEN 'I'
                ELSE NULL
              END;

  -- Misma normalizacion para la busqueda: sin esto, un ?busqueda= vacio
  -- filtraba por '%%' en vez de no filtrar, y el IS NULL de abajo nunca daba
  -- verdadero.
  l_busqueda := NULLIF(TRIM(:busqueda), '');
  l_busca    := '%' || LOWER(l_busqueda) || '%';

  -- Nunca se exponen CONTRASENA_HASH ni SALT.
  SELECT JSON_ARRAYAGG(
           JSON_OBJECT(
             'id'             VALUE ID_USUARIO,
             'usuario'        VALUE USUARIO,
             'nombreApellido' VALUE NOMBRE_APELLIDO,
             'correo'         VALUE CORREO,
             -- El estado sale tal cual esta en la columna: 'A' o 'I'. No se
             -- traduce a 1/0. Esa traduccion obligaba a retraducir en cada
             -- filtro de entrada y era el origen de los ORA-01722.
             'activo'         VALUE UPPER(TRIM(ACTIVO)),
             'fechaCreacion'  VALUE TO_CHAR(FECHA_CREACION, 'YYYY-MM-DD"T"HH24:MI:SS')
             RETURNING CLOB
           ) RETURNING CLOB
         )
    INTO l_items
    FROM (
      SELECT ID_USUARIO, USUARIO, NOMBRE_APELLIDO, CORREO,
             ACTIVO, FECHA_CREACION
        FROM USUARIOS
       WHERE (l_busqueda IS NULL
              OR LOWER(USUARIO) LIKE l_busca
              OR LOWER(NOMBRE_APELLIDO) LIKE l_busca
              OR LOWER(CORREO) LIKE l_busca)
         -- l_estado ya viene como 'A'/'I', el mismo codigo que guarda la
         -- columna: la comparacion es texto contra texto, sin conversiones.
         AND (l_estado IS NULL OR UPPER(TRIM(ACTIVO)) = l_estado)
       ORDER BY NOMBRE_APELLIDO
      OFFSET (l_pagina - 1) * l_tamanio ROWS FETCH NEXT l_tamanio ROWS ONLY
    );

  l_total := PKG_USUARIOS.CONTAR_USUARIOS(l_busqueda, l_estado);

  :status_code := 200;
  :resultado := JSON_OBJECT(
    'items'   VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON,
    'total'   VALUE l_total,
    'pagina'  VALUE l_pagina,
    'tamanio' VALUE l_tamanio
    RETURNING CLOB
  );
EXCEPTION
  WHEN OTHERS THEN
    :status_code := 500;
    :resultado := '{"error":"Error al listar usuarios"}';
END;
~'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => '.', p_method => 'GET',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => '.', p_method => 'GET',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => '.', p_method => 'GET',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- POST /usuarios/  · alta
  ----------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => '.',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion NUMBER;
  l_id     NUMBER;
BEGIN
  l_sesion := PKG_TOKENS.VALIDAR_TOKEN(REPLACE(:authorization, 'Bearer ', ''));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  PKG_USUARIOS.CREAR_USUARIO(
    p_usuario         => :usuario,
    p_nombre_apellido => :nombreApellido,
    p_correo          => :correo,
    p_password        => :password,
    p_id_usuario      => l_id
  );
  COMMIT;

  :status_code := 201;
  :resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true');
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    -- Los errores -20001..-20004 son de negocio: se devuelve 400 con el
    -- mensaje real. Cualquier otro es un fallo interno y se oculta.
    IF SQLCODE BETWEEN -20004 AND -20001 THEN
      :status_code := 400;
      :resultado := JSON_OBJECT('error' VALUE SUBSTR(SQLERRM, 12));
    ELSE
      :status_code := 500;
      :resultado := '{"error":"Error al crear el usuario"}';
    END IF;
END;
~'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => '.', p_method => 'POST',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => '.', p_method => 'POST',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => '.', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- GET /usuarios/:id
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'usuarios', p_pattern => ':id');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => ':id',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion NUMBER;
  l_json   CLOB;
BEGIN
  l_sesion := PKG_TOKENS.VALIDAR_TOKEN(REPLACE(:authorization, 'Bearer ', ''));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  SELECT JSON_OBJECT(
           'id'                 VALUE ID_USUARIO,
           'usuario'            VALUE USUARIO,
           'nombreApellido'     VALUE NOMBRE_APELLIDO,
           'correo'             VALUE CORREO,
           -- 'A'/'I' -> 1/0: el frontend tipa `activo` como number. CASE
           -- inline: en SQL no se invoca una funcion de PKG_USUARIOS.
           -- 'A'/'I' tal cual la columna, sin traducir a numeros.
           'activo'             VALUE UPPER(TRIM(ACTIVO)),
           'fechaCreacion'      VALUE TO_CHAR(FECHA_CREACION, 'YYYY-MM-DD"T"HH24:MI:SS'),
           'fechaActualizacion' VALUE TO_CHAR(FECHA_ACTUALIZACION, 'YYYY-MM-DD"T"HH24:MI:SS')
           RETURNING CLOB
         )
    INTO l_json
    FROM USUARIOS
   WHERE ID_USUARIO = TO_NUMBER(:id);

  :status_code := 200;
  :resultado := l_json;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    :status_code := 404;
    :resultado := '{"error":"El usuario no existe"}';
  WHEN OTHERS THEN
    :status_code := 500;
    :resultado := '{"error":"Error al obtener el usuario"}';
END;
~'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id', p_method => 'GET',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id', p_method => 'GET',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id', p_method => 'GET',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- PUT /usuarios/:id  · modificación
  ----------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => ':id',
    p_method      => 'PUT',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion NUMBER;
BEGIN
  l_sesion := PKG_TOKENS.VALIDAR_TOKEN(REPLACE(:authorization, 'Bearer ', ''));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  -- p_activo es 'A'/'I'; NULL significa "no cambiar", asi que un PUT que solo
  -- toca el nombre simplemente no lo manda. El paquete descarta cualquier
  -- valor que no sea A o I.
  PKG_USUARIOS.ACTUALIZAR_USUARIO(
    p_id_usuario      => TO_NUMBER(:id),
    p_nombre_apellido => :nombreApellido,
    p_correo          => :correo,
    p_activo          => NULLIF(:activo, '')
  );
  COMMIT;

  :status_code := 200;
  :resultado := '{"ok":true}';
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    IF SQLCODE = -20002 THEN
      :status_code := 404;
      :resultado := '{"error":"El usuario no existe"}';
    ELSIF SQLCODE BETWEEN -20004 AND -20001 THEN
      :status_code := 400;
      :resultado := JSON_OBJECT('error' VALUE SUBSTR(SQLERRM, 12));
    ELSE
      :status_code := 500;
      :resultado := '{"error":"Error al actualizar el usuario"}';
    END IF;
END;
~'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id', p_method => 'PUT',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id', p_method => 'PUT',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id', p_method => 'PUT',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- DELETE /usuarios/:id  · baja física
  ----------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => ':id',
    p_method      => 'DELETE',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion NUMBER;
BEGIN
  l_sesion := PKG_TOKENS.VALIDAR_TOKEN(REPLACE(:authorization, 'Bearer ', ''));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  -- Un usuario no puede borrarse a si mismo: dejaria la sesion activa
  -- apuntando a una cuenta inexistente.
  IF l_sesion = TO_NUMBER(:id) THEN
    :status_code := 400;
    :resultado := '{"error":"No podes eliminar tu propio usuario"}';
    RETURN;
  END IF;

  PKG_USUARIOS.ELIMINAR_USUARIO(TO_NUMBER(:id));
  COMMIT;

  :status_code := 200;
  :resultado := '{"ok":true}';
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    IF SQLCODE = -20002 THEN
      :status_code := 404;
      :resultado := '{"error":"El usuario no existe"}';
    ELSE
      :status_code := 500;
      :resultado := '{"error":"Error al eliminar el usuario"}';
    END IF;
END;
~'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id', p_method => 'DELETE',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id', p_method => 'DELETE',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id', p_method => 'DELETE',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- POST /usuarios/:id/inactivar
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'usuarios', p_pattern => ':id/inactivar');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => ':id/inactivar',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion NUMBER;
BEGIN
  l_sesion := PKG_TOKENS.VALIDAR_TOKEN(REPLACE(:authorization, 'Bearer ', ''));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  IF l_sesion = TO_NUMBER(:id) THEN
    :status_code := 400;
    :resultado := '{"error":"No podes inactivar tu propio usuario"}';
    RETURN;
  END IF;

  PKG_USUARIOS.INACTIVAR_USUARIO(TO_NUMBER(:id));
  COMMIT;

  :status_code := 200;
  :resultado := '{"ok":true}';
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    IF SQLCODE = -20002 THEN
      :status_code := 404;
      :resultado := '{"error":"El usuario no existe"}';
    ELSE
      :status_code := 500;
      :resultado := '{"error":"Error al inactivar el usuario"}';
    END IF;
END;
~'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id/inactivar', p_method => 'POST',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id/inactivar', p_method => 'POST',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id/inactivar', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- POST /usuarios/:id/activar
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'usuarios', p_pattern => ':id/activar');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => ':id/activar',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion NUMBER;
BEGIN
  l_sesion := PKG_TOKENS.VALIDAR_TOKEN(REPLACE(:authorization, 'Bearer ', ''));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  PKG_USUARIOS.ACTIVAR_USUARIO(TO_NUMBER(:id));
  COMMIT;

  :status_code := 200;
  :resultado := '{"ok":true}';
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    IF SQLCODE = -20002 THEN
      :status_code := 404;
      :resultado := '{"error":"El usuario no existe"}';
    ELSE
      :status_code := 500;
      :resultado := '{"error":"Error al activar el usuario"}';
    END IF;
END;
~'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id/activar', p_method => 'POST',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id/activar', p_method => 'POST',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id/activar', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  ----------------------------------------------------------------------------
  -- POST /usuarios/:id/password  · cambio de contraseña
  ----------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'usuarios', p_pattern => ':id/password');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => ':id/password',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion NUMBER;
BEGIN
  l_sesion := PKG_TOKENS.VALIDAR_TOKEN(REPLACE(:authorization, 'Bearer ', ''));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  PKG_USUARIOS.CAMBIAR_PASSWORD(TO_NUMBER(:id), :password);
  COMMIT;

  -- Se revocaron todas las sesiones del usuario, incluida la propia si se
  -- cambio la clave a si mismo: hay que volver a iniciar sesion.
  :status_code := 200;
  :resultado := '{"ok":true}';
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    IF SQLCODE = -20002 THEN
      :status_code := 404;
      :resultado := '{"error":"El usuario no existe"}';
    ELSIF SQLCODE BETWEEN -20004 AND -20001 THEN
      :status_code := 400;
      :resultado := JSON_OBJECT('error' VALUE SUBSTR(SQLERRM, 12));
    ELSE
      :status_code := 500;
      :resultado := '{"error":"Error al cambiar la contrasena"}';
    END IF;
END;
~'
  );

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id/password', p_method => 'POST',
    p_name => 'authorization', p_bind_variable_name => 'authorization',
    p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id/password', p_method => 'POST',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.DEFINE_PARAMETER(
    p_module_name => 'usuarios', p_pattern => ':id/password', p_method => 'POST',
    p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
    p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 4b. NORMALIZACIÓN DE USUARIOS.ACTIVO
--
-- USUARIOS.ACTIVO es VARCHAR2(1) y guarda un CÓDIGO DE ESTADO: 'A' activo,
-- 'I' inactivo. Pero el DDL de la tabla declara `DEFAULT 1`, un número: toda
-- fila insertada sin especificar la columna quedó con el texto '1', que no es
-- un estado válido. Esas cuentas no pueden loguearse, porque el WHERE busca
-- 'A' y encuentra '1'.
--
-- Este bloque las lleva a 'A'/'I'. Es idempotente: al reejecutarlo no toca
-- nada si ya está todo normalizado.
--
-- Criterio: '1', 'S', 'Y' y NULL se consideran activos; '0', 'N' e 'I',
-- inactivos. Ante cualquier otro valor se elige 'I', el estado más
-- restrictivo — es preferible dejar afuera a alguien que debía entrar, y
-- corregirlo a mano, que habilitar una cuenta que debía estar cerrada.
--------------------------------------------------------------------------------

DECLARE
  l_raros NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_raros
    FROM USUARIOS
   WHERE ACTIVO IS NULL
      OR UPPER(TRIM(ACTIVO)) NOT IN ('A', 'I');

  IF l_raros > 0 THEN
    -- Antes de tocar nada, queda registro de lo que había.
    DBMS_OUTPUT.PUT_LINE('Valores no validos en USUARIOS.ACTIVO: ' || l_raros);

    UPDATE USUARIOS
       SET ACTIVO = CASE
                      WHEN ACTIVO IS NULL                            THEN 'A'
                      WHEN UPPER(TRIM(ACTIVO)) IN ('1', 'S', 'Y')    THEN 'A'
                      ELSE 'I'
                    END
     WHERE ACTIVO IS NULL
        OR UPPER(TRIM(ACTIVO)) NOT IN ('A', 'I');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Normalizadas ' || l_raros || ' filas a ''A''/''I''.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('USUARIOS.ACTIVO ya usa ''A''/''I'': nada que normalizar.');
  END IF;
END;
/

-- Estado de la columna después de normalizar. Solo deberían verse A e I.
SELECT ACTIVO, COUNT(*) AS CANTIDAD
  FROM USUARIOS
 GROUP BY ACTIVO
 ORDER BY ACTIVO;

--------------------------------------------------------------------------------
-- 5. USUARIO ADMINISTRADOR INICIAL
--
-- Sólo se crea si la tabla está vacía, así el script se puede reejecutar.
--
-- >>> CAMBIA ESTA CONTRASENA APENAS INICIES SESION POR PRIMERA VEZ <<<
--------------------------------------------------------------------------------

DECLARE
  l_existe NUMBER;
  l_id     NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_existe FROM USUARIOS;

  IF l_existe = 0 THEN
    PKG_USUARIOS.CREAR_USUARIO(
      p_usuario         => 'admin',
      p_nombre_apellido => 'Administrador CTELL',
      p_correo          => NULL,
      p_password        => 'Ctell2026!',
      p_id_usuario      => l_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Usuario admin creado con ID ' || l_id);
    DBMS_OUTPUT.PUT_LINE('Contrasena inicial: Ctell2026!  <-- CAMBIALA AL INGRESAR');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Ya existen usuarios: no se creo el admin inicial.');
  END IF;
END;
/

--------------------------------------------------------------------------------
-- 6. VERIFICACIÓN
--------------------------------------------------------------------------------

DECLARE
  l_errores NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_errores
    FROM USER_ERRORS
   WHERE NAME IN ('PKG_USUARIOS', 'PKG_TOKENS');

  IF l_errores = 0 THEN
    DBMS_OUTPUT.PUT_LINE('OK: paquetes compilados sin errores.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('ATENCION: ' || l_errores || ' errores de compilacion.');
  END IF;
END;
/

-- La columna correcta de USER_OBJECTS es OBJECT_NAME (no NAME).
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_TYPE IN ('PACKAGE', 'PACKAGE BODY')
   AND OBJECT_NAME IN ('PKG_USUARIOS', 'PKG_TOKENS')
 ORDER BY OBJECT_NAME, OBJECT_TYPE;

SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME IN ('PKG_USUARIOS', 'PKG_TOKENS')
 ORDER BY NAME, SEQUENCE;

SELECT m.NAME AS modulo, m.URI_PREFIX, t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_MODULES m
  JOIN USER_ORDS_TEMPLATES t ON t.MODULE_ID = m.ID
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
 WHERE m.NAME IN ('auth', 'usuarios')
 ORDER BY m.NAME, t.URI_TEMPLATE, h.METHOD;

--------------------------------------------------------------------------------
-- 7. PRUEBA DEL CIRCUITO DE LOGIN
--
-- Ejercita lo mismo que hace POST /auth/login, pero desde PL/SQL. Si esto
-- imprime OK, el problema (si queda alguno) está en ORDS o en el cliente, no
-- en los paquetes: eso separa las dos mitades del sistema y evita seguir
-- adivinando contra un 500 genérico.
--
-- No deja rastro: el token de prueba se revoca y se borra al final.
--------------------------------------------------------------------------------

DECLARE
  l_id      NUMBER;
  l_token   VARCHAR2(64);
  l_expira  TIMESTAMP;
  l_valida  NUMBER;
  l_estado  VARCHAR2(1);
  l_usuario VARCHAR2(50) := 'admin';
  l_pass    VARCHAR2(128) := 'Ctell2026!';
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba de login para "' || l_usuario || '" ---');

  -- Estado real del usuario de prueba, para que el diagnostico sea concreto.
  BEGIN
    SELECT UPPER(TRIM(ACTIVO)) INTO l_estado
      FROM USUARIOS WHERE USUARIO = l_usuario;
    DBMS_OUTPUT.PUT_LINE('   ACTIVO en la tabla = ''' || l_estado || '''');
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE('FALLA: no existe el usuario "' || l_usuario || '".');
      RETURN;
  END;

  -- 1. Credenciales
  l_id := PKG_USUARIOS.VERIFICAR_CREDENCIALES(l_usuario, l_pass);

  IF l_id IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('FALLA: VERIFICAR_CREDENCIALES devolvio NULL.');
    IF l_estado != 'A' THEN
      DBMS_OUTPUT.PUT_LINE('  Causa: el usuario esta en estado ''' || l_estado ||
                           ''', no ''A''.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('  El usuario esta activo, asi que la contrasena');
      DBMS_OUTPUT.PUT_LINE('  no coincide con la esperada.');
    END IF;
    RETURN;
  END IF;

  DBMS_OUTPUT.PUT_LINE('OK 1/4: credenciales validas, ID_USUARIO = ' || l_id);

  -- 2. Emisión del token
  PKG_TOKENS.CREAR_TOKEN(
    p_id_usuario       => l_id,
    p_token            => l_token,
    p_fecha_expiracion => l_expira
  );

  DBMS_OUTPUT.PUT_LINE('OK 2/4: token emitido (largo ' || LENGTH(l_token) ||
                       '), vence ' || TO_CHAR(l_expira, 'YYYY-MM-DD HH24:MI:SS'));

  -- 3. Validación del token recién emitido
  l_valida := PKG_TOKENS.VALIDAR_TOKEN(l_token);

  IF l_valida = l_id THEN
    DBMS_OUTPUT.PUT_LINE('OK 3/4: el token valida y devuelve el mismo usuario.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('FALLA: VALIDAR_TOKEN devolvio ' || NVL(TO_CHAR(l_valida), 'NULL'));
    RETURN;
  END IF;

  -- 4. El JOIN de VALIDAR_TOKEN mezcla los dos tipos de ACTIVO: se comprueba
  --    que el token deje de valer al inactivar al usuario, y no antes.
  UPDATE USUARIOS SET ACTIVO = 'I' WHERE ID_USUARIO = l_id;

  IF PKG_TOKENS.VALIDAR_TOKEN(l_token) IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('OK 4/4: inactivar al usuario invalida su token.');
    DBMS_OUTPUT.PUT_LINE('>>> El backend funciona de punta a punta. <<<');
  ELSE
    DBMS_OUTPUT.PUT_LINE('FALLA: el token sigue valido con el usuario en ''I''.');
  END IF;

  -- Se restaura el estado original: la prueba no debe dejar al admin afuera.
  UPDATE USUARIOS SET ACTIVO = l_estado WHERE ID_USUARIO = l_id;

  -- Limpieza: la prueba no debe dejar sesiones abiertas.
  DELETE FROM TOKENS WHERE TOKEN = l_token;
  COMMIT;

EXCEPTION
  WHEN OTHERS THEN
    -- El paso 4 inactiva al usuario temporalmente. Si algo falla despues de
    -- eso, el ROLLBACK lo deja como estaba: nunca se pierde el acceso.
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('EXCEPCION: ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    DBMS_OUTPUT.PUT_LINE('(Se revirtieron los cambios de la prueba.)');
END;
/

-- Red de seguridad: si la prueba quedo a medias, esto devuelve al admin a 'A'.
-- Es un no-op cuando la prueba termino bien.
UPDATE USUARIOS SET ACTIVO = 'A'
 WHERE USUARIO = 'admin' AND UPPER(TRIM(ACTIVO)) != 'A';
COMMIT;
