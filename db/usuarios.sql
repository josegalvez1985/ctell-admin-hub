--------------------------------------------------------------------------------
-- CTELL · USUARIOS
--
-- Script único: paquete PL/SQL + endpoints ORDS. Se ejecuta de una sola vez en
-- la hoja de trabajo SQL de APEX, conectado con el esquema del workspace.
--
-- Alcance: ABM de usuarios. La autenticación (login, logout, sesión actual)
-- vive en db/auth.sql y NO se repite acá.
--
--   GET    /usuarios/              listado paginado, con búsqueda y filtro
--   POST   /usuarios/              alta
--   GET    /usuarios/:id           detalle
--   PUT    /usuarios/:id           modificación
--   DELETE /usuarios/:id           baja física
--   POST   /usuarios/:id/inactivar baja lógica  (ACTIVO = 'I')
--   POST   /usuarios/:id/activar   alta lógica  (ACTIVO = 'A')
--   POST   /usuarios/:id/password  cambio de contraseña
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/usuarios/
--
-- REQUIERE db/auth.sql EJECUTADO ANTES. Este paquete depende de PKG_AUTH para
-- dos cosas y no las reimplementa:
--   · HASH_PASSWORD / GENERAR_SALT  — si el alta calculara el hash distinto
--     del login, el usuario se crearía sin poder entrar nunca.
--   · VALIDAR_TOKEN / REVOCAR_TOKENS_USUARIO — la sesión es de auth.
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   USUARIOS  ID_USUARIO, USUARIO, NOMBRE_APELLIDO, CORREO, CONTRASENA_HASH,
--             SALT, ACTIVO, FECHA_CREACION, FECHA_ACTUALIZACION, ES_ADMIN
--
-- ESTADO: ACTIVO es VARCHAR2(1) con 'A' (activo) / 'I' (inactivo). Ese mismo
-- código viaja en el JSON y lo consume el frontend (tipo `Estado` en
-- src/lib/api.ts). No se traduce a 1/0 en ningún punto: la traducción no
-- aportaba nada y cada conversión era una oportunidad de ORA-01722.
--
-- ES_ADMIN es VARCHAR2(1) con 'S'/'N', y sigue el mismo criterio: viaja como
-- está, sin convertirse a booleano.
--
-- NUNCA SE DEVUELVEN CONTRASENA_HASH NI SALT. Ningún SELECT de este archivo
-- los incluye en una respuesta.
--
-- CORS: se configura UNA sola vez para todo el workspace (Administración del
-- Workspace -> RESTful Services -> orígenes permitidos), no por módulo. No
-- hay nada que agregar acá — orígenes vigentes y detalle en db/auth.sql
-- (hoy: https://www.ctell.online y http://localhost:8080).
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_USUARIOS
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_USUARIOS AS

  -- Códigos de error de negocio, en el rango que Oracle reserva al usuario.
  -- Los handlers los traducen a 400/404/409; cualquier otro código se oculta
  -- como 500 para no filtrar detalles internos.
  C_ERR_DUPLICADO       CONSTANT PLS_INTEGER := -20001;
  C_ERR_NO_EXISTE       CONSTANT PLS_INTEGER := -20002;
  C_ERR_PASSWORD_DEBIL  CONSTANT PLS_INTEGER := -20003;
  C_ERR_DATOS_INVALIDOS CONSTANT PLS_INTEGER := -20004;

  -- Mismos códigos que PKG_AUTH: se repiten como constantes propias para no
  -- obligar a leer el otro paquete cada vez, pero los valores son los mismos.
  C_ESTADO_ACTIVO   CONSTANT VARCHAR2(1) := 'A';
  C_ESTADO_INACTIVO CONSTANT VARCHAR2(1) := 'I';

  C_ADMIN_SI CONSTANT VARCHAR2(1) := 'S';
  C_ADMIN_NO CONSTANT VARCHAR2(1) := 'N';

  -- Tope del listado. Sin esto, un ?tamanio=999999 obliga a la base a armar un
  -- CLOB enorme y el request muere por timeout.
  C_TAMANIO_MAXIMO CONSTANT PLS_INTEGER := 200;
  C_TAMANIO_DEFECTO CONSTANT PLS_INTEGER := 25;

  PROCEDURE CREAR (
    p_usuario         IN  VARCHAR2,
    p_nombre_apellido IN  VARCHAR2,
    p_correo          IN  VARCHAR2 DEFAULT NULL,
    p_password        IN  VARCHAR2,
    p_es_admin        IN  VARCHAR2 DEFAULT 'N',
    p_id_usuario      OUT NUMBER
  );

  -- Un parámetro NULL significa "no cambiar", no "borrar".
  -- p_activo y p_es_admin son códigos: 'A'/'I' y 'S'/'N'. Un valor inválido se
  -- ignora (conserva el actual) en vez de escribir basura en la columna.
  -- La contraseña NO se toca acá: para eso está CAMBIAR_PASSWORD.
  PROCEDURE ACTUALIZAR (
    p_id_usuario      IN NUMBER,
    p_nombre_apellido IN VARCHAR2 DEFAULT NULL,
    p_correo          IN VARCHAR2 DEFAULT NULL,
    p_activo          IN VARCHAR2 DEFAULT NULL,
    p_es_admin        IN VARCHAR2 DEFAULT NULL
  );

  PROCEDURE CAMBIAR_PASSWORD (
    p_id_usuario IN NUMBER,
    p_password   IN VARCHAR2
  );

  -- Baja lógica: ACTIVO = 'I' y se revocan las sesiones abiertas.
  PROCEDURE INACTIVAR (p_id_usuario IN NUMBER);

  PROCEDURE ACTIVAR (p_id_usuario IN NUMBER);

  -- Baja física. Preferí INACTIVAR salvo que haya que borrar el rastro.
  PROCEDURE ELIMINAR (p_id_usuario IN NUMBER);

  -- p_activo: 'A' o 'I'. NULL o un código inválido = sin filtro.
  FUNCTION CONTAR (
    p_busqueda IN VARCHAR2 DEFAULT NULL,
    p_activo   IN VARCHAR2 DEFAULT NULL
  ) RETURN NUMBER;

  -- Normaliza el filtro de estado: devuelve 'A', 'I' o NULL (sin filtro).
  -- Es pública porque los handlers la necesitan ANTES de llamar a CONTAR: una
  -- función del paquete no se puede invocar desde una sentencia SQL, así que
  -- el valor se resuelve en PL/SQL y se pasa como variable.
  FUNCTION NORMALIZAR_ESTADO (p_valor IN VARCHAR2) RETURN VARCHAR2;

END PKG_USUARIOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_USUARIOS AS

  ------------------------------------------------------------------------------
  -- Privados
  ------------------------------------------------------------------------------

  -- Reglas de la contraseña, en un solo lugar: las usan el alta y el cambio.
  PROCEDURE VALIDAR_PASSWORD (p_password IN VARCHAR2) IS
  BEGIN
    IF p_password IS NULL OR LENGTH(p_password) < 8 THEN
      RAISE_APPLICATION_ERROR(C_ERR_PASSWORD_DEBIL,
        'La contrasena debe tener al menos 8 caracteres');
    END IF;

    -- El tope no es capricho: el hash se calcula sobre (SALT || password) y
    -- conviene acotar lo que entra. 128 es holgado para cualquier uso real.
    IF LENGTH(p_password) > 128 THEN
      RAISE_APPLICATION_ERROR(C_ERR_PASSWORD_DEBIL,
        'La contrasena no puede superar los 128 caracteres');
    END IF;
  END VALIDAR_PASSWORD;

  PROCEDURE VALIDAR_CORREO (p_correo IN VARCHAR2) IS
  BEGIN
    -- CORREO es la única columna opcional de la tabla: NULL es válido.
    IF p_correo IS NULL THEN
      RETURN;
    END IF;

    IF NOT REGEXP_LIKE(TRIM(p_correo),
         '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS, 'El correo no es valido');
    END IF;

    IF LENGTH(TRIM(p_correo)) > 100 THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS,
        'El correo no puede superar los 100 caracteres');
    END IF;
  END VALIDAR_CORREO;

  -- Devuelve 'S'/'N', o NULL si el valor no es ninguno de los dos.
  FUNCTION NORMALIZAR_ADMIN (p_valor IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE UPPER(TRIM(p_valor))
             WHEN 'S' THEN C_ADMIN_SI
             WHEN 'N' THEN C_ADMIN_NO
             ELSE NULL
           END;
  END NORMALIZAR_ADMIN;

  -- Lanza C_ERR_NO_EXISTE si el ID no está en la tabla. Se usa antes de las
  -- operaciones que necesitan distinguir "no existe" de "no hizo falta cambiar
  -- nada", donde SQL%ROWCOUNT = 0 sería ambiguo.
  PROCEDURE EXIGIR_QUE_EXISTA (p_id_usuario IN NUMBER) IS
    l_existe PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_existe
      FROM USUARIOS
     WHERE ID_USUARIO = p_id_usuario;

    IF l_existe = 0 THEN
      RAISE_APPLICATION_ERROR(C_ERR_NO_EXISTE, 'El usuario no existe');
    END IF;
  END EXIGIR_QUE_EXISTA;

  ------------------------------------------------------------------------------
  -- Públicos
  ------------------------------------------------------------------------------

  FUNCTION NORMALIZAR_ESTADO (p_valor IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    -- Un código que no sea 'A' ni 'I' devuelve NULL: en un filtro eso es "sin
    -- filtro" y en un UPDATE es "no cambiar". Las dos lecturas son las
    -- deseables ante un valor que no entendemos.
    RETURN CASE UPPER(TRIM(p_valor))
             WHEN C_ESTADO_ACTIVO   THEN C_ESTADO_ACTIVO
             WHEN C_ESTADO_INACTIVO THEN C_ESTADO_INACTIVO
             ELSE NULL
           END;
  END NORMALIZAR_ESTADO;

  PROCEDURE CREAR (
    p_usuario         IN  VARCHAR2,
    p_nombre_apellido IN  VARCHAR2,
    p_correo          IN  VARCHAR2 DEFAULT NULL,
    p_password        IN  VARCHAR2,
    p_es_admin        IN  VARCHAR2 DEFAULT 'N',
    p_id_usuario      OUT NUMBER
  ) IS
    l_usuario   VARCHAR2(50);
    l_salt      VARCHAR2(32);
    l_hash      VARCHAR2(256);
    l_es_admin  VARCHAR2(1);
  BEGIN
    -- El nombre de usuario se guarda SIEMPRE en minúscula. El login busca con
    -- LOWER(), así que un usuario guardado con mayúsculas no podría entrar
    -- nunca — y el 401 resultante es indistinguible de una clave mal puesta.
    l_usuario := LOWER(TRIM(p_usuario));

    IF l_usuario IS NULL OR LENGTH(l_usuario) < 3 THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS,
        'El usuario debe tener al menos 3 caracteres');
    END IF;

    IF LENGTH(l_usuario) > 50 THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS,
        'El usuario no puede superar los 50 caracteres');
    END IF;

    -- Sin espacios ni símbolos: el usuario viaja en la URL y en el JSON del
    -- login, y permitir cualquier cosa complica más de lo que habilita.
    IF NOT REGEXP_LIKE(l_usuario, '^[a-z0-9._-]+$') THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS,
        'El usuario solo admite letras, numeros, punto, guion y guion bajo');
    END IF;

    IF TRIM(p_nombre_apellido) IS NULL THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS,
        'El nombre y apellido es obligatorio');
    END IF;

    IF LENGTH(TRIM(p_nombre_apellido)) > 200 THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS,
        'El nombre y apellido no puede superar los 200 caracteres');
    END IF;

    VALIDAR_CORREO(p_correo);
    VALIDAR_PASSWORD(p_password);

    -- Un valor inválido en el alta cae a 'N': el default seguro es no ser
    -- administrador. Acá NO se usa NORMALIZAR_ADMIN a secas porque su NULL
    -- significa "no cambiar", que en un INSERT no tiene sentido.
    l_es_admin := NVL(NORMALIZAR_ADMIN(p_es_admin), C_ADMIN_NO);

    -- El hash se delega en PKG_AUTH a propósito: es el mismo algoritmo con el
    -- que el login va a verificar después. Duplicarlo acá sería garantizar que
    -- algún día se desincronicen.
    l_salt := PKG_AUTH.GENERAR_SALT();
    l_hash := PKG_AUTH.HASH_PASSWORD(p_password, l_salt);

    INSERT INTO USUARIOS (
      USUARIO, NOMBRE_APELLIDO, CORREO, CONTRASENA_HASH, SALT,
      ACTIVO, ES_ADMIN, FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_usuario,
      TRIM(p_nombre_apellido),
      LOWER(TRIM(p_correo)),
      l_hash,
      l_salt,
      C_ESTADO_ACTIVO,
      l_es_admin,
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_USUARIO INTO p_id_usuario;

  EXCEPTION
    -- Lo atrapa la constraint UNIQUE de USUARIO. Se traduce a un error de
    -- negocio para que el handler lo devuelva como 409 y no como 500.
    WHEN DUP_VAL_ON_INDEX THEN
      RAISE_APPLICATION_ERROR(C_ERR_DUPLICADO,
        'Ya existe un usuario con ese nombre');
  END CREAR;

  PROCEDURE ACTUALIZAR (
    p_id_usuario      IN NUMBER,
    p_nombre_apellido IN VARCHAR2 DEFAULT NULL,
    p_correo          IN VARCHAR2 DEFAULT NULL,
    p_activo          IN VARCHAR2 DEFAULT NULL,
    p_es_admin        IN VARCHAR2 DEFAULT NULL
  ) IS
    l_estado   VARCHAR2(1);
    l_es_admin VARCHAR2(1);
  BEGIN
    VALIDAR_CORREO(p_correo);

    IF p_nombre_apellido IS NOT NULL
       AND LENGTH(TRIM(p_nombre_apellido)) > 200 THEN
      RAISE_APPLICATION_ERROR(C_ERR_DATOS_INVALIDOS,
        'El nombre y apellido no puede superar los 200 caracteres');
    END IF;

    -- Los códigos se resuelven ACÁ, en PL/SQL, y entran al UPDATE como
    -- variables. Llamar a una función del paquete dentro de la sentencia SQL
    -- da PLS-00231: en contexto SQL no es visible.
    l_estado   := NORMALIZAR_ESTADO(p_activo);
    l_es_admin := NORMALIZAR_ADMIN(p_es_admin);

    -- USUARIO no se modifica nunca: es la identidad con la que se inicia
    -- sesión y cambiarla rompería las referencias que alguien tenga anotadas.
    -- Para eso se da de baja y se crea otro.
    UPDATE USUARIOS
       SET NOMBRE_APELLIDO     = NVL(TRIM(p_nombre_apellido), NOMBRE_APELLIDO),
           CORREO              = NVL(LOWER(TRIM(p_correo)), CORREO),
           -- NULL conserva el valor actual, y un código inválido también:
           -- NORMALIZAR_* ya devolvió NULL para lo que no entendió.
           ACTIVO              = NVL(l_estado, ACTIVO),
           ES_ADMIN            = NVL(l_es_admin, ES_ADMIN),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_USUARIO = p_id_usuario;

    -- Sin esto, actualizar un ID inexistente devuelve 200 y quien lo usó cree
    -- que guardó.
    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(C_ERR_NO_EXISTE, 'El usuario no existe');
    END IF;

    -- Si esta modificación lo dejó inactivo, sus sesiones abiertas tienen que
    -- morir con él. Si no, sigue navegando hasta que venza el token.
    IF l_estado = C_ESTADO_INACTIVO THEN
      PKG_AUTH.REVOCAR_TOKENS_USUARIO(p_id_usuario);
    END IF;
  END ACTUALIZAR;

  PROCEDURE CAMBIAR_PASSWORD (
    p_id_usuario IN NUMBER,
    p_password   IN VARCHAR2
  ) IS
    l_salt VARCHAR2(32);
    l_hash VARCHAR2(256);
  BEGIN
    VALIDAR_PASSWORD(p_password);

    -- Salt nuevo en cada cambio: reutilizar el anterior deja el hash viejo y
    -- el nuevo emparentados, y desperdicia la única defensa del salt.
    l_salt := PKG_AUTH.GENERAR_SALT();
    l_hash := PKG_AUTH.HASH_PASSWORD(p_password, l_salt);

    UPDATE USUARIOS
       SET CONTRASENA_HASH     = l_hash,
           SALT                = l_salt,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_USUARIO = p_id_usuario;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(C_ERR_NO_EXISTE, 'El usuario no existe');
    END IF;

    -- Cambiar la clave cierra las demás sesiones. Es lo que se espera cuando
    -- se cambia por sospecha de robo: si las sesiones abiertas sobrevivieran,
    -- el cambio no serviría de nada contra quien ya entró.
    PKG_AUTH.REVOCAR_TOKENS_USUARIO(p_id_usuario);
  END CAMBIAR_PASSWORD;

  PROCEDURE INACTIVAR (p_id_usuario IN NUMBER) IS
  BEGIN
    -- Se verifica la existencia aparte porque acá SQL%ROWCOUNT = 0 es ambiguo:
    -- puede ser "no existe" o "ya estaba inactivo". El primero es un 404 y el
    -- segundo no es un error.
    EXIGIR_QUE_EXISTA(p_id_usuario);

    UPDATE USUARIOS
       SET ACTIVO              = C_ESTADO_INACTIVO,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_USUARIO = p_id_usuario;

    PKG_AUTH.REVOCAR_TOKENS_USUARIO(p_id_usuario);
  END INACTIVAR;

  PROCEDURE ACTIVAR (p_id_usuario IN NUMBER) IS
  BEGIN
    EXIGIR_QUE_EXISTA(p_id_usuario);

    UPDATE USUARIOS
       SET ACTIVO              = C_ESTADO_ACTIVO,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_USUARIO = p_id_usuario;

    -- No se reactivan los tokens revocados: volver a habilitar la cuenta no
    -- debería resucitar sesiones viejas. Que inicie sesión de nuevo.
  END ACTIVAR;

  PROCEDURE ELIMINAR (p_id_usuario IN NUMBER) IS
  BEGIN
    -- TOKENS tiene una FK contra USUARIOS: sin borrar los hijos primero, el
    -- DELETE aborta con ORA-02292.
    DELETE FROM TOKENS WHERE ID_USUARIO = p_id_usuario;

    DELETE FROM USUARIOS WHERE ID_USUARIO = p_id_usuario;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(C_ERR_NO_EXISTE, 'El usuario no existe');
    END IF;
  END ELIMINAR;

  FUNCTION CONTAR (
    p_busqueda IN VARCHAR2 DEFAULT NULL,
    p_activo   IN VARCHAR2 DEFAULT NULL
  ) RETURN NUMBER IS
    l_total   NUMBER;
    l_busqueda VARCHAR2(200);
    l_estado   VARCHAR2(1);
  BEGIN
    l_busqueda := '%' || LOWER(TRIM(p_busqueda)) || '%';
    l_estado   := NORMALIZAR_ESTADO(p_activo);

    SELECT COUNT(*)
      INTO l_total
      FROM USUARIOS
     WHERE (p_busqueda IS NULL
            OR LOWER(USUARIO) LIKE l_busqueda
            OR LOWER(NOMBRE_APELLIDO) LIKE l_busqueda
            OR LOWER(CORREO) LIKE l_busqueda)
       AND (l_estado IS NULL OR UPPER(TRIM(ACTIVO)) = l_estado);

    RETURN l_total;
  END CONTAR;

END PKG_USUARIOS;
/

--------------------------------------------------------------------------------
-- 2. ORDS · MÓDULO /usuarios/   (todos los handlers requieren token)
--
-- BORRAR_MODULO_ORDS se crea en db/auth.sql, que se ejecuta antes que este
-- archivo. No se redefine acá para que exista en un solo lugar.
--
-- Cada handler declara sus parámetros con ORDS.DEFINE_PARAMETER:
--   authorization       HEADER   / IN    -> el token
--   resultado           RESPONSE / OUT   -> el cuerpo de la respuesta
--   X-APEX-STATUS-CODE  HEADER   / OUT   -> el código HTTP (bind status_code)
--
-- El cuerpo de un POST/PUT NO se declara: ORDS parsea el JSON y lo vincula a
-- los binds del mismo nombre. Pasar 'BODY' como p_source_type aborta el script
-- entero con ORA-02290, dejando el módulo sin crear.
--
-- DOS TRAMPAS QUE YA COSTARON CARO, presentes en cada handler de abajo:
--
--  1. Un query param ausente llega como CADENA VACÍA, no como NULL.
--     TO_NUMBER('') lanza ORA-01722, y `:param IS NULL` no protege porque una
--     cadena vacía no es NULL. Por eso todo TO_NUMBER lleva NULLIF(:param,'').
--
--  2. Las conversiones van DENTRO del BEGIN, nunca en el DECLARE. El DECLARE
--     se ejecuta antes de que exista el bloque EXCEPTION: una excepción ahí
--     escapa del handler y ORDS responde un 500 genérico sin que el EXCEPTION
--     escrito llegue a correr.
--------------------------------------------------------------------------------

BEGIN
  BORRAR_MODULO_ORDS('usuarios');

  ORDS.DEFINE_MODULE(
    p_module_name    => 'usuarios',
    p_base_path      => '/usuarios/',
    p_items_per_page => 0,
    p_status         => 'PUBLISHED',
    p_comments       => 'ABM de usuarios'
  );

  ------------------------------------------------------------------------------
  -- GET /usuarios/   → listado paginado
  --
  -- Query params (todos opcionales):
  --   busqueda  texto libre sobre usuario, nombre y correo
  --   activo    'A' o 'I'; cualquier otra cosa = sin filtro
  --   pagina    1 por defecto
  --   tamanio   25 por defecto, 200 como techo
  --
  -- 200 → { items: [...], total, pagina, tamanio }
  ------------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'usuarios', p_pattern => '.');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => '.',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion   NUMBER;
  l_busqueda VARCHAR2(200);
  l_patron   VARCHAR2(200);
  l_estado   VARCHAR2(1);
  l_pagina   NUMBER;
  l_tamanio  NUMBER;
  l_offset   NUMBER;
  l_total    NUMBER;
  l_items    CLOB;
