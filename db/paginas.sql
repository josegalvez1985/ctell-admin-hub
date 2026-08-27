--------------------------------------------------------------------------------
-- CTELL · PAGINAS
--
-- Un paquete (PKG_PAGINAS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicación de los endpoints ORDS. Todo vive
-- dentro del paquete: no hay procedimientos sueltos ni PL/SQL embebido como
-- texto dentro de los handlers.
--
--   1. LISTAR      GET    /paginas/listar
--   2. INSERTAR    POST   /paginas/crear
--   3. ACTUALIZAR  PUT    /paginas/actualizar/:id
--   4. ELIMINAR    DELETE /paginas/eliminar/:id
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES (usa PKG_AUTH
-- para validar el token).
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/paginas/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   PAGINAS  ID_PAGINA, ID_MODULO, NOMBRE, RUTA, ENTRADA, ORDEN, ACTIVO
--
-- RUTA: path del frontend para cargar la página ("/compras/ordenes", etc).
-- Identifica qué componente renderizar en el menú dinámico.
--
-- ENTRADA: tipo de sección donde se agrupa la página: 'D' (Definiciones),
-- 'O' (Operaciones), 'R' (Reportes). Afecta dónde aparece en el menú.
--
-- FK_PAGINA_MODULO: ID_MODULO referencia MODULOS.ID_MODULO. Un ID de módulo
-- inexistente da ORA-02291 en el INSERT/UPDATE, que se traduce a 400 en vez de
-- dejarlo escapar como 500 genérico.
--
-- El listado hace JOIN con MODULOS para devolver también el nombre del módulo:
-- el frontend lo necesita para agrupar y no tendría cómo resolverlo solo.
--
-- ESTADO: ACTIVO es VARCHAR2(1) con 'A' (activo) / 'I' (inactivo), sin
-- traducirse a 1/0 en ningún punto.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO ORDS, no a nivel de workspace. Se
-- declara en PUBLICAR_ENDPOINTS. Ver la explicación completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_PAGINAS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_PAGINAS.LISTAR('Bearer TU_TOKEN', NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_PAGINAS AS

  -- p_id_modulo filtra por módulo. NULL o vacío = todas las páginas.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_modulo     IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_modulo     IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_ruta          IN  VARCHAR2,
    p_entrada       IN  VARCHAR2,
    p_orden         IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Los parámetros ausentes (NULL) no modifican la columna correspondiente.
  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_modulo     IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_ruta          IN  VARCHAR2,
    p_entrada       IN  VARCHAR2,
    p_orden         IN  VARCHAR2,
    p_activo        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el módulo ORDS /paginas/ con sus 4 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_PAGINAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_PAGINAS AS

  ------------------------------------------------------------------------------
  -- Privado: deja la ruta en una sola forma canónica.
  --
  -- El UNIQUE (ID_MODULO, RUTA, ENTRADA) compara strings: para Oracle "/Ventas",
  -- "ventas" y "/ventas/" son tres valores distintos y las tres entrarían como
  -- páginas separadas, con el mismo destino repetido en el menú. Normalizando
  -- antes de guardar, la restricción hace lo que se espera de ella.
  --
  -- Minúsculas porque las rutas del router lo son, barra inicial siempre y final
  -- nunca — salvo la raíz, que es sólo "/".
  FUNCTION NORMALIZAR_RUTA (p_ruta IN VARCHAR2) RETURN VARCHAR2 IS
    l_ruta VARCHAR2(200);
  BEGIN
    l_ruta := LOWER(TRIM(p_ruta));
    IF l_ruta IS NULL THEN RETURN NULL; END IF;
    IF SUBSTR(l_ruta, 1, 1) != '/' THEN l_ruta := '/' || l_ruta; END IF;
    -- RTRIM y no SUBSTR: "/ventas///" tambien tiene que quedar en "/ventas".
    IF LENGTH(l_ruta) > 1 THEN l_ruta := RTRIM(l_ruta, '/'); END IF;
    RETURN NVL(NULLIF(l_ruta, ''), '/');
  END NORMALIZAR_RUTA;

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
         WHERE NAME = 'paginas';

        IF l_existe = 0 THEN
          RETURN;  -- No existía: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'paginas');
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
    p_id_modulo     IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_modulo  NUMBER;
    l_total      NUMBER;
    l_items      CLOB;
  BEGIN
    -- SOLO ADMINISTRADORES: la estructura del menu se administra desde la
    -- pantalla de Administracion, que ya es exclusiva de admins. El menu que ve
    -- cada usuario NO sale de aca sino de /usuario-paginas/listar, asi que
    -- restringir este modulo no deja a nadie sin menu.
    l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 403;
      p_resultado := '{"error":"Se requieren permisos de administrador"}';
      RETURN;
    END IF;

    -- La conversión va acá, dentro del BEGIN: en el DECLARE se ejecutaría
    -- antes de que exista el EXCEPTION y el error escaparía del procedimiento.
    -- NULLIF convierte la cadena vacía del parámetro ausente en NULL antes de
    -- que TO_NUMBER la toque (si no, ORA-01722).
    l_id_modulo := TO_NUMBER(NULLIF(p_id_modulo, ''));

    SELECT COUNT(*)
      INTO l_total
      FROM PAGINAS
     WHERE l_id_modulo IS NULL OR ID_MODULO = l_id_modulo;

    -- El JOIN trae el nombre del módulo: el frontend lo usa para agrupar y no
    -- tendría cómo resolverlo por su cuenta sin otra petición.
    SELECT JSON_ARRAYAGG(
             JSON_OBJECT(
               'id'           VALUE p.ID_PAGINA,
               'idModulo'     VALUE p.ID_MODULO,
               'modulo'       VALUE m.NOMBRE,
               'nombre'       VALUE p.NOMBRE,
               'ruta'         VALUE p.RUTA,
               'entrada'      VALUE p.ENTRADA,
               'orden'        VALUE p.ORDEN,
               'activo'       VALUE UPPER(TRIM(p.ACTIVO))
               RETURNING CLOB
             )
             ORDER BY m.ORDEN, m.NOMBRE, p.ORDEN, p.NOMBRE
             RETURNING CLOB
           )
      INTO l_items
      FROM PAGINAS p
      JOIN MODULOS m ON m.ID_MODULO = p.ID_MODULO
     WHERE l_id_modulo IS NULL OR p.ID_MODULO = l_id_modulo;

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
      APEX_DEBUG.ERROR('PKG_PAGINAS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las paginas"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_modulo     IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_ruta          IN  VARCHAR2,
    p_entrada       IN  VARCHAR2,
    p_orden         IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion    NUMBER;
    l_id_modulo NUMBER;
    l_entrada   VARCHAR2(1);
    l_orden     NUMBER;
    l_id        NUMBER;
    -- La ruta normalizada se resuelve ANTES del INSERT: NORMALIZAR_RUTA es
    -- privada del body y no se puede llamar desde una sentencia SQL
    -- (PLS-00231). En el INSERT va la variable.
    l_ruta      VARCHAR2(200);
  BEGIN
    -- SOLO ADMINISTRADORES: la estructura del menu se administra desde la
    -- pantalla de Administracion, que ya es exclusiva de admins. El menu que ve
    -- cada usuario NO sale de aca sino de /usuario-paginas/listar, asi que
    -- restringir este modulo no deja a nadie sin menu.
    l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 403;
      p_resultado := '{"error":"Se requieren permisos de administrador"}';
      RETURN;
    END IF;

    l_id_modulo := TO_NUMBER(NULLIF(p_id_modulo, ''));
    l_entrada := CASE UPPER(TRIM(p_entrada))
                   WHEN 'D' THEN 'D'
                   WHEN 'O' THEN 'O'
                   WHEN 'R' THEN 'R'
                   ELSE NULL
                 END;

    IF l_id_modulo IS NULL OR TRIM(p_nombre) IS NULL OR TRIM(p_ruta) IS NULL OR l_entrada IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idModulo, nombre, ruta y entrada son obligatorios. entrada debe ser D, O o R"}';
      RETURN;
    END IF;

    -- Orden automático: el siguiente dentro de este módulo Y esta entrada.
    --
    -- Se calcula acá y no en el cliente porque es el único lugar que ve la
    -- tabla entera; el frontend tendría que traerse todas las páginas para
    -- averiguarlo, y dos altas simultáneas se pisarían igual.
    --
    -- El alcance es (módulo, entrada) porque el menú ordena dentro de cada
    -- sección: Reportes de Compras numera aparte de Definiciones de Compras.
    -- Con MAX global, una página nueva en Reportes nacería con un orden que la
    -- manda al fondo de una lista con la que no comparte pantalla.
    --
    -- Un orden explícito gana: sirve para intercalar una página entre dos que
    -- ya existen sin renumerar el resto.
    IF NULLIF(p_orden, '') IS NOT NULL THEN
      l_orden := TO_NUMBER(p_orden);
    ELSE
      -- NVL sobre el MAX, no COUNT: si borraron la última, COUNT reutilizaría
      -- un orden ya usado y dos páginas quedarían empatadas.
      SELECT NVL(MAX(ORDEN), 0) + 1
        INTO l_orden
        FROM PAGINAS
       WHERE ID_MODULO = l_id_modulo
         AND ENTRADA = l_entrada;
    END IF;

    l_ruta := NORMALIZAR_RUTA(p_ruta);

    INSERT INTO PAGINAS (ID_MODULO, NOMBRE, RUTA, ENTRADA, ORDEN, ACTIVO)
    VALUES (
      l_id_modulo,
      TRIM(p_nombre),
      l_ruta,
      l_entrada,
      l_orden,
      'A'
    )
    RETURNING ID_PAGINA INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    -- PAGINAS_UK (ID_MODULO, RUTA, ENTRADA): esa ruta ya está en ese módulo y
    -- esa sección. Sin capturarlo, el ORA-00001 llegaba como un 500 genérico y
    -- el usuario no sabía si era un error suyo o del sistema.
    --
    -- La misma ruta en OTRO módulo sí es válida y no pasa por acá: dos entradas
    -- de menú al mismo destino, para dos perfiles que lo buscan en lugares
    -- distintos.
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Esa ruta ya esta cargada en ese modulo y seccion"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: la FK contra MODULOS no encontró el padre. Es un dato
      -- inválido del cliente (400), no un fallo del servidor.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El modulo indicado no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_PAGINAS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear la pagina"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_modulo     IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_ruta          IN  VARCHAR2,
    p_entrada       IN  VARCHAR2,
    p_orden         IN  VARCHAR2,
    p_activo        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion    NUMBER;
    l_id_modulo NUMBER;
    l_entrada   VARCHAR2(1);
    l_estado    VARCHAR2(1);
    -- Ver la nota en INSERTAR: PLS-00231 si se llama dentro del UPDATE.
    l_ruta      VARCHAR2(200);
  BEGIN
    -- SOLO ADMINISTRADORES: la estructura del menu se administra desde la
    -- pantalla de Administracion, que ya es exclusiva de admins. El menu que ve
    -- cada usuario NO sale de aca sino de /usuario-paginas/listar, asi que
    -- restringir este modulo no deja a nadie sin menu.
    l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 403;
      p_resultado := '{"error":"Se requieren permisos de administrador"}';
      RETURN;
    END IF;

    l_id_modulo := TO_NUMBER(NULLIF(p_id_modulo, ''));
    l_entrada := CASE UPPER(TRIM(p_entrada))
                   WHEN 'D' THEN 'D'
                   WHEN 'O' THEN 'O'
                   WHEN 'R' THEN 'R'
                   ELSE NULL
                 END;

    -- Valor invalido = NULL = no cambiar: es preferible ignorar un código que
    -- no entendemos a escribir basura en la columna.
    l_estado := CASE UPPER(TRIM(p_activo))
                  WHEN 'A' THEN 'A'
                  WHEN 'I' THEN 'I'
                  ELSE NULL
                END;

    l_ruta := NORMALIZAR_RUTA(p_ruta);

    UPDATE PAGINAS
       SET ID_MODULO = NVL(l_id_modulo, ID_MODULO),
           NOMBRE    = NVL(TRIM(p_nombre), NOMBRE),
           RUTA      = NVL(l_ruta, RUTA),
           ENTRADA   = NVL(l_entrada, ENTRADA),
           ORDEN     = NVL(TO_NUMBER(NULLIF(p_orden, '')), ORDEN),
           ACTIVO    = NVL(l_estado, ACTIVO)
     WHERE ID_PAGINA = TO_NUMBER(NULLIF(p_id, ''));

    -- Sin esto, actualizar un ID inexistente devuelve 200 y quien lo usó cree
    -- que guardó.
    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La pagina no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    -- Mover una página a un módulo donde esa ruta ya existe choca con el mismo
    -- UNIQUE que el alta. Ver la nota en INSERTAR.
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Esa ruta ya esta cargada en ese modulo y seccion"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El modulo indicado no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_PAGINAS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar la pagina"}';
      END IF;
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
  BEGIN
    -- SOLO ADMINISTRADORES: la estructura del menu se administra desde la
    -- pantalla de Administracion, que ya es exclusiva de admins. El menu que ve
    -- cada usuario NO sale de aca sino de /usuario-paginas/listar, asi que
    -- restringir este modulo no deja a nadie sin menu.
    l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 403;
      p_resultado := '{"error":"Se requieren permisos de administrador"}';
      RETURN;
    END IF;

    DELETE FROM PAGINAS WHERE ID_PAGINA = TO_NUMBER(NULLIF(p_id, ''));

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La pagina no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_PAGINAS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al eliminar la pagina"}';
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Publica el módulo ORDS /paginas/ con sus 4 endpoints.
  --
  -- Cada handler es una sola línea: invoca al procedimiento del paquete
  -- pasando los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parámetro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahí). Sin
  -- esto, toda petición cross-origin a /paginas/* la rechaza ORDS antes de
  -- llegar a cualquiera de los 4 handlers. Ver la explicación en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'paginas',
      p_base_path      => '/paginas/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'ABM de paginas del sistema'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'paginas',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /paginas/listar
    -- Query param opcional: ?idModulo=  (sin él, devuelve todas)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'paginas', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'paginas',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PAGINAS.LISTAR(:authorization, :idModulo, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'paginas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'paginas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'paginas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /paginas/crear
    -- Body: { idModulo, nombre, ruta, entrada, orden? }
    -- entrada: 'D' (Definiciones), 'O' (Operaciones), 'R' (Reportes)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'paginas', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'paginas',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PAGINAS.INSERTAR(:authorization, :idModulo, :nombre, :ruta, :entrada, :orden, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'paginas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'paginas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'paginas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /paginas/actualizar/:id
    -- Body: { idModulo?, nombre?, ruta?, entrada?, orden?, activo? }  (ausentes = no cambia)
    -- entrada: 'D' (Definiciones), 'O' (Operaciones), 'R' (Reportes)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'paginas', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'paginas',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PAGINAS.ACTUALIZAR(:authorization, :id, :idModulo, :nombre, :ruta, :entrada, :orden, :activo, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'paginas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'paginas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'paginas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /paginas/eliminar/:id
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'paginas', p_pattern => 'eliminar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'paginas',
      p_pattern     => 'eliminar/:id',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PAGINAS.ELIMINAR(:authorization, :id, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'paginas', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'paginas', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'paginas', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_PAGINAS;
/

--------------------------------------------------------------------------------
-- 2. Publicación de los endpoints
--
-- Única sentencia fuera del paquete: la llamada que publica el módulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_PAGINAS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificación
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_PAGINAS'
 ORDER BY OBJECT_TYPE;

-- Si algo salió INVALID arriba, acá está el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_PAGINAS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'paginas';

SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'paginas'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

SELECT p.ID_PAGINA, p.ID_MODULO, m.NOMBRE AS MODULO, p.NOMBRE, p.ORDEN, p.ACTIVO
  FROM PAGINAS p
  JOIN MODULOS m ON m.ID_MODULO = p.ID_MODULO
 ORDER BY m.ORDEN, m.NOMBRE, p.ORDEN, p.NOMBRE;
