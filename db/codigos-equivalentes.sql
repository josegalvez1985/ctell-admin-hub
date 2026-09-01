--------------------------------------------------------------------------------
-- CTELL · CODIGOS EQUIVALENTES
--
-- Un paquete (PKG_CODIGOS_EQUIVALENTES) con los 4 procedimientos — LISTAR,
-- INSERTAR, ACTUALIZAR, ELIMINAR — y la publicacion de los endpoints ORDS.
--
--   1. LISTAR      GET    /codigos-equivalentes/listar
--                         (?idEmpresa= OBLIGATORIO, &idArticulo= &busqueda=)
--   2. INSERTAR    POST   /codigos-equivalentes/crear
--   3. ACTUALIZAR  PUT    /codigos-equivalentes/actualizar/:id
--   4. ELIMINAR    DELETE /codigos-equivalentes/eliminar/:id/:idEmpresa
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX. REQUIERE
-- db/auth.sql EJECUTADO ANTES: usa PKG_AUTH para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/codigos-equivalentes/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   CODIGOS_EQUIVALENTES  ID_CODIGO_EQUIVALENTE, ID_EMPRESA, ID_ARTICULO,
--                         CODIGO_EQUIVALENTE, DESCRIPCION,
--                         FECHA_CREACION, FECHA_ACTUALIZACION
--
--------------------------------------------------------------------------------
-- QUE RESUELVE
--
-- Un repuesto se pide por el codigo del fabricante, por el del proveedor o por
-- el que figura en el catalogo del vehiculo, y casi nunca por el codigo interno.
-- Esta tabla guarda todos esos alias contra un mismo articulo, para poder
-- encontrarlo por cualquiera de ellos.
--
-- Es una relacion 1:N con ARTICULOS: un articulo tiene varios codigos, cada
-- codigo pertenece a un solo articulo. Por eso vive en su propia tabla y no
-- como columnas del articulo — no se sabe cuantos van a ser.
--
--------------------------------------------------------------------------------
-- EL CODIGO SE GUARDA NORMALIZADO, O EL UNIQUE NO SIRVE
--
-- El DDL trae UNIQUE (ID_EMPRESA, ID_ARTICULO, CODIGO_EQUIVALENTE), pero para
-- Oracle 'ABC-123', 'abc-123' y 'ABC-123 ' son TRES valores distintos: el
-- indice los deja pasar a los tres y el mismo repuesto queda cargado por
-- triplicado.
--
-- Se guarda entonces en MAYUSCULAS y sin espacios de sobra. Es lo que hace
-- PKG_PAGINAS con las rutas, por el mismo motivo (ver la seccion 3.8 de
-- docs/GUIA-IMPLEMENTACION.md).
--
-- Un codigo de repuesto es case-insensitive en la practica —nadie distingue
-- 'ngk' de 'NGK'—, asi que subirlo a mayusculas no pierde informacion. Si algun
-- dia hiciera falta conservar como se escribio, va una columna aparte para el
-- texto original y el UNIQUE sigue sobre el normalizado.
--
--------------------------------------------------------------------------------
-- EL MISMO CODIGO PUEDE ESTAR EN DOS ARTICULOS
--
-- El UNIQUE incluye ID_ARTICULO, asi que 'W-712' puede apuntar a dos articulos
-- distintos. Es a proposito: dos filtros diferentes pueden compartir el codigo
-- de un fabricante que los declara equivalentes, y decidir cual usar es del
-- vendedor, no de la base.
--
-- Por eso la busqueda por codigo devuelve una LISTA y no un articulo.
--
--------------------------------------------------------------------------------
-- FILTRO POR EMPRESA
--
-- ID_EMPRESA es NOT NULL en el DDL, asi que aca NO hace falta contemplar filas
-- heredadas como en MARCAS o en ASISTENCIAS_PROFESORES: el filtro es directo.
--
-- Ademas se valida que el ARTICULO sea de la misma empresa: la FK garantiza que
-- exista, no de quien es. Sin ese control se podrian colgar codigos de la
-- empresa A sobre un articulo de la B.
--
--------------------------------------------------------------------------------
-- NO TIENE COLUMNA ACTIVO
--
-- Igual que MARCAS: el DDL no trae ACTIVO, asi que no hay baja logica ni
-- endpoints /activar e /inactivar, y el ELIMINAR es un DELETE fisico. Un codigo
-- equivalente que ya no aplica se borra — no hay nada que archivar.
--
--------------------------------------------------------------------------------
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_CODIGOS_EQUIVALENTES AS

  ------------------------------------------------------------------------------
  -- Codigos equivalentes de la empresa.
  --
  -- Con p_id_articulo: los de ESE articulo, que es lo que pide la ficha.
  -- Sin el y con p_busqueda: los que coinciden con el codigo en toda la
  -- empresa, para responder "que articulo es este codigo de fabricante".
  ------------------------------------------------------------------------------
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE INSERTAR (
    p_authorization      IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_id_articulo        IN  VARCHAR2,
    p_codigo_equivalente IN  VARCHAR2,
    p_descripcion        IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  );

  -- El articulo NO se puede cambiar: mover un codigo de un articulo a otro es
  -- borrarlo y crearlo, y asi el UNIQUE se evalua contra el articulo correcto.
  PROCEDURE ACTUALIZAR (
    p_authorization      IN  VARCHAR2,
    p_id                 IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_codigo_equivalente IN  VARCHAR2,
    p_descripcion        IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_CODIGOS_EQUIVALENTES;
/

CREATE OR REPLACE PACKAGE BODY PKG_CODIGOS_EQUIVALENTES AS

  ------------------------------------------------------------------------------
  -- Privado: borra el modulo ORDS si existe, reintentando ante un interbloqueo.
  -- Nunca `WHEN OTHERS THEN NULL`: se tragaria un ORA-00060 y el DEFINE_MODULE
  -- de despues moriria con ORA-00001 contra el modulo que no se llego a borrar.
  ------------------------------------------------------------------------------
  PROCEDURE BORRAR_MODULO IS
    C_INTENTOS CONSTANT PLS_INTEGER := 3;
    l_existe   PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. C_INTENTOS LOOP
      BEGIN
        SELECT COUNT(*)
          INTO l_existe
          FROM USER_ORDS_MODULES
         WHERE NAME = 'codigos-equivalentes';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'codigos-equivalentes');
        COMMIT;
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
          -- ORA-00060 (interbloqueo) y ORA-04020 (lock de objeto) son
          -- transitorios: la otra sesion termina y el reintento pasa.
          --
          -- DBMS_SESSION.SLEEP y NO DBMS_LOCK.SLEEP: este workspace no tiene
          -- GRANT EXECUTE sobre SYS.DBMS_LOCK.
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
  -- Privado: el codigo tal como se guarda.
  --
  -- MAYUSCULAS y sin espacios de sobra. Sin esto el UNIQUE del DDL no aplica:
  -- 'abc' y 'ABC ' entrarian como dos codigos distintos del mismo articulo.
  ------------------------------------------------------------------------------
  FUNCTION NORMALIZAR (p_codigo IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN UPPER(TRIM(p_codigo));
  END NORMALIZAR;

  ------------------------------------------------------------------------------
  -- Privado: true si ese articulo existe y es de esa empresa.
  --
  -- La FK garantiza que el articulo exista, NO de quien es: sin este control se
  -- podrian colgar codigos de la empresa A sobre un articulo de la B. Es el
  -- mismo criterio que PKG_ASISTENCIAS_PROFESORES.VALIDAR_COHERENCIA.
  ------------------------------------------------------------------------------
  FUNCTION ARTICULO_VALIDO (p_id_articulo IN NUMBER, p_id_empresa IN NUMBER)
    RETURN BOOLEAN IS
    l_cuenta PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_cuenta
      FROM ARTICULOS
     WHERE ID_ARTICULO = p_id_articulo
       AND ID_EMPRESA  = p_id_empresa;

    RETURN l_cuenta > 0;
  END ARTICULO_VALIDO;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion    NUMBER;
    l_empresa   NUMBER;
    l_articulo  NUMBER;
    l_busqueda  VARCHAR2(200);
    l_total     NUMBER;
    l_items     CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van DENTRO del BEGIN: en el DECLARE correrian antes de
    -- que exista el EXCEPTION y el error escaparia del procedimiento. NULLIF
    -- convierte la cadena vacia del parametro ausente en NULL antes de que
    -- TO_NUMBER la toque (si no, ORA-01722).
    l_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_articulo := TO_NUMBER(NULLIF(p_id_articulo, ''));

    -- El termino se sube a mayusculas UNA vez, no por fila: el WHERE compara
    -- contra el codigo ya normalizado, que se guarda en mayusculas.
    l_busqueda := NORMALIZAR(NULLIF(p_busqueda, ''));

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    SELECT COUNT(*)
      INTO l_total
      FROM CODIGOS_EQUIVALENTES c
     WHERE c.ID_EMPRESA = l_empresa
       AND (l_articulo IS NULL OR c.ID_ARTICULO = l_articulo)
       AND (l_busqueda IS NULL
            OR c.CODIGO_EQUIVALENTE LIKE '%' || l_busqueda || '%'
            OR UPPER(c.DESCRIPCION)  LIKE '%' || l_busqueda || '%');

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'                 VALUE c.ID_CODIGO_EQUIVALENTE,
                 'idEmpresa'          VALUE c.ID_EMPRESA,
                 'idArticulo'         VALUE c.ID_ARTICULO,
                 -- El nombre del articulo viene del JOIN: la busqueda por codigo
                 -- necesita mostrar A QUE articulo llego, y sin esto el frontend
                 -- tendria que pedirlo por cada fila.
                 'articulo'           VALUE a.NOMBRE_ARTICULO,
                 'codigoArticulo'     VALUE a.CODIGO_ARTICULO,
                 'codigoEquivalente'  VALUE c.CODIGO_EQUIVALENTE,
                 'descripcion'        VALUE c.DESCRIPCION
                 RETURNING CLOB
               ) AS fila,
               c.CODIGO_EQUIVALENTE AS orden
          FROM CODIGOS_EQUIVALENTES c
          -- JOIN interno y no LEFT: ID_ARTICULO es NOT NULL con FK, asi que la
          -- fila huerfana no puede existir. Si algun dia existiera, que no
          -- aparezca es correcto: un codigo sin articulo no significa nada.
          JOIN ARTICULOS a ON a.ID_ARTICULO = c.ID_ARTICULO
         WHERE c.ID_EMPRESA = l_empresa
           AND (l_articulo IS NULL OR c.ID_ARTICULO = l_articulo)
           AND (l_busqueda IS NULL
                OR c.CODIGO_EQUIVALENTE LIKE '%' || l_busqueda || '%'
                OR UPPER(c.DESCRIPCION)  LIKE '%' || l_busqueda || '%')
      );

    p_status_code := 200;
    -- SELECT ... INTO y no una asignacion directa: `RETURNING CLOB` no se
    -- acepta en una expresion PL/SQL suelta (PLS-00684).
    --
    -- NVL sobre l_items: JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un
    -- array vacio, y el frontend reventaria al iterar "items":null.
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
      APEX_DEBUG.ERROR('PKG_CODIGOS_EQUIVALENTES.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los codigos equivalentes"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization      IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_id_articulo        IN  VARCHAR2,
    p_codigo_equivalente IN  VARCHAR2,
    p_descripcion        IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_empresa  NUMBER;
    l_articulo NUMBER;
    l_codigo   VARCHAR2(100);
    l_id       NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_articulo := TO_NUMBER(NULLIF(p_id_articulo, ''));

    -- Se calcula en una variable y no dentro del INSERT: una funcion privada
    -- del BODY no se puede llamar desde una sentencia SQL (PLS-00231).
    l_codigo   := NORMALIZAR(p_codigo_equivalente);

    IF l_empresa IS NULL OR l_articulo IS NULL OR l_codigo IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, idArticulo y codigoEquivalente son obligatorios"}';
      RETURN;
    END IF;

    -- La columna es VARCHAR2(100): se verifica antes para devolver un 400 con
    -- mensaje en vez de un ORA-12899 convertido en 500.
    IF LENGTH(l_codigo) > 100 THEN
      p_status_code := 400;
      p_resultado := '{"error":"El codigo no puede superar los 100 caracteres"}';
      RETURN;
    END IF;

    IF LENGTH(TRIM(p_descripcion)) > 200 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La descripcion no puede superar los 200 caracteres"}';
      RETURN;
    END IF;

    IF NOT ARTICULO_VALIDO(l_articulo, l_empresa) THEN
      p_status_code := 400;
      p_resultado := '{"error":"El articulo no existe o no pertenece a esta empresa"}';
      RETURN;
    END IF;

    INSERT INTO CODIGOS_EQUIVALENTES (
      ID_EMPRESA, ID_ARTICULO, CODIGO_EQUIVALENTE, DESCRIPCION,
      FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_empresa, l_articulo, l_codigo, TRIM(p_descripcion),
      SYSTIMESTAMP, SYSTIMESTAMP
    )
    RETURNING ID_CODIGO_EQUIVALENTE INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      -- El UNIQUE (ID_EMPRESA, ID_ARTICULO, CODIGO_EQUIVALENTE) del DDL. Se
      -- traduce a un 409 que dice que paso, en vez de un 500 mudo.
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ese codigo ya esta cargado para este articulo"}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_CODIGOS_EQUIVALENTES.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al crear el codigo equivalente"}';
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization      IN  VARCHAR2,
    p_id                 IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_codigo_equivalente IN  VARCHAR2,
    p_descripcion        IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_id      NUMBER;
    l_empresa NUMBER;
    l_codigo  VARCHAR2(100);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id      := TO_NUMBER(NULLIF(p_id, ''));
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_codigo  := NORMALIZAR(p_codigo_equivalente);

    -- El idEmpresa no es un dato mas a guardar: acota A CUAL fila se aplica el
    -- cambio. Sin el, un PUT con el id de otra empresa la modificaria igual.
    IF l_id IS NULL OR l_empresa IS NULL OR l_codigo IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id, idEmpresa y codigoEquivalente son obligatorios"}';
      RETURN;
    END IF;

    IF LENGTH(l_codigo) > 100 THEN
      p_status_code := 400;
      p_resultado := '{"error":"El codigo no puede superar los 100 caracteres"}';
      RETURN;
    END IF;

    IF LENGTH(TRIM(p_descripcion)) > 200 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La descripcion no puede superar los 200 caracteres"}';
      RETURN;
    END IF;

    -- ID_ARTICULO no va en el SET: mover un codigo de articulo es borrarlo y
    -- crearlo. Ver la nota del spec.
    UPDATE CODIGOS_EQUIVALENTES
       SET CODIGO_EQUIVALENTE  = l_codigo,
           DESCRIPCION         = TRIM(p_descripcion),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_CODIGO_EQUIVALENTE = l_id
       AND ID_EMPRESA            = l_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      -- 404 y no 403: decir "existe pero es de otra empresa" confirmaria que el
      -- id existe, que es lo que no deberia poder averiguarse.
      p_status_code := 404;
      p_resultado := '{"error":"El codigo equivalente no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ese codigo ya esta cargado para este articulo"}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_CODIGOS_EQUIVALENTES.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al actualizar el codigo equivalente"}';
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_id      NUMBER;
    l_empresa NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id      := TO_NUMBER(NULLIF(p_id, ''));
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    IF l_id IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    -- Baja FISICA: la tabla no tiene columna de estado. Nada cuelga de un
    -- codigo equivalente, asi que no hay nada que revertir ni que rechazar.
    DELETE FROM CODIGOS_EQUIVALENTES
     WHERE ID_CODIGO_EQUIVALENTE = l_id
       AND ID_EMPRESA            = l_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El codigo equivalente no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_CODIGOS_EQUIVALENTES.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al eliminar el codigo equivalente"}';
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'codigos-equivalentes',
      p_base_path      => '/codigos-equivalentes/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Codigos equivalentes de repuestos por articulo'
    );

    -- ORIGINS_ALLOWED es POR MODULO, no del workspace: sin esto ORDS rechaza la
    -- peticion cross-origin ANTES del handler, con un "Service Unavailable" que
    -- ningun WHEN OTHERS puede capturar.
    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'codigos-equivalentes',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /codigos-equivalentes/listar?idEmpresa=&idArticulo=&busqueda=
    --
    -- Los query params se vinculan solos al bind del mismo nombre; no se
    -- declaran con DEFINE_PARAMETER.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'codigos-equivalentes', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'codigos-equivalentes',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_CODIGOS_EQUIVALENTES.LISTAR(:authorization, :idEmpresa, :idArticulo, :busqueda, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'codigos-equivalentes', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'codigos-equivalentes', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'codigos-equivalentes', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /codigos-equivalentes/crear
    --
    -- Los campos del JSON llegan SUELTOS, no como :body — ese bind trae el
    -- payload crudo como BLOB y JSON_VALUE sobre el devuelve NULL en todos los
    -- campos. Ver la seccion 3 de docs/GUIA-IMPLEMENTACION.md.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'codigos-equivalentes', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'codigos-equivalentes',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_CODIGOS_EQUIVALENTES.INSERTAR(:authorization, :idEmpresa, :idArticulo, :codigoEquivalente, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'codigos-equivalentes', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'codigos-equivalentes', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'codigos-equivalentes', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /codigos-equivalentes/actualizar/:id
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'codigos-equivalentes', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'codigos-equivalentes',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_CODIGOS_EQUIVALENTES.ACTUALIZAR(:authorization, :id, :idEmpresa, :codigoEquivalente, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'codigos-equivalentes', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'codigos-equivalentes', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'codigos-equivalentes', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /codigos-equivalentes/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(
      p_module_name => 'codigos-equivalentes', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'codigos-equivalentes',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_CODIGOS_EQUIVALENTES.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'codigos-equivalentes', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'codigos-equivalentes', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'codigos-equivalentes', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_CODIGOS_EQUIVALENTES;
/

BEGIN
  PKG_CODIGOS_EQUIVALENTES.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- VERIFICACION — mirar la salida, no alcanza con ejecutar.
-- Un paquete INVALID devuelve un 500 mudo: el WHEN OTHERS no captura errores de
-- compilacion porque el PL/SQL nunca llega a ejecutarse.
--------------------------------------------------------------------------------

-- Tiene que decir VALID las dos veces (PACKAGE y PACKAGE BODY).
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_CODIGOS_EQUIVALENTES'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo. Tiene que volver VACIO.
SELECT LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_CODIGOS_EQUIVALENTES'
 ORDER BY SEQUENCE;

-- La tabla tiene que existir, o el SQL estatico que la nombra falla con
-- ORA-00942 y el BODY queda INVALID.
SELECT COLUMN_NAME, NULLABLE, DATA_TYPE, DATA_LENGTH
  FROM USER_TAB_COLUMNS
 WHERE TABLE_NAME = 'CODIGOS_EQUIVALENTES'
 ORDER BY COLUMN_ID;

-- El modulo, con su CORS.
SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'codigos-equivalentes';

-- Cuatro filas: listar GET, crear POST, actualizar/:id PUT,
-- eliminar/:id/:idEmpresa DELETE.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'codigos-equivalentes'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- Codigos que quedaron SIN normalizar, de una carga anterior a este paquete.
-- Tiene que volver VACIO: si trae filas, el UNIQUE no las esta protegiendo y
-- puede haber duplicados que solo se diferencian por mayusculas o espacios.
--
-- Para normalizarlas:
--   UPDATE CODIGOS_EQUIVALENTES
--      SET CODIGO_EQUIVALENTE = UPPER(TRIM(CODIGO_EQUIVALENTE))
--    WHERE CODIGO_EQUIVALENTE != UPPER(TRIM(CODIGO_EQUIVALENTE));
-- Si eso choca contra el UNIQUE, hay duplicados reales que hay que borrar
-- primero — la consulta de abajo los encuentra.
SELECT ID_CODIGO_EQUIVALENTE, CODIGO_EQUIVALENTE
  FROM CODIGOS_EQUIVALENTES
 WHERE CODIGO_EQUIVALENTE != UPPER(TRIM(CODIGO_EQUIVALENTE));

-- Duplicados que solo se diferencian por mayusculas o espacios. Tiene que
-- volver VACIO.
SELECT ID_EMPRESA, ID_ARTICULO, UPPER(TRIM(CODIGO_EQUIVALENTE)) AS CODIGO, COUNT(*) AS VECES
  FROM CODIGOS_EQUIVALENTES
 GROUP BY ID_EMPRESA, ID_ARTICULO, UPPER(TRIM(CODIGO_EQUIVALENTE))
HAVING COUNT(*) > 1;

-- Los articulos con mas codigos equivalentes, para confirmar que el listado
-- devuelve lo esperado.
SELECT a.NOMBRE_ARTICULO, COUNT(*) AS CODIGOS
  FROM CODIGOS_EQUIVALENTES c
  JOIN ARTICULOS a ON a.ID_ARTICULO = c.ID_ARTICULO
 GROUP BY a.NOMBRE_ARTICULO
 ORDER BY CODIGOS DESC, a.NOMBRE_ARTICULO;