BEGIN
  l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(:authorization));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  -- Todas las conversiones adentro del BEGIN. NULLIF convierte la cadena
  -- vacia del parametro ausente en NULL antes de que TO_NUMBER la toque.
  l_pagina  := GREATEST(NVL(TO_NUMBER(NULLIF(:pagina, '')), 1), 1);
  l_tamanio := NVL(TO_NUMBER(NULLIF(:tamanio, '')), PKG_USUARIOS.C_TAMANIO_DEFECTO);
  l_tamanio := LEAST(GREATEST(l_tamanio, 1), PKG_USUARIOS.C_TAMANIO_MAXIMO);
  l_offset  := (l_pagina - 1) * l_tamanio;

  l_busqueda := NULLIF(TRIM(:busqueda), '');
  l_patron   := '%' || LOWER(l_busqueda) || '%';
  -- Se resuelve en PL/SQL y entra al SELECT como variable: una funcion del
  -- paquete no es visible desde una sentencia SQL (PLS-00231).
  l_estado   := PKG_USUARIOS.NORMALIZAR_ESTADO(NULLIF(:activo, ''));

  l_total := PKG_USUARIOS.CONTAR(l_busqueda, l_estado);

  -- RETURNING ... INTO un CLOB: un listado de 200 filas supera holgadamente
  -- los 4000 bytes de un VARCHAR2 y se truncaria.
  --
  -- Ni CONTRASENA_HASH ni SALT aparecen en este SELECT, ni deben aparecer.
  SELECT JSON_ARRAYAGG(
           JSON_OBJECT(
             'id'                  VALUE ID_USUARIO,
             'usuario'             VALUE USUARIO,
             'nombreApellido'      VALUE NOMBRE_APELLIDO,
             'correo'              VALUE CORREO,
             'activo'              VALUE UPPER(TRIM(ACTIVO)),
             'esAdmin'             VALUE NVL(UPPER(TRIM(ES_ADMIN)), 'N'),
             'fechaCreacion'       VALUE TO_CHAR(FECHA_CREACION, 'YYYY-MM-DD"T"HH24:MI:SS'),
             'fechaActualizacion'  VALUE TO_CHAR(FECHA_ACTUALIZACION, 'YYYY-MM-DD"T"HH24:MI:SS')
             RETURNING CLOB
           )
           -- El ORDER BY va en los dos niveles a proposito: el de la
           -- subconsulta decide QUE filas entran en la pagina (es el que
           -- acompaña al OFFSET), y este decide en que orden quedan dentro
           -- del array. Sin el de aca, el orden del array no esta garantizado
           -- aunque la subconsulta venga ordenada.
           ORDER BY NOMBRE_APELLIDO
           RETURNING CLOB
         )
    INTO l_items
    FROM (
      SELECT ID_USUARIO, USUARIO, NOMBRE_APELLIDO, CORREO, ACTIVO, ES_ADMIN,
             FECHA_CREACION, FECHA_ACTUALIZACION
        FROM USUARIOS
       WHERE (l_busqueda IS NULL
              OR LOWER(USUARIO) LIKE l_patron
              OR LOWER(NOMBRE_APELLIDO) LIKE l_patron
              OR LOWER(CORREO) LIKE l_patron)
         AND (l_estado IS NULL OR UPPER(TRIM(ACTIVO)) = l_estado)
       ORDER BY NOMBRE_APELLIDO
       OFFSET l_offset ROWS FETCH NEXT l_tamanio ROWS ONLY
    );

  :status_code := 200;
  -- JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un array vacio: sin
  -- el NVL el frontend recibiria "items":null y reventaria al iterarlo.
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
    APEX_DEBUG.ERROR('usuarios GET /: ' || SQLERRM || ' | ' ||
                     DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    :resultado := '{"error":"Error al listar los usuarios"}';
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

  ------------------------------------------------------------------------------
  -- POST /usuarios/   → alta
  --
  -- Body: { usuario, nombreApellido, correo?, password, esAdmin? }
  -- 201 → { id, ok: true }     409 → usuario duplicado
  ------------------------------------------------------------------------------
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
  l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(:authorization));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  PKG_USUARIOS.CREAR(
    p_usuario         => :usuario,
    p_nombre_apellido => :nombreApellido,
    p_correo          => :correo,
    p_password        => :password,
    p_es_admin        => :esAdmin,
    p_id_usuario      => l_id
  );

  COMMIT;
  :status_code := 201;
  :resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    IF SQLCODE = -20001 THEN
      -- Duplicado: 409 y no 400. El dato no es invalido, el estado del
      -- servidor es el que lo rechaza.
      :status_code := 409;
      :resultado := JSON_OBJECT('error' VALUE SUBSTR(SQLERRM, 12));
    ELSIF SQLCODE BETWEEN -20004 AND -20002 THEN
      :status_code := 400;
      -- SUBSTR(...,12) recorta el prefijo "ORA-20004: " que Oracle antepone.
      :resultado := JSON_OBJECT('error' VALUE SUBSTR(SQLERRM, 12));
    ELSE
      :status_code := 500;
      APEX_DEBUG.ERROR('usuarios POST /: ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
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

  ------------------------------------------------------------------------------
  -- GET /usuarios/:id   → detalle
  ------------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'usuarios', p_pattern => ':id');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => ':id',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion NUMBER;
  l_id     NUMBER;
