--------------------------------------------------------------------------------
-- CTELL · FICHAS DE TRASPASO DE CLASE
--
-- Un paquete (PKG_FICHAS_TRASPASO_CLASE) con el ABM de la ficha que deja un
-- profesor ausente para quien lo suplente, y la publicacion de los endpoints
-- ORDS. Todo vive dentro del paquete: no hay procedimientos sueltos ni PL/SQL
-- embebido como texto dentro de los handlers.
--
--   1. LISTAR      GET    /fichas-traspaso-clase/listar
--   2. OBTENER     GET    /fichas-traspaso-clase/obtener/:id/:idEmpresa
--   3. POR_JUSTIF  GET    /fichas-traspaso-clase/por-justificacion/:idJustificacion/:idEmpresa
--   4. CREAR       POST   /fichas-traspaso-clase/crear
--   5. ACTUALIZAR  PUT    /fichas-traspaso-clase/actualizar/:id
--   6. ELIMINAR    DELETE /fichas-traspaso-clase/eliminar/:id/:idEmpresa
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/fichas-traspaso-clase/
--
-- Tablas (no las crea ni las altera; el DDL se administra aparte):
--   FICHAS_TRASPASO_CLASE      ID_FICHA_TRASPASO, ID_EMPRESA, ID_JUSTIFICACION,
--                              ID_INSTITUCION, FECHA_AUSENCIA, MATERIA_AREA,
--                              PERSONA_CONTACTO, INGRESO_REQUISITOS,
--                              MATERIALES_RECURSOS, OTRAS_INDICACIONES,
--                              OBSERVACIONES_ADICIONALES, FECHA_CREACION,
--                              FECHA_ACTUALIZACION
--   FICHAS_TRASPASO_CLASE_DET  ID_DETALLE_FICHA, ID_FICHA_TRASPASO,
--                              GRADO_CURSO, HORA_DESDE, HORA_HASTA,
--                              TEMA_DESARROLLAR, OBSERVACIONES_GRUPO,
--                              FECHA_CREACION
--
--------------------------------------------------------------------------------
-- QUE ES ESTO Y DE QUE CUELGA
--
-- Una justificacion de ausencia dice que un profesor no va. Esta ficha dice
-- QUE TIENE QUE HACER EL QUE VA EN SU LUGAR: por donde entra al colegio, con
-- quien se presenta, que materiales lleva, y grado por grado que tema toca y a
-- que hora. Es el documento que se imprime y se le da al suplente.
--
-- Cuelga de JUSTIFICACIONES_AUSENCIA (FK NOT NULL): sin la ausencia, la ficha
-- no significa nada. Y por eso hereda TODO lo que ya esta resuelto en
-- db/justificaciones-ausencia.sql, incluidas sus dos decisiones incomodas.
--
--------------------------------------------------------------------------------
-- LA EMPRESA ES LA DEL PROFESOR DE LA JUSTIFICACION, NO LA COLUMNA PROPIA
--
-- ESTA ES LA REGLA MAS IMPORTANTE DEL ARCHIVO. La tabla TIENE ID_EMPRESA, con
-- su FK y su NOT NULL, y aun asi NO SE FILTRA POR ELLA.
--
-- El motivo es el de db/justificaciones-ausencia.sql: la empresa de una
-- justificacion es la de su PROFESOR, porque la app del profesor fija su
-- ID_EMPRESA siempre en 1 (lo dice el COMMENT de esa columna). Una ficha que
-- cuelga de esa justificacion no puede usar un criterio distinto al de su
-- padre: si el hub filtrara por f.ID_EMPRESA, la bandeja de justificaciones y
-- el listado de fichas mostrarian conjuntos distintos de la misma realidad —
-- una ausencia visible cuya ficha no aparece, o al reves.
--
-- Asi que el filtro es el mismo de siempre, encadenado un nivel mas:
--
--   JOIN JUSTIFICACIONES_AUSENCIA j ON j.ID_JUSTIFICACION = f.ID_JUSTIFICACION
--   JOIN PROFESORES p               ON p.ID_PROFESOR      = j.ID_PROFESOR
--   WHERE p.ID_EMPRESA = l_empresa
--
-- Va en TODAS las consultas —listado, COUNT, obtener, actualizar y eliminar—:
-- filtrar el listado no alcanza, o se edita por endpoint la ficha de otra
-- empresa. En el UPDATE y el DELETE, donde no se puede escribir un JOIN, va
-- como EXISTS. Es el mismo filtro, no una version relajada.
--
-- Los dos JOIN son INTERNOS a proposito. Las dos FK son NOT NULL, asi que no
-- hay fila que un INNER pueda esconder; con un LEFT, una ficha cuya
-- justificacion no matchea el WHERE se colaria en el listado de otra empresa.
--
-- Y ENTONCES QUE SE ESCRIBE EN f.ID_EMPRESA? La del profesor, resuelta en el
-- alta. La columna es NOT NULL y hay que ponerle algo; ponerle el dato bueno
-- cuesta lo mismo que ponerle uno malo, y deja la tabla coherente para el dia
-- que alguien la consulte por fuera del hub. Pero SE ESCRIBE, NO SE LEE: el
-- idEmpresa que manda el cliente se usa para AUTORIZAR (contra el profesor),
-- nunca como valor a guardar de frente.
--
--------------------------------------------------------------------------------
-- UNA FICHA POR JUSTIFICACION
--
-- El DDL no tiene UNIQUE (ID_JUSTIFICACION) y deberia tenerlo. Mientras no lo
-- tenga, LO GARANTIZA EL PAQUETE: CREAR devuelve 409 si la ausencia ya tiene
-- ficha.
--
-- Sin esa regla, una ausencia puede terminar con tres fichas y nadie sabe cual
-- rige — que es exactamente el problema que la ficha viene a resolver. Un
-- suplente con dos juegos de instrucciones esta peor que sin ninguno.
--
-- ES UNA REGLA DEL PAQUETE, NO DE LA BASE, y hay que saber la diferencia: dos
-- altas simultaneas de la misma justificacion pasan las dos el COUNT antes de
-- que cualquiera inserte, y quedan las dos. Con un solo hub y una ficha que se
-- carga a mano es improbable; el arreglo de verdad es el indice:
--
--   ALTER TABLE FICHAS_TRASPASO_CLASE
--     ADD CONSTRAINT UQ_FICHA_JUSTIFICACION UNIQUE (ID_JUSTIFICACION);
--
-- El paquete YA traduce el DUP_VAL_ON_INDEX a ese mismo 409, asi que agregarlo
-- no rompe nada: solo convierte la regla en garantia.
--
--------------------------------------------------------------------------------
-- INSTITUCION Y FECHA SE DERIVAN, NO SE PIDEN
--
-- Las dos columnas existen en la tabla y las dos salen de la justificacion:
-- ID_INSTITUCION es la misma, y FECHA_AUSENCIA es su FECHA_AUSENCIA_INICIO.
--
-- El alta manda SOLO idJustificacion y el paquete las resuelve. Aceptarlas del
-- body obligaria a validar que coincidan con el padre, y el dia que esa
-- validacion se afloje la base guarda una ficha que dice un colegio y una
-- ausencia que dice otro. Es el mismo criterio de reportes-actividades, donde
-- el reporte deriva todo de su marcacion, y el de los totales de una venta:
-- SI SE PUEDE DERIVAR, SE DERIVA.
--
-- Consecuencia asumida: una ausencia de varios dias tiene UNA ficha, fechada
-- el primer dia. Si mas adelante hace falta una por dia, el cambio es
-- UNIQUE (ID_JUSTIFICACION, FECHA_AUSENCIA) y aceptar la fecha en el alta
-- validandola DENTRO del rango de la ausencia — no aceptarla libre.
--
-- MATERIA_AREA tambien esta en las dos tablas, y esa SI se pide: la
-- justificacion trae la materia del profesor ausente, pero la ficha puede
-- necesitar precisarla para el suplente ("Matematica" -> "Matematica -
-- Geometria, unidad 4"). Se propone la del padre como valor inicial y se deja
-- editar. Es la diferencia entre un dato que se copia y uno que se aclara.
--
--------------------------------------------------------------------------------
-- CABECERA Y DETALLE: UNA TRANSACCION
--
-- La ficha son dos tablas y solo tienen sentido juntas: una cabecera sin
-- grados no le dice nada al suplente. El detalle viaja en el MISMO request,
-- como array JSON, y se recorre con JSON_TABLE.
--
--   { "idEmpresa": 1, "idJustificacion": 7, "detalle": [
--       { "gradoCurso": "3ro. A", "horaDesde": "07:30", "horaHasta": "08:15",
--         "temaDesarrollar": "Fracciones", "observacionesGrupo": "..." } ] }
--
-- GUARDAR_DETALLE no hace COMMIT ni ROLLBACK y devuelve el error en un OUT en
-- vez de lanzar: quien llama tiene que poder deshacer TAMBIEN la cabecera.
-- Y valida CADA linea dentro del bucle, con FOR ORDINALITY para el numero:
-- "la linea 3 no tiene grado" se corrige, "hay una linea sin grado" obliga a
-- buscarla.
--
-- ACTUALIZAR reemplaza el detalle ENTERO (borra y reinserta), y solo si vino:
-- un PUT que cambia unicamente la persona de contacto deja los grados como
-- estaban. Los ID_DETALLE_FICHA cambian en cada edicion; no importa mientras
-- nada apunte al detalle.
--
-- ELIMINAR borra el detalle PRIMERO: el DDL no declara ON DELETE CASCADE y al
-- reves da ORA-02292.
--
--------------------------------------------------------------------------------
-- LAS HORAS SON VARCHAR2(10), Y ESO OBLIGA A VALIDARLAS
--
-- HORA_DESDE y HORA_HASTA son texto, no DATE ni INTERVAL: su COMMENT dice
-- "Ej: 08:00, 13:30". Texto libre significa que nada impide guardar "8", "8hs",
-- "de 8 a 9" o "a la manana", y con eso la ficha impresa deja de tener una
-- columna de horario para tener una columna de comentarios sobre el horario.
--
-- Se validan contra HH24:MI con FORMATO_HORA_VALIDO y se guardan normalizadas
-- ('8:00' entra como '08:00'), para que ordenen bien como texto: sin el cero a
-- la izquierda, '8:00' sale despues de '13:30' en cualquier ORDER BY.
--
-- Tambien se valida que HASTA sea posterior a DESDE cuando vienen las dos. No
-- se valida el solapamiento entre lineas: dos grados a la misma hora es raro
-- pero puede ser real (dos secciones juntas en el mismo salon), y rechazarlo
-- seria decidir por el colegio.
--
--------------------------------------------------------------------------------
-- LOS TEXTOS LARGOS NO VIAJAN ENTEROS EN EL LISTADO
--
-- Cuatro columnas de la cabecera aceptan 1000 caracteres cada una. Veinte filas
-- con las cuatro llenas son 80.000 caracteres: MUY por encima del techo de 4000
-- bytes del bind de ORDS, que devuelve un 500 que ningun WHEN OTHERS registra
-- porque el PL/SQL ya termino bien.
--
-- El LISTAR no las manda: devuelve la cabecera identificatoria mas la CANTIDAD
-- de grados, y un flag por cada texto que dice si tiene contenido. La ficha
-- entera —los cuatro textos completos y el detalle— sale de OBTENER.
--
-- Y DE AHI SALE LA REGLA MAS IMPORTANTE DE LA PANTALLA: el formulario de
-- edicion carga con /obtener, NUNCA con la fila del listado. Es la trampa de
-- INVENTARIOS.OBSERVACIONES, y aca esta impedida por estructura: los textos ni
-- siquiera viajan en el listado, asi que no hay resumen que guardar por error.
--
--------------------------------------------------------------------------------
-- EN EL ACTUALIZAR, UN CAMPO VACIO BORRA
--
-- Igual que en db/inventarios.sql y db/justificaciones-ausencia.sql, y por el
-- mismo motivo: el formulario manda SIEMPRE todos los campos. Con el NVL
-- habitual ("no cambiar"), quien escribio una indicacion en la ficha equivocada
-- no tendria forma de dejarla en blanco — el campo se vaciaria en pantalla y
-- volveria lleno al recargar.
--
-- ID_JUSTIFICACION NO SE PUEDE CAMBIAR. Mover una ficha a otra ausencia es
-- crear otra ficha: la institucion y la fecha quedarian derivadas de la
-- justificacion vieja, y ademas permitiria saltar el "una ficha por
-- justificacion" moviendo la existente. Si se mando mal, se borra y se rehace.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_FICHAS_TRASPASO_CLASE AS

  -- El listado. Solo idEmpresa es obligatorio; el resto acota.
  -- NO devuelve los textos largos: solo flags de "tiene contenido". La ficha
  -- entera sale de OBTENER.
  PROCEDURE LISTAR (
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_desde          IN  VARCHAR2,
    p_hasta          IN  VARCHAR2,
    p_id_profesor    IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_busqueda       IN  VARCHAR2,
    p_pagina         IN  VARCHAR2,
    p_tamanio        IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  );

  -- La ficha entera: los cuatro textos completos y el detalle de grados.
  -- Es la que tiene que usar el formulario de edicion, nunca la fila del
  -- listado.
  PROCEDURE OBTENER (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  ------------------------------------------------------------------------------
  -- La ficha de una justificacion, buscada por el id de la AUSENCIA.
  --
  -- Existe porque la pantalla entra por la justificacion, no por la ficha: al
  -- abrir el dialogo de gestion de una ausencia hay que saber si ya tiene ficha
  -- (para ofrecer "Ver" o "Crear"), y ahi el unico id disponible es el de la
  -- justificacion. Sin este endpoint habria que traerse el listado entero y
  -- buscarla en memoria.
  --
  -- Devuelve 200 con la ficha, o 200 con {"ficha":null} si no tiene. NO es un
  -- 404: "esta ausencia no tiene ficha todavia" es una respuesta valida y
  -- esperada, no un error — el 404 obligaria a la pantalla a tratar como falla
  -- el camino normal de una ausencia recien recibida.
  ------------------------------------------------------------------------------
  PROCEDURE POR_JUSTIFICACION (
    p_authorization     IN  VARCHAR2,
    p_id_justificacion  IN  VARCHAR2,
    p_id_empresa        IN  VARCHAR2,
    p_status_code       OUT NUMBER,
    p_resultado         OUT CLOB
  );

  ------------------------------------------------------------------------------
  -- Alta de la ficha con su detalle, en una transaccion.
  --
  -- Body: { idEmpresa, idJustificacion, materiaArea, personaContacto,
  --         ingresoRequisitos, materialesRecursos, otrasIndicaciones,
  --         observacionesAdicionales, detalle: [...] }
  --
  -- NO recibe idInstitucion ni fechaAusencia: se derivan de la justificacion
  -- (ver cabecera). NO recibe id: lo genera la IDENTITY.
  --
  -- Los campos del JSON llegan SUELTOS como binds (:idEmpresa, :detalle, ...),
  -- no dentro de :body, que es el payload crudo como BLOB. Un JSON_VALUE sobre
  -- el devuelve NULL en todo y el endpoint contesta 400 con el body bien
  -- puesto. Del lado del cliente hay que mandar TODAS las claves aunque vayan
  -- en "": una clave omitida deja el bind sin definir en vez de en NULL.
  ------------------------------------------------------------------------------
  PROCEDURE CREAR (
    p_authorization             IN  VARCHAR2,
    p_id_empresa                IN  VARCHAR2,
    p_id_justificacion          IN  VARCHAR2,
    p_materia_area              IN  VARCHAR2,
    p_persona_contacto          IN  VARCHAR2,
    p_ingreso_requisitos        IN  VARCHAR2,
    p_materiales_recursos       IN  VARCHAR2,
    p_otras_indicaciones        IN  VARCHAR2,
    p_observaciones_adicionales IN  VARCHAR2,
    p_detalle                   IN  CLOB,
    p_status_code               OUT NUMBER,
    p_resultado                 OUT CLOB
  );

  ------------------------------------------------------------------------------
  -- Modificacion. Un campo vacio BORRA (ver cabecera).
  --
  -- El detalle se reemplaza ENTERO, y solo si vino: sin p_detalle, los grados
  -- quedan como estaban.
  --
  -- NO acepta idJustificacion: mover una ficha a otra ausencia es crear otra
  -- ficha, no editar esta.
  ------------------------------------------------------------------------------
  PROCEDURE ACTUALIZAR (
    p_authorization             IN  VARCHAR2,
    p_id                        IN  VARCHAR2,
    p_id_empresa                IN  VARCHAR2,
    p_materia_area              IN  VARCHAR2,
    p_persona_contacto          IN  VARCHAR2,
    p_ingreso_requisitos        IN  VARCHAR2,
    p_materiales_recursos       IN  VARCHAR2,
    p_otras_indicaciones        IN  VARCHAR2,
    p_observaciones_adicionales IN  VARCHAR2,
    p_detalle                   IN  CLOB,
    p_status_code               OUT NUMBER,
    p_resultado                 OUT CLOB
  );

  -- Baja fisica: se lleva el detalle. No hay baja logica porque la tabla no
  -- tiene ACTIVO — una ficha que ya no corre se corrige o se borra.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_FICHAS_TRASPASO_CLASE;
/

CREATE OR REPLACE PACKAGE BODY PKG_FICHAS_TRASPASO_CLASE AS

  -- 50 y no 200 aunque otras tablas lo acepten: aunque el listado no manda los
  -- textos largos, cada fila lleva materia, contacto, profesor e institucion.
  C_TAMANIO_MAXIMO CONSTANT PLS_INTEGER := 50;

  -- Los topes de las columnas que escribe este paquete. Estan aca y no en un
  -- COMMENT para poder devolver un 400 legible en vez del ORA-12899, que
  -- llegaria al cliente como un 500 mudo.
  C_MAX_MATERIA     CONSTANT PLS_INTEGER := 200;
  C_MAX_CONTACTO    CONSTANT PLS_INTEGER := 200;
  C_MAX_TEXTO       CONSTANT PLS_INTEGER := 1000;
  C_MAX_GRADO       CONSTANT PLS_INTEGER := 100;
  C_MAX_HORA        CONSTANT PLS_INTEGER := 10;

  -- Techo de lineas de una ficha. Un dia de clases no tiene cuarenta grados: lo
  -- que pase de ahi es un cliente en un bucle, y sin tope el INSERT corre hasta
  -- que ORDS corta la peticion, dejando media ficha escrita.
  C_MAX_LINEAS      CONSTANT PLS_INTEGER := 40;

  ------------------------------------------------------------------------------
  -- Privado: borra el modulo ORDS si existe, reintentando ante un interbloqueo.
  --
  -- El DELETE_MODULE toma locks sobre los metadatos de ORDS, y una sesion de
  -- `npm run dev` pegandole al endpoint los mantiene ocupados: sin reintentar,
  -- el borrado falla en silencio y el DEFINE_MODULE de despues muere con
  -- ORA-00001 contra el modulo que nunca se llego a borrar.
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
         WHERE NAME = 'fichas-traspaso-clase';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'fichas-traspaso-clase');
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
  -- Privados de conversion. Los query params y los campos del body llegan como
  -- TEXTO: convertirlos afuera del handler es lo que evita el 500 sin mensaje
  -- de un bind tipado que ORDS no logra convertir.
  ------------------------------------------------------------------------------
  FUNCTION NUMERO(p_valor VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN TO_NUMBER(NULLIF(TRIM(p_valor), ''));
  EXCEPTION
    WHEN OTHERS THEN
      RETURN NULL;
  END NUMERO;

  -- NULL cuando no vino y NULL cuando vino mal: el que llama distingue los dos
  -- casos mirando si el texto original estaba vacio, y solo asi puede devolver
  -- 400 por una fecha ilegible en vez de ignorarla.
  FUNCTION FECHA(p_valor VARCHAR2) RETURN DATE IS
  BEGIN
    RETURN TO_DATE(NULLIF(TRIM(p_valor), ''), 'YYYY-MM-DD');
  EXCEPTION
    WHEN OTHERS THEN
      RETURN NULL;
  END FECHA;

  FUNCTION VINO(p_valor VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN NULLIF(TRIM(p_valor), '') IS NOT NULL;
  END VINO;

  FUNCTION SESION(p_authorization VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
  END SESION;

  ------------------------------------------------------------------------------
  -- La hora, normalizada a HH24:MI.
  --
  -- HORA_DESDE y HORA_HASTA son VARCHAR2(10) sin CHECK: nada impide guardar
  -- "8hs" o "a la manana". Sin normalizar, ademas, '8:00' ordena DESPUES de
  -- '13:30' en cualquier ORDER BY de texto, y la ficha impresa sale con los
  -- grados desordenados.
  --
  -- Devuelve NULL si no se puede interpretar; el que llama decide si eso es un
  -- 400 (vino algo ilegible) o un campo vacio legitimo.
  ------------------------------------------------------------------------------
  FUNCTION NORMALIZAR_HORA(p_valor VARCHAR2) RETURN VARCHAR2 IS
    l_texto VARCHAR2(20);
    l_hora  PLS_INTEGER;
    l_min   PLS_INTEGER;
    l_pos   PLS_INTEGER;
  BEGIN
    l_texto := NULLIF(TRIM(p_valor), '');

    IF l_texto IS NULL THEN
      RETURN NULL;
    END IF;

    -- Se acepta '8:00' y '08.00': el separador puede ser dos puntos o punto,
    -- que es como lo escribe la mitad de la gente. Cualquier otra cosa cae en
    -- el NULL de abajo.
    l_texto := REPLACE(l_texto, '.', ':');
    l_pos   := INSTR(l_texto, ':');

    IF l_pos = 0 THEN
      RETURN NULL;
    END IF;

    l_hora := TO_NUMBER(SUBSTR(l_texto, 1, l_pos - 1));
    l_min  := TO_NUMBER(SUBSTR(l_texto, l_pos + 1));

    IF l_hora IS NULL OR l_min IS NULL
       OR l_hora < 0 OR l_hora > 23
       OR l_min  < 0 OR l_min  > 59 THEN
      RETURN NULL;
    END IF;

    RETURN LPAD(TO_CHAR(l_hora), 2, '0') || ':' || LPAD(TO_CHAR(l_min), 2, '0');
  EXCEPTION
    WHEN OTHERS THEN
      -- TO_NUMBER sobre texto no numerico. Es una hora ilegible, no un error
      -- del servidor.
      RETURN NULL;
  END NORMALIZAR_HORA;

  ------------------------------------------------------------------------------
  -- LA AUTORIZACION, EN UN SOLO LUGAR
  --
  -- Devuelve los datos derivados de la justificacion SOLO si es de la empresa
  -- que dice el que llama —medida contra el PROFESOR, no contra la columna
  -- ID_EMPRESA de la justificacion (ver cabecera)—.
  --
  -- Las dos preguntas, "existe" y "es tuya", en una sola funcion y con un solo
  -- desenlace: si es de otra empresa, para esta sesion es lo mismo que si no
  -- existiera. Un mensaje distinto para cada caso confirmaria que el id existe.
  ------------------------------------------------------------------------------
  PROCEDURE DATOS_DE_JUSTIFICACION (
    p_id_justificacion IN  NUMBER,
    p_id_empresa       IN  NUMBER,
    p_id_institucion   OUT NUMBER,
    p_fecha_ausencia   OUT DATE,
    p_id_empresa_real  OUT NUMBER,
    p_materia          OUT VARCHAR2,
    p_encontrada       OUT BOOLEAN
  ) IS
  BEGIN
    p_encontrada := FALSE;

    SELECT j.ID_INSTITUCION,
           j.FECHA_AUSENCIA_INICIO,
           -- La del PROFESOR: es la que se guarda en la ficha. La columna
           -- j.ID_EMPRESA no se lee nunca.
           p.ID_EMPRESA,
           j.MATERIA_AREA
      INTO p_id_institucion,
           p_fecha_ausencia,
           p_id_empresa_real,
           p_materia
      FROM JUSTIFICACIONES_AUSENCIA j
      JOIN PROFESORES p ON p.ID_PROFESOR = j.ID_PROFESOR
     WHERE j.ID_JUSTIFICACION = p_id_justificacion
       AND p.ID_EMPRESA       = p_id_empresa;

    p_encontrada := TRUE;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_encontrada := FALSE;
  END DATOS_DE_JUSTIFICACION;

  ------------------------------------------------------------------------------
  -- GUARDAR_DETALLE
  --
  -- NO hace COMMIT ni ROLLBACK y devuelve el error en un OUT en vez de lanzar:
  -- quien llama tiene que poder deshacer TAMBIEN la cabecera.
  ------------------------------------------------------------------------------
  PROCEDURE GUARDAR_DETALLE (
    p_id_ficha IN  NUMBER,
    p_detalle  IN  CLOB,
    p_lineas   OUT NUMBER,
    p_error    OUT VARCHAR2
  ) IS
    l_lineas PLS_INTEGER := 0;
    l_desde  VARCHAR2(10);
    l_hasta  VARCHAR2(10);
    l_grado  VARCHAR2(4000);
  BEGIN
    p_error  := NULL;
    p_lineas := 0;

    FOR linea IN (
      SELECT d.nro, d.gradoCurso, d.horaDesde, d.horaHasta,
             d.temaDesarrollar, d.observacionesGrupo
        FROM JSON_TABLE(
               p_detalle, '$[*]'
               COLUMNS (
                 -- FOR ORDINALITY y no ROWNUM: da la posicion REAL dentro del
                 -- array, que es la que el usuario ve en el formulario. ROWNUM
                 -- se asigna al leer y puede no coincidir con el orden del
                 -- JSON, asi que un mensaje de error apuntaria a la linea
                 -- equivocada.
                 nro                FOR ORDINALITY,
                 gradoCurso         VARCHAR2(4000) PATH '$.gradoCurso',
                 horaDesde          VARCHAR2(4000) PATH '$.horaDesde',
                 horaHasta          VARCHAR2(4000) PATH '$.horaHasta',
                 temaDesarrollar    VARCHAR2(4000) PATH '$.temaDesarrollar',
                 observacionesGrupo VARCHAR2(4000) PATH '$.observacionesGrupo'
               )
             ) d
    ) LOOP
      l_lineas := l_lineas + 1;

      IF l_lineas > C_MAX_LINEAS THEN
        p_error := 'La ficha no puede tener mas de ' || C_MAX_LINEAS || ' grados';
        RETURN;
      END IF;

      l_grado := NULLIF(TRIM(linea.gradoCurso), '');

      -- GRADO_CURSO es NOT NULL en el DDL: sin este chequeo el INSERT falla con
      -- ORA-01400, que llega al usuario como un 500 sin decir cual linea falto.
      IF l_grado IS NULL THEN
        p_error := 'La linea ' || linea.nro || ' no tiene grado o curso';
        RETURN;
      END IF;

      IF LENGTH(l_grado) > C_MAX_GRADO THEN
        p_error := 'El grado de la linea ' || linea.nro ||
                   ' no puede pasar de ' || C_MAX_GRADO || ' caracteres';
        RETURN;
      END IF;

      -- Las horas son opcionales, pero si vinieron tienen que ser horas. Una
      -- que no se entiende se avisa en vez de guardarse: la columna es texto
      -- libre y aceptaria "a la manana", dejando la ficha impresa con una
      -- columna de horario que no tiene horarios.
      l_desde := NORMALIZAR_HORA(linea.horaDesde);
      l_hasta := NORMALIZAR_HORA(linea.horaHasta);

      IF VINO(linea.horaDesde) AND l_desde IS NULL THEN
        p_error := 'La hora de inicio de la linea ' || linea.nro ||
                   ' no es una hora valida (formato HH:MM)';
        RETURN;
      END IF;

      IF VINO(linea.horaHasta) AND l_hasta IS NULL THEN
        p_error := 'La hora de fin de la linea ' || linea.nro ||
                   ' no es una hora valida (formato HH:MM)';
        RETURN;
      END IF;

      -- Comparacion de texto, que es exacta porque las dos estan normalizadas
      -- a HH24:MI con cero a la izquierda. Sin normalizar, '9:00' > '13:30'.
      IF l_desde IS NOT NULL AND l_hasta IS NOT NULL AND l_hasta <= l_desde THEN
        p_error := 'En la linea ' || linea.nro ||
                   ' la hora de fin tiene que ser posterior a la de inicio';
        RETURN;
      END IF;

      IF LENGTH(NULLIF(TRIM(linea.temaDesarrollar), '')) > C_MAX_TEXTO THEN
        p_error := 'El tema de la linea ' || linea.nro ||
                   ' no puede pasar de ' || C_MAX_TEXTO || ' caracteres';
        RETURN;
      END IF;

      IF LENGTH(NULLIF(TRIM(linea.observacionesGrupo), '')) > C_MAX_TEXTO THEN
        p_error := 'Las observaciones de la linea ' || linea.nro ||
                   ' no pueden pasar de ' || C_MAX_TEXTO || ' caracteres';
        RETURN;
      END IF;

      INSERT INTO FICHAS_TRASPASO_CLASE_DET (
        ID_FICHA_TRASPASO, GRADO_CURSO, HORA_DESDE, HORA_HASTA,
        TEMA_DESARROLLAR, OBSERVACIONES_GRUPO, FECHA_CREACION
      ) VALUES (
        p_id_ficha,
        l_grado,
        l_desde,
        l_hasta,
        NULLIF(TRIM(linea.temaDesarrollar), ''),
        NULLIF(TRIM(linea.observacionesGrupo), ''),
        SYSTIMESTAMP
      );
    END LOOP;

    p_lineas := l_lineas;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE IN (-40441, -40442, -40444) THEN
        -- Errores de parseo de JSON_TABLE: el array vino mal formado.
        p_error := 'El detalle no tiene un formato valido';
      ELSE
        APEX_DEBUG.ERROR('PKG_FICHAS_TRASPASO_CLASE.GUARDAR_DETALLE: [' || SQLCODE ||
                         '] ' || SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_error := 'Error al guardar el detalle de la ficha';
      END IF;
  END GUARDAR_DETALLE;

  ------------------------------------------------------------------------------
  -- El detalle de una ficha como array JSON.
  --
  -- Se arma APARTE y se inyecta con FORMAT JSON en el JSON_OBJECT de la
  -- cabecera: anidar un JSON_ARRAYAGG adentro vuelve a caer en el limite de
  -- 4000 bytes del resultado intermedio.
  ------------------------------------------------------------------------------
  FUNCTION DETALLE_JSON(p_id_ficha NUMBER) RETURN CLOB IS
    l_detalle CLOB;
  BEGIN
    SELECT JSON_ARRAYAGG(fila ORDER BY orden, id RETURNING CLOB)
      INTO l_detalle
      FROM (
        SELECT JSON_OBJECT(
                 'id'                 VALUE d.ID_DETALLE_FICHA,
                 'gradoCurso'         VALUE d.GRADO_CURSO,
                 'horaDesde'          VALUE d.HORA_DESDE,
                 'horaHasta'          VALUE d.HORA_HASTA,
                 'temaDesarrollar'    VALUE d.TEMA_DESARROLLAR,
                 'observacionesGrupo' VALUE d.OBSERVACIONES_GRUPO
                 RETURNING CLOB
               ) fila,
               -- Las horas se guardan normalizadas a HH24:MI, asi que ordenan
               -- bien como texto. NULLS LAST: una linea sin hora va al final,
               -- no arriba de la primera clase del dia.
               d.HORA_DESDE      orden,
               d.ID_DETALLE_FICHA id
          FROM FICHAS_TRASPASO_CLASE_DET d
         WHERE d.ID_FICHA_TRASPASO = p_id_ficha
         ORDER BY d.HORA_DESDE NULLS LAST, d.ID_DETALLE_FICHA
      );

    RETURN NVL(l_detalle, TO_CLOB('[]'));
  END DETALLE_JSON;

  ------------------------------------------------------------------------------
  -- La ficha entera como JSON, sin validar permisos: los valida quien llama.
  --
  -- Compartida por OBTENER y POR_JUSTIFICACION, que devuelven exactamente lo
  -- mismo y solo se diferencian en como encuentran la fila. Duplicar este
  -- JSON_OBJECT garantizaria que tarde o temprano uno devuelva un campo que el
  -- otro no.
  ------------------------------------------------------------------------------
  FUNCTION FICHA_JSON(p_id_ficha NUMBER) RETURN CLOB IS
    l_ficha   CLOB;
    l_detalle CLOB;
  BEGIN
    l_detalle := DETALLE_JSON(p_id_ficha);

    SELECT JSON_OBJECT(
             'id'               VALUE f.ID_FICHA_TRASPASO,
             -- La del PROFESOR de la justificacion, no f.ID_EMPRESA: la ficha
             -- guarda la buena, pero se devuelve la derivada por si alguna fila
             -- vieja quedo con otra cosa.
             'idEmpresa'        VALUE p.ID_EMPRESA,
             'idJustificacion'  VALUE f.ID_JUSTIFICACION,
             'idProfesor'       VALUE j.ID_PROFESOR,
             'profesor'         VALUE p.NOMBRE || NVL2(p.APELLIDO, ' ' || p.APELLIDO, ''),
             'idInstitucion'    VALUE f.ID_INSTITUCION,
             'institucion'      VALUE i.NOMBRE_INSTITUCION,
             -- Formato ISO explicito: un DATE crudo sale con el formato NLS de
             -- la sesion ('20-AGO-24'), que `new Date()` no parsea.
             'fechaAusencia'    VALUE TO_CHAR(f.FECHA_AUSENCIA, 'YYYY-MM-DD'),
             -- Las fechas de la ausencia, para que la ficha pueda decir "dia 1
             -- de 3" sin pedir la justificacion aparte.
             'fechaInicio'      VALUE TO_CHAR(j.FECHA_AUSENCIA_INICIO, 'YYYY-MM-DD'),
             'fechaFin'         VALUE TO_CHAR(j.FECHA_AUSENCIA_FIN, 'YYYY-MM-DD'),
             'turno'            VALUE j.TURNO_HORARIO,
             'suplente'         VALUE j.SUPLENTE_ASIGNADO,
             'estadoJustificacion' VALUE UPPER(TRIM(NVL(j.ESTADO_SOLICITUD, 'PENDIENTE'))),
             -- Los cuatro textos ENTEROS: esta es la que lee el formulario.
             'materiaArea'      VALUE f.MATERIA_AREA,
             'personaContacto'  VALUE f.PERSONA_CONTACTO,
             'ingresoRequisitos' VALUE f.INGRESO_REQUISITOS,
             'materialesRecursos' VALUE f.MATERIALES_RECURSOS,
             'otrasIndicaciones' VALUE f.OTRAS_INDICACIONES,
             'observacionesAdicionales' VALUE f.OBSERVACIONES_ADICIONALES,
             'detalle'          VALUE l_detalle FORMAT JSON,
             'fechaCreacion'    VALUE TO_CHAR(f.FECHA_CREACION, 'YYYY-MM-DD"T"HH24:MI:SS'),
             'fechaActualizacion' VALUE TO_CHAR(f.FECHA_ACTUALIZACION, 'YYYY-MM-DD"T"HH24:MI:SS')
             RETURNING CLOB
           )
      INTO l_ficha
      FROM FICHAS_TRASPASO_CLASE f
      JOIN JUSTIFICACIONES_AUSENCIA j ON j.ID_JUSTIFICACION = f.ID_JUSTIFICACION
      JOIN PROFESORES p               ON p.ID_PROFESOR      = j.ID_PROFESOR
      LEFT JOIN INSTITUCIONES i       ON i.ID_INSTITUCION   = f.ID_INSTITUCION
     WHERE f.ID_FICHA_TRASPASO = p_id_ficha;

    RETURN l_ficha;
  END FICHA_JSON;

  ------------------------------------------------------------------------------
  -- LISTAR
  ------------------------------------------------------------------------------
  PROCEDURE LISTAR (
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_desde          IN  VARCHAR2,
    p_hasta          IN  VARCHAR2,
    p_id_profesor    IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_busqueda       IN  VARCHAR2,
    p_pagina         IN  VARCHAR2,
    p_tamanio        IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_empresa     NUMBER;
    l_profesor    NUMBER;
    l_institucion NUMBER;
    l_desde       DATE;
    l_hasta       DATE;
    l_busqueda    VARCHAR2(200);
    l_pagina      NUMBER;
    l_tamanio     NUMBER;
    l_offset      NUMBER;
    l_total       NUMBER;
    l_items       CLOB;
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa     := NUMERO(p_id_empresa);
    l_profesor    := NUMERO(p_id_profesor);
    l_institucion := NUMERO(p_id_institucion);
    l_desde       := FECHA(p_desde);
    l_hasta       := FECHA(p_hasta);
    l_busqueda    := LOWER(NULLIF(TRIM(p_busqueda), ''));

    -- Obligatorio, nunca "todas": esta consulta NO se acota sola. El filtro por
    -- empresa vive en el JOIN, asi que sin l_empresa el WHERE desaparece y
    -- devuelve las fichas de todo el sistema, que se ven igual a las propias.
    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- Una fecha ilegible se avisa; ignorarla devolveria el historial entero
    -- como si el filtro no existiera.
    IF (VINO(p_desde) AND l_desde IS NULL) OR (VINO(p_hasta) AND l_hasta IS NULL) THEN
      p_status_code := 400;
      p_resultado   := '{"error":"Las fechas deben tener formato YYYY-MM-DD"}';
      RETURN;
    END IF;

    -- FECHA_AUSENCIA es DATE y puede traer hora: "<= hasta" dejaria afuera el
    -- ultimo dia.
    IF l_hasta IS NOT NULL THEN
      l_hasta := l_hasta + 1;
    END IF;

    l_pagina  := GREATEST(NVL(NUMERO(p_pagina), 1), 1);
    l_tamanio := LEAST(GREATEST(NVL(NUMERO(p_tamanio), 20), 1), C_TAMANIO_MAXIMO);
    l_offset  := (l_pagina - 1) * l_tamanio;

    -- El total cuenta las filas que pasan el filtro, no las de la pagina: es lo
    -- que le dice al frontend si queda algo por traer. Lleva los MISMOS JOIN
    -- que el SELECT, o cuenta de mas.
    SELECT COUNT(*)
      INTO l_total
      FROM FICHAS_TRASPASO_CLASE f
      JOIN JUSTIFICACIONES_AUSENCIA j ON j.ID_JUSTIFICACION = f.ID_JUSTIFICACION
      JOIN PROFESORES p               ON p.ID_PROFESOR      = j.ID_PROFESOR
      LEFT JOIN INSTITUCIONES i       ON i.ID_INSTITUCION   = f.ID_INSTITUCION
     WHERE p.ID_EMPRESA = l_empresa
       AND (l_desde IS NULL OR f.FECHA_AUSENCIA >= l_desde)
       AND (l_hasta IS NULL OR f.FECHA_AUSENCIA <  l_hasta)
       AND (l_profesor IS NULL OR j.ID_PROFESOR = l_profesor)
       AND (l_institucion IS NULL OR f.ID_INSTITUCION = l_institucion)
       AND (l_busqueda IS NULL
            OR LOWER(p.NOMBRE || ' ' || p.APELLIDO) LIKE '%' || l_busqueda || '%'
            OR LOWER(i.NOMBRE_INSTITUCION)   LIKE '%' || l_busqueda || '%'
            OR LOWER(f.MATERIA_AREA)         LIKE '%' || l_busqueda || '%'
            OR LOWER(f.PERSONA_CONTACTO)     LIKE '%' || l_busqueda || '%'
            OR LOWER(j.SUPLENTE_ASIGNADO)    LIKE '%' || l_busqueda || '%');

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta a los 4000 bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY fecha DESC, id DESC RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'              VALUE f.ID_FICHA_TRASPASO,
                 'idEmpresa'       VALUE p.ID_EMPRESA,
                 'idJustificacion' VALUE f.ID_JUSTIFICACION,
                 'idProfesor'      VALUE j.ID_PROFESOR,
                 -- Del JOIN: sin el, la grilla resolveria una peticion por fila.
                 'profesor'        VALUE p.NOMBRE || NVL2(p.APELLIDO, ' ' || p.APELLIDO, ''),
                 'idInstitucion'   VALUE f.ID_INSTITUCION,
                 'institucion'     VALUE i.NOMBRE_INSTITUCION,
                 'fechaAusencia'   VALUE TO_CHAR(f.FECHA_AUSENCIA, 'YYYY-MM-DD'),
                 'materiaArea'     VALUE f.MATERIA_AREA,
                 'personaContacto' VALUE f.PERSONA_CONTACTO,
                 'suplente'        VALUE j.SUPLENTE_ASIGNADO,
                 -- Cuantos grados tiene la ficha. Es el dato que dice si esta
                 -- cargada de verdad o si quedo a medias: una ficha sin grados
                 -- no le sirve al suplente.
                 'cantidadGrados'  VALUE (SELECT COUNT(*)
                                            FROM FICHAS_TRASPASO_CLASE_DET d
                                           WHERE d.ID_FICHA_TRASPASO = f.ID_FICHA_TRASPASO),
                 -- LOS CUATRO TEXTOS LARGOS NO VIAJAN, solo si tienen algo.
                 -- Veinte filas con las cuatro llenas son 80.000 caracteres,
                 -- MUY por encima del techo de 4000 bytes del bind de ORDS.
                 -- La ficha entera sale de /obtener.
                 'tieneIngreso'    VALUE CASE WHEN f.INGRESO_REQUISITOS IS NOT NULL
                                              THEN 'S' ELSE 'N' END,
                 'tieneMateriales' VALUE CASE WHEN f.MATERIALES_RECURSOS IS NOT NULL
                                              THEN 'S' ELSE 'N' END,
                 'tieneIndicaciones' VALUE CASE WHEN f.OTRAS_INDICACIONES IS NOT NULL
                                              THEN 'S' ELSE 'N' END,
                 'tieneObservaciones' VALUE CASE WHEN f.OBSERVACIONES_ADICIONALES IS NOT NULL
                                              THEN 'S' ELSE 'N' END,
                 'fechaCreacion'   VALUE TO_CHAR(f.FECHA_CREACION, 'YYYY-MM-DD"T"HH24:MI:SS'),
                 'fechaActualizacion' VALUE TO_CHAR(f.FECHA_ACTUALIZACION, 'YYYY-MM-DD"T"HH24:MI:SS')
                 RETURNING CLOB
               ) fila,
               f.FECHA_AUSENCIA    fecha,
               f.ID_FICHA_TRASPASO id
          FROM FICHAS_TRASPASO_CLASE f
          JOIN JUSTIFICACIONES_AUSENCIA j ON j.ID_JUSTIFICACION = f.ID_JUSTIFICACION
          JOIN PROFESORES p               ON p.ID_PROFESOR      = j.ID_PROFESOR
          LEFT JOIN INSTITUCIONES i       ON i.ID_INSTITUCION   = f.ID_INSTITUCION
         WHERE p.ID_EMPRESA = l_empresa
           AND (l_desde IS NULL OR f.FECHA_AUSENCIA >= l_desde)
           AND (l_hasta IS NULL OR f.FECHA_AUSENCIA <  l_hasta)
           AND (l_profesor IS NULL OR j.ID_PROFESOR = l_profesor)
           AND (l_institucion IS NULL OR f.ID_INSTITUCION = l_institucion)
           AND (l_busqueda IS NULL
                OR LOWER(p.NOMBRE || ' ' || p.APELLIDO) LIKE '%' || l_busqueda || '%'
                OR LOWER(i.NOMBRE_INSTITUCION)   LIKE '%' || l_busqueda || '%'
                OR LOWER(f.MATERIA_AREA)         LIKE '%' || l_busqueda || '%'
                OR LOWER(f.PERSONA_CONTACTO)     LIKE '%' || l_busqueda || '%'
                OR LOWER(j.SUPLENTE_ASIGNADO)    LIKE '%' || l_busqueda || '%')
         ORDER BY f.FECHA_AUSENCIA DESC, f.ID_FICHA_TRASPASO DESC
         OFFSET l_offset ROWS FETCH NEXT l_tamanio ROWS ONLY
      );

    p_status_code := 200;

    -- RETURNING CLOB no va en una asignacion PL/SQL suelta (PLS-00684).
    SELECT JSON_OBJECT(
             'items'   VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON,
             'total'   VALUE l_total,
             'pagina'  VALUE l_pagina,
             'tamanio' VALUE l_tamanio
             RETURNING CLOB
           )
      INTO p_resultado
      FROM DUAL;

  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_FICHAS_TRASPASO_CLASE.LISTAR: ' || SQLERRM);
      p_resultado := '{"error":"Error al listar las fichas de traspaso"}';
  END LISTAR;

  ------------------------------------------------------------------------------
  -- OBTENER
  ------------------------------------------------------------------------------
  PROCEDURE OBTENER (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_id      NUMBER;
    l_empresa NUMBER;
    l_existe  PLS_INTEGER;
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id      := NUMERO(p_id);
    l_empresa := NUMERO(p_id_empresa);

    IF l_id IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    -- El permiso se comprueba aparte de armar el JSON: FICHA_JSON no filtra por
    -- empresa a proposito —lo comparte con POR_JUSTIFICACION— y meterle el
    -- filtro adentro obligaria a pasarle la empresa a una funcion que solo
    -- tiene que saber dibujar la ficha.
    SELECT COUNT(*)
      INTO l_existe
      FROM FICHAS_TRASPASO_CLASE f
      JOIN JUSTIFICACIONES_AUSENCIA j ON j.ID_JUSTIFICACION = f.ID_JUSTIFICACION
      JOIN PROFESORES p               ON p.ID_PROFESOR      = j.ID_PROFESOR
     WHERE f.ID_FICHA_TRASPASO = l_id
       AND p.ID_EMPRESA        = l_empresa;

    IF l_existe = 0 THEN
      -- No existe y "es de otra empresa" se contestan igual: distinguirlas
      -- confirmaria la existencia de datos ajenos.
      p_status_code := 404;
      p_resultado   := '{"error":"Ficha de traspaso no encontrada"}';
      RETURN;
    END IF;

    p_resultado   := FICHA_JSON(l_id);
    p_status_code := 200;

  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_FICHAS_TRASPASO_CLASE.OBTENER: ' || SQLERRM);
      p_resultado := '{"error":"Error al obtener la ficha de traspaso"}';
  END OBTENER;

  ------------------------------------------------------------------------------
  -- POR_JUSTIFICACION
  --
  -- "Esta ausencia no tiene ficha" es 200 con ficha en null, NO un 404: es el
  -- estado normal de una ausencia recien recibida, y un 404 obligaria a la
  -- pantalla a tratar como falla el camino habitual.
  --
  -- El 404 queda para la justificacion que no existe o no es de esta empresa,
  -- que si es un error de quien llama.
  ------------------------------------------------------------------------------
  PROCEDURE POR_JUSTIFICACION (
    p_authorization     IN  VARCHAR2,
    p_id_justificacion  IN  VARCHAR2,
    p_id_empresa        IN  VARCHAR2,
    p_status_code       OUT NUMBER,
    p_resultado         OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_justif      NUMBER;
    l_empresa     NUMBER;
    l_id_ficha    NUMBER;
    l_institucion NUMBER;
    l_fecha       DATE;
    l_empresa_real NUMBER;
    l_materia     VARCHAR2(4000);
    l_encontrada  BOOLEAN;
    l_ficha       CLOB;
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_justif  := NUMERO(p_id_justificacion);
    l_empresa := NUMERO(p_id_empresa);

    IF l_justif IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"idJustificacion e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    DATOS_DE_JUSTIFICACION(l_justif, l_empresa, l_institucion, l_fecha,
                           l_empresa_real, l_materia, l_encontrada);

    IF NOT l_encontrada THEN
      p_status_code := 404;
      p_resultado   := '{"error":"Justificacion no encontrada"}';
      RETURN;
    END IF;

    BEGIN
      SELECT f.ID_FICHA_TRASPASO
        INTO l_id_ficha
        FROM FICHAS_TRASPASO_CLASE f
       WHERE f.ID_JUSTIFICACION = l_justif;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        l_id_ficha := NULL;
      WHEN TOO_MANY_ROWS THEN
        -- No deberia pasar: CREAR lo impide. Puede haber quedado de antes de
        -- este paquete, o de dos altas simultaneas si el UNIQUE del DDL todavia
        -- no se agrego (ver cabecera). Se devuelve la mas nueva en vez de
        -- fallar: la pantalla tiene que poder abrir algo.
        SELECT MAX(f.ID_FICHA_TRASPASO)
          INTO l_id_ficha
          FROM FICHAS_TRASPASO_CLASE f
         WHERE f.ID_JUSTIFICACION = l_justif;
    END;

    IF l_id_ficha IS NULL THEN
      p_status_code := 200;
      -- La materia de la justificacion viaja igual: es lo que el formulario de
      -- alta propone como valor inicial, y sin esto habria que pedir la
      -- justificacion aparte solo para eso.
      SELECT JSON_OBJECT(
               'ficha'           VALUE NULL,
               'idJustificacion' VALUE l_justif,
               'idInstitucion'   VALUE l_institucion,
               'fechaAusencia'   VALUE TO_CHAR(l_fecha, 'YYYY-MM-DD'),
               'materiaSugerida' VALUE l_materia
               RETURNING CLOB
             )
        INTO p_resultado
        FROM DUAL;
      RETURN;
    END IF;

    l_ficha := FICHA_JSON(l_id_ficha);

    SELECT JSON_OBJECT(
             'ficha'           VALUE l_ficha FORMAT JSON,
             'idJustificacion' VALUE l_justif,
             'idInstitucion'   VALUE l_institucion,
             'fechaAusencia'   VALUE TO_CHAR(l_fecha, 'YYYY-MM-DD'),
             'materiaSugerida' VALUE l_materia
             RETURNING CLOB
           )
      INTO p_resultado
      FROM DUAL;

    p_status_code := 200;

  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_FICHAS_TRASPASO_CLASE.POR_JUSTIFICACION: ' || SQLERRM);
      p_resultado := '{"error":"Error al buscar la ficha de la justificacion"}';
  END POR_JUSTIFICACION;

  ------------------------------------------------------------------------------
  -- CREAR
  ------------------------------------------------------------------------------
  PROCEDURE CREAR (
    p_authorization             IN  VARCHAR2,
    p_id_empresa                IN  VARCHAR2,
    p_id_justificacion          IN  VARCHAR2,
    p_materia_area              IN  VARCHAR2,
    p_persona_contacto          IN  VARCHAR2,
    p_ingreso_requisitos        IN  VARCHAR2,
    p_materiales_recursos       IN  VARCHAR2,
    p_otras_indicaciones        IN  VARCHAR2,
    p_observaciones_adicionales IN  VARCHAR2,
    p_detalle                   IN  CLOB,
    p_status_code               OUT NUMBER,
    p_resultado                 OUT CLOB
  ) IS
    l_sesion       NUMBER;
    l_empresa      NUMBER;
    l_justif       NUMBER;
    l_institucion  NUMBER;
    l_fecha        DATE;
    l_empresa_real NUMBER;
    l_materia_padre VARCHAR2(4000);
    l_encontrada   BOOLEAN;
    l_existe       PLS_INTEGER;
    l_id           NUMBER;
    l_lineas       NUMBER;
    l_error        VARCHAR2(4000);
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa := NUMERO(p_id_empresa);
    l_justif  := NUMERO(p_id_justificacion);

    IF l_empresa IS NULL OR l_justif IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"idEmpresa e idJustificacion son obligatorios"}';
      RETURN;
    END IF;

    IF LENGTH(NULLIF(TRIM(p_materia_area), '')) > C_MAX_MATERIA THEN
      p_status_code := 400;
      p_resultado   := '{"error":"La materia no puede pasar de 200 caracteres"}';
      RETURN;
    END IF;

    IF LENGTH(NULLIF(TRIM(p_persona_contacto), '')) > C_MAX_CONTACTO THEN
      p_status_code := 400;
      p_resultado   := '{"error":"La persona de contacto no puede pasar de 200 caracteres"}';
      RETURN;
    END IF;

    IF LENGTH(NULLIF(TRIM(p_ingreso_requisitos), ''))        > C_MAX_TEXTO
       OR LENGTH(NULLIF(TRIM(p_materiales_recursos), ''))     > C_MAX_TEXTO
       OR LENGTH(NULLIF(TRIM(p_otras_indicaciones), ''))      > C_MAX_TEXTO
       OR LENGTH(NULLIF(TRIM(p_observaciones_adicionales), '')) > C_MAX_TEXTO THEN
      p_status_code := 400;
      p_resultado   := '{"error":"Los textos de la ficha no pueden pasar de 1000 caracteres"}';
      RETURN;
    END IF;

    -- La justificacion tiene que existir Y ser de esta empresa —medida contra
    -- el profesor—. De aca salen la institucion y la fecha: no se piden.
    DATOS_DE_JUSTIFICACION(l_justif, l_empresa, l_institucion, l_fecha,
                           l_empresa_real, l_materia_padre, l_encontrada);

    IF NOT l_encontrada THEN
      p_status_code := 404;
      p_resultado   := '{"error":"Justificacion no encontrada"}';
      RETURN;
    END IF;

    -- UNA FICHA POR JUSTIFICACION. Es una regla del paquete, no de la base:
    -- mientras el DDL no tenga el UNIQUE, dos altas simultaneas pasan las dos
    -- este COUNT. Ver la cabecera.
    SELECT COUNT(*)
      INTO l_existe
      FROM FICHAS_TRASPASO_CLASE f
     WHERE f.ID_JUSTIFICACION = l_justif;

    IF l_existe > 0 THEN
      p_status_code := 409;
      p_resultado   := '{"error":"Esta ausencia ya tiene una ficha de traspaso. Editala en vez de crear otra."}';
      RETURN;
    END IF;

    -- ID_INSTITUCION y FECHA_AUSENCIA salen de la justificacion, no del body.
    -- ID_EMPRESA se escribe con la del PROFESOR (l_empresa_real), que es la
    -- unica confiable: la columna es NOT NULL y hay que ponerle algo, y ponerle
    -- el dato bueno cuesta lo mismo que ponerle uno malo.
    INSERT INTO FICHAS_TRASPASO_CLASE (
      ID_EMPRESA, ID_JUSTIFICACION, ID_INSTITUCION, FECHA_AUSENCIA,
      MATERIA_AREA, PERSONA_CONTACTO, INGRESO_REQUISITOS, MATERIALES_RECURSOS,
      OTRAS_INDICACIONES, OBSERVACIONES_ADICIONALES,
      FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_empresa_real,
      l_justif,
      l_institucion,
      l_fecha,
      -- Si no mandaron materia, se hereda la de la justificacion: es el valor
      -- que el formulario propone, y aceptarlo vacio dejaria la ficha sin decir
      -- de que materia es.
      NVL(NULLIF(TRIM(p_materia_area), ''), l_materia_padre),
      NULLIF(TRIM(p_persona_contacto), ''),
      NULLIF(TRIM(p_ingreso_requisitos), ''),
      NULLIF(TRIM(p_materiales_recursos), ''),
      NULLIF(TRIM(p_otras_indicaciones), ''),
      NULLIF(TRIM(p_observaciones_adicionales), ''),
      SYSTIMESTAMP,
      SYSTIMESTAMP
    ) RETURNING ID_FICHA_TRASPASO INTO l_id;

    -- El detalle es opcional en el alta: una ficha puede empezar con los datos
    -- de acceso y completarse con los grados despues. Sin grados no le sirve al
    -- suplente, pero eso lo avisa la pantalla —con cantidadGrados— y no es
    -- motivo para rechazar el alta a medias.
    IF p_detalle IS NOT NULL AND DBMS_LOB.GETLENGTH(p_detalle) > 0 THEN
      GUARDAR_DETALLE(l_id, p_detalle, l_lineas, l_error);

      IF l_error IS NOT NULL THEN
        ROLLBACK;   -- Deshace TAMBIEN la cabecera.
        p_status_code := 400;
        SELECT JSON_OBJECT('error' VALUE l_error RETURNING CLOB)
          INTO p_resultado FROM DUAL;
        RETURN;
      END IF;
    END IF;

    COMMIT;

    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);

  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- Si el DDL ya tiene UNIQUE (ID_JUSTIFICACION), la carrera que el COUNT
      -- de arriba no puede cubrir termina aca, con el mismo 409.
      p_status_code := 409;
      p_resultado   := '{"error":"Esta ausencia ya tiene una ficha de traspaso. Editala en vez de crear otra."}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_FICHAS_TRASPASO_CLASE.CREAR: ' || SQLERRM ||
                       ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al crear la ficha de traspaso"}';
  END CREAR;

  ------------------------------------------------------------------------------
  -- ACTUALIZAR
  --
  -- Un campo vacio BORRA (ver cabecera). ID_JUSTIFICACION, ID_INSTITUCION y
  -- FECHA_AUSENCIA no aparecen en el SET: los dos ultimos son derivados y el
  -- primero define la ficha. ID_EMPRESA tampoco —poder cambiarla permitiria
  -- mover la fila a otra empresa desde el endpoint que deberia impedirlo—.
  ------------------------------------------------------------------------------
  PROCEDURE ACTUALIZAR (
    p_authorization             IN  VARCHAR2,
    p_id                        IN  VARCHAR2,
    p_id_empresa                IN  VARCHAR2,
    p_materia_area              IN  VARCHAR2,
    p_persona_contacto          IN  VARCHAR2,
    p_ingreso_requisitos        IN  VARCHAR2,
    p_materiales_recursos       IN  VARCHAR2,
    p_otras_indicaciones        IN  VARCHAR2,
    p_observaciones_adicionales IN  VARCHAR2,
    p_detalle                   IN  CLOB,
    p_status_code               OUT NUMBER,
    p_resultado                 OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_id      NUMBER;
    l_empresa NUMBER;
    l_lineas  NUMBER;
    l_error   VARCHAR2(4000);
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id      := NUMERO(p_id);
    l_empresa := NUMERO(p_id_empresa);

    IF l_id IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    IF LENGTH(NULLIF(TRIM(p_materia_area), '')) > C_MAX_MATERIA THEN
      p_status_code := 400;
      p_resultado   := '{"error":"La materia no puede pasar de 200 caracteres"}';
      RETURN;
    END IF;

    IF LENGTH(NULLIF(TRIM(p_persona_contacto), '')) > C_MAX_CONTACTO THEN
      p_status_code := 400;
      p_resultado   := '{"error":"La persona de contacto no puede pasar de 200 caracteres"}';
      RETURN;
    END IF;

    IF LENGTH(NULLIF(TRIM(p_ingreso_requisitos), ''))        > C_MAX_TEXTO
       OR LENGTH(NULLIF(TRIM(p_materiales_recursos), ''))     > C_MAX_TEXTO
       OR LENGTH(NULLIF(TRIM(p_otras_indicaciones), ''))      > C_MAX_TEXTO
       OR LENGTH(NULLIF(TRIM(p_observaciones_adicionales), '')) > C_MAX_TEXTO THEN
      p_status_code := 400;
      p_resultado   := '{"error":"Los textos de la ficha no pueden pasar de 1000 caracteres"}';
      RETURN;
    END IF;

    UPDATE FICHAS_TRASPASO_CLASE f
       SET f.MATERIA_AREA              = NULLIF(TRIM(p_materia_area), ''),
           f.PERSONA_CONTACTO          = NULLIF(TRIM(p_persona_contacto), ''),
           f.INGRESO_REQUISITOS        = NULLIF(TRIM(p_ingreso_requisitos), ''),
           f.MATERIALES_RECURSOS       = NULLIF(TRIM(p_materiales_recursos), ''),
           f.OTRAS_INDICACIONES        = NULLIF(TRIM(p_otras_indicaciones), ''),
           f.OBSERVACIONES_ADICIONALES = NULLIF(TRIM(p_observaciones_adicionales), ''),
           f.FECHA_ACTUALIZACION       = SYSTIMESTAMP
     WHERE f.ID_FICHA_TRASPASO = l_id
       -- El mismo filtro del listado, escrito como EXISTS porque un UPDATE no
       -- lleva JOIN. Sin esto se edita por endpoint la ficha de otra empresa:
       -- filtrar el listado no alcanza.
       AND EXISTS (SELECT 1
                     FROM JUSTIFICACIONES_AUSENCIA j
                     JOIN PROFESORES p ON p.ID_PROFESOR = j.ID_PROFESOR
                    WHERE j.ID_JUSTIFICACION = f.ID_JUSTIFICACION
                      AND p.ID_EMPRESA       = l_empresa);

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado   := '{"error":"Ficha de traspaso no encontrada"}';
      RETURN;
    END IF;

    -- EL DETALLE SE REEMPLAZA ENTERO, y solo si vino: un PUT que cambia
    -- unicamente la persona de contacto deja los grados como estaban.
    -- Comparar linea por linea seria mucho mas codigo para el mismo resultado
    -- en fichas de cinco o diez grados.
    IF p_detalle IS NOT NULL AND DBMS_LOB.GETLENGTH(p_detalle) > 0 THEN
      DELETE FROM FICHAS_TRASPASO_CLASE_DET
       WHERE ID_FICHA_TRASPASO = l_id;

      GUARDAR_DETALLE(l_id, p_detalle, l_lineas, l_error);

      IF l_error IS NOT NULL THEN
        ROLLBACK;   -- Deshace tambien el UPDATE y el DELETE.
        p_status_code := 400;
        SELECT JSON_OBJECT('error' VALUE l_error RETURNING CLOB)
          INTO p_resultado FROM DUAL;
        RETURN;
      END IF;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado   := '{"ok":true}';

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_FICHAS_TRASPASO_CLASE.ACTUALIZAR: ' || SQLERRM ||
                       ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al actualizar la ficha de traspaso"}';
  END ACTUALIZAR;

  ------------------------------------------------------------------------------
  -- ELIMINAR
  --
  -- Baja fisica, detalle primero: el DDL no declara ON DELETE CASCADE y al
  -- reves da ORA-02292.
  ------------------------------------------------------------------------------
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
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id      := NUMERO(p_id);
    l_empresa := NUMERO(p_id_empresa);

    IF l_id IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    -- El subselect acota por empresa: sin el, mandar el id de una ficha ajena
    -- le borraria las lineas aunque el DELETE de la cabecera no hiciera nada.
    DELETE FROM FICHAS_TRASPASO_CLASE_DET d
     WHERE d.ID_FICHA_TRASPASO IN (
             SELECT f.ID_FICHA_TRASPASO
               FROM FICHAS_TRASPASO_CLASE f
               JOIN JUSTIFICACIONES_AUSENCIA j ON j.ID_JUSTIFICACION = f.ID_JUSTIFICACION
               JOIN PROFESORES p               ON p.ID_PROFESOR      = j.ID_PROFESOR
              WHERE f.ID_FICHA_TRASPASO = l_id
                AND p.ID_EMPRESA        = l_empresa
           );

    DELETE FROM FICHAS_TRASPASO_CLASE f
     WHERE f.ID_FICHA_TRASPASO = l_id
       AND EXISTS (SELECT 1
                     FROM JUSTIFICACIONES_AUSENCIA j
                     JOIN PROFESORES p ON p.ID_PROFESOR = j.ID_PROFESOR
                    WHERE j.ID_JUSTIFICACION = f.ID_JUSTIFICACION
                      AND p.ID_EMPRESA       = l_empresa);

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado   := '{"error":"Ficha de traspaso no encontrada"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado   := '{"ok":true}';

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_FICHAS_TRASPASO_CLASE.ELIMINAR: ' || SQLERRM);
      p_resultado := '{"error":"Error al eliminar la ficha de traspaso"}';
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- PUBLICACION DE LOS ENDPOINTS
  --
  -- Cada handler declara SOLO tres parametros: el header `authorization`, el
  -- CLOB de salida y el status code. Los query params (?idEmpresa=, ?desde=) y
  -- los campos del body se vinculan SOLOS al bind del mismo nombre, sin
  -- DEFINE_PARAMETER.
  --
  -- LAS LLAMADAS VAN ESCRITAS UNA POR UNA, CON LOS VALORES LITERALES. Envolver
  -- ORDS.DEFINE_PARAMETER en un helper propio hace que ORDS rechace el PRIMER
  -- parametro con ORA-02290 (REST_PARAMS_SOURCE_TYPE_CK) sobre un HEADER/IN
  -- identico al que publican los otros cuarenta modulos; lo unico distinto es
  -- pasar el valor por variable en vez de literal. El error corta la
  -- publicacion a la mitad y deja el modulo SIN NINGUN endpoint. Ver la
  -- cabecera de db/reportes-actividades.sql: NO reintroducir los helpers.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no del workspace, y NO es un parametro de
  -- DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin esto, toda
  -- peticion cross-origin la rechaza ORDS ANTES de llegar al handler, con un
  -- "Service Unavailable" que ningun WHEN OTHERS puede capturar.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'fichas-traspaso-clase',
      p_base_path      => '/fichas-traspaso-clase/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Fichas de traspaso de clase para suplencias'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'fichas-traspaso-clase',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /fichas-traspaso-clase/listar
    --   ?idEmpresa= &desde= &hasta= &idProfesor= &idInstitucion= &busqueda=
    --   &pagina= &tamanio=
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'fichas-traspaso-clase', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'fichas-traspaso-clase',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_FICHAS_TRASPASO_CLASE.LISTAR(:authorization, :idEmpresa, :desde, :hasta, :idProfesor, :idInstitucion, :busqueda, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /fichas-traspaso-clase/obtener/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'fichas-traspaso-clase', p_pattern => 'obtener/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'fichas-traspaso-clase',
      p_pattern     => 'obtener/:id/:idEmpresa',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_FICHAS_TRASPASO_CLASE.OBTENER(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /fichas-traspaso-clase/por-justificacion/:idJustificacion/:idEmpresa
    --
    -- Devuelve 200 con ficha en null si la ausencia todavia no tiene ficha.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'fichas-traspaso-clase', p_pattern => 'por-justificacion/:idJustificacion/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'fichas-traspaso-clase',
      p_pattern     => 'por-justificacion/:idJustificacion/:idEmpresa',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_FICHAS_TRASPASO_CLASE.POR_JUSTIFICACION(:authorization, :idJustificacion, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'por-justificacion/:idJustificacion/:idEmpresa', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'por-justificacion/:idJustificacion/:idEmpresa', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'por-justificacion/:idJustificacion/:idEmpresa', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /fichas-traspaso-clase/crear
    -- Body: { idEmpresa, idJustificacion, materiaArea, personaContacto,
    --         ingresoRequisitos, materialesRecursos, otrasIndicaciones,
    --         observacionesAdicionales, detalle: [...] }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'fichas-traspaso-clase', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'fichas-traspaso-clase',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_FICHAS_TRASPASO_CLASE.CREAR(:authorization, :idEmpresa, :idJustificacion, :materiaArea, :personaContacto, :ingresoRequisitos, :materialesRecursos, :otrasIndicaciones, :observacionesAdicionales, :detalle, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /fichas-traspaso-clase/actualizar/:id
    -- Body: { idEmpresa, materiaArea, personaContacto, ingresoRequisitos,
    --         materialesRecursos, otrasIndicaciones, observacionesAdicionales,
    --         detalle: [...] }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'fichas-traspaso-clase', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'fichas-traspaso-clase',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_FICHAS_TRASPASO_CLASE.ACTUALIZAR(:authorization, :id, :idEmpresa, :materiaArea, :personaContacto, :ingresoRequisitos, :materialesRecursos, :otrasIndicaciones, :observacionesAdicionales, :detalle, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /fichas-traspaso-clase/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'fichas-traspaso-clase', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'fichas-traspaso-clase',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_FICHAS_TRASPASO_CLASE.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'fichas-traspaso-clase', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_FICHAS_TRASPASO_CLASE;
/

BEGIN
  PKG_FICHAS_TRASPASO_CLASE.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- VERIFICACION
--
-- Un paquete INVALID responde 500 sin mensaje: el WHEN OTHERS no captura
-- errores de compilacion. Mirar SIEMPRE la salida de estas consultas.
--------------------------------------------------------------------------------
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_FICHAS_TRASPASO_CLASE';

SELECT LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_FICHAS_TRASPASO_CLASE'
 ORDER BY LINE;

-- Seis handlers: listar, obtener, por-justificacion, crear, actualizar y
-- eliminar. Si falta alguno, la publicacion se corto a la mitad.
SELECT m.NAME, t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_MODULES m
  JOIN USER_ORDS_TEMPLATES t ON t.MODULE_ID = m.ID
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
 WHERE m.NAME = 'fichas-traspaso-clase'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

--------------------------------------------------------------------------------
-- EL UNIQUE QUE LE FALTA AL DDL
--
-- "Una ficha por justificacion" hoy la garantiza el paquete, no la base (ver
-- cabecera). Esta consulta muestra si hay que limpiar algo antes de agregar la
-- restriccion; si devuelve cero filas, se puede ejecutar directo:
--
--   ALTER TABLE FICHAS_TRASPASO_CLASE
--     ADD CONSTRAINT UQ_FICHA_JUSTIFICACION UNIQUE (ID_JUSTIFICACION);
--
-- El paquete ya traduce el DUP_VAL_ON_INDEX al mismo 409, asi que agregarlo no
-- rompe nada: solo convierte la regla en garantia.
--------------------------------------------------------------------------------
SELECT f.ID_JUSTIFICACION, COUNT(*) AS FICHAS
  FROM FICHAS_TRASPASO_CLASE f
 GROUP BY f.ID_JUSTIFICACION
HAVING COUNT(*) > 1
 ORDER BY FICHAS DESC;

--------------------------------------------------------------------------------
-- AUDITORIA
--
-- Coherencias que el DDL no puede expresar. TODAS TIENEN QUE DEVOLVER CERO
-- FILAS; si devuelven algo, es un dato que hay que mirar.
--------------------------------------------------------------------------------

-- 1. Fichas cuya ID_EMPRESA no es la de su profesor.
--
-- El hub no lee esa columna —filtra por la del profesor— pero SI la escribe con
-- el valor bueno. Lo que aparezca aca es anterior a este paquete, o lo cargo
-- otro programa. No rompe nada mientras nadie consulte la tabla por fuera del
-- hub, que es justamente el riesgo que esta consulta vigila.
SELECT f.ID_FICHA_TRASPASO, f.ID_EMPRESA AS EN_LA_FICHA, p.ID_EMPRESA AS DEL_PROFESOR
  FROM FICHAS_TRASPASO_CLASE f
  JOIN JUSTIFICACIONES_AUSENCIA j ON j.ID_JUSTIFICACION = f.ID_JUSTIFICACION
  JOIN PROFESORES p               ON p.ID_PROFESOR      = j.ID_PROFESOR
 WHERE f.ID_EMPRESA <> p.ID_EMPRESA
 ORDER BY f.ID_FICHA_TRASPASO;

-- 2. Fichas cuya institucion o fecha no coincide con su justificacion.
--
-- Las dos se DERIVAN en el alta, asi que no deberia haber ninguna. Lo que
-- aparezca aca se cargo por fuera del paquete, o quedo de una justificacion que
-- se corrigio despues — este segundo caso es real y hay que decidirlo a mano:
-- la ficha impresa puede estar circulando con la fecha vieja.
SELECT f.ID_FICHA_TRASPASO,
       f.ID_INSTITUCION AS EN_LA_FICHA,
       j.ID_INSTITUCION AS EN_LA_AUSENCIA,
       f.FECHA_AUSENCIA AS FECHA_FICHA,
       j.FECHA_AUSENCIA_INICIO AS FECHA_AUSENCIA
  FROM FICHAS_TRASPASO_CLASE f
  JOIN JUSTIFICACIONES_AUSENCIA j ON j.ID_JUSTIFICACION = f.ID_JUSTIFICACION
 WHERE f.ID_INSTITUCION <> j.ID_INSTITUCION
    OR TRUNC(f.FECHA_AUSENCIA) <> TRUNC(j.FECHA_AUSENCIA_INICIO)
 ORDER BY f.ID_FICHA_TRASPASO;

-- 3. Fichas sin ningun grado cargado.
--
-- No es un error de datos: el alta las permite a proposito (se cargan los datos
-- de acceso y los grados despues). Pero una ficha sin grados NO LE SIRVE AL
-- SUPLENTE, asi que conviene tener el numero a la vista. La pantalla lo avisa
-- con `cantidadGrados`.
SELECT f.ID_FICHA_TRASPASO, f.FECHA_AUSENCIA, f.MATERIA_AREA
  FROM FICHAS_TRASPASO_CLASE f
 WHERE NOT EXISTS (SELECT 1 FROM FICHAS_TRASPASO_CLASE_DET d
                    WHERE d.ID_FICHA_TRASPASO = f.ID_FICHA_TRASPASO)
 ORDER BY f.FECHA_AUSENCIA DESC;

-- 4. Horas que no quedaron en formato HH:MM.
--
-- El paquete las normaliza al guardar, asi que lo que aparezca aca es anterior
-- o lo escribio otro programa. Ordenan mal en la ficha impresa: '8:00' cae
-- despues de '13:30' en un ORDER BY de texto.
SELECT d.ID_DETALLE_FICHA, d.ID_FICHA_TRASPASO, d.GRADO_CURSO,
       d.HORA_DESDE, d.HORA_HASTA
  FROM FICHAS_TRASPASO_CLASE_DET d
 WHERE (d.HORA_DESDE IS NOT NULL
        AND NOT REGEXP_LIKE(d.HORA_DESDE, '^[0-2][0-9]:[0-5][0-9]$'))
    OR (d.HORA_HASTA IS NOT NULL
        AND NOT REGEXP_LIKE(d.HORA_HASTA, '^[0-2][0-9]:[0-5][0-9]$'))
 ORDER BY d.ID_FICHA_TRASPASO, d.ID_DETALLE_FICHA;
