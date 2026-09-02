--------------------------------------------------------------------------------
-- CTELL · NOTIFICACIONES
--
-- Un paquete (PKG_NOTIFICACIONES) con el ABM completo y la publicacion de los
-- endpoints ORDS.
--
--   1. LISTAR      GET    /notificaciones/listar    (?busqueda=&pagina=&tamanio=)
--   2. OBTENER     GET    /notificaciones/obtener/:id/:idEmpresa
--   3. INSERTAR    POST   /notificaciones/crear
--   4. ACTUALIZAR  PUT    /notificaciones/actualizar/:id
--   5. ELIMINAR    DELETE /notificaciones/eliminar/:id/:idEmpresa
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/notificaciones/
--
-- Tablas (no las crea ni las altera; el DDL se administra aparte):
--   NOTIFICACIONES             ID_NOTIFICACION, ID_EMPRESA, TITULO, DESCRIPCION,
--                              FECHA_NOTIFICACION, FECHA_CREACION,
--                              FECHA_ACTUALIZACION
--   NOTIFICACIONES_PROFESORES  ID_NOTIFICACION_PROFESOR, ID_NOTIFICACION,
--                              ID_PROFESOR, LEIDO, FECHA_LECTURA, FECHA_CREACION
--
--------------------------------------------------------------------------------
-- ES CABECERA Y DETALLE, COMO UNA FACTURA
--
-- Una notificacion sin destinatarios no es un aviso a medio cargar: es un
-- registro que no le llego a nadie. Por eso los profesores viajan en el MISMO
-- request que la cabecera —un array `destinatarios` en el body— y se guardan en
-- una sola transaccion, igual que db/facturas-compras.sql.
--
-- Sin eso, un corte de red entre "guardar la cabecera" y "guardar el primer
-- destinatario" dejaria un aviso que la pantalla muestra como enviado y que
-- ningun profesor tiene.
--
--------------------------------------------------------------------------------
-- ACTUALIZAR REEMPLAZA LOS DESTINATARIOS ENTEROS, Y ESO BORRA LAS LECTURAS
--
-- Igual que el detalle de una factura: se borran las filas de
-- NOTIFICACIONES_PROFESORES y se reinsertan. Comparar una por una —quien sigue,
-- quien se fue, quien es nuevo— es mucho mas codigo para el mismo resultado.
--
-- PERO ACA EL DETALLE TIENE ESTADO: LEIDO y FECHA_LECTURA. Reemplazarlo pone en
-- 'N' a quien ya la habia leido, y esa marca no se puede recuperar.
--
-- Se hace igual, con dos mitigaciones:
--
--   1. `destinatarios` es OPCIONAL en el PUT. Si no viene, las filas quedan
--      intactas: corregir un typo del titulo NO toca las lecturas.
--   2. Cuando SI viene, se PRESERVA la lectura de quien siga en la lista nueva.
--      Ver RESULTADO_DESTINATARIOS: se leen las marcas antes de borrar y se
--      reinsertan con su LEIDO y FECHA_LECTURA originales.
--
-- Sin la segunda, agregar un destinatario a un aviso ya leido por diez personas
-- reiniciaria las diez.
--
--------------------------------------------------------------------------------
-- EL DETALLE NO SE PUBLICA COMO ENDPOINT PROPIO
--
-- NOTIFICACIONES_PROFESORES no tiene su archivo db/ ni su pantalla, y es la
-- excepcion a la regla de "una tabla, un archivo". No es una entidad que alguien
-- administre: es el detalle de la notificacion, se crea con ella y se lee con
-- ella. Un ABM propio permitiria agregarle un destinatario a un aviso sin pasar
-- por el aviso.
--
-- Quien SI la va a escribir por su cuenta es el profesor al marcar leido, desde
-- la app. Ese endpoint todavia no existe: LEIDO y FECHA_LECTURA se leen y se
-- muestran, pero hoy nadie los pone en 'S'. Cuando exista, va a resolver el
-- profesor por el ID_USUARIO del token —no por un idProfesor del body, que
-- dejaria marcar como leida la notificacion de otro.
--
--------------------------------------------------------------------------------
-- LA DESCRIPCION VIAJA RECORTADA EN EL LISTADO
--
-- Mismo problema que db/inventarios.sql con OBSERVACIONES: ORDS devuelve el JSON
-- por un parametro tipado STRING con techo de 4000 BYTES, y 1000 caracteres de
-- DESCRIPCION por 20 filas lo pasan largo. El listado manda
-- `descripcionResumen` con los primeros 150.
--
-- EL FORMULARIO DE EDICION TIENE QUE USAR /obtener, que trae el texto entero.
-- Guardar lo del listado escribiria el resumen encima del mensaje completo.
--
--------------------------------------------------------------------------------
-- LEIDO ES 'S'/'N', NO 'A'/'I'
--
-- Rompe la convencion del proyecto a proposito: el DDL declara
-- DEFAULT 'N' y la columna no es un estado de la fila —la fila no se da de baja—
-- sino la respuesta a "¿la leyo?". Es el mismo criterio de IND_BANCO en
-- CANALES_PAGOS ('S'/'N') y de ENTRADA_OFFLINE en ASISTENCIAS_PROFESORES.
--
-- No hay helper `esActivo` que aplique: del lado del frontend se compara contra
-- 'S' directamente.
--
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_NOTIFICACIONES AS

  -- Paginado. `busqueda` filtra por titulo y descripcion.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Una notificacion con su DESCRIPCION completa y sus destinatarios.
  PROCEDURE OBTENER (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- p_destinatarios es un array JSON de ids: [1, 5, 12]. OBLIGATORIO y no
  -- vacio: un aviso sin destinatarios no le llega a nadie.
  PROCEDURE INSERTAR (
    p_authorization      IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_titulo             IN  VARCHAR2,
    p_descripcion        IN  VARCHAR2,
    p_fecha_notificacion IN  VARCHAR2,
    p_destinatarios      IN  CLOB,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  );

  -- p_destinatarios OPCIONAL: ausente deja los que ya estaban, con sus lecturas.
  PROCEDURE ACTUALIZAR (
    p_authorization      IN  VARCHAR2,
    p_id                 IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_titulo             IN  VARCHAR2,
    p_descripcion        IN  VARCHAR2,
    p_fecha_notificacion IN  VARCHAR2,
    p_destinatarios      IN  CLOB,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  );

  -- p_id_empresa es OBLIGATORIO: acota el borrado a la empresa de la sesion.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /notificaciones/ con sus 5 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_NOTIFICACIONES;
/

CREATE OR REPLACE PACKAGE BODY PKG_NOTIFICACIONES AS

  -- Cuantos caracteres de DESCRIPCION viajan en el listado. Ver el encabezado.
  C_LARGO_RESUMEN  CONSTANT PLS_INTEGER := 150;
  C_TAMANIO_DEFECTO CONSTANT PLS_INTEGER := 20;
  -- Techo de pagina: 20 filas x 150 caracteres de resumen entran holgadas en los
  -- 4000 bytes del bind. Subirlo sin bajar C_LARGO_RESUMEN devuelve un 500 mudo.
  C_TAMANIO_MAXIMO CONSTANT PLS_INTEGER := 50;

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
        SELECT COUNT(*)
          INTO l_existe
          FROM USER_ORDS_MODULES
         WHERE NAME = 'notificaciones';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'notificaciones');
        COMMIT;
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
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
  -- Privado: texto ISO -> TIMESTAMP.
  --
  -- Acepta 'YYYY-MM-DD"T"HH24:MI:SS', el mismo sin segundos —un
  -- <input type="datetime-local"> los omite cuando estan en cero— y la fecha
  -- sola, que vale medianoche. Devuelve NULL si no matchea ninguno, y el
  -- llamador decide si eso es un error o un "dejalo como estaba".
  --
  -- Es una funcion privada del BODY: NO se puede llamar desde una sentencia SQL
  -- (PLS-00231). Calcular en una variable PL/SQL y usar la variable.
  ------------------------------------------------------------------------------
  FUNCTION A_TIMESTAMP (p_texto IN VARCHAR2) RETURN TIMESTAMP IS
    l_texto VARCHAR2(40) := TRIM(p_texto);
  BEGIN
    IF l_texto IS NULL THEN
      RETURN NULL;
    END IF;

    BEGIN
      RETURN TO_TIMESTAMP(l_texto, 'YYYY-MM-DD"T"HH24:MI:SS');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
      RETURN TO_TIMESTAMP(l_texto, 'YYYY-MM-DD"T"HH24:MI');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
      RETURN TO_TIMESTAMP(l_texto, 'YYYY-MM-DD');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    RETURN NULL;
  END A_TIMESTAMP;

  ------------------------------------------------------------------------------
  -- Privado: guarda los destinatarios de una notificacion.
  --
  -- NO HACE COMMIT NI ROLLBACK y NO LANZA: devuelve el error en p_error para que
  -- el llamador pueda deshacer TAMBIEN la cabecera. Es el mismo contrato que
  -- GUARDAR_DETALLE en db/facturas-compras.sql.
  --
  -- PRESERVA LAS LECTURAS de quien ya estaba en la lista: se leen las marcas
  -- antes de borrar y se reinsertan. Sin esto, agregar un destinatario a un
  -- aviso ya leido por diez personas reiniciaria las diez.
  ------------------------------------------------------------------------------
  PROCEDURE GUARDAR_DESTINATARIOS (
    p_id_notificacion IN  NUMBER,
    p_id_empresa      IN  NUMBER,
    p_destinatarios   IN  CLOB,
    p_cantidad        OUT PLS_INTEGER,
    p_error           OUT VARCHAR2
  ) IS
    TYPE t_lectura IS RECORD (leido VARCHAR2(1), fecha TIMESTAMP);
    TYPE t_lecturas IS TABLE OF t_lectura INDEX BY PLS_INTEGER;
    l_previas t_lecturas;
    l_leido   VARCHAR2(1);
    l_fecha   TIMESTAMP;
    l_existe  PLS_INTEGER;
  BEGIN
    p_cantidad := 0;
    p_error    := NULL;

    -- Las marcas actuales, para no perderlas al reemplazar.
    FOR r IN (SELECT ID_PROFESOR, LEIDO, FECHA_LECTURA
                FROM NOTIFICACIONES_PROFESORES
               WHERE ID_NOTIFICACION = p_id_notificacion) LOOP
      l_previas(r.ID_PROFESOR).leido := r.LEIDO;
      l_previas(r.ID_PROFESOR).fecha := r.FECHA_LECTURA;
    END LOOP;

    DELETE FROM NOTIFICACIONES_PROFESORES
     WHERE ID_NOTIFICACION = p_id_notificacion;

    -- FOR ORDINALITY y no ROWNUM: da la posicion REAL dentro del array, que es
    -- la que el usuario ve en el formulario. ROWNUM se asigna al leer y puede no
    -- coincidir con el orden del JSON, asi que un mensaje de error apuntaria al
    -- destinatario equivocado.
    FOR d IN (
      SELECT j.nro, j.id_profesor
        FROM JSON_TABLE(
               p_destinatarios, '$[*]'
               COLUMNS (
                 nro         FOR ORDINALITY,
                 -- PATH '$' porque el array es de numeros pelados —[1, 5, 12]—
                 -- y no de objetos.
                 id_profesor NUMBER PATH '$'
               )
             ) j
    ) LOOP
      IF d.id_profesor IS NULL THEN
        p_error := 'El destinatario ' || d.nro || ' no tiene un profesor valido';
        RETURN;
      END IF;

      -- EL PROFESOR TIENE QUE SER DE LA EMPRESA. Sin este chequeo, mandando un
      -- id ajeno se le cargaria una notificacion a un profesor de otra empresa
      -- —la FK lo aceptaria, porque solo valida que el profesor exista.
      SELECT COUNT(*)
        INTO l_existe
        FROM PROFESORES
       WHERE ID_PROFESOR = d.id_profesor
         AND ID_EMPRESA  = p_id_empresa;

      IF l_existe = 0 THEN
        p_error := 'El destinatario ' || d.nro || ' no pertenece a esta empresa';
        RETURN;
      END IF;

      IF l_previas.EXISTS(d.id_profesor) THEN
        l_leido := l_previas(d.id_profesor).leido;
        l_fecha := l_previas(d.id_profesor).fecha;
      ELSE
        l_leido := 'N';
        l_fecha := NULL;
      END IF;

      BEGIN
        INSERT INTO NOTIFICACIONES_PROFESORES (
          ID_NOTIFICACION, ID_PROFESOR, LEIDO, FECHA_LECTURA
        ) VALUES (
          p_id_notificacion, d.id_profesor, NVL(l_leido, 'N'), l_fecha
        );
        p_cantidad := p_cantidad + 1;
      EXCEPTION
        -- El UNIQUE (ID_NOTIFICACION, ID_PROFESOR) del DDL: el mismo profesor
        -- repetido en el array. Se ignora en vez de fallar — mandar dos veces al
        -- mismo destinatario es un descuido del formulario, no un error que
        -- valga la pena devolver.
        WHEN DUP_VAL_ON_INDEX THEN NULL;
      END;
    END LOOP;

    IF p_cantidad = 0 THEN
      p_error := 'La notificacion necesita al menos un destinatario';
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      -- Un JSON mal formado cae aca. Se devuelve como error de negocio y no se
      -- relanza: el llamador tiene que poder hacer ROLLBACK de la cabecera.
      p_error := 'No se pudieron guardar los destinatarios: ' || SQLERRM;
  END GUARDAR_DESTINATARIOS;

  ------------------------------------------------------------------------------
  -- LISTAR
  ------------------------------------------------------------------------------
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_empresa  NUMBER;
    l_busqueda VARCHAR2(200);
    l_pagina   PLS_INTEGER;
    l_tamanio  PLS_INTEGER;
    l_desplaza PLS_INTEGER;
    l_total    NUMBER;
    l_items    CLOB;
    -- Copia local de la constante del paquete: en el SELECT entra como bind, y
    -- con una variable local no hay dudas de que el motor la vincula.
    l_resumen  PLS_INTEGER := C_LARGO_RESUMEN;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_busqueda := LOWER(NULLIF(TRIM(p_busqueda), ''));

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    l_pagina  := GREATEST(NVL(TO_NUMBER(NULLIF(p_pagina, '')), 1), 1);
    l_tamanio := LEAST(NVL(TO_NUMBER(NULLIF(p_tamanio, '')), C_TAMANIO_DEFECTO),
                       C_TAMANIO_MAXIMO);
    l_desplaza := (l_pagina - 1) * l_tamanio;

    -- EL COUNT REPITE EXACTAMENTE EL MISMO WHERE que la consulta de abajo. Si
    -- filtran distinto, el total dice una cosa y las filas otra, y el paginador
    -- de la pantalla ofrece paginas vacias.
    SELECT COUNT(*)
      INTO l_total
      FROM NOTIFICACIONES n
     WHERE n.ID_EMPRESA = l_empresa
       AND (l_busqueda IS NULL
            OR LOWER(n.TITULO) LIKE '%' || l_busqueda || '%'
            OR LOWER(n.DESCRIPCION) LIKE '%' || l_busqueda || '%');

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden_fecha DESC, orden_id DESC RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'          VALUE n.ID_NOTIFICACION,
                 'idEmpresa'   VALUE n.ID_EMPRESA,
                 'titulo'      VALUE n.TITULO,
                 -- RECORTADA: el texto entero se pide con /obtener. Mandarla
                 -- completa revienta el bind de ORDS — ver el encabezado.
                 'descripcionResumen' VALUE SUBSTR(n.DESCRIPCION, 1, l_resumen),
                 'fechaNotificacion'  VALUE TO_CHAR(n.FECHA_NOTIFICACION,
                                                    'YYYY-MM-DD"T"HH24:MI:SS'),
                 'fechaCreacion'      VALUE TO_CHAR(n.FECHA_CREACION,
                                                    'YYYY-MM-DD"T"HH24:MI:SS'),
                 -- A CUANTOS SE LES MANDO Y CUANTOS LA LEYERON. Se derivan, no
                 -- se guardan: una columna CANTIDAD_DESTINATARIOS quedaria
                 -- desincronizada el dia que alguien toque el detalle a mano.
                 -- Es el mismo criterio que los totales de una factura.
                 'destinatarios' VALUE (SELECT COUNT(*)
                                          FROM NOTIFICACIONES_PROFESORES np
                                         WHERE np.ID_NOTIFICACION = n.ID_NOTIFICACION),
                 'leidos'        VALUE (SELECT COUNT(*)
                                          FROM NOTIFICACIONES_PROFESORES np
                                         WHERE np.ID_NOTIFICACION = n.ID_NOTIFICACION
                                           AND UPPER(TRIM(np.LEIDO)) = 'S')
                 RETURNING CLOB
               ) AS fila,
               n.FECHA_NOTIFICACION AS orden_fecha,
               n.ID_NOTIFICACION    AS orden_id
          FROM NOTIFICACIONES n
         WHERE n.ID_EMPRESA = l_empresa
           -- IDENTICO AL DEL COUNT DE ARRIBA.
           AND (l_busqueda IS NULL
                OR LOWER(n.TITULO) LIKE '%' || l_busqueda || '%'
                OR LOWER(n.DESCRIPCION) LIKE '%' || l_busqueda || '%')
         -- EL ORDER BY VA ACA, en la subconsulta, ademas de en el
         -- JSON_ARRAYAGG: es el que decide QUE filas entran en la pagina. Sin
         -- el, OFFSET/FETCH recorta en un orden que Oracle no garantiza y la
         -- misma fila puede aparecer en dos paginas.
         ORDER BY n.FECHA_NOTIFICACION DESC, n.ID_NOTIFICACION DESC
         OFFSET l_desplaza ROWS FETCH NEXT l_tamanio ROWS ONLY
      );

    p_status_code := 200;
    -- SELECT ... INTO y no una asignacion directa: `RETURNING CLOB` no se acepta
    -- en una expresion PL/SQL suelta (PLS-00684).
    --
    -- NVL sobre l_items: JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un
    -- array vacio, y el frontend reventaria al iterar "items":null.
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
      APEX_DEBUG.ERROR('PKG_NOTIFICACIONES.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las notificaciones"}';
  END LISTAR;

  ------------------------------------------------------------------------------
  -- OBTENER
  --
  -- La DESCRIPCION entera y la lista de destinatarios con su estado de lectura.
  -- Es lo que tiene que cargar el formulario de edicion.
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
    l_lista   CLOB;
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

    SELECT COUNT(*)
      INTO l_existe
      FROM NOTIFICACIONES
     WHERE ID_NOTIFICACION = l_id AND ID_EMPRESA = l_empresa;

    IF l_existe = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La notificacion no existe"}';
      RETURN;
    END IF;

    -- Los destinatarios, con el nombre del profesor: sin el, la pantalla
    -- tendria que traer el catalogo entero para poder leer la lista.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden RETURNING CLOB)
      INTO l_lista
      FROM (
        SELECT JSON_OBJECT(
                 'idProfesor'   VALUE np.ID_PROFESOR,
                 'profesor'     VALUE p.NOMBRE || ' ' || p.APELLIDO,
                 'numeroCi'     VALUE p.NUMERO_CI,
                 -- 'S'/'N' sin traducir, como IND_BANCO. Ver el encabezado.
                 'leido'        VALUE CASE WHEN UPPER(TRIM(np.LEIDO)) = 'S'
                                           THEN 'S' ELSE 'N' END,
                 'fechaLectura' VALUE TO_CHAR(np.FECHA_LECTURA,
                                              'YYYY-MM-DD"T"HH24:MI:SS')
                 RETURNING CLOB
               ) AS fila,
               p.APELLIDO || ' ' || p.NOMBRE AS orden
          FROM NOTIFICACIONES_PROFESORES np
          -- LEFT: un profesor borrado no puede hacer DESAPARECER al
          -- destinatario de la lista. La FK deberia impedirlo, pero si algun dia
          -- se agrega un ON DELETE, la fila se veria igual.
          LEFT JOIN PROFESORES p ON p.ID_PROFESOR = np.ID_PROFESOR
         WHERE np.ID_NOTIFICACION = l_id
      );

    p_status_code := 200;
    SELECT JSON_OBJECT(
             'id'          VALUE n.ID_NOTIFICACION,
             'idEmpresa'   VALUE n.ID_EMPRESA,
             'titulo'      VALUE n.TITULO,
             -- ENTERA, a diferencia del listado.
             'descripcion' VALUE n.DESCRIPCION,
             'fechaNotificacion' VALUE TO_CHAR(n.FECHA_NOTIFICACION,
                                               'YYYY-MM-DD"T"HH24:MI:SS'),
             'fechaCreacion'     VALUE TO_CHAR(n.FECHA_CREACION,
                                               'YYYY-MM-DD"T"HH24:MI:SS'),
             'destinatarios' VALUE NVL(l_lista, TO_CLOB('[]')) FORMAT JSON
             RETURNING CLOB
           )
      INTO p_resultado
      FROM NOTIFICACIONES n
     WHERE n.ID_NOTIFICACION = l_id AND n.ID_EMPRESA = l_empresa;
  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_NOTIFICACIONES.OBTENER: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al obtener la notificacion"}';
  END OBTENER;

  ------------------------------------------------------------------------------
  -- INSERTAR
  --
  -- La cabecera y los destinatarios en UNA transaccion: sin COMMIT entre medio,
  -- y ROLLBACK si el detalle falla. Ver el encabezado.
  ------------------------------------------------------------------------------
  PROCEDURE INSERTAR (
    p_authorization      IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_titulo             IN  VARCHAR2,
    p_descripcion        IN  VARCHAR2,
    p_fecha_notificacion IN  VARCHAR2,
    p_destinatarios      IN  CLOB,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_empresa     NUMBER;
    l_titulo      VARCHAR2(100);
    l_descripcion VARCHAR2(1000);
    l_fecha       TIMESTAMP;
    l_id          NUMBER;
    l_cantidad    PLS_INTEGER;
    l_error       VARCHAR2(500);
    l_existe      PLS_INTEGER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa     := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_titulo      := NULLIF(TRIM(p_titulo), '');
    l_descripcion := NULLIF(TRIM(p_descripcion), '');

    IF l_empresa IS NULL OR l_titulo IS NULL OR l_descripcion IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, titulo y descripcion son obligatorios"}';
      RETURN;
    END IF;

    SELECT COUNT(*) INTO l_existe FROM EMPRESAS WHERE ID_EMPRESA = l_empresa;
    IF l_existe = 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La empresa no existe"}';
      RETURN;
    END IF;

    -- La funcion privada se llama ACA, en una variable, y no dentro del INSERT:
    -- un helper del body no se puede invocar desde una sentencia SQL
    -- (PLS-00231).
    l_fecha := A_TIMESTAMP(p_fecha_notificacion);

    INSERT INTO NOTIFICACIONES (
      ID_EMPRESA, TITULO, DESCRIPCION, FECHA_NOTIFICACION
    ) VALUES (
      l_empresa, l_titulo, l_descripcion,
      -- Vacia = ahora: el aviso se manda en el momento de cargarlo, que es el
      -- caso normal. La fecha explicita queda para registrar uno ya comunicado.
      NVL(l_fecha, SYSTIMESTAMP)
    ) RETURNING ID_NOTIFICACION INTO l_id;

    GUARDAR_DESTINATARIOS(l_id, l_empresa, p_destinatarios, l_cantidad, l_error);

    IF l_error IS NOT NULL THEN
      ROLLBACK;  -- deshace TAMBIEN la cabecera
      p_status_code := 400;
      p_resultado := JSON_OBJECT('error' VALUE l_error);
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'destinatarios' VALUE l_cantidad,
                               'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_NOTIFICACIONES.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al crear la notificacion"}';
  END INSERTAR;

  ------------------------------------------------------------------------------
  -- ACTUALIZAR
  --
  -- Un campo ausente CONSERVA su valor —el criterio del resto del proyecto, al
  -- reves que db/inventarios.sql—, y eso incluye a los destinatarios: sin el
  -- array, las lecturas quedan intactas.
  ------------------------------------------------------------------------------
  PROCEDURE ACTUALIZAR (
    p_authorization      IN  VARCHAR2,
    p_id                 IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_titulo             IN  VARCHAR2,
    p_descripcion        IN  VARCHAR2,
    p_fecha_notificacion IN  VARCHAR2,
    p_destinatarios      IN  CLOB,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_id       NUMBER;
    l_empresa  NUMBER;
    l_fecha    TIMESTAMP;
    l_cantidad PLS_INTEGER;
    l_error    VARCHAR2(500);
    l_existe   PLS_INTEGER;
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

    SELECT COUNT(*)
      INTO l_existe
      FROM NOTIFICACIONES
     WHERE ID_NOTIFICACION = l_id AND ID_EMPRESA = l_empresa;

    IF l_existe = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La notificacion no existe"}';
      RETURN;
    END IF;

    l_fecha := A_TIMESTAMP(p_fecha_notificacion);

    UPDATE NOTIFICACIONES
       SET TITULO              = NVL(NULLIF(TRIM(p_titulo), ''), TITULO),
           DESCRIPCION         = NVL(NULLIF(TRIM(p_descripcion), ''), DESCRIPCION),
           FECHA_NOTIFICACION  = NVL(l_fecha, FECHA_NOTIFICACION),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_NOTIFICACION = l_id
       AND ID_EMPRESA      = l_empresa;

    -- SOLO SI VINO. Un PUT que corrige el titulo no toca los destinatarios ni
    -- sus lecturas — ver el encabezado.
    IF p_destinatarios IS NOT NULL AND DBMS_LOB.GETLENGTH(p_destinatarios) > 0 THEN
      GUARDAR_DESTINATARIOS(l_id, l_empresa, p_destinatarios, l_cantidad, l_error);

      IF l_error IS NOT NULL THEN
        ROLLBACK;  -- deshace TAMBIEN el UPDATE de la cabecera
        p_status_code := 400;
        p_resultado := JSON_OBJECT('error' VALUE l_error);
        RETURN;
      END IF;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_NOTIFICACIONES.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al actualizar la notificacion"}';
  END ACTUALIZAR;

  ------------------------------------------------------------------------------
  -- ELIMINAR
  --
  -- Detalle primero: el DDL no declara ON DELETE CASCADE y al reves da
  -- ORA-02292.
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

    -- El subselect acota por empresa: sin eso, mandar el id de una notificacion
    -- ajena le borraria los destinatarios aunque el DELETE de la cabecera no
    -- hiciera nada.
    DELETE FROM NOTIFICACIONES_PROFESORES
     WHERE ID_NOTIFICACION IN (
             SELECT ID_NOTIFICACION FROM NOTIFICACIONES
              WHERE ID_NOTIFICACION = l_id AND ID_EMPRESA = l_empresa
           );

    DELETE FROM NOTIFICACIONES
     WHERE ID_NOTIFICACION = l_id AND ID_EMPRESA = l_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La notificacion no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_NOTIFICACIONES.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al eliminar la notificacion"}';
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- PUBLICAR_ENDPOINTS
  --
  -- Cada handler es una sola linea: invoca al procedimiento del paquete pasando
  -- los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un parametro
  -- de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin esto, toda
  -- peticion cross-origin a /notificaciones/* la rechaza ORDS antes de llegar a
  -- cualquiera de los handlers. Ver la explicacion en db/auth.sql.
  --
  -- EL BODY NO SE LEE CON :body. ORDS crea un bind por cada clave de primer
  -- nivel del JSON (:idEmpresa, :titulo, :destinatarios), que se vinculan solos
  -- sin DEFINE_PARAMETER. `destinatarios` llega como el texto del array.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'notificaciones',
      p_base_path      => '/notificaciones/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Notificaciones a profesores, por empresa'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'notificaciones',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /notificaciones/listar?idEmpresa=&busqueda=&pagina=&tamanio=
    --
    -- Los query params no se declaran con DEFINE_PARAMETER: se vinculan solos al
    -- bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'notificaciones', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'notificaciones',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_NOTIFICACIONES.LISTAR(:authorization, :idEmpresa, :busqueda, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /notificaciones/obtener/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'notificaciones',
                         p_pattern => 'obtener/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'notificaciones',
      p_pattern     => 'obtener/:id/:idEmpresa',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_NOTIFICACIONES.OBTENER(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /notificaciones/crear
    -- Body: { idEmpresa, titulo, descripcion, fechaNotificacion?, destinatarios }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'notificaciones', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'notificaciones',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_NOTIFICACIONES.INSERTAR(:authorization, :idEmpresa, :titulo, :descripcion, :fechaNotificacion, :destinatarios, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /notificaciones/actualizar/:id
    -- Body: { idEmpresa, titulo?, descripcion?, fechaNotificacion?,
    --         destinatarios? }   (ausentes = no cambian)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'notificaciones',
                         p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'notificaciones',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_NOTIFICACIONES.ACTUALIZAR(:authorization, :id, :idEmpresa, :titulo, :descripcion, :fechaNotificacion, :destinatarios, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /notificaciones/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'notificaciones',
                         p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'notificaciones',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_NOTIFICACIONES.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'notificaciones', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_NOTIFICACIONES;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_NOTIFICACIONES.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--
-- MIRA LA SALIDA. Un paquete INVALID da un 500 mudo: el WHEN OTHERS no captura
-- errores de compilacion.
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_NOTIFICACIONES'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_NOTIFICACIONES'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'notificaciones';

SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'notificaciones'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- Las notificaciones con su conteo de destinatarios y lecturas.
SELECT n.ID_NOTIFICACION, e.NOMBRE_EMPRESA, n.TITULO,
       TO_CHAR(n.FECHA_NOTIFICACION, 'YYYY-MM-DD HH24:MI') AS FECHA,
       (SELECT COUNT(*) FROM NOTIFICACIONES_PROFESORES np
         WHERE np.ID_NOTIFICACION = n.ID_NOTIFICACION) AS DESTINATARIOS,
       (SELECT COUNT(*) FROM NOTIFICACIONES_PROFESORES np
         WHERE np.ID_NOTIFICACION = n.ID_NOTIFICACION
           AND UPPER(TRIM(np.LEIDO)) = 'S') AS LEIDOS
  FROM NOTIFICACIONES n
  JOIN EMPRESAS       e ON e.ID_EMPRESA = n.ID_EMPRESA
 ORDER BY n.FECHA_NOTIFICACION DESC;
