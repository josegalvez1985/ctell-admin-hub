--------------------------------------------------------------------------------
-- CTELL · ASISTENCIAS DE PROFESORES (REPORTE)
--
-- Requiere db/auth.sql, PROFESORES e INSTITUCIONES, y el DDL de
-- ASISTENCIAS_PROFESORES con la columna ID_EMPRESA.
--
-- Endpoints: /asistencias-profesores/listar, /periodos, /crear,
--            /actualizar/:id, /eliminar/:id/:idEmpresa
--
--------------------------------------------------------------------------------
-- LA CARGA NORMAL ES LA APP; ESTE MODULO ADEMAS PERMITE CORREGIRLA A MANO
--
-- El origen de los datos sigue siendo la app del profesor, que marca con GPS y
-- hora del dispositivo. El ABM manual existe para corregir lo que la app no
-- registro: una entrada sin salida, un dia que no se marco, una fila duplicada.
--
-- LO QUE ESTO IMPLICA, EXPLICITO: una marcacion cargada o editada a mano queda
-- INDISTINGUIBLE de una tomada con GPS al mirar el reporte. La tabla no guarda
-- quien la toco ni cuando se edito, asi que ante una discusion de liquidacion el
-- registro ya no separa una de otra. Fue una decision tomada a conciencia,
-- priorizando poder corregir sin friccion.
--
-- Lo unico que queda como rastro es indirecto: las filas cargadas a mano no
-- llevan LATITUD/LONGITUD ni MARCADO_EN_*, porque este modulo no los escribe.
-- Una fila sin GPS es, casi seguro, una fila manual — pero las marcaciones
-- viejas de la app tampoco los tienen, asi que no sirve como prueba.
--
-- Si algun dia hace falta trazabilidad de verdad, el camino es agregar al DDL
-- ID_USUARIO_CARGA y ORIGEN ('APP'/'MANUAL'), no deducirlo de los NULL.
--
--------------------------------------------------------------------------------
-- QUIEN ENTRA VE TODAS LAS MARCACIONES. NO FILTRAR POR USUARIO.
--
-- El acceso al reporte lo deciden los PERMISOS DE PAGINA (USUARIO_PAGINAS), no
-- este paquete: quien tenga habilitada la pagina ve todas las marcaciones de la
-- empresa. Por eso alcanza con VALIDAR_TOKEN —sesion valida— y NO se usa
-- VALIDAR_TOKEN_ADMIN ni se compara el idProfesor pedido contra el usuario
-- logueado.
--
-- Hubo una version publicada en ORDS que SI comparaba, y devolvia
-- 403 "Solo podes ver tus propias asistencias" para cualquier profesor que no
-- fuera el del usuario. Nunca estuvo en este archivo: se ejecuto en la hoja SQL
-- de APEX y el repo quedo desincronizado. El sintoma era enganoso — el reporte
-- "andaba" con un profesor y fallaba con el resto — y el 403 no se podia
-- rastrear leyendo el codigo, porque el mensaje no existia en el repo.
--
-- Un reporte de liquidacion que solo muestra al propio profesor no sirve para
-- nada: justamente se usa para comparar y liquidar a TODOS.
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
-- FILTRO POR EMPRESA: LA DEL PROFESOR, NO LA DE LA MARCACION
--
-- El filtro es UNO SOLO, y no mira ASISTENCIAS_PROFESORES.ID_EMPRESA:
--
--   JOIN PROFESORES p ON p.ID_PROFESOR = a.ID_PROFESOR
--   WHERE p.ID_EMPRESA = l_empresa
--
-- POR QUE LA DEL PROFESOR ES LA FUENTE REAL. PROFESORES tiene
-- UNIQUE (NUMERO_CI) GLOBAL: una cedula existe una sola vez en todo el sistema,
-- asi que un profesor pertenece a EXACTAMENTE UNA empresa. La empresa de una
-- marcacion no es un dato independiente — es la de quien marco.
--
-- QUE PASABA ANTES. El filtro era:
--
--   (a.ID_EMPRESA = l_empresa OR (a.ID_EMPRESA IS NULL AND p.ID_EMPRESA = l_empresa))
--
-- que cubre las filas historicas con la columna en NULL, pero le CREE a
-- a.ID_EMPRESA cuando tiene valor. Nada en el DDL garantiza que ese valor
-- coincida con la empresa del profesor: la FK apunta a EMPRESAS y no mira
-- PROFESORES. Una marcacion grabada con la empresa equivocada —o con la de la
-- sesion de quien la cargo a mano— aparecia en el reporte de esa empresa, con
-- el nombre de un profesor que no es suyo. Es el bug que se reporto como
-- "asistencias muestra registros de otra empresa".
--
-- Con p.ID_EMPRESA el problema no se puede dar: la fila se lista donde esta su
-- profesor, tenga a.ID_EMPRESA lo que tenga —incluido NULL, que deja de ser un
-- caso especial—.
--
-- LO QUE ESTO IMPLICA: mover un profesor de empresa se lleva su historial. Es
-- lo correcto —el historial es de la persona— y ademas es lo unico consistente
-- con el UNIQUE global de la cedula.
--
-- La consulta de diagnostico del final del archivo lista las filas cuya
-- ID_EMPRESA no coincide con la de su profesor, con el UPDATE para corregirlas.
-- No hace falta correrlo para que el reporte salga bien: el filtro ya no las
-- mira. Conviene igual, porque cualquier consulta que se escriba mañana contra
-- a.ID_EMPRESA volveria a leer el dato malo.
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

  ----------------------------------------------------------------------------
  -- PERIODOS CON MARCACIONES
  --
  -- Anio, mes y cuantas marcaciones tiene cada uno. Alimenta los combos del
  -- reporte, para no ofrecer meses que devuelven una pantalla vacia.
  --
  -- Es un endpoint aparte y NO se deduce de LISTAR: para saber que meses del
  -- anio tienen datos habria que pedir el anio entero —miles de marcaciones—
  -- y contarlas en el navegador. Esto devuelve una fila por mes, que es lo
  -- unico que el combo necesita.
  ----------------------------------------------------------------------------
  PROCEDURE PERIODOS (
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  );

  ------------------------------------------------------------------------------
  -- CARGA MANUAL
  --
  -- Alta, edicion y baja a mano de una marcacion, para corregir lo que la app
  -- no registro: una entrada sin salida, un dia que no se marco, una fila
  -- duplicada.
  --
  -- Las filas cargadas por aca NO llevan GPS ni marca de origen: LATITUD,
  -- LONGITUD, MARCADO_EN_* y las CLAVE_* quedan en NULL, que es como se
  -- distinguen de una marcacion real si alguna vez hace falta mirarlas.
  --
  -- Requieren sesion valida (VALIDAR_TOKEN), no rol de administrador: el acceso
  -- lo deciden los permisos de pagina, igual que el listado.
  ------------------------------------------------------------------------------
  ----------------------------------------------------------------------------
  -- LOS CAMPOS DEL JSON LLEGAN SUELTOS, NO COMO `:body`
  --
  -- ORDS parsea el JSON del body y crea un bind por cada clave de primer nivel:
  -- :idEmpresa, :idProfesor, :fecha, etc. `:body` es OTRA cosa — el payload
  -- CRUDO, y viene como BLOB. Pasarlo a un parametro CLOB y buscarle adentro
  -- con JSON_VALUE devolvia NULL en todos los campos, asi que el alta y la
  -- edicion respondian 400 "son obligatorios" con el body correctamente puesto.
  --
  -- El resto de los modulos del proyecto siempre lo hizo asi; los unicos `:body`
  -- que quedan son los de subir imagenes, que si son BLOB de verdad.
  --
  -- Todos entran como VARCHAR2 y se convierten adentro, igual que los query
  -- params: un bind tipado obliga a ORDS a convertir antes del handler, y ahi
  -- un error no lo captura ningun WHEN OTHERS.
  ----------------------------------------------------------------------------
  PROCEDURE INSERTAR (
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_id_profesor    IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_fecha          IN  VARCHAR2,
    p_hora_entrada   IN  VARCHAR2,
    p_hora_salida    IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  );

  PROCEDURE ACTUALIZAR (
    p_authorization  IN  VARCHAR2,
    p_id             IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_id_profesor    IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_fecha          IN  VARCHAR2,
    p_hora_entrada   IN  VARCHAR2,
    p_hora_salida    IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization  IN  VARCHAR2,
    p_id             IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
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
     WHERE p.ID_EMPRESA = l_empresa
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
         WHERE p.ID_EMPRESA = l_empresa
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

  PROCEDURE PERIODOS (
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  ) IS
    l_sesion  NUMBER;
    l_empresa NUMBER;
    l_items   CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- El JSON_OBJECT va en la subconsulta y el JSON_ARRAYAGG agrega esa columna,
    -- que ya viene tipada como CLOB. Anidado, el intermedio del agregado se
    -- materializa como VARCHAR2 y revienta a los 4000 bytes. Mismo patron que
    -- LISTAR.
    --
    -- Aca SI se usa EXTRACT sobre la columna, al reves que en LISTAR: esto es
    -- un GROUP BY sobre todas las marcaciones de la empresa, asi que el indice
    -- por fecha no se iba a usar igual. Lo que importa es que el RESULTADO es
    -- chico —una fila por mes con datos— y por eso no hace falta paginarlo.
    --
    -- El filtro por empresa es el mismo del LISTAR, con las filas viejas que
    -- tienen ID_EMPRESA en NULL cayendo a la empresa del profesor. Si no, los
    -- meses historicos no aparecerian en el combo y no habria forma de llegar
    -- a ellos.
    SELECT JSON_ARRAYAGG(fila ORDER BY anio DESC, mes DESC RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'anio'     VALUE EXTRACT(YEAR  FROM a.FECHA_ASISTENCIA),
                 'mes'      VALUE EXTRACT(MONTH FROM a.FECHA_ASISTENCIA),
                 'cantidad' VALUE COUNT(*)
                 RETURNING CLOB
               ) AS fila,
               EXTRACT(YEAR  FROM a.FECHA_ASISTENCIA) AS anio,
               EXTRACT(MONTH FROM a.FECHA_ASISTENCIA) AS mes
          FROM ASISTENCIAS_PROFESORES a
          JOIN PROFESORES p ON p.ID_PROFESOR = a.ID_PROFESOR
         WHERE p.ID_EMPRESA = l_empresa
           AND a.FECHA_ASISTENCIA IS NOT NULL
         GROUP BY EXTRACT(YEAR FROM a.FECHA_ASISTENCIA), EXTRACT(MONTH FROM a.FECHA_ASISTENCIA)
      );

    p_status_code := 200;
    -- NVL: JSON_ARRAYAGG devuelve NULL sin filas, no un array vacio, y el
    -- frontend reventaria al iterar "items":null.
    SELECT JSON_OBJECT('items' VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON RETURNING CLOB)
      INTO p_resultado
      FROM DUAL;
  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_ASISTENCIAS_PROFESORES.PERIODOS: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los periodos"}';
  END PERIODOS;

  ------------------------------------------------------------------------------
  -- Privado: arma un TIMESTAMP a partir de la fecha del dia y una hora 'HH24:MI'.
  --
  -- La hora viaja como texto y no como timestamp completo porque el formulario
  -- pide "07:30", no una fecha con hora: componerla aca evita que el frontend
  -- tenga que armar un ISO y que una zona horaria le corra el dia.
  --
  -- Devuelve NULL con hora vacia: una marcacion sin salida es un estado valido
  -- (el profesor entro y todavia no salio).
  ------------------------------------------------------------------------------
  FUNCTION ARMAR_HORA (p_fecha IN DATE, p_hora IN VARCHAR2) RETURN TIMESTAMP IS
  BEGIN
    IF p_hora IS NULL OR TRIM(p_hora) IS NULL THEN
      RETURN NULL;
    END IF;
    RETURN TO_TIMESTAMP(TO_CHAR(p_fecha, 'YYYY-MM-DD') || ' ' || TRIM(p_hora),
                        'YYYY-MM-DD HH24:MI');
  END ARMAR_HORA;

  ------------------------------------------------------------------------------
  -- Privado: valida que el profesor y la institucion existan y sean de la
  -- empresa indicada.
  --
  -- Las FK garantizan que existan, pero NO que sean de la misma empresa: sin
  -- esto se podria cargar una marcacion de un profesor de la empresa A en una
  -- institucion de la B. Es el mismo control que hace PKG_UBICACIONES.
  --
  -- Devuelve el mensaje de error, o NULL si esta todo bien.
  ------------------------------------------------------------------------------
  FUNCTION VALIDAR_COHERENCIA (
    p_id_empresa     IN NUMBER,
    p_id_profesor    IN NUMBER,
    p_id_institucion IN NUMBER
  ) RETURN VARCHAR2 IS
    l_cuenta PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO l_cuenta
      FROM PROFESORES
     WHERE ID_PROFESOR = p_id_profesor
       AND ID_EMPRESA  = p_id_empresa;
    IF l_cuenta = 0 THEN
      RETURN 'El profesor no existe o no pertenece a esta empresa';
    END IF;

    SELECT COUNT(*) INTO l_cuenta
      FROM INSTITUCIONES
     WHERE ID_INSTITUCION = p_id_institucion
       AND ID_EMPRESA     = p_id_empresa;
    IF l_cuenta = 0 THEN
      RETURN 'La institucion no existe o no pertenece a esta empresa';
    END IF;

    RETURN NULL;
  END VALIDAR_COHERENCIA;

  PROCEDURE INSERTAR (
    p_authorization  IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_id_profesor    IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_fecha          IN  VARCHAR2,
    p_hora_entrada   IN  VARCHAR2,
    p_hora_salida    IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_empresa     NUMBER;
    l_profesor    NUMBER;
    l_institucion NUMBER;
    l_fecha       DATE;
    l_entrada     TIMESTAMP;
    l_salida      TIMESTAMP;
    l_error       VARCHAR2(400);
    l_id          NUMBER;
    l_hora_ent    VARCHAR2(10);
    l_hora_sal    VARCHAR2(10);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van DENTRO del BEGIN, nunca en el DECLARE: alli correrian
    -- antes de que exista el EXCEPTION y el error escaparia del procedimiento.
    l_empresa     := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_profesor    := TO_NUMBER(NULLIF(p_id_profesor, ''));
    l_institucion := TO_NUMBER(NULLIF(p_id_institucion, ''));
    l_hora_ent    := NULLIF(TRIM(p_hora_entrada), '');
    l_hora_sal    := NULLIF(TRIM(p_hora_salida), '');

    IF l_empresa IS NULL OR l_profesor IS NULL OR l_institucion IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, idProfesor e idInstitucion son obligatorios"}';
      RETURN;
    END IF;

    BEGIN
      l_fecha := TO_DATE(NULLIF(TRIM(p_fecha), ''), 'YYYY-MM-DD');
    EXCEPTION
      WHEN OTHERS THEN
        l_fecha := NULL;
    END;

    IF l_fecha IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"La fecha es obligatoria y va en formato YYYY-MM-DD"}';
      RETURN;
    END IF;

    l_error := VALIDAR_COHERENCIA(l_empresa, l_profesor, l_institucion);
    IF l_error IS NOT NULL THEN
      p_status_code := 400;
      p_resultado := JSON_OBJECT('error' VALUE l_error);
      RETURN;
    END IF;

    -- Se calcula en variables y no dentro del INSERT: una funcion privada del
    -- BODY no se puede llamar desde una sentencia SQL (PLS-00231).
    BEGIN
      l_entrada := ARMAR_HORA(l_fecha, l_hora_ent);
      l_salida  := ARMAR_HORA(l_fecha, l_hora_sal);
    EXCEPTION
      WHEN OTHERS THEN
        p_status_code := 400;
        p_resultado := '{"error":"La hora va en formato HH:MM (24 horas)"}';
        RETURN;
    END;

    IF l_entrada IS NOT NULL AND l_salida IS NOT NULL AND l_salida <= l_entrada THEN
      p_status_code := 400;
      p_resultado := '{"error":"La salida tiene que ser posterior a la entrada"}';
      RETURN;
    END IF;

    -- LATITUD, LONGITUD, MARCADO_EN_* y CLAVE_* quedan en NULL: esta fila no la
    -- tomo la app, se cargo a mano.
    INSERT INTO ASISTENCIAS_PROFESORES (
      ID_EMPRESA, ID_PROFESOR, ID_INSTITUCION, FECHA_ASISTENCIA,
      HORA_ENTRADA, HORA_SALIDA, ENTRADA_OFFLINE, SALIDA_OFFLINE
    ) VALUES (
      l_empresa, l_profesor, l_institucion, l_fecha,
      l_entrada, l_salida, 'N', 'N'
    ) RETURNING ID_ASISTENCIA INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_ASISTENCIAS_PROFESORES.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al guardar la marcacion"}';
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization  IN  VARCHAR2,
    p_id             IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_id_profesor    IN  VARCHAR2,
    p_id_institucion IN  VARCHAR2,
    p_fecha          IN  VARCHAR2,
    p_hora_entrada   IN  VARCHAR2,
    p_hora_salida    IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id          NUMBER;
    l_empresa     NUMBER;
    l_profesor    NUMBER;
    l_institucion NUMBER;
    l_fecha       DATE;
    l_entrada     TIMESTAMP;
    l_salida      TIMESTAMP;
    l_error       VARCHAR2(400);
    l_hora_ent    VARCHAR2(10);
    l_hora_sal    VARCHAR2(10);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id          := TO_NUMBER(NULLIF(p_id, ''));
    l_empresa     := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_profesor    := TO_NUMBER(NULLIF(p_id_profesor, ''));
    l_institucion := TO_NUMBER(NULLIF(p_id_institucion, ''));
    l_hora_ent    := NULLIF(TRIM(p_hora_entrada), '');
    l_hora_sal    := NULLIF(TRIM(p_hora_salida), '');

    -- El idEmpresa no es un dato mas a guardar: acota A CUAL FILA se aplica el
    -- cambio, igual que en el DELETE. Sin el, un PUT podria tocar la marcacion
    -- de otra empresa.
    IF l_id IS NULL OR l_empresa IS NULL OR l_profesor IS NULL OR l_institucion IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id, idEmpresa, idProfesor e idInstitucion son obligatorios"}';
      RETURN;
    END IF;

    BEGIN
      l_fecha := TO_DATE(NULLIF(TRIM(p_fecha), ''), 'YYYY-MM-DD');
    EXCEPTION
      WHEN OTHERS THEN
        l_fecha := NULL;
    END;

    IF l_fecha IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"La fecha es obligatoria y va en formato YYYY-MM-DD"}';
      RETURN;
    END IF;

    l_error := VALIDAR_COHERENCIA(l_empresa, l_profesor, l_institucion);
    IF l_error IS NOT NULL THEN
      p_status_code := 400;
      p_resultado := JSON_OBJECT('error' VALUE l_error);
      RETURN;
    END IF;

    BEGIN
      l_entrada := ARMAR_HORA(l_fecha, l_hora_ent);
      l_salida  := ARMAR_HORA(l_fecha, l_hora_sal);
    EXCEPTION
      WHEN OTHERS THEN
        p_status_code := 400;
        p_resultado := '{"error":"La hora va en formato HH:MM (24 horas)"}';
        RETURN;
    END;

    IF l_entrada IS NOT NULL AND l_salida IS NOT NULL AND l_salida <= l_entrada THEN
      p_status_code := 400;
      p_resultado := '{"error":"La salida tiene que ser posterior a la entrada"}';
      RETURN;
    END IF;

    -- ID_EMPRESA NO va en el SET: poder cambiarla permitiria mover la fila a
    -- otra empresa, que es justo lo que el WHERE impide. Va en el WHERE, y la
    -- condicion contempla las filas viejas que la tienen en NULL, igual que el
    -- LISTAR.
    UPDATE ASISTENCIAS_PROFESORES a
       SET ID_PROFESOR         = l_profesor,
           ID_INSTITUCION      = l_institucion,
           FECHA_ASISTENCIA    = l_fecha,
           HORA_ENTRADA        = l_entrada,
           HORA_SALIDA         = l_salida,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE a.ID_ASISTENCIA = l_id
       AND EXISTS (SELECT 1 FROM PROFESORES p
                    WHERE p.ID_PROFESOR = a.ID_PROFESOR
                      AND p.ID_EMPRESA  = l_empresa);

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      -- 404 y no 403: decir "existe pero no es tuya" confirmaria que el id
      -- existe, que es lo que no deberia poder averiguarse.
      p_status_code := 404;
      p_resultado := '{"error":"No se encontro la marcacion"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := JSON_OBJECT('ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_ASISTENCIAS_PROFESORES.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al actualizar la marcacion"}';
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization  IN  VARCHAR2,
    p_id             IN  VARCHAR2,
    p_id_empresa     IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
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

    -- La baja es FISICA: la tabla no tiene columna de estado, y una marcacion
    -- inactiva no significa nada — o paso o no paso.
    DELETE FROM ASISTENCIAS_PROFESORES a
     WHERE a.ID_ASISTENCIA = l_id
       AND EXISTS (SELECT 1 FROM PROFESORES p
                    WHERE p.ID_PROFESOR = a.ID_PROFESOR
                      AND p.ID_EMPRESA  = l_empresa);

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"No se encontro la marcacion"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := JSON_OBJECT('ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_ASISTENCIAS_PROFESORES.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al eliminar la marcacion"}';
  END ELIMINAR;

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

    ----------------------------------------------------------------------------
    -- GET /asistencias-profesores/periodos?idEmpresa=
    --
    -- Los meses que tienen marcaciones, para los combos del reporte.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'asistencias-profesores', p_pattern => 'periodos');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'asistencias-profesores',
      p_pattern     => 'periodos',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ASISTENCIAS_PROFESORES.PERIODOS(:authorization, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'periodos', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'periodos', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'periodos', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /asistencias-profesores/crear
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'asistencias-profesores', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'asistencias-profesores',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ASISTENCIAS_PROFESORES.INSERTAR(:authorization, :idEmpresa, :idProfesor, :idInstitucion, :fecha, :horaEntrada, :horaSalida, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /asistencias-profesores/actualizar/:id
    --
    -- El idEmpresa va en el BODY, no en la ruta: acota a cual fila se aplica el
    -- cambio. Es el mismo criterio del resto de las tablas por empresa.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'asistencias-profesores', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'asistencias-profesores',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ASISTENCIAS_PROFESORES.ACTUALIZAR(:authorization, :id, :idEmpresa, :idProfesor, :idInstitucion, :fecha, :horaEntrada, :horaSalida, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /asistencias-profesores/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(
      p_module_name => 'asistencias-profesores', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'asistencias-profesores',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_ASISTENCIAS_PROFESORES.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'asistencias-profesores', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
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

-- Cinco filas: listar GET, periodos GET, crear POST, actualizar/:id PUT,
-- eliminar/:id/:idEmpresa DELETE.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'asistencias-profesores'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- TIENE QUE VOLVER VACIO. Si devuelve filas, el paquete COMPILADO en la base no
-- es este archivo: quedo publicada una version que filtra por usuario y responde
-- 403 "Solo podes ver tus propias asistencias" para todo profesor que no sea el
-- del que consulta. Ver la nota del encabezado. La cura es reejecutar este
-- archivo entero (con `npm run dev` frenado).
--
-- Se mira USER_SOURCE y no el comportamiento porque el sintoma es intermitente
-- por naturaleza: con el profesor propio el endpoint responde 200 y todo
-- parece sano.
SELECT LINE, TEXT
  FROM USER_SOURCE
 WHERE NAME = 'PKG_ASISTENCIAS_PROFESORES'
   AND (UPPER(TEXT) LIKE '%PROPIAS ASISTENCIAS%'
     OR UPPER(TEXT) LIKE '%VALIDAR_TOKEN_ADMIN%')
 ORDER BY LINE;

-- Cuantas asistencias tienen ID_EMPRESA en NULL (filas previas a la columna).
-- El LISTAR las incluye igual via la empresa del profesor, pero conviene
-- rellenarlas:
--   UPDATE ASISTENCIAS_PROFESORES a SET ID_EMPRESA =
--     (SELECT p.ID_EMPRESA FROM PROFESORES p WHERE p.ID_PROFESOR = a.ID_PROFESOR)
--    WHERE a.ID_EMPRESA IS NULL;
SELECT COUNT(*) AS SIN_EMPRESA
  FROM ASISTENCIAS_PROFESORES
 WHERE ID_EMPRESA IS NULL;

-- Los periodos con marcaciones, que es lo que alimenta los combos del reporte.
-- Si esto vuelve vacio, el combo de mes queda con el mes en curso y nada mas.
SELECT EXTRACT(YEAR FROM FECHA_ASISTENCIA)  AS ANIO,
       EXTRACT(MONTH FROM FECHA_ASISTENCIA) AS MES,
       COUNT(*)                             AS CANTIDAD
  FROM ASISTENCIAS_PROFESORES
 GROUP BY EXTRACT(YEAR FROM FECHA_ASISTENCIA), EXTRACT(MONTH FROM FECHA_ASISTENCIA)
 ORDER BY ANIO DESC, MES DESC;

-- Marcaciones incompletas: entrada sin salida en un dia ya cerrado. Cero es lo
-- esperable; si hay filas, el reporte las va a mostrar marcadas.
SELECT COUNT(*) AS SIN_SALIDA
  FROM ASISTENCIAS_PROFESORES
 WHERE HORA_ENTRADA IS NOT NULL
   AND HORA_SALIDA IS NULL
   AND FECHA_ASISTENCIA < TRUNC(SYSDATE);

--------------------------------------------------------------------------------
-- MARCACIONES CON LA EMPRESA EQUIVOCADA
--
-- Filas cuya ID_EMPRESA no es la de su profesor. Nada en el DDL lo impide: la
-- FK apunta a EMPRESAS sin mirar PROFESORES.
--
-- Con el filtro actual (p.ID_EMPRESA) estas filas YA se listan donde
-- corresponde, asi que el reporte sale bien sin tocar nada. Se corrigen igual
-- porque el dato sigue mal guardado, y cualquier consulta que se escriba manana
-- contra a.ID_EMPRESA volveria a leerlo.
--
-- Si esta consulta devuelve filas, ESA es la causa de "veo asistencias de otra
-- empresa" en una version anterior del reporte.
--------------------------------------------------------------------------------
SELECT a.ID_ASISTENCIA,
       TO_CHAR(a.FECHA_ASISTENCIA, 'YYYY-MM-DD') AS FECHA,
       p.NOMBRE || ' ' || p.APELLIDO             AS PROFESOR,
       a.ID_EMPRESA                              AS EMPRESA_MARCACION,
       p.ID_EMPRESA                              AS EMPRESA_PROFESOR
  FROM ASISTENCIAS_PROFESORES a
  JOIN PROFESORES p ON p.ID_PROFESOR = a.ID_PROFESOR
 WHERE a.ID_EMPRESA IS NOT NULL
   AND a.ID_EMPRESA <> p.ID_EMPRESA
 ORDER BY a.FECHA_ASISTENCIA DESC;

-- Correccion (revisar la lista de arriba antes de correrlo):
--   UPDATE ASISTENCIAS_PROFESORES a
--      SET ID_EMPRESA = (SELECT p.ID_EMPRESA FROM PROFESORES p
--                         WHERE p.ID_PROFESOR = a.ID_PROFESOR)
--    WHERE a.ID_EMPRESA IS NULL
--       OR a.ID_EMPRESA <> (SELECT p.ID_EMPRESA FROM PROFESORES p
--                            WHERE p.ID_PROFESOR = a.ID_PROFESOR);
--   COMMIT;
