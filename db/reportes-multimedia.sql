--------------------------------------------------------------------------------
-- CTELL · MULTIMEDIA DE LOS REPORTES DE ACTIVIDADES
--
-- Un paquete (PKG_REPORTES_MULTIMEDIA) con el CRUD de los archivos que cuelgan
-- de un reporte, y la publicacion de los endpoints ORDS.
--
--   1. LISTAR      GET    /reportes-multimedia/listar
--   2. INSERTAR    POST   /reportes-multimedia/crear
--   3. ACTUALIZAR  PUT    /reportes-multimedia/actualizar/:id
--   4. ELIMINAR    DELETE /reportes-multimedia/eliminar/:id/:idEmpresa
--
-- REQUIERE db/auth.sql y db/reportes-actividades.sql ejecutados antes.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/reportes-multimedia/
--
-- Tabla (no la crea ni la altera):
--   REPORTES_MULTIMEDIA  ID_MULTIMEDIA, ID_REPORTE, TIPO_ARCHIVO,
--                        DESCRIPCION_TEXTO, URL_ARCHIVO, NOMBRE_ARCHIVO,
--                        TAMANIO_BYTES, FECHA_CREACION
--
--------------------------------------------------------------------------------
-- ACA NO SE GUARDA EL BINARIO: SE GUARDA LA URL
--
-- Es la diferencia con los otros archivos del proyecto —la foto del profesor,
-- el logo de la empresa, el PDF de un manual—, que viven como BLOB en su tabla
-- y salen por un endpoint `source_type_media`. Estos no: el archivo lo sube el
-- navegador DIRECTO A CLOUDINARY y aca queda su URL.
--
-- Lo que eso compra: un video de 80 MB nunca pasa por ORDS, no hay que subirlo
-- dos veces, y las miniaturas las genera Cloudinary transformando la URL. Lo
-- que cuesta, y hay que tenerlo presente:
--
--   · BORRAR LA FILA NO BORRA EL ARCHIVO. Este paquete no habla con Cloudinary
--     —hacerlo necesitaria la api_secret, que no puede vivir en un frontend
--     estatico—. El binario queda alla, huerfano. Limpiarlos es una tarea
--     aparte contra la consola de Cloudinary.
--
--   · LA URL ES DATO DE ENTRADA, NO ALGO QUE ESTE PAQUETE FABRIQUE. Y la
--     pantalla la mete en un <a href> y en un <img src>. Por eso se valida que
--     empiece con https://: sin esa comprobacion, un POST con
--     "javascript:..." deja guardado un enlace que ejecuta script en el
--     navegador del que abra la galeria. No alcanza con que el formulario no lo
--     permita, el endpoint esta abierto a cualquiera con sesion.
--
--   · NO SE VALIDA QUE LA URL SEA DE CLOUDINARY. Se penso y se descarto: ataria
--     el modulo a un proveedor en el peor lugar posible —una validacion que hay
--     que recordar aflojar el dia que se migre— y no agrega seguridad real
--     sobre exigir https.
--
--------------------------------------------------------------------------------
-- DESCRIPCION_TEXTO: LA COLUMNA ACEPTA 1000, EL ENDPOINT ACEPTA 200
--
-- Es un pie de foto, y viaja ENTERO en la galeria. Si se aceptaran los 1000 de
-- la columna, veinte fotos con su pie pasarian el techo del bind de ORDS y la
-- galeria devolveria un 500 sin mensaje.
--
-- El camino alternativo —guardar 1000 y recortar en el listado— es el que sigue
-- INVENTARIOS con sus observaciones, y arrastra su trampa: el formulario de
-- edicion tiene que leer de otro endpoint o termina guardando el resumen encima
-- del texto entero. Para un pie de foto no vale la pena: se limita al alta, y
-- entonces lo que la galeria muestra es siempre lo que hay guardado.
--
--------------------------------------------------------------------------------
-- EL AISLAMIENTO POR EMPRESA SE HACE CONTRA EL PADRE
--
-- REPORTES_MULTIMEDIA no tiene ID_EMPRESA: cuelga de REPORTES_ACTIVIDADES, que
-- si la tiene. Es el caso de "tabla sin columna de empresa" de la guia, el mismo
-- de MANUALES contra INSTITUCIONES: `idEmpresa` viaja en todas las llamadas sin
-- ser una columna, y cada operacion lo comprueba con un EXISTS contra el padre.
--
-- Sin eso, un DELETE con el id de un archivo de otra empresa lo borraba igual:
-- la pantalla no lo permite, pero el endpoint esta abierto a cualquiera con
-- sesion.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_REPORTES_MULTIMEDIA AS

  -- Galeria de un reporte. `idReporte` e `idEmpresa` son obligatorios: sin el
  -- segundo la consulta no se acota sola y devolveria archivos de otra empresa.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_reporte    IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  ------------------------------------------------------------------------------
  -- LOS CAMPOS DEL JSON LLEGAN SUELTOS, NO COMO `:body`
  --
  -- ORDS crea un bind por cada clave de primer nivel (:idReporte, :urlArchivo).
  -- `:body` es el payload crudo como BLOB, y buscarle adentro con JSON_VALUE
  -- devuelve NULL en todos los campos. Del lado del cliente hay que mandar
  -- TODAS las claves aunque vayan en "": una clave omitida deja el bind sin
  -- definir en vez de en NULL.
  ------------------------------------------------------------------------------
  PROCEDURE INSERTAR (
    p_authorization     IN  VARCHAR2,
    p_id_reporte        IN  VARCHAR2,
    p_id_empresa        IN  VARCHAR2,
    p_tipo_archivo      IN  VARCHAR2,
    p_descripcion_texto IN  VARCHAR2,
    p_url_archivo       IN  VARCHAR2,
    p_nombre_archivo    IN  VARCHAR2,
    p_tamanio_bytes     IN  VARCHAR2,
    p_status_code       OUT NUMBER,
    p_resultado         OUT CLOB
  );

  -- Solo el pie de foto. La URL, el tipo y el peso describen un archivo que ya
  -- esta subido: cambiarlos seria otro archivo, y eso es borrar y volver a
  -- agregar.
  PROCEDURE ACTUALIZAR (
    p_authorization     IN  VARCHAR2,
    p_id                IN  VARCHAR2,
    p_id_empresa        IN  VARCHAR2,
    p_descripcion_texto IN  VARCHAR2,
    p_status_code       OUT NUMBER,
    p_resultado         OUT CLOB
  );

  -- Baja fisica de la fila. El archivo sigue en Cloudinary (ver cabecera).
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_REPORTES_MULTIMEDIA;
/

