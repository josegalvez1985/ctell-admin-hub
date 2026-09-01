--------------------------------------------------------------------------------
-- CTELL · MARCAS
--
-- Un paquete (PKG_MARCAS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicacion de los endpoints ORDS.
--
--   1. LISTAR      GET    /marcas/listar        (?busqueda= opcional)
--   2. INSERTAR    POST   /marcas/crear
--   3. ACTUALIZAR  PUT    /marcas/actualizar/:id
--   4. ELIMINAR    DELETE /marcas/eliminar/:id/:idEmpresa
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/marcas/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   MARCAS  ID_MARCA, ID_EMPRESA, DESCRIPCION, FECHA_CREACION,
--           FECHA_ACTUALIZACION
--
--------------------------------------------------------------------------------
-- CUELGA DE LA EMPRESA — Y LAS FILAS VIEJAS NO
--
-- ID_EMPRESA se agrego DESPUES de que la tabla estuviera en uso, asi que el
-- catalogo tiene dos clases de fila:
--
--   - Las de una empresa: ID_EMPRESA cargado. Solo las ve esa empresa.
--   - Las HEREDADAS: ID_EMPRESA en NULL. Las ve TODAS, porque son las que ya
--     estaban cuando la columna no existia.
--
-- Todos los filtros van entonces como:
--
--   (ID_EMPRESA = l_empresa OR ID_EMPRESA IS NULL)
--
-- Con un filtro estricto las heredadas desapareceran del combo de articulos
-- —sin ningun error visible— y los articulos que ya las usan quedarian
-- apuntando a una marca que nadie puede volver a elegir. Es el mismo criterio
-- que db/asistencias-profesores.sql aplica a sus filas previas a la columna.
--
-- OJO CON EL COMMENT DEL DDL: dice "OBLIGATORIO", pero la columna NO tiene
-- NOT NULL y la FK acepta NULL mientras no lo tenga. Un COMMENT no es una
-- restriccion — ver la seccion 3.5.1 de docs/GUIA-IMPLEMENTACION.md.
--
-- El bloque de verificacion del final trae el UPDATE para asignar las
-- heredadas y terminar la migracion.
--
--------------------------------------------------------------------------------
-- NO TIENE COLUMNA ACTIVO, Y ESO CAMBIA EL ABM
--
-- Es la primera tabla del proyecto sin estado: el DDL no trae ACTIVO. En
-- consecuencia NO hay baja logica ni endpoints /activar e /inactivar, y el
-- ELIMINAR es un DELETE fisico.
--
-- Lo que trae eso: no se puede "archivar" una marca que ya no se usa. Si algun
-- dia hace falta, la solucion es agregar ACTIVO VARCHAR2(1) al DDL con 'A'/'I'
-- —como el resto del sistema— y no inventar un estado por otro camino.
--
--------------------------------------------------------------------------------
-- LA DESCRIPCION ES UNICA POR EMPRESA, PERO EL DDL NO LO IMPONE
--
-- La unicidad es POR EMPRESA, no global: dos empresas pueden tener cada una su
-- "Sakura" y son marcas separadas. Sin ese recorte, la segunda empresa que la
-- cargara recibiria un 409 por una fila que ni siquiera puede ver.
--
-- El DDL no declara UNIQUE sobre DESCRIPCION, asi que hoy se pueden cargar dos
-- veces "Sony". El paquete lo verifica a mano antes de insertar y devuelve 409,
-- comparando en MAYUSCULAS y sin espacios de sobra: para Oracle 'Sony' y 'SONY '
-- son distintos, y sin normalizar el control no sirve de nada.
--
-- Es un control de aplicacion, no una restriccion: dos sesiones simultaneas
-- podrian pasar las dos. Si el duplicado importa de verdad, va un
--   CREATE UNIQUE INDEX UX_MARCAS_DESC
--     ON MARCAS (ID_EMPRESA, UPPER(TRIM(DESCRIPCION)));
-- en el DDL —con la empresa adentro, o dos empresas no podrian repetir una
-- marca— y aca se captura el DUP_VAL_ON_INDEX.
--
--------------------------------------------------------------------------------
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_MARCAS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_MARCAS.LISTAR('Bearer TU_TOKEN', NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_MARCAS AS

  -- p_busqueda NULL o vacio devuelve todas. El catalogo es acotado (decenas de
  -- marcas, no miles), asi que no se pagina: ver la nota del final sobre cuando
  -- habria que hacerlo.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
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

  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_MARCAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_MARCAS AS

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
         WHERE NAME = 'marcas';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'marcas');
        COMMIT;
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
          -- ORA-00060 (interbloqueo) y ORA-04020 (lock de objeto) son
          -- transitorios: la otra sesion termina y el reintento pasa.
          --
          -- DBMS_SESSION.SLEEP y NO DBMS_LOCK.SLEEP: este workspace no tiene
          -- GRANT EXECUTE sobre SYS.DBMS_LOCK, y usarlo hace que el BODY no
          -- compile con PLS-00201.
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
  -- Privado: true si ya hay otra marca con esa descripcion EN ESA EMPRESA.
  --
  -- Compara en MAYUSCULAS y sin espacios de sobra: sin normalizar, 'Sony' y
  -- 'SONY ' pasarian como distintas y el control no serviria.
  --
  -- LA UNICIDAD ES POR EMPRESA, no global: dos empresas distintas pueden tener
  -- cada una su "Sakura", y son marcas separadas. Sin el filtro, la segunda
  -- empresa que la cargara recibiria un 409 por una fila que no puede ni ver.
  --
  -- Las marcas heredadas (ID_EMPRESA en NULL) tambien cuentan: el listado las
  -- muestra a todas las empresas, asi que permitir un duplicado dejaria dos
  -- entradas iguales en el mismo combo.
  --
  -- p_id_excluir permite reusarla en el ACTUALIZAR, donde la fila que se esta
  -- editando no debe chocar consigo misma.
  ------------------------------------------------------------------------------
  FUNCTION YA_EXISTE (
    p_descripcion IN VARCHAR2,
    p_id_empresa  IN NUMBER,
    p_id_excluir  IN NUMBER DEFAULT NULL
  ) RETURN BOOLEAN IS
    l_cuenta PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_cuenta
      FROM MARCAS
     WHERE UPPER(TRIM(DESCRIPCION)) = UPPER(TRIM(p_descripcion))
       AND (ID_EMPRESA = p_id_empresa OR ID_EMPRESA IS NULL)
       AND (p_id_excluir IS NULL OR ID_MARCA <> p_id_excluir);

    RETURN l_cuenta > 0;
  END YA_EXISTE;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_empresa  NUMBER;
    l_busqueda VARCHAR2(200);
    l_total    NUMBER;
    l_items    CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Un parametro ausente llega como cadena vacia, no como NULL: NULLIF lo
    -- convierte antes de que el LIKE lo tome como un filtro real.
    l_busqueda := NULLIF(TRIM(p_busqueda), '');
    l_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- EL FILTRO INCLUYE LAS FILAS CON ID_EMPRESA EN NULL.
    --
    -- La columna se agrego despues, asi que todas las marcas cargadas hasta
    -- entonces la tienen vacia. Con un filtro estricto desapareceran del combo
    -- de articulos —sin ningun error— y los articulos que ya las usan quedarian
    -- apuntando a una marca que nadie puede volver a elegir.
    --
    -- Se las trata como HEREDADAS: visibles para todas las empresas hasta que
    -- alguien las asigne. El bloque de verificacion del final trae el UPDATE
    -- para hacerlo.
    SELECT COUNT(*)
      INTO l_total
      FROM MARCAS
     WHERE (ID_EMPRESA = l_empresa OR ID_EMPRESA IS NULL)
       AND (l_busqueda IS NULL
            OR UPPER(DESCRIPCION) LIKE '%' || UPPER(l_busqueda) || '%');

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'          VALUE ID_MARCA,
                 'descripcion' VALUE DESCRIPCION,
                 -- Viaja para que la pantalla pueda distinguir una marca propia
                 -- de una heredada: null es de todas, y editarla la toca para
                 -- las demas empresas tambien.
                 'idEmpresa'   VALUE ID_EMPRESA
                 RETURNING CLOB
               ) AS fila,
               UPPER(DESCRIPCION) AS orden
          FROM MARCAS
         WHERE (ID_EMPRESA = l_empresa OR ID_EMPRESA IS NULL)
           AND (l_busqueda IS NULL
                OR UPPER(DESCRIPCION) LIKE '%' || UPPER(l_busqueda) || '%')
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
      APEX_DEBUG.ERROR('PKG_MARCAS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las marcas"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_empresa NUMBER;
    l_id      NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    IF TRIM(p_descripcion) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"descripcion es obligatoria"}';
      RETURN;
    END IF;

    -- La columna es VARCHAR2(100): se verifica antes para devolver un 400 con
    -- mensaje en vez de un ORA-12899 convertido en 500.
    IF LENGTH(TRIM(p_descripcion)) > 100 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La descripcion no puede superar los 100 caracteres"}';
      RETURN;
    END IF;

    -- Se llama en un IF y no dentro del INSERT: una funcion privada del BODY no
    -- se puede usar en una sentencia SQL (PLS-00231).
    IF YA_EXISTE(p_descripcion, l_empresa) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una marca con esa descripcion"}';
      RETURN;
    END IF;

    -- La empresa se guarda SIEMPRE: las filas con ID_EMPRESA en NULL son las
    -- heredadas de antes de la columna, no algo que este endpoint deba crear.
    INSERT INTO MARCAS (ID_EMPRESA, DESCRIPCION)
    VALUES (l_empresa, TRIM(p_descripcion))
    RETURNING ID_MARCA INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      -- Solo salta si algun dia se agrega el UNIQUE al DDL. Se contempla igual:
      -- sin esto, el duplicado que YA_EXISTE no llegue a ver por una carrera
      -- entre dos sesiones saldria como un 500 sin explicacion.
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una marca con esa descripcion"}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_MARCAS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al crear la marca"}';
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_empresa NUMBER;
    l_id      NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van DENTRO del BEGIN, nunca en el DECLARE: alli correrian
    -- antes de que exista el EXCEPTION y el error escaparia del procedimiento.
    l_id      := TO_NUMBER(NULLIF(p_id, ''));
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    -- El idEmpresa no es un dato mas a guardar: acota A CUAL fila se aplica el
    -- cambio. Sin el, un PUT con el id de otra empresa la modificaria igual.
    IF l_id IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    IF TRIM(p_descripcion) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"descripcion es obligatoria"}';
      RETURN;
    END IF;

    IF LENGTH(TRIM(p_descripcion)) > 100 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La descripcion no puede superar los 100 caracteres"}';
      RETURN;
    END IF;

    -- Excluyendo la propia fila: sin eso, guardar sin cambiar el nombre daria
    -- 409 contra si misma.
    IF YA_EXISTE(p_descripcion, l_empresa, l_id) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otra marca con esa descripcion"}';
      RETURN;
    END IF;

    -- ID_EMPRESA NO va en el SET: poder cambiarla permitiria mover la marca a
    -- otra empresa, que es justo lo que el WHERE impide. Las heredadas (NULL)
    -- se dejan editar desde cualquier empresa: son de todas hasta que alguien
    -- las asigne.
    UPDATE MARCAS
       SET DESCRIPCION         = TRIM(p_descripcion),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_MARCA = l_id
       AND (ID_EMPRESA = l_empresa OR ID_EMPRESA IS NULL);

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      -- 404 y no 403: decir "existe pero es de otra empresa" confirmaria que
      -- el id existe, que es lo que no deberia poder averiguarse.
      p_status_code := 404;
      p_resultado := '{"error":"La marca no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otra marca con esa descripcion"}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_MARCAS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al actualizar la marca"}';
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_empresa NUMBER;
    l_id      NUMBER;
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

    -- Baja FISICA: la tabla no tiene columna de estado, asi que no hay baja
    -- logica posible. Ver la nota del encabezado.
    --
    -- Acotada a la empresa, igual que el UPDATE: sin eso, cualquiera con sesion
    -- podia borrar la marca de otra empresa mandando su id.
    DELETE FROM MARCAS
     WHERE ID_MARCA = l_id
       AND (ID_EMPRESA = l_empresa OR ID_EMPRESA IS NULL);

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La marca no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay filas hijas (una FK apuntando a esta marca). Se traduce a
      -- 409 con un mensaje que dice que hacer, en vez de un 500 mudo. Hoy
      -- ninguna tabla referencia a MARCAS, pero ARTICULOS es el candidato
      -- natural y conviene que el dia que se agregue la FK esto ya funcione.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay articulos que usan esta marca"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_MARCAS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar la marca"}';
      END IF;
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'marcas',
      p_base_path      => '/marcas/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Catalogo global de marcas de articulos'
    );

    -- ORIGINS_ALLOWED es POR MODULO, no del workspace: sin esto ORDS rechaza la
    -- peticion cross-origin ANTES del handler, con un "Service Unavailable" que
    -- ningun WHEN OTHERS puede capturar.
    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'marcas',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /marcas/listar?busqueda=
    --
    -- Los query params se vinculan solos al bind del mismo nombre; no se
    -- declaran con DEFINE_PARAMETER.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'marcas', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'marcas',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MARCAS.LISTAR(:authorization, :idEmpresa, :busqueda, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /marcas/crear
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'marcas', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'marcas',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MARCAS.INSERTAR(:authorization, :idEmpresa, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /marcas/actualizar/:id
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'marcas', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'marcas',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MARCAS.ACTUALIZAR(:authorization, :id, :idEmpresa, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /marcas/eliminar/:id/:idEmpresa
    --
    -- Sin idEmpresa: es un catalogo global, no cuelga de ninguna empresa.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'marcas', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'marcas',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MARCAS.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'marcas', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_MARCAS;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_MARCAS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion — mirar la salida, no alcanza con ejecutar.
--
-- Un paquete INVALID devuelve un 500 mudo: el WHEN OTHERS no captura errores de
-- compilacion porque el PL/SQL nunca llega a ejecutarse.
--------------------------------------------------------------------------------

-- Tiene que decir VALID las dos veces (PACKAGE y PACKAGE BODY).
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_MARCAS'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo. Tiene que volver VACIO.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_MARCAS'
 ORDER BY SEQUENCE;

-- El modulo, con su CORS.
SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'marcas';

-- Cuatro filas: listar GET, crear POST, actualizar/:id PUT,
-- eliminar/:id/:idEmpresa DELETE.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'marcas'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- La columna nueva tiene que estar, o el paquete no compila: el SQL estatico
-- que la nombra falla con ORA-00904 y el BODY queda INVALID.
SELECT COLUMN_NAME, NULLABLE, DATA_TYPE
  FROM USER_TAB_COLUMNS
 WHERE TABLE_NAME = 'MARCAS'
   AND COLUMN_NAME = 'ID_EMPRESA';

-- Cuantas marcas quedaron HEREDADAS (ID_EMPRESA en NULL). El listado las
-- muestra a todas las empresas a proposito, pero conviene asignarlas:
--
--   Si todas las marcas son de una sola empresa:
--     UPDATE MARCAS SET ID_EMPRESA = <id> WHERE ID_EMPRESA IS NULL;
--
--   Si hay varias, se puede deducir por los articulos que las usan:
--     UPDATE MARCAS m SET ID_EMPRESA =
--       (SELECT MIN(a.ID_EMPRESA) FROM ARTICULOS a WHERE a.ID_MARCA = m.ID_MARCA)
--      WHERE m.ID_EMPRESA IS NULL
--        AND EXISTS (SELECT 1 FROM ARTICULOS a WHERE a.ID_MARCA = m.ID_MARCA);
--
-- Una marca usada por articulos de DOS empresas no se puede repartir: hay que
-- duplicarla y reapuntar los articulos de una de ellas.
SELECT COUNT(*) AS TOTAL,
       COUNT(ID_EMPRESA) AS CON_EMPRESA,
       COUNT(*) - COUNT(ID_EMPRESA) AS HEREDADAS
  FROM MARCAS;

-- Marcas usadas por articulos de mas de una empresa: son las que hay que
-- duplicar antes de asignar. Tiene que volver VACIO.
SELECT m.ID_MARCA, m.DESCRIPCION, COUNT(DISTINCT a.ID_EMPRESA) AS EMPRESAS
  FROM MARCAS m
  JOIN ARTICULOS a ON a.ID_MARCA = m.ID_MARCA
 WHERE m.ID_EMPRESA IS NULL
 GROUP BY m.ID_MARCA, m.DESCRIPCION
HAVING COUNT(DISTINCT a.ID_EMPRESA) > 1;

-- Duplicados dentro de una misma empresa. Tiene que volver VACIO; si trae
-- filas, hay que unificarlas a mano antes de agregar el UNIQUE al DDL.
SELECT ID_EMPRESA, UPPER(TRIM(DESCRIPCION)) AS DESCRIPCION, COUNT(*) AS VECES
  FROM MARCAS
 GROUP BY ID_EMPRESA, UPPER(TRIM(DESCRIPCION))
HAVING COUNT(*) > 1
 ORDER BY VECES DESC;

-- El catalogo, para confirmar que el listado devuelve lo esperado.
SELECT ID_MARCA, ID_EMPRESA, DESCRIPCION, FECHA_CREACION
  FROM MARCAS
 ORDER BY ID_EMPRESA NULLS FIRST, UPPER(DESCRIPCION);
