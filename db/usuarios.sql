--------------------------------------------------------------------------------
-- CTELL · USUARIOS
--
-- Un paquete (PKG_USUARIOS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicación de los endpoints ORDS. Todo vive
-- dentro del paquete: no hay procedimientos sueltos ni PL/SQL embebido como
-- texto dentro de los handlers.
--
--   1. LISTAR      GET    /usuarios/listar
--   2. INSERTAR    POST   /usuarios/crear
--   3. ACTUALIZAR  PUT    /usuarios/actualizar/:id
--   4. ELIMINAR    DELETE /usuarios/eliminar/:id
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token y para hashear la contraseña en el alta.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/usuarios/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   USUARIOS  ID_USUARIO, USUARIO, NOMBRE_APELLIDO, CORREO, CONTRASENA_HASH,
--             SALT, ACTIVO, ES_ADMIN, FECHA_CREACION, FECHA_ACTUALIZACION
--
-- ESTADO: ACTIVO es VARCHAR2(1) con 'A' (activo) / 'I' (inactivo). Ese mismo
-- código viaja en el JSON y lo consume el frontend, sin traducirse a 1/0.
-- ES_ADMIN sigue el mismo criterio con 'S'/'N'.
--
-- NUNCA SE DEVUELVEN CONTRASENA_HASH NI SALT. Ningún SELECT de este archivo
-- los incluye en una respuesta.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicación completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_USUARIOS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_USUARIOS.LISTAR('Bearer TU_TOKEN', l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_USUARIOS AS

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- El correo es OBLIGATORIO: es a donde va la contraseña inicial.
  -- p_password es opcional — si no viene, se genera una al azar. En los dos
  -- casos la clave se manda por correo y no se devuelve en la respuesta,
  -- salvo que el envío falle (ver el cuerpo).
  PROCEDURE INSERTAR (
    p_authorization   IN  VARCHAR2,
    p_usuario         IN  VARCHAR2,
    p_nombre_apellido IN  VARCHAR2,
    p_correo          IN  VARCHAR2,
    p_password        IN  VARCHAR2,
    p_es_admin        IN  VARCHAR2,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  );

  -- Los parámetros ausentes (NULL) no modifican la columna correspondiente.
  -- USUARIO no se actualiza nunca: es la identidad con la que se inicia sesión.
  PROCEDURE ACTUALIZAR (
    p_authorization   IN  VARCHAR2,
    p_id              IN  VARCHAR2,
    p_nombre_apellido IN  VARCHAR2,
    p_correo          IN  VARCHAR2,
    p_activo          IN  VARCHAR2,
    p_es_admin        IN  VARCHAR2,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el módulo ORDS /usuarios/ con sus 4 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_USUARIOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_USUARIOS AS

  ------------------------------------------------------------------------------
  -- Privado: borra el módulo ORDS si existe, reintentando ante un interbloqueo.
  --
  -- Nunca usar `WHEN OTHERS THEN NULL` acá: se tragaría también un ORA-00060,
  -- el DELETE fallaría en silencio, y el DEFINE_MODULE de después moriría con
  -- ORA-00001 (nombre duplicado) contra el módulo que nunca se llegó a borrar.
  ------------------------------------------------------------------------------
  PROCEDURE BORRAR_MODULO IS
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
         WHERE NAME = 'usuarios';

        IF l_existe = 0 THEN
          RETURN;  -- No existía: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'usuarios');
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
  END BORRAR_MODULO;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_total  NUMBER;
    l_items  CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    SELECT COUNT(*) INTO l_total FROM USUARIOS;

    -- Ni CONTRASENA_HASH ni SALT aparecen acá, ni deben aparecer.
    SELECT JSON_ARRAYAGG(
             JSON_OBJECT(
               'id'                 VALUE ID_USUARIO,
               'usuario'            VALUE USUARIO,
               'nombreApellido'     VALUE NOMBRE_APELLIDO,
               'correo'             VALUE CORREO,
               'activo'             VALUE UPPER(TRIM(ACTIVO)),
               'esAdmin'            VALUE NVL(UPPER(TRIM(ES_ADMIN)), 'N'),
               'fechaCreacion'      VALUE TO_CHAR(FECHA_CREACION, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'fechaActualizacion' VALUE TO_CHAR(FECHA_ACTUALIZACION, 'YYYY-MM-DD"T"HH24:MI:SS')
               RETURNING CLOB
             )
             ORDER BY NOMBRE_APELLIDO
             RETURNING CLOB
           )
      INTO l_items
      FROM USUARIOS;

    p_status_code := 200;
    -- JSON_OBJECT(... RETURNING CLOB) como asignación PL/SQL directa (sin
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
      APEX_DEBUG.ERROR('PKG_USUARIOS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los usuarios"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization   IN  VARCHAR2,
    p_usuario         IN  VARCHAR2,
    p_nombre_apellido IN  VARCHAR2,
    p_correo          IN  VARCHAR2,
    p_password        IN  VARCHAR2,
    p_es_admin        IN  VARCHAR2,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_usuario  VARCHAR2(50);
    l_correo   VARCHAR2(200);
    l_password VARCHAR2(128);
    l_generada VARCHAR2(1);
    l_enviado  VARCHAR2(1);
    l_salt     VARCHAR2(32);
    l_hash     VARCHAR2(256);
    l_id       NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- El nombre de usuario se guarda SIEMPRE en minúscula: el login busca con
    -- LOWER(), así que uno guardado con mayúsculas no podría entrar nunca — y
    -- el 401 resultante es indistinguible de una clave mal puesta.
    l_usuario := LOWER(TRIM(p_usuario));
    l_correo  := LOWER(TRIM(p_correo));

    IF l_usuario IS NULL OR TRIM(p_nombre_apellido) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"usuario y nombreApellido son obligatorios"}';
      RETURN;
    END IF;

    -- El correo pasó a ser obligatorio: es el único canal por el que sale la
    -- contraseña inicial. Sin él, la cuenta nacería inaccesible.
    IF l_correo IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"El correo es obligatorio: ahi se envia la contrasena inicial"}';
      RETURN;
    END IF;

    -- Validación mínima de formato. No pretende cubrir el RFC entero: alcanza
    -- con descartar lo que seguro no es una dirección, porque un correo mal
    -- escrito acá deja al usuario sin poder entrar.
    IF NOT REGEXP_LIKE(l_correo, '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') THEN
      p_status_code := 400;
      p_resultado := '{"error":"El correo no tiene un formato valido"}';
      RETURN;
    END IF;

    -- La contraseña es opcional. Si no viene, se genera una al azar y el
    -- usuario la recibe por correo; quien da el alta no la elige ni la ve.
    IF p_password IS NULL THEN
      l_password := PKG_AUTH.GENERAR_PASSWORD();
      l_generada := 'S';
    ELSE
      l_password := p_password;
      l_generada := 'N';

      IF LENGTH(l_password) < 8 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La contrasena debe tener al menos 8 caracteres"}';
        RETURN;
      END IF;
    END IF;

    -- El hash se delega en PKG_AUTH a propósito: es el mismo algoritmo con el
    -- que el login va a verificar después. Duplicarlo acá sería garantizar que
    -- algún día se desincronicen.
    l_salt := PKG_AUTH.GENERAR_SALT();
    l_hash := PKG_AUTH.HASH_PASSWORD(l_password, l_salt);

    INSERT INTO USUARIOS (
      USUARIO, NOMBRE_APELLIDO, CORREO, CONTRASENA_HASH, SALT,
      ACTIVO, ES_ADMIN, FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_usuario,
      TRIM(p_nombre_apellido),
      l_correo,
      l_hash,
      l_salt,
      'A',
      -- Un valor inválido cae a 'N': el default seguro es no ser administrador.
      CASE UPPER(TRIM(p_es_admin)) WHEN 'S' THEN 'S' ELSE 'N' END,
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_USUARIO INTO l_id;

    -- El COMMIT va ANTES del correo, no después: el usuario ya es válido y no
    -- queremos que un SMTP lento mantenga la transacción abierta. Si el envío
    -- falla, la cuenta igual queda creada y la clave se devuelve como respaldo.
    COMMIT;

    PKG_AUTH.ENVIAR_PASSWORD_INICIAL(
      p_correo          => l_correo,
      p_usuario         => l_usuario,
      p_nombre_apellido => TRIM(p_nombre_apellido),
      p_password        => l_password,
      p_enviado         => l_enviado
    );

    p_status_code := 201;

    -- La contraseña se devuelve SOLO si el correo no salió, y sólo cuando la
    -- generó el sistema: si la eligió quien dio el alta, ya la conoce y
    -- repetirla en la respuesta sería exponerla sin ninguna ganancia.
    SELECT JSON_OBJECT(
             'id'               VALUE l_id,
             'ok'               VALUE 'true' FORMAT JSON,
             'correoEnviado'    VALUE CASE WHEN l_enviado = 'A' THEN 'true'
                                           ELSE 'false' END FORMAT JSON,
             'passwordInicial'  VALUE CASE WHEN l_enviado != 'A' AND l_generada = 'S'
                                           THEN l_password END
             RETURNING CLOB
           )
      INTO p_resultado
      FROM DUAL;
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- Duplicado: 409 y no 400. El dato no es inválido, el estado del
      -- servidor es el que lo rechaza.
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe un usuario con ese nombre"}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_USUARIOS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al crear el usuario"}';
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization   IN  VARCHAR2,
    p_id              IN  VARCHAR2,
    p_nombre_apellido IN  VARCHAR2,
    p_correo          IN  VARCHAR2,
    p_activo          IN  VARCHAR2,
    p_es_admin        IN  VARCHAR2,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_id       NUMBER;
    l_estado   VARCHAR2(1);
    l_es_admin VARCHAR2(1);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id := TO_NUMBER(NULLIF(p_id, ''));

    -- Los códigos se resuelven ACÁ, en PL/SQL, y entran al UPDATE como
    -- variables. Un valor inválido queda NULL = no cambiar: es preferible
    -- ignorarlo a escribir basura en la columna.
    l_estado := CASE UPPER(TRIM(p_activo))
                  WHEN 'A' THEN 'A'
                  WHEN 'I' THEN 'I'
                  ELSE NULL
                END;

    l_es_admin := CASE UPPER(TRIM(p_es_admin))
                    WHEN 'S' THEN 'S'
                    WHEN 'N' THEN 'N'
                    ELSE NULL
                  END;

    -- Inactivarse a uno mismo revoca la sesión en curso y deja al usuario
    -- afuera sin aviso.
    IF l_id = l_sesion AND l_estado = 'I' THEN
      p_status_code := 400;
      p_resultado := '{"error":"No podes inactivar tu propio usuario"}';
      RETURN;
    END IF;

    -- USUARIO no se modifica nunca: es la identidad con la que se inicia
    -- sesión. Para cambiarla se da de baja y se crea otro.
    UPDATE USUARIOS
       SET NOMBRE_APELLIDO     = NVL(TRIM(p_nombre_apellido), NOMBRE_APELLIDO),
           CORREO              = NVL(LOWER(TRIM(p_correo)), CORREO),
           ACTIVO              = NVL(l_estado, ACTIVO),
           ES_ADMIN            = NVL(l_es_admin, ES_ADMIN),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_USUARIO = l_id;

    -- Sin esto, actualizar un ID inexistente devuelve 200 y quien lo usó cree
    -- que guardó.
    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El usuario no existe"}';
      RETURN;
    END IF;

    -- Si esta modificación lo dejó inactivo, sus sesiones abiertas tienen que
    -- morir con él. Si no, sigue navegando hasta que venza el token.
    IF l_estado = 'I' THEN
      PKG_AUTH.REVOCAR_TOKENS_USUARIO(l_id);
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_USUARIOS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al actualizar el usuario"}';
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_id     NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id := TO_NUMBER(NULLIF(p_id, ''));

    -- Nadie puede borrarse a sí mismo: se quedaría sin sesión a mitad de la
    -- operación, y si era el último administrador el sistema queda inaccesible.
    IF l_id = l_sesion THEN
      p_status_code := 400;
      p_resultado := '{"error":"No podes eliminar tu propio usuario"}';
      RETURN;
    END IF;

    -- TOKENS tiene una FK contra USUARIOS: sin borrar los hijos primero, el
    -- DELETE aborta con ORA-02292.
    DELETE FROM TOKENS WHERE ID_USUARIO = l_id;

    DELETE FROM USUARIOS WHERE ID_USUARIO = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El usuario no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_USUARIOS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al eliminar el usuario"}';
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Publica el módulo ORDS /usuarios/ con sus 4 endpoints.
  --
  -- Cada handler es una sola línea: invoca al procedimiento del paquete
  -- pasando los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parámetro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahí). Sin
  -- esto, toda petición cross-origin a /usuarios/* la rechaza ORDS antes de
  -- llegar a cualquiera de los 4 handlers. Ver la explicación en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'usuarios',
      p_base_path      => '/usuarios/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'ABM de usuarios'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'usuarios',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /usuarios/listar
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'usuarios', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'usuarios',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_USUARIOS.LISTAR(:authorization, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuarios', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuarios', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuarios', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /usuarios/crear
    -- Body: { usuario, nombreApellido, correo?, password, esAdmin? }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'usuarios', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'usuarios',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_USUARIOS.INSERTAR(:authorization, :usuario, :nombreApellido, :correo, :password, :esAdmin, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuarios', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuarios', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuarios', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /usuarios/actualizar/:id
    -- Body: { nombreApellido?, correo?, activo?, esAdmin? }  (ausentes = no cambia)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'usuarios', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'usuarios',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_USUARIOS.ACTUALIZAR(:authorization, :id, :nombreApellido, :correo, :activo, :esAdmin, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuarios', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuarios', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuarios', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /usuarios/eliminar/:id
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'usuarios', p_pattern => 'eliminar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'usuarios',
      p_pattern     => 'eliminar/:id',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_USUARIOS.ELIMINAR(:authorization, :id, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuarios', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuarios', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuarios', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_USUARIOS;
/

--------------------------------------------------------------------------------
-- 2. Publicación de los endpoints
--
-- Única sentencia fuera del paquete: la llamada que publica el módulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_USUARIOS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificación
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

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'usuarios';

SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'usuarios'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

SELECT ID_USUARIO, USUARIO, NOMBRE_APELLIDO, ACTIVO, ES_ADMIN
  FROM USUARIOS
 ORDER BY NOMBRE_APELLIDO;
