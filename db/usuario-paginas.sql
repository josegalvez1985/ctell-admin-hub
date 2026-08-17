--------------------------------------------------------------------------------
-- CTELL · USUARIO_PAGINAS
--
-- Permisos: qué páginas puede ver cada usuario. Es una tabla puente, así que
-- el ABM no es el de siempre — no hay "actualizar" (un permiso existe o no) y
-- la fila se identifica por las dos claves juntas, no por un ID propio:
--
--   1. LISTAR   GET    /usuario-paginas/listar?idUsuario=
--   2. ASIGNAR  POST   /usuario-paginas/asignar  { idUsuario, idPagina, idEmpresa? }
--   3. QUITAR   DELETE /usuario-paginas/quitar/:idUsuario/:idPagina
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES (usa PKG_AUTH
-- para validar el token).
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/usuario-paginas/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   USUARIO_PAGINAS  ID_USUARIO, ID_PAGINA, FECHA_ALTA, ID_EMPRESA
--   PK compuesta (ID_USUARIO, ID_PAGINA): un mismo permiso no se puede
--   duplicar — el segundo INSERT da ORA-00001, que se traduce a 409.
--
-- ID_EMPRESA DEFINE DONDE VALE EL PERMISO. El menú solo muestra las páginas
-- cuyo permiso corresponde a la empresa con la que el usuario inició sesión
-- (ver src/hooks/use-menu-usuario.ts). Sin permisos en esa empresa, el menú
-- queda vacío.
--
-- HAY UNA LIMITACION IMPORTANTE EN EL DDL, y conviene tenerla presente:
--
--   * ID_EMPRESA **no está en la PK**, que sigue siendo (ID_USUARIO,
--     ID_PAGINA). Por eso un usuario NO puede tener la misma página habilitada
--     en DOS empresas a la vez: el segundo INSERT choca con la PK y da 409,
--     aunque cambie el idEmpresa. Cada página se asigna a una sola empresa por
--     usuario.
--
--     Para levantar ese límite hay que cambiar el DDL: PK en (ID_USUARIO,
--     ID_PAGINA, ID_EMPRESA) y la columna NOT NULL.
--
--   * Es NULLABLE. Las filas anteriores a esta columna quedan en NULL y el
--     menú NO las muestra en ninguna empresa: hay que reasignarlas desde el ABM
--     de permisos, que ahora registra la empresa activa. Es el precio de
--     filtrar — tratarlas como "válidas en todas" haría que el menú siguiera
--     mostrando páginas que nadie habilitó para esa empresa.
--
--     La última consulta de verificación cuenta cuántos permisos quedaron sin
--     empresa, para saber qué hay que reasignar.
--
-- La FK contra EMPRESAS sí se respeta: mandar un idEmpresa inexistente da
-- ORA-02291, que se traduce a 400 en vez de 500.
--
-- OJO CON LAS FK: la tabla tiene FK contra USUARIOS pero NO contra PAGINAS
-- (el DDL solo crea un índice sobre ID_PAGINA). Por eso ASIGNAR verifica a
-- mano que la página exista: sin eso se podrían guardar permisos sobre
-- páginas fantasma y el listado los ocultaría al hacer JOIN, dejando filas
-- basura invisibles.
--
-- El listado hace JOIN con PAGINAS y MODULOS para devolver los nombres: el
-- frontend necesita mostrar "Compras › Órdenes", no dos números sueltos.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO ORDS, no a nivel de workspace. Se
-- declara en PUBLICAR_ENDPOINTS. Ver la explicación completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_USUARIO_PAGINAS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_USUARIO_PAGINAS.LISTAR('Bearer TU_TOKEN', '21', l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_USUARIO_PAGINAS AS

  -- p_id_usuario filtra los permisos de un usuario. NULL o vacío = todos.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Da permiso a un usuario sobre una página. Si ya lo tenía, 409 — incluso
  -- con otra empresa: ID_EMPRESA no integra la PK.
  --
  -- p_id_empresa define en qué empresa vale el permiso. Es técnicamente
  -- opcional (la columna es nullable), pero un permiso sin empresa no aparece
  -- en ningún menú. Ver la explicación completa en el encabezado del archivo.
  PROCEDURE ASIGNAR (
    p_authorization IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_id_pagina     IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Le saca el permiso. Hacen falta las dos claves: la PK es compuesta.
  PROCEDURE QUITAR (
    p_authorization IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_id_pagina     IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el módulo ORDS /usuario-paginas/ con sus 3 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_USUARIO_PAGINAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_USUARIO_PAGINAS AS

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
         WHERE NAME = 'usuario-paginas';

        IF l_existe = 0 THEN
          RETURN;  -- No existía: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'usuario-paginas');
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
    p_id_usuario    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_usuario NUMBER;
    l_total      NUMBER;
    l_items      CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- La conversión va acá, dentro del BEGIN: en el DECLARE se ejecutaría
    -- antes de que exista el EXCEPTION y el error escaparía del procedimiento.
    -- NULLIF convierte la cadena vacía del parámetro ausente en NULL antes de
    -- que TO_NUMBER la toque (si no, ORA-01722).
    l_id_usuario := TO_NUMBER(NULLIF(p_id_usuario, ''));

    -- ESTE LISTAR TIENE DOS USOS Y SOLO UNO ES ADMINISTRATIVO:
    --
    --   1. El MENU de cada usuario, que pide SUS PROPIOS permisos
    --      (?idUsuario=<el suyo>). Lo usa toda la app en cada carga, asi que
    --      exigir admin lo dejaria sin menu a todo el mundo.
    --   2. El ABM de Permisos, que consulta los de OTRO usuario.
    --
    -- La regla que cubre los dos: cada uno puede ver los suyos, y solo un
    -- administrador puede ver los de otro. Sin este control, cualquiera podia
    -- mapear los accesos de cualquier cuenta pasando otro id.
    --
    -- El filtro vacio (todos los usuarios) tambien es administrativo: devuelve
    -- el mapa de permisos completo del sistema.
    IF (l_id_usuario IS NULL OR l_id_usuario != l_sesion)
       AND NOT PKG_AUTH.ES_ADMINISTRADOR(l_sesion) THEN
      p_status_code := 403;
      p_resultado := '{"error":"Solo un administrador puede ver los permisos de otro usuario"}';
      RETURN;
    END IF;

    SELECT COUNT(*)
      INTO l_total
      FROM USUARIO_PAGINAS
     WHERE l_id_usuario IS NULL OR ID_USUARIO = l_id_usuario;

    -- Los JOIN traen los nombres: el frontend muestra "Compras › Órdenes", no
    -- dos números sueltos. Van como INNER JOIN a propósito — una fila que
    -- apunte a una página inexistente no debería aparecer como si fuera un
    -- permiso válido.
    -- RUTA y ENTRADA salen de PAGINAS porque el menú dinámico las necesita:
    -- sin RUTA el item no sabe adónde navegar, y sin ENTRADA no puede
    -- agruparse bajo Definiciones / Operaciones / Reportes.
    SELECT JSON_ARRAYAGG(
             JSON_OBJECT(
               'idUsuario'  VALUE up.ID_USUARIO,
               'usuario'    VALUE u.USUARIO,
               'idPagina'   VALUE up.ID_PAGINA,
               'pagina'     VALUE p.NOMBRE,
               'ruta'       VALUE p.RUTA,
               -- UPPER(TRIM(...)): el frontend agrupa el menu con esta letra
               -- como clave de un objeto ('D'/'O'/'R'). Una 'o' minuscula o con
               -- un espacio no matchea, y el grupo entero —"Operaciones"— no se
               -- dibuja aunque el permiso exista. Mismo criterio que ACTIVO.
               'entrada'    VALUE UPPER(TRIM(p.ENTRADA)),
               'orden'      VALUE p.ORDEN,
               'idModulo'   VALUE m.ID_MODULO,
               'modulo'     VALUE m.NOMBRE,
               'moduloIcono' VALUE m.ICONO,
               -- Empresa en la que vale el permiso. El frontend filtra por
               -- esto: solo muestra en el menú las páginas cuya empresa
               -- coincide con la de la sesión. Null = no aparece en ninguna.
               'idEmpresa'  VALUE up.ID_EMPRESA,
               'fechaAlta'  VALUE TO_CHAR(up.FECHA_ALTA, 'YYYY-MM-DD"T"HH24:MI:SS')
               RETURNING CLOB
             )
             ORDER BY u.USUARIO, m.ORDEN, m.NOMBRE, p.ORDEN, p.NOMBRE
             RETURNING CLOB
           )
      INTO l_items
      FROM USUARIO_PAGINAS up
      JOIN USUARIOS u ON u.ID_USUARIO = up.ID_USUARIO
      JOIN PAGINAS  p ON p.ID_PAGINA  = up.ID_PAGINA
      JOIN MODULOS  m ON m.ID_MODULO  = p.ID_MODULO
     WHERE l_id_usuario IS NULL OR up.ID_USUARIO = l_id_usuario;

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
      APEX_DEBUG.ERROR('PKG_USUARIO_PAGINAS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los permisos"}';
  END LISTAR;

  PROCEDURE ASIGNAR (
    p_authorization IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_id_pagina     IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_usuario NUMBER;
    l_id_pagina  NUMBER;
    l_id_empresa NUMBER;
    l_existe     PLS_INTEGER;
  BEGIN
    -- SOLO ADMINISTRADORES: otorgar accesos es la operacion mas sensible del
    -- sistema. Sin este control, cualquier usuario con sesion podia asignarse a
    -- si mismo cualquier pagina —incluida Administracion— y escalar privilegios
    -- con una sola peticion.
    l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 403;
      p_resultado := '{"error":"Se requieren permisos de administrador"}';
      RETURN;
    END IF;

    l_id_usuario := TO_NUMBER(NULLIF(p_id_usuario, ''));
    l_id_pagina  := TO_NUMBER(NULLIF(p_id_pagina, ''));
    -- La empresa no entra en la validación de obligatorios porque la columna es
    -- nullable, pero OJO: un permiso que quede en NULL no lo muestra ningún
    -- menú. El frontend siempre manda la empresa activa.
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    IF l_id_usuario IS NULL OR l_id_pagina IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idUsuario e idPagina son obligatorios"}';
      RETURN;
    END IF;

    -- La tabla NO tiene FK contra PAGINAS (ver la nota del encabezado): sin
    -- este chequeo se guardaría un permiso sobre una página que no existe, y
    -- el JOIN del listado lo escondería para siempre.
    SELECT COUNT(*)
      INTO l_existe
      FROM PAGINAS
     WHERE ID_PAGINA = l_id_pagina;

    IF l_existe = 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La pagina indicada no existe"}';
      RETURN;
    END IF;

    INSERT INTO USUARIO_PAGINAS (ID_USUARIO, ID_PAGINA, FECHA_ALTA, ID_EMPRESA)
    VALUES (l_id_usuario, l_id_pagina, SYSTIMESTAMP, l_id_empresa);

    COMMIT;
    p_status_code := 201;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- La PK compuesta lo rechaza: el usuario ya tenía ese permiso. Es 409 y
      -- no 400 — el dato no es inválido, el estado del servidor lo rechaza.
      p_status_code := 409;
      p_resultado := '{"error":"El usuario ya tiene acceso a esa pagina"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: alguna FK no encontró el padre. Ahora hay DOS (USUARIOS y
      -- EMPRESAS), así que el mensaje mira el texto del error para nombrar la
      -- correcta: decir "el usuario no existe" cuando lo que falla es la
      -- empresa manda a revisar el dato equivocado.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        IF INSTR(UPPER(SQLERRM), 'FK_EMPRESAS') > 0 THEN
          p_resultado := '{"error":"La empresa indicada no existe"}';
        ELSE
          p_resultado := '{"error":"El usuario indicado no existe"}';
        END IF;
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_USUARIO_PAGINAS.ASIGNAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al asignar el permiso"}';
      END IF;
  END ASIGNAR;

  PROCEDURE QUITAR (
    p_authorization IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_id_pagina     IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
  BEGIN
    -- SOLO ADMINISTRADORES, igual que ASIGNAR: quitarle el acceso a alguien es
    -- tan sensible como darselo.
    l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 403;
      p_resultado := '{"error":"Se requieren permisos de administrador"}';
      RETURN;
    END IF;

    -- Las dos claves: la PK es compuesta, borrar solo por una dejaría afuera
    -- la mitad de la identidad de la fila.
    DELETE FROM USUARIO_PAGINAS
     WHERE ID_USUARIO = TO_NUMBER(NULLIF(p_id_usuario, ''))
       AND ID_PAGINA  = TO_NUMBER(NULLIF(p_id_pagina, ''));

    -- Sin esto, quitar un permiso inexistente devuelve 200 y quien lo usó cree
    -- que hizo algo.
    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El usuario no tenia acceso a esa pagina"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_USUARIO_PAGINAS.QUITAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al quitar el permiso"}';
  END QUITAR;

  ------------------------------------------------------------------------------
  -- Publica el módulo ORDS /usuario-paginas/ con sus 3 endpoints.
  --
  -- Cada handler es una sola línea: invoca al procedimiento del paquete
  -- pasando los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parámetro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahí). Sin
  -- esto, toda petición cross-origin a /usuario-paginas/* la rechaza ORDS
  -- antes de llegar a los handlers. Ver la explicación en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'usuario-paginas',
      p_base_path      => '/usuario-paginas/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Permisos de usuarios sobre paginas'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'usuario-paginas',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /usuario-paginas/listar
    -- Query param opcional: ?idUsuario=  (sin él, devuelve todos los permisos)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'usuario-paginas', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'usuario-paginas',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_USUARIO_PAGINAS.LISTAR(:authorization, :idUsuario, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /usuario-paginas/asignar
    -- Body: { idUsuario, idPagina }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'usuario-paginas', p_pattern => 'asignar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'usuario-paginas',
      p_pattern     => 'asignar',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_USUARIO_PAGINAS.ASIGNAR(:authorization, :idUsuario, :idPagina, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'asignar', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'asignar', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'asignar', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /usuario-paginas/quitar/:idUsuario/:idPagina
    --
    -- Las dos claves van en la URL porque la PK es compuesta: no alcanza con
    -- un solo :id como en las otras tablas.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(
      p_module_name => 'usuario-paginas',
      p_pattern     => 'quitar/:idUsuario/:idPagina'
    );

    ORDS.DEFINE_HANDLER(
      p_module_name => 'usuario-paginas',
      p_pattern     => 'quitar/:idUsuario/:idPagina',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_USUARIO_PAGINAS.QUITAR(:authorization, :idUsuario, :idPagina, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'quitar/:idUsuario/:idPagina',
      p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'quitar/:idUsuario/:idPagina',
      p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'quitar/:idUsuario/:idPagina',
      p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_USUARIO_PAGINAS;
/

--------------------------------------------------------------------------------
-- 2. Publicación de los endpoints
--
-- Única sentencia fuera del paquete: la llamada que publica el módulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_USUARIO_PAGINAS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificación
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_USUARIO_PAGINAS'
 ORDER BY OBJECT_TYPE;

-- Si algo salió INVALID arriba, acá está el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_USUARIO_PAGINAS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'usuario-paginas';

SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'usuario-paginas'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- LEFT JOIN contra EMPRESAS, no interno: ID_EMPRESA es nullable y los permisos
-- anteriores a esa columna la tienen en NULL. Con un JOIN interno esas filas
-- desaparecerían de esta verificación justo cuando uno quiere verlas.
SELECT u.USUARIO, m.NOMBRE AS MODULO, p.NOMBRE AS PAGINA,
       up.ID_EMPRESA, e.NOMBRE_EMPRESA, up.FECHA_ALTA
  FROM USUARIO_PAGINAS up
  JOIN USUARIOS u ON u.ID_USUARIO = up.ID_USUARIO
  JOIN PAGINAS  p ON p.ID_PAGINA  = up.ID_PAGINA
  JOIN MODULOS  m ON m.ID_MODULO  = p.ID_MODULO
  LEFT JOIN EMPRESAS e ON e.ID_EMPRESA = up.ID_EMPRESA
 ORDER BY u.USUARIO, m.ORDEN, p.ORDEN;

-- ATENCION: permisos sin empresa, los cargados antes de que existiera la
-- columna. NO aparecen en el menú de ninguna empresa, porque el frontend filtra
-- por ID_EMPRESA. Hay que reasignarlos desde el ABM de permisos entrando con la
-- empresa que corresponda.
--
-- Si el listado de abajo devuelve filas y alguien reporta "me quedé sin menú",
-- la causa es esta.
SELECT u.USUARIO, m.NOMBRE AS MODULO, p.NOMBRE AS PAGINA
  FROM USUARIO_PAGINAS up
  JOIN USUARIOS u ON u.ID_USUARIO = up.ID_USUARIO
  JOIN PAGINAS  p ON p.ID_PAGINA  = up.ID_PAGINA
  JOIN MODULOS  m ON m.ID_MODULO  = p.ID_MODULO
 WHERE up.ID_EMPRESA IS NULL
 ORDER BY u.USUARIO, m.ORDEN, p.ORDEN;

-- Atajo para reasignarlos todos a una empresa, si el sistema venía usándose con
-- una sola. Revisar el id antes de ejecutar: dejar el permiso en la empresa
-- equivocada da acceso donde no corresponde.
--
--   UPDATE USUARIO_PAGINAS SET ID_EMPRESA = <ID> WHERE ID_EMPRESA IS NULL;
--   COMMIT;
