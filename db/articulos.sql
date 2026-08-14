--------------------------------------------------------------------------------
-- CTELL · ARTICULOS
--
-- Un paquete (PKG_ARTICULOS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — más la carga de imagen, y la publicación de los
-- endpoints ORDS. Todo vive dentro del paquete: no hay procedimientos sueltos
-- ni PL/SQL embebido como texto dentro de los handlers.
--
--   1. LISTAR      GET    /articulos/listar        (?idEmpresa= opcional)
--   2. INSERTAR    POST   /articulos/crear
--   3. ACTUALIZAR  PUT    /articulos/actualizar/:id
--   4. ELIMINAR    DELETE /articulos/eliminar/:id
--   5. (sin PL/SQL) GET   /articulos/imagen/:id    (SIN TOKEN, media)
--   6. GUARDAR_IMAGEN PUT /articulos/imagen/:id    (con token)
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/articulos/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   ARTICULOS  ID_ARTICULO, ID_EMPRESA, ID_CATEGORIA, ID_MONEDA,
--              ID_UNIDAD_MEDIDA, CODIGO_ARTICULO, NOMBRE_ARTICULO,
--              DESCRIPCION, PRECIO_ULTIMA_COMPRA, PRECIO_VENTA,
--              CANTIDAD_STOCK, CANTIDAD_MINIMA, ACTIVO,
--              FECHA_CREACION, FECHA_ACTUALIZACION, IMAGEN
--
-- EL ARTICULO ES POR EMPRESA. El idEmpresa sale de la empresa que se eligió al
-- iniciar sesión, no de un combobox. Mismo criterio que db/monedas.sql,
-- db/unidades-medida.sql y db/categorias.sql.
--
-- TRES FK OPCIONALES: ID_CATEGORIA, ID_MONEDA e ID_UNIDAD_MEDIDA son NULLABLE.
-- Un artículo puede cargarse sin categoría, sin moneda o sin unidad todavía.
-- Por eso el listado usa LEFT JOIN contra las tres: con JOIN interno, un
-- artículo sin categoría desaparecería del listado — el bug más fácil de
-- introducir acá y el más difícil de notar, porque la lista simplemente
-- muestra de menos sin ningún error.
--
-- Las tres tablas referenciadas son a su vez POR EMPRESA, así que el frontend
-- solo ofrece las de la empresa activa. La base NO lo verifica: nada impide
-- guardar un artículo de la empresa 1 con una categoría de la empresa 2 si el
-- id se manda a mano. Validarlo requeriría consultar las tres tablas en cada
-- alta; hoy se confía en que el frontend ofrece únicamente lo que corresponde.
--
-- SIN UNIQUE: el DDL no declara ninguno, ni siquiera sobre CODIGO_ARTICULO. Dos
-- artículos de la misma empresa pueden compartir código. El DUP_VAL_ON_INDEX
-- queda contemplado igual en INSERTAR y ACTUALIZAR por si se agrega uno.
--
-- IMAGEN (BLOB) NO viaja en el JSON del CRUD —un binario no entra en un
-- JSON_OBJECT— sino por dos endpoints propios, igual que el logo en
-- db/empresas.sql:
--
--   GET /articulos/imagen/:id  devuelve la imagen cruda con su content-type.
--     Es PÚBLICO: lo consume un <img>, y el navegador no manda el header
--     Authorization al descargar una imagen. Ver la nota de seguridad abajo.
--
--   PUT /articulos/imagen/:id  recibe el binario en el body. Este SÍ pide
--     token: escribir nunca es público.
--
-- OJO CON EL GET PUBLICO: a diferencia del logo de una empresa —material de
-- marca—, la foto de un artículo es dato de negocio. Cualquiera que adivine un
-- id puede verla sin credenciales. Se acepta porque un <img> no puede mandar
-- el token, y porque una foto de producto no revela precios ni stock. Si eso
-- deja de ser aceptable, la salida es servir la imagen con una URL firmada.
--
-- El listado devuelve `tieneImagen` (true/false) en vez del binario, así el
-- frontend sabe si pedir la imagen o dibujar un marcador, sin traerse los BLOB
-- de todos los artículos.
--
-- CONTENT-TYPE: se guarda junto al BLOB en IMAGEN_MIME. Sin eso habría que
-- adivinar el formato al servirlo, y un PNG servido como image/jpeg no lo
-- renderiza ningún navegador. Ver el ALTER TABLE del paso 0 más abajo.
--
-- PRECIOS Y CANTIDADES llegan como VARCHAR2 y se convierten con TO_NUMBER acá
-- adentro, igual que los ids: ORDS entrega los binds como texto, y declarar el
-- parámetro como NUMBER haría que un valor mal formado explote antes de llegar
-- al handler, con un error que el WHEN OTHERS no puede traducir.
--
-- ESTADO: ACTIVO es VARCHAR2(1) con 'A' (activo) / 'I' (inactivo). Ese mismo
-- código viaja en el JSON y lo consume el frontend, sin traducirse a 1/0. El
-- DDL ya declara DEFAULT 'A', pero el INSERT lo escribe explícito igual.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicación completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 0. Columna IMAGEN_MIME
--
-- ÚNICA excepción a la regla de que estos archivos no tocan el DDL. Es una
-- columna nueva y opcional que el paquete necesita para servir la imagen con el
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
   WHERE TABLE_NAME = 'ARTICULOS'
     AND COLUMN_NAME = 'IMAGEN_MIME';

  IF l_existe = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE ARTICULOS ADD (IMAGEN_MIME VARCHAR2(100))';
  END IF;
END;
/

--------------------------------------------------------------------------------
-- 1. PKG_ARTICULOS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_ARTICULOS.LISTAR('Bearer TU_TOKEN', NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || SUBSTR(l_result, 1, 3000));
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_ARTICULOS AS

  -- p_id_empresa NULL o vacío devuelve los artículos de todas las empresas. En
  -- la app siempre viaja con la empresa de la sesión.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE INSERTAR (
    p_authorization        IN  VARCHAR2,
    p_id_empresa           IN  VARCHAR2,
    p_id_categoria         IN  VARCHAR2,
    p_id_moneda            IN  VARCHAR2,
    p_id_unidad_medida     IN  VARCHAR2,
    p_codigo_articulo      IN  VARCHAR2,
    p_nombre_articulo      IN  VARCHAR2,
    p_descripcion          IN  VARCHAR2,
    p_precio_ultima_compra IN  VARCHAR2,
    p_precio_venta         IN  VARCHAR2,
    p_cantidad_stock       IN  VARCHAR2,
    p_cantidad_minima      IN  VARCHAR2,
    p_status_code          OUT NUMBER,
    p_resultado            OUT CLOB
  );

  -- Los parámetros ausentes (NULL) no modifican la columna correspondiente.
  PROCEDURE ACTUALIZAR (
    p_authorization        IN  VARCHAR2,
    p_id                   IN  VARCHAR2,
    p_id_empresa           IN  VARCHAR2,
    p_id_categoria         IN  VARCHAR2,
    p_id_moneda            IN  VARCHAR2,
    p_id_unidad_medida     IN  VARCHAR2,
    p_codigo_articulo      IN  VARCHAR2,
    p_nombre_articulo      IN  VARCHAR2,
    p_descripcion          IN  VARCHAR2,
    p_precio_ultima_compra IN  VARCHAR2,
    p_precio_venta         IN  VARCHAR2,
    p_cantidad_stock       IN  VARCHAR2,
    p_cantidad_minima      IN  VARCHAR2,
    p_activo               IN  VARCHAR2,
    p_status_code          OUT NUMBER,
    p_resultado            OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- NO hay procedimiento para SERVIR la imagen: el GET /articulos/imagen/:id se
  -- publica con ORDS.source_type_media, que arma la respuesta binaria desde una
  -- consulta sin pasar por PL/SQL. Ver el detalle en PUBLICAR_ENDPOINTS.

  -- Guarda la imagen. CON token: escribir nunca es público.
  -- p_imagen llega como el cuerpo crudo del PUT; p_content_type, del header.
  PROCEDURE GUARDAR_IMAGEN (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_imagen        IN  BLOB,
    p_content_type  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el módulo ORDS /articulos/ con sus endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_ARTICULOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_ARTICULOS AS

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
         WHERE NAME = 'articulos';

        IF l_existe = 0 THEN
          RETURN;  -- No existía: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'articulos');
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

  ------------------------------------------------------------------------------
  -- Privado: traduce un ORA-02291 (FK sin padre) al mensaje de la FK concreta.
  --
  -- ARTICULOS tiene CUATRO FK, así que un "el dato indicado no existe" genérico
  -- mandaría a revisar el campo equivocado. El texto del error trae el nombre
  -- de la restricción; como el DDL las crea sin nombrarlas (quedan con nombre
  -- generado tipo SYS_C00...), se mira la columna a través del mensaje
  -- completo, que la incluye.
  ------------------------------------------------------------------------------
  FUNCTION MENSAJE_FK RETURN VARCHAR2 IS
    l_error VARCHAR2(4000) := UPPER(SQLERRM || ' ' || DBMS_UTILITY.FORMAT_ERROR_STACK);
  BEGIN
    IF INSTR(l_error, 'CATEGORIA') > 0 THEN
      RETURN '{"error":"La categoria indicada no existe"}';
    ELSIF INSTR(l_error, 'MONEDA') > 0 THEN
      RETURN '{"error":"La moneda indicada no existe"}';
    ELSIF INSTR(l_error, 'UNIDAD') > 0 THEN
      RETURN '{"error":"La unidad de medida indicada no existe"}';
    ELSIF INSTR(l_error, 'EMPRESA') > 0 THEN
      RETURN '{"error":"La empresa indicada no existe"}';
    ELSE
      -- Nombre de restricción generado por el sistema: no se puede saber cuál
      -- falló. El mensaje las nombra todas para que se puedan revisar.
      RETURN '{"error":"Alguno de los datos relacionados (empresa, categoria, moneda o unidad) no existe"}';
    END IF;
  END MENSAJE_FK;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
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
      FROM ARTICULOS
     WHERE l_id_empresa IS NULL OR ID_EMPRESA = l_id_empresa;

    -- LEFT JOIN en las TRES, no JOIN: las FK son nullables. Con el interno, un
    -- artículo sin categoría (o sin moneda, o sin unidad) desaparecería del
    -- listado sin ningún error visible.
    --
    -- Se devuelven los ids Y los nombres: el formulario necesita los ids para
    -- precargar los combobox, y la tabla los nombres para mostrarlos.
    --
    -- IMAGEN no se selecciona: es un BLOB y no entra en el JSON. Va
    -- `tieneImagen` en su lugar.
    --
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: con DESCRIPCION de hasta 1000 caracteres por fila, ese techo se
    -- alcanza con tres o cuatro artículos.
    SELECT JSON_ARRAYAGG(fila ORDER BY nombre_articulo RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'                   VALUE a.ID_ARTICULO,
                 'idEmpresa'            VALUE a.ID_EMPRESA,
                 'idCategoria'          VALUE a.ID_CATEGORIA,
                 'categoria'            VALUE c.NOMBRE_CATEGORIA,
                 'idMoneda'             VALUE a.ID_MONEDA,
                 'moneda'               VALUE m.NOMBRE_MONEDA,
                 'simboloMoneda'        VALUE m.SIMBOLO,
                 'idUnidadMedida'       VALUE a.ID_UNIDAD_MEDIDA,
                 'unidadMedida'         VALUE u.NOMBRE_UNIDAD,
                 'abreviaturaUnidad'    VALUE u.ABREVIATURA,
                 'codigoArticulo'       VALUE a.CODIGO_ARTICULO,
                 'nombreArticulo'       VALUE a.NOMBRE_ARTICULO,
                 'descripcion'          VALUE a.DESCRIPCION,
                 'precioUltimaCompra'   VALUE a.PRECIO_ULTIMA_COMPRA,
                 'precioVenta'          VALUE a.PRECIO_VENTA,
                 'cantidadStock'        VALUE a.CANTIDAD_STOCK,
                 'cantidadMinima'       VALUE a.CANTIDAD_MINIMA,
                 -- El BLOB no entra en el JSON, pero el frontend necesita saber
                 -- si pedir /articulos/imagen/:id o dibujar el marcador.
                 -- GETLENGTH > 0 y no "IS NOT NULL": una fila puede tener un
                 -- BLOB vacío, que no sirve como imagen.
                 'tieneImagen'          VALUE CASE
                                                WHEN a.IMAGEN IS NOT NULL
                                                 AND DBMS_LOB.GETLENGTH(a.IMAGEN) > 0
                                                THEN 'true' ELSE 'false'
                                              END FORMAT JSON,
                 'activo'               VALUE CASE UPPER(TRIM(a.ACTIVO))
                                                WHEN 'I' THEN 'I'
                                                WHEN '0' THEN 'I'
                                                ELSE 'A'
                                              END
                 RETURNING CLOB
               ) AS fila,
               a.NOMBRE_ARTICULO AS nombre_articulo
          FROM ARTICULOS a
          LEFT JOIN CATEGORIAS      c ON c.ID_CATEGORIA     = a.ID_CATEGORIA
          LEFT JOIN MONEDAS         m ON m.ID_MONEDA        = a.ID_MONEDA
          LEFT JOIN UNIDADES_MEDIDA u ON u.ID_UNIDAD_MEDIDA = a.ID_UNIDAD_MEDIDA
         WHERE l_id_empresa IS NULL OR a.ID_EMPRESA = l_id_empresa
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
      APEX_DEBUG.ERROR('PKG_ARTICULOS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los articulos"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization        IN  VARCHAR2,
    p_id_empresa           IN  VARCHAR2,
    p_id_categoria         IN  VARCHAR2,
    p_id_moneda            IN  VARCHAR2,
    p_id_unidad_medida     IN  VARCHAR2,
    p_codigo_articulo      IN  VARCHAR2,
    p_nombre_articulo      IN  VARCHAR2,
    p_descripcion          IN  VARCHAR2,
    p_precio_ultima_compra IN  VARCHAR2,
    p_precio_venta         IN  VARCHAR2,
    p_cantidad_stock       IN  VARCHAR2,
    p_cantidad_minima      IN  VARCHAR2,
    p_status_code          OUT NUMBER,
    p_resultado            OUT CLOB
  ) IS
    l_sesion         NUMBER;
    l_id_empresa     NUMBER;
    l_id_categoria   NUMBER;
    l_id_moneda      NUMBER;
    l_id_unidad      NUMBER;
    l_precio_compra  NUMBER;
    l_precio_venta   NUMBER;
    l_stock          NUMBER;
    l_minima         NUMBER;
    l_id             NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Todas las conversiones juntas y dentro del BEGIN: si alguna falla, el
    -- ORA-01722 lo captura el WHEN OTHERS de abajo y se traduce a 400.
    l_id_empresa    := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_categoria  := TO_NUMBER(NULLIF(p_id_categoria, ''));
    l_id_moneda     := TO_NUMBER(NULLIF(p_id_moneda, ''));
    l_id_unidad     := TO_NUMBER(NULLIF(p_id_unidad_medida, ''));
    l_precio_compra := TO_NUMBER(NULLIF(p_precio_ultima_compra, ''));
    l_precio_venta  := TO_NUMBER(NULLIF(p_precio_venta, ''));
    l_stock         := TO_NUMBER(NULLIF(p_cantidad_stock, ''));
    l_minima        := TO_NUMBER(NULLIF(p_cantidad_minima, ''));

    -- PRECIO_VENTA es NOT NULL en el DDL, así que se exige junto al nombre.
    -- Las tres FK y el resto de los campos son opcionales.
    IF l_id_empresa IS NULL
       OR TRIM(p_nombre_articulo) IS NULL
       OR l_precio_venta IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, nombreArticulo y precioVenta son obligatorios"}';
      RETURN;
    END IF;

    -- Un precio negativo no es un dato válido: es 400, no un 500 más adelante.
    IF l_precio_venta < 0 OR NVL(l_precio_compra, 0) < 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"Los precios no pueden ser negativos"}';
      RETURN;
    END IF;

    -- 'A' explícito aunque el DEFAULT ya sea 'A': es el criterio del proyecto,
    -- para no depender de un default que puede cambiar en el DDL.
    --
    -- NVL en stock y mínima: el DDL las declara DEFAULT 0, pero mandar NULL
    -- explícito pisaría ese default y dejaría la columna en NULL, que después
    -- rompe cualquier suma o comparación de stock.
    INSERT INTO ARTICULOS (
      ID_EMPRESA, ID_CATEGORIA, ID_MONEDA, ID_UNIDAD_MEDIDA,
      CODIGO_ARTICULO, NOMBRE_ARTICULO, DESCRIPCION,
      PRECIO_ULTIMA_COMPRA, PRECIO_VENTA,
      CANTIDAD_STOCK, CANTIDAD_MINIMA,
      ACTIVO, FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_empresa,
      l_id_categoria,
      l_id_moneda,
      l_id_unidad,
      TRIM(p_codigo_articulo),
      TRIM(p_nombre_articulo),
      TRIM(p_descripcion),
      l_precio_compra,
      l_precio_venta,
      NVL(l_stock, 0),
      NVL(l_minima, 0),
      'A',
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_ARTICULO INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- Hoy la tabla no tiene UNIQUE, así que esto no debería dispararse. Se
      -- deja contemplado por si se agrega uno sobre CODIGO_ARTICULO.
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe un articulo con ese codigo"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        -- Alguna de las cuatro FK no encontró su padre.
        p_status_code := 400;
        p_resultado := MENSAJE_FK;
      ELSIF SQLCODE = -1722 THEN
        -- Un precio o cantidad que no era número.
        p_status_code := 400;
        p_resultado := '{"error":"Los precios y cantidades deben ser numericos"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_ARTICULOS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear el articulo"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization        IN  VARCHAR2,
    p_id                   IN  VARCHAR2,
    p_id_empresa           IN  VARCHAR2,
    p_id_categoria         IN  VARCHAR2,
    p_id_moneda            IN  VARCHAR2,
    p_id_unidad_medida     IN  VARCHAR2,
    p_codigo_articulo      IN  VARCHAR2,
    p_nombre_articulo      IN  VARCHAR2,
    p_descripcion          IN  VARCHAR2,
    p_precio_ultima_compra IN  VARCHAR2,
    p_precio_venta         IN  VARCHAR2,
    p_cantidad_stock       IN  VARCHAR2,
    p_cantidad_minima      IN  VARCHAR2,
    p_activo               IN  VARCHAR2,
    p_status_code          OUT NUMBER,
    p_resultado            OUT CLOB
  ) IS
    l_sesion         NUMBER;
    l_id             NUMBER;
    l_id_empresa     NUMBER;
    l_id_categoria   NUMBER;
    l_id_moneda      NUMBER;
    l_id_unidad      NUMBER;
    l_precio_compra  NUMBER;
    l_precio_venta   NUMBER;
    l_stock          NUMBER;
    l_minima         NUMBER;
    l_estado         VARCHAR2(1);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id            := TO_NUMBER(NULLIF(p_id, ''));
    l_id_empresa    := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_categoria  := TO_NUMBER(NULLIF(p_id_categoria, ''));
    l_id_moneda     := TO_NUMBER(NULLIF(p_id_moneda, ''));
    l_id_unidad     := TO_NUMBER(NULLIF(p_id_unidad_medida, ''));
    l_precio_compra := TO_NUMBER(NULLIF(p_precio_ultima_compra, ''));
    l_precio_venta  := TO_NUMBER(NULLIF(p_precio_venta, ''));
    l_stock         := TO_NUMBER(NULLIF(p_cantidad_stock, ''));
    l_minima        := TO_NUMBER(NULLIF(p_cantidad_minima, ''));

    IF NVL(l_precio_venta, 0) < 0 OR NVL(l_precio_compra, 0) < 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"Los precios no pueden ser negativos"}';
      RETURN;
    END IF;

    -- Un valor inválido se ignora en vez de escribirse: es preferible
    -- conservar el estado actual a dejar basura en la columna.
    l_estado := CASE UPPER(TRIM(p_activo))
                  WHEN 'A' THEN 'A'
                  WHEN 'I' THEN 'I'
                  ELSE NULL
                END;

    -- NVL en cada columna: un parámetro ausente conserva el valor actual.
    --
    -- Consecuencia en las tres FK: mandarlas vacías significa "no cambiar", NO
    -- "desvincular". Es el mismo criterio que la ubicación en db/empresas.sql;
    -- para poder quitarle la categoría a un artículo haría falta un centinela
    -- explícito (un 0, por ejemplo) que hoy no existe.
    UPDATE ARTICULOS
       SET ID_EMPRESA           = NVL(l_id_empresa, ID_EMPRESA),
           ID_CATEGORIA         = NVL(l_id_categoria, ID_CATEGORIA),
           ID_MONEDA            = NVL(l_id_moneda, ID_MONEDA),
           ID_UNIDAD_MEDIDA     = NVL(l_id_unidad, ID_UNIDAD_MEDIDA),
           CODIGO_ARTICULO      = NVL(TRIM(p_codigo_articulo), CODIGO_ARTICULO),
           NOMBRE_ARTICULO      = NVL(TRIM(p_nombre_articulo), NOMBRE_ARTICULO),
           DESCRIPCION          = NVL(TRIM(p_descripcion), DESCRIPCION),
           PRECIO_ULTIMA_COMPRA = NVL(l_precio_compra, PRECIO_ULTIMA_COMPRA),
           PRECIO_VENTA         = NVL(l_precio_venta, PRECIO_VENTA),
           CANTIDAD_STOCK       = NVL(l_stock, CANTIDAD_STOCK),
           CANTIDAD_MINIMA      = NVL(l_minima, CANTIDAD_MINIMA),
           ACTIVO               = NVL(l_estado, ACTIVO),
           FECHA_ACTUALIZACION  = SYSTIMESTAMP
     WHERE ID_ARTICULO = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El articulo no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe un articulo con ese codigo"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := MENSAJE_FK;
      ELSIF SQLCODE = -1722 THEN
        p_status_code := 400;
        p_resultado := '{"error":"Los precios y cantidades deben ser numericos"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_ARTICULOS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar el articulo"}';
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

    DELETE FROM ARTICULOS WHERE ID_ARTICULO = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El articulo no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos (movimientos de stock, líneas de comprobante, lo
      -- que cuelgue del artículo) apuntando a esta fila. Es un conflicto de
      -- estado (409), no un error del servidor: el dato era válido.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de este articulo"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_ARTICULOS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar el articulo"}';
      END IF;
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Guarda la imagen de un artículo. CON token: escribir nunca es público.
  --
  -- El binario llega como el cuerpo crudo del PUT (ORDS lo mapea a un BLOB) y
  -- el formato, del header Content-Type. Se acepta solo image/*: sin ese
  -- control, cualquier archivo quedaría guardado y después se serviría de
  -- vuelta con su content-type a quien abra el listado.
  ------------------------------------------------------------------------------
  PROCEDURE GUARDAR_IMAGEN (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_imagen        IN  BLOB,
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

    IF p_imagen IS NULL OR DBMS_LOB.GETLENGTH(p_imagen) = 0 THEN
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

    UPDATE ARTICULOS
       SET IMAGEN              = p_imagen,
           IMAGEN_MIME         = l_mime,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_ARTICULO = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El articulo no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_ARTICULOS.GUARDAR_IMAGEN: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al guardar la imagen"}';
  END GUARDAR_IMAGEN;

  ------------------------------------------------------------------------------
  -- Publica el módulo ORDS /articulos/ con sus endpoints.
  --
  -- Cada handler es una sola línea: invoca al procedimiento del paquete
  -- pasando los binds de ORDS como argumentos. Nada de PL/SQL embebido, salvo
  -- el GET de la imagen, que es una consulta por source_type_media.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parámetro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahí). Sin
  -- esto, toda petición cross-origin a /articulos/* la rechaza ORDS antes de
  -- llegar a cualquier handler. Ver la explicación en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'articulos',
      p_base_path      => '/articulos/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'ABM de articulos por empresa'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'articulos',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /articulos/listar?idEmpresa=
    --
    -- idEmpresa no se declara con DEFINE_PARAMETER: los query params se
    -- vinculan solos al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'articulos', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'articulos',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ARTICULOS.LISTAR(:authorization, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /articulos/crear
    -- Body: { idEmpresa, nombreArticulo, precioVenta,
    --         idCategoria?, idMoneda?, idUnidadMedida?, codigoArticulo?,
    --         descripcion?, precioUltimaCompra?, cantidadStock?,
    --         cantidadMinima? }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'articulos', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'articulos',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ARTICULOS.INSERTAR(:authorization, :idEmpresa, :idCategoria, :idMoneda, :idUnidadMedida, :codigoArticulo, :nombreArticulo, :descripcion, :precioUltimaCompra, :precioVenta, :cantidadStock, :cantidadMinima, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /articulos/actualizar/:id
    -- Body: los mismos campos, todos opcionales (ausentes = no cambia), más
    --       activo.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'articulos', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'articulos',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ARTICULOS.ACTUALIZAR(:authorization, :id, :idEmpresa, :idCategoria, :idMoneda, :idUnidadMedida, :codigoArticulo, :nombreArticulo, :descripcion, :precioUltimaCompra, :precioVenta, :cantidadStock, :cantidadMinima, :activo, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /articulos/eliminar/:id
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'articulos', p_pattern => 'eliminar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'articulos',
      p_pattern     => 'eliminar/:id',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ARTICULOS.ELIMINAR(:authorization, :id, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /articulos/imagen/:id — SIN TOKEN
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
    -- deja el módulo SIN NINGÚN endpoint. Costó dos intentos descubrirlo con el
    -- logo de empresas; no repetir el camino.
    --
    -- LA FORMA QUE SÍ FUNCIONA: source_type_media. ORDS toma una consulta que
    -- devuelve DOS columnas —content-type y BLOB, en ese orden— y arma la
    -- respuesta binaria él mismo, sin parámetros de salida que declarar.
    --
    -- El 404 de la imagen faltante sale solo: si la consulta no devuelve filas,
    -- ORDS responde 404 sin que haya que manejar un status code a mano. Por eso
    -- el WHERE filtra los BLOB vacíos en vez de devolverlos.
    --
    -- El mismo template lleva también el PUT que guarda la imagen, más abajo.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'articulos', p_pattern => 'imagen/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'articulos',
      p_pattern     => 'imagen/:id',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_media,
      p_source      => 'SELECT NVL(IMAGEN_MIME, ''image/png''), IMAGEN
                          FROM ARTICULOS
                         WHERE ID_ARTICULO = :id
                           AND IMAGEN IS NOT NULL
                           AND DBMS_LOB.GETLENGTH(IMAGEN) > 0'
    );

    ----------------------------------------------------------------------------
    -- PUT /articulos/imagen/:id — con token
    -- Body: la imagen cruda. Content-Type: image/png, image/jpeg, etc.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_HANDLER(
      p_module_name   => 'articulos',
      p_pattern       => 'imagen/:id',
      p_method        => 'PUT',
      p_source_type   => ORDS.source_type_plsql,
      p_mimes_allowed => 'image/png,image/jpeg,image/gif,image/webp,image/svg+xml',
      p_source        => 'BEGIN PKG_ARTICULOS.GUARDAR_IMAGEN(:authorization, :id, :body, :content_type, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'imagen/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    -- El Content-Type de entrada: de ahí sale el formato que se guarda.
    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'imagen/:id', p_method => 'PUT',
      p_name => 'Content-Type', p_bind_variable_name => 'content_type',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'imagen/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'articulos', p_pattern => 'imagen/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_ARTICULOS;
/

--------------------------------------------------------------------------------
-- 2. Publicación de los endpoints
--
-- Única sentencia fuera del paquete: la llamada que publica el módulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_ARTICULOS.PUBLICAR_ENDPOINTS;
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
 WHERE OBJECT_NAME = 'PKG_ARTICULOS'
 ORDER BY OBJECT_TYPE;

-- Si algo salió INVALID arriba, acá está el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_ARTICULOS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'articulos';

-- Deben aparecer 6 filas: listar GET, crear POST, actualizar PUT,
-- eliminar DELETE, imagen GET e imagen PUT.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'articulos'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- LEFT JOIN en las tres: las FK son nullables y un artículo sin categoría
-- desaparecería de esta verificación con un JOIN interno.
SELECT a.ID_ARTICULO, a.CODIGO_ARTICULO, a.NOMBRE_ARTICULO,
       e.NOMBRE_EMPRESA, c.NOMBRE_CATEGORIA, m.NOMBRE_MONEDA, u.ABREVIATURA,
       a.PRECIO_VENTA, a.CANTIDAD_STOCK, a.ACTIVO
  FROM ARTICULOS a
  JOIN EMPRESAS          e ON e.ID_EMPRESA       = a.ID_EMPRESA
  LEFT JOIN CATEGORIAS      c ON c.ID_CATEGORIA     = a.ID_CATEGORIA
  LEFT JOIN MONEDAS         m ON m.ID_MONEDA        = a.ID_MONEDA
  LEFT JOIN UNIDADES_MEDIDA u ON u.ID_UNIDAD_MEDIDA = a.ID_UNIDAD_MEDIDA
 ORDER BY e.NOMBRE_EMPRESA, a.NOMBRE_ARTICULO;

-- Qué artículos tienen imagen cargada. Los que digan 'NO' se ven con el
-- marcador, que es el comportamiento esperado, no un error.
SELECT ID_ARTICULO,
       NOMBRE_ARTICULO,
       CASE WHEN IMAGEN IS NOT NULL AND DBMS_LOB.GETLENGTH(IMAGEN) > 0
            THEN 'SI' ELSE 'NO' END AS TIENE_IMAGEN,
       IMAGEN_MIME,
       DBMS_LOB.GETLENGTH(IMAGEN) AS BYTES
  FROM ARTICULOS
 ORDER BY NOMBRE_ARTICULO;

-- Artículos con stock por debajo del mínimo. No es parte del ABM, pero es la
-- consulta que uno quiere correr apenas la tabla tiene datos.
SELECT ID_ARTICULO, NOMBRE_ARTICULO, CANTIDAD_STOCK, CANTIDAD_MINIMA
  FROM ARTICULOS
 WHERE CANTIDAD_STOCK < CANTIDAD_MINIMA
   AND UPPER(TRIM(ACTIVO)) != 'I'
 ORDER BY NOMBRE_ARTICULO;
