--------------------------------------------------------------------------------
-- CTELL · ASISTENCIAS DE PROFESORES (REPORTE)
--
-- Requiere db/auth.sql, PROFESORES e INSTITUCIONES, y el DDL de
-- ASISTENCIAS_PROFESORES con la columna ID_EMPRESA.
--
-- Endpoints: /asistencias-profesores/listar
--
-- ES SOLO LECTURA. La marcacion la hace la app del profesor, no este modulo:
-- aca no hay INSERTAR, ACTUALIZAR ni ELIMINAR a proposito. Un ABM permitiria
-- editar a mano una marcacion con GPS y hora de origen, que es justamente el
-- dato que hace confiable al registro.
--
--------------------------------------------------------------------------------
-- LOS IMPORTES NO SE CALCULAN ACA
--
-- El precio por hora y la duracion de la hora catedra NO son columnas de
-- ninguna tabla: se cargan en la pantalla del reporte y los totales se calculan
-- en el frontend. Este paquete devuelve MINUTOS TRABAJADOS y nada de plata.
--
-- Es deliberado: guardar un precio por hora aca lo congelaria por profesor,
-- cuando en la practica cambia por institucion, por periodo y por acuerdo. Si
-- algun dia se formaliza, va en su propia tabla de tarifas con vigencia —el
-- mismo criterio que LISTAS_DESCUENTOS— y no como una columna suelta.
--
--------------------------------------------------------------------------------
-- FILTRO POR EMPRESA
--
-- La tabla tiene ID_EMPRESA, pero es NULLABLE: las filas cargadas antes de que
-- existiera la columna la tienen en NULL. Por eso el filtro mira TAMBIEN la
-- empresa del profesor, que es la fuente real:
--
--   (a.ID_EMPRESA = l_empresa OR (a.ID_EMPRESA IS NULL AND p.ID_EMPRESA = l_empresa))
--
-- Con solo a.ID_EMPRESA, las asistencias historicas desaparecerian del reporte
-- sin ningun error visible.
--
--------------------------------------------------------------------------------
-- UNA FILA POR MARCACION, NO POR DIA
--
-- El UNIQUE es sobre CLAVE_ENTRADA / CLAVE_SALIDA, no sobre (profesor, fecha):
-- un profesor puede entrar y salir varias veces el mismo dia. El reporte las
-- agrupa por fecha en el frontend, que es donde se arma la grilla.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_ASISTENCIAS_PROFESORES AS

  -- Marcaciones de un periodo. Todos los filtros son opcionales salvo la
  -- empresa: sin anio ni mes devuelve todo, que con muchos profesores es mucho
  -- — la pantalla siempre manda los dos.
  PROCEDURE LISTAR (
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_anio           IN  VARCHAR2,
    p_mes            IN  VARCHAR2,
    p_id_profesor    IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  );

  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_ASISTENCIAS_PROFESORES;
/

