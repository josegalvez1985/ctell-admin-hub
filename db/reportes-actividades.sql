--------------------------------------------------------------------------------
-- CTELL · REPORTES DE ACTIVIDADES
--
-- Un paquete (PKG_REPORTES_ACTIVIDADES) con el CRUD y la publicacion de los
-- endpoints ORDS. Todo vive dentro del paquete: no hay procedimientos sueltos
-- ni PL/SQL embebido como texto dentro de los handlers.
--
--   1. LISTAR      GET    /reportes-actividades/listar
--   2. PENDIENTES  GET    /reportes-actividades/pendientes
--   3. VINCULOS    GET    /reportes-actividades/vinculos
--   4. OBTENER     GET    /reportes-actividades/obtener/:id/:idEmpresa
--   5. INSERTAR    POST   /reportes-actividades/crear
--   6. ACTUALIZAR  PUT    /reportes-actividades/actualizar/:id
--   7. ELIMINAR    DELETE /reportes-actividades/eliminar/:id/:idEmpresa
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/reportes-actividades/
--
-- Tabla (no la crea ni la altera):
--   REPORTES_ACTIVIDADES  ID_REPORTE, ID_EMPRESA, ID_PROFESOR, ID_INSTITUCION,
--                         FECHA_ACTIVIDAD, ID_ASISTENCIA, DESCRIPCION,
--                         FECHA_CREACION, FECHA_ACTUALIZACION
--
--------------------------------------------------------------------------------
-- UN REPORTE CUELGA DE UNA MARCACION, Y ESO DEFINE TODO EL MODULO
--
-- El DDL trae UNIQUE (ID_ASISTENCIA). No es un detalle de integridad: es lo que
-- dice QUE ES un reporte. No es una nota suelta que alguien escribe cuando se
-- acuerda, es el "que se hizo" de un dia que el profesor YA MARCO. Una
-- marcacion tiene, como mucho, un reporte; un reporte no existe sin marcacion.
--
-- De ahi salen dos decisiones que sostienen el resto:
--
-- 1. EL PROFESOR, LA INSTITUCION Y LA FECHA NO SE MANDAN: SE DERIVAN.
--
--    Los tres son columnas de ASISTENCIAS_PROFESORES. El cliente manda
--    idAsistencia y el paquete los copia de ahi. Aceptarlos del body obligaria
--    a validar que coincidan —y el dia que la validacion se afloje, la base
--    guarda un reporte del profesor A sobre la marcacion de B, o fechado el 3
--    colgado de una marcacion del 10. Es el mismo criterio de "si se puede
--    derivar, se deriva" con el que los totales de una venta no se guardan.
--
--    Se COPIAN a sus columnas (en vez de leerlas siempre por JOIN) porque el
--    DDL las trae con sus indices, y son los que hacen barato filtrar por
--    profesor o por institucion sin tocar ASISTENCIAS_PROFESORES.
--
-- 2. LA FECHA NO SE EDITA. El ACTUALIZAR toca la DESCRIPCION y nada mas.
--    Mover la fecha del reporte sin mover la de su marcacion las desalinea, y
--    la fecha correcta siempre es la de la marcacion. Si un reporte quedo en el
--    dia equivocado, lo que esta mal es la marcacion: se corrige en
--    /asistencias y el reporte se borra y se vuelve a crear sobre la buena.
--
-- La contracara, explicita: NO SE PUEDE REPORTAR UN DIA QUE NO SE MARCO. Es
-- deliberado —si hubo clase, hay marcacion; si falta, se carga a mano desde
-- /asistencias, que para eso tiene el ABM manual—. Un reporte sin marcacion
-- seria una clase que, segun la planilla que se firma, no ocurrio.
--
--------------------------------------------------------------------------------
-- PENDIENTES: LAS MARCACIONES QUE TODAVIA DEBEN SU REPORTE
--
-- Es el endpoint que hace usable el alta, y no se deduce del listado: para
-- saber que dias faltan habria que traer TODAS las marcaciones del periodo y
-- TODOS los reportes y restarlos en el navegador. Esto devuelve directamente la
-- resta —un NOT EXISTS contra REPORTES_ACTIVIDADES— con su `total`, que es el
-- numero que la pantalla muestra arriba ("faltan 7 reportes de agosto").
--
-- Sin el, el alta seria un buscador de asistencias donde la mitad de lo que
-- ofrece ya tiene reporte y responde 409 recien al elegirlo.
--
--------------------------------------------------------------------------------
-- DESCRIPCION: LA COLUMNA ACEPTA 4000, EL ENDPOINT ACEPTA 2000
--
-- No es una regla de negocio: es el techo del transporte. ORDS devuelve el JSON
-- por un parametro tipado STRING y una respuesta grande muere con un 500 que
-- ningun WHEN OTHERS registra, porque el PL/SQL ya termino bien (los tres pisos
-- del mismo 4000, en GUIA-IMPLEMENTACION). Un /obtener con una descripcion de
-- 4000 caracteres —mas bytes aun si trae acentos— es exactamente ese caso.
--
-- Asi que el POST y el PUT rechazan con 400 lo que pase de 2000 caracteres, y
-- el frontend pone el mismo tope en el textarea. Guardar 4000 y no poder
-- devolverlos seria peor: el reporte se cargaria bien y no se abriria nunca mas.
--
-- Y EN EL LISTADO VIAJA RECORTADA A 200 caracteres, por lo mismo multiplicado
-- por las filas de la pagina. La ficha entera sale de /obtener. Ojo con la
-- trampa que ya costo cara en INVENTARIOS: el formulario de edicion TIENE que
-- cargar desde /obtener — guardar el resumen escribiria 200 caracteres encima
-- de los 2000.
--
--------------------------------------------------------------------------------
-- EL MULTIMEDIA NO VIAJA EN LA FICHA
--
-- /obtener devuelve el reporte y su `cantidadMultimedia`, no los archivos: diez
-- URLs de Cloudinary con su pie de foto pesan mas que la descripcion entera y
-- vuelven a chocar contra el mismo techo. La galeria la pide
-- /reportes-multimedia/listar, que pagina.
--
-- ELIMINAR SI LOS BORRA, y en la misma transaccion: la FK de
-- REPORTES_MULTIMEDIA no tiene ON DELETE CASCADE, asi que borrar solo el padre
-- falla con ORA-02292 en cuanto el reporte tenga una foto. Se borran las filas
-- primero. Lo que NO se borra es el archivo en Cloudinary —este paquete no
-- habla con Cloudinary—: la baja se lleva la referencia y el binario queda alla.
--
--------------------------------------------------------------------------------
-- FILTRO POR EMPRESA
--
-- REPORTES_ACTIVIDADES tiene ID_EMPRESA NOT NULL, asi que sus propias consultas
-- la usan directo.
--
-- Pero todo lo que sale de ASISTENCIAS_PROFESORES —/pendientes, /vinculos y la
-- validacion del alta— filtra por LA EMPRESA DEL PROFESOR (p.ID_EMPRESA), no
-- por la de la marcacion. PROFESORES tiene UNIQUE (NUMERO_CI) global: un
-- profesor pertenece a una sola empresa, asi que la suya es la fuente real.
-- Nada en el DDL obliga a que ASISTENCIAS_PROFESORES.ID_EMPRESA coincida, y una
-- marcacion grabada con la empresa equivocada aparecia en el listado de esa
-- empresa con el nombre de un profesor ajeno. Ver la explicacion completa en
-- db/asistencias-profesores.sql.
--
-- Al CREAR, ID_EMPRESA se copia de esa misma fuente: la del profesor.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_REPORTES_ACTIVIDADES AS

  -- Reportes de un periodo. Solo idEmpresa es obligatorio; el resto acota.
  -- `descripcion` viene RECORTADA a 200 caracteres (ver cabecera).
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

  -- Marcaciones del periodo que todavia no tienen reporte. Alimenta el alta y
  -- el contador de pendientes.
  PROCEDURE PENDIENTES (
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_desde          IN  VARCHAR2,
    p_hasta          IN  VARCHAR2,
    p_id_profesor    IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_pagina         IN  VARCHAR2,
    p_tamanio        IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  );

  ----------------------------------------------------------------------------
  -- QUE PROFESOR ESTUVO EN QUE INSTITUCION
  --
  -- Los pares (profesor, institucion) que tienen marcaciones en el periodo, sin
  -- repetir. Es lo que hace que al elegir un profesor el combo de institucion
  -- ofrezca SOLO donde ese profesor estuvo, en vez de las veinte instituciones
  -- de la empresa —diecinueve de las cuales devuelven la pantalla vacia—.
  --
  -- NO SALE DE NINGUNA TABLA DE RELACION: PROFESORES no tiene institucion y no
  -- hay cruce entre las dos. El vinculo es historico y lo escribe la marcacion,
  -- asi que la fuente es ASISTENCIAS_PROFESORES.
  --
  -- Va acotado al periodo por el mismo criterio que `conArticulos` en el
  -- selector de ubicaciones: no ofrecer busquedas que ya se sabe que no
  -- devuelven nada. Un profesor que en agosto no piso el Santa Ana no deberia
  -- tener al Santa Ana en su combo mientras mira agosto.
  ----------------------------------------------------------------------------
  PROCEDURE VINCULOS (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_desde         IN  VARCHAR2,
    p_hasta         IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Una ficha con la DESCRIPCION entera. Es la que tiene que usar el formulario
  -- de edicion, nunca la fila del listado.
  PROCEDURE OBTENER (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  ------------------------------------------------------------------------------
  -- LOS CAMPOS DEL JSON LLEGAN SUELTOS, NO COMO `:body`
  --
  -- ORDS parsea el JSON del body y crea un bind por cada clave de primer nivel:
  -- :idEmpresa, :idAsistencia, :descripcion. `:body` es OTRA cosa —el payload
  -- crudo, como BLOB— y buscarle adentro con JSON_VALUE devuelve NULL en todos
  -- los campos: el paquete compila, el GET y el DELETE andan, y solo el POST
  -- responde 400 "son obligatorios" con el body bien puesto.
  --
  -- Del lado del cliente hay que mandar TODAS las claves aunque vayan en "":
  -- una clave omitida deja el bind sin definir en vez de en NULL.
  ------------------------------------------------------------------------------
  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_asistencia IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Solo la descripcion: profesor, institucion y fecha son de la marcacion.
  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Baja fisica. Se lleva las filas de REPORTES_MULTIMEDIA (no los archivos de
  -- Cloudinary).
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_REPORTES_ACTIVIDADES;
/

CREATE OR REPLACE PACKAGE BODY PKG_REPORTES_ACTIVIDADES AS

  -- Tope del texto que el endpoint acepta guardar y el que viaja en el listado.
  -- Ver "DESCRIPCION" en la cabecera: los dos numeros son del transporte.
  C_MAX_DESCRIPCION CONSTANT PLS_INTEGER := 2000;
  C_RESUMEN         CONSTANT PLS_INTEGER := 200;

  -- 50 y no 200 como en otras tablas: cada fila lleva texto libre, y una pagina
  -- grande vuelve a rozar el bind de ORDS. Ver GUIA-IMPLEMENTACION.
  C_TAMANIO_MAXIMO  CONSTANT PLS_INTEGER := 50;

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
         WHERE NAME = 'reportes-actividades';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'reportes-actividades');
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

    -- FECHA_ACTIVIDAD es DATE y puede traer hora: el rango se cierra con
    -- "< hasta + 1" en vez de "<= hasta", que dejaria afuera el ultimo dia.
    IF l_hasta IS NOT NULL THEN
      l_hasta := l_hasta + 1;
    END IF;

    l_pagina  := GREATEST(NVL(NUMERO(p_pagina), 1), 1);
    l_tamanio := LEAST(GREATEST(NVL(NUMERO(p_tamanio), 20), 1), C_TAMANIO_MAXIMO);
    l_offset  := (l_pagina - 1) * l_tamanio;

    -- El total cuenta las filas que pasan el filtro, no las de la pagina: es lo
    -- que le dice al frontend si queda algo por traer.
    SELECT COUNT(*)
      INTO l_total
      FROM REPORTES_ACTIVIDADES r
      JOIN PROFESORES p ON p.ID_PROFESOR = r.ID_PROFESOR
      LEFT JOIN INSTITUCIONES i ON i.ID_INSTITUCION = r.ID_INSTITUCION
     WHERE r.ID_EMPRESA = l_empresa
       AND (l_desde IS NULL OR r.FECHA_ACTIVIDAD >= l_desde)
       AND (l_hasta IS NULL OR r.FECHA_ACTIVIDAD <  l_hasta)
       AND (l_profesor IS NULL OR r.ID_PROFESOR = l_profesor)
       AND (l_institucion IS NULL OR r.ID_INSTITUCION = l_institucion)
       AND (l_busqueda IS NULL
            OR LOWER(p.NOMBRE || ' ' || p.APELLIDO) LIKE '%' || l_busqueda || '%'
            OR LOWER(i.NOMBRE_INSTITUCION) LIKE '%' || l_busqueda || '%'
            OR LOWER(r.DESCRIPCION) LIKE '%' || l_busqueda || '%');

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta a los 4000 bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY fecha DESC, id DESC RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'                 VALUE r.ID_REPORTE,
                 'idEmpresa'          VALUE r.ID_EMPRESA,
                 'idProfesor'         VALUE r.ID_PROFESOR,
                 -- El nombre viene del JOIN: sin el, el frontend resolveria una
                 -- peticion por fila para pintar la tarjeta.
                 'profesor'           VALUE p.NOMBRE || NVL2(p.APELLIDO, ' ' || p.APELLIDO, ''),
                 'idInstitucion'      VALUE r.ID_INSTITUCION,
                 'institucion'        VALUE i.NOMBRE_INSTITUCION,
                 -- Formato ISO explicito: un DATE crudo sale con el formato NLS
                 -- de la sesion ('20-AGO-24'), que `new Date()` no parsea.
                 'fecha'              VALUE TO_CHAR(r.FECHA_ACTIVIDAD, 'YYYY-MM-DD'),
                 'idAsistencia'       VALUE r.ID_ASISTENCIA,
                 'horaEntrada'        VALUE TO_CHAR(a.HORA_ENTRADA, 'HH24:MI'),
                 'horaSalida'         VALUE TO_CHAR(a.HORA_SALIDA, 'HH24:MI'),
                 -- RECORTADA: la ficha entera sale de /obtener. `truncada` le
                 -- dice a la tarjeta si poner el "seguir leyendo".
                 'descripcion'        VALUE SUBSTR(r.DESCRIPCION, 1, l_resumen),
                 'truncada'           VALUE CASE WHEN LENGTH(r.DESCRIPCION) > l_resumen
                                                 THEN 'S' ELSE 'N' END,
                 'cantidadMultimedia' VALUE (SELECT COUNT(*)
                                               FROM REPORTES_MULTIMEDIA m
                                              WHERE m.ID_REPORTE = r.ID_REPORTE),
                 'fechaCreacion'      VALUE TO_CHAR(r.FECHA_CREACION, 'YYYY-MM-DD"T"HH24:MI:SS'),
                 'fechaActualizacion' VALUE TO_CHAR(r.FECHA_ACTUALIZACION, 'YYYY-MM-DD"T"HH24:MI:SS')
                 RETURNING CLOB
               ) fila,
               r.FECHA_ACTIVIDAD fecha,
               r.ID_REPORTE      id
          FROM REPORTES_ACTIVIDADES r
          JOIN PROFESORES p ON p.ID_PROFESOR = r.ID_PROFESOR
          LEFT JOIN INSTITUCIONES i ON i.ID_INSTITUCION = r.ID_INSTITUCION
          LEFT JOIN ASISTENCIAS_PROFESORES a ON a.ID_ASISTENCIA = r.ID_ASISTENCIA
         WHERE r.ID_EMPRESA = l_empresa
           AND (l_desde IS NULL OR r.FECHA_ACTIVIDAD >= l_desde)
           AND (l_hasta IS NULL OR r.FECHA_ACTIVIDAD <  l_hasta)
           AND (l_profesor IS NULL OR r.ID_PROFESOR = l_profesor)
           AND (l_institucion IS NULL OR r.ID_INSTITUCION = l_institucion)
           AND (l_busqueda IS NULL
                OR LOWER(p.NOMBRE || ' ' || p.APELLIDO) LIKE '%' || l_busqueda || '%'
                OR LOWER(i.NOMBRE_INSTITUCION) LIKE '%' || l_busqueda || '%'
                OR LOWER(r.DESCRIPCION) LIKE '%' || l_busqueda || '%')
         ORDER BY r.FECHA_ACTIVIDAD DESC, r.ID_REPORTE DESC
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
      APEX_DEBUG.ERROR('PKG_REPORTES_ACTIVIDADES.LISTAR: ' || SQLERRM);
      p_resultado := '{"error":"Error al listar los reportes"}';
  END LISTAR;

  ------------------------------------------------------------------------------
  -- PENDIENTES
  --
  -- Marcaciones del periodo sin reporte. El NOT EXISTS usa UX_REPORTES_ASISTENCIA,
  -- que es unico sobre ID_ASISTENCIA: la resta no recorre la tabla.
  ------------------------------------------------------------------------------
  PROCEDURE PENDIENTES (
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_desde          IN  VARCHAR2,
    p_hasta          IN  VARCHAR2,
    p_id_profesor    IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
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

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    IF (VINO(p_desde) AND l_desde IS NULL) OR (VINO(p_hasta) AND l_hasta IS NULL) THEN
      p_status_code := 400;
      p_resultado   := '{"error":"Las fechas deben tener formato YYYY-MM-DD"}';
      RETURN;
    END IF;

    IF l_hasta IS NOT NULL THEN
      l_hasta := l_hasta + 1;
    END IF;

    l_pagina  := GREATEST(NVL(NUMERO(p_pagina), 1), 1);
    l_tamanio := LEAST(GREATEST(NVL(NUMERO(p_tamanio), 30), 1), C_TAMANIO_MAXIMO);
    l_offset  := (l_pagina - 1) * l_tamanio;

    SELECT COUNT(*)
      INTO l_total
      FROM ASISTENCIAS_PROFESORES a
      JOIN PROFESORES p ON p.ID_PROFESOR = a.ID_PROFESOR
     WHERE p.ID_EMPRESA = l_empresa
       AND (l_desde IS NULL OR a.FECHA_ASISTENCIA >= l_desde)
       AND (l_hasta IS NULL OR a.FECHA_ASISTENCIA <  l_hasta)
       AND (l_profesor IS NULL OR a.ID_PROFESOR = l_profesor)
       AND (l_institucion IS NULL OR a.ID_INSTITUCION = l_institucion)
       AND NOT EXISTS (SELECT 1
                         FROM REPORTES_ACTIVIDADES r
                        WHERE r.ID_ASISTENCIA = a.ID_ASISTENCIA);

    SELECT JSON_ARRAYAGG(fila ORDER BY fecha DESC, id DESC RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'idAsistencia'  VALUE a.ID_ASISTENCIA,
                 'idProfesor'    VALUE a.ID_PROFESOR,
                 'profesor'      VALUE p.NOMBRE || NVL2(p.APELLIDO, ' ' || p.APELLIDO, ''),
                 'idInstitucion' VALUE a.ID_INSTITUCION,
                 'institucion'   VALUE i.NOMBRE_INSTITUCION,
                 'fecha'         VALUE TO_CHAR(a.FECHA_ASISTENCIA, 'YYYY-MM-DD'),
                 'horaEntrada'   VALUE TO_CHAR(a.HORA_ENTRADA, 'HH24:MI'),
                 'horaSalida'    VALUE TO_CHAR(a.HORA_SALIDA, 'HH24:MI')
                 RETURNING CLOB
               ) fila,
               a.FECHA_ASISTENCIA fecha,
               a.ID_ASISTENCIA    id
          FROM ASISTENCIAS_PROFESORES a
          JOIN PROFESORES p ON p.ID_PROFESOR = a.ID_PROFESOR
          LEFT JOIN INSTITUCIONES i ON i.ID_INSTITUCION = a.ID_INSTITUCION
         WHERE p.ID_EMPRESA = l_empresa
           AND (l_desde IS NULL OR a.FECHA_ASISTENCIA >= l_desde)
           AND (l_hasta IS NULL OR a.FECHA_ASISTENCIA <  l_hasta)
           AND (l_profesor IS NULL OR a.ID_PROFESOR = l_profesor)
           AND (l_institucion IS NULL OR a.ID_INSTITUCION = l_institucion)
           AND NOT EXISTS (SELECT 1
                             FROM REPORTES_ACTIVIDADES r
                            WHERE r.ID_ASISTENCIA = a.ID_ASISTENCIA)
         ORDER BY a.FECHA_ASISTENCIA DESC, a.ID_ASISTENCIA DESC
         OFFSET l_offset ROWS FETCH NEXT l_tamanio ROWS ONLY
      );

    p_status_code := 200;

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
      APEX_DEBUG.ERROR('PKG_REPORTES_ACTIVIDADES.PENDIENTES: ' || SQLERRM);
      p_resultado := '{"error":"Error al listar las marcaciones pendientes"}';
  END PENDIENTES;

  ------------------------------------------------------------------------------
  -- VINCULOS
  --
  -- Los pares (profesor, institucion) con marcaciones en el periodo.
  --
  -- El DISTINCT va en la subconsulta de adentro, sobre los DOS NUMEROS, y el
  -- JSON se arma afuera. No es estilo: `SELECT DISTINCT` sobre una columna CLOB
  -- —que es lo que devuelve JSON_OBJECT ... RETURNING CLOB— falla con
  -- ORA-00932, porque un CLOB no se puede comparar para deduplicar.
  ------------------------------------------------------------------------------
  PROCEDURE VINCULOS (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_desde         IN  VARCHAR2,
    p_hasta         IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_empresa NUMBER;
    l_desde   DATE;
    l_hasta   DATE;
    l_items   CLOB;
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa := NUMERO(p_id_empresa);
    l_desde   := FECHA(p_desde);
    l_hasta   := FECHA(p_hasta);

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    IF (VINO(p_desde) AND l_desde IS NULL) OR (VINO(p_hasta) AND l_hasta IS NULL) THEN
      p_status_code := 400;
      p_resultado   := '{"error":"Las fechas deben tener formato YYYY-MM-DD"}';
      RETURN;
    END IF;

    IF l_hasta IS NOT NULL THEN
      l_hasta := l_hasta + 1;
    END IF;

    SELECT JSON_ARRAYAGG(fila ORDER BY profesor, institucion RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'idProfesor'    VALUE d.profesor,
                 'idInstitucion' VALUE d.institucion
                 RETURNING CLOB
               ) fila,
               d.profesor,
               d.institucion
          FROM (
            SELECT DISTINCT a.ID_PROFESOR profesor, a.ID_INSTITUCION institucion
              FROM ASISTENCIAS_PROFESORES a
              JOIN PROFESORES p ON p.ID_PROFESOR = a.ID_PROFESOR
             WHERE p.ID_EMPRESA = l_empresa
               AND (l_desde IS NULL OR a.FECHA_ASISTENCIA >= l_desde)
               AND (l_hasta IS NULL OR a.FECHA_ASISTENCIA <  l_hasta)
               AND a.ID_INSTITUCION IS NOT NULL
          ) d
      );

    p_status_code := 200;

    SELECT JSON_OBJECT('items' VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON RETURNING CLOB)
      INTO p_resultado
      FROM DUAL;

  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_REPORTES_ACTIVIDADES.VINCULOS: ' || SQLERRM);
      p_resultado := '{"error":"Error al listar los vinculos"}';
  END VINCULOS;

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
             'id'                 VALUE r.ID_REPORTE,
             'idEmpresa'          VALUE r.ID_EMPRESA,
             'idProfesor'         VALUE r.ID_PROFESOR,
             'profesor'           VALUE p.NOMBRE || NVL2(p.APELLIDO, ' ' || p.APELLIDO, ''),
             'idInstitucion'      VALUE r.ID_INSTITUCION,
             'institucion'        VALUE i.NOMBRE_INSTITUCION,
             'fecha'              VALUE TO_CHAR(r.FECHA_ACTIVIDAD, 'YYYY-MM-DD'),
             'idAsistencia'       VALUE r.ID_ASISTENCIA,
             'horaEntrada'        VALUE TO_CHAR(a.HORA_ENTRADA, 'HH24:MI'),
             'horaSalida'         VALUE TO_CHAR(a.HORA_SALIDA, 'HH24:MI'),
             -- Entera, no recortada: esta es la que edita el formulario.
             'descripcion'        VALUE r.DESCRIPCION,
             'truncada'           VALUE 'N',
             'cantidadMultimedia' VALUE (SELECT COUNT(*)
                                           FROM REPORTES_MULTIMEDIA m
                                          WHERE m.ID_REPORTE = r.ID_REPORTE),
             'fechaCreacion'      VALUE TO_CHAR(r.FECHA_CREACION, 'YYYY-MM-DD"T"HH24:MI:SS'),
             'fechaActualizacion' VALUE TO_CHAR(r.FECHA_ACTUALIZACION, 'YYYY-MM-DD"T"HH24:MI:SS')
             RETURNING CLOB
           )
      INTO p_resultado
      FROM REPORTES_ACTIVIDADES r
      JOIN PROFESORES p ON p.ID_PROFESOR = r.ID_PROFESOR
      LEFT JOIN INSTITUCIONES i ON i.ID_INSTITUCION = r.ID_INSTITUCION
      LEFT JOIN ASISTENCIAS_PROFESORES a ON a.ID_ASISTENCIA = r.ID_ASISTENCIA
     WHERE r.ID_REPORTE = l_id
       AND r.ID_EMPRESA = l_empresa;

    p_status_code := 200;

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_status_code := 404;
      p_resultado   := '{"error":"Reporte no encontrado"}';
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_REPORTES_ACTIVIDADES.OBTENER: ' || SQLERRM);
      p_resultado := '{"error":"Error al obtener el reporte"}';
  END OBTENER;

  ------------------------------------------------------------------------------
  -- INSERTAR
  --
  -- Recibe idAsistencia y nada mas: profesor, institucion, fecha y empresa
  -- salen de la marcacion (ver cabecera). La consulta que los trae es tambien
  -- la que valida que la marcacion sea de esta empresa — si no devuelve fila,
  -- o no existe o es de otra, y las dos cosas se contestan igual (404) para no
  -- confirmar la existencia de datos ajenos.
  ------------------------------------------------------------------------------
  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_asistencia IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_empresa     NUMBER;
    l_asistencia  NUMBER;
    l_profesor    NUMBER;
    l_institucion NUMBER;
    l_fecha       DATE;
    l_descripcion VARCHAR2(4000);
    l_repetido    PLS_INTEGER;
    l_id          NUMBER;
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa     := NUMERO(p_id_empresa);
    l_asistencia  := NUMERO(p_id_asistencia);
    l_descripcion := NULLIF(TRIM(p_descripcion), '');

    IF l_empresa IS NULL OR l_asistencia IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"idEmpresa e idAsistencia son obligatorios"}';
      RETURN;
    END IF;

    IF LENGTH(l_descripcion) > C_MAX_DESCRIPCION THEN
      p_status_code := 400;
      p_resultado   := '{"error":"La descripcion no puede pasar de 2000 caracteres"}';
      RETURN;
    END IF;

    BEGIN
      SELECT a.ID_PROFESOR,
             a.ID_INSTITUCION,
             TRUNC(a.FECHA_ASISTENCIA)
        INTO l_profesor, l_institucion, l_fecha
        FROM ASISTENCIAS_PROFESORES a
        JOIN PROFESORES p ON p.ID_PROFESOR = a.ID_PROFESOR
       WHERE a.ID_ASISTENCIA = l_asistencia
         AND p.ID_EMPRESA = l_empresa;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_status_code := 404;
        p_resultado   := '{"error":"La marcacion no existe o no es de esta empresa"}';
        RETURN;
    END;

    -- Se consulta antes en vez de esperar el DUP_VAL_ON_INDEX para poder
    -- nombrar el caso: la excepcion no dice cual indice se violo y el mensaje
    -- quedaria en "algun dato esta repetido". El DUP_VAL_ON_INDEX se captura
    -- igual, por si dos altas simultaneas pasan las dos esta validacion.
    SELECT COUNT(*)
      INTO l_repetido
      FROM REPORTES_ACTIVIDADES
     WHERE ID_ASISTENCIA = l_asistencia;

    IF l_repetido > 0 THEN
      p_status_code := 409;
      p_resultado   := '{"error":"Esa marcacion ya tiene un reporte cargado"}';
      RETURN;
    END IF;

    INSERT INTO REPORTES_ACTIVIDADES (
      ID_EMPRESA, ID_PROFESOR, ID_INSTITUCION, FECHA_ACTIVIDAD,
      ID_ASISTENCIA, DESCRIPCION, FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_empresa, l_profesor, l_institucion, l_fecha,
      l_asistencia, l_descripcion, SYSTIMESTAMP, SYSTIMESTAMP
    ) RETURNING ID_REPORTE INTO l_id;

    COMMIT;

    p_status_code := 201;
    p_resultado   := '{"ok":true,"id":' || TO_CHAR(l_id) || '}';

  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado   := '{"error":"Esa marcacion ya tiene un reporte cargado"}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_REPORTES_ACTIVIDADES.INSERTAR: ' || SQLERRM);
      p_resultado := '{"error":"Error al crear el reporte"}';
  END INSERTAR;

  ------------------------------------------------------------------------------
  -- ACTUALIZAR
  --
  -- Solo la descripcion. Un campo vacio BORRA la descripcion —el reporte vuelve
  -- a quedar sin texto— porque es el unico campo editable y el cliente siempre
  -- lo manda: con el NVL habitual, vaciar el textarea no tendria efecto y no
  -- habria forma de deshacer un texto pegado por error.
  ------------------------------------------------------------------------------
  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id          NUMBER;
    l_empresa     NUMBER;
    l_descripcion VARCHAR2(4000);
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id          := NUMERO(p_id);
    l_empresa     := NUMERO(p_id_empresa);
    l_descripcion := NULLIF(TRIM(p_descripcion), '');

    IF l_id IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    IF LENGTH(l_descripcion) > C_MAX_DESCRIPCION THEN
      p_status_code := 400;
      p_resultado   := '{"error":"La descripcion no puede pasar de 2000 caracteres"}';
      RETURN;
    END IF;

    UPDATE REPORTES_ACTIVIDADES
       SET DESCRIPCION         = l_descripcion,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_REPORTE = l_id
       AND ID_EMPRESA = l_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado   := '{"error":"Reporte no encontrado"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado   := '{"ok":true}';

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_REPORTES_ACTIVIDADES.ACTUALIZAR: ' || SQLERRM);
      p_resultado := '{"error":"Error al actualizar el reporte"}';
  END ACTUALIZAR;

  ------------------------------------------------------------------------------
  -- ELIMINAR
  --
  -- Baja fisica, con sus archivos. El DELETE de los hijos va acotado por el
  -- mismo id de reporte que ya se valido contra la empresa en el WHERE del
  -- padre: si el padre no era de esta empresa, el borrado del padre no afecta
  -- filas y se hace ROLLBACK sin haber tocado nada.
  ------------------------------------------------------------------------------
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_id       NUMBER;
    l_empresa  NUMBER;
    l_archivos PLS_INTEGER;
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

    -- Los hijos primero: la FK no tiene ON DELETE CASCADE y borrar el padre con
    -- fotos cargadas moriria con ORA-02292.
    DELETE FROM REPORTES_MULTIMEDIA m
     WHERE m.ID_REPORTE = l_id
       AND EXISTS (SELECT 1
                     FROM REPORTES_ACTIVIDADES r
                    WHERE r.ID_REPORTE = m.ID_REPORTE
                      AND r.ID_EMPRESA = l_empresa);

    l_archivos := SQL%ROWCOUNT;

    DELETE FROM REPORTES_ACTIVIDADES
     WHERE ID_REPORTE = l_id
       AND ID_EMPRESA = l_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado   := '{"error":"Reporte no encontrado"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    -- `archivosEliminados` para que la pantalla pueda decir que se llevo: los
    -- binarios siguen en Cloudinary y quien quiera limpiarlos necesita saberlo.
    p_resultado := '{"ok":true,"archivosEliminados":' || TO_CHAR(l_archivos) || '}';

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_REPORTES_ACTIVIDADES.ELIMINAR: ' || SQLERRM);
      p_resultado := '{"error":"Error al eliminar el reporte"}';
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- PUBLICACION DE LOS ENDPOINTS
  --
  -- Cada handler declara SOLO tres parametros: el header `authorization`, el
  -- CLOB de salida y el status code. Los query params (?idEmpresa=, ?desde=) y
  -- los campos del body se vinculan SOLOS al bind del mismo nombre, sin
  -- DEFINE_PARAMETER.
  --
  -- LAS LLAMADAS VAN ESCRITAS UNA POR UNA, CON LOS VALORES LITERALES.
  --
  -- La primera version de este archivo las envolvia en dos helpers
  -- (PARAMETRO/RESPUESTA) para no repetir tres lineas por handler. El paquete
  -- compilaba, y PUBLICAR_ENDPOINTS moria en la PRIMERA llamada con:
  --
  --   ORA-02290: restriccion de control (ORDS_METADATA.REST_PARAMS_SOURCE_TYPE_CK)
  --
  -- sobre un parametro —'HEADER'/'IN'— identico al que los otros cuarenta
  -- modulos del proyecto publican sin problema. Lo unico distinto era pasar el
  -- valor por una variable en lugar de un literal. No se pudo confirmar por que
  -- ORDS lo rechaza (la constraint vive en ORDS_METADATA, al que el workspace
  -- no tiene acceso), y el precio de averiguarlo es alto: un ORA-02290 aborta
  -- PUBLICAR_ENDPOINTS a la mitad y deja el modulo SIN NINGUN endpoint, no solo
  -- sin el que fallo.
  --
  -- Asi que esto se escribe como db/manuales.sql y db/inventarios.sql: verboso
  -- y probado. NO reintroducir los helpers.
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
      p_module_name    => 'reportes-actividades',
      p_base_path      => '/reportes-actividades/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Reportes de actividades de clase por marcacion'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'reportes-actividades',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /reportes-actividades/listar
    --   ?idEmpresa= &desde= &hasta= &idProfesor= &idInstitucion= &busqueda=
    --   &pagina= &tamanio=
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'reportes-actividades', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'reportes-actividades',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_REPORTES_ACTIVIDADES.LISTAR(:authorization, :idEmpresa, :desde, :hasta, :idProfesor, :idInstitucion, :busqueda, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /reportes-actividades/pendientes
    --   ?idEmpresa= &desde= &hasta= &idProfesor= &idInstitucion= &pagina= &tamanio=
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'reportes-actividades', p_pattern => 'pendientes');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'reportes-actividades',
      p_pattern     => 'pendientes',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_REPORTES_ACTIVIDADES.PENDIENTES(:authorization, :idEmpresa, :desde, :hasta, :idProfesor, :idInstitucion, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'pendientes', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'pendientes', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'pendientes', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /reportes-actividades/vinculos?idEmpresa= &desde= &hasta=
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'reportes-actividades', p_pattern => 'vinculos');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'reportes-actividades',
      p_pattern     => 'vinculos',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_REPORTES_ACTIVIDADES.VINCULOS(:authorization, :idEmpresa, :desde, :hasta, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'vinculos', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'vinculos', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'vinculos', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /reportes-actividades/obtener/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'reportes-actividades', p_pattern => 'obtener/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'reportes-actividades',
      p_pattern     => 'obtener/:id/:idEmpresa',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_REPORTES_ACTIVIDADES.OBTENER(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /reportes-actividades/crear
    -- Body: { idEmpresa, idAsistencia, descripcion }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'reportes-actividades', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'reportes-actividades',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_REPORTES_ACTIVIDADES.INSERTAR(:authorization, :idEmpresa, :idAsistencia, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /reportes-actividades/actualizar/:id
    -- Body: { idEmpresa, descripcion }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'reportes-actividades', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'reportes-actividades',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_REPORTES_ACTIVIDADES.ACTUALIZAR(:authorization, :id, :idEmpresa, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /reportes-actividades/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'reportes-actividades', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'reportes-actividades',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_REPORTES_ACTIVIDADES.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-actividades', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_REPORTES_ACTIVIDADES;
/

BEGIN
  PKG_REPORTES_ACTIVIDADES.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- VERIFICACION
--
-- Un paquete INVALID responde 500 sin mensaje: el WHEN OTHERS no captura
-- errores de compilacion. Mirar SIEMPRE la salida de estas dos consultas.
--------------------------------------------------------------------------------
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_REPORTES_ACTIVIDADES';

SELECT LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_REPORTES_ACTIVIDADES'
 ORDER BY LINE;

SELECT m.NAME, t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_MODULES m
  JOIN USER_ORDS_TEMPLATES t ON t.MODULE_ID = m.ID
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
 WHERE m.NAME = 'reportes-actividades'
 ORDER BY t.URI_TEMPLATE, h.METHOD;
