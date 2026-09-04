--------------------------------------------------------------------------------
-- CTELL · JUSTIFICACIONES DE AUSENCIA
--
-- Un paquete (PKG_JUSTIFICACIONES_AUSENCIA) con la bandeja de solicitudes y la
-- publicacion de los endpoints ORDS. Todo vive dentro del paquete: no hay
-- procedimientos sueltos ni PL/SQL embebido como texto dentro de los handlers.
--
--   1. LISTAR      GET  /justificaciones-ausencia/listar
--   2. OBTENER     GET  /justificaciones-ausencia/obtener/:id/:idEmpresa
--   3. ACTUALIZAR  PUT  /justificaciones-ausencia/actualizar/:id
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token y para saber quien recibio la solicitud.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/justificaciones-ausencia/
--
-- Tabla (no la crea ni la altera):
--   JUSTIFICACIONES_AUSENCIA  ID_JUSTIFICACION, ID_EMPRESA, ID_PROFESOR,
--                             ID_INSTITUCION, MATERIA_AREA,
--                             FECHA_AUSENCIA_INICIO, FECHA_AUSENCIA_FIN,
--                             CANTIDAD_DIAS_HORAS, TURNO_HORARIO,
--                             CURSOS_GRUPOS, DESCRIPCION_MOTIVO,
--                             URL_ARCHIVO_RESPALDO, ESTADO_SOLICITUD,
--                             RECIBIDO_POR, FECHA_RECEPCION,
--                             SUPLENTE_ASIGNADO, OBSERVACIONES, FECHA_ENVIO,
--                             FECHA_CREACION, FECHA_ACTUALIZACION
--
--------------------------------------------------------------------------------
-- ESTA TABLA LA ESCRIBEN DOS PROGRAMAS, Y CADA UNO ESCRIBE SU MITAD
--
-- La solicitud la CREA la app del profesor, que no es este proyecto. El hub la
-- RESUELVE. Son dos mitades que no se pisan:
--
--   La app escribe   profesor, institucion, materia, fechas de la ausencia,
--                    turno, cursos, motivo, archivo de respaldo, FECHA_ENVIO
--                    y el ESTADO_SOLICITUD inicial (PENDIENTE).
--
--   El hub escribe   ESTADO_SOLICITUD, RECIBIDO_POR, FECHA_RECEPCION,
--                    SUPLENTE_ASIGNADO y OBSERVACIONES. NADA MAS.
--
-- Por eso ACA NO HAY /crear NI /eliminar, y no es un olvido. Una justificacion
-- es un documento que mando una persona: el hub la resuelve, no la fabrica ni
-- la hace desaparecer. Un ABM completo dejaria que administracion cargue una
-- ausencia a nombre de un profesor que nunca la pidio, y que borre la unica
-- constancia de una que si pidio. Si algun dia hace falta cargar la que llego
-- en papel, va como un endpoint aparte y con su propio motivo escrito.
--
-- Y por eso el ACTUALIZAR no menciona ni una de las columnas de la app. No
-- alcanza con que la pantalla no las muestre: el que llama al endpoint puede
-- ser cualquiera con un token.
--
--------------------------------------------------------------------------------
-- LA EMPRESA ES LA DEL PROFESOR, NO LA DE LA COLUMNA
--
-- El COMMENT de ID_EMPRESA lo dice sin rodeos: "La app la fija SIEMPRE en 1".
-- Es una columna que no se lee: si el hub filtrara por ella, una empresa
-- distinta de la 1 tendria la bandeja vacia mientras sus profesores mandan
-- solicitudes, y la empresa 1 veria las de todo el mundo.
--
-- Asi que el filtro es UNO SOLO y va contra el padre, igual que en
-- db/asistencias-profesores.sql:
--
--   JOIN PROFESORES p ON p.ID_PROFESOR = j.ID_PROFESOR
--   WHERE p.ID_EMPRESA = l_empresa
--
-- La cedula es unica en todo el sistema, asi que un profesor pertenece a una
-- sola empresa y su solicitud se lista donde esta el, tenga j.ID_EMPRESA lo que
-- tenga. Va en las TRES consultas —el listado, su COUNT y el UPDATE—: filtrar
-- el listado no alcanza, o se edita por endpoint una solicitud ajena.
--
-- En el UPDATE el JOIN no se puede escribir, asi que va como EXISTS. Es el
-- mismo filtro, no una version relajada.
--
--------------------------------------------------------------------------------
-- ESTADO_SOLICITUD ACEPTA NULL, NO TIENE CHECK, Y LO ESCRIBE OTRO PROGRAMA
--
-- Tres cosas que hay que mirar juntas:
--
--   1. La columna es NULLABLE con DEFAULT PENDIENTE. Un DEFAULT solo actua
--      cuando el INSERT no nombra la columna: si la app manda NULL explicito,
--      queda NULL. Por eso se lee siempre NVL(ESTADO_SOLICITUD, 'PENDIENTE') —
--      una solicitud sin estado es una solicitud pendiente, no una fila rota
--      que no aparece en ningun filtro.
--
--   2. NO HAY CHECK. Los cuatro valores viven en un COMMENT, y un COMMENT no es
--      una restriccion (la misma trampa que GRADO en db/manuales.sql). Los
--      valida ESTADO_VALIDO en este paquete, y LA MISMA LISTA ESTA EN
--      ESTADOS_JUSTIFICACION de src/lib/api.ts: si se agrega un estado, van
--      los dos. Sin eso 'Aprobado' entra como un estado distinto de 'APROBADA'
--      y la bandeja muestra dos columnas para lo mismo.
--
--   3. Lo escribe otro programa. Por eso el valor se normaliza AL LEER
--      —UPPER(TRIM(...))— y no solo al escribir: si la app guardo 'aprobada',
--      el filtro de la bandeja tiene que encontrarla igual.
--
-- Un estado que no este en la lista SE MUESTRA pero NO SE OFRECE como filtro,
-- como PROCESADO en el reporte de inventarios: el dato existe y esconderlo
-- seria peor.
--
--------------------------------------------------------------------------------
-- QUIEN RECIBIO LA SOLICITUD SALE DEL TOKEN, Y SE SELLA UNA SOLA VEZ
--
-- RECIBIDO_POR y FECHA_RECEPCION no viajan en el body: los pone el paquete con
-- el usuario de la sesion la PRIMERA vez que alguien gestiona la solicitud, y
-- despues no se pisan (NVL contra el valor que ya tiene la fila).
--
-- Aceptarlos del cliente convertiria una auditoria en una casilla de texto:
-- cualquiera podria firmar la recepcion con el nombre de otro. Y volver a
-- escribirlos en cada guardado haria que corregir una observacion seis meses
-- despues mueva la fecha de recepcion a hoy, borrando cuando llego de verdad.
--
-- FECHA_RECEPCION va con TRUNC(SYSDATE) porque es una fecha, no un instante: el
-- momento exacto del ultimo cambio ya esta en FECHA_ACTUALIZACION.
--
-- Se valida el token con VALIDAR_TOKEN y no con VALIDAR_TOKEN_ADMIN: resolver
-- una justificacion es trabajo de negocio, no administracion del sistema. Quien
-- puede entrar lo decide el permiso de la pagina, como en el resto del hub.
--
--------------------------------------------------------------------------------
-- EN EL ACTUALIZAR, UN CAMPO VACIO BORRA
--
-- Rompe el criterio del resto del proyecto (NVL = "no cambiar") a proposito, y
-- por el mismo motivo que db/inventarios.sql: el formulario manda SIEMPRE los
-- tres campos, y son los unicos editables. Con el NVL habitual, quien pego un
-- suplente en la solicitud equivocada no tendria forma de dejarlo en blanco —
-- el campo se vaciaria en pantalla y volveria lleno al recargar.
--
-- El estado es la excepcion dentro de la excepcion: vacio es 400, no borrado.
-- Una solicitud sin estado no significa nada.
--
--------------------------------------------------------------------------------
-- LOS TEXTOS LARGOS NO VIAJAN ENTEROS EN EL LISTADO
--
-- DESCRIPCION_MOTIVO y OBSERVACIONES aceptan 1000 caracteres cada una. Veinte
-- filas con las dos llenas pasan el techo de 4000 bytes del bind de ORDS, que
-- devuelve un 500 que ningun WHEN OTHERS registra porque el PL/SQL ya termino
-- bien. Van recortadas a 200, con su flag de "hay mas".
--
-- Y DE AHI SALE LA REGLA MAS IMPORTANTE DE LA PANTALLA: el dialogo de gestion
-- carga con /obtener, NUNCA con la fila del listado. OBSERVACIONES es editable:
-- guardar la fila del listado escribiria el resumen de 200 encima de los 1000.
-- Es exactamente la trampa de INVENTARIOS.OBSERVACIONES.
--
--------------------------------------------------------------------------------
-- EL ARCHIVO DE RESPALDO SE OFRECE SOLO SI ES https
--
-- URL_ARCHIVO_RESPALDO es texto que escribio otro programa y que esta pantalla
-- mete en un <a href>. El COMMENT dice que la app la valida contra Cloudinary;
-- que la app valide no es garantia de lo que hay guardado. Un javascript: ahi
-- adentro es un enlace que ejecuta script al tocarlo.
--
-- Asi que el endpoint devuelve urlArchivo SOLO cuando empieza con https://, y
-- aparte tieneArchivo cuando la columna tiene algo. Con los dos, la pantalla
-- distingue "no adjunto nada" de "adjunto algo que no se puede abrir" — que es
-- justo el caso que hay que poder ver, no esconder.
--
--------------------------------------------------------------------------------
-- EL RANGO DE FECHAS ES UN SOLAPAMIENTO
--
-- Una ausencia es un intervalo, no un dia. Filtrar el mes con
-- FECHA_AUSENCIA_INICIO BETWEEN desde AND hasta pierde la licencia que arranco
-- el 29 de marzo y termino el 4 de abril: no aparece en abril, y en abril es
-- cuando hay que resolverla.
--
--   INICIO < hasta + 1  AND  NVL(FIN, INICIO) >= desde
--
-- FECHA_AUSENCIA_FIN en NULL significa "un solo dia" (su COMMENT), asi que el
-- NVL contra INICIO no es un parche: es la definicion de la columna.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_JUSTIFICACIONES_AUSENCIA AS

  -- La bandeja. Solo idEmpresa es obligatorio; el resto acota.
  -- `motivo` y `observaciones` vienen RECORTADOS a 200 caracteres.
  PROCEDURE LISTAR (
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_desde          IN  VARCHAR2,
    p_hasta          IN  VARCHAR2,
    p_id_profesor    IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_estado         IN  VARCHAR2,
    p_busqueda       IN  VARCHAR2,
    p_pagina         IN  VARCHAR2,
    p_tamanio        IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  );

  -- La ficha entera, con el motivo y las observaciones completas. Es la que
  -- tiene que usar el dialogo de gestion, nunca la fila del listado.
  PROCEDURE OBTENER (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  ------------------------------------------------------------------------------
  -- LA RESOLUCION DE LA SOLICITUD, Y SOLO ESO
  --
  -- Body: { idEmpresa, estado, suplenteAsignado, observaciones }
  --
  -- No recibe ni una columna de las que escribe la app, y no recibe
  -- recibidoPor ni fechaRecepcion: esos dos los sella el paquete con el usuario
  -- del token (ver cabecera).
  --
  -- Los campos del JSON llegan SUELTOS como binds (:idEmpresa, :estado, ...),
  -- no dentro de :body, que es el payload crudo como BLOB. Un JSON_VALUE sobre
  -- el devuelve NULL en todo y el endpoint contesta 400 con el body bien
  -- puesto. Del lado del cliente hay que mandar TODAS las claves aunque vayan
  -- en "": una clave omitida deja el bind sin definir en vez de en NULL.
  ------------------------------------------------------------------------------
  PROCEDURE ACTUALIZAR (
    p_authorization     IN  VARCHAR2,
    p_id                IN  VARCHAR2,
    p_id_empresa        IN  VARCHAR2,
    p_estado            IN  VARCHAR2,
    p_suplente_asignado IN  VARCHAR2,
    p_observaciones     IN  VARCHAR2,
    p_status_code       OUT NUMBER,
    p_resultado         OUT CLOB
  );

  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_JUSTIFICACIONES_AUSENCIA;
/

CREATE OR REPLACE PACKAGE BODY PKG_JUSTIFICACIONES_AUSENCIA AS

  -- Lo que viaja de un texto largo en el listado. La ficha entera sale de
  -- OBTENER: ver "LOS TEXTOS LARGOS" en la cabecera.
  C_RESUMEN        CONSTANT PLS_INTEGER := 200;

  -- 50 y no 200 aunque otras tablas lo acepten: cada fila lleva dos textos
  -- libres y una pagina grande vuelve a rozar el bind de ORDS.
  C_TAMANIO_MAXIMO CONSTANT PLS_INTEGER := 50;

  -- Los topes de las dos columnas que escribe este paquete. Estan aca y no en
  -- un COMMENT para poder devolver un 400 legible en vez del ORA-12899 que
  -- llegaria al cliente como un 500 mudo.
  C_MAX_SUPLENTE      CONSTANT PLS_INTEGER := 200;
  C_MAX_OBSERVACIONES CONSTANT PLS_INTEGER := 1000;

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
         WHERE NAME = 'justificaciones-ausencia';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'justificaciones-ausencia');
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
  -- El estado, normalizado igual que se lo lee de la columna.
  --
  -- La MISMA expresion —UPPER(TRIM(...))— se escribe inline en las consultas
  -- sobre ESTADO_SOLICITUD. Una funcion privada no se puede invocar desde SQL
  -- (PLS-00231), y no vale la pena una version mas lista de la que el SQL no
  -- pueda copiar: si las dos no coinciden, el filtro no encuentra las filas.
  ------------------------------------------------------------------------------
  FUNCTION NORMALIZAR_ESTADO(p_valor VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    -- El REPLACE del '+' es por 'EN REVISION', el unico valor con espacio: en
    -- una query string un espacio viaja como '+', y aunque ORDS lo decodifica
    -- como corresponde, si algun dia no lo hiciera el filtro no fallaria — solo
    -- devolveria cero filas, en silencio. Ningun estado valido lleva un '+', asi
    -- que la conversion no puede romper nada.
    RETURN UPPER(TRIM(REPLACE(NULLIF(TRIM(p_valor), ''), '+', ' ')));
  END NORMALIZAR_ESTADO;

  -- Los cuatro valores del COMMENT de la columna, que no tiene CHECK. La misma
  -- lista vive en ESTADOS_JUSTIFICACION de src/lib/api.ts: si se agrega uno,
  -- van los dos.
  FUNCTION ESTADO_VALIDO(p_estado VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN p_estado IN ('PENDIENTE', 'EN REVISION', 'APROBADA', 'RECHAZADA');
  END ESTADO_VALIDO;

  -- El nombre con el que se firma la recepcion. Protegido: si el usuario del
  -- token se borro entre medio, la gestion no tiene por que fallar — queda sin
  -- firma, que es exactamente lo que paso.
  FUNCTION NOMBRE_DE_USUARIO(p_id_usuario NUMBER) RETURN VARCHAR2 IS
    l_nombre USUARIOS.NOMBRE_APELLIDO%TYPE;
  BEGIN
    SELECT NOMBRE_APELLIDO
      INTO l_nombre
      FROM USUARIOS
     WHERE ID_USUARIO = p_id_usuario;

    RETURN l_nombre;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END NOMBRE_DE_USUARIO;

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
    p_estado         IN  VARCHAR2,
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
    l_estado      VARCHAR2(50);
    l_desde       DATE;
    l_hasta       DATE;
    l_busqueda    VARCHAR2(200);
    l_pagina      NUMBER;
    l_tamanio     NUMBER;
    l_offset      NUMBER;
    l_total       NUMBER;
    l_items       CLOB;
    -- En una variable local y no la constante del paquete: una constante del
    -- BODY dentro de una sentencia SQL es la misma clase de dependencia que un
    -- helper privado, y no vale arriesgar un PLS-00231 por ahorrar una linea.
    l_resumen     PLS_INTEGER := C_RESUMEN;
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
    -- Un estado desconocido NO se rechaza en el LISTAR: la columna no tiene
    -- CHECK y otro programa la escribe, asi que puede haber filas con un valor
    -- que este paquete no conoce. Filtrar por el devuelve cero filas, que es la
    -- respuesta correcta, no un error. En el ACTUALIZAR si es 400: ahi el valor
    -- lo escribe el hub.
    l_estado      := NORMALIZAR_ESTADO(p_estado);
    l_desde       := FECHA(p_desde);
    l_hasta       := FECHA(p_hasta);
    l_busqueda    := LOWER(NULLIF(TRIM(p_busqueda), ''));

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

    -- El rango se cierra con "< hasta + 1": FECHA_AUSENCIA_INICIO es DATE y
    -- puede traer hora, y "<= hasta" dejaria afuera el ultimo dia.
    IF l_hasta IS NOT NULL THEN
      l_hasta := l_hasta + 1;
    END IF;

    l_pagina  := GREATEST(NVL(NUMERO(p_pagina), 1), 1);
    l_tamanio := LEAST(GREATEST(NVL(NUMERO(p_tamanio), 20), 1), C_TAMANIO_MAXIMO);
    l_offset  := (l_pagina - 1) * l_tamanio;

    -- El total cuenta las filas que pasan el filtro, no las de la pagina: es lo
    -- que le dice al frontend si queda algo por traer. Lleva el MISMO JOIN
    -- contra PROFESORES que el SELECT, o cuenta de mas.
    SELECT COUNT(*)
      INTO l_total
      FROM JUSTIFICACIONES_AUSENCIA j
      JOIN PROFESORES p ON p.ID_PROFESOR = j.ID_PROFESOR
      LEFT JOIN INSTITUCIONES i ON i.ID_INSTITUCION = j.ID_INSTITUCION
     WHERE p.ID_EMPRESA = l_empresa
       AND (l_desde IS NULL OR NVL(j.FECHA_AUSENCIA_FIN, j.FECHA_AUSENCIA_INICIO) >= l_desde)
       AND (l_hasta IS NULL OR j.FECHA_AUSENCIA_INICIO < l_hasta)
       AND (l_profesor IS NULL OR j.ID_PROFESOR = l_profesor)
       AND (l_institucion IS NULL OR j.ID_INSTITUCION = l_institucion)
       AND (l_estado IS NULL
            OR UPPER(TRIM(NVL(j.ESTADO_SOLICITUD, 'PENDIENTE'))) = l_estado)
       AND (l_busqueda IS NULL
            OR LOWER(p.NOMBRE || ' ' || p.APELLIDO) LIKE '%' || l_busqueda || '%'
            OR LOWER(i.NOMBRE_INSTITUCION)  LIKE '%' || l_busqueda || '%'
            OR LOWER(j.MATERIA_AREA)        LIKE '%' || l_busqueda || '%'
            OR LOWER(j.CURSOS_GRUPOS)       LIKE '%' || l_busqueda || '%'
            OR LOWER(j.DESCRIPCION_MOTIVO)  LIKE '%' || l_busqueda || '%'
            OR LOWER(j.SUPLENTE_ASIGNADO)   LIKE '%' || l_busqueda || '%');

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta a los 4000 bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY inicio DESC, id DESC RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'            VALUE j.ID_JUSTIFICACION,
                 -- La del PROFESOR, no la de la fila: j.ID_EMPRESA la app la
                 -- fija siempre en 1 y devolverla seria repetir el dato malo.
                 'idEmpresa'     VALUE p.ID_EMPRESA,
                 'idProfesor'    VALUE j.ID_PROFESOR,
                 -- Del JOIN: sin el, la grilla resolveria una peticion por fila.
                 'profesor'      VALUE p.NOMBRE || NVL2(p.APELLIDO, ' ' || p.APELLIDO, ''),
                 'idInstitucion' VALUE j.ID_INSTITUCION,
                 'institucion'   VALUE i.NOMBRE_INSTITUCION,
                 'materia'       VALUE j.MATERIA_AREA,
                 -- Formato ISO explicito: un DATE crudo sale con el formato NLS
                 -- de la sesion ('20-AGO-24'), que `new Date()` no parsea.
                 'fechaInicio'   VALUE TO_CHAR(j.FECHA_AUSENCIA_INICIO, 'YYYY-MM-DD'),
                 'fechaFin'      VALUE TO_CHAR(j.FECHA_AUSENCIA_FIN, 'YYYY-MM-DD'),
                 -- Derivado de las fechas, que es lo unico verificable.
                 -- CANTIDAD_DIAS_HORAS viaja aparte y sin tocar: es texto libre
                 -- que escribio el profesor ("4 horas"), y los dos pueden no
                 -- coincidir. Mostrar los dos es justamente el punto.
                 'dias'          VALUE GREATEST(
                                         NVL(TRUNC(j.FECHA_AUSENCIA_FIN)
                                             - TRUNC(j.FECHA_AUSENCIA_INICIO), 0) + 1, 1),
                 'cantidadDeclarada' VALUE j.CANTIDAD_DIAS_HORAS,
                 'turno'         VALUE j.TURNO_HORARIO,
                 'cursos'        VALUE j.CURSOS_GRUPOS,
                 -- RECORTADOS: la ficha entera sale de /obtener, y el flag le
                 -- dice a la grilla si poner el "seguir leyendo".
                 'motivo'        VALUE SUBSTR(j.DESCRIPCION_MOTIVO, 1, l_resumen),
                 'motivoTruncado' VALUE CASE WHEN LENGTH(j.DESCRIPCION_MOTIVO) > l_resumen
                                             THEN 'S' ELSE 'N' END,
                 -- Solo si es https: lo escribio otro programa y termina en un
                 -- <a href>. `tieneArchivo` va aparte para poder distinguir "no
                 -- adjunto nada" de "adjunto algo que no se puede ofrecer".
                 'urlArchivo'    VALUE CASE WHEN j.URL_ARCHIVO_RESPALDO LIKE 'https://%'
                                            THEN j.URL_ARCHIVO_RESPALDO END,
                 'tieneArchivo'  VALUE CASE WHEN j.URL_ARCHIVO_RESPALDO IS NOT NULL
                                            THEN 'S' ELSE 'N' END,
                 'estado'        VALUE UPPER(TRIM(NVL(j.ESTADO_SOLICITUD, 'PENDIENTE'))),
                 'recibidoPor'   VALUE j.RECIBIDO_POR,
                 'fechaRecepcion' VALUE TO_CHAR(j.FECHA_RECEPCION, 'YYYY-MM-DD'),
                 'suplente'      VALUE j.SUPLENTE_ASIGNADO,
                 'observaciones' VALUE SUBSTR(j.OBSERVACIONES, 1, l_resumen),
                 'observacionesTruncadas' VALUE CASE WHEN LENGTH(j.OBSERVACIONES) > l_resumen
                                                     THEN 'S' ELSE 'N' END,
                 -- FECHA_ENVIO es la hora LOCAL del profesor y FECHA_CREACION
                 -- el UTC del servidor (sus COMMENT lo dicen). No son el mismo
                 -- reloj: no se las puede comparar ni usar una por la otra.
                 'fechaEnvio'    VALUE TO_CHAR(j.FECHA_ENVIO, 'YYYY-MM-DD"T"HH24:MI:SS'),
                 'fechaCreacion' VALUE TO_CHAR(j.FECHA_CREACION, 'YYYY-MM-DD"T"HH24:MI:SS'),
                 'fechaActualizacion' VALUE TO_CHAR(j.FECHA_ACTUALIZACION, 'YYYY-MM-DD"T"HH24:MI:SS')
                 RETURNING CLOB
               ) fila,
               j.FECHA_AUSENCIA_INICIO inicio,
               j.ID_JUSTIFICACION      id
          FROM JUSTIFICACIONES_AUSENCIA j
          JOIN PROFESORES p ON p.ID_PROFESOR = j.ID_PROFESOR
          LEFT JOIN INSTITUCIONES i ON i.ID_INSTITUCION = j.ID_INSTITUCION
         WHERE p.ID_EMPRESA = l_empresa
           AND (l_desde IS NULL OR NVL(j.FECHA_AUSENCIA_FIN, j.FECHA_AUSENCIA_INICIO) >= l_desde)
           AND (l_hasta IS NULL OR j.FECHA_AUSENCIA_INICIO < l_hasta)
           AND (l_profesor IS NULL OR j.ID_PROFESOR = l_profesor)
           AND (l_institucion IS NULL OR j.ID_INSTITUCION = l_institucion)
           AND (l_estado IS NULL
                OR UPPER(TRIM(NVL(j.ESTADO_SOLICITUD, 'PENDIENTE'))) = l_estado)
           AND (l_busqueda IS NULL
                OR LOWER(p.NOMBRE || ' ' || p.APELLIDO) LIKE '%' || l_busqueda || '%'
                OR LOWER(i.NOMBRE_INSTITUCION)  LIKE '%' || l_busqueda || '%'
                OR LOWER(j.MATERIA_AREA)        LIKE '%' || l_busqueda || '%'
                OR LOWER(j.CURSOS_GRUPOS)       LIKE '%' || l_busqueda || '%'
                OR LOWER(j.DESCRIPCION_MOTIVO)  LIKE '%' || l_busqueda || '%'
                OR LOWER(j.SUPLENTE_ASIGNADO)   LIKE '%' || l_busqueda || '%')
         ORDER BY j.FECHA_AUSENCIA_INICIO DESC, j.ID_JUSTIFICACION DESC
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
      APEX_DEBUG.ERROR('PKG_JUSTIFICACIONES_AUSENCIA.LISTAR: ' || SQLERRM);
      p_resultado := '{"error":"Error al listar las justificaciones"}';
  END LISTAR;

  ------------------------------------------------------------------------------
  -- OBTENER
  --
  -- La ficha con los textos completos. El WHERE lleva el mismo filtro por la
  -- empresa del profesor que el listado: si no, con un id adivinado se lee la
  -- solicitud de otra empresa.
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

    SELECT JSON_OBJECT(
             'id'            VALUE j.ID_JUSTIFICACION,
             'idEmpresa'     VALUE p.ID_EMPRESA,
             'idProfesor'    VALUE j.ID_PROFESOR,
             'profesor'      VALUE p.NOMBRE || NVL2(p.APELLIDO, ' ' || p.APELLIDO, ''),
             'idInstitucion' VALUE j.ID_INSTITUCION,
             'institucion'   VALUE i.NOMBRE_INSTITUCION,
             'materia'       VALUE j.MATERIA_AREA,
             'fechaInicio'   VALUE TO_CHAR(j.FECHA_AUSENCIA_INICIO, 'YYYY-MM-DD'),
             'fechaFin'      VALUE TO_CHAR(j.FECHA_AUSENCIA_FIN, 'YYYY-MM-DD'),
             'dias'          VALUE GREATEST(
                                     NVL(TRUNC(j.FECHA_AUSENCIA_FIN)
                                         - TRUNC(j.FECHA_AUSENCIA_INICIO), 0) + 1, 1),
             'cantidadDeclarada' VALUE j.CANTIDAD_DIAS_HORAS,
             'turno'         VALUE j.TURNO_HORARIO,
             'cursos'        VALUE j.CURSOS_GRUPOS,
             -- Enteros, no recortados: estos son los que lee y edita el dialogo.
             'motivo'        VALUE j.DESCRIPCION_MOTIVO,
             'motivoTruncado' VALUE 'N',
             'urlArchivo'    VALUE CASE WHEN j.URL_ARCHIVO_RESPALDO LIKE 'https://%'
                                        THEN j.URL_ARCHIVO_RESPALDO END,
             'tieneArchivo'  VALUE CASE WHEN j.URL_ARCHIVO_RESPALDO IS NOT NULL
                                        THEN 'S' ELSE 'N' END,
             'estado'        VALUE UPPER(TRIM(NVL(j.ESTADO_SOLICITUD, 'PENDIENTE'))),
             'recibidoPor'   VALUE j.RECIBIDO_POR,
             'fechaRecepcion' VALUE TO_CHAR(j.FECHA_RECEPCION, 'YYYY-MM-DD'),
             'suplente'      VALUE j.SUPLENTE_ASIGNADO,
             'observaciones' VALUE j.OBSERVACIONES,
             'observacionesTruncadas' VALUE 'N',
             'fechaEnvio'    VALUE TO_CHAR(j.FECHA_ENVIO, 'YYYY-MM-DD"T"HH24:MI:SS'),
             'fechaCreacion' VALUE TO_CHAR(j.FECHA_CREACION, 'YYYY-MM-DD"T"HH24:MI:SS'),
             'fechaActualizacion' VALUE TO_CHAR(j.FECHA_ACTUALIZACION, 'YYYY-MM-DD"T"HH24:MI:SS')
             RETURNING CLOB
           )
      INTO p_resultado
      FROM JUSTIFICACIONES_AUSENCIA j
      JOIN PROFESORES p ON p.ID_PROFESOR = j.ID_PROFESOR
      LEFT JOIN INSTITUCIONES i ON i.ID_INSTITUCION = j.ID_INSTITUCION
     WHERE j.ID_JUSTIFICACION = l_id
       AND p.ID_EMPRESA = l_empresa;

    p_status_code := 200;

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      -- No existe y "es de otra empresa" se contestan igual: distinguirlas
      -- confirmaria la existencia de datos ajenos.
      p_status_code := 404;
      p_resultado   := '{"error":"Justificacion no encontrada"}';
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_JUSTIFICACIONES_AUSENCIA.OBTENER: ' || SQLERRM);
      p_resultado := '{"error":"Error al obtener la justificacion"}';
  END OBTENER;

  ------------------------------------------------------------------------------
  -- ACTUALIZAR
  --
  -- La resolucion de la solicitud: estado, suplente y observaciones. NINGUNA
  -- columna de las que escribe la app aparece en el SET, y ID_EMPRESA tampoco
  -- —poder cambiarla permitiria mover la fila a otra empresa desde el endpoint
  -- que deberia impedirlo—.
  --
  -- Un suplente o una observacion vacios BORRAN (ver la cabecera). El estado no:
  -- vacio es 400.
  ------------------------------------------------------------------------------
  PROCEDURE ACTUALIZAR (
    p_authorization     IN  VARCHAR2,
    p_id                IN  VARCHAR2,
    p_id_empresa        IN  VARCHAR2,
    p_estado            IN  VARCHAR2,
    p_suplente_asignado IN  VARCHAR2,
    p_observaciones     IN  VARCHAR2,
    p_status_code       OUT NUMBER,
    p_resultado         OUT CLOB
  ) IS
    l_sesion        NUMBER;
    l_id            NUMBER;
    l_empresa       NUMBER;
    l_estado        VARCHAR2(50);
    l_suplente      VARCHAR2(4000);
    l_observaciones VARCHAR2(4000);
    l_usuario       VARCHAR2(200);
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id            := NUMERO(p_id);
    l_empresa       := NUMERO(p_id_empresa);
    l_estado        := NORMALIZAR_ESTADO(p_estado);
    l_suplente      := NULLIF(TRIM(p_suplente_asignado), '');
    l_observaciones := NULLIF(TRIM(p_observaciones), '');

    IF l_id IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    IF l_estado IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"El estado es obligatorio"}';
      RETURN;
    END IF;

    -- Aca si es 400: lo que el hub ESCRIBE tiene que estar en la lista. Leer un
    -- estado desconocido que dejo otro programa es otra cosa —eso se muestra—,
    -- pero agregar uno nuevo desde este endpoint es un error de quien llama.
    IF NOT ESTADO_VALIDO(l_estado) THEN
      p_status_code := 400;
      p_resultado   := '{"error":"El estado debe ser PENDIENTE, EN REVISION, APROBADA o RECHAZADA"}';
      RETURN;
    END IF;

    IF LENGTH(l_suplente) > C_MAX_SUPLENTE THEN
      p_status_code := 400;
      p_resultado   := '{"error":"El suplente no puede pasar de 200 caracteres"}';
      RETURN;
    END IF;

    IF LENGTH(l_observaciones) > C_MAX_OBSERVACIONES THEN
      p_status_code := 400;
      p_resultado   := '{"error":"Las observaciones no pueden pasar de 1000 caracteres"}';
      RETURN;
    END IF;

    -- Se resuelve antes del UPDATE: una funcion privada del body no se puede
    -- invocar dentro de una sentencia SQL (PLS-00231).
    l_usuario := NOMBRE_DE_USUARIO(l_sesion);

    UPDATE JUSTIFICACIONES_AUSENCIA j
       SET j.ESTADO_SOLICITUD    = l_estado,
           j.SUPLENTE_ASIGNADO   = l_suplente,
           j.OBSERVACIONES       = l_observaciones,
           -- Sellados la PRIMERA vez y nunca pisados: en un SET, la columna a
           -- la derecha vale lo que valia antes del UPDATE.
           j.RECIBIDO_POR        = NVL(j.RECIBIDO_POR, l_usuario),
           j.FECHA_RECEPCION     = NVL(j.FECHA_RECEPCION, TRUNC(SYSDATE)),
           j.FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE j.ID_JUSTIFICACION = l_id
       -- El mismo filtro del listado, escrito como EXISTS porque un UPDATE no
       -- lleva JOIN. Sin esto se resuelve por endpoint la solicitud de otra
       -- empresa: filtrar el listado no alcanza.
       AND EXISTS (SELECT 1
                     FROM PROFESORES p
                    WHERE p.ID_PROFESOR = j.ID_PROFESOR
                      AND p.ID_EMPRESA  = l_empresa);

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado   := '{"error":"Justificacion no encontrada"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado   := '{"ok":true}';

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_JUSTIFICACIONES_AUSENCIA.ACTUALIZAR: ' || SQLERRM);
      p_resultado := '{"error":"Error al actualizar la justificacion"}';
  END ACTUALIZAR;

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
      p_module_name    => 'justificaciones-ausencia',
      p_base_path      => '/justificaciones-ausencia/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Justificaciones de ausencia de profesores: bandeja y resolucion'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'justificaciones-ausencia',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /justificaciones-ausencia/listar
    --   ?idEmpresa= &desde= &hasta= &idProfesor= &idInstitucion= &estado=
    --   &busqueda= &pagina= &tamanio=
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'justificaciones-ausencia', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'justificaciones-ausencia',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_JUSTIFICACIONES_AUSENCIA.LISTAR(:authorization, :idEmpresa, :desde, :hasta, :idProfesor, :idInstitucion, :estado, :busqueda, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'justificaciones-ausencia', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'justificaciones-ausencia', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'justificaciones-ausencia', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /justificaciones-ausencia/obtener/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'justificaciones-ausencia', p_pattern => 'obtener/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'justificaciones-ausencia',
      p_pattern     => 'obtener/:id/:idEmpresa',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_JUSTIFICACIONES_AUSENCIA.OBTENER(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'justificaciones-ausencia', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'justificaciones-ausencia', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'justificaciones-ausencia', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /justificaciones-ausencia/actualizar/:id
    -- Body: { idEmpresa, estado, suplenteAsignado, observaciones }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'justificaciones-ausencia', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'justificaciones-ausencia',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_JUSTIFICACIONES_AUSENCIA.ACTUALIZAR(:authorization, :id, :idEmpresa, :estado, :suplenteAsignado, :observaciones, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'justificaciones-ausencia', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'justificaciones-ausencia', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'justificaciones-ausencia', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_JUSTIFICACIONES_AUSENCIA;
/

BEGIN
  PKG_JUSTIFICACIONES_AUSENCIA.PUBLICAR_ENDPOINTS;
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
 WHERE OBJECT_NAME = 'PKG_JUSTIFICACIONES_AUSENCIA';

SELECT LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_JUSTIFICACIONES_AUSENCIA'
 ORDER BY LINE;

-- Tres templates: listar, obtener y actualizar. Si falta alguno, la
-- publicacion se corto a la mitad.
SELECT m.NAME, t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_MODULES m
  JOIN USER_ORDS_TEMPLATES t ON t.MODULE_ID = m.ID
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
 WHERE m.NAME = 'justificaciones-ausencia'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

--------------------------------------------------------------------------------
-- AUDITORIA
--
-- Coherencias que el DDL no puede expresar. LAS DOS TIENEN QUE DEVOLVER CERO
-- FILAS; si devuelven algo, no es un error de este paquete sino un dato que hay
-- que mirar.
--------------------------------------------------------------------------------

-- 1. Solicitudes cuya ID_EMPRESA no es la de su profesor.
--
-- Se espera que devuelva MUCHAS: la app fija la columna en 1 para todos. Esta
-- consulta no esta para corregirlas —el hub ya no la lee, filtra por la del
-- profesor— sino para tener el numero a la vista el dia que alguien proponga
-- volver a confiar en esa columna.
SELECT COUNT(*)                                   AS CON_EMPRESA_DISTINTA,
       COUNT(DISTINCT j.ID_EMPRESA)               AS VALORES_DISTINTOS_EN_LA_COLUMNA
  FROM JUSTIFICACIONES_AUSENCIA j
  JOIN PROFESORES p ON p.ID_PROFESOR = j.ID_PROFESOR
 WHERE j.ID_EMPRESA <> p.ID_EMPRESA;

-- 2. Estados fuera de la lista de los cuatro conocidos.
--
-- La columna no tiene CHECK y la escribe otro programa. Lo que aparezca aca se
-- ve en la pantalla pero no se puede filtrar: o se agrega a ESTADO_VALIDO y a
-- ESTADOS_JUSTIFICACION de api.ts, o se corrige el dato.
SELECT NVL(j.ESTADO_SOLICITUD, '(null)') AS ESTADO,
       COUNT(*)                          AS FILAS
  FROM JUSTIFICACIONES_AUSENCIA j
 WHERE UPPER(TRIM(NVL(j.ESTADO_SOLICITUD, 'PENDIENTE')))
       NOT IN ('PENDIENTE', 'EN REVISION', 'APROBADA', 'RECHAZADA')
 GROUP BY j.ESTADO_SOLICITUD
 ORDER BY FILAS DESC;

-- 3. Archivos de respaldo que la pantalla no va a poder ofrecer.
--
-- El endpoint devuelve urlArchivo solo si empieza con https://. Lo que aparezca
-- aca sale en la ficha como "adjunto no valido", que es a proposito: esconderlo
-- haria parecer que el profesor no adjunto nada.
SELECT j.ID_JUSTIFICACION, j.URL_ARCHIVO_RESPALDO
  FROM JUSTIFICACIONES_AUSENCIA j
 WHERE j.URL_ARCHIVO_RESPALDO IS NOT NULL
   AND j.URL_ARCHIVO_RESPALDO NOT LIKE 'https://%'
 ORDER BY j.ID_JUSTIFICACION;

-- 4. Ausencias con la fecha de fin anterior al inicio.
--
-- `dias` las muestra como 1 (va con GREATEST) para no ensuciar la grilla con
-- numeros negativos, pero el dato esta mal cargado y hay que corregirlo en la
-- app.
SELECT j.ID_JUSTIFICACION, j.FECHA_AUSENCIA_INICIO, j.FECHA_AUSENCIA_FIN
  FROM JUSTIFICACIONES_AUSENCIA j
 WHERE j.FECHA_AUSENCIA_FIN IS NOT NULL
   AND j.FECHA_AUSENCIA_FIN < j.FECHA_AUSENCIA_INICIO
 ORDER BY j.ID_JUSTIFICACION;
