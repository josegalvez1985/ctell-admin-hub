--------------------------------------------------------------------------------
-- CTELL · PERSONAS
--
-- Un paquete (PKG_PERSONAS) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicacion de los endpoints ORDS. Todo vive
-- dentro del paquete: no hay procedimientos sueltos ni PL/SQL embebido como
-- texto dentro de los handlers.
--
--   1. LISTAR      GET    /personas/listar     (?busqueda= &tipo= opcionales)
--   2. INSERTAR    POST   /personas/crear
--   3. ACTUALIZAR  PUT    /personas/actualizar/:id
--   4. ELIMINAR    DELETE /personas/eliminar/:id
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/personas/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   PERSONAS  ID_PERSONA, NUMERO_CI, RUC, NOMBRE, APELLIDO, RAZON_SOCIAL,
--             EMAIL, TELEFONO, DIRECCION, TIPO_PERSONA,
--             FECHA_CREACION, FECHA_ACTUALIZACION
--
--------------------------------------------------------------------------------
-- ES UN CATALOGO GLOBAL, NO UNA TABLA POR EMPRESA
--
-- No tiene ID_EMPRESA, asi que se comporta como PAISES, DEPARTAMENTOS o
-- CIUDADES: el padron de personas es uno solo y lo comparten todas las empresas.
-- La misma persona puede ser cliente de una y proveedor de otra sin cargarse dos
-- veces.
--
-- CONSECUENCIA: NINGUN procedimiento recibe idEmpresa, y el ELIMINAR lleva solo
-- el :id — no el /eliminar/:id/:idEmpresa de las tablas por empresa. No es un
-- olvido: no hay ninguna empresa contra la cual acotar.
--
-- Si mas adelante hiciera falta que cada empresa tenga su propio padron, el
-- camino NO es agregarle ID_EMPRESA a esta tabla (romperia a quien ya sea
-- cliente de dos), sino una tabla de cruce EMPRESA_PERSONAS con el rol que
-- cumple en cada una.
--
--------------------------------------------------------------------------------
-- NO TIENE COLUMNA ACTIVO: LA BAJA ES FISICA
--
-- A diferencia de casi todas las demas tablas del proyecto, PERSONAS no tiene
-- ACTIVO 'A'/'I', asi que no hay baja logica: ELIMINAR borra la fila.
--
-- ESO VA A CHOCAR CON LAS FK EL DIA QUE PERSONAS CUELGUE DE ALGO. Cuando existan
-- compras o ventas apuntando aca, borrar a alguien con movimientos va a dar
-- ORA-02292. El procedimiento ya lo traduce a un 409 con un mensaje que se
-- entiende, en vez de dejar salir un 500 — pero el usuario se va a encontrar con
-- que no puede dar de baja a un cliente viejo.
--
-- La solucion cuando llegue ese momento es agregar ACTIVO al DDL y pasar a baja
-- logica, como el resto del proyecto. Se decidio no hacerlo ahora para no tocar
-- el DDL antes de tiempo.
--
--------------------------------------------------------------------------------
-- TIPO_PERSONA: 'F' FISICA / 'J' JURIDICA
--
-- Mismo criterio que ACTIVO ('A'/'I') y ES_ADMIN ('S'/'N') en el resto del
-- proyecto: el codigo de una letra viaja al JSON sin traducirse a booleano ni a
-- una palabra. El default es 'F'.
--
-- EL PROBLEMA QUE RESUELVE ESTE PAQUETE: el DDL declara NOMBRE y APELLIDO como
-- NOT NULL, pero RAZON_SOCIAL como nullable — y una persona JURIDICA es
-- exactamente al reves: tiene razon social y no tiene ni nombre ni apellido.
-- Tal cual esta el DDL, cargar una empresa obliga a inventarle un nombre y un
-- apellido que no existen.
--
-- COMO SE RESUELVE, sin tocar el DDL:
--
--   FISICA ('F')   NOMBRE y APELLIDO son obligatorios y se guardan tal cual.
--                  RAZON_SOCIAL queda en null.
--
--   JURIDICA ('J') RAZON_SOCIAL es obligatoria. NOMBRE recibe UNA COPIA de la
--                  razon social y APELLIDO un guion, solo para satisfacer el
--                  NOT NULL. El formulario NO pide esos dos campos.
--
-- La copia en NOMBRE no es redundancia gratuita: hace que cualquier consulta que
-- busque por NOMBRE —incluidos los reportes que se escriban despues sin conocer
-- esta regla— encuentre tambien a las juridicas. Y el guion en APELLIDO es
-- deliberadamente visible: si aparece en una pantalla, se nota que es un relleno
-- y no un dato real.
--
-- PARA MOSTRAR ESTA EL CAMPO CALCULADO `nombreCompleto` (ver LISTAR), que
-- resuelve cual de los dos corresponde segun el tipo. El frontend usa ese y no
-- arma la concatenacion por su cuenta.
--
--------------------------------------------------------------------------------
-- DOS UNIQUE SOBRE COLUMNAS NULLABLE: NUMERO_CI Y RUC
--
-- Oracle NO considera que dos NULL choquen entre si, asi que se pueden cargar
-- muchas personas sin CI y sin RUC. Lo que el UNIQUE impide es repetir un valor
-- que SI esta cargado — que es justo lo que se busca.
--
-- Los dos se consultan ANTES de insertar para poder nombrar el campo en el
-- mensaje: DUP_VAL_ON_INDEX no informa cual de los dos indices fallo, y "ya
-- existe una persona con esos datos" no le dice a nadie que corregir. El
-- DUP_VAL_ON_INDEX queda igual como red por si dos peticiones simultaneas pasan
-- las dos consultas.
--
-- La comparacion es UPPER(TRIM(...)) de los dos lados: '4.123.456' y '4123456'
-- son distintos para la base y hay poco que hacer ahi, pero al menos 'abc123' y
-- 'ABC123' no entran dos veces.
--
--------------------------------------------------------------------------------
-- COMO EJECUTAR
--
--   1. Frena `npm run dev` (evita ORA-00060 al borrar el modulo).
--   2. Pega este archivo entero en la hoja SQL de APEX y ejecutalo.
--   3. Revisa que PKG_PERSONAS quede VALID y que USER_ERRORS no traiga nada.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_PERSONAS AS

  -- p_busqueda filtra por nombre, apellido, razon social, CI o RUC. p_tipo
  -- acepta 'F' o 'J'; vacio trae las dos. Los dos son opcionales.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_tipo          IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Que es obligatorio depende del tipo (ver la cabecera):
  --   'F' nombre y apellido.
  --   'J' razon social.
  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_tipo_persona  IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_apellido      IN  VARCHAR2,
    p_razon_social  IN  VARCHAR2,
    p_numero_ci     IN  VARCHAR2,
    p_ruc           IN  VARCHAR2,
    p_email         IN  VARCHAR2,
    p_telefono      IN  VARCHAR2,
    p_direccion     IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Los parametros ausentes (NULL) no modifican su columna.
  --
  -- TIPO_PERSONA SI se puede cambiar, pero cambiarlo obliga a mandar los datos
  -- del tipo nuevo: pasar de fisica a juridica sin razon social se rechaza con
  -- un 400 en vez de dejar la fila a medio armar.
  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_tipo_persona  IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_apellido      IN  VARCHAR2,
    p_razon_social  IN  VARCHAR2,
    p_numero_ci     IN  VARCHAR2,
    p_ruc           IN  VARCHAR2,
    p_email         IN  VARCHAR2,
    p_telefono      IN  VARCHAR2,
    p_direccion     IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- BAJA FISICA: la tabla no tiene ACTIVO. Ver la nota de la cabecera.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /personas/ con sus endpoints.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_PERSONAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_PERSONAS AS

  -- Lo que se guarda en APELLIDO de una persona juridica. Una constante y no un
  -- literal suelto: aparece en tres lugares y tiene que ser el mismo en todos,
  -- porque el listado lo usa para decidir que mostrar.
  C_SIN_APELLIDO CONSTANT VARCHAR2(1) := '-';

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
         WHERE NAME = 'personas';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'personas');
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
  -- Privado: normaliza el tipo. Cualquier cosa que no sea 'J' cae en 'F'.
  --
  -- Devuelve NULL solo si el parametro vino vacio, para que ACTUALIZAR pueda
  -- distinguir "no me lo mandaron" de "me mandaron algo raro".
  ------------------------------------------------------------------------------
  FUNCTION NORMALIZAR_TIPO (p_tipo IN VARCHAR2) RETURN VARCHAR2 IS
    l_limpio VARCHAR2(10) := UPPER(TRIM(p_tipo));
  BEGIN
    IF l_limpio IS NULL THEN
      RETURN NULL;
    END IF;

    RETURN CASE l_limpio WHEN 'J' THEN 'J' ELSE 'F' END;
  END NORMALIZAR_TIPO;

  ------------------------------------------------------------------------------
  -- Privado: ese CI ya esta usado por OTRA persona.
  --
  -- p_id_excluir es la fila que se esta editando: sin el, actualizar una persona
  -- sin cambiarle el CI chocaria contra si misma.
  ------------------------------------------------------------------------------
  FUNCTION CI_REPETIDO (
    p_numero_ci  IN VARCHAR2,
    p_id_excluir IN NUMBER DEFAULT NULL
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    IF TRIM(p_numero_ci) IS NULL THEN
      -- Sin CI no hay choque posible: Oracle no compara NULL contra NULL en un
      -- UNIQUE, asi que varias personas sin CI conviven sin problema.
      RETURN FALSE;
    END IF;

    SELECT COUNT(*)
      INTO l_existe
      FROM PERSONAS
     WHERE UPPER(TRIM(NUMERO_CI)) = UPPER(TRIM(p_numero_ci))
       AND (p_id_excluir IS NULL OR ID_PERSONA != p_id_excluir);

    RETURN l_existe > 0;
  END CI_REPETIDO;

  ------------------------------------------------------------------------------
  -- Privado: ese RUC ya esta usado por OTRA persona. Igual que CI_REPETIDO.
  ------------------------------------------------------------------------------
  FUNCTION RUC_REPETIDO (
    p_ruc        IN VARCHAR2,
    p_id_excluir IN NUMBER DEFAULT NULL
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    IF TRIM(p_ruc) IS NULL THEN
      RETURN FALSE;
    END IF;

    SELECT COUNT(*)
      INTO l_existe
      FROM PERSONAS
     WHERE UPPER(TRIM(RUC)) = UPPER(TRIM(p_ruc))
       AND (p_id_excluir IS NULL OR ID_PERSONA != p_id_excluir);

    RETURN l_existe > 0;
  END RUC_REPETIDO;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_tipo          IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_busqueda VARCHAR2(200);
    l_tipo     VARCHAR2(1);
    l_total    NUMBER;
    l_items    CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- El % va en la variable y no concatenado en el SQL: asi el LIKE usa un bind
    -- y no arma una sentencia distinta por cada busqueda.
    l_busqueda := CASE
                    WHEN TRIM(p_busqueda) IS NULL THEN NULL
                    ELSE '%' || UPPER(TRIM(p_busqueda)) || '%'
                  END;

    -- Un tipo desconocido se ignora en vez de filtrar por el: filtrar por algo
    -- que no existe devuelve cero filas y parece que no hay datos cargados.
    l_tipo := CASE UPPER(TRIM(p_tipo))
                WHEN 'F' THEN 'F'
                WHEN 'J' THEN 'J'
                ELSE NULL
              END;

    SELECT COUNT(*)
      INTO l_total
      FROM PERSONAS
     WHERE (l_tipo IS NULL OR NVL(UPPER(TRIM(TIPO_PERSONA)), 'F') = l_tipo)
       AND (l_busqueda IS NULL
            OR UPPER(NOMBRE)              LIKE l_busqueda
            OR UPPER(APELLIDO)            LIKE l_busqueda
            OR UPPER(RAZON_SOCIAL)        LIKE l_busqueda
            OR UPPER(NUMERO_CI)           LIKE l_busqueda
            OR UPPER(RUC)                 LIKE l_busqueda);

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: con DIRECCION de hasta 500 caracteres por fila, ese techo se
    -- alcanza enseguida.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'             VALUE p.ID_PERSONA,
                 -- El codigo de una letra viaja sin traducir, igual que ACTIVO
                 -- y ES_ADMIN. El NVL cubre las filas cargadas antes de que la
                 -- columna tuviera default.
                 'tipoPersona'    VALUE NVL(UPPER(TRIM(p.TIPO_PERSONA)), 'F'),
                 'nombre'         VALUE p.NOMBRE,
                 -- El guion de relleno de las juridicas NO viaja: el frontend
                 -- recibe null y no tiene que saber que existe esa convencion.
                 -- Si mostrara el '-' tal cual, pareceria un apellido cargado
                 -- mal en vez de un campo que no aplica.
                 'apellido'       VALUE CASE
                                          WHEN TRIM(p.APELLIDO) = C_SIN_APELLIDO
                                          THEN NULL ELSE p.APELLIDO
                                        END,
                 'razonSocial'    VALUE p.RAZON_SOCIAL,
                 -- CALCULADO, para mostrar: resuelve cual de los dos nombres
                 -- corresponde segun el tipo, asi el frontend no repite la regla
                 -- —ni la olvida— en cada pantalla que liste personas.
                 --
                 -- En juridica cae a NOMBRE si no hay razon social, que no
                 -- deberia pasar (INSERTAR la exige) pero cubre las filas
                 -- cargadas antes de este paquete.
                 'nombreCompleto' VALUE CASE
                                          WHEN NVL(UPPER(TRIM(p.TIPO_PERSONA)), 'F') = 'J'
                                          THEN NVL(p.RAZON_SOCIAL, p.NOMBRE)
                                          ELSE TRIM(p.NOMBRE || ' ' ||
                                                    CASE WHEN TRIM(p.APELLIDO) = C_SIN_APELLIDO
                                                         THEN NULL ELSE p.APELLIDO END)
                                        END,
                 'numeroCi'       VALUE p.NUMERO_CI,
                 'ruc'            VALUE p.RUC,
                 'email'          VALUE p.EMAIL,
                 'telefono'       VALUE p.TELEFONO,
                 'direccion'      VALUE p.DIRECCION
                 RETURNING CLOB
               ) AS fila,
               -- Se ordena por lo que se muestra, no por NOMBRE: en una juridica
               -- NOMBRE es la copia de la razon social y ordenaria igual, pero
               -- dejarlo explicito evita que un cambio futuro en esa convencion
               -- desordene el listado sin que nadie lo note.
               CASE
                 WHEN NVL(UPPER(TRIM(p.TIPO_PERSONA)), 'F') = 'J'
                 THEN NVL(p.RAZON_SOCIAL, p.NOMBRE)
                 ELSE p.APELLIDO || ' ' || p.NOMBRE
               END AS orden
          FROM PERSONAS p
         WHERE (l_tipo IS NULL OR NVL(UPPER(TRIM(p.TIPO_PERSONA)), 'F') = l_tipo)
           AND (l_busqueda IS NULL
                OR UPPER(p.NOMBRE)       LIKE l_busqueda
                OR UPPER(p.APELLIDO)     LIKE l_busqueda
                OR UPPER(p.RAZON_SOCIAL) LIKE l_busqueda
                OR UPPER(p.NUMERO_CI)    LIKE l_busqueda
                OR UPPER(p.RUC)          LIKE l_busqueda)
      );

    p_status_code := 200;
    -- JSON_OBJECT(... RETURNING CLOB) como asignacion PL/SQL directa (sin
    -- SELECT) falla con PLS-00684 dentro de un package body.
    --
    -- JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un array vacio: sin el
    -- NVL el frontend recibiria "items":null y reventaria al iterarlo.
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
      APEX_DEBUG.ERROR('PKG_PERSONAS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las personas"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_tipo_persona  IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_apellido      IN  VARCHAR2,
    p_razon_social  IN  VARCHAR2,
    p_numero_ci     IN  VARCHAR2,
    p_ruc           IN  VARCHAR2,
    p_email         IN  VARCHAR2,
    p_telefono      IN  VARCHAR2,
    p_direccion     IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion       NUMBER;
    l_tipo         VARCHAR2(1);
    l_nombre       VARCHAR2(100);
    l_apellido     VARCHAR2(100);
    l_razon_social VARCHAR2(200);
    l_id           NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Sin tipo se asume fisica, que es el default del DDL y el caso habitual.
    l_tipo := NVL(NORMALIZAR_TIPO(p_tipo_persona), 'F');

    -- QUE ES OBLIGATORIO DEPENDE DEL TIPO. Es la regla central de esta tabla:
    -- el DDL pide NOMBRE y APELLIDO siempre, pero una empresa no los tiene.
    IF l_tipo = 'J' THEN
      IF TRIM(p_razon_social) IS NULL THEN
        p_status_code := 400;
        p_resultado := '{"error":"La razon social es obligatoria en una persona juridica"}';
        RETURN;
      END IF;

      -- NOMBRE recibe una COPIA de la razon social y APELLIDO el guion de
      -- relleno: las dos columnas son NOT NULL y una juridica no tiene ninguno
      -- de los dos datos. Ver la nota de la cabecera.
      --
      -- SUBSTR porque RAZON_SOCIAL admite 200 caracteres y NOMBRE solo 100: sin
      -- esto, una razon social larga aborta el alta con ORA-12899.
      l_razon_social := TRIM(p_razon_social);
      l_nombre       := SUBSTR(l_razon_social, 1, 100);
      l_apellido     := C_SIN_APELLIDO;
    ELSE
      IF TRIM(p_nombre) IS NULL OR TRIM(p_apellido) IS NULL THEN
        p_status_code := 400;
        p_resultado := '{"error":"El nombre y el apellido son obligatorios en una persona fisica"}';
        RETURN;
      END IF;

      l_nombre       := TRIM(p_nombre);
      l_apellido     := TRIM(p_apellido);
      -- Una fisica no tiene razon social. Se ignora lo que haya llegado en vez
      -- de guardarlo: dejaria una fila que dice ser fisica y juridica a la vez.
      l_razon_social := NULL;
    END IF;

    -- Los dos UNIQUE se consultan antes de insertar para poder nombrar el campo
    -- en el mensaje: DUP_VAL_ON_INDEX no informa cual de los dos indices fallo.
    IF CI_REPETIDO(p_numero_ci) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una persona con ese numero de CI"}';
      RETURN;
    END IF;

    IF RUC_REPETIDO(p_ruc) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una persona con ese RUC"}';
      RETURN;
    END IF;

    INSERT INTO PERSONAS (
      TIPO_PERSONA, NOMBRE, APELLIDO, RAZON_SOCIAL,
      NUMERO_CI, RUC, EMAIL, TELEFONO, DIRECCION,
      FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_tipo,
      l_nombre,
      l_apellido,
      l_razon_social,
      TRIM(p_numero_ci),
      TRIM(p_ruc),
      TRIM(p_email),
      TRIM(p_telefono),
      TRIM(p_direccion),
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_PERSONA INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- Las consultas de arriba ya cubren el caso normal; esto atrapa dos
      -- peticiones simultaneas que las pasaron las dos. El mensaje es generico
      -- porque aca si es imposible saber cual de los dos indices fallo.
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una persona con ese CI o RUC"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -12899 THEN
        -- Un valor mas largo que su columna. Es un dato invalido del cliente
        -- (400), no un fallo del servidor.
        p_status_code := 400;
        p_resultado := '{"error":"Alguno de los datos supera el largo permitido"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_PERSONAS.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear la persona"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_tipo_persona  IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_apellido      IN  VARCHAR2,
    p_razon_social  IN  VARCHAR2,
    p_numero_ci     IN  VARCHAR2,
    p_ruc           IN  VARCHAR2,
    p_email         IN  VARCHAR2,
    p_telefono      IN  VARCHAR2,
    p_direccion     IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion         NUMBER;
    l_id             NUMBER;
    l_tipo_pedido    VARCHAR2(1);
    l_tipo_actual    VARCHAR2(1);
    l_tipo_final     VARCHAR2(1);
    l_nombre         VARCHAR2(100);
    l_apellido       VARCHAR2(100);
    l_razon_social   VARCHAR2(200);
    l_razon_final    VARCHAR2(200);
    l_razon_actual   PERSONAS.RAZON_SOCIAL%TYPE;
    l_nombre_actual  PERSONAS.NOMBRE%TYPE;
    l_apellido_actual PERSONAS.APELLIDO%TYPE;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id := TO_NUMBER(NULLIF(p_id, ''));

    IF l_id IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id es obligatorio"}';
      RETURN;
    END IF;

    -- Se lee la fila actual antes de decidir nada. HAY QUE SABER COMO VA A
    -- QUEDAR, no solo que llego: un PUT que cambia el tipo a 'J' sin mandar
    -- razon social puede ser valido —si ya la tenia cargada— o invalido si no.
    -- Resolverlo mirando solo los parametros daria el resultado equivocado en
    -- uno de los dos casos.
    BEGIN
      SELECT NVL(UPPER(TRIM(TIPO_PERSONA)), 'F'), NOMBRE, APELLIDO, RAZON_SOCIAL
        INTO l_tipo_actual, l_nombre_actual, l_apellido_actual, l_razon_actual
        FROM PERSONAS
       WHERE ID_PERSONA = l_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_status_code := 404;
        p_resultado := '{"error":"La persona no existe"}';
        RETURN;
    END;

    l_tipo_pedido := NORMALIZAR_TIPO(p_tipo_persona);
    -- Ausente = no cambia, igual que el resto de los campos.
    l_tipo_final  := NVL(l_tipo_pedido, l_tipo_actual);

    IF l_tipo_final = 'J' THEN
      -- Como va a quedar la razon social: la que mandaron, o la que ya tenia.
      l_razon_final := NVL(TRIM(p_razon_social), l_razon_actual);

      IF l_razon_final IS NULL THEN
        p_status_code := 400;
        p_resultado := '{"error":"La razon social es obligatoria en una persona juridica"}';
        RETURN;
      END IF;

      l_razon_social := l_razon_final;
      l_nombre       := SUBSTR(l_razon_final, 1, 100);
      l_apellido     := C_SIN_APELLIDO;
    ELSE
      -- Como van a quedar nombre y apellido. El apellido actual puede ser el
      -- guion de relleno —si venia de ser juridica— y en ese caso NO cuenta
      -- como apellido cargado: pasar de juridica a fisica exige mandarlo.
      l_nombre   := NVL(TRIM(p_nombre), l_nombre_actual);
      l_apellido := NVL(TRIM(p_apellido),
                        CASE WHEN TRIM(l_apellido_actual) = C_SIN_APELLIDO
                             THEN NULL ELSE l_apellido_actual END);

      IF l_nombre IS NULL OR l_apellido IS NULL THEN
        p_status_code := 400;
        p_resultado := '{"error":"El nombre y el apellido son obligatorios en una persona fisica"}';
        RETURN;
      END IF;

      l_razon_social := NULL;
    END IF;

    -- Los UNIQUE, excluyendo la propia fila: sin el p_id_excluir, actualizar una
    -- persona sin tocarle el CI chocaria contra si misma.
    IF CI_REPETIDO(p_numero_ci, l_id) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otra persona con ese numero de CI"}';
      RETURN;
    END IF;

    IF RUC_REPETIDO(p_ruc, l_id) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otra persona con ese RUC"}';
      RETURN;
    END IF;

    -- Los tres campos de identidad (tipo, nombre, apellido, razon social) van
    -- con el valor YA RESUELTO de arriba, no con NVL sobre el parametro: entre
    -- los cuatro hay reglas cruzadas y aplicarlas columna por columna dejaria
    -- combinaciones invalidas (una juridica con apellido real, por ejemplo).
    --
    -- Los de contacto SI usan NVL: son independientes entre si, y un parametro
    -- ausente conserva el valor actual.
    UPDATE PERSONAS
       SET TIPO_PERSONA        = l_tipo_final,
           NOMBRE              = l_nombre,
           APELLIDO            = l_apellido,
           RAZON_SOCIAL        = l_razon_social,
           NUMERO_CI           = NVL(TRIM(p_numero_ci), NUMERO_CI),
           RUC                 = NVL(TRIM(p_ruc), RUC),
           EMAIL               = NVL(TRIM(p_email), EMAIL),
           TELEFONO            = NVL(TRIM(p_telefono), TELEFONO),
           DIRECCION           = NVL(TRIM(p_direccion), DIRECCION),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_PERSONA = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      -- El SELECT de arriba la encontro, asi que llegar aca significa que otra
      -- sesion la borro en el medio.
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La persona no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otra persona con ese CI o RUC"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -12899 THEN
        p_status_code := 400;
        p_resultado := '{"error":"Alguno de los datos supera el largo permitido"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_PERSONAS.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar la persona"}';
      END IF;
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_id     NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id := TO_NUMBER(NULLIF(p_id, ''));

    IF l_id IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id es obligatorio"}';
      RETURN;
    END IF;

    -- BAJA FISICA: la tabla no tiene ACTIVO, asi que no hay baja logica que
    -- hacer. Ver la nota de la cabecera sobre lo que va a pasar cuando PERSONAS
    -- empiece a tener hijos.
    --
    -- Sin AND ID_EMPRESA, al reves que las tablas por empresa: PERSONAS es un
    -- catalogo global y no hay empresa contra la cual acotar.
    DELETE FROM PERSONAS WHERE ID_PERSONA = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La persona no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos apuntando a esta fila. Hoy no existe ninguna tabla
      -- que cuelgue de PERSONAS, asi que no puede pasar todavia — queda
      -- contemplado porque va a ser el caso NORMAL apenas se agreguen compras,
      -- ventas o clientes. Es un conflicto de estado (409), no un error del
      -- servidor: el dato que mandaron era valido.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de esta persona"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_PERSONAS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar la persona"}';
      END IF;
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'personas',
      p_base_path      => '/personas/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Padron de personas fisicas y juridicas, compartido por todas las empresas'
    );

    -- ORIGINS_ALLOWED ES POR MODULO, no por workspace: la pantalla de APEX
    -- sugiere lo contrario, pero habilitarlo en otro modulo no lo propaga a
    -- este. Sin esto, ORDS rechaza la peticion cross-origin ANTES de llegar al
    -- handler, con un "Service Unavailable" que ningun WHEN OTHERS captura
    -- porque el PL/SQL nunca llega a ejecutarse.
    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'personas',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /personas/listar?busqueda=&tipo=
    --
    -- Los query params no se declaran con DEFINE_PARAMETER: se vinculan solos al
    -- bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'personas', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'personas',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PERSONAS.LISTAR(:authorization, :busqueda, :tipo, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'personas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'personas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'personas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /personas/crear
    -- Body: { tipoPersona?, nombre?, apellido?, razonSocial?, numeroCi?, ruc?,
    --         email?, telefono?, direccion? }
    --
    -- Que es obligatorio depende de tipoPersona: 'F' pide nombre y apellido,
    -- 'J' pide razonSocial.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'personas', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'personas',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PERSONAS.INSERTAR(:authorization, :tipoPersona, :nombre, :apellido, :razonSocial, :numeroCi, :ruc, :email, :telefono, :direccion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'personas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'personas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'personas', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /personas/actualizar/:id
    -- Body: los mismos campos, todos opcionales (ausentes = no cambia).
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'personas', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'personas',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PERSONAS.ACTUALIZAR(:authorization, :id, :tipoPersona, :nombre, :apellido, :razonSocial, :numeroCi, :ruc, :email, :telefono, :direccion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'personas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'personas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'personas', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /personas/eliminar/:id
    --
    -- SIN idEmpresa, al reves que las tablas por empresa: PERSONAS es un
    -- catalogo global, igual que PAISES o CIUDADES.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'personas', p_pattern => 'eliminar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'personas',
      p_pattern     => 'eliminar/:id',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PERSONAS.ELIMINAR(:authorization, :id, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'personas', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'personas', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'personas', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_PERSONAS;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_PERSONAS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_PERSONAS'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_PERSONAS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'personas';

-- Deben aparecer 4 filas: listar GET, crear POST, actualizar PUT,
-- eliminar DELETE.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'personas'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- El padron, como lo ve el listado.
SELECT ID_PERSONA,
       NVL(UPPER(TRIM(TIPO_PERSONA)), 'F') AS TIPO,
       CASE WHEN NVL(UPPER(TRIM(TIPO_PERSONA)), 'F') = 'J'
            THEN NVL(RAZON_SOCIAL, NOMBRE)
            ELSE APELLIDO || ', ' || NOMBRE END AS NOMBRE_COMPLETO,
       NUMERO_CI, RUC, EMAIL, TELEFONO
  FROM PERSONAS
 ORDER BY TIPO, NOMBRE_COMPLETO;

--------------------------------------------------------------------------------
-- Auditoria: las cuatro consultas que tienen que devolver CERO filas
--
-- El DDL no puede expresar las reglas cruzadas entre TIPO_PERSONA y los campos
-- de identidad (haria falta un CHECK). Solo el paquete las mantiene, asi que
-- esto verifica que nada se haya colado por otro camino.
--------------------------------------------------------------------------------

-- 1. Juridicas SIN razon social. Es el caso que INSERTAR rechaza con 400: sin
--    ella la fila no tiene ningun nombre real, solo el relleno.
SELECT ID_PERSONA, NOMBRE, APELLIDO
  FROM PERSONAS
 WHERE NVL(UPPER(TRIM(TIPO_PERSONA)), 'F') = 'J'
   AND TRIM(RAZON_SOCIAL) IS NULL;

-- 2. Fisicas CON razon social. Una persona fisica no tiene: si aparece, la fila
--    dice ser de los dos tipos a la vez.
SELECT ID_PERSONA, NOMBRE, APELLIDO, RAZON_SOCIAL
  FROM PERSONAS
 WHERE NVL(UPPER(TRIM(TIPO_PERSONA)), 'F') = 'F'
   AND TRIM(RAZON_SOCIAL) IS NOT NULL;

-- 3. Fisicas con el guion de relleno en APELLIDO. Ese valor es exclusivo de las
--    juridicas; en una fisica significa que quedo mal convertida.
SELECT ID_PERSONA, NOMBRE, APELLIDO
  FROM PERSONAS
 WHERE NVL(UPPER(TRIM(TIPO_PERSONA)), 'F') = 'F'
   AND TRIM(APELLIDO) = '-';

-- 4. Tipos que no son ni 'F' ni 'J'. El paquete normaliza todo a esos dos, asi
--    que una fila aca entro por fuera de la API.
SELECT ID_PERSONA, TIPO_PERSONA, NOMBRE
  FROM PERSONAS
 WHERE TIPO_PERSONA IS NOT NULL
   AND UPPER(TRIM(TIPO_PERSONA)) NOT IN ('F', 'J');

--------------------------------------------------------------------------------
-- Consultas utiles
--------------------------------------------------------------------------------

-- Cuantas hay de cada tipo.
SELECT NVL(UPPER(TRIM(TIPO_PERSONA)), 'F') AS TIPO, COUNT(*) AS CANTIDAD
  FROM PERSONAS
 GROUP BY NVL(UPPER(TRIM(TIPO_PERSONA)), 'F')
 ORDER BY TIPO;

-- Personas sin ningun documento cargado. No es un error —el DDL los permite
-- nulos— pero son las que no se van a poder facturar.
SELECT ID_PERSONA,
       CASE WHEN NVL(UPPER(TRIM(TIPO_PERSONA)), 'F') = 'J'
            THEN RAZON_SOCIAL ELSE APELLIDO || ', ' || NOMBRE END AS NOMBRE_COMPLETO,
       EMAIL, TELEFONO
  FROM PERSONAS
 WHERE TRIM(NUMERO_CI) IS NULL
   AND TRIM(RUC) IS NULL
 ORDER BY NOMBRE_COMPLETO;

-- Personas sin ninguna forma de contacto: ni mail, ni telefono, ni direccion.
SELECT ID_PERSONA,
       CASE WHEN NVL(UPPER(TRIM(TIPO_PERSONA)), 'F') = 'J'
            THEN RAZON_SOCIAL ELSE APELLIDO || ', ' || NOMBRE END AS NOMBRE_COMPLETO,
       NUMERO_CI, RUC
  FROM PERSONAS
 WHERE TRIM(EMAIL) IS NULL
   AND TRIM(TELEFONO) IS NULL
   AND TRIM(DIRECCION) IS NULL
 ORDER BY NOMBRE_COMPLETO;
