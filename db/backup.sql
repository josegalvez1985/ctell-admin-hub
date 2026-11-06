--------------------------------------------------------------------------------
-- CTELL · BACKUP — copia del esquema en scripts SQL, por correo
--
-- PKG_BACKUP_CTELL. Interno: no publica módulo ORDS ni valida token, como PKG_STOCK.
-- Lo corre el job JOB_BACKUP_CTELL todos los días a las 03:00 de Paraguay.
--
-- Tiene que alcanzar para levantar el sistema en otro lado si se pierde la base o el
-- proveedor da de baja la cuenta.
--
-- ORDEN: auth.sql -> backup-ddl.sql (una vez) -> backup.sql -> asistente.sql (lleva las
-- tablas CTELL_BACKUP_* en ES_PRIVADA). Ejecutar completo como dueño del esquema, en SQL
-- Workshop -> SQL Scripts. Idempotente.
--
-- ANTES DE REEJECUTAR ESTE ARCHIVO, detener cualquier copia que esté corriendo (ver
-- OPERACIÓN): reemplazar el paquete mientras se usa deja el script esperando.
--
-- QUÉ GENERA (.sql en .zip, numerados en el orden de restauración)
--
--   NN_estructura  secuencias, tipos, tablas (con PK, UK, CHECK y NOT NULL), índices,
--                  comentarios, vistas, código, triggers, FK, sinónimos y jobs.
--   NN_ords        los módulos publicados, si la instancia deja exportarlos.
--   NN_datos       un INSERT por fila. La primera parte apaga FK y triggers y prepara
--                  los identity, para que restaurar no dispare nada (un conteo cerrado
--                  volvería a ajustar EXISTENCIAS).
--   NN_archivos    el contenido de los BLOB. La última parte prende lo que se apagó.
--
-- Cada corrida termina con un correo de RESUMEN: si no llegó, la corrida no terminó. Si
-- dice CON ERRORES, la copia NO está completa. Un AVISO no la invalida.
--
-- QUÉ NO VA, A PROPÓSITO (un correo no es lugar para esto)
--
--   - Los datos de IA_*, TOKENS, CLOUDINARY_CONFIG y CTELL_BACKUP_*: su estructura sí.
--     Ver c_sin_datos: una tabla nueva con secretos va ahí Y en ES_PRIVADA de asistente.sql.
--   - USUARIOS.CONTRASENA_HASH y SALT: van con un valor que no coincide con ningún hash.
--     Ver c_col_secreta. Una columna secreta con otro nombre viaja por correo, así que
--     hay que revisar cada tanto:
--       SELECT TABLE_NAME, COLUMN_NAME FROM USER_TAB_COLS
--        WHERE REGEXP_LIKE(COLUMN_NAME, 'CLAVE|PASS|KEY|TOKEN|SECRET|CREDENCIAL|HASH|SALT|PIN', 'i')
--        ORDER BY 1, 2;
--
-- QUÉ NO CUBRE
--
--   - LO QUE ESTÁ EN CLOUDINARY (fotos de artículos y profesores, evidencias, manuales):
--     la copia lleva la URL, no el archivo. Perder esa cuenta los pierde.
--   - El resto del workspace y los GRANT. El frontend se reconstruye desde el repo.
--
-- OJO: el correo lleva clientes, precios y correos de usuarios SIN cifrar. El destino
-- tiene que ser una casilla sólo del dueño, con verificación en dos pasos.
--
-- CORRE EN TRAMOS: la instancia limita la CPU por llamada (CPU_PER_CALL, ORA-02393) y un
-- job entero es una sola llamada. Cada tramo es un job, usa el 60 % del límite y deja lo
-- que falta en CTELL_BACKUP_TAREA para el siguiente (BACKUP_TRAMO_*). Por eso las tablas
-- no se leen todas en la misma foto: una venta cargada durante la copia puede quedar sin
-- su detalle, y por eso corre de madrugada.
--
-- PUESTA EN MARCHA, EN SQL COMMANDS (la casilla no va en este archivo: se sube al repo)
--
--   1. BEGIN PKG_BACKUP_CTELL.fijar_destino('la casilla'); END;
--   2. BEGIN PKG_BACKUP_CTELL.probar_correo; END;
--      Tiene que llegar prueba.zip. Si no llega, ver db/diagnostico-correo.sql y:
--        SELECT ID, MAIL_SUBJ, MAIL_SEND_COUNT, MAIL_SEND_ERROR FROM APEX_MAIL_QUEUE;
--   3. Medir, SIN mandar nada:
--        BEGIN PKG_BACKUP_CTELL.lanzar(p_enviar => FALSE); END;
--        SELECT ESTADO, PASO, PASO_EN, PARTES, TABLAS, FILAS, ERRORES, BYTES_ZIP, DETALLE
--          FROM CTELL_BACKUP_LOG ORDER BY ID DESC;
--   4. La primera copia de verdad: BEGIN PKG_BACKUP_CTELL.lanzar; END;
--
-- COMPROBAR LA COPIA. Sólo el último nivel prueba que sirve.
--
--   1. ESTADO = OK y ERRORES = 0.
--   2. Llegaron el resumen y tantas partes como diga PARTES, con los números seguidos, y
--      con todo descomprimido en una carpeta, en PowerShell:
--        (Select-String -Path *_datos.sql -Pattern '^INSERT INTO').Count   -- igual a FILAS
--        Select-String -Path *.sql -Pattern '^-- (ERROR en|NO SE PUDO)'    -- sólo ORDS, o nada
--   3. Restaurar en una base aparte (Oracle Free alcanza, salvo para ORDS) y comparar:
--        SELECT OBJECT_TYPE, STATUS, COUNT(*) FROM USER_OBJECTS
--         WHERE GENERATED = 'N' AND OBJECT_NAME NOT LIKE '%$%'
--           AND OBJECT_NAME NOT LIKE 'BACKUP\_%' ESCAPE '\'
--         GROUP BY OBJECT_TYPE, STATUS ORDER BY 1, 2;
--
-- RESTAURAR (NUNCA EN PRODUCCIÓN para probar)
--
--   1. Descomprimir los .zip de UN MISMO DÍA y correr los .sql en orden de número:
--        SPOOL restauracion.log
--        @ctell_2026-11-07_01_estructura.sql
--        -- ...y las demás partes, en orden
--        SPOOL OFF
--   2. Buscar ORA- en restauracion.log: los scripts siguen aunque haya errores.
--   3. Volver a cargar lo que no viaja:
--        PKG_ASISTENTE.FIJAR_CLAVE, PKG_CLOUDINARY.FIJAR_CREDENCIALES,
--        PKG_BACKUP_CTELL.fijar_destino, y los GRANT y permisos de red.
--   4. NADIE PUEDE ENTRAR hasta recuperar su clave: POST /auth/recuperar la manda por
--      correo, así que APEX_MAIL tiene que estar funcionando en la base nueva.
--
-- OPERACIÓN
--
--   CONFIGURACIÓN, en CTELL_BACKUP_CONFIG (UPDATE + COMMIT, sin correr el script):
--     DESTINO    la casilla (con fijar_destino)
--     REMITENTE  el "De:". Vacío, lo resuelve APEX: el free tier sólo acepta como origen
--                la del dueño del workspace (ver db/auth.sql)
--     PARTE_MB   20: tamaño de cada .sql antes de comprimir. Bajarlo si rebotan
--     CPU_SEG    opcional: segundos de CPU por tramo. Sin esto, el 60 % de CPU_PER_CALL
--
--   SI QUEDA 'EN CURSO' MUCHO TIEMPO, ese estado no prueba que siga corriendo:
--     -- Con una fila, hay un tramo corriendo o por arrancar. Sin filas, la corrida murió
--     -- (queda INTERRUMPIDA cuando arranca la siguiente).
--     SELECT JOB_NAME, STATE FROM USER_SCHEDULER_JOBS
--      WHERE JOB_NAME LIKE 'BACKUP\_MANUAL%' ESCAPE '\' OR JOB_NAME LIKE 'BACKUP\_TRAMO%' ESCAPE '\';
--     -- Por qué terminó cada job
--     SELECT JOB_NAME, STATUS, ACTUAL_START_DATE, RUN_DURATION, ERRORS
--       FROM USER_SCHEDULER_JOB_RUN_DETAILS
--      WHERE JOB_NAME LIKE '%BACKUP%' ORDER BY ACTUAL_START_DATE DESC;
--     -- Detener una corrida
--     BEGIN DBMS_SCHEDULER.STOP_JOB('<job_name>'); END;
--
--   Un día sin resumen es un día sin copia, y nada más avisa.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_BACKUP_CTELL AS

  -- Genera la copia. p_enviar FALSE: solo mide, queda en CTELL_BACKUP_LOG.
  -- Es lo que corre el job.
  PROCEDURE ejecutar(p_enviar IN BOOLEAN DEFAULT TRUE);

  -- Uso interno: sigue una corrida en un job nuevo cuando el tramo anterior agotó su CPU.
  PROCEDURE continuar(p_id IN NUMBER);

  -- Lo mismo, en segundo plano: una corrida larga no depende de la pantalla abierta.
  PROCEDURE lanzar(p_enviar IN BOOLEAN DEFAULT TRUE);

  -- La casilla que recibe las copias (y, opcional, el remitente).
  PROCEDURE fijar_destino(p_correo IN VARCHAR2, p_remitente IN VARCHAR2 DEFAULT NULL);

  -- Manda un correo chico con un .zip, para saber si esta instancia puede.
  PROCEDURE probar_correo;

