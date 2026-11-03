-- CTELL · MANUALES
--
-- Un paquete (PKG_MANUALES) con los procedimientos del CRUD — LISTAR,
-- INSERTAR, ACTUALIZAR, ELIMINAR — mas la carga del PDF, y la publicacion de
-- los endpoints ORDS. Todo vive dentro del paquete: no hay procedimientos
-- sueltos ni PL/SQL embebido como texto dentro de los handlers.
--
--   1. LISTAR        GET    /manuales/listar  (?idEmpresa= &idInstitucion= &grado= &busqueda=)
--   2. INSERTAR      POST   /manuales/crear
--   3. ACTUALIZAR    PUT    /manuales/actualizar/:id
--   4. ELIMINAR      DELETE /manuales/eliminar/:id/:idEmpresa
--   5. (sin PL/SQL)  GET    /manuales/archivo/:id   (SIN TOKEN, media; solo los viejos)
--   6. GUARDAR_ARCHIVO PUT  /manuales/archivo-url/:id   (con token)
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql Y db/cloudinary.sql EJECUTADOS
-- ANTES: usa PKG_AUTH para validar el token y PKG_CLOUDINARY para borrar el
-- PDF reemplazado.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/manuales/
--
-- Tabla (no la crea ni la altera, salvo ARCHIVO_MIME, ARCHIVO_URL y
-- ARCHIVO_BYTES del paso 0):
--   MANUALES  ID_MANUAL, ID_INSTITUCION, GRADO, ARCHIVO_PDF, ARCHIVO_URL,
--             ARCHIVO_BYTES, FECHA_CARGA, FECHA_ACTUALIZACION
--
--------------------------------------------------------------------------------
-- LA TABLA NO TIENE ID_EMPRESA, Y ESO CAMBIA COMO SE AISLA
--
-- Todas las tablas por empresa del proyecto llevan su propia columna
-- ID_EMPRESA, y el WHERE del UPDATE/DELETE la usa para acotar la fila. MANUALES
-- NO LA TIENE: cuelga de INSTITUCIONES, que si es por empresa.
--
-- Agregarla seria denormalizar —el mismo dato en dos lugares, con la puerta
-- abierta a que un manual quede en una empresa y su institucion en otra—, asi
-- que el aislamiento se hace CONTRA EL PADRE, con un JOIN. Es el caso que la
-- guia llama "si no tiene columna ID_EMPRESA (detalle o cruce): se valida
-- contra el padre con un JOIN antes de escribir".
--
-- En la practica, cada operacion:
--
--   LISTAR      JOIN INSTITUCIONES + WHERE i.ID_EMPRESA = :idEmpresa
--   INSERTAR    comprueba que la institucion sea de esa empresa -> 400 si no
--   ACTUALIZAR  EXISTS contra INSTITUCIONES en el WHERE del UPDATE
--   ELIMINAR    idem, con /eliminar/:id/:idEmpresa
--
-- SIN eso, un PUT con el id de un manual de otra empresa lo modificaba igual:
-- la pantalla no lo permite, pero el endpoint esta abierto a cualquiera con
-- sesion.
--
-- Y OJO CON LA INSTITUCION DE DESTINO: al mover un manual de institucion hay
-- que validar que la NUEVA tambien sea de la empresa de la sesion. Validar solo
-- la fila que se edita dejaria pasar un manual hacia una institucion ajena, que
-- es la misma fuga por la puerta de atras.
--
--------------------------------------------------------------------------------
-- UNIQUE (ID_INSTITUCION, GRADO): UN MANUAL POR GRADO Y POR INSTITUCION
--
-- El DDL declara UNIQUE (ID_INSTITUCION, GRADO). No es global como el de la
-- cedula en PROFESORES: dos instituciones distintas pueden tener cada una su
-- manual de 3er grado, que es justamente lo esperado.
--
-- SE CONSULTA ANTES DE INSERTAR en vez de esperar al DUP_VAL_ON_INDEX, para
-- poder nombrar el caso en el mensaje: la excepcion no dice cual indice se
-- violo, y el error quedaria en "algun dato esta repetido". El
-- DUP_VAL_ON_INDEX se captura igual como red de seguridad, por si dos altas
-- simultaneas pasan la validacion antes de que cualquiera escriba.
--
-- Como el manual es unico por (institucion, grado), REEMPLAZAR el PDF es la
-- operacion normal: no se carga un segundo manual del mismo grado, se sube otra
-- vez el archivo sobre la misma fila.
--
--------------------------------------------------------------------------------
-- GRADO: DOCE VALORES, VALIDADOS ACA
--
-- La columna es VARCHAR2(5) y el COMMENT enumera los valores permitidos:
--
--   1ro.  2do.  3er.  4to.  5to.  6to.  7mo.  8vo.  9no.  1ME.  2ME.  3ME.
--
-- PERO UN COMMENT NO ES UNA RESTRICCION —es la leccion que el proyecto ya
-- aprendio con ID_LISTA_DESCUENTOS— y el DDL no tiene ningun CHECK. Sin
-- validarlo, el endpoint acepta '1ro' sin punto, '13vo' o 'xxxxx', y cada
-- variante entra como un grado distinto que el UNIQUE deja pasar: la
-- institucion termina con dos manuales de primero que la pantalla muestra como
-- filas separadas.
--
-- La lista vive en GRADO_VALIDO y se repite en el frontend
-- (GRADOS en src/lib/api.ts). Si se agrega un grado, VAN LOS DOS.
--
-- Se normaliza con TRIM antes de comparar y de guardar; NO se toca la
-- capitalizacion: 'ME' va en mayusculas y 'ro'/'do' en minusculas, asi que un
-- UPPER convertiria '1ro.' en '1RO.' y ninguno de los dos matchearia.
--
--------------------------------------------------------------------------------
-- EL PDF: EN CLOUDINARY, NO EN LA BASE
--
-- El navegador sube el PDF directo a Cloudinary (src/lib/cloudinary.ts) y aca
-- se guarda solo la URL, en ARCHIVO_URL, con su peso en ARCHIVO_BYTES. Es el
-- mismo cambio que la imagen de db/articulos.sql, y aca pesa mas que en ningun
-- otro lado: un manual escaneado son varios MB, y el esquema tiene una cuota de
-- 25 MB compartida que los BLOB ya llenaron una vez (ORA-01536 en todo INSERT
-- de cualquier tabla). Tres manuales alcanzaban para trabar el sistema entero.
--
--   PUT /manuales/archivo-url/:id  Body { idEmpresa, archivoUrl, bytes }. Con
--     token y aislado por empresa —ahora se puede: el body es un JSON—. Guarda
--     la URL, VACIA EL BLOB VIEJO, mueve FECHA_CARGA y borra de Cloudinary el
--     PDF anterior.
--
--   GET /manuales/archivo/:id  SIGUE PUBLICADO, solo para los PDF cargados
--     antes del cambio. Se retira cuando la consulta del pie diga que no queda
--     ningun BLOB.
--
-- NO HAY PUT DEL BINARIO: se retiro a proposito. Mientras existiera, un cliente
-- viejo (una PWA cacheada) podia volver a llenar la base sin que nadie lo
-- notara. Template nuevo (archivo-url) y no un PUT JSON en archivo/:id: ahi ese
-- cliente mandaria el binario a un handler que espera JSON.
--
-- LA URL SE VALIDA CONTRA https://: termina en un <a href>, y sin eso un
-- "javascript:..." se guarda igual. El riesgo viejo —servir un HTML con script
-- desde el origen de la API— desaparece: el archivo lo sirve Cloudinary, desde
-- su dominio.
--
-- ELIMINAR EL MANUAL O REEMPLAZAR EL PDF BORRA EL ARCHIVO EN CLOUDINARY, con
-- PKG_CLOUDINARY.BORRAR despues del COMMIT (best effort: ver db/cloudinary.sql).
--
-- El listado devuelve `archivoUrl` (o null) y `tieneArchivo`, que es true con
-- CUALQUIERA de las dos: con URL la pantalla abre la URL; sin URL y con
-- tieneArchivo, es un PDF viejo y lo pide a /manuales/archivo/:id. Y ademas
-- `bytesArchivo`, para mostrar el peso: un manual escaneado de 40 MB explica
-- solo por que tarda en abrir.
--
-- PUBLICO, igual que antes: cualquiera con la URL ve el manual. Se acepta
-- porque un manual escolar es material para distribuir —el caso de uso es
-- justamente que llegue a quien lo necesita— y el link compartible sigue
-- andando.
--
-- TAMAÑO: el techo lo pone Cloudinary, no este paquete (en el plan gratuito,
-- 10 MB por archivo). Un PDF no se puede recomprimir en el navegador sin
-- destruirlo: un escaneo mas pesado hay que achicarlo antes de subirlo.
--
--------------------------------------------------------------------------------
-- SIN COLUMNA ACTIVO: LA BAJA ES FISICA
--
-- La tabla no tiene ACTIVO, asi que no hay baja logica ni filtro por estado, y
-- el ACTUALIZAR no recibe p_activo. Es coherente con lo que la tabla modela: un
-- manual que ya no corre no se inactiva, se reemplaza por el nuevo del mismo
-- grado (el UNIQUE lo garantiza) o se borra.
--
-- No se le agrega la columna: el DDL lo administra otro, y estos archivos no
-- crean ni alteran tablas —salvo ARCHIVO_MIME del paso 0, que es la excepcion
-- documentada para servir un binario con su content-type.
--
--------------------------------------------------------------------------------
-- FECHA_CARGA VS FECHA_ACTUALIZACION
--
-- Las dos tienen DEFAULT SYSTIMESTAMP y se escriben explicitas en el INSERT,
-- por el mismo criterio que el 'A' de los demas paquetes: no depender de un
-- default que puede cambiar en el DDL.
--
-- Despues del alta significan cosas distintas y por eso el paquete las mueve
-- distinto:
--
--   FECHA_CARGA          se toca CUANDO ENTRA UN PDF (el alta y cada PUT del
--                        archivo). Responde "de cuando es este manual".
--   FECHA_ACTUALIZACION  se toca en CUALQUIER cambio de la fila, incluido
--                        corregir el grado sin tocar el archivo.
--
-- Si el ACTUALIZAR moviera FECHA_CARGA, arreglar un grado mal tipeado haria
-- figurar el manual como recien cargado.
--
--------------------------------------------------------------------------------
-- SIN JOIN CONTRA EMPRESAS: el listado no devuelve el nombre de la empresa.
-- Viene filtrado por una sola —la de la sesion— asi que seria la misma
-- constante repetida en cada fila. Mismo criterio que db/monedas.sql.
--
-- SI HAY JOIN CONTRA INSTITUCIONES, y es INTERNO a proposito: ID_INSTITUCION es
-- NOT NULL con FK, asi que toda fila tiene su institucion y no hay ninguna que
-- un INNER pueda esconder. Ademas es el JOIN que hace el filtro por empresa —
-- con un LEFT, un manual cuya institucion no matchea el WHERE se colaria en el
-- listado de otra empresa.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 0. Columna ARCHIVO_MIME
--
-- UNICA excepcion a la regla de que estos archivos no tocan el DDL. Es una
-- columna nueva y opcional que el paquete necesita para servir el PDF con el
-- content-type correcto, asi que se agrega aca en vez de dejar el archivo sin
-- poder ejecutarse hasta que alguien la cree a mano. Mismo criterio que
-- FOTO_MIME en db/profesores.sql e IMAGEN_MIME en db/articulos.sql.
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
   WHERE TABLE_NAME = 'MANUALES'
     AND COLUMN_NAME = 'ARCHIVO_MIME';

  IF l_existe = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE MANUALES ADD (ARCHIVO_MIME VARCHAR2(100))';
  END IF;