CREATE OR REPLACE PACKAGE BODY PKG_ASISTENCIAS_PROFESORES AS

  ------------------------------------------------------------------------------
  -- Privado: borra el modulo ORDS si existe, reintentando ante un interbloqueo.
  -- Nunca `WHEN OTHERS THEN NULL`: se tragaria un ORA-00060 y el DEFINE_MODULE
  -- de despues moriria con ORA-00001 contra el modulo que no se llego a borrar.
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
         WHERE NAME = 'asistencias-profesores';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'asistencias-profesores');
        COMMIT;  -- Libera los locks antes de que DEFINE_MODULE los vuelva a pedir.
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
          -- ORA-00060 (interbloqueo) y ORA-04020 (lock de objeto) son
          -- transitorios: la otra sesion termina y el reintento pasa.
          --
          -- DBMS_SESSION.SLEEP y NO DBMS_LOCK.SLEEP: este workspace no tiene
          -- GRANT EXECUTE sobre SYS.DBMS_LOCK, y usarlo hace que el BODY no
          -- compile con PLS-00201. Es el mismo helper que usan los demas
          -- archivos de db/.
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
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_anio           IN  VARCHAR2,
    p_mes            IN  VARCHAR2,
    p_id_profesor    IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_empresa     NUMBER;
    l_anio        NUMBER;
    l_mes         NUMBER;
    l_profesor    NUMBER;
    l_institucion NUMBER;
    l_desde       DATE;
    l_hasta       DATE;
    l_total       NUMBER;
    l_items       CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van DENTRO del BEGIN: en el DECLARE correrian antes de
    -- que exista el EXCEPTION y el error escaparia del procedimiento. NULLIF
    -- convierte la cadena vacia del parametro ausente en NULL antes de que
    -- TO_NUMBER la toque (si no, ORA-01722).
    l_empresa     := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_anio        := TO_NUMBER(NULLIF(p_anio, ''));
    l_mes         := TO_NUMBER(NULLIF(p_mes, ''));
    l_profesor    := TO_NUMBER(NULLIF(p_id_profesor, ''));
    l_institucion := TO_NUMBER(NULLIF(p_id_institucion, ''));

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- El rango se arma una vez y se compara con >= / <, en vez de poner
    -- EXTRACT(YEAR FROM a.FECHA_ASISTENCIA) en el WHERE: una funcion sobre la
    -- columna anula el indice IDX_ASISTENCIAS_FECHA y obliga a leer la tabla
    -- entera.
    IF l_anio IS NOT NULL THEN
      IF l_mes IS NOT NULL THEN
        IF l_mes < 1 OR l_mes > 12 THEN
          p_status_code := 400;
          p_resultado := '{"error":"El mes debe estar entre 1 y 12"}';
          RETURN;
        END IF;
        l_desde := TO_DATE(LPAD(TO_CHAR(l_anio), 4, '0') || LPAD(TO_CHAR(l_mes), 2, '0') || '01', 'YYYYMMDD');
        l_hasta := ADD_MONTHS(l_desde, 1);
      ELSE
        l_desde := TO_DATE(LPAD(TO_CHAR(l_anio), 4, '0') || '0101', 'YYYYMMDD');
        l_hasta := ADD_MONTHS(l_desde, 12);
      END IF;
    END IF;

    SELECT COUNT(*)
      INTO l_total
      FROM ASISTENCIAS_PROFESORES a
      JOIN PROFESORES p ON p.ID_PROFESOR = a.ID_PROFESOR
     WHERE (a.ID_EMPRESA = l_empresa OR (a.ID_EMPRESA IS NULL AND p.ID_EMPRESA = l_empresa))
       AND (l_desde IS NULL OR (a.FECHA_ASISTENCIA >= l_desde AND a.FECHA_ASISTENCIA < l_hasta))
       AND (l_profesor IS NULL OR a.ID_PROFESOR = l_profesor)
       AND (l_institucion IS NULL OR a.ID_INSTITUCION = l_institucion);

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY fecha, entrada NULLS LAST RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'               VALUE a.ID_ASISTENCIA,
                 'idProfesor'       VALUE a.ID_PROFESOR,
                 -- El nombre viene del JOIN: sin el, el frontend tendria que
                 -- resolverlo con otra peticion por cada fila.
                 'profesor'         VALUE p.NOMBRE || NVL2(p.APELLIDO, ' ' || p.APELLIDO, ''),
                 'numeroCi'         VALUE p.NUMERO_CI,
                 'idInstitucion'    VALUE a.ID_INSTITUCION,
                 'institucion'      VALUE i.NOMBRE_INSTITUCION,
                 -- Formato ISO explicito: un DATE crudo sale en el JSON con el
                 -- formato NLS de la sesion ('20-AGO-24'), que `new Date()` no
                 -- parsea y deja "Invalid Date" en pantalla.
                 'fecha'            VALUE TO_CHAR(a.FECHA_ASISTENCIA, 'YYYY-MM-DD'),
                 'horaEntrada'      VALUE TO_CHAR(a.HORA_ENTRADA, 'HH24:MI'),
                 'horaSalida'       VALUE TO_CHAR(a.HORA_SALIDA, 'HH24:MI'),
                 -- MINUTOS y no horas decimales: la division la hace el
                 -- frontend, que es quien conoce la duracion de la hora catedra
                 -- que el usuario cargo en pantalla. Redondear aca a dos
                 -- decimales perderia precision al sumar el mes.
                 --
                 -- NULL —y no 0— cuando falta una de las dos marcas: una
                 -- entrada sin salida es un registro INCOMPLETO, no una jornada
                 -- de cero minutos, y la pantalla lo tiene que poder distinguir
                 -- para marcarlo.
                 'minutos'          VALUE CASE
                                            WHEN a.HORA_ENTRADA IS NOT NULL
                                             AND a.HORA_SALIDA  IS NOT NULL
                                            THEN ROUND((CAST(a.HORA_SALIDA AS DATE)
                                                      - CAST(a.HORA_ENTRADA AS DATE)) * 1440)
                                          END,
                 -- Auditoria de la app movil. 'S' si la marca se tomo sin
                 -- conexion y se sincronizo despues: esa hora es la del
                 -- telefono, no la del servidor.
                 'entradaOffline'   VALUE CASE UPPER(TRIM(a.ENTRADA_OFFLINE)) WHEN 'S' THEN 'S' ELSE 'N' END,
                 'salidaOffline'    VALUE CASE UPPER(TRIM(a.SALIDA_OFFLINE))  WHEN 'S' THEN 'S' ELSE 'N' END,
                 'marcadoEnEntrada' VALUE a.MARCADO_EN_ENTRADA,
                 'marcadoEnSalida'  VALUE a.MARCADO_EN_SALIDA,
                 -- Coordenadas como texto, tal como estan en la tabla: son
                 -- VARCHAR2(50), y convertirlas a numero aca solo agregaria una
                 -- forma de fallar con un dato que la pantalla usa para armar
                 -- un enlace a un mapa.
                 'latitud'          VALUE a.LATITUD,
                 'longitud'         VALUE a.LONGITUD,
                 'latitudSalida'    VALUE a.LATITUD_SALIDA,
                 'longitudSalida'   VALUE a.LONGITUD_SALIDA
                 RETURNING CLOB
               ) AS fila,
               a.FECHA_ASISTENCIA AS fecha,
               a.HORA_ENTRADA     AS entrada
          FROM ASISTENCIAS_PROFESORES a
          JOIN PROFESORES p ON p.ID_PROFESOR = a.ID_PROFESOR
          -- LEFT en INSTITUCIONES: ID_INSTITUCION es NOT NULL, pero si alguna
          -- fila apunta a una institucion borrada, un JOIN interno la haria
          -- desaparecer del reporte sin ningun aviso.
          LEFT JOIN INSTITUCIONES i ON i.ID_INSTITUCION = a.ID_INSTITUCION
         WHERE (a.ID_EMPRESA = l_empresa OR (a.ID_EMPRESA IS NULL AND p.ID_EMPRESA = l_empresa))
           AND (l_desde IS NULL OR (a.FECHA_ASISTENCIA >= l_desde AND a.FECHA_ASISTENCIA < l_hasta))
           AND (l_profesor IS NULL OR a.ID_PROFESOR = l_profesor)
           AND (l_institucion IS NULL OR a.ID_INSTITUCION = l_institucion)
      );

    p_status_code := 200;
    -- SELECT ... INTO y no una asignacion directa: `RETURNING CLOB` no se
    -- acepta en una expresion PL/SQL suelta (PLS-00684).
    --
    -- NVL sobre l_items: JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un
    -- array vacio, y el frontend reventaria al iterar "items":null.
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
      APEX_DEBUG.ERROR('PKG_ASISTENCIAS_PROFESORES.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las asistencias"}';
  END LISTAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'asistencias-profesores',
      p_base_path      => '/asistencias-profesores/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Reporte de asistencias de profesores (solo lectura)'
    );

    -- ORIGINS_ALLOWED es POR MODULO, no del workspace: sin esto ORDS rechaza la
    -- peticion cross-origin ANTES del handler, con un "Service Unavailable" que
    -- ningun WHEN OTHERS puede capturar.
    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'asistencias-profesores',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /asistencias-profesores/listar?idEmpresa=&anio=&mes=&idProfesor=&idInstitucion=
    --
    -- Los query params se vinculan solos al bind del mismo nombre; no se
    -- declaran con DEFINE_PARAMETER.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'asistencias-profesores', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'asistencias-profesores',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ASISTENCIAS_PROFESORES.LISTAR(:authorization, :idEmpresa, :anio, :mes, :idProfesor, :idInstitucion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_ASISTENCIAS_PROFESORES;
/

BEGIN
  PKG_ASISTENCIAS_PROFESORES.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- VERIFICACION — mirar la salida, no alcanza con ejecutar.
-- Un paquete INVALID devuelve un 500 mudo: el WHEN OTHERS no captura errores de
-- compilacion porque el PL/SQL nunca llega a ejecutarse.
--------------------------------------------------------------------------------

-- Tiene que decir VALID.
SELECT OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_ASISTENCIAS_PROFESORES';

-- Tiene que volver VACIO.
SELECT LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_ASISTENCIAS_PROFESORES'
 ORDER BY SEQUENCE;

-- El modulo, con su CORS.
SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'asistencias-profesores';

-- Una fila: listar GET.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'asistencias-profesores';

-- Cuantas asistencias tienen ID_EMPRESA en NULL (filas previas a la columna).
-- El LISTAR las incluye igual via la empresa del profesor, pero conviene
-- rellenarlas:
--   UPDATE ASISTENCIAS_PROFESORES a SET ID_EMPRESA =
--     (SELECT p.ID_EMPRESA FROM PROFESORES p WHERE p.ID_PROFESOR = a.ID_PROFESOR)
--    WHERE a.ID_EMPRESA IS NULL;
SELECT COUNT(*) AS SIN_EMPRESA
  FROM ASISTENCIAS_PROFESORES
 WHERE ID_EMPRESA IS NULL;

-- Marcaciones incompletas: entrada sin salida en un dia ya cerrado. Cero es lo
-- esperable; si hay filas, el reporte las va a mostrar marcadas.
SELECT COUNT(*) AS SIN_SALIDA
  FROM ASISTENCIAS_PROFESORES
 WHERE HORA_ENTRADA IS NOT NULL
   AND HORA_SALIDA IS NULL
   AND FECHA_ASISTENCIA < TRUNC(SYSDATE);