END PKG_BACKUP_CTELL;
/

CREATE OR REPLACE PACKAGE BODY PKG_BACKUP_CTELL AS

  -- El mismo que PKG_AUTH.C_WORKSPACE_MAIL: un job no corre dentro de ningún workspace.
  c_workspace CONSTANT VARCHAR2(64) := 'CTELL';
  -- UTC -> hora de Paraguay, como en PKG_ASISTENTE.
  c_desfase   CONSTANT NUMBER       := -3 / 24;
  -- De estas tablas va la estructura, nunca los datos. El filtro de columnas de abajo
  -- NO alcanza para ellas: en IA_CONFIG y CLOUDINARY_CONFIG el secreto está en una
  -- columna que se llama VALOR.
  c_sin_datos CONSTANT VARCHAR2(100) := '^(CTELL_BACKUP_|IA_|TOKENS$|CLOUDINARY_CONFIG$)';
  -- Estas columnas no se copian. CONTRASENA y SALT son las de USUARIOS, que el filtro
  -- genérico dejaba pasar. El ancla de SALT es para no atrapar un SALTO cualquiera.
  c_col_secreta CONSTANT VARCHAR2(100) := 'PASSWORD|PASSWD|API_?KEY|TOKEN|SECRET|CONTRASENA|(^|_)SALT$';
  -- Lo que recibe una columna secreta NOT NULL, para que el INSERT no falle. En
  -- CONTRASENA_HASH no coincide con ningún hash: nadie entra hasta recuperar la clave.
  c_sin_valor CONSTANT VARCHAR2(1) := 'X';
  -- Un adjunto más grande que esto suele rebotar: se avisa en el resumen.
  c_zip_grande CONSTANT NUMBER := 18 * 1024 * 1024;

  g_parte   CLOB;
  g_buf     VARCHAR2(32767);
  g_chars   NUMBER := 0;
  g_ancho   PLS_INTEGER := 0;
  g_tope    NUMBER;
  g_fecha   VARCHAR2(10);
  g_tipo    VARCHAR2(30);
  g_n       PLS_INTEGER := 0;
  g_enviar  BOOLEAN := FALSE;
  g_destino VARCHAR2(400);
  g_desde   VARCHAR2(400);
  g_errores PLS_INTEGER := 0;
  g_detalle VARCHAR2(3900);
  g_tablas  NUMBER := 0;
  g_filas   NUMBER := 0;
  g_b_sql   NUMBER := 0;
  g_b_zip   NUMBER := 0;
  g_log     NUMBER;
  g_cpu0    NUMBER;
  g_cpu_max NUMBER;
  g_pausa   BOOLEAN := FALSE;

  ------------------------------------------------------------------------------
  -- AUXILIARES
  ------------------------------------------------------------------------------

  FUNCTION ahora RETURN DATE IS
  BEGIN
    RETURN CAST(SYS_EXTRACT_UTC(SYSTIMESTAMP) AS DATE) + c_desfase;
  END ahora;

  FUNCTION config(p_clave IN VARCHAR2, p_defecto IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    l_v ctell_backup_config.valor%TYPE;
  BEGIN
    SELECT valor INTO l_v FROM ctell_backup_config WHERE clave = p_clave;
    RETURN NVL(TRIM(l_v), p_defecto);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN p_defecto;
  END config;

  PROCEDURE anotar(p_txt IN VARCHAR2) IS
  BEGIN
    -- SUBSTRB: la variable mide bytes y con acentos 3900 caracteres no entran (ORA-06502).
    g_detalle := SUBSTRB(g_detalle || p_txt || CHR(10), 1, 3900);
  END anotar;

  -- Mismo criterio que PKG_AUTH.ESTABLECER_WORKSPACE_MAIL, que es privado de ese paquete:
  -- por nombre, sin sesión y sin aplicación APEX (este workspace no tiene ninguna).
  PROCEDURE contexto_apex IS
    l_id NUMBER;
  BEGIN
    l_id := APEX_UTIL.FIND_SECURITY_GROUP_ID(p_workspace => c_workspace);
    IF l_id IS NULL THEN
      RAISE_APPLICATION_ERROR(-20005, 'No existe el workspace ' || c_workspace || '.');
    END IF;
    APEX_UTIL.SET_SECURITY_GROUP_ID(p_security_group_id => l_id);
  END contexto_apex;

  -- Autónoma: el correo queda en la cola aunque el tramo se corte después.
  PROCEDURE enviar(p_asunto IN VARCHAR2, p_cuerpo IN VARCHAR2,
                   p_adjunto IN BLOB DEFAULT NULL, p_archivo IN VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_id NUMBER;
  BEGIN
    contexto_apex;
    -- g_desde en NULL (lo normal): APEX resuelve el remitente, como en db/auth.sql.
    l_id := APEX_MAIL.SEND(p_to => g_destino, p_from => g_desde,
                           p_body => p_cuerpo, p_subj => p_asunto);
    IF p_adjunto IS NOT NULL THEN
      APEX_MAIL.ADD_ATTACHMENT(p_mail_id => l_id, p_attachment => p_adjunto,
                               p_filename => p_archivo, p_mime_type => 'application/zip');
    END IF;
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END enviar;

  PROCEDURE empujar_cola IS
  BEGIN
    contexto_apex;
    APEX_MAIL.PUSH_QUEUE;
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN NULL;  -- igual lo manda el job de la cola de APEX
  END empujar_cola;

  FUNCTION log_inicio(p_enviar IN BOOLEAN) RETURN NUMBER IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_id     NUMBER;
    -- En variables: una función privada del paquete no se puede usar dentro de SQL.
    l_ahora  DATE := ahora;
    l_enviar CHAR(1) := CASE WHEN p_enviar THEN 'S' ELSE 'N' END;
  BEGIN
    -- Una corrida cuya sesión murió no llega a anotar su final: quedaría EN CURSO para
    -- siempre. Si en realidad sigue viva, al terminar pisa este estado con el suyo.
    UPDATE ctell_backup_log
       SET fin = l_ahora, estado = 'INTERRUMPIDA'
     WHERE estado = 'EN CURSO';
    DELETE FROM ctell_backup_tarea
     WHERE corrida IN (SELECT id FROM ctell_backup_log WHERE inicio < l_ahora - 3);
    -- La cuota del esquema son 25 MB: el registro no puede crecer sin techo.
    DELETE FROM ctell_backup_log WHERE inicio < l_ahora - 90;
    INSERT INTO ctell_backup_log (inicio, estado, enviado)
    VALUES (l_ahora, 'EN CURSO', l_enviar)
    RETURNING id INTO l_id;
    COMMIT;
    RETURN l_id;
  END log_inicio;

  PROCEDURE log_fin(p_id IN NUMBER, p_estado IN VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_ahora DATE := ahora;
  BEGIN
    UPDATE ctell_backup_log
       SET fin = l_ahora, estado = p_estado, partes = g_n, tablas = g_tablas, filas = g_filas,
           bytes_script = g_b_sql, bytes_zip = g_b_zip, errores = g_errores, detalle = g_detalle
     WHERE id = p_id;
    COMMIT;
  END log_fin;

  -- Autónoma: se tiene que ver mientras corre, y queda aunque la sesión muera después.
  PROCEDURE avance(p_paso IN VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_ahora DATE := ahora;
    l_paso  VARCHAR2(200) := SUBSTRB(p_paso, 1, 200);
  BEGIN
    UPDATE ctell_backup_log
       SET paso = l_paso, paso_en = l_ahora, partes = g_n, tablas = g_tablas, filas = g_filas,
           bytes_script = g_b_sql, bytes_zip = g_b_zip, errores = g_errores, detalle = g_detalle
     WHERE id = g_log;
    COMMIT;
  END avance;

  -- Cancelaron la corrida, mataron la sesión o se pasó de un límite de la instancia:
  -- los WHEN OTHERS por objeto no pueden tragárselo y seguir con el objeto siguiente.
  FUNCTION cancelada(p_codigo IN NUMBER) RETURN BOOLEAN IS
  BEGIN
    RETURN p_codigo IN (-1013, -40, -28, -2393);
  END cancelada;

  -- La CPU que puede usar un tramo, en centésimas de segundo. Hay que parar antes del
  -- límite: pasado el ORA-02393, en esa llamada ya no se puede ni anotar el error.
  FUNCTION presupuesto_cpu RETURN NUMBER IS
    l_seg    VARCHAR2(400) := config('CPU_SEG');
    l_limite VARCHAR2(40);
  BEGIN
    IF l_seg IS NOT NULL THEN
      RETURN TO_NUMBER(l_seg) * 100;
    END IF;
    SELECT "LIMIT" INTO l_limite FROM user_resource_limits WHERE resource_name = 'CPU_PER_CALL';
    IF REGEXP_LIKE(l_limite, '^[0-9]+$') THEN
      RETURN TRUNC(TO_NUMBER(l_limite) * 0.6);
    END IF;
    RETURN 30000;
  EXCEPTION
    WHEN OTHERS THEN RETURN 30000;
  END presupuesto_cpu;

  FUNCTION sin_cpu RETURN BOOLEAN IS
  BEGIN
    RETURN DBMS_UTILITY.GET_CPU_TIME - g_cpu0 > g_cpu_max;
  END sin_cpu;

  ------------------------------------------------------------------------------
  -- ESCRIBIR EL SCRIPT: de a pedazos, porque concatenar sobre un CLOB es lentísimo
  ------------------------------------------------------------------------------

  PROCEDURE volcar IS
  BEGIN
    IF g_buf IS NOT NULL THEN
      -- APPEND y no WRITEAPPEND: ese pide el largo en UTF-16 y LENGTH cuenta un emoji como
      -- uno, así que un pie de foto con emojis perdía en silencio el final del pedazo.
      DBMS_LOB.APPEND(g_parte, TO_CLOB(g_buf));
      g_buf := NULL;
    END IF;
  END volcar;

  PROCEDURE poner(p_txt IN VARCHAR2) IS
  BEGIN
    IF p_txt IS NULL THEN
      RETURN;
    END IF;
    IF NVL(LENGTHB(g_buf), 0) + LENGTHB(p_txt) > 32000 THEN
      volcar;
    END IF;
    g_buf   := g_buf || p_txt;
    g_chars := g_chars + LENGTH(p_txt);
    g_ancho := g_ancho + LENGTH(p_txt);
  END poner;

  PROCEDURE linea(p_txt IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    poner(p_txt);
    poner(CHR(10));
    g_ancho := 0;
  END linea;

  -- Cortar la línea: SQL*Plus no acepta líneas muy largas.
  PROCEDURE cortar IS
  BEGIN
    IF g_ancho > 1000 THEN
      linea;
    END IF;
  END cortar;

  PROCEDURE poner_clob(p_txt IN CLOB) IS
    l_pos NUMBER := 1;
    l_len NUMBER := NVL(DBMS_LOB.GETLENGTH(p_txt), 0);
  BEGIN
    WHILE l_pos <= l_len LOOP
      poner(DBMS_LOB.SUBSTR(p_txt, 7000, l_pos));
      l_pos := l_pos + 7000;
    END LOOP;
  END poner_clob;

  -- Un pedazo de texto como literal de SQL, sin saltos de línea adentro. SQL*Plus lee por
  -- línea y no mira las comillas: dentro de un literal, una línea que termina en ";" o que
  -- es sólo "/" cortaría el INSERT. Con esto toda línea del dato arranca con comilla.
  FUNCTION literal(p_txt IN VARCHAR2) RETURN VARCHAR2 IS
    c_lf CONSTANT VARCHAR2(20) := '''||CHR(10)||' || CHR(10) || '''';
    c_cr CONSTANT VARCHAR2(20) := '''||CHR(13)||' || CHR(10) || '''';
  BEGIN
    RETURN '''' || REPLACE(REPLACE(REPLACE(p_txt, '''', ''''''), CHR(10), c_lf), CHR(13), c_cr)
           || '''';
  END literal;

  -- Un texto como literal, en pedazos: un literal de SQL tiene tope de largo.
  PROCEDURE poner_texto(p_txt IN VARCHAR2) IS
    l_pos PLS_INTEGER := 1;
  BEGIN
    IF p_txt IS NULL THEN
      poner('NULL');
      RETURN;
    END IF;
    WHILE l_pos <= LENGTH(p_txt) LOOP
      IF l_pos > 1 THEN
        linea('||');
      END IF;
      poner(literal(SUBSTR(p_txt, l_pos, 700)));
      l_pos := l_pos + 700;
    END LOOP;
  END poner_texto;

  PROCEDURE poner_clob_literal(p_txt IN CLOB) IS
    l_pos NUMBER := 1;
    l_len NUMBER := NVL(DBMS_LOB.GETLENGTH(p_txt), 0);
  BEGIN
    IF l_len = 0 THEN
      poner('NULL');
      RETURN;
    END IF;
    WHILE l_pos <= l_len LOOP
      IF l_pos > 1 THEN
        linea('||');
      END IF;
      poner('TO_CLOB(' || literal(DBMS_LOB.SUBSTR(p_txt, 700, l_pos)) || ')');
      l_pos := l_pos + 700;
    END LOOP;
  END poner_clob_literal;

  ------------------------------------------------------------------------------
  -- LAS PARTES
  ------------------------------------------------------------------------------

  PROCEDURE abrir_parte(p_tipo IN VARCHAR2) IS
  BEGIN
    g_tipo  := p_tipo;
    g_n     := g_n + 1;
    g_chars := 0;
    g_ancho := 0;
    g_buf   := NULL;
    DBMS_LOB.CREATETEMPORARY(g_parte, TRUE, DBMS_LOB.SESSION);
    linea('-- Backup de CTELL del ' || g_fecha || ', parte ' || g_n || ' (' || p_tipo || ').');
    linea('-- Correr las partes en orden de número, con SQLcl o SQL*Plus.');
    linea('SET DEFINE OFF');
    linea('SET SQLBLANKLINES ON');
    linea('SET FEEDBACK OFF');
    linea('WHENEVER SQLERROR CONTINUE');
    linea;
  END abrir_parte;

  PROCEDURE cerrar_parte IS
    l_bin    BLOB;
    l_zip    BLOB;
    l_do     INTEGER := 1;
    l_so     INTEGER := 1;
    l_ctx    INTEGER := DBMS_LOB.DEFAULT_LANG_CTX;
    l_warn   INTEGER;
    l_nombre VARCHAR2(100) := 'ctell_' || g_fecha || '_' || LPAD(g_n, 2, '0') || '_' || g_tipo;
    l_tam    NUMBER;
  BEGIN
    avance('Comprimiendo la parte ' || g_n || ' (' || g_tipo || ')');
    volcar;
    DBMS_LOB.CREATETEMPORARY(l_bin, TRUE, DBMS_LOB.SESSION);
    DBMS_LOB.CONVERTTOBLOB(l_bin, g_parte, DBMS_LOB.LOBMAXSIZE, l_do, l_so,
                           NLS_CHARSET_ID('AL32UTF8'), l_ctx, l_warn);
    g_b_sql := g_b_sql + DBMS_LOB.GETLENGTH(l_bin);

    APEX_ZIP.ADD_FILE(p_zipped_blob => l_zip, p_file_name => l_nombre || '.sql', p_content => l_bin);
    APEX_ZIP.FINISH(p_zipped_blob => l_zip);
    l_tam   := DBMS_LOB.GETLENGTH(l_zip);
    g_b_zip := g_b_zip + l_tam;

    IF l_tam > c_zip_grande THEN
      anotar('Parte ' || g_n || ' pesa ' || ROUND(l_tam / 1048576, 1)
             || ' MB: puede rebotar. Bajar PARTE_MB.');
    END IF;
    IF g_enviar THEN
      enviar('Backup CTELL ' || g_fecha || ', parte ' || LPAD(g_n, 2, '0') || ' (' || g_tipo || ')',
             'Parte ' || g_n || ' del backup del ' || g_fecha || '. Al terminar llega un correo de resumen.',
             l_zip, l_nombre || '.zip');
    END IF;

    DBMS_LOB.FREETEMPORARY(l_bin);
    IF DBMS_LOB.ISTEMPORARY(l_zip) = 1 THEN
      DBMS_LOB.FREETEMPORARY(l_zip);
    END IF;
    DBMS_LOB.FREETEMPORARY(g_parte);
  END cerrar_parte;

  PROCEDURE seguir_parte IS
  BEGIN
    IF g_chars > g_tope THEN
      linea('COMMIT;');
      cerrar_parte;
      abrir_parte(g_tipo);
    END IF;
  END seguir_parte;

  ------------------------------------------------------------------------------
  -- ESTRUCTURA
  ------------------------------------------------------------------------------

  PROCEDURE transformar(p_param IN VARCHAR2, p_valor IN BOOLEAN) IS
  BEGIN
    DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, p_param, p_valor);
  EXCEPTION
    WHEN OTHERS THEN anotar('Sin el ajuste ' || p_param || ': ' || SUBSTR(SQLERRM, 1, 120));
  END transformar;

  PROCEDURE ddl(p_tipo IN VARCHAR2, p_nombre IN VARCHAR2, p_dependiente IN BOOLEAN DEFAULT FALSE) IS
    l_txt CLOB;
  BEGIN
    avance(p_tipo || ' ' || p_nombre);
    IF p_dependiente THEN
      l_txt := DBMS_METADATA.GET_DEPENDENT_DDL(p_tipo, p_nombre);
    ELSE
      l_txt := DBMS_METADATA.GET_DDL(p_tipo, p_nombre);
    END IF;
    poner_clob(l_txt);
    linea;
  EXCEPTION
    WHEN OTHERS THEN
      IF cancelada(SQLCODE) THEN
        RAISE;
      END IF;
      -- ORA-31608: la tabla no tiene ese dependiente (FK, comentarios): es normal.
      IF NOT (p_dependiente AND SQLCODE = -31608) THEN
        g_errores := g_errores + 1;
        linea('-- ERROR en ' || p_tipo || ' ' || p_nombre || ': ' || SUBSTR(SQLERRM, 1, 200));
        anotar('ERROR en ' || p_tipo || ' ' || p_nombre || ': ' || SUBSTR(SQLERRM, 1, 200));
      END IF;
  END ddl;

  PROCEDURE titulo(p_txt IN VARCHAR2) IS
  BEGIN
    linea;
    linea('-- === ' || p_txt || ' ===');
    linea;
  END titulo;

  -- Valen para la sesión: cada tramo los vuelve a fijar.
  PROCEDURE preparar_metadata IS
  BEGIN
    transformar('SQLTERMINATOR', TRUE);
    transformar('PRETTY', TRUE);
    transformar('SEGMENT_ATTRIBUTES', FALSE);
    transformar('STORAGE', FALSE);
    transformar('TABLESPACE', FALSE);
    transformar('EMIT_SCHEMA', FALSE);
    transformar('CONSTRAINTS', TRUE);        -- PK, UK, CHECK y NOT NULL, con la tabla
    transformar('REF_CONSTRAINTS', FALSE);   -- las FK van al final
  END preparar_metadata;

  ------------------------------------------------------------------------------
  -- ORDS: dinámico, porque esta instancia puede no permitirlo y eso no tiene que impedir
  -- compilar el paquete ni cortar la copia de los datos.
  --
  -- No se exporta la aplicación APEX porque este workspace no tiene ninguna (el frontend
  -- es React), ni el workspace: lleva los hashes de sus usuarios y sólo lo puede importar
  -- un administrador de instancia.
  --
  -- Si falla es un AVISO y no un error: lo publicado se reconstruye corriendo db/, que
  -- está en el repo. Es una foto de lo que ORDS tiene de verdad, no la única fuente.
  ------------------------------------------------------------------------------

  PROCEDURE exportar_ords IS
    l_txt CLOB;
  BEGIN
    avance('Exportando los módulos ORDS');
    titulo('LOS MÓDULOS ORDS');
    EXECUTE IMMEDIATE 'BEGIN :1 := ORDS_METADATA.ORDS_EXPORT.EXPORT_SCHEMA(); END;' USING OUT l_txt;
    IF NVL(DBMS_LOB.GETLENGTH(l_txt), 0) = 0 THEN
      anotar('AVISO: la exportación de ORDS vino vacía. Se publican corriendo db/.');
    END IF;
    poner_clob(l_txt);
    linea;
  EXCEPTION
    WHEN OTHERS THEN
      IF cancelada(SQLCODE) THEN
        RAISE;
      END IF;
      linea('-- NO SE PUDO EXPORTAR ORDS: ' || SUBSTR(SQLERRM, 1, 200));
      anotar('AVISO: sin exportación de ORDS (' || SUBSTR(SQLERRM, 1, 120)
             || '). Se publican corriendo db/.');
  END exportar_ords;

  ------------------------------------------------------------------------------
  -- DATOS
  ------------------------------------------------------------------------------

  PROCEDURE preparar_restauracion IS
  BEGIN
    titulo('APAGAR FK Y TRIGGERS MIENTRAS SE CARGAN LOS DATOS');
    FOR c IN (SELECT table_name, constraint_name FROM user_constraints
               WHERE constraint_type = 'R' AND status = 'ENABLED' AND table_name NOT LIKE '%$%') LOOP
      linea('ALTER TABLE "' || c.table_name || '" DISABLE CONSTRAINT "' || c.constraint_name || '";');
    END LOOP;
    FOR t IN (SELECT trigger_name FROM user_triggers
               WHERE status = 'ENABLED' AND base_object_type = 'TABLE' AND table_name NOT LIKE '%$%') LOOP
      linea('ALTER TRIGGER "' || t.trigger_name || '" DISABLE;');
    END LOOP;
    -- Un identity GENERATED ALWAYS rechazaría el valor original de la columna.
    FOR i IN (SELECT table_name, column_name FROM user_tab_identity_cols
               WHERE generation_type = 'ALWAYS' AND table_name NOT LIKE '%$%') LOOP
      linea('ALTER TABLE "' || i.table_name || '" MODIFY "' || i.column_name
            || '" GENERATED BY DEFAULT AS IDENTITY;');
    END LOOP;
  END preparar_restauracion;

  PROCEDURE terminar_restauracion IS
  BEGIN
    titulo('VOLVER A PRENDER LO QUE SE APAGÓ Y AJUSTAR LOS IDENTITY');
    FOR i IN (SELECT i.table_name, i.column_name, i.generation_type, c.default_on_null
                FROM user_tab_identity_cols i
                JOIN user_tab_cols c ON c.table_name = i.table_name AND c.column_name = i.column_name
               WHERE i.table_name NOT LIKE '%$%') LOOP
      linea('ALTER TABLE "' || i.table_name || '" MODIFY "' || i.column_name || '" GENERATED '
            || i.generation_type || CASE WHEN i.default_on_null = 'YES' THEN ' ON NULL' END
            || ' AS IDENTITY (START WITH LIMIT VALUE);');
    END LOOP;
    FOR c IN (SELECT table_name, constraint_name FROM user_constraints
               WHERE constraint_type = 'R' AND status = 'ENABLED' AND table_name NOT LIKE '%$%') LOOP
      linea('ALTER TABLE "' || c.table_name || '" ENABLE CONSTRAINT "' || c.constraint_name || '";');
    END LOOP;
    FOR t IN (SELECT trigger_name FROM user_triggers
               WHERE status = 'ENABLED' AND base_object_type = 'TABLE' AND table_name NOT LIKE '%$%') LOOP
      linea('ALTER TRIGGER "' || t.trigger_name || '" ENABLE;');
    END LOOP;
    linea('COMMIT;');
  END terminar_restauracion;

  -- p_desde: las filas que ya copió un tramo anterior. Si se acaba la CPU en medio de la
  -- tabla, deja anotado hasta dónde llegó y prende g_pausa.
  PROCEDURE datos_tabla(p_orden IN NUMBER, p_tabla IN VARCHAR2, p_desde IN NUMBER) IS
    TYPE t_txt IS TABLE OF VARCHAR2(30) INDEX BY PLS_INTEGER;
    l_clase  t_txt;
    l_sel    VARCHAR2(32767);
    l_ins    VARCHAR2(32767);
    l_n      PLS_INTEGER := 0;
    l_cur    INTEGER;
    l_ign    INTEGER;
    l_val    VARCHAR2(32767);
    l_clob   CLOB;
    l_filas  NUMBER := 0;
    l_clase1 VARCHAR2(1);
    l_expr   VARCHAR2(400);
    l_col    VARCHAR2(140);
  BEGIN
    FOR c IN (SELECT column_name, data_type, nullable FROM user_tab_cols
               WHERE table_name = p_tabla AND hidden_column = 'NO' AND virtual_column = 'NO'
               ORDER BY column_id) LOOP
      l_col    := '"' || c.column_name || '"';
      l_clase1 := NULL;
      IF REGEXP_LIKE(c.column_name, c_col_secreta, 'i') THEN
        IF p_desde = 0 THEN
          anotar('Sin copiar (dato secreto): ' || p_tabla || '.' || c.column_name);
        END IF;
        -- Obligatoria: omitirla haría fallar el INSERT de la fila entera (ORA-01400).
        IF c.nullable = 'N' THEN
          l_clase1 := 'S';
          l_expr   := 'NULL';
        END IF;
      ELSIF c.data_type IN ('NUMBER', 'FLOAT', 'BINARY_FLOAT', 'BINARY_DOUBLE') THEN
        l_clase1 := 'N';
        l_expr   := 'TO_CHAR(' || l_col || ', ''TM9'', ''NLS_NUMERIC_CHARACTERS=''''.,'''''')';
      ELSIF c.data_type IN ('VARCHAR2', 'NVARCHAR2', 'CHAR', 'NCHAR') THEN
        l_clase1 := 'T';
        l_expr   := l_col;
      ELSIF c.data_type = 'DATE' THEN
        l_clase1 := 'D';
        l_expr   := 'TO_CHAR(' || l_col || ', ''YYYY-MM-DD HH24:MI:SS'')';
      ELSIF c.data_type LIKE 'TIMESTAMP%TIME ZONE' THEN
        l_clase1 := 'Z';
        l_expr   := 'TO_CHAR(' || l_col || ', ''YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM'')';
      ELSIF c.data_type LIKE 'TIMESTAMP%' THEN
        l_clase1 := 'M';
        l_expr   := 'TO_CHAR(' || l_col || ', ''YYYY-MM-DD HH24:MI:SS.FF9'')';
      ELSIF c.data_type IN ('CLOB', 'NCLOB') THEN
        l_clase1 := 'C';
        l_expr   := 'TO_CLOB(' || l_col || ')';
      ELSIF c.data_type = 'RAW' THEN
        l_clase1 := 'R';
        l_expr   := 'RAWTOHEX(' || l_col || ')';
      ELSIF c.data_type = 'BLOB' THEN
        -- El contenido va aparte (archivos_columna). Obligatoria: vacía, para que el INSERT
        -- no falle.
        IF c.nullable = 'N' THEN
          l_clase1 := 'E';
          l_expr   := 'NULL';
        END IF;
      ELSIF p_desde = 0 THEN
        g_errores := g_errores + 1;
        anotar('Sin copiar (tipo ' || c.data_type || '): ' || p_tabla || '.' || c.column_name);
      END IF;
      IF l_clase1 IS NOT NULL THEN
        l_n := l_n + 1;
        l_clase(l_n) := l_clase1;
        l_sel := l_sel || CASE WHEN l_n > 1 THEN ', ' END || l_expr;
        l_ins := l_ins || CASE WHEN l_n > 1 THEN ',' END
                 || CASE WHEN MOD(l_n, 10) = 0 THEN CHR(10) END || l_col;
      END IF;
    END LOOP;
    IF l_n = 0 THEN
      RETURN;
    END IF;
    l_ins := 'INSERT INTO "' || p_tabla || '" (' || l_ins || ')' || CHR(10) || 'VALUES (';

    avance('Datos de ' || p_tabla);
    titulo('DATOS DE ' || p_tabla);
    l_cur := DBMS_SQL.OPEN_CURSOR;
    -- ORDER BY ROWID: el tramo siguiente tiene que encontrar las filas en el mismo orden.
    DBMS_SQL.PARSE(l_cur, 'SELECT ' || l_sel || ' FROM "' || p_tabla || '" ORDER BY ROWID'
      || CASE WHEN p_desde > 0 THEN ' OFFSET ' || p_desde || ' ROWS' END, DBMS_SQL.NATIVE);
    FOR i IN 1 .. l_n LOOP
      IF l_clase(i) = 'C' THEN
        DBMS_SQL.DEFINE_COLUMN(l_cur, i, l_clob);
      ELSE
        DBMS_SQL.DEFINE_COLUMN(l_cur, i, l_val, 32767);
      END IF;
    END LOOP;
    l_ign := DBMS_SQL.EXECUTE(l_cur);

    WHILE DBMS_SQL.FETCH_ROWS(l_cur) > 0 LOOP
      poner(l_ins);
      FOR i IN 1 .. l_n LOOP
        IF i > 1 THEN
          poner(',');
          cortar;
        END IF;
        IF l_clase(i) = 'E' THEN
          poner('EMPTY_BLOB()');
        ELSIF l_clase(i) = 'S' THEN
          poner('''' || c_sin_valor || '''');
        ELSIF l_clase(i) = 'C' THEN
          DBMS_SQL.COLUMN_VALUE(l_cur, i, l_clob);
          poner_clob_literal(l_clob);
        ELSE
          DBMS_SQL.COLUMN_VALUE(l_cur, i, l_val);
          IF l_val IS NULL THEN
            poner('NULL');
          ELSIF l_clase(i) = 'N' THEN
            poner(l_val);
          ELSIF l_clase(i) = 'T' THEN
            poner_texto(l_val);
          ELSIF l_clase(i) = 'D' THEN
            poner('TO_DATE(''' || l_val || ''',''YYYY-MM-DD HH24:MI:SS'')');
          ELSIF l_clase(i) = 'M' THEN
            poner('TO_TIMESTAMP(''' || l_val || ''',''YYYY-MM-DD HH24:MI:SS.FF9'')');
          ELSIF l_clase(i) = 'Z' THEN
            poner('TO_TIMESTAMP_TZ(''' || l_val || ''',''YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM'')');
          ELSE
            poner('HEXTORAW(''' || l_val || ''')');
          END IF;
        END IF;
      END LOOP;
      linea(');');
      l_filas := l_filas + 1;
      IF MOD(l_filas, 500) = 0 THEN
        linea('COMMIT;');
      END IF;
      IF MOD(l_filas, 5000) = 0 THEN
        avance('Datos de ' || p_tabla || ': ' || (p_desde + l_filas) || ' filas');
      END IF;
      IF MOD(l_filas, 200) = 0 AND sin_cpu THEN
        g_pausa := TRUE;
        EXIT;
      END IF;
      seguir_parte;
    END LOOP;
    DBMS_SQL.CLOSE_CURSOR(l_cur);
    linea('COMMIT;');
    g_filas := g_filas + l_filas;
    IF g_pausa THEN
      UPDATE ctell_backup_tarea
         SET desde_fila = p_desde + l_filas
       WHERE corrida = g_log AND orden = p_orden;
      COMMIT;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_cur IS NOT NULL AND DBMS_SQL.IS_OPEN(l_cur) THEN
        DBMS_SQL.CLOSE_CURSOR(l_cur);
      END IF;
      IF cancelada(SQLCODE) THEN
        RAISE;
      END IF;
      g_errores := g_errores + 1;
      linea('-- ERROR en los datos de ' || p_tabla || ': ' || SUBSTR(SQLERRM, 1, 200));
      anotar('ERROR en los datos de ' || p_tabla || ': ' || SUBSTR(SQLERRM, 1, 200));
  END datos_tabla;

  ------------------------------------------------------------------------------
  -- ARCHIVOS: los BLOB que sólo existen en esta base (logos de empresa, fotos de
  -- denominación y lo cargado antes de pasar a Cloudinary), como bloques que restauran con
  -- el mismo @script que todo lo demás. Sale el doble en hexadecimal, pero la cuota del
  -- esquema son 25 MB y el zip recupera buena parte.
  --
  -- Cada bloque es independiente, así que el contenido de una fila se puede partir entre
  -- dos partes. Para identificar la fila hace falta una clave primaria numérica: sin ella
  -- no se copia y el resumen queda CON ERRORES.
  ------------------------------------------------------------------------------

  PROCEDURE archivos_columna(p_orden IN NUMBER, p_tabla IN VARCHAR2, p_columna IN VARCHAR2,
                             p_desde IN NUMBER) IS
    c_trozo    CONSTANT PLS_INTEGER := 8000;
    l_tabla    VARCHAR2(140) := '"' || p_tabla || '"';
    l_col      VARCHAR2(140) := '"' || p_columna || '"';
    l_cond_sql VARCHAR2(4000);   -- la expresión que, en cada fila, arma su WHERE
    l_cond     VARCHAR2(4000);
    l_bin      BLOB;
    l_cur      INTEGER;
    l_ign      INTEGER;
    l_filas    NUMBER := 0;
    l_pos      NUMBER;
    l_len      NUMBER;
    l_hex      VARCHAR2(32767);
  BEGIN
    FOR k IN (SELECT cc.column_name, tc.data_type
                FROM user_constraints c
                JOIN user_cons_columns cc ON cc.constraint_name = c.constraint_name
                JOIN user_tab_cols tc ON tc.table_name = c.table_name
                                     AND tc.column_name = cc.column_name
               WHERE c.table_name = p_tabla AND c.constraint_type = 'P'
               ORDER BY cc.position) LOOP
      IF k.data_type <> 'NUMBER' THEN
        l_cond_sql := NULL;
        EXIT;
      END IF;
      l_cond_sql := l_cond_sql || CASE WHEN l_cond_sql IS NOT NULL THEN ' || '' AND '' || ' END
                    || '''"' || k.column_name || '" = '' || TO_CHAR("' || k.column_name
                    || '", ''TM9'', ''NLS_NUMERIC_CHARACTERS=''''.,'''''')';
    END LOOP;
    IF l_cond_sql IS NULL THEN
      g_errores := g_errores + 1;
      linea('-- ERROR en los archivos de ' || p_tabla || '.' || p_columna || ': sin clave numérica');
      anotar('Sin copiar (sin clave primaria numérica): ' || p_tabla || '.' || p_columna);
      RETURN;
    END IF;

    avance('Archivos de ' || p_tabla || '.' || p_columna);
    titulo('ARCHIVOS DE ' || p_tabla || '.' || p_columna);
    l_cur := DBMS_SQL.OPEN_CURSOR;
    DBMS_SQL.PARSE(l_cur, 'SELECT ' || l_cond_sql || ', ' || l_col || ' FROM ' || l_tabla
      || ' WHERE DBMS_LOB.GETLENGTH(' || l_col || ') > 0 ORDER BY ROWID'
      || CASE WHEN p_desde > 0 THEN ' OFFSET ' || p_desde || ' ROWS' END, DBMS_SQL.NATIVE);
    DBMS_SQL.DEFINE_COLUMN(l_cur, 1, l_cond, 4000);
    DBMS_SQL.DEFINE_COLUMN(l_cur, 2, l_bin);
    l_ign := DBMS_SQL.EXECUTE(l_cur);

    WHILE DBMS_SQL.FETCH_ROWS(l_cur) > 0 LOOP
      DBMS_SQL.COLUMN_VALUE(l_cur, 1, l_cond);
      DBMS_SQL.COLUMN_VALUE(l_cur, 2, l_bin);
      linea('UPDATE ' || l_tabla || ' SET ' || l_col || ' = EMPTY_BLOB() WHERE ' || l_cond || ';');
      l_pos := 1;
      l_len := DBMS_LOB.GETLENGTH(l_bin);
      WHILE l_pos <= l_len LOOP
        l_hex := RAWTOHEX(DBMS_LOB.SUBSTR(l_bin, c_trozo, l_pos));
        linea('DECLARE b BLOB; BEGIN');
        linea('SELECT ' || l_col || ' INTO b FROM ' || l_tabla || ' WHERE ' || l_cond || ' FOR UPDATE;');
        poner('DBMS_LOB.WRITEAPPEND(b, ' || (LENGTH(l_hex) / 2) || ', HEXTORAW(');
        poner_texto(l_hex);
        linea('));');
        linea('END;');
        linea('/');
        l_pos := l_pos + c_trozo;
        seguir_parte;
      END LOOP;
      linea('COMMIT;');
      l_filas := l_filas + 1;
      IF sin_cpu THEN
        g_pausa := TRUE;
        EXIT;
      END IF;
    END LOOP;
    DBMS_SQL.CLOSE_CURSOR(l_cur);

    IF g_pausa THEN
      UPDATE ctell_backup_tarea
         SET desde_fila = p_desde + l_filas
       WHERE corrida = g_log AND orden = p_orden;
      COMMIT;
    ELSIF p_desde + l_filas > 0 THEN
      anotar('Archivos de ' || p_tabla || '.' || p_columna || ': ' || (p_desde + l_filas));
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_cur IS NOT NULL AND DBMS_SQL.IS_OPEN(l_cur) THEN
        DBMS_SQL.CLOSE_CURSOR(l_cur);
      END IF;
      IF cancelada(SQLCODE) THEN
        RAISE;
      END IF;
      g_errores := g_errores + 1;
      linea('-- ERROR en los archivos de ' || p_tabla || '.' || p_columna || ': ' || SUBSTR(SQLERRM, 1, 200));
      anotar('ERROR en los archivos de ' || p_tabla || '.' || p_columna || ': ' || SUBSTR(SQLERRM, 1, 200));
  END archivos_columna;

  ------------------------------------------------------------------------------
  -- LOS TRAMOS: la lista de lo que hay que hacer, y cada job hace lo que le alcanza
  ------------------------------------------------------------------------------

  PROCEDURE armar_tareas IS
    l_orden NUMBER := 0;

    CURSOR c_tablas IS
      SELECT table_name FROM user_tables
       WHERE temporary = 'N' AND nested = 'NO' AND secondary = 'N' AND dropped = 'NO'
         AND (iot_type IS NULL OR iot_type = 'IOT')
         AND table_name NOT LIKE '%$%'
         AND NOT REGEXP_LIKE(table_name, c_sin_datos)
         AND table_name NOT IN (SELECT mview_name FROM user_mviews)
         AND table_name NOT IN (SELECT table_name FROM user_external_tables)
       ORDER BY table_name;

    PROCEDURE agregar(p_etapa IN VARCHAR2, p_seccion IN VARCHAR2, p_accion IN VARCHAR2,
                      p_tipo IN VARCHAR2 DEFAULT NULL, p_nombre IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
      l_orden := l_orden + 1;
      INSERT INTO ctell_backup_tarea (corrida, orden, etapa, seccion, accion, tipo, nombre)
      VALUES (g_log, l_orden, p_etapa, p_seccion, p_accion, p_tipo, p_nombre);
    END agregar;

    PROCEDURE objetos(p_titulo IN VARCHAR2, p_tipo_dic IN VARCHAR2, p_tipo_meta IN VARCHAR2) IS
    BEGIN
      FOR o IN (SELECT object_name FROM user_objects
                 WHERE object_type = p_tipo_dic
                   AND generated = 'N'
                   AND object_name NOT LIKE '%$%'
                 ORDER BY object_name) LOOP
        agregar('estructura', p_titulo, 'DDL', p_tipo_meta, o.object_name);
      END LOOP;
    END objetos;
  BEGIN
    FOR s IN (SELECT sequence_name FROM user_sequences
               WHERE sequence_name NOT LIKE 'ISEQ$$%' ORDER BY sequence_name) LOOP
      agregar('estructura', 'SECUENCIAS', 'DDL', 'SEQUENCE', s.sequence_name);
    END LOOP;

    objetos('TIPOS', 'TYPE', 'TYPE_SPEC');

    FOR t IN (SELECT table_name FROM user_tables
               WHERE nested = 'NO' AND secondary = 'N' AND dropped = 'NO'
                 AND (iot_type IS NULL OR iot_type = 'IOT')
                 AND table_name NOT LIKE '%$%'
                 AND table_name NOT IN (SELECT mview_name FROM user_mviews)
               ORDER BY table_name) LOOP
      agregar('estructura', 'TABLAS (con PK, UK, CHECK y NOT NULL)', 'DDL', 'TABLE', t.table_name);
      agregar('estructura', 'TABLAS (con PK, UK, CHECK y NOT NULL)', 'DEP', 'COMMENT', t.table_name);
    END LOOP;

    FOR i IN (SELECT i.index_name FROM user_indexes i
               WHERE i.generated = 'N'
                 AND i.index_type NOT IN ('LOB', 'IOT - TOP')
                 AND i.table_name NOT LIKE '%$%'
                 AND NOT EXISTS (SELECT 1 FROM user_constraints c WHERE c.index_name = i.index_name)
               ORDER BY i.index_name) LOOP
      agregar('estructura', 'ÍNDICES', 'DDL', 'INDEX', i.index_name);
    END LOOP;

    objetos('VISTAS', 'VIEW', 'VIEW');
    objetos('FUNCIONES', 'FUNCTION', 'FUNCTION');
    objetos('PROCEDIMIENTOS', 'PROCEDURE', 'PROCEDURE');
    objetos('PAQUETES', 'PACKAGE', 'PACKAGE_SPEC');
    objetos('CUERPOS DE PAQUETES', 'PACKAGE BODY', 'PACKAGE_BODY');
    objetos('CUERPOS DE TIPOS', 'TYPE BODY', 'TYPE_BODY');
    objetos('VISTAS MATERIALIZADAS', 'MATERIALIZED VIEW', 'MATERIALIZED_VIEW');
    objetos('TRIGGERS', 'TRIGGER', 'TRIGGER');

    FOR t IN (SELECT DISTINCT table_name FROM user_constraints
               WHERE constraint_type = 'R' AND table_name NOT LIKE '%$%' ORDER BY table_name) LOOP
      agregar('estructura', 'CLAVES FORÁNEAS', 'DEP', 'REF_CONSTRAINT', t.table_name);
    END LOOP;

    objetos('SINÓNIMOS', 'SYNONYM', 'SYNONYM');

    -- Sin los jobs de las corridas: al restaurar dispararían una copia y sus correos.
    FOR j IN (SELECT job_name FROM user_scheduler_jobs
               WHERE job_name NOT LIKE 'BACKUP_MANUAL%' AND job_name NOT LIKE 'BACKUP_TRAMO%'
               ORDER BY job_name) LOOP
      agregar('estructura', 'JOBS', 'DDL', 'PROCOBJ', j.job_name);
    END LOOP;

    agregar('ords', NULL, 'EXPORTAR');

    agregar('datos', NULL, 'PREPARAR');
    FOR t IN c_tablas LOOP
      agregar('datos', NULL, 'DATOS', NULL, t.table_name);
    END LOOP;

    -- Con los triggers todavía apagados: el UPDATE del contenido no tiene que moverle
    -- FECHA_ACTUALIZACION a nadie. La última tarea, la que los vuelve a prender, va acá.
    FOR t IN c_tablas LOOP
      FOR b IN (SELECT column_name FROM user_tab_cols
                 WHERE table_name = t.table_name AND data_type = 'BLOB' AND hidden_column = 'NO'
                 ORDER BY column_id) LOOP
        agregar('archivos', NULL, 'ARCHIVO', b.column_name, t.table_name);
      END LOOP;
    END LOOP;
    agregar('archivos', NULL, 'TERMINAR');
    COMMIT;
  END armar_tareas;

  PROCEDURE programar_tramo IS
  BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
      job_name   => DBMS_SCHEDULER.GENERATE_JOB_NAME('BACKUP_TRAMO_'),
      job_type   => 'PLSQL_BLOCK',
      job_action => 'BEGIN PKG_BACKUP_CTELL.continuar(' || g_log || '); END;',
      start_date => SYSTIMESTAMP,
      enabled    => TRUE,
      auto_drop  => TRUE);
  END programar_tramo;

  PROCEDURE terminar IS
    l_estado VARCHAR2(20) := CASE WHEN g_errores > 0 THEN 'CON ERRORES' ELSE 'OK' END;
    l_cuerpo VARCHAR2(4000);
  BEGIN
    log_fin(g_log, l_estado);
    l_cuerpo := SUBSTRB('Backup del ' || g_fecha || ': ' || l_estado || CHR(10)
      || CASE WHEN g_errores > 0 THEN 'ATENCIÓN: esta copia NO está completa. Ver el detalle.' || CHR(10) END
      || 'Partes: ' || g_n || CHR(10)
      || 'Tablas: ' || g_tablas || CHR(10)
      || 'Filas: ' || g_filas || CHR(10)
      || 'Comprimido: ' || ROUND(g_b_zip / 1048576, 1) || ' MB (sin comprimir: '
      || ROUND(g_b_sql / 1048576, 1) || ' MB)' || CHR(10) || CHR(10)
      || 'Para restaurar: correr las partes en orden de número, con SQLcl o SQL*Plus.' || CHR(10)
      || 'No incluye las claves ni las contraseñas, ni lo que está en Cloudinary.' || CHR(10)
      || CASE WHEN g_detalle IS NOT NULL THEN CHR(10) || 'Detalle:' || CHR(10) || g_detalle END, 1, 4000);
    IF g_enviar THEN
      enviar('Backup CTELL ' || g_fecha || ': ' || l_estado || ', ' || g_n || ' partes', l_cuerpo);
      empujar_cola;
    END IF;
    DELETE FROM ctell_backup_tarea WHERE corrida = g_log;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE(l_cuerpo);
  END terminar;

  -- Hace tareas hasta agotar la CPU del tramo. Cada parte se cierra (y se manda) dentro
  -- del tramo: entre un job y otro no sobrevive nada que esté en memoria.
  PROCEDURE tramo IS
    l_abierta BOOLEAN := FALSE;
    l_etapa   VARCHAR2(20);
    l_seccion VARCHAR2(60);
    l_quedan  PLS_INTEGER;
  BEGIN
    g_cpu_max := presupuesto_cpu;
    g_pausa   := FALSE;
    preparar_metadata;

    FOR t IN (SELECT orden, etapa, seccion, accion, tipo, nombre, desde_fila
                FROM ctell_backup_tarea
               WHERE corrida = g_log
               ORDER BY orden) LOOP
      IF sin_cpu THEN
        g_pausa := TRUE;
        EXIT;
      END IF;
      IF NOT l_abierta OR t.etapa <> l_etapa THEN
        IF l_abierta THEN
          cerrar_parte;
        END IF;
        abrir_parte(t.etapa);
        l_abierta := TRUE;
        l_etapa   := t.etapa;
        l_seccion := NULL;
      END IF;
      IF t.seccion IS NOT NULL AND (l_seccion IS NULL OR t.seccion <> l_seccion) THEN
        titulo(t.seccion);
        l_seccion := t.seccion;
      END IF;

      IF t.accion = 'DDL' THEN
        ddl(t.tipo, t.nombre);
        IF t.tipo = 'TABLE' THEN
          g_tablas := g_tablas + 1;
        END IF;
      ELSIF t.accion = 'DEP' THEN
        ddl(t.tipo, t.nombre, TRUE);
      ELSIF t.accion = 'EXPORTAR' THEN
        exportar_ords;
      ELSIF t.accion = 'PREPARAR' THEN
        preparar_restauracion;
      ELSIF t.accion = 'DATOS' THEN
        datos_tabla(t.orden, t.nombre, t.desde_fila);
      ELSIF t.accion = 'ARCHIVO' THEN
        archivos_columna(t.orden, t.nombre, t.tipo, t.desde_fila);
      ELSE
        terminar_restauracion;
      END IF;

      EXIT WHEN g_pausa;  -- la tabla quedó a medias: esta tarea sigue pendiente
      DELETE FROM ctell_backup_tarea WHERE corrida = g_log AND orden = t.orden;
      COMMIT;
    END LOOP;

    IF l_abierta THEN
      cerrar_parte;
    END IF;

    SELECT COUNT(*) INTO l_quedan FROM ctell_backup_tarea WHERE corrida = g_log;
    IF l_quedan > 0 THEN
      avance('Sigue en otro tramo. Faltan ' || l_quedan || ' tareas');
      programar_tramo;
    ELSE
      terminar;
    END IF;
  END tramo;

  PROCEDURE leer_config IS
  BEGIN
    g_tope    := NVL(TO_NUMBER(config('PARTE_MB', '30')), 30) * 1048576;
    g_destino := config('DESTINO');
    g_desde   := config('REMITENTE');
  END leer_config;

  -- Después de un ORA-02393 ya no se puede escribir nada: el motivo queda igual en
  -- USER_SCHEDULER_JOB_RUN_DETAILS y la corrida siguiente la marca INTERRUMPIDA.
  PROCEDURE registrar_corte(p_msg IN VARCHAR2) IS
  BEGIN
    anotar('La copia se cortó: ' || p_msg);
    BEGIN
      ROLLBACK;
      log_fin(g_log, 'ERROR');
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;
    IF g_enviar AND g_destino IS NOT NULL THEN
      BEGIN
        enviar('Backup CTELL ' || g_fecha || ': ERROR, la copia NO se completó',
               'La copia se cortó: ' || p_msg || CHR(10) || CHR(10) || g_detalle);
        empujar_cola;
      EXCEPTION
        WHEN OTHERS THEN NULL;  -- sin correo, igual queda en CTELL_BACKUP_LOG
      END;
    END IF;
  END registrar_corte;

  ------------------------------------------------------------------------------
  -- LO PÚBLICO
  ------------------------------------------------------------------------------

  PROCEDURE ejecutar(p_enviar IN BOOLEAN DEFAULT TRUE) IS
  BEGIN
    g_cpu0   := DBMS_UTILITY.GET_CPU_TIME;
    g_enviar := p_enviar;
    g_n := 0; g_errores := 0; g_detalle := NULL; g_tablas := 0; g_filas := 0;
    g_b_sql := 0; g_b_zip := 0;
    g_fecha := TO_CHAR(ahora, 'YYYY-MM-DD');
    leer_config;

    g_log := log_inicio(p_enviar);
    IF p_enviar AND g_destino IS NULL THEN
      anotar('Falta la casilla: PKG_BACKUP_CTELL.fijar_destino.');
      log_fin(g_log, 'ERROR');
      RAISE_APPLICATION_ERROR(-20001, 'Falta la casilla: PKG_BACKUP_CTELL.fijar_destino.');
    END IF;

    armar_tareas;
    tramo;
  EXCEPTION
    WHEN OTHERS THEN
      DECLARE
        l_msg VARCHAR2(1000) := SUBSTRB(SQLERRM, 1, 1000);
        l_cod NUMBER := SQLCODE;
      BEGIN
        IF l_cod <> -20001 THEN
          registrar_corte(l_msg);
        END IF;
        RAISE_APPLICATION_ERROR(-20002, 'Backup: ' || l_msg);
      END;
  END ejecutar;

  PROCEDURE continuar(p_id IN NUMBER) IS
    l_enviado CHAR(1);
    l_inicio  DATE;
  BEGIN
    g_cpu0 := DBMS_UTILITY.GET_CPU_TIME;
    g_log  := p_id;
    SELECT enviado, inicio, NVL(partes, 0), NVL(tablas, 0), NVL(filas, 0),
           NVL(bytes_script, 0), NVL(bytes_zip, 0), NVL(errores, 0), detalle
      INTO l_enviado, l_inicio, g_n, g_tablas, g_filas, g_b_sql, g_b_zip, g_errores, g_detalle
      FROM ctell_backup_log
     WHERE id = p_id;
    g_enviar := l_enviado = 'S';
    g_fecha  := TO_CHAR(l_inicio, 'YYYY-MM-DD');
    leer_config;
    tramo;
  EXCEPTION
    WHEN OTHERS THEN
      DECLARE
        l_msg VARCHAR2(1000) := SUBSTRB(SQLERRM, 1, 1000);
      BEGIN
        registrar_corte(l_msg);
        RAISE_APPLICATION_ERROR(-20002, 'Backup: ' || l_msg);
      END;
  END continuar;

  PROCEDURE lanzar(p_enviar IN BOOLEAN DEFAULT TRUE) IS
    l_corriendo PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO l_corriendo FROM user_scheduler_jobs
     WHERE state IN ('SCHEDULED', 'RUNNING')
       AND (job_name LIKE 'BACKUP_MANUAL%' OR job_name LIKE 'BACKUP_TRAMO%')
        OR (job_name = 'JOB_BACKUP_CTELL' AND state = 'RUNNING');
    IF l_corriendo > 0 THEN
      RAISE_APPLICATION_ERROR(-20004, 'Ya hay una copia corriendo: ver USER_SCHEDULER_JOBS.');
    END IF;
    DBMS_SCHEDULER.CREATE_JOB(
      job_name   => DBMS_SCHEDULER.GENERATE_JOB_NAME('BACKUP_MANUAL_'),
      job_type   => 'PLSQL_BLOCK',
      job_action => 'BEGIN PKG_BACKUP_CTELL.ejecutar(p_enviar => '
                    || CASE WHEN p_enviar THEN 'TRUE' ELSE 'FALSE' END
                    || '); END;',
      start_date => SYSTIMESTAMP,
      enabled    => TRUE,
      auto_drop  => TRUE);
    DBMS_OUTPUT.PUT_LINE('[OK] Corriendo en segundo plano. Ver: '
                         || 'SELECT * FROM ctell_backup_log ORDER BY id DESC');
  END lanzar;

  PROCEDURE fijar_destino(p_correo IN VARCHAR2, p_remitente IN VARCHAR2 DEFAULT NULL) IS
    PROCEDURE guardar(p_clave IN VARCHAR2, p_valor IN VARCHAR2) IS
    BEGIN
      MERGE INTO ctell_backup_config t
      USING (SELECT p_clave AS clave, p_valor AS valor FROM dual) s
         ON (t.clave = s.clave)
       WHEN MATCHED THEN UPDATE SET t.valor = s.valor
       WHEN NOT MATCHED THEN INSERT (clave, valor) VALUES (s.clave, s.valor);
    END guardar;
  BEGIN
    IF NOT REGEXP_LIKE(TRIM(p_correo), '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') THEN
      RAISE_APPLICATION_ERROR(-20003, 'Esa casilla no parece válida.');
    END IF;
    guardar('DESTINO', TRIM(p_correo));
    guardar('REMITENTE', TRIM(p_remitente));
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('[OK] Casilla guardada.');
  END fijar_destino;

  PROCEDURE probar_correo IS
    l_zip BLOB;
    l_bin BLOB;
    l_do  INTEGER := 1;
    l_so  INTEGER := 1;
    l_ctx INTEGER := DBMS_LOB.DEFAULT_LANG_CTX;
    l_w   INTEGER;
    l_txt CLOB := TO_CLOB('-- Prueba del backup de CTELL: si lo podés abrir, el adjunto llegó bien.');
  BEGIN
    g_destino := config('DESTINO');
    g_desde   := config('REMITENTE');
    IF g_destino IS NULL THEN
      DBMS_OUTPUT.PUT_LINE('[ERROR] Falta la casilla: PKG_BACKUP_CTELL.fijar_destino.');
      RETURN;
    END IF;
    DBMS_LOB.CREATETEMPORARY(l_bin, TRUE, DBMS_LOB.SESSION);
    DBMS_LOB.CONVERTTOBLOB(l_bin, l_txt, DBMS_LOB.LOBMAXSIZE, l_do, l_so,
                           NLS_CHARSET_ID('AL32UTF8'), l_ctx, l_w);
    APEX_ZIP.ADD_FILE(p_zipped_blob => l_zip, p_file_name => 'prueba.sql', p_content => l_bin);
    APEX_ZIP.FINISH(p_zipped_blob => l_zip);
    enviar('Prueba del backup de CTELL',
           'Si llegó este correo con prueba.zip adjunto, el backup puede enviarse.',
           l_zip, 'prueba.zip');
    empujar_cola;
    DBMS_OUTPUT.PUT_LINE('[OK] Correo en cola. Si no llega en unos minutos, mirar APEX_MAIL_QUEUE y APEX_MAIL_LOG.');
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('[ERROR] No se pudo mandar: ' || SQLERRM);
  END probar_correo;

END PKG_BACKUP_CTELL;
/

-- El job de la madrugada. La hora se calcula en la zona de start_date, no en la del servidor.
-- Arranca MAÑANA: con el start_date en una hora que ya pasó, Oracle puede largarlo apenas se
-- crea, y reejecutar este archivo a media tarde no tiene que disparar una copia con sus correos.
BEGIN
  BEGIN
    DBMS_SCHEDULER.DROP_JOB('JOB_BACKUP_CTELL', force => TRUE);
  EXCEPTION
    WHEN OTHERS THEN NULL;
  END;
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_BACKUP_CTELL',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN PKG_BACKUP_CTELL.ejecutar; END;',
    start_date      => TO_TIMESTAMP_TZ(TO_CHAR((SYSTIMESTAMP AT TIME ZONE '-03:00') + INTERVAL '1' DAY, 'YYYY-MM-DD')
                                       || ' 03:00:00 -03:00', 'YYYY-MM-DD HH24:MI:SS TZH:TZM'),
    repeat_interval => 'FREQ=DAILY;BYHOUR=3;BYMINUTE=0;BYSECOND=0',
    enabled         => TRUE,
    auto_drop       => FALSE,
    comments        => 'Backup completo por correo. Ver db/backup.sql');
END;
/

--------------------------------------------------------------------------------
-- Verificación: un paquete INVALID no hace ruido hasta la madrugada, y ahí no avisa nadie.
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME IN ('PKG_BACKUP_CTELL', 'JOB_BACKUP_CTELL')
 ORDER BY OBJECT_NAME, OBJECT_TYPE;

SELECT NAME, TYPE, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_BACKUP_CTELL'
 ORDER BY TYPE, SEQUENCE;

SELECT CLAVE, VALOR FROM CTELL_BACKUP_CONFIG ORDER BY CLAVE;