END;
/

-- ARCHIVO_URL y ARCHIVO_BYTES: la direccion del PDF en Cloudinary y su peso.
-- Mismo criterio que la de arriba —columnas nuevas y opcionales sin las cuales
-- el paquete no compila—. El peso se guarda porque ya no hay un BLOB al que
-- preguntarle con GETLENGTH, y el listado lo muestra.
DECLARE
  l_existe PLS_INTEGER;
BEGIN
  SELECT COUNT(*)
    INTO l_existe
    FROM USER_TAB_COLUMNS
   WHERE TABLE_NAME = 'MANUALES'
     AND COLUMN_NAME = 'ARCHIVO_URL';

  IF l_existe = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE MANUALES ADD (ARCHIVO_URL VARCHAR2(500))';
  END IF;

  SELECT COUNT(*)
    INTO l_existe
    FROM USER_TAB_COLUMNS
   WHERE TABLE_NAME = 'MANUALES'
     AND COLUMN_NAME = 'ARCHIVO_BYTES';

  IF l_existe = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE MANUALES ADD (ARCHIVO_BYTES NUMBER)';
  END IF;
END;
/

--------------------------------------------------------------------------------
-- 1. PKG_MANUALES
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_MANUALES.LISTAR('Bearer TU_TOKEN', '1', NULL, NULL, NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_MANUALES AS

  -- p_id_empresa es OBLIGATORIO (400 si falta), a diferencia del resto de los
  -- listados del proyecto, donde vacio significa "todas las empresas".
  --
  -- El motivo es que aca la empresa no es una columna sino el JOIN con
  -- INSTITUCIONES: sin ella la consulta no se acota sola, devuelve los manuales
  -- de todo el sistema. En una tabla con ID_EMPRESA el olvido se nota en el
  -- listado; aca pasaria desapercibido hasta que una institucion vea los
  -- manuales de otra.
  --
  -- p_id_institucion y p_grado filtran; NULL o vacio no filtran.
  -- p_busqueda mira el nombre de la institucion y el grado.
  PROCEDURE LISTAR (
    p_authorization   IN  VARCHAR2,
    p_id_empresa      IN  VARCHAR2,
    p_id_institucion  IN  VARCHAR2,
    p_grado           IN  VARCHAR2,
    p_busqueda        IN  VARCHAR2,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  );

  -- idEmpresa, idInstitucion y grado son obligatorios. El PDF NO se carga aca:
  -- va por PUT /manuales/archivo-url/:id despues del alta, cuando ya hay un id al
  -- que asociarlo.
  --
  -- idEmpresa no es una columna de MANUALES: sirve para comprobar que la
  -- institucion sea de la empresa de la sesion.
  PROCEDURE INSERTAR (
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_grado          IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  );

  -- Los parametros ausentes (NULL) no modifican la columna correspondiente.
  -- Es la regla del proyecto, y aca aplica sin excepciones: no hay ningun campo
  -- que se pueda "desvincular", asi que no hace falta ningun centinela.
  --
  -- p_id_empresa es obligatorio: acota A CUAL fila se aplica el cambio.
  PROCEDURE ACTUALIZAR (
    p_authorization  IN  VARCHAR2,
    p_id             IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_grado          IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  );

  -- p_id_empresa es OBLIGATORIO: acota el borrado a la empresa de la sesion.
  --
  -- Es baja FISICA, y la unica que hay: la tabla no tiene columna ACTIVO.
  -- Borra tambien el PDF de Cloudinary (o el BLOB viejo, que vive en la fila).
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- NO hay procedimiento para SERVIR el PDF: el GET /manuales/archivo/:id se
  -- publica como source_type_media. Ver el comentario en PUBLICAR_ENDPOINTS.
  --
  -- Guarda la URL del PDF, que el navegador ya subio a Cloudinary, y vacia el
  -- BLOB viejo si lo habia. CON token y acotado a la empresa.
  PROCEDURE GUARDAR_ARCHIVO (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_archivo_url   IN  VARCHAR2,
    p_bytes         IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /manuales/ con sus 6 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_MANUALES;
/

CREATE OR REPLACE PACKAGE BODY PKG_MANUALES AS

  -- El largo de MANUALES.ARCHIVO_URL (ver el paso 0). Pasarlo daria ORA-12899.
  C_MAX_URL CONSTANT PLS_INTEGER := 500;

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
         WHERE NAME = 'manuales';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'manuales');
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
  -- Privado: el grado es uno de los doce que admite la columna.
  --
  -- El DDL NO tiene CHECK constraint: solo un COMMENT que los enumera, y un
  -- COMMENT no es una restriccion. Sin esta validacion el endpoint acepta '1ro'
  -- sin punto o '13vo', y cada variante entra como un grado distinto que el
  -- UNIQUE (ID_INSTITUCION, GRADO) deja pasar tranquilo: la institucion termina
  -- con dos manuales de primero, que en la pantalla son dos filas y en la
  -- realidad son el mismo grado.
  --
  -- SIN UPPER en la comparacion: los valores mezclan mayusculas y minusculas a
  -- proposito ('1ro.' pero '1ME.'), asi que normalizar la capitalizacion haria
  -- que ningun valor legitimo matcheara. Solo TRIM.
  --
  -- LA MISMA LISTA ESTA EN EL FRONTEND (GRADOS, en src/lib/api.ts). Si se
  -- agrega un grado, van los dos: aca para que el endpoint lo acepte, alla para
  -- que el selector lo ofrezca.
  ------------------------------------------------------------------------------
  FUNCTION GRADO_VALIDO (p_grado IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN TRIM(p_grado) IN (
      '1ro.', '2do.', '3er.', '4to.', '5to.', '6to.',
      '7mo.', '8vo.', '9no.', '1ME.', '2ME.', '3ME.'
    );
  END GRADO_VALIDO;

  ------------------------------------------------------------------------------
  -- Privado: esa institucion existe Y es de esa empresa.
  --
  -- Las dos preguntas en una: si la institucion es de otra empresa, para esta
  -- sesion es lo mismo que si no existiera. Devolver un mensaje distinto para
  -- cada caso confirmaria que el id existe, que es informacion que quien
  -- pregunta no deberia obtener.
  --
  -- ES LO QUE REEMPLAZA AL `AND ID_EMPRESA = :idEmpresa` que tienen las tablas
  -- con columna propia. Sin esta comprobacion, el alta acepta cualquier
  -- idInstitucion y la FK lo deja pasar —valida que la institucion exista, no
  -- de quien es— dejando un manual de una empresa colgado de la institucion de
  -- otra.
  ------------------------------------------------------------------------------
  FUNCTION INSTITUCION_ES_DE_EMPRESA (
    p_id_institucion IN NUMBER,
    p_id_empresa     IN NUMBER
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    IF p_id_institucion IS NULL OR p_id_empresa IS NULL THEN
      RETURN FALSE;
    END IF;

    SELECT COUNT(*)
      INTO l_existe
      FROM INSTITUCIONES
     WHERE ID_INSTITUCION = p_id_institucion
       AND ID_EMPRESA     = p_id_empresa;

    RETURN l_existe > 0;
  END INSTITUCION_ES_DE_EMPRESA;

  ------------------------------------------------------------------------------
  -- Privado: esa institucion ya tiene un manual de ese grado.
  --
  -- El UNIQUE es (ID_INSTITUCION, GRADO) y NO incluye la empresa: no hace falta,
  -- porque la institucion ya pertenece a una sola. Dos instituciones distintas
  -- pueden tener cada una su manual de 3er grado.
  --
  -- p_id_excluir es la fila que se esta editando: sin el, guardar un manual sin
  -- cambiarle ni la institucion ni el grado chocaria contra si mismo.
  ------------------------------------------------------------------------------
  FUNCTION MANUAL_REPETIDO (
    p_id_institucion IN NUMBER,
    p_grado          IN VARCHAR2,
    p_id_excluir     IN NUMBER DEFAULT NULL
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    IF p_id_institucion IS NULL OR TRIM(p_grado) IS NULL THEN
      RETURN FALSE;
    END IF;

    SELECT COUNT(*)
      INTO l_existe
      FROM MANUALES
     WHERE ID_INSTITUCION = p_id_institucion
       AND TRIM(GRADO)    = TRIM(p_grado)
       AND (p_id_excluir IS NULL OR ID_MANUAL != p_id_excluir);

    RETURN l_existe > 0;
  END MANUAL_REPETIDO;

  PROCEDURE LISTAR (
    p_authorization   IN  VARCHAR2,
    p_id_empresa      IN  VARCHAR2,
    p_id_institucion  IN  VARCHAR2,
    p_grado           IN  VARCHAR2,
    p_busqueda        IN  VARCHAR2,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  ) IS
    l_sesion         NUMBER;
    l_id_empresa     NUMBER;
    l_id_institucion NUMBER;
    l_grado          VARCHAR2(5);
    l_busqueda       VARCHAR2(200);
    l_total          NUMBER;
    l_items          CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van aca, dentro del BEGIN: en el DECLARE se ejecutarian
    -- antes de que exista el EXCEPTION y el error escaparia del procedimiento.
    l_id_empresa     := A_NUMERO(p_id_empresa);
    l_id_institucion := A_NUMERO(p_id_institucion);
    l_grado          := NULLIF(TRIM(p_grado), '');
    l_busqueda       := UPPER(NULLIF(TRIM(p_busqueda), ''));

    -- OBLIGATORIO, a diferencia de los demas listados del proyecto: la empresa
    -- no es una columna de MANUALES sino el JOIN con INSTITUCIONES, asi que sin
    -- ella la consulta devolveria los manuales de TODAS las empresas en vez de
    -- los de ninguna. Un olvido silencioso es exactamente lo que hay que evitar.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- El JOIN es INTERNO y es el que hace el filtro por empresa: ID_INSTITUCION
    -- es NOT NULL con FK, asi que no hay ninguna fila que un INNER pueda
    -- esconder, y con un LEFT un manual cuya institucion no matchea el WHERE se
    -- colaria en el listado de otra empresa.
    SELECT COUNT(*)
      INTO l_total
      FROM MANUALES m
      JOIN INSTITUCIONES i ON i.ID_INSTITUCION = m.ID_INSTITUCION
     WHERE i.ID_EMPRESA = l_id_empresa
       AND (l_id_institucion IS NULL OR m.ID_INSTITUCION = l_id_institucion)
       AND (l_grado          IS NULL OR TRIM(m.GRADO)    = l_grado)
       AND (l_busqueda       IS NULL
            OR UPPER(i.NOMBRE_INSTITUCION) LIKE '%' || l_busqueda || '%'
            OR UPPER(m.GRADO)              LIKE '%' || l_busqueda || '%');

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY nombre_institucion, orden_grado RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'                VALUE m.ID_MANUAL,
                 'idInstitucion'     VALUE m.ID_INSTITUCION,
                 'institucion'       VALUE i.NOMBRE_INSTITUCION,
                 'grado'             VALUE TRIM(m.GRADO),
                 -- La de Cloudinary, sólo si es https: termina en un <a href>.
                 'archivoUrl'        VALUE CASE
                                             WHEN LOWER(SUBSTR(m.ARCHIVO_URL, 1, 8)) = 'https://'
                                             THEN m.ARCHIVO_URL
                                           END,
                 -- True con cualquiera de las dos: sin URL y con tieneArchivo,
                 -- es un PDF viejo que se pide a /manuales/archivo/:id.
                 -- GETLENGTH > 0 y no IS NOT NULL: una fila puede tener un BLOB
                 -- vacio, que no sirve como archivo y haria fallar la descarga.
                 'tieneArchivo'      VALUE CASE
                                             WHEN LOWER(SUBSTR(m.ARCHIVO_URL, 1, 8)) = 'https://'
                                             THEN 'true'
                                             WHEN m.ARCHIVO_PDF IS NOT NULL
                                              AND DBMS_LOB.GETLENGTH(m.ARCHIVO_PDF) > 0
                                             THEN 'true' ELSE 'false'
                                           END FORMAT JSON,
                 -- El peso, para mostrarlo al lado del nombre: un manual de
                 -- 40 MB explica solo por que tarda en abrir. 0 si no hay
                 -- archivo, para que el frontend no tenga que contemplar null.
                 'bytesArchivo'      VALUE CASE
                                             WHEN m.ARCHIVO_URL IS NOT NULL
                                             THEN NVL(m.ARCHIVO_BYTES, 0)
                                             ELSE NVL(DBMS_LOB.GETLENGTH(m.ARCHIVO_PDF), 0)
                                           END,
                 'fechaCarga'        VALUE TO_CHAR(m.FECHA_CARGA, 'YYYY-MM-DD"T"HH24:MI:SS'),
                 'fechaActualizacion' VALUE TO_CHAR(m.FECHA_ACTUALIZACION, 'YYYY-MM-DD"T"HH24:MI:SS')
                 RETURNING CLOB
               ) AS fila,
               i.NOMBRE_INSTITUCION AS nombre_institucion,
               -- Los grados se ordenan por su posicion real, no alfabeticamente:
               -- con un ORDER BY GRADO, '1ME.' cae entre '1ro.' y '2do.' y la
               -- media queda intercalada con la escolar basica.
               CASE TRIM(m.GRADO)
                 WHEN '1ro.' THEN 1  WHEN '2do.' THEN 2  WHEN '3er.' THEN 3
                 WHEN '4to.' THEN 4  WHEN '5to.' THEN 5  WHEN '6to.' THEN 6
                 WHEN '7mo.' THEN 7  WHEN '8vo.' THEN 8  WHEN '9no.' THEN 9
                 WHEN '1ME.' THEN 10 WHEN '2ME.' THEN 11 WHEN '3ME.' THEN 12
                 ELSE 99  -- Un grado fuera de lista (cargado antes de este archivo) va al final.
               END AS orden_grado
          FROM MANUALES m
          JOIN INSTITUCIONES i ON i.ID_INSTITUCION = m.ID_INSTITUCION
         WHERE i.ID_EMPRESA = l_id_empresa
           AND (l_id_institucion IS NULL OR m.ID_INSTITUCION = l_id_institucion)
           AND (l_grado          IS NULL OR TRIM(m.GRADO)    = l_grado)
           AND (l_busqueda       IS NULL
                OR UPPER(i.NOMBRE_INSTITUCION) LIKE '%' || l_busqueda || '%'
                OR UPPER(m.GRADO)              LIKE '%' || l_busqueda || '%')
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
      APEX_DEBUG.ERROR('PKG_MANUALES.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      -- El SQLERRM viaja en la respuesta: el mensaje generico deja el 500 sin
      -- diagnostico y APEX_DEBUG escribe en un log del workspace que hay que ir
      -- a buscar. REPLACE saca las comillas y los saltos de linea, que romperian
      -- el JSON.
      p_resultado := '{"error":"Error al listar los manuales: ' ||
                     REPLACE(
                       REPLACE(
                         REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                         CHR(10), ' '),
                       CHR(13), ' ') ||
                     '"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_grado          IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  ) IS
    l_sesion         NUMBER;
    l_id             NUMBER;
    l_id_empresa     NUMBER;
    l_id_institucion NUMBER;
    l_grado          VARCHAR2(5);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_empresa     := A_NUMERO(p_id_empresa);
    l_id_institucion := A_NUMERO(p_id_institucion);
    l_grado          := NULLIF(TRIM(p_grado), '');

    -- Las dos columnas NOT NULL del DDL, mas el idEmpresa que acota la
    -- institucion. Sin esto el INSERT moriria con ORA-01400 (500); validado
    -- aca devuelve un 400 que dice cual falta.
    IF l_id_empresa IS NULL OR l_id_institucion IS NULL OR l_grado IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, idInstitucion y grado son obligatorios"}';
      RETURN;
    END IF;

    -- El COMMENT enumera los doce valores pero no hay CHECK que los imponga.
    IF NOT GRADO_VALIDO(l_grado) THEN
      p_status_code := 400;
      p_resultado := '{"error":"El grado no es valido. Valores permitidos: 1ro., 2do., 3er., 4to., 5to., 6to., 7mo., 8vo., 9no., 1ME., 2ME., 3ME."}';
      RETURN;
    END IF;

    -- AISLAMIENTO POR EMPRESA, contra el padre: MANUALES no tiene ID_EMPRESA.
    -- La FK sola no alcanza —valida que la institucion exista, no de quien es—
    -- y sin esto se podria colgar un manual de la institucion de otra empresa.
    IF NOT INSTITUCION_ES_DE_EMPRESA(l_id_institucion, l_id_empresa) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La institucion indicada no existe o no pertenece a esta empresa"}';
      RETURN;
    END IF;

    -- EL UNIQUE SE CONSULTA ANTES DE INSERTAR para poder nombrar el caso en el
    -- mensaje: DUP_VAL_ON_INDEX no informa cual indice fallo.
    IF MANUAL_REPETIDO(l_id_institucion, l_grado) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Esa institucion ya tiene un manual de ese grado. Para cambiarlo, subi el archivo sobre el manual que ya existe"}';
      RETURN;
    END IF;

    -- Las dos fechas explicitas aunque el DEFAULT ya sea SYSTIMESTAMP: es el
    -- criterio del proyecto, para no depender de un default que puede cambiar
    -- en el DDL.
    --
    -- El ARCHIVO_PDF no se carga aca: va por PUT /manuales/archivo-url/:id despues
    -- del alta, cuando ya hay un id al que asociarlo.
    INSERT INTO MANUALES (
      ID_INSTITUCION, GRADO, FECHA_CARGA, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_institucion,
      l_grado,
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_MANUAL INTO l_id;

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
      p_resultado := '{"error":"Esa institucion ya tiene un manual de ese grado"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: la FK no encontro la institucion. Es un dato invalido del
      -- cliente (400), no un fallo del servidor. En la practica no deberia
      -- llegar aca —INSTITUCION_ES_DE_EMPRESA ya lo valida— pero queda por si
      -- la institucion se borra entre la comprobacion y el INSERT.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La institucion indicada no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_MANUALES.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear el manual: ' ||
                       REPLACE(
                         REPLACE(
                           REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                           CHR(10), ' '),
                         CHR(13), ' ') ||
                       '"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization  IN  VARCHAR2,
    p_id             IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_grado          IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  ) IS
    l_sesion              NUMBER;
    l_id                  NUMBER;
    l_id_empresa          NUMBER;
    l_id_institucion      NUMBER;
    l_grado               VARCHAR2(5);
    l_existe              PLS_INTEGER;
    -- Los valores que quedarian despues del UPDATE, resueltos ANTES de validar:
    -- los UNIQUE se chequean contra la fila final, no contra lo que vino en el
    -- request. Cambiar solo el grado tiene que chocar contra la institucion que
    -- la fila ya tiene, no contra un NULL.
    l_institucion_final   NUMBER;
    l_grado_final         VARCHAR2(5);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id             := A_NUMERO(p_id);
    l_id_empresa     := A_NUMERO(p_id_empresa);
    l_id_institucion := A_NUMERO(p_id_institucion);
    l_grado          := NULLIF(TRIM(p_grado), '');

    -- AISLAMIENTO POR EMPRESA: el idEmpresa acota A CUAL fila se le aplica el
    -- cambio, no es solo un campo mas a modificar. Sin el, un PUT con el id de
    -- un manual de OTRA empresa lo modificaba igual — la pantalla no lo
    -- permite, pero el endpoint es publico para cualquiera con sesion.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    IF l_grado IS NOT NULL AND NOT GRADO_VALIDO(l_grado) THEN
      p_status_code := 400;
      p_resultado := '{"error":"El grado no es valido. Valores permitidos: 1ro., 2do., 3er., 4to., 5to., 6to., 7mo., 8vo., 9no., 1ME., 2ME., 3ME."}';
      RETURN;
    END IF;

    -- Existe Y es de esta empresa? Se comprueba ANTES de los UNIQUE: si la fila
    -- no es suya, el 404 tiene que ganarle al 409. Al reves, un 409 confirmaria
    -- que el id existe, que es informacion que quien pregunta no deberia
    -- obtener.
    --
    -- La empresa se pregunta contra la INSTITUCION de la fila, no contra una
    -- columna propia: es lo que reemplaza al `AND ID_EMPRESA = ...` del resto
    -- de los paquetes.
    SELECT COUNT(*)
      INTO l_existe
      FROM MANUALES m
      JOIN INSTITUCIONES i ON i.ID_INSTITUCION = m.ID_INSTITUCION
     WHERE m.ID_MANUAL  = l_id
       AND i.ID_EMPRESA = l_id_empresa;

    IF l_existe = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El manual no existe"}';
      RETURN;
    END IF;

    -- LA INSTITUCION DE DESTINO TAMBIEN SE VALIDA. Comprobar solo que la fila
    -- que se edita sea de la empresa deja abierta la puerta de atras: un PUT
    -- podria mover un manual propio a la institucion de otra empresa, que es
    -- exactamente la fuga que el control busca impedir.
    IF l_id_institucion IS NOT NULL
       AND NOT INSTITUCION_ES_DE_EMPRESA(l_id_institucion, l_id_empresa) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La institucion indicada no existe o no pertenece a esta empresa"}';
      RETURN;
    END IF;

    -- Los valores finales, resueltos contra la fila actual con NVL: es lo que
    -- permite validar el UNIQUE contra la fila que va a quedar. Sin esto,
    -- cambiar solo el grado compararia contra un idInstitucion NULL y el choque
    -- pasaria desapercibido hasta el DUP_VAL_ON_INDEX.
    SELECT NVL(l_id_institucion, ID_INSTITUCION),
           NVL(l_grado, TRIM(GRADO))
      INTO l_institucion_final, l_grado_final
      FROM MANUALES
     WHERE ID_MANUAL = l_id;

    IF MANUAL_REPETIDO(l_institucion_final, l_grado_final, l_id) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Esa institucion ya tiene un manual de ese grado"}';
      RETURN;
    END IF;

    -- NVL: un parametro ausente conserva el valor actual. Es la regla del
    -- proyecto, y aca aplica sin excepciones — no hay ningun campo opcional que
    -- haga falta poder desvincular, asi que no hay centinela.
    --
    -- FECHA_CARGA NO SE TOCA: responde "de cuando es este manual", y corregir un
    -- grado mal tipeado no cambia la fecha del PDF. La mueve el PUT del archivo.
    --
    -- El WHERE repite la condicion de empresa que el SELECT verifico: entre los
    -- dos hay una ventana en la que otra sesion pudo mover la institucion.
    UPDATE MANUALES m
       SET m.ID_INSTITUCION      = NVL(l_id_institucion, m.ID_INSTITUCION),
           m.GRADO               = NVL(l_grado, m.GRADO),
           m.FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE m.ID_MANUAL = l_id
       AND EXISTS (
             SELECT 1
               FROM INSTITUCIONES i
              WHERE i.ID_INSTITUCION = m.ID_INSTITUCION
                AND i.ID_EMPRESA     = l_id_empresa
           );

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El manual no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Esa institucion ya tiene un manual de ese grado"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La institucion indicada no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_MANUALES.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar el manual: ' ||
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
    l_sesion      NUMBER;
    l_id          NUMBER;
    l_id_empresa  NUMBER;
    l_archivo_url MANUALES.ARCHIVO_URL%TYPE;
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

    -- AISLAMIENTO POR EMPRESA con EXISTS, porque la columna no esta en esta
    -- tabla. Con solo el id, un DELETE con el id de un manual de otra empresa
    -- lo borraba.
    --
    -- BAJA FISICA, y es la unica que hay: la tabla no tiene columna ACTIVO.
    -- RETURNING: el PDF se borra de Cloudinary recien despues del COMMIT, y
    -- para entonces la fila ya no esta para preguntarle.
    DELETE FROM MANUALES m
     WHERE m.ID_MANUAL = l_id
       AND EXISTS (
             SELECT 1
               FROM INSTITUCIONES i
              WHERE i.ID_INSTITUCION = m.ID_INSTITUCION
                AND i.ID_EMPRESA     = l_id_empresa
           )
    RETURNING m.ARCHIVO_URL INTO l_archivo_url;

    -- 404 tambien cuando existe pero es de otra empresa: no se confirma que el
    -- id exista.
    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El manual no existe"}';
      RETURN;
    END IF;

    COMMIT;
    PKG_CLOUDINARY.BORRAR(l_archivo_url);

    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos apuntando a esta fila. Hoy nada cuelga de
      -- MANUALES, pero el dia que algo lo haga esto evita que el borrado salga
      -- como un 500 mudo: es un conflicto de estado (409), no un error del
      -- servidor — el dato que mandaron era valido.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de este manual"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_MANUALES.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar el manual: ' ||
                       REPLACE(
                         REPLACE(
                           REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                           CHR(10), ' '),
                         CHR(13), ' ') ||
                       '"}';
      END IF;
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Guarda la URL del PDF de un manual. CON token, acotado a la empresa via
  -- INSTITUCIONES (la tabla no tiene ID_EMPRESA).
  --
  -- El archivo ya esta en Cloudinary: lo subio el navegador antes de llamar
  -- aca. Este procedimiento solo anota donde quedo y cuanto pesa.
  --
  -- VACIA EL BLOB VIEJO en el mismo UPDATE: cada manual que se vuelve a subir
  -- libera su lugar en la base. Ojo: el espacio vuelve al segmento, NO a la
  -- cuota — para eso hace falta el SHRINK del pie del archivo.
  --
  -- MUEVE FECHA_CARGA, que es lo que la distingue de FECHA_ACTUALIZACION: la
  -- fecha de carga es la del PDF, no la de la fila. Reemplazar el archivo es
  -- cargar un manual nuevo sobre el mismo grado.
  ------------------------------------------------------------------------------
  PROCEDURE GUARDAR_ARCHIVO (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_archivo_url   IN  VARCHAR2,
    p_bytes         IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_id       NUMBER;
    l_empresa  NUMBER;
    l_bytes    NUMBER;
    l_url      VARCHAR2(4000);
    l_anterior MANUALES.ARCHIVO_URL%TYPE;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id      := A_NUMERO(p_id);
    l_empresa := A_NUMERO(p_id_empresa);
    l_bytes   := A_NUMERO(p_bytes);
    l_url     := NULLIF(TRIM(p_archivo_url), '');

    IF l_id IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    -- La URL termina en un <a href>. Sin esto, "javascript:..." se guarda
    -- igual.
    IF l_url IS NULL
       OR LENGTH(l_url) > C_MAX_URL
       OR LOWER(SUBSTR(l_url, 1, 8)) != 'https://' THEN
      p_status_code := 400;
      p_resultado := '{"error":"La URL del PDF debe empezar con https:// y no pasar de 500 caracteres"}';
      RETURN;
    END IF;

    -- La URL anterior, para borrar su archivo despues. FOR UPDATE: dos subidas
    -- simultaneas leerian la misma anterior y la segunda dejaria huerfano el
    -- PDF de la primera. El EXISTS es el aislamiento por empresa.
    BEGIN
      SELECT m.ARCHIVO_URL
        INTO l_anterior
        FROM MANUALES m
       WHERE m.ID_MANUAL = l_id
         AND EXISTS (
               SELECT 1
                 FROM INSTITUCIONES i
                WHERE i.ID_INSTITUCION = m.ID_INSTITUCION
                  AND i.ID_EMPRESA     = l_empresa
             )
         FOR UPDATE OF m.ARCHIVO_URL;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_status_code := 404;
        p_resultado := '{"error":"El manual no existe"}';
        RETURN;
    END;

    UPDATE MANUALES
       SET ARCHIVO_URL         = l_url,
           ARCHIVO_BYTES       = l_bytes,
           ARCHIVO_PDF         = NULL,
           ARCHIVO_MIME        = NULL,
           FECHA_CARGA         = SYSTIMESTAMP,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_MANUAL = l_id;

    COMMIT;

    -- Despues del COMMIT y nunca antes: ver el encabezado de db/cloudinary.sql.
    IF l_anterior IS NOT NULL AND l_anterior != l_url THEN
      PKG_CLOUDINARY.BORRAR(l_anterior);
    END IF;

    p_status_code := 200;
    p_resultado := JSON_OBJECT('ok' VALUE 'true' FORMAT JSON, 'bytes' VALUE l_bytes);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_MANUALES.GUARDAR_ARCHIVO: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al guardar el archivo"}';
  END GUARDAR_ARCHIVO;

  ------------------------------------------------------------------------------
  -- Publica el modulo ORDS /manuales/ con sus 6 endpoints.
  --
  -- Cada handler PL/SQL es una sola linea: invoca al procedimiento del paquete
  -- pasando los binds de ORDS como argumentos. Nada de PL/SQL embebido. La
  -- excepcion es el GET del archivo, que es una consulta por source_type_media.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un parametro
  -- de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin esto, toda
  -- peticion cross-origin a /manuales/* la rechaza ORDS antes de llegar a
  -- cualquiera de los handlers. Ver la explicacion en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'manuales',
      p_base_path      => '/manuales/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Manuales en PDF por institucion y grado'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'manuales',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /manuales/listar?idEmpresa=&idInstitucion=&grado=&busqueda=
    --
    -- Los query params no se declaran con DEFINE_PARAMETER: se vinculan solos
    -- al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'manuales', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'manuales',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MANUALES.LISTAR(:authorization, :idEmpresa, :idInstitucion, :grado, :busqueda, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /manuales/crear
    -- Body: { idEmpresa, idInstitucion, grado }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'manuales', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'manuales',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MANUALES.INSERTAR(:authorization, :idEmpresa, :idInstitucion, :grado, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /manuales/actualizar/:id
    -- Body: { idEmpresa, idInstitucion?, grado? }   (ausentes = no cambia)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'manuales', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'manuales',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MANUALES.ACTUALIZAR(:authorization, :id, :idEmpresa, :idInstitucion, :grado, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /manuales/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'manuales', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'manuales',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MANUALES.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /manuales/archivo/:id — SIN TOKEN
    --
    -- Devuelve el PDF crudo, no un JSON, y por eso NO se publica como los demas
    -- endpoints.
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
    -- El 404 del archivo faltante sale solo: si la consulta no devuelve filas,
    -- ORDS responde 404 sin que haya que manejar un status code a mano. Por eso
    -- el WHERE filtra los BLOB vacios en vez de devolverlos — un manual dado de
    -- alta al que todavia no le subieron el PDF es exactamente ese caso.
    --
    -- SOLO SIRVE LOS PDF DE ANTES DE CLOUDINARY. Ya no tiene PUT: los nuevos
    -- se guardan como URL (archivo-url/:id, mas abajo). Retirarlo cuando no
    -- quede ningun BLOB (consulta al pie del archivo).
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'manuales', p_pattern => 'archivo/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'manuales',
      p_pattern     => 'archivo/:id',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_media,
      p_source      => 'SELECT NVL(ARCHIVO_MIME, ''application/pdf''), ARCHIVO_PDF
                          FROM MANUALES
                         WHERE ID_MANUAL = :id
                           AND ARCHIVO_PDF IS NOT NULL
                           AND DBMS_LOB.GETLENGTH(ARCHIVO_PDF) > 0'
    );

    ----------------------------------------------------------------------------
    -- PUT /manuales/archivo-url/:id — con token
    -- Body: { idEmpresa, archivoUrl, bytes }. El PDF ya esta en Cloudinary.
    --
    -- Template propio y no un PUT en archivo/:id: ahi un cliente viejo mandaria
    -- el binario crudo a un handler que espera JSON. En una ruta nueva recibe
    -- un 404 claro, y el PDF no termina en la base por la puerta de atras.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'manuales', p_pattern => 'archivo-url/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'manuales',
      p_pattern     => 'archivo-url/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_MANUALES.GUARDAR_ARCHIVO(:authorization, :id, :idEmpresa, :archivoUrl, :bytes, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'archivo-url/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'archivo-url/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'manuales', p_pattern => 'archivo-url/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_MANUALES;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_MANUALES.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_MANUALES'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_MANUALES'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'manuales';

-- Deben salir 6 filas: actualizar PUT, archivo GET, archivo-url PUT, crear
-- POST, eliminar DELETE y listar GET. Si aparece un PUT en archivo/:id, el
-- modulo viejo sigue publicado.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'manuales'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- La columna ARCHIVO_MIME del paso 0 tiene que existir: sin ella el paquete
-- queda INVALID y el modulo responde 500 en todo.
SELECT COLUMN_NAME, DATA_TYPE, NULLABLE
  FROM USER_TAB_COLUMNS
 WHERE TABLE_NAME = 'MANUALES'
 ORDER BY COLUMN_ID;

-- El contenido, con la empresa que sale de la institucion (MANUALES no tiene
-- ID_EMPRESA). El JOIN es interno igual que en el listado: ID_INSTITUCION es
-- NOT NULL, asi que no hay fila que pueda esconder.
SELECT m.ID_MANUAL,
       e.NOMBRE_EMPRESA,
       i.NOMBRE_INSTITUCION,
       m.GRADO,
       CASE WHEN m.ARCHIVO_PDF IS NOT NULL AND DBMS_LOB.GETLENGTH(m.ARCHIVO_PDF) > 0
            THEN 'SI' ELSE 'NO' END AS TIENE_PDF,
       ROUND(DBMS_LOB.GETLENGTH(m.ARCHIVO_PDF) / 1024 / 1024, 2) AS MB,
       m.ARCHIVO_MIME,
       TO_CHAR(m.FECHA_CARGA, 'DD/MM/YYYY HH24:MI') AS CARGADO
  FROM MANUALES      m
  JOIN INSTITUCIONES i ON i.ID_INSTITUCION = m.ID_INSTITUCION
  JOIN EMPRESAS      e ON e.ID_EMPRESA     = i.ID_EMPRESA
 ORDER BY e.NOMBRE_EMPRESA, i.NOMBRE_INSTITUCION, m.GRADO;

--------------------------------------------------------------------------------
-- GRADOS FUERA DE LA LISTA — DEBE DEVOLVER CERO FILAS.
--
-- El paquete valida los doce valores, pero el DDL no tiene CHECK y las filas
-- cargadas antes de este archivo pueden traer cualquier cosa. Una fila con
-- '1ro' sin punto convive con la de '1ro.' —el UNIQUE las ve distintas— y en la
-- pantalla son dos manuales de primer grado.
--
-- Se corrigen a mano, porque cual era el grado correcto no se puede deducir:
--   UPDATE MANUALES SET GRADO = '1ro.' WHERE ID_MANUAL = <el que sea>;
--   COMMIT;
--------------------------------------------------------------------------------

SELECT ID_MANUAL, ID_INSTITUCION, GRADO
  FROM MANUALES
 WHERE TRIM(GRADO) NOT IN (
         '1ro.', '2do.', '3er.', '4to.', '5to.', '6to.',
         '7mo.', '8vo.', '9no.', '1ME.', '2ME.', '3ME.'
       );

--------------------------------------------------------------------------------
-- MANUALES SIN PDF CARGADO — informativo, puede devolver filas.
--
-- El alta crea la fila y el PDF se sube despues, asi que una fila sin archivo es
-- un estado normal y transitorio. Si queda asi por mucho tiempo, es un alta que
-- alguien empezo y no termino: la pantalla las muestra con el aviso de que falta
-- el archivo.
--------------------------------------------------------------------------------

SELECT m.ID_MANUAL, i.NOMBRE_INSTITUCION, m.GRADO,
       TO_CHAR(m.FECHA_CARGA, 'DD/MM/YYYY HH24:MI') AS DADO_DE_ALTA
  FROM MANUALES      m
  JOIN INSTITUCIONES i ON i.ID_INSTITUCION = m.ID_INSTITUCION
 WHERE m.ARCHIVO_URL IS NULL
   AND (m.ARCHIVO_PDF IS NULL OR DBMS_LOB.GETLENGTH(m.ARCHIVO_PDF) = 0)
 ORDER BY m.FECHA_CARGA;

--------------------------------------------------------------------------------
-- MIGRACION DE LOS PDF VIEJOS
--
-- Cuantos siguen en la base y cuanto ocupan. Cada manual que se vuelve a subir
-- desde /manuales pasa a Cloudinary. Cuando BLOB llegue a 0, el GET
-- /manuales/archivo/:id se puede retirar.
--------------------------------------------------------------------------------

SELECT CASE
         WHEN ARCHIVO_URL IS NOT NULL THEN 'CLOUDINARY'
         WHEN ARCHIVO_PDF IS NOT NULL AND DBMS_LOB.GETLENGTH(ARCHIVO_PDF) > 0 THEN 'BLOB'
         ELSE 'SIN PDF'
       END AS DONDE,
       COUNT(*) AS MANUALES,
       ROUND(SUM(NVL(DBMS_LOB.GETLENGTH(ARCHIVO_PDF), 0)) / 1024 / 1024, 2) AS MB_EN_LA_BASE
  FROM MANUALES
 GROUP BY CASE
            WHEN ARCHIVO_URL IS NOT NULL THEN 'CLOUDINARY'
            WHEN ARCHIVO_PDF IS NOT NULL AND DBMS_LOB.GETLENGTH(ARCHIVO_PDF) > 0 THEN 'BLOB'
            ELSE 'SIN PDF'
          END;

-- Vaciar el BLOB devuelve el espacio al segmento, no a la cuota del esquema.
-- Para liberarlo de verdad, una vez migrados (fuera de horario):
--   ALTER TABLE MANUALES MODIFY LOB (ARCHIVO_PDF) (SHRINK SPACE);
