--------------------------------------------------------------------------------
-- CTELL · UBICACIONES
--
-- Un paquete (PKG_UBICACIONES) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicacion de los endpoints ORDS. Todo vive
-- dentro del paquete: no hay procedimientos sueltos ni PL/SQL embebido como
-- texto dentro de los handlers.
--
--   1. LISTAR      GET    /ubicaciones/listar        (?idEmpresa= &idSucursal= &conArticulos=)
--   2. INSERTAR    POST   /ubicaciones/crear
--   3. ACTUALIZAR  PUT    /ubicaciones/actualizar/:id
--   4. ELIMINAR    DELETE /ubicaciones/eliminar/:id/:idEmpresa
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/ubicaciones/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   UBICACIONES  ID_UBICACION, ID_EMPRESA, ID_SUCURSAL, ZONA, ESTANTE, NIVEL,
--                DESCRIPCION, FECHA_CREACION, FECHA_ACTUALIZACION
--
-- QUE ES: la posicion fisica de la mercaderia en un deposito — zona, estante y
-- nivel. Sirve para saber donde esta cada articulo dentro de la sucursal.
--
-- CUELGA DE EMPRESA **Y** DE SUCURSAL. Es la primera tabla del proyecto con dos
-- FK de contexto: el idEmpresa sale de la empresa activa de la sesion y el
-- idSucursal de la sucursal activa (los dos del frontend, no de combobox del
-- formulario). Por eso el listado acepta los dos filtros y el alta los recibe
-- como datos obligatorios.
--
-- OJO CON LA COHERENCIA: el DDL NO garantiza que ID_SUCURSAL pertenezca a
-- ID_EMPRESA — son dos FK independientes, y nada impide guardar la sucursal de
-- otra empresa. INSERTAR y ACTUALIZAR lo validan a mano contra SUCURSALES antes
-- de escribir, y devuelven 400 si no coinciden. Sin esa verificacion, la
-- ubicacion quedaria colgada de una sucursal ajena y el listado por empresa la
-- mostraria igual.
--
-- SIN JOIN CONTRA EMPRESAS NI SUCURSALES: el listado no devuelve sus nombres.
-- Viene filtrado por una sola empresa y una sola sucursal —las de la sesion—
-- asi que serian la misma constante repetida en cada fila, y el frontend ya las
-- tiene en los providers. Mismo criterio que db/monedas.sql.
--
-- NO TIENE COLUMNA ACTIVO, igual que DETALLE_MONEDAS: el DDL no la trae, asi que
-- la baja es fisica y no hay estado 'A'/'I' en el JSON ni endpoints de
-- activar/inactivar. Una ubicacion existe o no existe.
--
-- ZONA es VARCHAR2(10) y se guarda en MAYUSCULAS: 'a1' y 'A1' son la misma
-- ubicacion fisica, y sin normalizar el UNIQUE las trataria como distintas.
--
-- ESTANTE y NIVEL son NUMBER. Se validan > 0: un estante 0 o negativo no existe
-- en un deposito, y dejarlo pasar ensucia el orden del listado.
--
-- El UNIQUE (ID_EMPRESA, ID_SUCURSAL, ZONA, ESTANTE, NIVEL) impide dos
-- ubicaciones identicas en la misma sucursal, pero si permite la misma
-- combinacion en sucursales distintas (cada deposito tiene su zona A1). El
-- DUP_VAL_ON_INDEX se traduce a 409 con ese matiz en el mensaje.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_UBICACIONES
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_UBICACIONES.LISTAR('Bearer TU_TOKEN', NULL, NULL, p_status_code => l_status, p_resultado => l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_UBICACIONES AS

  -- Los filtros NULL o vacios no filtran. En la app siempre viajan los dos, con
  -- la empresa y la sucursal activas.
  --
  -- Devuelve ademas 'cantidadArticulos' por fila: cuantos articulos hay
  -- asignados a ese estante. Cero es un dato util —dice que se puede borrar sin
  -- romper nada— asi que va siempre, se filtre o no.
  --
  -- p_con_articulos = 'S' deja SOLO las ubicaciones que tienen algun articulo
  -- asignado. Sirve para el filtro "que hay en este estante": ofrecer los
  -- estantes vacios ahi es ofrecer busquedas que ya se sabe que no devuelven
  -- nada, y en un deposito con la grilla entera cargada son la mayoria.
  --
  -- El ABM de ubicaciones NO lo usa: ahi hay que ver los vacios, que son
  -- justamente los que se pueden editar o borrar sin romper nada.
  --
  -- CON DEFAULT, y NO es cosmetico. A este endpoint lo consumen CINCO pantallas.
  -- Un parametro obligatorio invalida toda llamada con la firma vieja, y entre
  -- que se compila el paquete y se republica el modulo ORDS hay un instante en
  -- que el handler publicado todavia manda tres argumentos: ahi se caen las
  -- cinco, no solo la nueva. Con el DEFAULT ese instante no existe.
  --
  -- POR ESO VA ULTIMO ENTRE LOS 'IN'. Un DEFAULT en el medio no sirve de nada en
  -- una llamada posicional —solo cubre los argumentos finales— y habria dado la
  -- misma rotura con la falsa sensacion de estar cubierta.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_con_articulos IN  VARCHAR2 DEFAULT NULL,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_zona          IN  VARCHAR2,
    p_estante       IN  VARCHAR2,
    p_nivel         IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Los parametros ausentes (NULL) no modifican la columna correspondiente.
  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_zona          IN  VARCHAR2,
    p_estante       IN  VARCHAR2,
    p_nivel         IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- p_id_empresa es OBLIGATORIO: acota el borrado a la empresa de la sesion.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /ubicaciones/ con sus 4 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_UBICACIONES;
/

CREATE OR REPLACE PACKAGE BODY PKG_UBICACIONES AS

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
         WHERE NAME = 'ubicaciones';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'ubicaciones');
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
  -- Privado: la sucursal existe y pertenece a esa empresa.
  --
  -- El DDL tiene las dos FK por separado, asi que por si solo acepta la
  -- sucursal de otra empresa. Esto lo cierra antes de escribir.
  ------------------------------------------------------------------------------
  FUNCTION SUCURSAL_ES_DE_EMPRESA (
    p_id_sucursal IN NUMBER,
    p_id_empresa  IN NUMBER
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_existe
      FROM SUCURSALES
     WHERE ID_SUCURSAL = p_id_sucursal
       AND ID_EMPRESA  = p_id_empresa;

    RETURN l_existe > 0;
  END SUCURSAL_ES_DE_EMPRESA;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_con_articulos IN  VARCHAR2 DEFAULT NULL,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion        NUMBER;
    l_id_empresa    NUMBER;
    l_id_sucursal   NUMBER;
    -- 'S' deja fuera los estantes vacios. Ver la nota de la spec.
    --
    -- VARCHAR2 Y NO BOOLEAN: un BOOLEAN de PL/SQL NO SE PUEDE USAR DENTRO DE UNA
    -- SENTENCIA SQL —el WHERE de abajo lo necesita— y el paquete no compilaria.
    -- Es la misma familia de trampas que los helpers privados en SQL.
    l_solo_con      VARCHAR2(1);
    l_total         NUMBER;
    l_items         CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van aca, dentro del BEGIN: en el DECLARE se ejecutarian
    -- antes de que exista el EXCEPTION y el error escaparia del procedimiento.
    -- NULLIF convierte la cadena vacia del parametro ausente en NULL antes de
    -- que TO_NUMBER la toque (si no, ORA-01722).
    l_id_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, ''));

    -- Sin empresa NO se devuelve nada. El default de "todas" que tenia antes es
    -- el error: un olvido en el cliente pasaba desapercibido justamente porque
    -- la pantalla se llenaba de datos —y de datos ajenos—.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- Solo 'S' activa el recorte. Cualquier otra cosa —vacio, 'N', basura— deja
    -- el listado completo, que es el comportamiento que ya tenia y el que usa el
    -- ABM de ubicaciones.
    l_solo_con := CASE WHEN UPPER(TRIM(p_con_articulos)) = 'S' THEN 'S' ELSE 'N' END;

    -- EL COUNT REPITE EL MISMO WHERE que la consulta de abajo, EXISTS incluido.
    -- Si filtran distinto, el total dice una cosa y las filas otra.
    SELECT COUNT(*)
      INTO l_total
      FROM UBICACIONES u
     WHERE u.ID_EMPRESA = l_id_empresa
       AND (l_id_sucursal IS NULL OR u.ID_SUCURSAL = l_id_sucursal)
       AND (l_solo_con = 'N'
            OR EXISTS (SELECT 1 FROM ARTICULOS_UBICACIONES au
                        WHERE au.ID_UBICACION = u.ID_UBICACION));

    -- Sin JOIN: la consulta sale de UBICACIONES y nada mas. Los nombres de la
    -- empresa y la sucursal no se devuelven porque el listado ya viene filtrado
    -- por una sola de cada una, y el frontend las tiene en sus providers.
    --
    -- ORDEN: zona, estante, nivel — el recorrido fisico del deposito. Alfabetico
    -- por zona y numerico por estante y nivel (son NUMBER, no hay que
    -- convertir).
    --
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: el listado anda con pocas filas y devuelve 500 cuando crece.
    SELECT JSON_ARRAYAGG(fila ORDER BY zona, estante, nivel RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'          VALUE u.ID_UBICACION,
                 'idEmpresa'   VALUE u.ID_EMPRESA,
                 'idSucursal'  VALUE u.ID_SUCURSAL,
                 'zona'        VALUE u.ZONA,
                 'estante'     VALUE u.ESTANTE,
                 'nivel'       VALUE u.NIVEL,
                 'descripcion' VALUE u.DESCRIPCION,
                 -- CUANTOS ARTICULOS TIENE ASIGNADOS. Va siempre, tambien sin
                 -- el recorte: es lo que deja mostrar "A · Estante 3 — 12
                 -- articulos" en la lista de valores, y en el ABM avisa cual
                 -- esta vacio y se puede borrar sin romper nada.
                 --
                 -- Es una subconsulta y no un JOIN con GROUP BY: agrupar por las
                 -- siete columnas del SELECT para contar una sola seria mas
                 -- fragil de leer, y ademas dejaria fuera las ubicaciones sin
                 -- articulos en vez de darles 0.
                 'cantidadArticulos' VALUE (SELECT COUNT(*)
                                              FROM ARTICULOS_UBICACIONES au
                                             WHERE au.ID_UBICACION = u.ID_UBICACION)
                 RETURNING CLOB
               ) AS fila,
               u.ZONA    AS zona,
               u.ESTANTE AS estante,
               u.NIVEL   AS nivel
          FROM UBICACIONES u
         WHERE u.ID_EMPRESA = l_id_empresa
           AND (l_id_sucursal IS NULL OR u.ID_SUCURSAL = l_id_sucursal)
           -- IDENTICO AL DEL COUNT DE ARRIBA.
           AND (l_solo_con = 'N'
                OR EXISTS (SELECT 1 FROM ARTICULOS_UBICACIONES au
                            WHERE au.ID_UBICACION = u.ID_UBICACION))
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
      APEX_DEBUG.ERROR('PKG_UBICACIONES.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las ubicaciones"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_zona          IN  VARCHAR2,
    p_estante       IN  VARCHAR2,
    p_nivel         IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id_empresa  NUMBER;
    l_id_sucursal NUMBER;
    l_estante     NUMBER;
    l_nivel       NUMBER;
    l_zona        VARCHAR2(10);
    l_id          NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    l_estante     := TO_NUMBER(NULLIF(p_estante, ''));
    l_nivel       := TO_NUMBER(NULLIF(p_nivel, ''));
    -- ZONA en mayusculas: 'a1' y 'A1' son la misma ubicacion fisica y el UNIQUE
    -- las trataria como distintas.
    l_zona        := UPPER(TRIM(p_zona));

    IF l_id_empresa IS NULL OR l_id_sucursal IS NULL OR l_zona IS NULL
       OR l_estante IS NULL OR l_nivel IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, idSucursal, zona, estante y nivel son obligatorios"}';
      RETURN;
    END IF;

    -- Un estante o nivel 0 o negativo no existe en un deposito.
    IF l_estante <= 0 OR l_nivel <= 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"Estante y nivel tienen que ser mayores a cero"}';
      RETURN;
    END IF;

    -- Las dos FK son independientes: sin esto se podria guardar la sucursal de
    -- otra empresa y la ubicacion quedaria colgada de una sucursal ajena.
    IF NOT SUCURSAL_ES_DE_EMPRESA(l_id_sucursal, l_id_empresa) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La sucursal no pertenece a la empresa indicada"}';
      RETURN;
    END IF;

    INSERT INTO UBICACIONES (
      ID_EMPRESA, ID_SUCURSAL, ZONA, ESTANTE, NIVEL, DESCRIPCION,
      FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_empresa,
      l_id_sucursal,
      l_zona,
      l_estante,
      l_nivel,
      TRIM(p_descripcion),
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_UBICACION INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- El UNIQUE es (ID_EMPRESA, ID_SUCURSAL, ZONA, ESTANTE, NIVEL): el choque
      -- es dentro de la misma sucursal, no global.
      p_status_code := 409;
      p_resultado := '{"error":"Esta sucursal ya tiene esa zona, estante y nivel"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: alguna FK no encontro el padre. Es un dato invalido del
      -- cliente (400), no un fallo del servidor.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La empresa o la sucursal indicada no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_UBICACIONES.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear la ubicacion"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_zona          IN  VARCHAR2,
    p_estante       IN  VARCHAR2,
    p_nivel         IN  VARCHAR2,
    p_descripcion   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id          NUMBER;
    l_id_empresa  NUMBER;
    l_id_sucursal NUMBER;
    l_estante     NUMBER;
    l_nivel       NUMBER;
    l_zona        VARCHAR2(10);
    -- Los valores que van a quedar tras el UPDATE, para validar la coherencia
    -- empresa/sucursal incluso cuando el pedido cambia solo uno de los dos.
    l_emp_final   NUMBER;
    l_suc_final   NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id          := TO_NUMBER(NULLIF(p_id, ''));
    l_id_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    l_estante     := TO_NUMBER(NULLIF(p_estante, ''));
    l_nivel       := TO_NUMBER(NULLIF(p_nivel, ''));
    l_zona        := UPPER(TRIM(p_zona));

    IF (l_estante IS NOT NULL AND l_estante <= 0)
       OR (l_nivel IS NOT NULL AND l_nivel <= 0) THEN
      p_status_code := 400;
      p_resultado := '{"error":"Estante y nivel tienen que ser mayores a cero"}';
      RETURN;
    END IF;

    -- AISLAMIENTO POR EMPRESA: el idEmpresa acota A CUAL fila se le aplica el
    -- cambio, no es solo un campo mas a modificar. Sin el, un PUT con el id de
    -- una ubicacion de OTRA empresa la modificaba igual — la pantalla no lo
    -- permite, pero el endpoint es publico para cualquiera con sesion.
    --
    -- Va ANTES del SELECT de abajo porque ese SELECT tambien se acota con el.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- Que sucursal va a quedar despues del UPDATE. Se resuelve ANTES de
    -- escribir porque cambiar solo la sucursal puede romper la coherencia.
    --
    -- El SELECT lleva el AND ID_EMPRESA: si la fila es de otra empresa, cae en
    -- NO_DATA_FOUND y responde 404 sin llegar a tocar nada.
    BEGIN
      SELECT l_id_empresa, NVL(l_id_sucursal, ID_SUCURSAL)
        INTO l_emp_final, l_suc_final
        FROM UBICACIONES
       WHERE ID_UBICACION = l_id
         AND ID_EMPRESA   = l_id_empresa;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_status_code := 404;
        p_resultado := '{"error":"La ubicacion no existe"}';
        RETURN;
    END;

    IF NOT SUCURSAL_ES_DE_EMPRESA(l_suc_final, l_emp_final) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La sucursal no pertenece a la empresa indicada"}';
      RETURN;
    END IF;

    -- ID_EMPRESA fuera del SET a proposito: mover una fila de empresa es lo que
    -- este control busca impedir.
    UPDATE UBICACIONES
       SET ID_SUCURSAL         = NVL(l_id_sucursal, ID_SUCURSAL),
           ZONA                = NVL(l_zona, ZONA),
           ESTANTE             = NVL(l_estante, ESTANTE),
           NIVEL               = NVL(l_nivel, NIVEL),
           DESCRIPCION         = NVL(TRIM(p_descripcion), DESCRIPCION),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_UBICACION = l_id
       AND ID_EMPRESA   = l_id_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La ubicacion no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Esta sucursal ya tiene esa zona, estante y nivel"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La empresa o la sucursal indicada no existe"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_UBICACIONES.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar la ubicacion"}';
      END IF;
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

    l_id         := TO_NUMBER(NULLIF(p_id, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    -- Obligatorio: sin empresa el DELETE alcanzaria filas de cualquiera.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- Baja FISICA: la tabla no tiene columna ACTIVO.
    -- AISLAMIENTO POR EMPRESA: las dos condiciones. Con solo el id, un DELETE
    -- con el id de una fila de otra empresa la borraba.
    DELETE FROM UBICACIONES
     WHERE ID_UBICACION = l_id
       AND ID_EMPRESA = l_id_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La ubicacion no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos (stock, movimientos, lo que cuelgue de la
      -- ubicacion) apuntando a esta fila. Es un conflicto de estado (409), no un
      -- error del servidor: el dato que mandaron era valido.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de esta ubicacion"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_UBICACIONES.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar la ubicacion"}';
      END IF;
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Publica el modulo ORDS /ubicaciones/ con sus 4 endpoints.
  --
  -- Cada handler es una sola linea: invoca al procedimiento del paquete pasando
  -- los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parametro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin
  -- esto, toda peticion cross-origin a /ubicaciones/* la rechaza ORDS antes de
  -- llegar a cualquiera de los 4 handlers. Ver la explicacion en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'ubicaciones',
      p_base_path      => '/ubicaciones/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Ubicaciones fisicas del deposito, por empresa y sucursal'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'ubicaciones',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /ubicaciones/listar?idEmpresa=&idSucursal=
    --
    -- Los query params no se declaran con DEFINE_PARAMETER: se vinculan solos
    -- al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'ubicaciones', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'ubicaciones',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_UBICACIONES.LISTAR(:authorization, :idEmpresa, :idSucursal, :conArticulos, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'ubicaciones', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'ubicaciones', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'ubicaciones', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /ubicaciones/crear
    -- Body: { idEmpresa, idSucursal, zona, estante, nivel, descripcion? }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'ubicaciones', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'ubicaciones',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_UBICACIONES.INSERTAR(:authorization, :idEmpresa, :idSucursal, :zona, :estante, :nivel, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'ubicaciones', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'ubicaciones', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'ubicaciones', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /ubicaciones/actualizar/:id
    -- Body: { idEmpresa?, idSucursal?, zona?, estante?, nivel?, descripcion? }
    --       (ausentes = no cambia)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'ubicaciones', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'ubicaciones',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_UBICACIONES.ACTUALIZAR(:authorization, :id, :idEmpresa, :idSucursal, :zona, :estante, :nivel, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'ubicaciones', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'ubicaciones', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'ubicaciones', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /ubicaciones/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'ubicaciones', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'ubicaciones',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_UBICACIONES.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'ubicaciones', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'ubicaciones', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'ubicaciones', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_UBICACIONES;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_UBICACIONES.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_UBICACIONES'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_UBICACIONES'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'ubicaciones';

-- Rutas publicadas: listar (GET), crear (POST), actualizar/:id (PUT),
-- eliminar/:id (DELETE).
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'ubicaciones'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

SELECT u.ID_UBICACION, e.NOMBRE_EMPRESA, s.NOMBRE_SUCURSAL,
       u.ZONA, u.ESTANTE, u.NIVEL, u.DESCRIPCION
  FROM UBICACIONES u
  JOIN EMPRESAS    e ON e.ID_EMPRESA  = u.ID_EMPRESA
  JOIN SUCURSALES  s ON s.ID_SUCURSAL = u.ID_SUCURSAL
 ORDER BY e.NOMBRE_EMPRESA, s.NOMBRE_SUCURSAL, u.ZONA, u.ESTANTE, u.NIVEL;

-- Coherencia empresa/sucursal: el DDL no la garantiza (son dos FK
-- independientes). Esta consulta tiene que devolver CERO filas; si devuelve
-- alguna, esa ubicacion quedo colgada de una sucursal de otra empresa.
SELECT u.ID_UBICACION, u.ID_EMPRESA AS EMPRESA_UBICACION,
       s.ID_EMPRESA AS EMPRESA_SUCURSAL, u.ZONA, u.ESTANTE, u.NIVEL
  FROM UBICACIONES u
  JOIN SUCURSALES  s ON s.ID_SUCURSAL = u.ID_SUCURSAL
 WHERE s.ID_EMPRESA != u.ID_EMPRESA;
