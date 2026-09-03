-- CTELL · PROFESORES
--
-- Un paquete (PKG_PROFESORES) con los procedimientos del CRUD — LISTAR,
-- INSERTAR, ACTUALIZAR, ELIMINAR — mas la carga de la foto, y la publicacion
-- de los endpoints ORDS. Todo vive dentro del paquete: no hay procedimientos
-- sueltos ni PL/SQL embebido como texto dentro de los handlers.
--
--   1. LISTAR        GET    /profesores/listar  (?idEmpresa= &busqueda= &activo=)
--   2. INSERTAR      POST   /profesores/crear
--   3. ACTUALIZAR    PUT    /profesores/actualizar/:id
--   4. ELIMINAR      DELETE /profesores/eliminar/:id/:idEmpresa
--   5. (sin PL/SQL)  GET    /profesores/foto/:id   (SIN TOKEN, media)
--   6. GUARDAR_FOTO  PUT    /profesores/foto/:id   (con token)
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/profesores/
--
-- Tabla (no la crea ni la altera, salvo la columna FOTO_MIME del paso 0):
--   PROFESORES  ID_PROFESOR, ID_EMPRESA, NUMERO_CI, NOMBRE, APELLIDO,
--               DIRECCION, TELEFONO, CORREO, FECHA_CREACION,
--               FECHA_ACTUALIZACION, ACTIVO, FOTO, ID_USUARIO
--
-- EL PROFESOR ES POR EMPRESA. Cada empresa tiene su propio plantel: el
-- idEmpresa sale de la empresa que se eligio al iniciar sesion, no de un
-- combobox del formulario. Por eso el listado se filtra por ?idEmpresa= y el
-- alta lo recibe como dato obligatorio.
--
--------------------------------------------------------------------------------
-- CAMBIO DE ESTRUCTURA: SE FUE USUARIO_SISTEMA, LLEGARON ID_USUARIO, ACTIVO Y FOTO
--
-- La version anterior de la tabla tenia una columna USUARIO_SISTEMA VARCHAR2
-- —un identificador corto tipo 'jperez', UNIQUE global, sin ninguna relacion
-- con la tabla USUARIOS—. YA NO EXISTE. En su lugar hay:
--
--   ID_USUARIO  NUMBER, FK a USUARIOS(ID_USUARIO), OPCIONAL (permite NULL).
--               Ahora si es una cuenta de login de verdad: vincula al profesor
--               con el usuario con el que entra al sistema. Opcional porque un
--               profesor puede estar en el padron sin tener acceso.
--
--   ACTIVO      VARCHAR2(1) 'A'/'I', DEFAULT 'A'. Antes no existia y la baja
--               era solo fisica; ahora hay baja logica y el DELETE queda como
--               ultimo recurso.
--
--   FOTO        BLOB. Foto del profesor, con sus dos endpoints propios.
--
-- El paquete viejo referenciaba USUARIO_SISTEMA en el SELECT del listado, en
-- el INSERT, en el UPDATE y en una funcion USUARIO_REPETIDO. Todo eso se
-- elimino: contra la tabla nueva, cualquiera de esas referencias es un
-- ORA-00904 que deja el paquete INVALID y el modulo respondiendo 500.
--
--------------------------------------------------------------------------------
-- DOS UNIQUE, Y UNO DE ELLOS ES GLOBAL — ESTO SIGUE SIENDO LO IMPORTANTE
--
-- El DDL declara:
--
--   UNIQUE (NUMERO_CI)                 <-- GLOBAL, cruza empresas
--   UNIQUE (ID_EMPRESA, NUMERO_CI)     <-- por empresa (redundante con el anterior)
--
-- ES DISTINTO DEL RESTO DEL PROYECTO. En MONEDAS, CATEGORIAS o
-- LISTAS_DESCUENTOS el unico es SIEMPRE compuesto con la empresa, y por eso el
-- mensaje del 409 dice "esta empresa ya tiene...". Aca NO: dos empresas no
-- pueden cargar al mismo profesor. La segunda recibe un 409 contra una fila que
-- su propio listado NO MUESTRA, asi que el mensaje tiene que aclarar que el
-- duplicado puede estar en otra empresa; si no, quien lo reciba busca en su
-- listado, no encuentra nada y el error parece un bug.
--
-- SE CONSULTA ANTES DE INSERTAR, no se espera al DUP_VAL_ON_INDEX: esa
-- excepcion no dice CUAL indice se violo, y el mensaje quedaria en "algun dato
-- esta repetido". Con la consulta previa se nombra el campo. El
-- DUP_VAL_ON_INDEX se captura igual como red de seguridad, por si dos altas
-- simultaneas pasan la validacion antes de que cualquiera escriba.
--
-- NUMERO_CI se normaliza (TRIM, y mayusculas al comparar): una cedula con un
-- espacio al final no deberia colar como distinta.
--
--------------------------------------------------------------------------------
-- ID_USUARIO: OPCIONAL, PERO UNO SOLO POR PROFESOR
--
-- El DDL no declara UNIQUE sobre ID_USUARIO, asi que la base aceptaria dos
-- profesores con la misma cuenta. El paquete lo impide igual —USUARIO_REPETIDO
-- consulta antes de escribir— porque una cuenta que identifica a dos personas
-- distintas rompe cualquier lectura posterior de "quien hizo esto".
--
-- La validacion es GLOBAL, sin filtrar por empresa: el usuario de login tampoco
-- pertenece a una empresa.
--
-- SE COMPRUEBA QUE LA CUENTA EXISTA antes del INSERT: la FK contra USUARIOS
-- daria ORA-02291 (un 500 sin explicacion) y validarlo antes devuelve un 400
-- que dice que la cuenta no existe.
--
-- CENTINELA PARA DESVINCULAR: como todos los campos ausentes conservan su
-- valor, mandar idUsuario vacio en el PUT significa "no cambiar", no "quitar".
-- Para desvincular hay que mandar idUsuario = 0 explicitamente. Sin ese
-- centinela no habria forma de deshacer un vinculo cargado por error.
--
--------------------------------------------------------------------------------
-- FOTO (BLOB): POR ENDPOINTS PROPIOS, NO EN EL JSON
--
-- Un binario no entra en un JSON_OBJECT, asi que va aparte, con el mismo
-- mecanismo que la imagen en db/articulos.sql y el logo en db/empresas.sql:
--
--   GET /profesores/foto/:id  devuelve la foto cruda con su content-type.
--     Es PUBLICO: lo consume un <img>, y el navegador no manda el header
--     Authorization al descargar una imagen. Ver la nota de seguridad abajo.
--
--   PUT /profesores/foto/:id  recibe el binario en el body. Este SI pide
--     token: escribir nunca es publico.
--
-- OJO CON EL GET PUBLICO: la foto de una persona es un dato mas sensible que
-- una foto de producto. Cualquiera que adivine un id la ve sin credenciales.
-- Se acepta con el mismo criterio que el resto del proyecto —un <img> no puede
-- mandar el token— pero aca conviene recordarlo: si en algun momento hay que
-- cerrarlo, la salida es servir la foto con una URL firmada, y este es el
-- primer endpoint que habria que migrar.
--
-- El listado devuelve `tieneFoto` (true/false) en vez del binario, asi el
-- frontend sabe si pedir la foto o dibujar las iniciales, sin traerse los BLOB
-- de todo el plantel.
--
-- CONTENT-TYPE: se guarda junto al BLOB en FOTO_MIME. Sin eso habria que
-- adivinar el formato al servirlo, y un PNG servido como image/jpeg no lo
-- renderiza ningun navegador. Ver el ALTER TABLE del paso 0.
--
-- TAMAÑO: el limite duro son 2 MB, validado aca. El frontend ademas redimensiona
-- y recomprime antes de subir (ver src/lib/imagen.ts), asi que en la practica
-- lo que llega ronda los 100-200 KB. La validacion del backend no confia en eso:
-- el endpoint esta abierto a cualquiera con sesion, no solo a la pantalla.
--
--------------------------------------------------------------------------------
-- ESTADO: ACTIVO es VARCHAR2(1) con 'A' (activo) / 'I' (inactivo). Ese mismo
-- codigo viaja en el JSON y lo consume el frontend, sin traducirse a 1/0. El
-- DDL ya declara DEFAULT 'A', pero el INSERT lo escribe explicito igual.
--
-- BAJA LOGICA Y BAJA FISICA CONVIVEN: el ACTUALIZAR recibe p_activo, asi que
-- inactivar es un PUT mas —no hay endpoints /activar ni /inactivar separados,
-- igual que en db/categorias.sql—. El DELETE sigue existiendo para el caso de
-- una carga equivocada, y devuelve 409 si hay registros colgando del profesor.
--
-- SIN JOIN CONTRA EMPRESAS: el listado no devuelve el nombre de la empresa.
-- Viene filtrado por una sola —la de la sesion— asi que seria la misma
-- constante repetida en cada fila. Mismo criterio que db/monedas.sql.
--
-- SI HAY JOIN CONTRA USUARIOS, pero con LEFT: ID_USUARIO permite NULL, y con
-- un INNER JOIN los profesores sin cuenta desaparecerian del listado. Es el
-- error mas facil de cometer aca y el mas dificil de notar, porque la pantalla
-- se ve bien: simplemente faltan filas.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 0. Columna FOTO_MIME
--
-- UNICA excepcion a la regla de que estos archivos no tocan el DDL. Es una
-- columna nueva y opcional que el paquete necesita para servir la foto con el
-- content-type correcto, asi que se agrega aca en vez de dejar el archivo sin
-- poder ejecutarse hasta que alguien la cree a mano. Mismo criterio que
-- IMAGEN_MIME en db/articulos.sql.
--
-- El bloque consulta USER_TAB_COLUMNS antes de agregarla: sin eso, la segunda
-- ejecucion del archivo fallaria con ORA-01430 (la columna ya existe) y todo
-- lo que viene despues no llegaria a ejecutarse.
--------------------------------------------------------------------------------

