--------------------------------------------------------------------------------
-- CTELL · CATEGORIAS
--
-- Un paquete (PKG_CATEGORIAS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicación de los endpoints ORDS. Todo vive
-- dentro del paquete: no hay procedimientos sueltos ni PL/SQL embebido como
-- texto dentro de los handlers.
--
--   1. LISTAR      GET    /categorias/listar        (?idEmpresa= opcional)
--   2. INSERTAR    POST   /categorias/crear
--   3. ACTUALIZAR  PUT    /categorias/actualizar/:id
--   4. ELIMINAR    DELETE /categorias/eliminar/:id/:idEmpresa
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/categorias/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   CATEGORIAS  ID_CATEGORIA, ID_EMPRESA, NOMBRE_CATEGORIA, DESCRIPCION,
--               ACTIVO, FECHA_CREACION, FECHA_ACTUALIZACION
--
-- LA CATEGORIA ES POR EMPRESA. Cada empresa tiene su propio juego de
-- categorías: el idEmpresa sale de la empresa que se eligió al iniciar sesión,
-- no de un combobox del formulario. Por eso el listado se filtra por
-- ?idEmpresa= y el alta lo recibe como dato obligatorio. Mismo criterio que
-- db/monedas.sql y db/unidades-medida.sql.
--
-- SIN JOIN CONTRA EMPRESAS: el listado no devuelve el nombre de la empresa.
-- Viene filtrado por una sola —la de la sesión—, así que ese nombre sería la
-- misma constante repetida en cada fila, y el frontend ya lo tiene en la
-- empresa activa. Mismo criterio aplicado en db/ciudades.sql.
--
-- La FK contra EMPRESAS obliga a que la empresa exista: mandar un idEmpresa
-- inexistente da ORA-02291 en el INSERT/UPDATE, que se traduce a 400 en vez de
-- 500 — el dato es inválido, no falló el servidor.
--
-- El UNIQUE (ID_EMPRESA, NOMBRE_CATEGORIA) impide dos categorías con el mismo
-- nombre dentro de la misma empresa, pero sí permite repetir el nombre entre
-- empresas distintas. El DUP_VAL_ON_INDEX se traduce a 409 con ese matiz en el
-- mensaje. Ojo: acá lo único es el NOMBRE, como en MONEDAS — no la abreviatura,
-- como en UNIDADES_MEDIDA.
--
-- DESCRIPCION es opcional (nullable, hasta 500 caracteres). El INSERT la manda
-- con TRIM, que convierte la cadena vacía en NULL: una categoría sin
-- descripción guarda NULL, no ''.
--
-- ESTADO: ACTIVO es VARCHAR2(1) con 'A' (activo) / 'I' (inactivo). Ese mismo
-- código viaja en el JSON y lo consume el frontend, sin traducirse a 1/0. Acá
-- el DDL ya declara DEFAULT 'A' (a diferencia de ciudades o departamentos, que
-- traen DEFAULT 1 y guardan el literal '1'), pero el INSERT lo escribe
-- explícito igual, como en el resto del proyecto.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicación completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_CATEGORIAS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_CATEGORIAS.LISTAR('Bearer TU_TOKEN', NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_CATEGORIAS AS

  -- p_id_empresa NULL o vacío devuelve las categorías de todas las empresas. En
  -- la app siempre viaja con la empresa de la sesión.
  PROCEDURE LISTAR (
    p_authorization   IN  VARCHAR2,
    p_id_empresa      IN  VARCHAR2,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  );

  PROCEDURE INSERTAR (
    p_authorization    IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_nombre_categoria IN  VARCHAR2,
    p_descripcion      IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  );

  -- Los parámetros ausentes (NULL) no modifican la columna correspondiente.
  PROCEDURE ACTUALIZAR (
    p_authorization    IN  VARCHAR2,
    p_id               IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_nombre_categoria IN  VARCHAR2,
    p_descripcion      IN  VARCHAR2,
    p_activo           IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  );

  -- p_id_empresa es OBLIGATORIO: acota el borrado a la empresa de la sesion.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el módulo ORDS /categorias/ con sus 4 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_CATEGORIAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_CATEGORIAS AS

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
         WHERE NAME = 'categorias';

        IF l_existe = 0 THEN
          RETURN;  -- No existía: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'categorias');
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
    p_authorization   IN  VARCHAR2,
    p_id_empresa      IN  VARCHAR2,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
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

    -- La conversión va acá, dentro del BEGIN: en el DECLARE se ejecutaría
    -- antes de que exista el EXCEPTION y el error escaparía del procedimiento.
    -- NULLIF convierte la cadena vacía del parámetro ausente en NULL antes de
    -- que TO_NUMBER la toque (si no, ORA-01722).
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    SELECT COUNT(*)
      INTO l_total
      FROM CATEGORIAS
     WHERE l_id_empresa IS NULL OR ID_EMPRESA = l_id_empresa;

    -- Sin JOIN: la consulta sale de CATEGORIAS y nada más. El nombre de la
    -- empresa no se devuelve porque el listado ya viene filtrado por una sola
    -- —la de la sesión— y sería la misma constante en todas las filas.
    --
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: con DESCRIPCION de hasta 500 caracteres por fila, ese techo se
    -- alcanza con apenas unas pocas categorías.
    SELECT JSON_ARRAYAGG(fila ORDER BY nombre_categoria RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'               VALUE c.ID_CATEGORIA,
                 'idEmpresa'        VALUE c.ID_EMPRESA,
                 'nombreCategoria'  VALUE c.NOMBRE_CATEGORIA,
                 'descripcion'      VALUE c.DESCRIPCION,
                 'activo'           VALUE CASE UPPER(TRIM(c.ACTIVO))
                                            WHEN 'I' THEN 'I'
                                            WHEN '0' THEN 'I'
                                            ELSE 'A'
                                          END
                 RETURNING CLOB
               ) AS fila,
               c.NOMBRE_CATEGORIA AS nombre_categoria
          FROM CATEGORIAS c
         WHERE l_id_empresa IS NULL OR c.ID_EMPRESA = l_id_empresa
      );

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
      APEX_DEBUG.ERROR('PKG_CATEGORIAS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las categorias"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization    IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_nombre_categoria IN  VARCHAR2,
    p_descripcion      IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_empresa NUMBER;
    l_id         NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    -- La descripción NO se valida: es nullable en el DDL.
    IF l_id_empresa IS NULL OR TRIM(p_nombre_categoria) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa y nombreCategoria son obligatorios"}';
      RETURN;
    END IF;

    -- 'A' explícito aunque el DEFAULT ya sea 'A': es el criterio del proyecto,
    -- para no depender de un default que puede cambiar en el DDL.
    --
    -- TRIM sobre la descripción deja NULL si vino vacía: guardar '' haría que
    -- el frontend muestre una celda en blanco en vez del guión de "sin dato".
    INSERT INTO CATEGORIAS (
      ID_EMPRESA, NOMBRE_CATEGORIA, DESCRIPCION,
      ACTIVO, FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_empresa,
      TRIM(p_nombre_categoria),
      TRIM(p_descripcion),
      'A',
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_CATEGORIA INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- El UNIQUE es (ID_EMPRESA, NOMBRE_CATEGORIA): el choque es dentro de la
      -- misma empresa, no global. El mensaje lo dice para que no parezca que el
      -- nombre está tomado en todos lados.
      p_status_code := 409;
      p_resultado := '{"error":"Esta empresa ya tiene una categoria con ese nombre"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: la FK contra EMPRESAS no encontró el padre. Es un dato
      -- inválido del cliente (400), no un fallo del servidor.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La empresa indicada no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_CATEGORIAS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear la categoria"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization    IN  VARCHAR2,
    p_id               IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_nombre_categoria IN  VARCHAR2,
    p_descripcion      IN  VARCHAR2,
    p_activo           IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id         NUMBER;
    l_id_empresa NUMBER;
    l_estado     VARCHAR2(1);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id         := TO_NUMBER(NULLIF(p_id, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    -- Un valor inválido se ignora en vez de escribirse: es preferible
    -- conservar el estado actual a dejar basura en la columna.
    l_estado := CASE UPPER(TRIM(p_activo))
                  WHEN 'A' THEN 'A'
                  WHEN 'I' THEN 'I'
                  ELSE NULL
                END;

    -- NVL en cada columna: un parámetro ausente conserva el valor actual.
    --
    -- Consecuencia en DESCRIPCION: mandarla vacía significa "no cambiar", NO
    -- "borrar". Es el mismo criterio que el resto del proyecto (ver la
    -- ubicación en db/empresas.sql); si algún día hace falta vaciarla, necesita
    -- un centinela explícito.
    -- AISLAMIENTO POR EMPRESA: el idEmpresa acota A CUAL fila se le aplica el
    -- cambio, no es solo un campo mas a modificar. Sin el WHERE, un PUT con el
    -- id de una fila de OTRA empresa la modificaba igual — la pantalla no lo
    -- permite, pero el endpoint es publico para cualquiera con sesion.
    --
    -- ID_EMPRESA sale del SET a proposito: mover una fila de empresa es lo que
    -- este control busca impedir.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    UPDATE CATEGORIAS
       SET NOMBRE_CATEGORIA    = NVL(TRIM(p_nombre_categoria), NOMBRE_CATEGORIA),
           DESCRIPCION         = NVL(TRIM(p_descripcion), DESCRIPCION),
           ACTIVO              = NVL(l_estado, ACTIVO),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_CATEGORIA = l_id
       AND ID_EMPRESA = l_id_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La categoria no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Esta empresa ya tiene una categoria con ese nombre"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La empresa indicada no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_CATEGORIAS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar la categoria"}';
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

    -- Obligatorio: sin empresa el DELETE alcanzaria filas de cualquiera.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- AISLAMIENTO POR EMPRESA: las dos condiciones. Con solo el id, un DELETE
    -- con el id de una fila de otra empresa la borraba.
    DELETE FROM CATEGORIAS
     WHERE ID_CATEGORIA = l_id
       AND ID_EMPRESA = l_id_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La categoria no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos (productos, subcategorías, lo que cuelgue de la
      -- categoría) apuntando a esta fila. Es un conflicto de estado (409), no
      -- un error del servidor: el dato que mandaron era válido.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de esta categoria"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_CATEGORIAS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar la categoria"}';
      END IF;
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Publica el módulo ORDS /categorias/ con sus 4 endpoints.
  --
  -- Cada handler es una sola línea: invoca al procedimiento del paquete
  -- pasando los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parámetro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahí). Sin
  -- esto, toda petición cross-origin a /categorias/* la rechaza ORDS antes de
  -- llegar a cualquiera de los 4 handlers. Ver la explicación en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'categorias',
      p_base_path      => '/categorias/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'ABM de categorias por empresa'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'categorias',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /categorias/listar?idEmpresa=
    --
    -- idEmpresa no se declara con DEFINE_PARAMETER: los query params se
    -- vinculan solos al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'categorias', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'categorias',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_CATEGORIAS.LISTAR(:authorization, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'categorias', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'categorias', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'categorias', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /categorias/crear
    -- Body: { idEmpresa, nombreCategoria, descripcion? }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'categorias', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'categorias',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_CATEGORIAS.INSERTAR(:authorization, :idEmpresa, :nombreCategoria, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'categorias', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'categorias', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'categorias', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /categorias/actualizar/:id
    -- Body: { idEmpresa?, nombreCategoria?, descripcion?, activo? }
    --       (ausentes = no cambia)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'categorias', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'categorias',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_CATEGORIAS.ACTUALIZAR(:authorization, :id, :idEmpresa, :nombreCategoria, :descripcion, :activo, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'categorias', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'categorias', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'categorias', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /categorias/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'categorias', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'categorias',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_CATEGORIAS.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'categorias', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'categorias', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'categorias', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_CATEGORIAS;
/

--------------------------------------------------------------------------------
-- 2. Publicación de los endpoints
--
-- Única sentencia fuera del paquete: la llamada que publica el módulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_CATEGORIAS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificación
--
-- No hace falta normalizar ACTIVO como en ciudades o departamentos: acá el DDL
-- declara DEFAULT 'A', así que no hay filas con el literal '1'.
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_CATEGORIAS'
 ORDER BY OBJECT_TYPE;

-- Si algo salió INVALID arriba, acá está el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_CATEGORIAS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'categorias';

SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'categorias'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

SELECT c.ID_CATEGORIA, c.ID_EMPRESA, e.NOMBRE_EMPRESA,
       c.NOMBRE_CATEGORIA, c.DESCRIPCION, c.ACTIVO
  FROM CATEGORIAS c
  JOIN EMPRESAS   e ON e.ID_EMPRESA = c.ID_EMPRESA
 ORDER BY e.NOMBRE_EMPRESA, c.NOMBRE_CATEGORIA;
