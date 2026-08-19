--------------------------------------------------------------------------------
-- CTELL · CONDICIONES_PAGO
--
-- Un paquete (PKG_CONDICIONES_PAGO) con los 4 procedimientos — LISTAR,
-- INSERTAR, ACTUALIZAR, ELIMINAR — y la publicacion de los endpoints ORDS.
--
--   1. LISTAR      GET    /condiciones-pago/listar
--   2. INSERTAR    POST   /condiciones-pago/crear
--   3. ACTUALIZAR  PUT    /condiciones-pago/actualizar/:id
--   4. ELIMINAR    DELETE /condiciones-pago/eliminar/:id
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX. REQUIERE
-- db/auth.sql EJECUTADO ANTES: usa PKG_AUTH para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/condiciones-pago/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   CONDICIONES_PAGO  ID_CONDICION, NOMBRE_CONDICION, DIAS_PAGO,
--                     CANTIDAD_CUOTAS, FECHA_CREACION, FECHA_ACTUALIZACION
--
--------------------------------------------------------------------------------
-- ES UN CATALOGO GLOBAL, COMO PAISES O PERSONAS
--
-- No tiene ID_EMPRESA: las condiciones de pago —contado, 30 dias, 3 cuotas— son
-- las mismas para cualquier empresa del sistema. Consecuencia: NINGUN
-- procedimiento recibe idEmpresa, y el ELIMINAR lleva solo el :id.
--
--------------------------------------------------------------------------------
-- QUE SIGNIFICAN LAS DOS COLUMNAS NUMERICAS
--
--   DIAS_PAGO        cuantos dias hay para pagar desde la fecha de la factura.
--                    0 es CONTADO. 30, 60, 90 son los plazos habituales.
--   CANTIDAD_CUOTAS  en cuantas veces se paga. 1 es pago unico.
--
-- LAS DOS SON NULLABLE EN EL DDL, y este paquete las trata como opcionales pero
-- con default: si no vienen, entran en 0 dias y 1 cuota — que es "contado, pago
-- unico", la condicion mas comun y la unica que se puede asumir sin equivocarse.
--
-- Dejarlas en NULL seria peor: el frontend tendria que mostrar "sin definir" en
-- una condicion que igual se puede elegir en una factura, y el dia que alguien
-- calcule vencimientos con ellas se encontraria con un NULL que rompe la cuenta.
--
-- SE VALIDAN COHERENTES ENTRE SI:
--   * dias >= 0        un plazo negativo no existe.
--   * cuotas >= 1      cero cuotas no es una forma de pago.
--   * contado (0 dias) no puede tener mas de una cuota: pagar en tres veces YA
--     ES un plazo, aunque el campo diga 0. Esa combinacion produce condiciones
--     como "Contado en 3 cuotas" que despues nadie sabe como interpretar.
--
--------------------------------------------------------------------------------
-- EL UNIQUE ES SOBRE NOMBRE_CONDICION
--
-- Se consulta antes de insertar para poder nombrar el campo en el mensaje:
-- DUP_VAL_ON_INDEX no informa cual indice fallo. La comparacion es
-- UPPER(TRIM(...)) de los dos lados, asi que 'contado' y 'Contado' se consideran
-- la misma condicion — que es lo que se busca: el UNIQUE de la base NO las
-- detectaria como iguales, y quedarian dos filas que en pantalla se leen igual.
--
-- OJO: eso significa que la base acepta un duplicado que este paquete rechaza.
-- Si alguien inserta a mano 'CONTADO' teniendo 'Contado', las dos conviven y hay
-- que limpiarlas. El archivo cierra con la consulta que las encuentra.
--
--------------------------------------------------------------------------------
-- ELIMINAR: BAJA FISICA, PROTEGIDA POR LA FK
--
-- La tabla no tiene columna ACTIVO, asi que no hay baja logica. Una condicion
-- USADA por alguna factura no se puede borrar: la FK
-- FACTURAS_COMPRAS_CAB_FK_CONDICIONES lo impide con ORA-02292, que el
-- procedimiento traduce a un 409 diciendo CUANTAS facturas la usan.
--
--------------------------------------------------------------------------------
-- COMO EJECUTAR
--
--   1. Frena `npm run dev` (evita ORA-00060 al borrar el modulo).
--   2. Pega este archivo entero en la hoja SQL de APEX y ejecutalo.
--   3. Revisa que PKG_CONDICIONES_PAGO quede VALID y USER_ERRORS vacio.
--   4. Carga las condiciones habituales (el archivo cierra con los INSERT).
--
-- ORDEN RESPECTO DE FACTURAS: este archivo va ANTES que
-- db/facturas-compras.sql, porque el listado de facturas hace JOIN contra
-- CONDICIONES_PAGO. Al reves, PKG_FACTURAS_COMPRAS queda INVALID si la tabla
-- todavia no existe.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_CONDICIONES_PAGO AS

  -- Todas las condiciones. Sin filtros ni paginado: son unas pocas filas.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Solo el nombre es obligatorio. Sin dias ni cuotas, entra como contado (0
  -- dias) y pago unico (1 cuota).
  PROCEDURE INSERTAR (
    p_authorization    IN  VARCHAR2,
    p_nombre_condicion IN  VARCHAR2,
    p_dias_pago        IN  VARCHAR2,
    p_cantidad_cuotas  IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  );

  -- Los parametros ausentes (NULL) no modifican su columna.
  PROCEDURE ACTUALIZAR (
    p_authorization    IN  VARCHAR2,
    p_id               IN  VARCHAR2,
    p_nombre_condicion IN  VARCHAR2,
    p_dias_pago        IN  VARCHAR2,
    p_cantidad_cuotas  IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  );

  -- Baja fisica. Una condicion usada por alguna factura devuelve 409.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /condiciones-pago/ con sus endpoints.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_CONDICIONES_PAGO;