DECLARE
  l_existe PLS_INTEGER;
BEGIN
  SELECT COUNT(*)
    INTO l_existe
    FROM USER_TAB_COLUMNS
   WHERE TABLE_NAME = 'PROFESORES'
     AND COLUMN_NAME = 'FOTO_MIME';

  IF l_existe = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE PROFESORES ADD (FOTO_MIME VARCHAR2(100))';
  END IF;
END;
/

--------------------------------------------------------------------------------
-- 1. PKG_PROFESORES
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_PROFESORES.LISTAR('Bearer TU_TOKEN', NULL, NULL, NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_PROFESORES AS

  -- p_id_empresa NULL o vacio devuelve los profesores de todas las empresas. En
  -- la app siempre viaja con la empresa de la sesion.
  --
  -- p_busqueda filtra por nombre, apellido, CI, correo y el usuario de la
  -- cuenta vinculada. Va en el SQL y no en el cliente porque el padron puede
  -- crecer.
  --
  -- p_activo ('A'/'I') filtra por estado; NULL o cualquier otra cosa devuelve
  -- los dos. El filtro fino de la pantalla es del cliente, pero tenerlo aca
  -- permite pedir "solo activos" para poblar un combo sin traer el resto.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_activo        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- idEmpresa, numeroCi, nombre y apellido son obligatorios: las cuatro
  -- columnas son NOT NULL en el DDL. idUsuario es OPCIONAL — un profesor puede
  -- no tener cuenta de acceso al sistema.
  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_numero_ci     IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_apellido      IN  VARCHAR2,
    p_direccion     IN  VARCHAR2,
    p_telefono      IN  VARCHAR2,
    p_correo        IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Los parametros ausentes (NULL) no modifican la columna correspondiente.
  --
  -- EXCEPCION: p_id_usuario = '0' DESVINCULA la cuenta (escribe NULL). Es el
  -- unico centinela del paquete, y existe porque sin el no habria forma de
  -- deshacer un vinculo cargado por error: el vacio ya significa "no cambiar".
  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_numero_ci     IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_apellido      IN  VARCHAR2,
    p_direccion     IN  VARCHAR2,
    p_telefono      IN  VARCHAR2,
    p_correo        IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_activo        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- p_id_empresa es OBLIGATORIO: acota el borrado a la empresa de la sesion.
  -- Sin el, un DELETE con el id de un profesor ajeno lo borraba igual.
  --
  -- Es baja FISICA. La logica se hace con ACTUALIZAR mandando activo='I'.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- NO hay procedimiento para SERVIR la foto: el GET /profesores/foto/:id se
  -- publica como source_type_media. Ver el comentario en PUBLICAR_ENDPOINTS.
  --
  -- Guarda la foto. CON token: escribir nunca es publico.
  -- p_foto llega como el cuerpo crudo del PUT; p_content_type, del header.
  PROCEDURE GUARDAR_FOTO (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_foto          IN  BLOB,
    p_content_type  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /profesores/ con sus 6 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_PROFESORES;
/

CREATE OR REPLACE PACKAGE BODY PKG_PROFESORES AS

  -- Techo del BLOB de la foto. 2 MB es holgado para lo que manda la pantalla
  -- —que redimensiona a 800px y recomprime a JPEG, dejando 100-200 KB— y sigue
  -- siendo un limite util contra una subida directa al endpoint.
  C_FOTO_MAX_BYTES CONSTANT NUMBER := 2 * 1024 * 1024;

  ------------------------------------------------------------------------------
  -- Privado: borra el modulo ORDS si existe, reintentando ante un interbloqueo.
  --
  -- Nunca usar `WHEN OTHERS THEN NULL` aca: se tragaria tambien un ORA-00060,
  -- el DELETE fallaria en silencio, y el DEFINE_MODULE de despues moriria con
  -- ORA-00001 (nombre duplicado) contra el modulo que nunca se llego a borrar.
  ------------------------------------------------------------------------------
  PROCEDURE BORRAR_MODULO IS
    C_INTENTOS CONSTANT PLS_INTEGER := 3;
    l_existe   PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. C_INTENTOS LOOP
      BEGIN
        -- Se consulta en vez de capturar el error de "no existe": asi el
        -- EXCEPTION queda libre para los fallos que si importan.
        SELECT COUNT(*)
          INTO l_existe
          FROM USER_ORDS_MODULES
         WHERE NAME = 'profesores';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'profesores');
        COMMIT;  -- Libera los locks antes de que DEFINE_MODULE los vuelva a pedir.
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
          -- ORA-00060 (interbloqueo) y ORA-04020 (lock de objeto) son
          -- transitorios: la otra sesion termina y el reintento pasa.
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
  -- Privado: texto -> NUMBER, tolerando el vacio.
  --
  -- NULLIF antes de TO_NUMBER: el parametro ausente llega como cadena vacia y
  -- TO_NUMBER('') da ORA-01722.
  ------------------------------------------------------------------------------
  FUNCTION A_NUMERO (p_texto IN VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN TO_NUMBER(NULLIF(TRIM(p_texto), ''));
  END A_NUMERO;

  ------------------------------------------------------------------------------
  -- Privado: 'A'/'I' normalizado, o NULL si vino cualquier otra cosa.
  --
  -- Un valor invalido se ignora en vez de escribirse: es preferible conservar
  -- el estado actual a dejar basura en la columna.
  ------------------------------------------------------------------------------
  FUNCTION A_ESTADO (p_texto IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE UPPER(TRIM(p_texto))
             WHEN 'A' THEN 'A'
             WHEN 'I' THEN 'I'
             ELSE NULL
           END;
  END A_ESTADO;

  ------------------------------------------------------------------------------
  -- Privado: esa cedula ya esta usada por OTRO profesor.
  --
  -- LA BUSQUEDA ES GLOBAL, SIN FILTRAR POR EMPRESA, porque el UNIQUE del DDL
  -- tambien lo es. Filtrar por empresa aca dejaria pasar el alta y el INSERT
  -- moriria despues con DUP_VAL_ON_INDEX contra una fila de otra empresa.
  --
  -- p_id_excluir es la fila que se esta editando: sin el, actualizar un profesor
  -- sin cambiarle la cedula chocaria contra si mismo.
  ------------------------------------------------------------------------------
  FUNCTION CI_REPETIDO (
    p_numero_ci  IN VARCHAR2,
    p_id_excluir IN NUMBER DEFAULT NULL
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    IF TRIM(p_numero_ci) IS NULL THEN
      RETURN FALSE;
    END IF;

    SELECT COUNT(*)
      INTO l_existe
      FROM PROFESORES
     WHERE UPPER(TRIM(NUMERO_CI)) = UPPER(TRIM(p_numero_ci))
       AND (p_id_excluir IS NULL OR ID_PROFESOR != p_id_excluir);

    RETURN l_existe > 0;
  END CI_REPETIDO;

  ------------------------------------------------------------------------------
  -- Privado: esa cuenta de usuario ya esta vinculada a OTRO profesor.
  --
  -- El DDL no declara UNIQUE sobre ID_USUARIO —la base aceptaria el duplicado—
  -- pero una cuenta que identifica a dos personas distintas rompe cualquier
  -- lectura posterior de "quien hizo esto". La busqueda es GLOBAL, como la de
  -- la cedula: el usuario de login tampoco pertenece a una empresa.
  ------------------------------------------------------------------------------
  FUNCTION USUARIO_REPETIDO (
    p_id_usuario IN NUMBER,
    p_id_excluir IN NUMBER DEFAULT NULL
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    IF p_id_usuario IS NULL THEN
      RETURN FALSE;
    END IF;

    SELECT COUNT(*)
      INTO l_existe
      FROM PROFESORES
     WHERE ID_USUARIO = p_id_usuario
       AND (p_id_excluir IS NULL OR ID_PROFESOR != p_id_excluir);

    RETURN l_existe > 0;
  END USUARIO_REPETIDO;

  ------------------------------------------------------------------------------
  -- Privado: esa cuenta existe en USUARIOS.
  --
  -- Se comprueba antes de escribir para que la FK no explote con ORA-02291, que
  -- llegaria al cliente como un 500 sin explicacion. Aca sale un 400 que dice
  -- que la cuenta no existe.
  ------------------------------------------------------------------------------
  FUNCTION USUARIO_EXISTE (p_id_usuario IN NUMBER) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    IF p_id_usuario IS NULL THEN
      RETURN TRUE;  -- Sin cuenta es un caso valido: la columna permite NULL.
    END IF;

    SELECT COUNT(*)
      INTO l_existe
      FROM USUARIOS
     WHERE ID_USUARIO = p_id_usuario;

    RETURN l_existe > 0;
  END USUARIO_EXISTE;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_activo        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_empresa NUMBER;
    l_busqueda   VARCHAR2(4000);
    l_estado     VARCHAR2(1);
    l_total      NUMBER;
    l_items      CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- La conversion va aca, dentro del BEGIN: en el DECLARE se ejecutaria antes
    -- de que exista el EXCEPTION y el error escaparia del procedimiento.
    l_id_empresa := A_NUMERO(p_id_empresa);
    l_estado     := A_ESTADO(p_activo);

    -- Sin empresa NO se devuelve nada. El default de "todas" que tenia antes es
    -- el error: un olvido en el cliente pasaba desapercibido justamente porque
    -- la pantalla se llenaba de datos —y de datos ajenos—.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- En minusculas una sola vez aca, no por fila: el WHERE compara contra
    -- LOWER() de cada columna, asi que subir el termino tambien dentro del SQL
    -- haria el trabajo tantas veces como filas tenga la tabla.
    --
    -- NULL cuando llega vacio: el WHERE esta escrito como "l_busqueda IS NULL
    -- OR ...", asi que una cadena vacia sin normalizar filtraria por '%%' en vez
    -- de saltear el filtro.
    l_busqueda := LOWER(TRIM(NULLIF(p_busqueda, '')));

    -- El COUNT lleva el mismo LEFT JOIN que el SELECT de abajo: la busqueda
    -- alcanza al usuario de la cuenta vinculada, asi que sin el join el total
    -- no coincidiria con la cantidad de filas devueltas.
    SELECT COUNT(*)
      INTO l_total
      FROM PROFESORES p
      LEFT JOIN USUARIOS u ON u.ID_USUARIO = p.ID_USUARIO
     WHERE p.ID_EMPRESA = l_id_empresa
       AND (l_estado IS NULL OR NVL(UPPER(TRIM(p.ACTIVO)), 'A') = l_estado)
       AND (l_busqueda IS NULL
            OR LOWER(p.NOMBRE)    LIKE '%' || l_busqueda || '%'
            OR LOWER(p.APELLIDO)  LIKE '%' || l_busqueda || '%'
            OR LOWER(p.NUMERO_CI) LIKE '%' || l_busqueda || '%'
            OR LOWER(p.CORREO)    LIKE '%' || l_busqueda || '%'
            OR LOWER(u.USUARIO)   LIKE '%' || l_busqueda || '%');

    -- Sin JOIN contra EMPRESAS: el nombre de la empresa no se devuelve porque
    -- el listado ya viene filtrado por una sola.
    --
    -- SI hay JOIN contra USUARIOS, y es LEFT: ID_USUARIO permite NULL, y con un
    -- INNER JOIN los profesores sin cuenta desaparecerian del listado sin que
    -- nada se vea roto en la pantalla — simplemente faltarian filas.
    --
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: con DIRECCION de hasta 500 caracteres por fila, ese techo se
    -- alcanza con siete u ocho profesores.
    --
    -- ORDEN por apellido y despues nombre: es como se busca a una persona en un
    -- listado, y como se imprimen las planillas.
    SELECT JSON_ARRAYAGG(fila ORDER BY apellido, nombre RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'          VALUE p.ID_PROFESOR,
                 'idEmpresa'   VALUE p.ID_EMPRESA,
                 'numeroCi'    VALUE p.NUMERO_CI,
                 'nombre'      VALUE p.NOMBRE,
                 'apellido'    VALUE p.APELLIDO,
                 'direccion'   VALUE p.DIRECCION,
                 'telefono'    VALUE p.TELEFONO,
                 'correo'      VALUE p.CORREO,
                 'idUsuario'   VALUE p.ID_USUARIO,
                 -- El nombre de la cuenta viene junto al id para que la tabla
                 -- pueda mostrarlo sin pedir el listado de usuarios aparte.
                 -- Es NULL cuando el profesor no tiene cuenta vinculada.
                 'usuario'     VALUE u.USUARIO,
                 -- NVL a 'A': las filas cargadas antes de que existiera la
                 -- columna pueden tenerla en NULL, y sin esto el frontend las
                 -- veria como un estado desconocido.
                 'activo'      VALUE NVL(UPPER(TRIM(p.ACTIVO)), 'A'),
                 -- El BLOB no entra en el JSON, pero el frontend necesita saber
                 -- si pedir /profesores/foto/:id o dibujar las iniciales.
                 -- GETLENGTH > 0 y no solo IS NOT NULL: una carga fallida deja
                 -- un BLOB vacio, que no sirve como foto.
                 'tieneFoto'   VALUE CASE
                                       WHEN p.FOTO IS NOT NULL
                                        AND DBMS_LOB.GETLENGTH(p.FOTO) > 0
                                       THEN 'true' ELSE 'false'
                                     END FORMAT JSON
                 RETURNING CLOB
               ) AS fila,
               p.APELLIDO AS apellido,
               p.NOMBRE   AS nombre
          FROM PROFESORES p
          LEFT JOIN USUARIOS u ON u.ID_USUARIO = p.ID_USUARIO
         WHERE p.ID_EMPRESA = l_id_empresa
           AND (l_estado IS NULL OR NVL(UPPER(TRIM(p.ACTIVO)), 'A') = l_estado)
           AND (l_busqueda IS NULL
                OR LOWER(p.NOMBRE)    LIKE '%' || l_busqueda || '%'
                OR LOWER(p.APELLIDO)  LIKE '%' || l_busqueda || '%'
                OR LOWER(p.NUMERO_CI) LIKE '%' || l_busqueda || '%'
                OR LOWER(p.CORREO)    LIKE '%' || l_busqueda || '%'
                OR LOWER(u.USUARIO)   LIKE '%' || l_busqueda || '%')
      );

    p_status_code := 200;
    -- JSON_OBJECT(... RETURNING CLOB) como asignacion PL/SQL directa (sin
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
      APEX_DEBUG.ERROR('PKG_PROFESORES.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      -- El SQLERRM viaja en la respuesta, como en db/lotes.sql: el mensaje
      -- generico deja el 500 sin diagnostico y APEX_DEBUG escribe en un log del
      -- workspace que hay que ir a buscar. REPLACE saca las comillas y los
      -- saltos de linea, que romperian el JSON.
      p_resultado := '{"error":"Error al listar los profesores: ' ||
                     REPLACE(
                       REPLACE(
                         REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                         CHR(10), ' '),
                       CHR(13), ' ') ||
                     '"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_numero_ci     IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_apellido      IN  VARCHAR2,
    p_direccion     IN  VARCHAR2,
    p_telefono      IN  VARCHAR2,
    p_correo        IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_empresa NUMBER;
    l_id_usuario NUMBER;
    l_id         NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_empresa := A_NUMERO(p_id_empresa);
    -- El 0 se trata como "sin cuenta", no como un id: es el mismo centinela que
    -- usa ACTUALIZAR para desvincular, y aceptarlo aca evita que el alta
    -- reviente con ORA-02291 si el formulario manda el valor del "Sin cuenta".
    l_id_usuario := NULLIF(A_NUMERO(p_id_usuario), 0);

    -- Las cuatro columnas NOT NULL del DDL. Sin esto el INSERT moriria con
    -- ORA-01400 (500); validado aca devuelve un 400 que dice cual falta.
    -- ID_USUARIO no entra: permite NULL a proposito.
    IF l_id_empresa IS NULL
       OR TRIM(p_numero_ci) IS NULL
       OR TRIM(p_nombre) IS NULL
       OR TRIM(p_apellido) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, numeroCi, nombre y apellido son obligatorios"}';
      RETURN;
    END IF;

    -- EL UNIQUE SE CONSULTA ANTES DE INSERTAR para poder nombrar el campo en el
    -- mensaje: DUP_VAL_ON_INDEX no informa cual indice fallo.
    --
    -- El mensaje aclara que el choque puede ser con OTRA EMPRESA: el UNIQUE es
    -- global, asi que quien lo reciba no va a encontrar el duplicado en su
    -- propio listado por mas que lo busque.
    IF CI_REPETIDO(p_numero_ci) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe un profesor con esa cedula. La cedula es unica en todo el sistema, asi que puede estar cargado en otra empresa"}';
      RETURN;
    END IF;

    IF NOT USUARIO_EXISTE(l_id_usuario) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La cuenta de usuario indicada no existe"}';
      RETURN;
    END IF;

    IF USUARIO_REPETIDO(l_id_usuario) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Esa cuenta de usuario ya esta vinculada a otro profesor. El vinculo es unico en todo el sistema, asi que puede ser de otra empresa"}';
      RETURN;
    END IF;

    -- 'A' explicito aunque el DEFAULT ya sea 'A': es el criterio del proyecto,
    -- para no depender de un default que puede cambiar en el DDL.
    --
    -- La FOTO no se carga aca: va por PUT /profesores/foto/:id despues del
    -- alta, cuando ya hay un id al que asociarla.
    INSERT INTO PROFESORES (
      ID_EMPRESA, NUMERO_CI, NOMBRE, APELLIDO,
      DIRECCION, TELEFONO, CORREO, ID_USUARIO,
      ACTIVO, FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_empresa,
      TRIM(p_numero_ci),
      TRIM(p_nombre),
      TRIM(p_apellido),
      TRIM(p_direccion),
      TRIM(p_telefono),
      TRIM(p_correo),
      l_id_usuario,
      'A',
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_PROFESOR INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- Red de seguridad: la validacion de arriba ya cubre el caso, pero dos
      -- altas simultaneas pueden pasarla las dos antes de que cualquiera
      -- escriba.
      p_status_code := 409;
      p_resultado := '{"error":"La cedula ya esta registrada"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: una FK no encontro el padre. Con dos FK en la tabla el
      -- mensaje no puede nombrar cual —EMPRESAS o USUARIOS— sin parsear el
      -- SQLERRM, asi que las nombra a las dos. Es un dato invalido del cliente
      -- (400), no un fallo del servidor.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La empresa o la cuenta de usuario indicada no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_PROFESORES.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear el profesor: ' ||
                       REPLACE(
                         REPLACE(
                           REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                           CHR(10), ' '),
                         CHR(13), ' ') ||
                       '"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_numero_ci     IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_apellido      IN  VARCHAR2,
    p_direccion     IN  VARCHAR2,
    p_telefono      IN  VARCHAR2,
    p_correo        IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_activo        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id          NUMBER;
    l_id_empresa  NUMBER;
    l_id_usuario  NUMBER;
    l_desvincular BOOLEAN;
    l_estado      VARCHAR2(1);
    l_existe      PLS_INTEGER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id         := A_NUMERO(p_id);
    l_id_empresa := A_NUMERO(p_id_empresa);
    l_id_usuario := A_NUMERO(p_id_usuario);
    l_estado     := A_ESTADO(p_activo);

    -- EL CENTINELA: 0 significa "quitar la cuenta". Sin el no habria forma de
    -- desvincular, porque el vacio ya significa "no cambiar" — es la regla de
    -- todos los demas campos de este UPDATE.
    l_desvincular := (l_id_usuario = 0);
    IF l_desvincular THEN
      l_id_usuario := NULL;
    END IF;

    -- AISLAMIENTO POR EMPRESA: el idEmpresa acota A CUAL fila se le aplica el
    -- cambio, no es solo un campo mas a modificar. Sin el WHERE, un PUT con el
    -- id de un profesor de OTRA empresa lo modificaba igual — la pantalla no lo
    -- permite, pero el endpoint es publico para cualquiera con sesion.
    --
    -- ID_EMPRESA sale del SET a proposito: mover una fila de empresa es lo que
    -- este control busca impedir, y dejarlo modificable seria la puerta de
    -- atras al mismo problema.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- Existe Y es de esta empresa? Se comprueba ANTES de los UNIQUE: si la fila
    -- no es suya, el 404 tiene que ganarle al 409. Al reves, un 409 confirmaria
    -- que el id existe, que es informacion que quien pregunta no deberia
    -- obtener.
    SELECT COUNT(*)
      INTO l_existe
      FROM PROFESORES
     WHERE ID_PROFESOR = l_id
       AND ID_EMPRESA  = l_id_empresa;

    IF l_existe = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El profesor no existe"}';
      RETURN;
    END IF;

    -- El UNIQUE, excluyendo la propia fila: sin el p_id_excluir, actualizar un
    -- profesor sin cambiarle la cedula chocaria contra si mismo.
    IF CI_REPETIDO(p_numero_ci, l_id) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otro profesor con esa cedula. La cedula es unica en todo el sistema, asi que puede estar cargado en otra empresa"}';
      RETURN;
    END IF;

    IF NOT USUARIO_EXISTE(l_id_usuario) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La cuenta de usuario indicada no existe"}';
      RETURN;
    END IF;

    IF USUARIO_REPETIDO(l_id_usuario, l_id) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Esa cuenta de usuario ya esta vinculada a otro profesor. El vinculo es unico en todo el sistema, asi que puede ser de otra empresa"}';
      RETURN;
    END IF;

    -- NVL en cada columna: un parametro ausente conserva el valor actual.
    --
    -- Consecuencia: mandar un campo vacio significa "no cambiar", NO "borrar".
    -- Es el mismo criterio que el resto del proyecto. La UNICA excepcion es
    -- ID_USUARIO, que si tiene como vaciarse — por eso el CASE en vez del NVL.
    UPDATE PROFESORES
       SET NUMERO_CI           = NVL(TRIM(p_numero_ci), NUMERO_CI),
           NOMBRE              = NVL(TRIM(p_nombre), NOMBRE),
           APELLIDO            = NVL(TRIM(p_apellido), APELLIDO),
           DIRECCION           = NVL(TRIM(p_direccion), DIRECCION),
           TELEFONO            = NVL(TRIM(p_telefono), TELEFONO),
           CORREO              = NVL(TRIM(p_correo), CORREO),
           ID_USUARIO          = CASE
                                   WHEN l_desvincular THEN NULL
                                   ELSE NVL(l_id_usuario, ID_USUARIO)
                                 END,
           ACTIVO              = NVL(l_estado, ACTIVO),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_PROFESOR = l_id
       AND ID_EMPRESA  = l_id_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El profesor no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"La cedula ya esta registrada"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La cuenta de usuario indicada no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_PROFESORES.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar el profesor: ' ||
                       REPLACE(
                         REPLACE(
                           REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                           CHR(10), ' '),
                         CHR(13), ' ') ||
                       '"}';
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

    l_id         := A_NUMERO(p_id);
    l_id_empresa := A_NUMERO(p_id_empresa);

    -- Obligatorio: sin empresa el DELETE alcanzaria filas de cualquiera.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- AISLAMIENTO POR EMPRESA: las dos condiciones. Con solo el id, un DELETE
    -- con el id de un profesor de otra empresa lo borraba.
    --
    -- BAJA FISICA. Ahora que la tabla tiene ACTIVO, la baja logica —un PUT con
    -- activo='I'— es el camino normal y este DELETE queda para el caso de una
    -- carga equivocada. Se mantiene porque una fila cargada por error no tiene
    -- por que quedar como registro inactivo para siempre.
    DELETE FROM PROFESORES
     WHERE ID_PROFESOR = l_id
       AND ID_EMPRESA  = l_id_empresa;

    -- 404 tambien cuando existe pero es de otra empresa: no se confirma que el
    -- id exista.
    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El profesor no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos (materias, cursos, lo que cuelgue del profesor)
      -- apuntando a esta fila. Es un conflicto de estado (409), no un error del
      -- servidor: el dato que mandaron era valido. El mensaje sugiere la baja
      -- logica, que es lo que resuelve el caso sin perder el historial.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de este profesor. Se lo puede inactivar en su lugar"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_PROFESORES.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar el profesor: ' ||
                       REPLACE(
                         REPLACE(
                           REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                           CHR(10), ' '),
                         CHR(13), ' ') ||
                       '"}';
      END IF;
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Guarda la foto de un profesor. CON token: escribir nunca es publico.
  --
  -- El binario llega como el cuerpo crudo del PUT (ORDS lo mapea a un BLOB) y
  -- el formato, del header Content-Type. Se acepta solo image/*: sin ese
  -- control, cualquier archivo quedaria guardado y despues se serviria de
  -- vuelta con su content-type a quien abra el listado.
  --
  -- El techo de 2 MB se valida ACA y no solo en el cliente: la pantalla
  -- redimensiona antes de subir, pero el endpoint esta abierto a cualquiera con
  -- sesion y una foto de camara sin procesar son varios MB por fila.
  ------------------------------------------------------------------------------
  PROCEDURE GUARDAR_FOTO (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_foto          IN  BLOB,
    p_content_type  IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_id     NUMBER;
    l_mime   VARCHAR2(100);
    l_bytes  NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id := A_NUMERO(p_id);

    IF p_foto IS NULL OR DBMS_LOB.GETLENGTH(p_foto) = 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"No se recibio ninguna foto"}';
      RETURN;
    END IF;

    l_bytes := DBMS_LOB.GETLENGTH(p_foto);
    IF l_bytes > C_FOTO_MAX_BYTES THEN
      p_status_code := 413;
      p_resultado := '{"error":"La foto supera el maximo de 2 MB"}';
      RETURN;
    END IF;

    -- El header puede venir con parametros ("image/jpeg; charset=..."), asi que
    -- se corta en el punto y coma antes de guardarlo.
    l_mime := LOWER(TRIM(REGEXP_SUBSTR(p_content_type, '^[^;]+')));

    IF l_mime IS NULL OR l_mime NOT LIKE 'image/%' THEN
      p_status_code := 400;
      p_resultado := '{"error":"El archivo debe ser una imagen"}';
      RETURN;
    END IF;

    -- Sin filtro por empresa, a diferencia del resto del paquete: ORDS no pasa
    -- el idEmpresa en este PUT —el cuerpo es el binario, no un JSON del que
    -- sacarlo— y meterlo en la URL obligaria a un template distinto al del GET
    -- publico, que es el que arma el <img>. El riesgo es acotado: hace falta
    -- una sesion valida y adivinar el id de un profesor ajeno para pisarle la
    -- foto, sin poder leer ningun otro dato.
    UPDATE PROFESORES
       SET FOTO                = p_foto,
           FOTO_MIME           = l_mime,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_PROFESOR = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El profesor no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_PROFESORES.GUARDAR_FOTO: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al guardar la foto"}';
  END GUARDAR_FOTO;

  ------------------------------------------------------------------------------
  -- Publica el modulo ORDS /profesores/ con sus 6 endpoints.
  --
  -- Cada handler PL/SQL es una sola linea: invoca al procedimiento del paquete
  -- pasando los binds de ORDS como argumentos. Nada de PL/SQL embebido. La
  -- excepcion es el GET de la foto, que es una consulta por source_type_media.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un parametro
  -- de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin esto, toda
  -- peticion cross-origin a /profesores/* la rechaza ORDS antes de llegar a
  -- cualquiera de los handlers. Ver la explicacion en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'profesores',
      p_base_path      => '/profesores/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'ABM de profesores por empresa'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'profesores',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /profesores/listar?idEmpresa=&busqueda=&activo=
    --
    -- Los query params no se declaran con DEFINE_PARAMETER: se vinculan solos
    -- al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'profesores', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'profesores',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PROFESORES.LISTAR(:authorization, :idEmpresa, :busqueda, :activo, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /profesores/crear
    -- Body: { idEmpresa, numeroCi, nombre, apellido,
    --         direccion?, telefono?, correo?, idUsuario? }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'profesores', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'profesores',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PROFESORES.INSERTAR(:authorization, :idEmpresa, :numeroCi, :nombre, :apellido, :direccion, :telefono, :correo, :idUsuario, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /profesores/actualizar/:id
    -- Body: { idEmpresa, numeroCi?, nombre?, apellido?, direccion?, telefono?,
    --         correo?, idUsuario?, activo? }
    --       (ausentes = no cambia; idUsuario = 0 desvincula la cuenta)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'profesores', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'profesores',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PROFESORES.ACTUALIZAR(:authorization, :id, :idEmpresa, :numeroCi, :nombre, :apellido, :direccion, :telefono, :correo, :idUsuario, :activo, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /profesores/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'profesores', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'profesores',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PROFESORES.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /profesores/foto/:id — SIN TOKEN
    --
    -- Devuelve la foto cruda, no un JSON, y por eso NO se publica como los
    -- demas endpoints.
    --
    -- POR QUE NO ES UN HANDLER PL/SQL CON PARAMETRO DE SALIDA:
    -- La forma "natural" seria un procedimiento con un OUT BLOB declarado como
    -- p_source_type => 'RESPONSE'. No funciona: DEFINE_PARAMETER valida
    -- p_param_type contra REST_PARAMS_PARAM_TYPE_CK, que admite un conjunto
    -- cerrado de valores, y ni 'BLOB' ni 'RESOURCE' pasan esa restriccion en
    -- esta instalacion. El ORA-02290 aborta PUBLICAR_ENDPOINTS a la mitad y
    -- deja el modulo SIN NINGUN endpoint. Ya costo dos intentos descubrirlo con
    -- el logo de empresas; no repetir el camino.
    --
    -- LA FORMA QUE SI FUNCIONA: source_type_media. ORDS toma una consulta que
    -- devuelve DOS columnas —content-type y BLOB, en ese orden— y arma la
    -- respuesta binaria el mismo, sin parametros de salida que declarar.
    --
    -- El 404 de la foto faltante sale solo: si la consulta no devuelve filas,
    -- ORDS responde 404 sin que haya que manejar un status code a mano. Por eso
    -- el WHERE filtra los BLOB vacios en vez de devolverlos.
    --
    -- El mismo template lleva tambien el PUT que guarda la foto, mas abajo.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'profesores', p_pattern => 'foto/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'profesores',
      p_pattern     => 'foto/:id',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_media,
      p_source      => 'SELECT NVL(FOTO_MIME, ''image/jpeg''), FOTO
                          FROM PROFESORES
                         WHERE ID_PROFESOR = :id
                           AND FOTO IS NOT NULL
                           AND DBMS_LOB.GETLENGTH(FOTO) > 0'
    );

    ----------------------------------------------------------------------------
    -- PUT /profesores/foto/:id — con token
    -- Body: la foto cruda. Content-Type: image/jpeg, image/png, etc.
    --
    -- SIN image/svg+xml, a diferencia de db/articulos.sql: un SVG es un
    -- documento que puede llevar script, y aca la foto sale de una camara o de
    -- la galeria. Ningun caso legitimo manda un SVG como foto de una persona.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_HANDLER(
      p_module_name   => 'profesores',
      p_pattern       => 'foto/:id',
      p_method        => 'PUT',
      p_source_type   => ORDS.source_type_plsql,
      p_mimes_allowed => 'image/png,image/jpeg,image/webp',
      p_source        => 'BEGIN PKG_PROFESORES.GUARDAR_FOTO(:authorization, :id, :body, :content_type, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'foto/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    -- El Content-Type de entrada: de ahi sale el formato que se guarda.
    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'foto/:id', p_method => 'PUT',
      p_name => 'Content-Type', p_bind_variable_name => 'content_type',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'foto/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'foto/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_PROFESORES;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_PROFESORES.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_PROFESORES'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_PROFESORES'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'profesores';

-- Deben salir 6 filas: listar GET, crear POST, actualizar PUT, eliminar DELETE,
-- foto GET y foto PUT.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'profesores'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- LEFT JOIN contra USUARIOS, igual que el listado: con un INNER, los profesores
-- sin cuenta vinculada no apareceran y la verificacion mentiria.
SELECT p.ID_PROFESOR, e.NOMBRE_EMPRESA, p.NUMERO_CI,
       p.APELLIDO || ', ' || p.NOMBRE AS PROFESOR,
       p.TELEFONO, p.CORREO,
       NVL(u.USUARIO, '(sin cuenta)') AS CUENTA,
       p.ACTIVO,
       CASE WHEN p.FOTO IS NOT NULL AND DBMS_LOB.GETLENGTH(p.FOTO) > 0
            THEN 'SI' ELSE 'NO' END AS TIENE_FOTO,
       DBMS_LOB.GETLENGTH(p.FOTO) AS BYTES_FOTO
  FROM PROFESORES p
  JOIN EMPRESAS   e ON e.ID_EMPRESA = p.ID_EMPRESA
  LEFT JOIN USUARIOS u ON u.ID_USUARIO = p.ID_USUARIO
 ORDER BY e.NOMBRE_EMPRESA, p.APELLIDO, p.NOMBRE;

--------------------------------------------------------------------------------
-- ESTADOS FUERA DE 'A'/'I' — DEBE DEVOLVER CERO FILAS.
--
-- Si devuelve alguna, hay filas con la columna en NULL o con otro valor. El
-- listado las muestra como activas (NVL a 'A'), pero el filtro por estado no
-- las encuentra. Para normalizarlas:
--   UPDATE PROFESORES SET ACTIVO = 'A' WHERE NVL(UPPER(TRIM(ACTIVO)), 'X') NOT IN ('A', 'I');
--   COMMIT;
--------------------------------------------------------------------------------

SELECT ID_PROFESOR, ID_EMPRESA, ACTIVO
  FROM PROFESORES
 WHERE NVL(UPPER(TRIM(ACTIVO)), 'X') NOT IN ('A', 'I');

--------------------------------------------------------------------------------
-- CUENTAS DE USUARIO VINCULADAS A MAS DE UN PROFESOR — DEBE DEVOLVER CERO FILAS.
--
-- El DDL no declara UNIQUE sobre ID_USUARIO: el paquete lo impide, pero las
-- filas cargadas antes de este archivo pueden traer el duplicado. Una cuenta
-- que identifica a dos personas rompe cualquier lectura de "quien hizo esto".
--------------------------------------------------------------------------------

SELECT ID_USUARIO, COUNT(*) AS CUANTOS
  FROM PROFESORES
 WHERE ID_USUARIO IS NOT NULL
 GROUP BY ID_USUARIO
HAVING COUNT(*) > 1;