CREATE OR REPLACE PACKAGE BODY PKG_REPORTES_MULTIMEDIA AS

  C_MAX_DESCRIPCION CONSTANT PLS_INTEGER := 200;
  C_MAX_URL         CONSTANT PLS_INTEGER := 500;
  C_MAX_NOMBRE      CONSTANT PLS_INTEGER := 200;
  C_TAMANIO_MAXIMO  CONSTANT PLS_INTEGER := 50;

  ------------------------------------------------------------------------------
  -- Privado: borra el modulo ORDS si existe, reintentando ante un interbloqueo.
  -- Una sesion de `npm run dev` pegandole al endpoint mantiene tomados los
  -- metadatos que DELETE_MODULE necesita.
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
         WHERE NAME = 'reportes-multimedia';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'reportes-multimedia');
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

  FUNCTION NUMERO(p_valor VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN TO_NUMBER(NULLIF(TRIM(p_valor), ''));
  EXCEPTION
    WHEN OTHERS THEN
      RETURN NULL;
  END NUMERO;

  FUNCTION SESION(p_authorization VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
  END SESION;

  -- El reporte existe Y es de esta empresa. Las dos cosas se contestan igual
  -- (404): distinguirlas confirmaria la existencia de datos ajenos.
  FUNCTION REPORTE_DE_LA_EMPRESA(p_reporte NUMBER, p_empresa NUMBER) RETURN BOOLEAN IS
    l_cuenta PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_cuenta
      FROM REPORTES_ACTIVIDADES
     WHERE ID_REPORTE = p_reporte
       AND ID_EMPRESA = p_empresa;

    RETURN l_cuenta > 0;
  END REPORTE_DE_LA_EMPRESA;

  -- foto | video | documento. El DDL no tiene CHECK —el COMMENT los enumera, y
  -- un COMMENT no es una restriccion—, asi que se validan aca. La misma lista
  -- esta en TIPOS_MULTIMEDIA de src/lib/api.ts: si se agrega uno, van los dos.
  FUNCTION TIPO_VALIDO(p_tipo VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN LOWER(TRIM(p_tipo)) IN ('foto', 'video', 'documento');
  END TIPO_VALIDO;

  -- La URL termina en un href y en un src. Sin esto, "javascript:alert(1)" se
  -- guarda igual y se ejecuta al abrir la galeria.
  FUNCTION URL_VALIDA(p_url VARCHAR2) RETURN BOOLEAN IS
    l_url VARCHAR2(4000) := NULLIF(TRIM(p_url), '');
  BEGIN
    RETURN l_url IS NOT NULL
       AND LENGTH(l_url) <= C_MAX_URL
       AND LOWER(SUBSTR(l_url, 1, 8)) = 'https://';
  END URL_VALIDA;

  ------------------------------------------------------------------------------
  -- LISTAR
  ------------------------------------------------------------------------------
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_reporte    IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_reporte NUMBER;
    l_empresa NUMBER;
    l_pagina  NUMBER;
    l_tamanio NUMBER;
    l_offset  NUMBER;
    l_total   NUMBER;
    l_items   CLOB;
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_reporte := NUMERO(p_id_reporte);
    l_empresa := NUMERO(p_id_empresa);

    IF l_reporte IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"idReporte e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    IF NOT REPORTE_DE_LA_EMPRESA(l_reporte, l_empresa) THEN
      p_status_code := 404;
      p_resultado   := '{"error":"Reporte no encontrado"}';
      RETURN;
    END IF;

    l_pagina  := GREATEST(NVL(NUMERO(p_pagina), 1), 1);
    l_tamanio := LEAST(GREATEST(NVL(NUMERO(p_tamanio), 20), 1), C_TAMANIO_MAXIMO);
    l_offset  := (l_pagina - 1) * l_tamanio;

    SELECT COUNT(*)
      INTO l_total
      FROM REPORTES_MULTIMEDIA
     WHERE ID_REPORTE = l_reporte;

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, ya tipada como CLOB: anidado, el intermedio se materializa como
    -- VARCHAR2 y revienta a los 4000 bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'               VALUE m.ID_MULTIMEDIA,
                 'idReporte'        VALUE m.ID_REPORTE,
                 'tipoArchivo'      VALUE m.TIPO_ARCHIVO,
                 'descripcionTexto' VALUE m.DESCRIPCION_TEXTO,
                 'urlArchivo'       VALUE m.URL_ARCHIVO,
                 'nombreArchivo'    VALUE m.NOMBRE_ARCHIVO,
                 'tamanioBytes'     VALUE m.TAMANIO_BYTES,
                 'fechaCreacion'    VALUE TO_CHAR(m.FECHA_CREACION, 'YYYY-MM-DD"T"HH24:MI:SS')
                 RETURNING CLOB
               ) fila,
               m.ID_MULTIMEDIA orden
          FROM REPORTES_MULTIMEDIA m
         WHERE m.ID_REPORTE = l_reporte
         ORDER BY m.ID_MULTIMEDIA
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
      APEX_DEBUG.ERROR('PKG_REPORTES_MULTIMEDIA.LISTAR: ' || SQLERRM);
      p_resultado := '{"error":"Error al listar los archivos"}';
  END LISTAR;

  ------------------------------------------------------------------------------
  -- INSERTAR
  ------------------------------------------------------------------------------
  PROCEDURE INSERTAR (
    p_authorization     IN  VARCHAR2,
    p_id_reporte        IN  VARCHAR2,
    p_id_empresa        IN  VARCHAR2,
    p_tipo_archivo      IN  VARCHAR2,
    p_descripcion_texto IN  VARCHAR2,
    p_url_archivo       IN  VARCHAR2,
    p_nombre_archivo    IN  VARCHAR2,
    p_tamanio_bytes     IN  VARCHAR2,
    p_status_code       OUT NUMBER,
    p_resultado         OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_reporte     NUMBER;
    l_empresa     NUMBER;
    l_tipo        VARCHAR2(20);
    l_descripcion VARCHAR2(1000);
    l_url         VARCHAR2(500);
    l_nombre      VARCHAR2(200);
    l_tamanio     NUMBER;
    l_id          NUMBER;
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_reporte     := NUMERO(p_id_reporte);
    l_empresa     := NUMERO(p_id_empresa);
    l_tipo        := LOWER(NULLIF(TRIM(p_tipo_archivo), ''));
    l_descripcion := NULLIF(TRIM(p_descripcion_texto), '');
    l_url         := NULLIF(TRIM(p_url_archivo), '');
    l_tamanio     := NUMERO(p_tamanio_bytes);
    -- El nombre original puede venir larguisimo desde el celular: se recorta en
    -- vez de rechazar. Es una etiqueta, no un dato con el que se opere.
    l_nombre      := SUBSTR(NULLIF(TRIM(p_nombre_archivo), ''), 1, C_MAX_NOMBRE);

    IF l_reporte IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"idReporte e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    IF NOT TIPO_VALIDO(l_tipo) THEN
      p_status_code := 400;
      p_resultado   := '{"error":"El tipo debe ser foto, video o documento"}';
      RETURN;
    END IF;

    IF NOT URL_VALIDA(l_url) THEN
      p_status_code := 400;
      p_resultado   := '{"error":"La URL del archivo debe empezar con https:// y no pasar de 500 caracteres"}';
      RETURN;
    END IF;

    IF LENGTH(l_descripcion) > C_MAX_DESCRIPCION THEN
      p_status_code := 400;
      p_resultado   := '{"error":"La descripcion no puede pasar de 200 caracteres"}';
      RETURN;
    END IF;

    IF NOT REPORTE_DE_LA_EMPRESA(l_reporte, l_empresa) THEN
      p_status_code := 404;
      p_resultado   := '{"error":"Reporte no encontrado"}';
      RETURN;
    END IF;

    INSERT INTO REPORTES_MULTIMEDIA (
      ID_REPORTE, TIPO_ARCHIVO, DESCRIPCION_TEXTO, URL_ARCHIVO,
      NOMBRE_ARCHIVO, TAMANIO_BYTES, FECHA_CREACION
    ) VALUES (
      l_reporte, l_tipo, l_descripcion, l_url,
      l_nombre, l_tamanio, SYSTIMESTAMP
    ) RETURNING ID_MULTIMEDIA INTO l_id;

    -- La ficha del reporte queda marcada como tocada: la galeria es parte del
    -- reporte, y un archivo agregado hoy sobre un texto de la semana pasada
    -- tiene que mover su "ultima actualizacion".
    UPDATE REPORTES_ACTIVIDADES
       SET FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_REPORTE = l_reporte;

    COMMIT;

    p_status_code := 201;
    p_resultado   := '{"ok":true,"id":' || TO_CHAR(l_id) || '}';

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_REPORTES_MULTIMEDIA.INSERTAR: ' || SQLERRM);
      p_resultado := '{"error":"Error al guardar el archivo"}';
  END INSERTAR;

  ------------------------------------------------------------------------------
  -- ACTUALIZAR
  --
  -- Solo el pie de foto, y un texto vacio lo BORRA: es el unico campo editable
  -- y el cliente siempre lo manda, asi que con el NVL habitual no habria forma
  -- de sacar un pie escrito por error.
  ------------------------------------------------------------------------------
  PROCEDURE ACTUALIZAR (
    p_authorization     IN  VARCHAR2,
    p_id                IN  VARCHAR2,
    p_id_empresa        IN  VARCHAR2,
    p_descripcion_texto IN  VARCHAR2,
    p_status_code       OUT NUMBER,
    p_resultado         OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id          NUMBER;
    l_empresa     NUMBER;
    l_descripcion VARCHAR2(1000);
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado   := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id          := NUMERO(p_id);
    l_empresa     := NUMERO(p_id_empresa);
    l_descripcion := NULLIF(TRIM(p_descripcion_texto), '');

    IF l_id IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado   := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    IF LENGTH(l_descripcion) > C_MAX_DESCRIPCION THEN
      p_status_code := 400;
      p_resultado   := '{"error":"La descripcion no puede pasar de 200 caracteres"}';
      RETURN;
    END IF;

    UPDATE REPORTES_MULTIMEDIA m
       SET m.DESCRIPCION_TEXTO = l_descripcion
     WHERE m.ID_MULTIMEDIA = l_id
       AND EXISTS (SELECT 1
                     FROM REPORTES_ACTIVIDADES r
                    WHERE r.ID_REPORTE = m.ID_REPORTE
                      AND r.ID_EMPRESA = l_empresa);

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado   := '{"error":"Archivo no encontrado"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado   := '{"ok":true}';

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_REPORTES_MULTIMEDIA.ACTUALIZAR: ' || SQLERRM);
      p_resultado := '{"error":"Error al actualizar el archivo"}';
  END ACTUALIZAR;

  ------------------------------------------------------------------------------
  -- ELIMINAR
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

    DELETE FROM REPORTES_MULTIMEDIA m
     WHERE m.ID_MULTIMEDIA = l_id
       AND EXISTS (SELECT 1
                     FROM REPORTES_ACTIVIDADES r
                    WHERE r.ID_REPORTE = m.ID_REPORTE
                      AND r.ID_EMPRESA = l_empresa);

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado   := '{"error":"Archivo no encontrado"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado   := '{"ok":true}';

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_REPORTES_MULTIMEDIA.ELIMINAR: ' || SQLERRM);
      p_resultado := '{"error":"Error al eliminar el archivo"}';
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- PUBLICACION DE LOS ENDPOINTS
  --
  -- Las llamadas van escritas una por una, con valores literales. Envolverlas
  -- en helpers hace que ORDS rechace el PRIMER parametro con
  -- ORA-02290 (REST_PARAMS_SOURCE_TYPE_CK) y deje el modulo sin ningun
  -- endpoint; esta explicado en db/reportes-actividades.sql. NO reintroducir
  -- los helpers.
  --
  -- Los query params y los campos del body se vinculan solos al bind del mismo
  -- nombre: solo se declaran el header `authorization`, el CLOB de salida y el
  -- status code.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'reportes-multimedia',
      p_base_path      => '/reportes-multimedia/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Archivos de los reportes de actividades'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'reportes-multimedia',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /reportes-multimedia/listar?idReporte= &idEmpresa= &pagina= &tamanio=
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'reportes-multimedia', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'reportes-multimedia',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_REPORTES_MULTIMEDIA.LISTAR(:authorization, :idReporte, :idEmpresa, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-multimedia', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-multimedia', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-multimedia', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /reportes-multimedia/crear
    -- Body: { idReporte, idEmpresa, tipoArchivo, descripcionTexto,
    --         urlArchivo, nombreArchivo, tamanioBytes }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'reportes-multimedia', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'reportes-multimedia',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_REPORTES_MULTIMEDIA.INSERTAR(:authorization, :idReporte, :idEmpresa, :tipoArchivo, :descripcionTexto, :urlArchivo, :nombreArchivo, :tamanioBytes, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-multimedia', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-multimedia', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-multimedia', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /reportes-multimedia/actualizar/:id
    -- Body: { idEmpresa, descripcionTexto }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'reportes-multimedia', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'reportes-multimedia',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_REPORTES_MULTIMEDIA.ACTUALIZAR(:authorization, :id, :idEmpresa, :descripcionTexto, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-multimedia', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-multimedia', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-multimedia', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /reportes-multimedia/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'reportes-multimedia', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'reportes-multimedia',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_REPORTES_MULTIMEDIA.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-multimedia', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-multimedia', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'reportes-multimedia', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_REPORTES_MULTIMEDIA;
/

BEGIN
  PKG_REPORTES_MULTIMEDIA.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- VERIFICACION
--------------------------------------------------------------------------------
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_REPORTES_MULTIMEDIA';

SELECT LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_REPORTES_MULTIMEDIA'
 ORDER BY LINE;

SELECT m.NAME, t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_MODULES m
  JOIN USER_ORDS_TEMPLATES t ON t.MODULE_ID = m.ID
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
 WHERE m.NAME = 'reportes-multimedia'
 ORDER BY t.URI_TEMPLATE, h.METHOD;
