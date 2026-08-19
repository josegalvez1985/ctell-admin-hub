--------------------------------------------------------------------------------
-- CTELL · PROFESORES
--
-- Un paquete (PKG_PROFESORES) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicacion de los endpoints ORDS. Todo vive
-- dentro del paquete: no hay procedimientos sueltos ni PL/SQL embebido como
-- texto dentro de los handlers.
--
--   1. LISTAR      GET    /profesores/listar   (?idEmpresa= &busqueda=)
--   2. INSERTAR    POST   /profesores/crear
--   3. ACTUALIZAR  PUT    /profesores/actualizar/:id
--   4. ELIMINAR    DELETE /profesores/eliminar/:id/:idEmpresa
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/profesores/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   PROFESORES  ID_PROFESOR, ID_EMPRESA, NUMERO_CI, NOMBRE, APELLIDO,
--               USUARIO_SISTEMA, DIRECCION, TELEFONO, CORREO,
--               FECHA_CREACION, FECHA_ACTUALIZACION
--
-- EL PROFESOR ES POR EMPRESA. Cada empresa tiene su propio plantel: el
-- idEmpresa sale de la empresa que se eligio al iniciar sesion, no de un
-- combobox del formulario. Por eso el listado se filtra por ?idEmpresa= y el
-- alta lo recibe como dato obligatorio.
--
--------------------------------------------------------------------------------
-- TRES UNIQUE, Y DOS DE ELLOS SON GLOBALES — ESTO ES LO IMPORTANTE DEL ARCHIVO
--
-- El DDL declara:
--
--   UNIQUE (NUMERO_CI)                 <-- GLOBAL, cruza empresas
--   UNIQUE (USUARIO_SISTEMA)           <-- GLOBAL, cruza empresas
--   UNIQUE (ID_EMPRESA, NUMERO_CI)     <-- por empresa
--
-- ES DISTINTO DEL RESTO DEL PROYECTO. En MONEDAS, CATEGORIAS o
-- LISTAS_DESCUENTOS el unico es SIEMPRE compuesto con la empresa, y por eso el
-- mensaje del 409 dice "esta empresa ya tiene...". Aca NO: dos empresas
-- distintas NO pueden cargar al mismo profesor, porque la cedula y el usuario
-- son unicos en toda la tabla.
--
-- CONSECUENCIA PRACTICA QUE HAY QUE TENER PRESENTE: si un profesor trabaja en
-- dos colegios que son dos EMPRESAS del sistema, solo se lo puede cargar en
-- una. La segunda va a recibir un 409 aunque su listado no muestre ningun
-- profesor con esa cedula — el choque es contra una fila que esa empresa NO
-- PUEDE VER. El mensaje lo dice explicitamente para que no se busque el
-- duplicado en la pantalla propia, donde nunca va a aparecer.
--
-- Si esa restriccion no era la intencion, lo que hay que cambiar es el DDL
-- (dejar solo el UNIQUE compuesto), no este paquete.
--
-- El UNIQUE (ID_EMPRESA, NUMERO_CI) es REDUNDANTE frente al global de
-- NUMERO_CI: si la cedula ya no puede repetirse en toda la tabla, tampoco puede
-- repetirse dentro de una empresa. No molesta —Oracle lo mantiene igual— pero
-- no agrega ninguna garantia, y por eso este paquete no lo valida por separado.
--
-- LOS TRES SE CONSULTAN ANTES DE INSERTAR, no se espera al DUP_VAL_ON_INDEX:
-- esa excepcion no dice CUAL de los tres indices se violo, y el mensaje
-- quedaria en "algun dato esta repetido". Con la consulta previa se nombra el
-- campo. El DUP_VAL_ON_INDEX se captura igual como red de seguridad, por si dos
-- altas simultaneas pasan las dos validaciones antes de que cualquiera escriba.
--
--------------------------------------------------------------------------------
-- USUARIO_SISTEMA NO ES UN USUARIO DE LOGIN
--
-- A pesar del nombre, esta columna NO tiene ninguna relacion con la tabla
-- USUARIOS ni con PKG_AUTH: no hay FK, no hay contraseña y no sirve para entrar
-- al sistema. Es un identificador corto del profesor —'jperez', 'mgarcia'—
-- segun el comentario del DDL.
--
-- Se guarda en MINUSCULAS y sin espacios: sin normalizar, 'JPerez' y 'jperez'
-- pasan el UNIQUE como dos profesores distintos siendo el mismo. Es el mismo
-- criterio que UBICACIONES.ZONA, que se guarda en mayusculas por la misma
-- razon.
--
-- NUMERO_CI tambien se normaliza (TRIM y mayusculas al comparar): una cedula
-- con un espacio al final no deberia colar como distinta.
--
--------------------------------------------------------------------------------
-- NO HAY COLUMNA ACTIVO
--
-- El DDL no la trae, asi que la baja es FISICA, como en DETALLE_MONEDAS,
-- LISTAS_DESCUENTOS e INSTITUCIONES. No hay /inactivar ni /activar, y el
-- ACTUALIZAR no recibe p_activo.
--
-- SIN JOIN CONTRA EMPRESAS: el listado no devuelve el nombre de la empresa.
-- Viene filtrado por una sola —la de la sesion— asi que seria la misma
-- constante repetida en cada fila. Mismo criterio que db/monedas.sql.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_PROFESORES
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_PROFESORES.LISTAR('Bearer TU_TOKEN', NULL, NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_PROFESORES AS

  -- p_id_empresa NULL o vacio devuelve los profesores de todas las empresas. En
  -- la app siempre viaja con la empresa de la sesion.
  --
  -- p_busqueda filtra por nombre, apellido, CI, usuario y correo. Va en el SQL
  -- y no en el cliente porque el padron puede crecer.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- idEmpresa, numeroCi, nombre, apellido y usuarioSistema son obligatorios:
  -- las cinco columnas son NOT NULL en el DDL.
  PROCEDURE INSERTAR (
    p_authorization    IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_numero_ci        IN  VARCHAR2,
    p_nombre           IN  VARCHAR2,
    p_apellido         IN  VARCHAR2,
    p_usuario_sistema  IN  VARCHAR2,
    p_direccion        IN  VARCHAR2,
    p_telefono         IN  VARCHAR2,
    p_correo           IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  );

  -- Los parametros ausentes (NULL) no modifican la columna correspondiente.
  PROCEDURE ACTUALIZAR (
    p_authorization    IN  VARCHAR2,
    p_id               IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_numero_ci        IN  VARCHAR2,
    p_nombre           IN  VARCHAR2,
    p_apellido         IN  VARCHAR2,
    p_usuario_sistema  IN  VARCHAR2,
    p_direccion        IN  VARCHAR2,
    p_telefono         IN  VARCHAR2,
    p_correo           IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  );

  -- p_id_empresa es OBLIGATORIO: acota el borrado a la empresa de la sesion.
  -- Sin el, un DELETE con el id de un profesor ajeno lo borraba igual.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /profesores/ con sus 4 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_PROFESORES;
/

CREATE OR REPLACE PACKAGE BODY PKG_PROFESORES AS

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
         WHERE NAME = 'profesores';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'profesores');
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
  -- Privado: el usuario del sistema, normalizado.
  --
  -- Minusculas y sin espacios: sin esto 'JPerez' y 'jperez' pasan el UNIQUE
  -- como dos profesores distintos siendo el mismo. Se aplica tanto al comparar
  -- como al guardar, para que la columna quede consistente.
  ------------------------------------------------------------------------------
  FUNCTION NORMALIZAR_USUARIO (p_texto IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF TRIM(p_texto) IS NULL THEN
      RETURN NULL;
    END IF;
    RETURN LOWER(REPLACE(TRIM(p_texto), ' ', ''));
  END NORMALIZAR_USUARIO;

  ------------------------------------------------------------------------------
  -- Privado: esa cedula ya esta usada por OTRO profesor.
  --
  -- LA BUSQUEDA ES GLOBAL, SIN FILTRAR POR EMPRESA, porque el UNIQUE del DDL
  -- tambien lo es. Filtrar por empresa aca dejaria pasar el alta y el INSERT
  -- moriria despues con DUP_VAL_ON_INDEX contra una fila de otra empresa.
  --
  -- p_id_excluir es la fila que se esta editando: sin el, actualizar un profesor
  -- sin cambiarle la cedula chocaria contra si mismo.
  ------------------------------------------------------------------------------
  FUNCTION CI_REPETIDO (
    p_numero_ci  IN VARCHAR2,
    p_id_excluir IN NUMBER DEFAULT NULL
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    IF TRIM(p_numero_ci) IS NULL THEN
      RETURN FALSE;
    END IF;

    SELECT COUNT(*)
      INTO l_existe
      FROM PROFESORES
     WHERE UPPER(TRIM(NUMERO_CI)) = UPPER(TRIM(p_numero_ci))
       AND (p_id_excluir IS NULL OR ID_PROFESOR != p_id_excluir);

    RETURN l_existe > 0;
  END CI_REPETIDO;

  ------------------------------------------------------------------------------
  -- Privado: ese usuario ya esta usado por OTRO profesor. Igual que
  -- CI_REPETIDO: el UNIQUE es global, asi que la busqueda tambien.
  ------------------------------------------------------------------------------
  FUNCTION USUARIO_REPETIDO (
    p_usuario_sistema IN VARCHAR2,
    p_id_excluir      IN NUMBER DEFAULT NULL
  ) RETURN BOOLEAN IS
    l_existe  PLS_INTEGER;
    l_usuario VARCHAR2(50);
  BEGIN
    l_usuario := NORMALIZAR_USUARIO(p_usuario_sistema);

    IF l_usuario IS NULL THEN
      RETURN FALSE;
    END IF;

    -- La comparacion normaliza LOS DOS LADOS: las filas viejas pueden tener
    -- mayusculas de antes de que este paquete existiera.
    SELECT COUNT(*)
      INTO l_existe
      FROM PROFESORES
     WHERE LOWER(TRIM(USUARIO_SISTEMA)) = l_usuario
       AND (p_id_excluir IS NULL OR ID_PROFESOR != p_id_excluir);

    RETURN l_existe > 0;
  END USUARIO_REPETIDO;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_empresa NUMBER;
    l_busqueda   VARCHAR2(4000);
    l_total      NUMBER;
    l_items      CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- La conversion va aca, dentro del BEGIN: en el DECLARE se ejecutaria antes
    -- de que exista el EXCEPTION y el error escaparia del procedimiento.
    l_id_empresa := A_NUMERO(p_id_empresa);

    -- En minusculas una sola vez aca, no por fila: el WHERE compara contra
    -- LOWER() de cada columna, asi que subir el termino tambien dentro del SQL
    -- haria el trabajo tantas veces como filas tenga la tabla.
    --
    -- NULL cuando llega vacio: el WHERE esta escrito como "l_busqueda IS NULL
    -- OR ...", asi que una cadena vacia sin normalizar filtraria por '%%' en vez
    -- de saltear el filtro.
    l_busqueda := LOWER(TRIM(NULLIF(p_busqueda, '')));

    SELECT COUNT(*)
      INTO l_total
      FROM PROFESORES
     WHERE (l_id_empresa IS NULL OR ID_EMPRESA = l_id_empresa)
       AND (l_busqueda IS NULL
            OR LOWER(NOMBRE)          LIKE '%' || l_busqueda || '%'
            OR LOWER(APELLIDO)        LIKE '%' || l_busqueda || '%'
            OR LOWER(NUMERO_CI)       LIKE '%' || l_busqueda || '%'
            OR LOWER(USUARIO_SISTEMA) LIKE '%' || l_busqueda || '%'
            OR LOWER(CORREO)          LIKE '%' || l_busqueda || '%');

    -- Sin JOIN: la consulta sale de PROFESORES y nada mas. El nombre de la
    -- empresa no se devuelve porque el listado ya viene filtrado por una sola.
    --
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: con DIRECCION de hasta 500 caracteres por fila, ese techo se
    -- alcanza con siete u ocho profesores.
    --
    -- ORDEN por apellido y despues nombre: es como se busca a una persona en un
    -- listado, y como se imprimen las planillas.
    SELECT JSON_ARRAYAGG(fila ORDER BY apellido, nombre RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'              VALUE p.ID_PROFESOR,
                 'idEmpresa'       VALUE p.ID_EMPRESA,
                 'numeroCi'        VALUE p.NUMERO_CI,
                 'nombre'          VALUE p.NOMBRE,
                 'apellido'        VALUE p.APELLIDO,
                 'usuarioSistema'  VALUE p.USUARIO_SISTEMA,
                 'direccion'       VALUE p.DIRECCION,
                 'telefono'        VALUE p.TELEFONO,
                 'correo'          VALUE p.CORREO
                 RETURNING CLOB
               ) AS fila,
               p.APELLIDO AS apellido,
               p.NOMBRE   AS nombre
          FROM PROFESORES p
         WHERE (l_id_empresa IS NULL OR p.ID_EMPRESA = l_id_empresa)
           AND (l_busqueda IS NULL
                OR LOWER(p.NOMBRE)          LIKE '%' || l_busqueda || '%'
                OR LOWER(p.APELLIDO)        LIKE '%' || l_busqueda || '%'
                OR LOWER(p.NUMERO_CI)       LIKE '%' || l_busqueda || '%'
                OR LOWER(p.USUARIO_SISTEMA) LIKE '%' || l_busqueda || '%'
                OR LOWER(p.CORREO)          LIKE '%' || l_busqueda || '%')
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
      APEX_DEBUG.ERROR('PKG_PROFESORES.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      -- El SQLERRM viaja en la respuesta, como en db/lotes.sql: el mensaje
      -- generico deja el 500 sin diagnostico y APEX_DEBUG escribe en un log del
      -- workspace que hay que ir a buscar. REPLACE saca las comillas y los
      -- saltos de linea, que romperian el JSON.
      p_resultado := '{"error":"Error al listar los profesores: ' ||
                     REPLACE(
                       REPLACE(
                         REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                         CHR(10), ' '),
                       CHR(13), ' ') ||
                     '"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization    IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_numero_ci        IN  VARCHAR2,
    p_nombre           IN  VARCHAR2,
    p_apellido         IN  VARCHAR2,
    p_usuario_sistema  IN  VARCHAR2,
    p_direccion        IN  VARCHAR2,
    p_telefono         IN  VARCHAR2,
    p_correo           IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_empresa NUMBER;
    l_usuario    VARCHAR2(50);
    l_id         NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_empresa := A_NUMERO(p_id_empresa);
    l_usuario    := NORMALIZAR_USUARIO(p_usuario_sistema);

    -- Las cinco columnas NOT NULL del DDL. Sin esto el INSERT moriria con
    -- ORA-01400 (500); validado aca devuelve un 400 que dice cual falta.
    IF l_id_empresa IS NULL
       OR TRIM(p_numero_ci) IS NULL
       OR TRIM(p_nombre) IS NULL
       OR TRIM(p_apellido) IS NULL
       OR l_usuario IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, numeroCi, nombre, apellido y usuarioSistema son obligatorios"}';
      RETURN;
    END IF;

    -- LOS UNIQUE SE CONSULTAN ANTES DE INSERTAR para poder nombrar el campo en
    -- el mensaje: DUP_VAL_ON_INDEX no informa cual de los tres indices fallo.
    --
    -- El mensaje aclara que el choque puede ser con OTRA EMPRESA: el UNIQUE es
    -- global, asi que quien lo reciba no va a encontrar el duplicado en su
    -- propio listado por mas que lo busque.
    IF CI_REPETIDO(p_numero_ci) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe un profesor con esa cedula. La cedula es unica en todo el sistema, asi que puede estar cargado en otra empresa"}';
      RETURN;
    END IF;

    IF USUARIO_REPETIDO(p_usuario_sistema) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe un profesor con ese usuario. El usuario es unico en todo el sistema, asi que puede estar cargado en otra empresa"}';
      RETURN;
    END IF;

    INSERT INTO PROFESORES (
      ID_EMPRESA, NUMERO_CI, NOMBRE, APELLIDO, USUARIO_SISTEMA,
      DIRECCION, TELEFONO, CORREO,
      FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_empresa,
      TRIM(p_numero_ci),
      TRIM(p_nombre),
      TRIM(p_apellido),
      -- Normalizado, no crudo: es lo que hace que el UNIQUE sirva de verdad.
      l_usuario,
      TRIM(p_direccion),
      TRIM(p_telefono),
      TRIM(p_correo),
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_PROFESOR INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- Red de seguridad: las validaciones de arriba ya cubren los tres casos,
      -- pero dos altas simultaneas pueden pasarlas las dos antes de que
      -- cualquiera escriba. Aca ya no se sabe cual indice fallo.
      p_status_code := 409;
      p_resultado := '{"error":"La cedula o el usuario ya estan registrados"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: la FK contra EMPRESAS no encontro el padre. Es un dato
      -- invalido del cliente (400), no un fallo del servidor.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La empresa indicada no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_PROFESORES.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear el profesor: ' ||
                       REPLACE(
                         REPLACE(
                           REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                           CHR(10), ' '),
                         CHR(13), ' ') ||
                       '"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization    IN  VARCHAR2,
    p_id               IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_numero_ci        IN  VARCHAR2,
    p_nombre           IN  VARCHAR2,
    p_apellido         IN  VARCHAR2,
    p_usuario_sistema  IN  VARCHAR2,
    p_direccion        IN  VARCHAR2,
    p_telefono         IN  VARCHAR2,
    p_correo           IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id         NUMBER;
    l_id_empresa NUMBER;
    l_usuario    VARCHAR2(50);
    l_existe     PLS_INTEGER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id         := A_NUMERO(p_id);
    l_id_empresa := A_NUMERO(p_id_empresa);
    l_usuario    := NORMALIZAR_USUARIO(p_usuario_sistema);

    -- AISLAMIENTO POR EMPRESA: el idEmpresa acota A CUAL fila se le aplica el
    -- cambio, no es solo un campo mas a modificar. Sin el WHERE, un PUT con el
    -- id de un profesor de OTRA empresa lo modificaba igual — la pantalla no lo
    -- permite, pero el endpoint es publico para cualquiera con sesion.
    --
    -- ID_EMPRESA sale del SET a proposito: mover una fila de empresa es lo que
    -- este control busca impedir, y dejarlo modificable seria la puerta de
    -- atras al mismo problema.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- Existe Y es de esta empresa? Se comprueba ANTES de los UNIQUE: si la fila
    -- no es suya, el 404 tiene que ganarle al 409. Al reves, un 409 confirmaria
    -- que el id existe, que es informacion que quien pregunta no deberia
    -- obtener.
    SELECT COUNT(*)
      INTO l_existe
      FROM PROFESORES
     WHERE ID_PROFESOR = l_id
       AND ID_EMPRESA  = l_id_empresa;

    IF l_existe = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El profesor no existe"}';
      RETURN;
    END IF;

    -- Los UNIQUE, excluyendo la propia fila: sin el p_id_excluir, actualizar un
    -- profesor sin cambiarle la cedula chocaria contra si mismo.
    IF CI_REPETIDO(p_numero_ci, l_id) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otro profesor con esa cedula. La cedula es unica en todo el sistema, asi que puede estar cargado en otra empresa"}';
      RETURN;
    END IF;

    IF USUARIO_REPETIDO(p_usuario_sistema, l_id) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otro profesor con ese usuario. El usuario es unico en todo el sistema, asi que puede estar cargado en otra empresa"}';
      RETURN;
    END IF;

    UPDATE PROFESORES
       SET NUMERO_CI           = NVL(TRIM(p_numero_ci), NUMERO_CI),
           NOMBRE              = NVL(TRIM(p_nombre), NOMBRE),
           APELLIDO            = NVL(TRIM(p_apellido), APELLIDO),
           -- Normalizado igual que en el alta: si no, editar un profesor
           -- ensuciaria una columna que el alta dejaba limpia.
           USUARIO_SISTEMA     = NVL(l_usuario, USUARIO_SISTEMA),
           DIRECCION           = NVL(TRIM(p_direccion), DIRECCION),
           TELEFONO            = NVL(TRIM(p_telefono), TELEFONO),
           CORREO              = NVL(TRIM(p_correo), CORREO),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_PROFESOR = l_id
       AND ID_EMPRESA  = l_id_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El profesor no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"La cedula o el usuario ya estan registrados"}';
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_PROFESORES.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al actualizar el profesor: ' ||
                     REPLACE(
                       REPLACE(
                         REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                         CHR(10), ' '),
                       CHR(13), ' ') ||
                     '"}';
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id         NUMBER;
    l_id_empresa NUMBER;
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

    -- AISLAMIENTO POR EMPRESA: las dos condiciones. Con solo el id, un DELETE
    -- con el id de un profesor de otra empresa lo borraba.
    --
    -- BAJA FISICA: la tabla no tiene columna ACTIVO, asi que no hay baja logica
    -- posible. Es el mismo caso que INSTITUCIONES.
    DELETE FROM PROFESORES
     WHERE ID_PROFESOR = l_id
       AND ID_EMPRESA  = l_id_empresa;

    -- 404 tambien cuando existe pero es de otra empresa: no se confirma que el
    -- id exista.
    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El profesor no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos (materias, cursos, lo que cuelgue del profesor)
      -- apuntando a esta fila. Es un conflicto de estado (409), no un error del
      -- servidor: el dato que mandaron era valido.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de este profesor"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_PROFESORES.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar el profesor: ' ||
                       REPLACE(
                         REPLACE(
                           REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                           CHR(10), ' '),
                         CHR(13), ' ') ||
                       '"}';
      END IF;
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Publica el modulo ORDS /profesores/ con sus 4 endpoints.
  --
  -- Cada handler es una sola linea: invoca al procedimiento del paquete pasando
  -- los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un parametro
  -- de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin esto, toda
  -- peticion cross-origin a /profesores/* la rechaza ORDS antes de llegar a
  -- cualquiera de los 4 handlers. Ver la explicacion en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'profesores',
      p_base_path      => '/profesores/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'ABM de profesores por empresa'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'profesores',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /profesores/listar?idEmpresa=&busqueda=
    --
    -- Los query params no se declaran con DEFINE_PARAMETER: se vinculan solos
    -- al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'profesores', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'profesores',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PROFESORES.LISTAR(:authorization, :idEmpresa, :busqueda, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /profesores/crear
    -- Body: { idEmpresa, numeroCi, nombre, apellido, usuarioSistema,
    --         direccion?, telefono?, correo? }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'profesores', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'profesores',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PROFESORES.INSERTAR(:authorization, :idEmpresa, :numeroCi, :nombre, :apellido, :usuarioSistema, :direccion, :telefono, :correo, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /profesores/actualizar/:id
    -- Body: { idEmpresa, numeroCi?, nombre?, apellido?, usuarioSistema?,
    --         direccion?, telefono?, correo? }
    --       (ausentes = no cambia)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'profesores', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'profesores',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PROFESORES.ACTUALIZAR(:authorization, :id, :idEmpresa, :numeroCi, :nombre, :apellido, :usuarioSistema, :direccion, :telefono, :correo, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /profesores/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'profesores', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'profesores',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_PROFESORES.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'profesores', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_PROFESORES;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_PROFESORES.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_PROFESORES'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_PROFESORES'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'profesores';

SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'profesores'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

SELECT p.ID_PROFESOR, e.NOMBRE_EMPRESA, p.NUMERO_CI,
       p.APELLIDO || ', ' || p.NOMBRE AS PROFESOR,
       p.USUARIO_SISTEMA, p.TELEFONO, p.CORREO
  FROM PROFESORES p
  JOIN EMPRESAS   e ON e.ID_EMPRESA = p.ID_EMPRESA
 ORDER BY e.NOMBRE_EMPRESA, p.APELLIDO, p.NOMBRE;

--------------------------------------------------------------------------------
-- USUARIOS SIN NORMALIZAR — DEBE DEVOLVER CERO FILAS.
--
-- Si devuelve alguna, hay filas cargadas antes de este paquete con mayusculas o
-- espacios en USUARIO_SISTEMA. El paquete ya no deja crear mas asi, pero las
-- viejas siguen ahi y pueden esconder un duplicado real: 'JPerez' y 'jperez'
-- pasaron el UNIQUE como dos profesores distintos.
--
-- Para normalizarlas (revisar antes que no genere un choque):
--   UPDATE PROFESORES SET USUARIO_SISTEMA = LOWER(REPLACE(TRIM(USUARIO_SISTEMA), ' ', ''));
--   COMMIT;
--------------------------------------------------------------------------------

SELECT ID_PROFESOR, ID_EMPRESA, USUARIO_SISTEMA
  FROM PROFESORES
 WHERE USUARIO_SISTEMA != LOWER(REPLACE(TRIM(USUARIO_SISTEMA), ' ', ''));

-- Y los que quedarian duplicados AL normalizar: hay que resolverlos a mano
-- antes de correr el UPDATE de arriba, porque el UNIQUE lo va a rechazar.
SELECT LOWER(REPLACE(TRIM(USUARIO_SISTEMA), ' ', '')) AS USUARIO_NORMALIZADO,
       COUNT(*)                                       AS CUANTOS
  FROM PROFESORES
 GROUP BY LOWER(REPLACE(TRIM(USUARIO_SISTEMA), ' ', ''))
HAVING COUNT(*) > 1;
