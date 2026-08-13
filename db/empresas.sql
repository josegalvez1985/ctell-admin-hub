--------------------------------------------------------------------------------
-- CTELL · EMPRESAS
--
-- Un paquete (PKG_EMPRESAS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicación de los endpoints ORDS. Todo vive
-- dentro del paquete: no hay procedimientos sueltos ni PL/SQL embebido como
-- texto dentro de los handlers.
--
--   1. LISTAR      GET    /empresas/listar        (?idCiudad= opcional)
--   2. INSERTAR    POST   /empresas/crear
--   3. ACTUALIZAR  PUT    /empresas/actualizar/:id
--   4. ELIMINAR    DELETE /empresas/eliminar/:id
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/empresas/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   EMPRESAS  ID_EMPRESA, NOMBRE_EMPRESA, RUC,
--             CORREO_EMPRESA, TELEFONO, DIRECCION,
--             ID_CIUDAD, ID_DEPARTAMENTO, ID_PAIS,
--             MONEDA_DEFECTO, LOGO, REPRESENTANTE_LEGAL,
--             FECHA_CREACION, FECHA_ACTUALIZACION, ACTIVO
--
-- LOGO (BLOB) queda FUERA de este CRUD a propósito: subir y servir un binario
-- por ORDS necesita endpoints aparte (multipart y un handler que devuelva el
-- contenido con su content-type). Se agrega después sin tocar nada de esto.
--
-- UBICACIÓN: la tabla guarda ID_PAIS, ID_DEPARTAMENTO e ID_CIUDAD, que son
-- redundantes entre sí (la ciudad ya implica departamento y país). Se guardan
-- los tres porque el DDL los pide, y el frontend los completa con tres
-- combobox en cascada. Las tres FK son NULLABLE: una empresa puede cargarse
-- sin dirección todavía.
--
-- UNIQUE en RUC: el choque se traduce a 409. Se consulta antes de insertar
-- para dar un mensaje que nombre el campo, porque DUP_VAL_ON_INDEX no dice
-- cuál índice falló.
--
-- ESTADO: ACTIVO es VARCHAR2(1) con 'A' (activo) / 'I' (inactivo), igual que
-- el resto de las tablas, y el DDL ya lo declara con DEFAULT 'A'. Aun así el
-- INSERT lo escribe explícito, como en el resto del proyecto.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicación completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_EMPRESAS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_EMPRESAS.LISTAR('Bearer TU_TOKEN', NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_EMPRESAS AS

  -- p_id_ciudad NULL o vacío devuelve las empresas de todas las ciudades.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_ciudad     IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE INSERTAR (
    p_authorization       IN  VARCHAR2,
    p_nombre_empresa      IN  VARCHAR2,
    p_ruc                 IN  VARCHAR2,
    p_correo_empresa      IN  VARCHAR2,
    p_telefono            IN  VARCHAR2,
    p_direccion           IN  VARCHAR2,
    p_id_ciudad           IN  VARCHAR2,
    p_id_departamento     IN  VARCHAR2,
    p_id_pais             IN  VARCHAR2,
    p_moneda_defecto      IN  VARCHAR2,
    p_representante_legal IN  VARCHAR2,
    p_status_code         OUT NUMBER,
    p_resultado           OUT CLOB
  );

  -- Los parámetros ausentes (NULL) no modifican la columna correspondiente.
  PROCEDURE ACTUALIZAR (
    p_authorization       IN  VARCHAR2,
    p_id                  IN  VARCHAR2,
    p_nombre_empresa      IN  VARCHAR2,
    p_ruc                 IN  VARCHAR2,
    p_correo_empresa      IN  VARCHAR2,
    p_telefono            IN  VARCHAR2,
    p_direccion           IN  VARCHAR2,
    p_id_ciudad           IN  VARCHAR2,
    p_id_departamento     IN  VARCHAR2,
    p_id_pais             IN  VARCHAR2,
    p_moneda_defecto      IN  VARCHAR2,
    p_representante_legal IN  VARCHAR2,
    p_activo              IN  VARCHAR2,
    p_status_code         OUT NUMBER,
    p_resultado           OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el módulo ORDS /empresas/ con sus 4 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_EMPRESAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_EMPRESAS AS

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
         WHERE NAME = 'empresas';

        IF l_existe = 0 THEN
          RETURN;  -- No existía: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'empresas');
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
    p_id_ciudad     IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion    NUMBER;
    l_id_ciudad NUMBER;
    l_total     NUMBER;
    l_items     CLOB;
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
    l_id_ciudad := TO_NUMBER(NULLIF(p_id_ciudad, ''));

    SELECT COUNT(*)
      INTO l_total
      FROM EMPRESAS
     WHERE l_id_ciudad IS NULL OR ID_CIUDAD = l_id_ciudad;

    -- LEFT JOIN, no JOIN: las tres FK de ubicación son NULLABLE, así que con
    -- el interno una empresa sin ciudad cargada desaparecería del listado.
    --
    -- Se devuelven los ids Y los nombres de los tres niveles: el formulario
    -- necesita los ids para precargar los combobox, y la tabla los nombres
    -- para mostrarlos. Traer sólo el nombre obligaría a otra petición.
    --
    -- LOGO no se selecciona: es un BLOB y no entra en el JSON.
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: el listado anda con pocas filas y devuelve 500 cuando crece.
    SELECT JSON_ARRAYAGG(fila ORDER BY nombre_empresa RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'                  VALUE e.ID_EMPRESA,
                 'nombreEmpresa'       VALUE e.NOMBRE_EMPRESA,
                 'ruc'                 VALUE e.RUC,
                 'correoEmpresa'       VALUE e.CORREO_EMPRESA,
                 'telefono'            VALUE e.TELEFONO,
                 'direccion'           VALUE e.DIRECCION,
                 'idCiudad'            VALUE e.ID_CIUDAD,
                 'ciudad'              VALUE c.NOMBRE_CIUDAD,
                 'idDepartamento'      VALUE e.ID_DEPARTAMENTO,
                 'departamento'        VALUE d.NOMBRE_DEPARTAMENTO,
                 'idPais'              VALUE e.ID_PAIS,
                 'pais'                VALUE p.NOMBRE_PAIS,
                 'monedaDefecto'       VALUE e.MONEDA_DEFECTO,
                 'representanteLegal'  VALUE e.REPRESENTANTE_LEGAL,
                 'activo'              VALUE CASE UPPER(TRIM(e.ACTIVO))
                                               WHEN 'I' THEN 'I'
                                               WHEN '0' THEN 'I'
                                               ELSE 'A'
                                             END
                 RETURNING CLOB
               ) AS fila,
               e.NOMBRE_EMPRESA AS nombre_empresa
          FROM EMPRESAS e
          LEFT JOIN CIUDADES      c ON c.ID_CIUDAD       = e.ID_CIUDAD
          LEFT JOIN DEPARTAMENTOS d ON d.ID_DEPARTAMENTO = e.ID_DEPARTAMENTO
          LEFT JOIN PAISES        p ON p.ID_PAIS         = e.ID_PAIS
         WHERE l_id_ciudad IS NULL OR e.ID_CIUDAD = l_id_ciudad
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
      APEX_DEBUG.ERROR('PKG_EMPRESAS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las empresas"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization       IN  VARCHAR2,
    p_nombre_empresa      IN  VARCHAR2,
    p_ruc                 IN  VARCHAR2,
    p_correo_empresa      IN  VARCHAR2,
    p_telefono            IN  VARCHAR2,
    p_direccion           IN  VARCHAR2,
    p_id_ciudad           IN  VARCHAR2,
    p_id_departamento     IN  VARCHAR2,
    p_id_pais             IN  VARCHAR2,
    p_moneda_defecto      IN  VARCHAR2,
    p_representante_legal IN  VARCHAR2,
    p_status_code         OUT NUMBER,
    p_resultado           OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_id       NUMBER;
    l_repetido NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    IF TRIM(p_nombre_empresa) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"nombreEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- El UNIQUE se consulta antes de insertar para poder nombrar el campo en
    -- el mensaje: DUP_VAL_ON_INDEX no informa qué índice falló.
    IF TRIM(p_ruc) IS NOT NULL THEN
      SELECT COUNT(*) INTO l_repetido
        FROM EMPRESAS WHERE UPPER(RUC) = UPPER(TRIM(p_ruc));
      IF l_repetido > 0 THEN
        p_status_code := 409;
        p_resultado := '{"error":"Ya existe una empresa con ese RUC"}';
        RETURN;
      END IF;
    END IF;

    -- 'A' explícito, y la moneda cae en PYG si no la mandan (el mismo default
    -- que declara el DDL, repetido acá para no depender de él).
    INSERT INTO EMPRESAS (
      NOMBRE_EMPRESA, RUC, CORREO_EMPRESA, TELEFONO, DIRECCION,
      ID_CIUDAD, ID_DEPARTAMENTO, ID_PAIS, MONEDA_DEFECTO, REPRESENTANTE_LEGAL,
      ACTIVO, FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      TRIM(p_nombre_empresa),
      TRIM(p_ruc),
      TRIM(p_correo_empresa),
      TRIM(p_telefono),
      TRIM(p_direccion),
      TO_NUMBER(NULLIF(p_id_ciudad, '')),
      TO_NUMBER(NULLIF(p_id_departamento, '')),
      TO_NUMBER(NULLIF(p_id_pais, '')),
      NVL(UPPER(TRIM(p_moneda_defecto)), 'PYG'),
      TRIM(p_representante_legal),
      'A',
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_EMPRESA INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      -- Red de seguridad: si dos altas simultáneas pasan el chequeo de arriba,
      -- el índice las frena igual. Acá ya no se sabe cuál de los dos fue.
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una empresa con ese RUC"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: alguna de las tres FK de ubicación no encontró el padre.
      -- Es un dato inválido del cliente (400), no un fallo del servidor.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El pais, departamento o ciudad indicado no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_EMPRESAS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear la empresa"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization       IN  VARCHAR2,
    p_id                  IN  VARCHAR2,
    p_nombre_empresa      IN  VARCHAR2,
    p_ruc                 IN  VARCHAR2,
    p_correo_empresa      IN  VARCHAR2,
    p_telefono            IN  VARCHAR2,
    p_direccion           IN  VARCHAR2,
    p_id_ciudad           IN  VARCHAR2,
    p_id_departamento     IN  VARCHAR2,
    p_id_pais             IN  VARCHAR2,
    p_moneda_defecto      IN  VARCHAR2,
    p_representante_legal IN  VARCHAR2,
    p_activo              IN  VARCHAR2,
    p_status_code         OUT NUMBER,
    p_resultado           OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_id       NUMBER;
    l_estado   VARCHAR2(1);
    l_repetido NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id := TO_NUMBER(NULLIF(p_id, ''));

    -- Un valor inválido se ignora en vez de escribirse: es preferible
    -- conservar el estado actual a dejar basura en la columna.
    l_estado := CASE UPPER(TRIM(p_activo))
                  WHEN 'A' THEN 'A'
                  WHEN 'I' THEN 'I'
                  ELSE NULL
                END;

    -- El UNIQUE, excluyendo la propia fila: sin el <> l_id, guardar una
    -- empresa sin cambiarle el RUC chocaría contra sí misma.
    IF TRIM(p_ruc) IS NOT NULL THEN
      SELECT COUNT(*) INTO l_repetido
        FROM EMPRESAS
       WHERE UPPER(RUC) = UPPER(TRIM(p_ruc))
         AND ID_EMPRESA <> l_id;
      IF l_repetido > 0 THEN
        p_status_code := 409;
        p_resultado := '{"error":"Ya existe una empresa con ese RUC"}';
        RETURN;
      END IF;
    END IF;

    -- NVL en cada columna: un parámetro ausente conserva el valor actual.
    --
    -- Las tres de ubicación se manejan igual, así que NO se pueden limpiar
    -- desde acá (mandar vacío significa "no cambiar", no "borrar"). Es el
    -- mismo criterio que el resto del proyecto; si algún día hace falta
    -- vaciarlas, necesita un centinela explícito.
    UPDATE EMPRESAS
       SET NOMBRE_EMPRESA      = NVL(TRIM(p_nombre_empresa), NOMBRE_EMPRESA),
           RUC                 = NVL(TRIM(p_ruc), RUC),
           CORREO_EMPRESA      = NVL(TRIM(p_correo_empresa), CORREO_EMPRESA),
           TELEFONO            = NVL(TRIM(p_telefono), TELEFONO),
           DIRECCION           = NVL(TRIM(p_direccion), DIRECCION),
           ID_CIUDAD           = NVL(TO_NUMBER(NULLIF(p_id_ciudad, '')), ID_CIUDAD),
           ID_DEPARTAMENTO     = NVL(TO_NUMBER(NULLIF(p_id_departamento, '')), ID_DEPARTAMENTO),
           ID_PAIS             = NVL(TO_NUMBER(NULLIF(p_id_pais, '')), ID_PAIS),
           MONEDA_DEFECTO      = NVL(UPPER(TRIM(p_moneda_defecto)), MONEDA_DEFECTO),
           REPRESENTANTE_LEGAL = NVL(TRIM(p_representante_legal), REPRESENTANTE_LEGAL),
           ACTIVO              = NVL(l_estado, ACTIVO),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_EMPRESA = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La empresa no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una empresa con ese RUC"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El pais, departamento o ciudad indicado no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_EMPRESAS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar la empresa"}';
      END IF;
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

    DELETE FROM EMPRESAS WHERE ID_EMPRESA = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La empresa no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos (sucursales, compras, lo que cuelgue de la
      -- empresa) apuntando a esta fila. Es un conflicto de estado (409), no un
      -- error del servidor: el dato que mandaron era válido.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de esta empresa"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_EMPRESAS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar la empresa"}';
      END IF;
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Publica el módulo ORDS /empresas/ con sus 4 endpoints.
  --
  -- Cada handler es una sola línea: invoca al procedimiento del paquete
  -- pasando los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parámetro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahí). Sin
  -- esto, toda petición cross-origin a /empresas/* la rechaza ORDS antes de
  -- llegar a cualquiera de los 4 handlers. Ver la explicación en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'empresas',
      p_base_path      => '/empresas/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'ABM de empresas'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'empresas',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /empresas/listar?idCiudad=
    --
    -- idCiudad no se declara con DEFINE_PARAMETER: los query params se
    -- vinculan solos al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'empresas', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'empresas',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_EMPRESAS.LISTAR(:authorization, :idCiudad, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /empresas/crear
    -- Body: { nombreEmpresa, ruc?, correoEmpresa?, telefono?, direccion?,
    --         idCiudad?, idDepartamento?, idPais?, monedaDefecto?,
    --         representanteLegal? }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'empresas', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'empresas',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_EMPRESAS.INSERTAR(:authorization, :nombreEmpresa, :ruc, :correoEmpresa, :telefono, :direccion, :idCiudad, :idDepartamento, :idPais, :monedaDefecto, :representanteLegal, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /empresas/actualizar/:id
    -- Body: los mismos campos, todos opcionales, más activo? (ausente = no cambia)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'empresas', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'empresas',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_EMPRESAS.ACTUALIZAR(:authorization, :id, :nombreEmpresa, :ruc, :correoEmpresa, :telefono, :direccion, :idCiudad, :idDepartamento, :idPais, :monedaDefecto, :representanteLegal, :activo, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /empresas/eliminar/:id
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'empresas', p_pattern => 'eliminar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'empresas',
      p_pattern     => 'eliminar/:id',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_EMPRESAS.ELIMINAR(:authorization, :id, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_EMPRESAS;
/

--------------------------------------------------------------------------------
-- 2. Publicación de los endpoints
--
-- Única sentencia fuera del paquete: la llamada que publica el módulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_EMPRESAS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificación
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_EMPRESAS'
 ORDER BY OBJECT_TYPE;

-- Si algo salió INVALID arriba, acá está el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_EMPRESAS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'empresas';

SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'empresas'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

SELECT e.ID_EMPRESA, e.NOMBRE_EMPRESA, e.RUC,
       p.NOMBRE_PAIS, d.NOMBRE_DEPARTAMENTO, c.NOMBRE_CIUDAD, e.ACTIVO
  FROM EMPRESAS e
  LEFT JOIN CIUDADES      c ON c.ID_CIUDAD       = e.ID_CIUDAD
  LEFT JOIN DEPARTAMENTOS d ON d.ID_DEPARTAMENTO = e.ID_DEPARTAMENTO
  LEFT JOIN PAISES        p ON p.ID_PAIS         = e.ID_PAIS
 ORDER BY e.NOMBRE_EMPRESA;