/

CREATE OR REPLACE PACKAGE BODY PKG_CONDICIONES_PAGO AS

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
         WHERE NAME = 'condiciones-pago';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'condiciones-pago');
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
  -- Privado: ese nombre ya lo usa OTRA condicion.
  --
  -- p_id_excluir es la fila que se esta editando: sin el, actualizar una
  -- condicion sin cambiarle el nombre chocaria contra si misma.
  --
  -- Compara en mayusculas, mas estricto que el UNIQUE de la base: 'contado' y
  -- 'Contado' son la misma condicion para una persona, aunque Oracle las vea
  -- distintas.
  ------------------------------------------------------------------------------
  FUNCTION NOMBRE_REPETIDO (
    p_nombre     IN VARCHAR2,
    p_id_excluir IN NUMBER DEFAULT NULL
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    IF TRIM(p_nombre) IS NULL THEN
      RETURN FALSE;
    END IF;

    SELECT COUNT(*)
      INTO l_existe
      FROM CONDICIONES_PAGO
     WHERE UPPER(TRIM(NOMBRE_CONDICION)) = UPPER(TRIM(p_nombre))
       AND (p_id_excluir IS NULL OR ID_CONDICION != p_id_excluir);

    RETURN l_existe > 0;
  END NOMBRE_REPETIDO;

  ------------------------------------------------------------------------------
  -- Privado: valida dias y cuotas entre si.
  --
  -- Devuelve el error en texto (NULL si esta bien) en vez de lanzar una
  -- excepcion: los dos procedimientos que la usan tienen que poder devolver un
  -- 400 con el mensaje, no un 500.
  ------------------------------------------------------------------------------
  FUNCTION ERROR_EN_PLAZOS (
    p_dias   IN NUMBER,
    p_cuotas IN NUMBER
  ) RETURN VARCHAR2 IS
  BEGIN
    IF p_dias < 0 THEN
      RETURN 'Los dias de pago no pueden ser negativos';
    END IF;

    IF p_cuotas < 1 THEN
      RETURN 'La cantidad de cuotas tiene que ser al menos 1';
    END IF;

    -- Contado en varias cuotas es una contradiccion: pagar en tres veces YA es
    -- un plazo, por mas que el campo de dias diga 0. Sin este control quedan
    -- condiciones como "Contado en 3 cuotas" que despues nadie sabe interpretar.
    IF p_dias = 0 AND p_cuotas > 1 THEN
      RETURN 'Una condicion de contado (0 dias) no puede tener mas de una cuota';
    END IF;

    RETURN NULL;
  END ERROR_EN_PLAZOS;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_total  NUMBER;
    l_items  CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    SELECT COUNT(*) INTO l_total FROM CONDICIONES_PAGO;

    -- Ordenado por dias y despues por cuotas: contado primero, y los plazos
    -- crecientes. Alfabetico dejaria "Credito 30" antes que "Contado", que no es
    -- el orden en que nadie piensa estas opciones.
    SELECT JSON_ARRAYAGG(fila ORDER BY dias, cuotas RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'              VALUE c.ID_CONDICION,
                 'nombreCondicion' VALUE c.NOMBRE_CONDICION,
                 -- NVL a los defaults: las filas cargadas a mano pueden tenerlos
                 -- en null, y el frontend no deberia manejar un tercer estado
                 -- para algo que siempre tiene una respuesta razonable.
                 'diasPago'        VALUE NVL(c.DIAS_PAGO, 0),
                 'cantidadCuotas'  VALUE NVL(c.CANTIDAD_CUOTAS, 1),
                 -- Cuantas facturas la usan. La pantalla lo muestra para
                 -- explicar por que una condicion en uso no se puede borrar.
                 'usos'            VALUE (SELECT COUNT(*)
                                            FROM FACTURAS_COMPRAS_CAB f
                                           WHERE f.ID_CONDICION = c.ID_CONDICION)
                 RETURNING CLOB
               ) AS fila,
               NVL(c.DIAS_PAGO, 0)       AS dias,
               NVL(c.CANTIDAD_CUOTAS, 1) AS cuotas
          FROM CONDICIONES_PAGO c
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
      APEX_DEBUG.ERROR('PKG_CONDICIONES_PAGO.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las condiciones de pago"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization    IN  VARCHAR2,
    p_nombre_condicion IN  VARCHAR2,
    p_dias_pago        IN  VARCHAR2,
    p_cantidad_cuotas  IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  ) IS
    l_sesion NUMBER;
    l_dias   NUMBER;
    l_cuotas NUMBER;
    l_error  VARCHAR2(200);
    l_id     NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van dentro del BEGIN: en el DECLARE se ejecutarian antes
    -- de que exista el EXCEPTION y el error escaparia del procedimiento. NULLIF
    -- convierte la cadena vacia del parametro ausente en NULL antes de que
    -- TO_NUMBER la toque (si no, ORA-01722).
    --
    -- Los defaults se aplican aca: sin dias ni cuotas, es contado y pago unico.
    l_dias   := NVL(TO_NUMBER(NULLIF(p_dias_pago, '')), 0);
    l_cuotas := NVL(TO_NUMBER(NULLIF(p_cantidad_cuotas, '')), 1);

    IF TRIM(p_nombre_condicion) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"El nombre de la condicion es obligatorio"}';
      RETURN;
    END IF;

    l_error := ERROR_EN_PLAZOS(l_dias, l_cuotas);
    IF l_error IS NOT NULL THEN
      p_status_code := 400;
      p_resultado := JSON_OBJECT('error' VALUE l_error);
      RETURN;
    END IF;

    IF NOMBRE_REPETIDO(p_nombre_condicion) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una condicion con ese nombre"}';
      RETURN;
    END IF;

    INSERT INTO CONDICIONES_PAGO (
      NOMBRE_CONDICION, DIAS_PAGO, CANTIDAD_CUOTAS,
      FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      TRIM(p_nombre_condicion),
      l_dias,
      l_cuotas,
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_CONDICION INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- La consulta de arriba ya cubre el caso normal; esto atrapa dos
      -- peticiones simultaneas que la pasaron las dos.
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una condicion con ese nombre"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -1722 THEN
        p_status_code := 400;
        p_resultado := '{"error":"Los dias y las cuotas tienen que ser numericos"}';
      ELSIF SQLCODE = -12899 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El nombre supera los 100 caracteres"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_CONDICIONES_PAGO.INSERTAR: [' || SQLCODE || '] ' || SQLERRM ||
                         ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear la condicion de pago"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization    IN  VARCHAR2,
    p_id               IN  VARCHAR2,
    p_nombre_condicion IN  VARCHAR2,
    p_dias_pago        IN  VARCHAR2,
    p_cantidad_cuotas  IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  ) IS
    l_sesion        NUMBER;
    l_id            NUMBER;
    l_dias          NUMBER;
    l_cuotas        NUMBER;
    l_dias_actual   NUMBER;
    l_cuotas_actual NUMBER;
    l_dias_final    NUMBER;
    l_cuotas_final  NUMBER;
    l_error         VARCHAR2(200);
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id     := TO_NUMBER(NULLIF(p_id, ''));
    l_dias   := TO_NUMBER(NULLIF(p_dias_pago, ''));
    l_cuotas := TO_NUMBER(NULLIF(p_cantidad_cuotas, ''));

    IF l_id IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id es obligatorio"}';
      RETURN;
    END IF;

    -- Se lee la fila actual antes de validar: hay que saber COMO VA A QUEDAR, no
    -- solo que llego. Un PUT que sube las cuotas a 3 sin mandar los dias puede
    -- ser valido —si ya tenia 30— o invalido si la condicion era de contado.
    -- Mirando solo los parametros, el control daria mal en uno de los dos casos.
    BEGIN
      SELECT NVL(DIAS_PAGO, 0), NVL(CANTIDAD_CUOTAS, 1)
        INTO l_dias_actual, l_cuotas_actual
        FROM CONDICIONES_PAGO
       WHERE ID_CONDICION = l_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_status_code := 404;
        p_resultado := '{"error":"La condicion no existe"}';
        RETURN;
    END;

    l_dias_final   := NVL(l_dias, l_dias_actual);
    l_cuotas_final := NVL(l_cuotas, l_cuotas_actual);

    l_error := ERROR_EN_PLAZOS(l_dias_final, l_cuotas_final);
    IF l_error IS NOT NULL THEN
      p_status_code := 400;
      p_resultado := JSON_OBJECT('error' VALUE l_error);
      RETURN;
    END IF;

    IF NOMBRE_REPETIDO(p_nombre_condicion, l_id) THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otra condicion con ese nombre"}';
      RETURN;
    END IF;

    -- Los dos numericos van con el valor YA RESUELTO de arriba, no con NVL sobre
    -- el parametro: entre ellos hay una regla cruzada (contado no admite cuotas)
    -- y aplicarlos columna por columna dejaria pasar combinaciones invalidas.
    UPDATE CONDICIONES_PAGO
       SET NOMBRE_CONDICION    = NVL(TRIM(p_nombre_condicion), NOMBRE_CONDICION),
           DIAS_PAGO           = l_dias_final,
           CANTIDAD_CUOTAS     = l_cuotas_final,
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_CONDICION = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      -- El SELECT de arriba la encontro, asi que llegar aca significa que otra
      -- sesion la borro en el medio.
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La condicion no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otra condicion con ese nombre"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -1722 THEN
        p_status_code := 400;
        p_resultado := '{"error":"Los dias y las cuotas tienen que ser numericos"}';
      ELSIF SQLCODE = -12899 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El nombre supera los 100 caracteres"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_CONDICIONES_PAGO.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM ||
                         ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar la condicion de pago"}';
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
    l_usos   PLS_INTEGER;
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

    -- Se cuenta ANTES de intentar el DELETE para poder decir CUANTAS facturas la
    -- usan. La FK igual lo impediria con ORA-02292, pero ese error no trae el
    -- numero, y "no se puede borrar" sin decir por que obliga a ir a buscarlo.
    SELECT COUNT(*) INTO l_usos
      FROM FACTURAS_COMPRAS_CAB
     WHERE ID_CONDICION = l_id;

    IF l_usos > 0 THEN
      p_status_code := 409;
      p_resultado := JSON_OBJECT(
        'error' VALUE 'No se puede eliminar: ' || TO_CHAR(l_usos) ||
                      ' factura(s) usan esta condicion'
      );
      RETURN;
    END IF;

    DELETE FROM CONDICIONES_PAGO WHERE ID_CONDICION = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La condicion no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2292 THEN
        -- La cuenta de arriba deberia haberlo evitado; esto atrapa la carrera
        -- entre las dos sentencias, o una tabla futura que tambien apunte aca
        -- (facturas de venta, por ejemplo).
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que usan esta condicion"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_CONDICIONES_PAGO.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM ||
                         ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar la condicion de pago"}';
      END IF;
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'condiciones-pago',
      p_base_path      => '/condiciones-pago/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Condiciones de pago: contado, plazos y cuotas. Catalogo global'
    );

    -- ORIGINS_ALLOWED ES POR MODULO, no por workspace: la pantalla de APEX
    -- sugiere lo contrario, pero habilitarlo en otro modulo no lo propaga a
    -- este. Sin esto, ORDS rechaza la peticion cross-origin ANTES de llegar al
    -- handler, con un "Service Unavailable" que ningun WHEN OTHERS captura
    -- porque el PL/SQL nunca llega a ejecutarse.
    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'condiciones-pago',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /condiciones-pago/listar
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'condiciones-pago', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'condiciones-pago',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_CONDICIONES_PAGO.LISTAR(:authorization, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'condiciones-pago', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'condiciones-pago', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'condiciones-pago', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /condiciones-pago/crear
    -- Body: { nombreCondicion, diasPago?, cantidadCuotas? }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'condiciones-pago', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'condiciones-pago',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_CONDICIONES_PAGO.INSERTAR(:authorization, :nombreCondicion, :diasPago, :cantidadCuotas, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'condiciones-pago', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'condiciones-pago', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'condiciones-pago', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /condiciones-pago/actualizar/:id
    -- Body: los mismos campos, todos opcionales (ausentes = no cambia).
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'condiciones-pago', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'condiciones-pago',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_CONDICIONES_PAGO.ACTUALIZAR(:authorization, :id, :nombreCondicion, :diasPago, :cantidadCuotas, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'condiciones-pago', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'condiciones-pago', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'condiciones-pago', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /condiciones-pago/eliminar/:id
    --
    -- Sin idEmpresa: es un catalogo global, igual que PAISES o PERSONAS.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'condiciones-pago', p_pattern => 'eliminar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'condiciones-pago',
      p_pattern     => 'eliminar/:id',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_CONDICIONES_PAGO.ELIMINAR(:authorization, :id, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'condiciones-pago', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'condiciones-pago', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'condiciones-pago', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_CONDICIONES_PAGO;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--------------------------------------------------------------------------------

BEGIN
  PKG_CONDICIONES_PAGO.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_CONDICIONES_PAGO'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
--
-- SI DICE QUE FACTURAS_COMPRAS_CAB NO EXISTE: este paquete la consulta para
-- contar los usos. Cree primero esa tabla (el DDL) y reejecute este archivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_CONDICIONES_PAGO'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'condiciones-pago';

-- Cuatro filas: actualizar PUT, crear POST, eliminar DELETE y listar GET.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'condiciones-pago'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

--------------------------------------------------------------------------------
-- 4. LAS CONDICIONES HABITUALES
--
-- Este archivo NO las inserta: son datos, no estructura. Lo normal es cargarlas
-- desde la pantalla, pero si la pagina todavia no esta dada de alta en el menu,
-- estos INSERT sirven para arrancar:
--
--   INSERT INTO CONDICIONES_PAGO (NOMBRE_CONDICION, DIAS_PAGO, CANTIDAD_CUOTAS)
--   VALUES ('Contado', 0, 1);
--   INSERT INTO CONDICIONES_PAGO (NOMBRE_CONDICION, DIAS_PAGO, CANTIDAD_CUOTAS)
--   VALUES ('Credito 30 dias', 30, 1);
--   INSERT INTO CONDICIONES_PAGO (NOMBRE_CONDICION, DIAS_PAGO, CANTIDAD_CUOTAS)
--   VALUES ('Credito 60 dias', 60, 1);
--   INSERT INTO CONDICIONES_PAGO (NOMBRE_CONDICION, DIAS_PAGO, CANTIDAD_CUOTAS)
--   VALUES ('Credito 90 dias', 90, 1);
--   INSERT INTO CONDICIONES_PAGO (NOMBRE_CONDICION, DIAS_PAGO, CANTIDAD_CUOTAS)
--   VALUES ('3 cuotas mensuales', 90, 3);
--   COMMIT;
--
-- Ojo con la ultima: 90 dias y 3 cuotas significa que la ULTIMA vence a los 90.
-- Este paquete no calcula vencimientos —guarda la definicion— asi que la
-- interpretacion queda del lado de quien la use.
--------------------------------------------------------------------------------

SELECT ID_CONDICION, NOMBRE_CONDICION,
       NVL(DIAS_PAGO, 0)       AS DIAS,
       NVL(CANTIDAD_CUOTAS, 1) AS CUOTAS
  FROM CONDICIONES_PAGO
 ORDER BY NVL(DIAS_PAGO, 0), NVL(CANTIDAD_CUOTAS, 1);

--------------------------------------------------------------------------------
-- Auditoria: las tres consultas que tienen que devolver CERO filas
--------------------------------------------------------------------------------

-- 1. Nombres duplicados ignorando mayusculas. El UNIQUE de la base NO los
--    detecta ('contado' y 'Contado' son distintos para Oracle) pero en pantalla
--    se leen igual, y este paquete los rechaza. Una fila aca entro a mano.
SELECT UPPER(TRIM(NOMBRE_CONDICION)) AS NOMBRE, COUNT(*) AS CANTIDAD
  FROM CONDICIONES_PAGO
 GROUP BY UPPER(TRIM(NOMBRE_CONDICION))
HAVING COUNT(*) > 1;

-- 2. Valores imposibles: dias negativos o menos de una cuota.
SELECT ID_CONDICION, NOMBRE_CONDICION, DIAS_PAGO, CANTIDAD_CUOTAS
  FROM CONDICIONES_PAGO
 WHERE NVL(DIAS_PAGO, 0) < 0
    OR NVL(CANTIDAD_CUOTAS, 1) < 1;

-- 3. Contado con mas de una cuota: la combinacion contradictoria que rechaza
--    ERROR_EN_PLAZOS. Pagar en varias veces ya es un plazo.
SELECT ID_CONDICION, NOMBRE_CONDICION, DIAS_PAGO, CANTIDAD_CUOTAS
  FROM CONDICIONES_PAGO
 WHERE NVL(DIAS_PAGO, 0) = 0
   AND NVL(CANTIDAD_CUOTAS, 1) > 1;

--------------------------------------------------------------------------------
-- Consultas utiles
--------------------------------------------------------------------------------

-- Que condicion usa cada factura, y cuando venceria segun el plazo.
--
-- El vencimiento se calcula aca y NO se guarda: es FECHA_FACTURA + DIAS_PAGO, y
-- guardarlo permitiria que quedara desfasado si se corrige la fecha o la
-- condicion.
SELECT f.ID_FACTURA,
       f.NUMERO_FACTURA,
       TO_CHAR(f.FECHA_FACTURA, 'YYYY-MM-DD') AS FECHA,
       NVL(c.NOMBRE_CONDICION, 'Sin condicion') AS CONDICION,
       NVL(c.DIAS_PAGO, 0) AS DIAS,
       TO_CHAR(f.FECHA_FACTURA + NVL(c.DIAS_PAGO, 0), 'YYYY-MM-DD') AS VENCE
  FROM FACTURAS_COMPRAS_CAB f
  LEFT JOIN CONDICIONES_PAGO c ON c.ID_CONDICION = f.ID_CONDICION
 ORDER BY f.FECHA_FACTURA DESC;

-- Cuantas facturas usan cada condicion. Las que digan 0 se pueden borrar.
SELECT c.ID_CONDICION, c.NOMBRE_CONDICION,
       NVL(c.DIAS_PAGO, 0) AS DIAS,
       COUNT(f.ID_FACTURA) AS FACTURAS
  FROM CONDICIONES_PAGO c
  LEFT JOIN FACTURAS_COMPRAS_CAB f ON f.ID_CONDICION = c.ID_CONDICION
 GROUP BY c.ID_CONDICION, c.NOMBRE_CONDICION, c.DIAS_PAGO
 ORDER BY NVL(c.DIAS_PAGO, 0);