BEGIN
  l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(:authorization));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  l_id := TO_NUMBER(NULLIF(:id, ''));

  SELECT JSON_OBJECT(
           'id'                 VALUE ID_USUARIO,
           'usuario'            VALUE USUARIO,
           'nombreApellido'     VALUE NOMBRE_APELLIDO,
           'correo'             VALUE CORREO,
           'activo'             VALUE UPPER(TRIM(ACTIVO)),
           'esAdmin'            VALUE NVL(UPPER(TRIM(ES_ADMIN)), 'N'),
           'fechaCreacion'      VALUE TO_CHAR(FECHA_CREACION, 'YYYY-MM-DD"T"HH24:MI:SS'),
           'fechaActualizacion' VALUE TO_CHAR(FECHA_ACTUALIZACION, 'YYYY-MM-DD"T"HH24:MI:SS')
         )
    INTO :resultado
    FROM USUARIOS
   WHERE ID_USUARIO = l_id;

  :status_code := 200;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    :status_code := 404;
    :resultado := '{"error":"El usuario no existe"}';
  WHEN OTHERS THEN
    :status_code := 500;
    APEX_DEBUG.ERROR('usuarios GET /:id: ' || SQLERRM || ' | ' ||
                     DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
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

  ------------------------------------------------------------------------------
  -- PUT /usuarios/:id   → modificación
  --
  -- Body: { nombreApellido?, correo?, activo?, esAdmin? }
  -- Los campos ausentes no se modifican. USUARIO y la contraseña no se tocan
  -- por acá.
  ------------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => ':id',
    p_method      => 'PUT',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion NUMBER;
BEGIN
  l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(:authorization));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  PKG_USUARIOS.ACTUALIZAR(
    p_id_usuario      => TO_NUMBER(NULLIF(:id, '')),
    p_nombre_apellido => :nombreApellido,
    p_correo          => :correo,
    p_activo          => :activo,
    p_es_admin        => :esAdmin
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
      APEX_DEBUG.ERROR('usuarios PUT /:id: ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
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

  ------------------------------------------------------------------------------
  -- DELETE /usuarios/:id   → baja física
  --
  -- Borra tambien sus tokens (la FK lo exige). Preferir /inactivar salvo que
  -- haya que borrar el rastro.
  ------------------------------------------------------------------------------
  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => ':id',
    p_method      => 'DELETE',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion NUMBER;
  l_id     NUMBER;
BEGIN
  l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(:authorization));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  l_id := TO_NUMBER(NULLIF(:id, ''));

  -- Nadie puede borrarse a si mismo: se quedaria sin sesion a mitad de la
  -- operacion, y si era el ultimo administrador el sistema queda inaccesible.
  IF l_id = l_sesion THEN
    :status_code := 400;
    :resultado := '{"error":"No podes eliminar tu propio usuario"}';
    RETURN;
  END IF;

  PKG_USUARIOS.ELIMINAR(l_id);

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
      APEX_DEBUG.ERROR('usuarios DELETE /:id: ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
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

  ------------------------------------------------------------------------------
  -- POST /usuarios/:id/inactivar   → baja lógica
  ------------------------------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(p_module_name => 'usuarios', p_pattern => ':id/inactivar');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'usuarios',
    p_pattern     => ':id/inactivar',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'~
DECLARE
  l_sesion NUMBER;
  l_id     NUMBER;
BEGIN
  l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(:authorization));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  l_id := TO_NUMBER(NULLIF(:id, ''));

  -- Mismo motivo que en DELETE: inactivarse a si mismo revoca la sesion en
  -- curso y deja al usuario afuera sin aviso.
  IF l_id = l_sesion THEN
    :status_code := 400;
    :resultado := '{"error":"No podes inactivar tu propio usuario"}';
    RETURN;
  END IF;

  PKG_USUARIOS.INACTIVAR(l_id);

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
      APEX_DEBUG.ERROR('usuarios POST /:id/inactivar: ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
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

  ------------------------------------------------------------------------------
  -- POST /usuarios/:id/activar   → alta lógica
  ------------------------------------------------------------------------------
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
  l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(:authorization));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  PKG_USUARIOS.ACTIVAR(TO_NUMBER(NULLIF(:id, '')));

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
      APEX_DEBUG.ERROR('usuarios POST /:id/activar: ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
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

  ------------------------------------------------------------------------------
  -- POST /usuarios/:id/password   → cambio de contraseña
  --
  -- Body: { password }
  -- Revoca todas las sesiones del usuario, incluida la propia si se cambia la
  -- de uno mismo: hay que volver a iniciar sesion.
  ------------------------------------------------------------------------------
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
  l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(:authorization));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  PKG_USUARIOS.CAMBIAR_PASSWORD(TO_NUMBER(NULLIF(:id, '')), :password);

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
      -- Incluye C_ERR_PASSWORD_DEBIL: el mensaje explica el requisito.
      :status_code := 400;
      :resultado := JSON_OBJECT('error' VALUE SUBSTR(SQLERRM, 12));
    ELSE
      :status_code := 500;
      APEX_DEBUG.ERROR('usuarios POST /:id/password: ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
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
-- 3. Usuario administrador inicial
--
-- Solo si la tabla está vacía: reejecutar el script no debe pisar nada ni
-- recrear un usuario que se dio de baja a propósito.
--
-- La contraseña se genera al azar en cada corrida y sale SOLO por
-- DBMS_OUTPUT: no queda escrita en el repositorio. Copiala de la salida de
-- este bloque y cambiala apenas entres.
--------------------------------------------------------------------------------

DECLARE
  l_total    PLS_INTEGER;
  l_id       NUMBER;
  l_password VARCHAR2(20);
BEGIN
  SELECT COUNT(*) INTO l_total FROM USUARIOS;

  IF l_total > 0 THEN
    DBMS_OUTPUT.PUT_LINE('Ya hay usuarios: no se crea el administrador inicial');
    RETURN;
  END IF;

  -- 20 hex de SYS_GUID(): cumple el mínimo de 8 caracteres de
  -- VALIDAR_PASSWORD con margen de sobra.
  l_password := SUBSTR(RAWTOHEX(SYS_GUID()), 1, 20);

  PKG_USUARIOS.CREAR(
    p_usuario         => 'admin',
    p_nombre_apellido => 'Administrador',
    p_correo          => NULL,
    p_password        => l_password,
    p_es_admin        => 'S',
    p_id_usuario      => l_id
  );

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Administrador inicial creado con ID ' || l_id);
  DBMS_OUTPUT.PUT_LINE('Usuario: admin / Contrasena: ' || l_password || ' — CAMBIALA YA');
END;
/

--------------------------------------------------------------------------------
-- 4. Verificación
--
-- En USER_OBJECTS la columna es OBJECT_NAME, no NAME: usar NAME da ORA-00904.
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_USUARIOS'
 ORDER BY OBJECT_TYPE;

-- Si algo salió INVALID arriba, acá está el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_USUARIOS'
 ORDER BY SEQUENCE;

-- Rutas publicadas: 8 handlers sobre 5 templates.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'usuarios'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

SELECT ID_USUARIO, USUARIO, NOMBRE_APELLIDO, ACTIVO, ES_ADMIN
  FROM USUARIOS
 ORDER BY ID_USUARIO;
