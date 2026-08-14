--------------------------------------------------------------------------------
-- CTELL · EMPRESAS
--
-- Un paquete (PKG_EMPRESAS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicación de los endpoints ORDS. Todo vive
-- dentro del paquete: no hay procedimientos sueltos ni PL/SQL embebido como
-- texto dentro de los handlers.
--
--   1. LISTAR          GET    /empresas/listar        (?idCiudad= opcional)
--   2. INSERTAR        POST   /empresas/crear
--   3. ACTUALIZAR      PUT    /empresas/actualizar/:id
--   4. ELIMINAR        DELETE /empresas/eliminar/:id
--   5. LISTAR_PUBLICAS GET    /empresas/publicas      (SIN TOKEN)
--   6. (sin PL/SQL)   GET    /empresas/logo/:id      (SIN TOKEN, media)
--   7. GUARDAR_LOGO    PUT    /empresas/logo/:id      (con token)
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- ENDPOINT PÚBLICO — /empresas/publicas es el ÚNICO de todo el proyecto que no
-- valida token, porque lo consume la pantalla de login: quien elige la empresa
-- todavía no inició sesión, así que exigirle credenciales sería un círculo.
--
-- Por eso NO reutiliza LISTAR ni comparte su consulta. Devuelve únicamente
-- { id, nombreEmpresa } de las empresas ACTIVAS, y nada más: RUC, correo,
-- teléfono, dirección y representante legal son datos de negocio que quedarían
-- expuestos a cualquiera que pegue a la URL sin credenciales. Si algún día hace
-- falta un campo más en el selector del login, agregarlo acá es una decisión
-- deliberada de publicarlo en internet, no un detalle de implementación.
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
-- LOGO (BLOB) NO viaja en el JSON del CRUD —un binario no entra en un
-- JSON_OBJECT— sino por dos endpoints propios:
--
--   GET /empresas/logo/:id  devuelve la imagen cruda con su content-type, para
--     usarla directo como src de un <img>. Es PÚBLICO, igual que /publicas: lo
--     consume el selector de empresa del login, donde todavía no hay sesión. Un
--     logo es material de marca, lo mismo que ya expone el nombre.
--     No pasa por el paquete: se publica con ORDS.source_type_media, que arma
--     la respuesta binaria desde una consulta de dos columnas (mime, blob). El
--     camino "normal" —un OUT BLOB como parámetro RESPONSE— NO funciona: el
--     check REST_PARAMS_PARAM_TYPE_CK rechaza tanto 'BLOB' como 'RESOURCE' y
--     aborta la publicación entera con ORA-02290.
--
--   PUT /empresas/logo/:id  recibe el binario en el body y lo guarda. Este SÍ
--     pide token: escribir nunca es público.
--
-- El listado devuelve `tieneLogo` (true/false) en vez del binario, así el
-- frontend sabe si pedir la imagen o dibujar las iniciales, sin traerse los
-- BLOB de todas las empresas para averiguarlo.
--
-- CONTENT-TYPE: se guarda junto al BLOB en LOGO_MIME. Sin eso habría que
-- adivinar el formato al servirlo, y un PNG servido como image/jpeg no lo
-- renderiza ningún navegador. Ver el ALTER TABLE del paso 0 más abajo.
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
-- 0. Columna LOGO_MIME
--
-- ÚNICA excepción a la regla de que estos archivos no tocan el DDL. Es una
-- columna nueva y opcional que el paquete necesita para servir el logo con el
-- content-type correcto, así que se agrega acá en vez de dejar el archivo sin
-- poder ejecutarse hasta que alguien la cree a mano.
--
-- El bloque consulta USER_TAB_COLUMNS antes de agregarla: sin eso, la segunda
-- ejecución del archivo fallaría con ORA-01430 (la columna ya existe) y todo
-- lo que viene después no llegaría a ejecutarse.
--------------------------------------------------------------------------------

DECLARE
  l_existe PLS_INTEGER;
BEGIN
  SELECT COUNT(*)
    INTO l_existe
    FROM USER_TAB_COLUMNS
   WHERE TABLE_NAME = 'EMPRESAS'
     AND COLUMN_NAME = 'LOGO_MIME';

  IF l_existe = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE EMPRESAS ADD (LOGO_MIME VARCHAR2(100))';
  END IF;
END;
/

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

  -- SIN TOKEN: alimenta el selector de empresa de la pantalla de login.
  -- Devuelve solo id y nombre de las empresas activas. No recibe
  -- p_authorization justamente porque no hay sesión todavía.
  PROCEDURE LISTAR_PUBLICAS (
    p_status_code OUT NUMBER,
    p_resultado   OUT CLOB
  );

  -- NO hay procedimiento para SERVIR el logo: el GET /empresas/logo/:id se
  -- publica con ORDS.source_type_media, que arma la respuesta binaria desde una
  -- consulta sin pasar por PL/SQL. Ver el detalle en PUBLICAR_ENDPOINTS.

  -- Guarda el logo. CON token: escribir nunca es público.
  -- p_logo llega como el cuerpo crudo del PUT; p_content_type, del header.
  PROCEDURE GUARDAR_LOGO (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_logo          IN  BLOB,
    p_content_type  IN  VARCHAR2,
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
                 -- Igual que en LISTAR_PUBLICAS: el binario va por su propio
                 -- endpoint, acá solo viaja si existe o no.
                 'tieneLogo'           VALUE CASE
                                               WHEN e.LOGO IS NOT NULL
                                                AND DBMS_LOB.GETLENGTH(e.LOGO) > 0
                                               THEN 'true' ELSE 'false'
                                             END FORMAT JSON,
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

  ------------------------------------------------------------------------------
  -- Listado público para el selector de empresa del login.
  --
  -- No valida token a propósito: quien está en la pantalla de login todavía no
  -- tiene sesión. Es el único procedimiento del proyecto sin VALIDAR_TOKEN.
  --
  -- Solo ID_EMPRESA y NOMBRE_EMPRESA, y solo las ACTIVAS. Deliberadamente NO
  -- reutiliza la consulta de LISTAR: si mañana alguien agrega una columna allá,
  -- no quiero que aparezca sola en un endpoint abierto a internet. Una empresa
  -- inactiva tampoco se ofrece — nadie debería poder conectarse a ella.
  ------------------------------------------------------------------------------
  PROCEDURE LISTAR_PUBLICAS (
    p_status_code OUT NUMBER,
    p_resultado   OUT CLOB
  ) IS
    l_total NUMBER;
    l_items CLOB;
  BEGIN
    SELECT COUNT(*)
      INTO l_total
      FROM EMPRESAS
     WHERE UPPER(TRIM(ACTIVO)) NOT IN ('I', '0')
        OR ACTIVO IS NULL;

    -- Mismo patrón que el resto de los listados: el JSON_OBJECT se arma en una
    -- subconsulta y el JSON_ARRAYAGG agrega esa columna ya tipada como CLOB.
    SELECT JSON_ARRAYAGG(fila ORDER BY nombre_empresa RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'            VALUE e.ID_EMPRESA,
                 'nombreEmpresa' VALUE e.NOMBRE_EMPRESA,
                 -- El BLOB no entra en el JSON, pero el frontend necesita saber
                 -- si pedir /empresas/logo/:id o dibujar las iniciales. Un
                 -- booleano evita traerse todos los binarios para averiguarlo.
                 -- DBMS_LOB.GETLENGTH > 0 y no "IS NOT NULL": una fila puede
                 -- tener un BLOB vacío, que no sirve como imagen.
                 'tieneLogo'     VALUE CASE
                                         WHEN e.LOGO IS NOT NULL
                                          AND DBMS_LOB.GETLENGTH(e.LOGO) > 0
                                         THEN 'true' ELSE 'false'
                                       END FORMAT JSON
                 RETURNING CLOB
               ) AS fila,
               e.NOMBRE_EMPRESA AS nombre_empresa
          FROM EMPRESAS e
         WHERE UPPER(TRIM(e.ACTIVO)) NOT IN ('I', '0')
            OR e.ACTIVO IS NULL
      );

    p_status_code := 200;
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
      APEX_DEBUG.ERROR('PKG_EMPRESAS.LISTAR_PUBLICAS: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las empresas"}';
  END LISTAR_PUBLICAS;

  ------------------------------------------------------------------------------
  -- Guarda el logo de una empresa. CON token: escribir nunca es público.
  --
  -- El binario llega como el cuerpo crudo del PUT (ORDS lo mapea a un BLOB) y
  -- el formato, del header Content-Type. Se acepta solo image/*: sin ese
  -- control, cualquier archivo quedaría guardado y después se serviría de
  -- vuelta con su content-type a quien abra el login.
  ------------------------------------------------------------------------------
  PROCEDURE GUARDAR_LOGO (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_logo          IN  BLOB,
    p_content_type  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_id     NUMBER;
    l_mime   VARCHAR2(100);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id := TO_NUMBER(NULLIF(p_id, ''));

    IF p_logo IS NULL OR DBMS_LOB.GETLENGTH(p_logo) = 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"No se recibio ninguna imagen"}';
      RETURN;
    END IF;

    -- El header puede venir con parámetros ("image/png; charset=..."), así que
    -- se corta en el punto y coma antes de guardarlo.
    l_mime := LOWER(TRIM(REGEXP_SUBSTR(p_content_type, '^[^;]+')));

    IF l_mime IS NULL OR l_mime NOT LIKE 'image/%' THEN
      p_status_code := 400;
      p_resultado := '{"error":"El archivo debe ser una imagen"}';
      RETURN;
    END IF;

    UPDATE EMPRESAS
       SET LOGO                = p_logo,
           LOGO_MIME           = l_mime,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_EMPRESA = l_id;

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
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_EMPRESAS.GUARDAR_LOGO: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al guardar el logo"}';
  END GUARDAR_LOGO;

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

    ----------------------------------------------------------------------------
    -- GET /empresas/publicas — SIN TOKEN
    --
    -- Alimenta el selector de empresa del login. No declara el parámetro
    -- 'authorization' porque el procedimiento no lo recibe: es público de
    -- verdad, no "público pero mira el header por las dudas".
    --
    -- ORIGINS_ALLOWED del módulo aplica igual que a los demás endpoints: el
    -- navegador solo lo consume desde www.ctell.online o localhost:8080. Eso NO
    -- es un control de acceso —un curl lo lee sin problema— y por eso el
    -- procedimiento devuelve únicamente id y nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'empresas', p_pattern => 'publicas');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'empresas',
      p_pattern     => 'publicas',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_EMPRESAS.LISTAR_PUBLICAS(:status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'publicas', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'publicas', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /empresas/logo/:id — SIN TOKEN
    --
    -- Devuelve la imagen cruda, no un JSON, y por eso NO se publica como los
    -- demás endpoints.
    --
    -- POR QUÉ NO ES UN HANDLER PL/SQL CON PARÁMETRO DE SALIDA:
    -- La forma "natural" sería un procedimiento con un OUT BLOB declarado como
    -- p_source_type => 'RESPONSE'. No funciona: DEFINE_PARAMETER valida
    -- p_param_type contra REST_PARAMS_PARAM_TYPE_CK, que admite un conjunto
    -- cerrado de valores, y ni 'BLOB' ni 'RESOURCE' pasan esa restricción en
    -- esta instalación. El ORA-02290 aborta PUBLICAR_ENDPOINTS a la mitad y
    -- deja el módulo SIN NINGÚN endpoint — se cae la app entera, no solo el
    -- logo.
    --
    -- LA FORMA QUE SÍ FUNCIONA: source_type_media. ORDS toma una consulta que
    -- devuelve DOS columnas —content-type y BLOB, en ese orden— y arma la
    -- respuesta binaria él mismo, sin parámetros de salida que declarar. Es el
    -- mecanismo pensado para servir imágenes y el que usa APEX internamente.
    --
    -- El 404 del logo faltante sale solo: si la consulta no devuelve filas,
    -- ORDS responde 404 sin que haya que manejar un status code a mano. Por eso
    -- el WHERE filtra los BLOB vacíos en vez de devolverlos — así el <img> cae
    -- a las iniciales en lugar de mostrar una imagen rota.
    --
    -- El mismo template lleva también el PUT que guarda el logo, más abajo. Ese
    -- sí es un handler PL/SQL normal: recibe el binario, no lo devuelve.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'empresas', p_pattern => 'logo/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'empresas',
      p_pattern     => 'logo/:id',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_media,
      p_source      => 'SELECT NVL(LOGO_MIME, ''image/png''), LOGO
                          FROM EMPRESAS
                         WHERE ID_EMPRESA = :id
                           AND LOGO IS NOT NULL
                           AND DBMS_LOB.GETLENGTH(LOGO) > 0'
    );

    ----------------------------------------------------------------------------
    -- PUT /empresas/logo/:id — con token
    -- Body: la imagen cruda. Content-Type: image/png, image/jpeg, etc.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_HANDLER(
      p_module_name => 'empresas',
      p_pattern     => 'logo/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_mimes_allowed => 'image/png,image/jpeg,image/gif,image/webp,image/svg+xml',
      p_source      => 'BEGIN PKG_EMPRESAS.GUARDAR_LOGO(:authorization, :id, :body, :content_type, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'logo/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    -- El Content-Type de entrada: de ahí sale el formato que se guarda.
    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'logo/:id', p_method => 'PUT',
      p_name => 'Content-Type', p_bind_variable_name => 'content_type',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'logo/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'empresas', p_pattern => 'logo/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

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

-- Valores que REST_PARAMS_PARAM_TYPE_CK acepta en p_param_type.
--
-- Si la publicación vuelve a fallar con ORA-02290 nombrando esa restricción, es
-- porque algún DEFINE_PARAMETER usa un tipo que no está en esta lista. Pasó con
-- 'BLOB' y también con 'RESOURCE' al intentar servir el logo por un parámetro
-- de salida; la solución fue no usar un parámetro (ver source_type_media en
-- PUBLICAR_ENDPOINTS). El error corta la publicación a la mitad y deja el
-- módulo sin NINGÚN endpoint, no solo sin el que falló.
--
-- El OWNER es obligatorio: la restricción vive en ORDS_METADATA, y sin filtrar
-- por esquema la consulta devuelve cero filas aunque exista.
SELECT SEARCH_CONDITION
  FROM ALL_CONSTRAINTS
 WHERE OWNER = 'ORDS_METADATA'
   AND CONSTRAINT_NAME = 'REST_PARAMS_PARAM_TYPE_CK';

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

-- Qué empresas tienen logo cargado. Las que digan 'NO' se ven en el login con
-- sus iniciales, que es el comportamiento esperado, no un error.
SELECT ID_EMPRESA,
       NOMBRE_EMPRESA,
       CASE WHEN LOGO IS NOT NULL AND DBMS_LOB.GETLENGTH(LOGO) > 0
            THEN 'SI' ELSE 'NO' END AS TIENE_LOGO,
       LOGO_MIME,
       DBMS_LOB.GETLENGTH(LOGO) AS BYTES
  FROM EMPRESAS
 ORDER BY NOMBRE_EMPRESA;
