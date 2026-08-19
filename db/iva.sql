--------------------------------------------------------------------------------
-- CTELL · IVA
--
-- Un paquete (PKG_IVA) con los 4 procedimientos — LISTAR, INSERTAR, ACTUALIZAR,
-- ELIMINAR — y la publicacion de los endpoints ORDS.
--
--   1. LISTAR      GET    /iva/listar
--   2. INSERTAR    POST   /iva/crear
--   3. ACTUALIZAR  PUT    /iva/actualizar/:id
--   4. ELIMINAR    DELETE /iva/eliminar/:id
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX. REQUIERE
-- db/auth.sql EJECUTADO ANTES: usa PKG_AUTH para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/iva/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   IVA  ID_IVA, PORCENTAJE, IVA_DIVISION, GRAVADA_DIVISION, DESCRIPCION,
--        FECHA_CREACION, FECHA_ACTUALIZACION
--
--------------------------------------------------------------------------------
-- EDITAR UNA TASA EN USO CAMBIA FACTURAS YA EMITIDAS. TENERLO PRESENTE.
--
-- El modulo tiene ABM completo, pero hay una consecuencia que conviene entender
-- antes de tocar una tasa:
--
-- El impuesto de cada linea NO se guarda: se calcula en cada consulta como
-- SUBTOTAL / IVA_DIVISION (ver mas abajo). Entonces, cambiar el IVA_DIVISION o
-- el PORCENTAJE de una tasa cambia el desglose de TODAS las facturas que ya la
-- usaban — incluidas las de periodos ya declarados. Una factura de hace seis
-- meses pasa a mostrar otro impuesto sin que nadie la haya tocado.
--
-- Esto NO se bloquea, porque a veces es exactamente lo que se necesita: si una
-- tasa se cargo mal desde el principio, corregirla tiene que arreglar tambien
-- las facturas que salieron mal.
--
-- LO QUE SI SE HACE ES AVISAR: el listado devuelve `usos` —cuantas lineas de
-- factura dependen de cada tasa— y la pantalla lo muestra antes de dejar
-- editar. La decision queda del lado de quien la toma, informada.
--
-- Si el cambio es porque cambio la LEY (no porque estaba mal cargada), lo
-- correcto NO es editar: es crear una tasa nueva y dejar la vieja para los
-- comprobantes historicos, que son los que se declararon con la tasa anterior.
--
-- ELIMINAR es mas seguro de lo que parece: la FK de FACTURAS_COMPRA_DET impide
-- borrar una tasa en uso (ORA-02292), que el procedimiento traduce a un 409 con
-- un mensaje que explica el caso. Solo se pueden borrar las que no uso nadie.
--
--------------------------------------------------------------------------------
-- QUE ES IVA_DIVISION Y POR QUE NO ES REDUNDANTE CON PORCENTAJE
--
-- Son dos numeros para dos calculos distintos:
--
--   PORCENTAJE    la tasa nominal: 10, 5, 0. Es lo que se muestra.
--   IVA_DIVISION  el DIVISOR para desglosar el impuesto de un precio que YA LO
--                 INCLUYE: 11 para el 10%, 21 para el 5%.
--
-- En este proyecto los precios se cargan CON IVA INCLUIDO, que es como se
-- factura en Paraguay. Entonces el impuesto contenido en un monto es:
--
--     IVA = SUBTOTAL / IVA_DIVISION
--
-- y NO `SUBTOTAL * PORCENTAJE / 100`, que daria de mas. Con 110.000 al 10%:
--   correcto:   110.000 / 11        = 10.000
--   incorrecto: 110.000 * 10 / 100  = 11.000   <- cobra impuesto sobre impuesto
--
-- Por eso la columna existe: guardar el divisor evita que cada consulta lo
-- derive y se equivoque. La EXENTA (0%) tiene que llevar IVA_DIVISION = 0, y
-- toda division se protege con NULLIF para no dar ORA-01476.
--
--------------------------------------------------------------------------------
-- GRAVADA_DIVISION: EL DIVISOR DE LA BASE IMPONIBLE
--
-- La tercera columna de la familia, y la mas reciente. Es el divisor que saca el
-- GRAVADO —lo que se cobra sin impuesto— de un monto que ya lo incluye:
--
--     GRAVADO = SUBTOTAL / GRAVADA_DIVISION      (1.1 para el 10%, 1.05 para el 5%)
--
-- Con 110.000 al 10%:  110.000 / 1.1 = 100.000 de gravado.
--
-- LOS TRES NUMEROS SON LA MISMA TASA VISTA DE TRES FORMAS:
--
--   PORCENTAJE        10        la tasa nominal, para mostrar
--   IVA_DIVISION      11        saca el impuesto contenido
--   GRAVADA_DIVISION  1.1       saca la base imponible
--
-- La relacion es GRAVADA_DIVISION = 1 + PORCENTAJE/100, y IVA_DIVISION es su
-- complemento: 1/11 + 1/1.1 = 1, que es lo que hace que gravado + iva = total.
--
-- EL GRAVADO SE DIVIDE, EL IVA SE RESTA. Aunque existan los dos divisores, el
-- impuesto NO se calcula con IVA_DIVISION cuando hay GRAVADA_DIVISION:
--
--     GRAVADO = ROUND(SUBTOTAL / GRAVADA_DIVISION, 2)
--     IVA     = SUBTOTAL - GRAVADO
--
-- Redondear las dos divisiones por separado deja diferencias de un guarani: los
-- dos redondeos son independientes y su suma no tiene por que dar el subtotal.
-- Con una sola division y una resta, gravado + iva = total SIEMPRE, exacto. En
-- un libro de compras esa diferencia de una unidad por linea se acumula y no
-- cuadra contra el papel.
--
-- ES NULLABLE Y LAS FILAS VIEJAS LA TIENEN VACIA. Ahi se cae al metodo anterior
-- —IVA por division y gravado por resta—, para que las facturas cargadas antes
-- de esta columna sigan mostrando exactamente lo mismo que mostraban. La
-- eleccion del metodo se hace por fila, no global.
--
-- La EXENTA lleva GRAVADA_DIVISION = 1: el monto entero es gravado y no hay
-- impuesto. Es distinto de IVA_DIVISION, que en la exenta va en 0 — ahi el 0
-- significa "no divide nada". Dos columnas con criterios opuestos para el mismo
-- caso, asi que conviene tenerlo presente.
--
--------------------------------------------------------------------------------
-- COMO EJECUTAR
--
--   1. Frena `npm run dev` (evita ORA-00060 al borrar el modulo).
--   2. Pega este archivo entero en la hoja SQL de APEX y ejecutalo.
--   3. Revisa que PKG_IVA quede VALID y que la tabla tenga sus tasas cargadas
--      (el archivo cierra con esa consulta).
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_IVA AS

  -- Todas las tasas, para alimentar el combobox del detalle de facturas.
  -- Sin filtros ni paginado: son tres filas y no van a crecer.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /iva/ con su endpoint.
  -- Agrega una tasa nueva.
  --
  -- Los dos divisores son opcionales: si no vienen se calculan a partir del
  -- porcentaje (100/p + 1 el del IVA, 1 + p/100 el del gravado).
  PROCEDURE INSERTAR (
    p_authorization    IN  VARCHAR2,
    p_porcentaje       IN  VARCHAR2,
    p_iva_division     IN  VARCHAR2,
    p_gravada_division IN  VARCHAR2,
    p_descripcion      IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  );

  -- Los parametros ausentes (NULL) no modifican su columna.
  --
  -- OJO: cambiar el porcentaje o el divisor de una tasa EN USO cambia el
  -- desglose de las facturas que ya la usaban. Ver la nota de la cabecera.
  --
  -- Si se cambia el porcentaje y NO se mandan los divisores, LOS DOS se
  -- RECALCULAN solos: dejar los viejos con un porcentaje nuevo es la unica
  -- combinacion que garantiza cifras mal en todas las facturas.
  PROCEDURE ACTUALIZAR (
    p_authorization    IN  VARCHAR2,
    p_id               IN  VARCHAR2,
    p_porcentaje       IN  VARCHAR2,
    p_iva_division     IN  VARCHAR2,
    p_gravada_division IN  VARCHAR2,
    p_descripcion      IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  );

  -- Baja fisica. Una tasa EN USO no se puede borrar: la FK del detalle de
  -- facturas lo impide, y el procedimiento lo devuelve como 409.
  PROCEDURE ELIMINAR (
    p_authorization  IN  VARCHAR2,
    p_id             IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
  );

  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_IVA;
/

CREATE OR REPLACE PACKAGE BODY PKG_IVA AS

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
         WHERE NAME = 'iva';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'iva');
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

    SELECT COUNT(*) INTO l_total FROM IVA;

    SELECT JSON_ARRAYAGG(fila ORDER BY porcentaje DESC RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'           VALUE i.ID_IVA,
                 'porcentaje'   VALUE i.PORCENTAJE,
                 -- El divisor para desglosar el impuesto de un precio que ya lo
                 -- incluye. Viaja al frontend para que la pantalla pueda mostrar
                 -- el desglose sin volver a pedirlo. Ver la nota de la cabecera.
                 'ivaDivision'  VALUE i.IVA_DIVISION,
                 -- El divisor de la base imponible: 1.1 para el 10%. NULL en las
                 -- filas cargadas antes de que existiera la columna, y ahi el
                 -- calculo cae al metodo anterior — por eso viaja tal cual, sin
                 -- NVL: el frontend necesita distinguir "no tiene" de "es 1".
                 'gravadaDivision' VALUE i.GRAVADA_DIVISION,
                 -- NVL para que el combobox tenga siempre algo que mostrar: sin
                 -- descripcion cargada, la etiqueta queda vacia y la opcion
                 -- parece un bug.
                 'descripcion'  VALUE NVL(i.DESCRIPCION, 'IVA ' || TO_CHAR(i.PORCENTAJE) || '%'),
                 -- Cuantas lineas de factura la usan. La pantalla lo muestra
                 -- para dejar claro por que una tasa en uso no se puede tocar —
                 -- sin el numero, la ausencia de botones parece un olvido.
                 --
                 -- Subconsulta y no JOIN con GROUP BY: son tres filas, y agrupar
                 -- toda la consulta para contar una columna seria mas fragil de
                 -- leer por ninguna ganancia.
                 'usos'         VALUE (SELECT COUNT(*)
                                         FROM FACTURAS_COMPRA_DET d
                                        WHERE d.ID_IVA = i.ID_IVA)
                 RETURNING CLOB
               ) AS fila,
               i.PORCENTAJE AS porcentaje
          FROM IVA i
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
      APEX_DEBUG.ERROR('PKG_IVA.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar las tasas de IVA"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization    IN  VARCHAR2,
    p_porcentaje       IN  VARCHAR2,
    p_iva_division     IN  VARCHAR2,
    p_gravada_division IN  VARCHAR2,
    p_descripcion      IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  ) IS
    l_sesion       NUMBER;
    l_porcentaje   NUMBER;
    l_division     NUMBER;
    l_gravada      NUMBER;
    l_repetido     PLS_INTEGER;
    l_id           NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van dentro del BEGIN: en el DECLARE se ejecutarian antes
    -- de que exista el EXCEPTION y el error escaparia del procedimiento.
    l_porcentaje := TO_NUMBER(NULLIF(p_porcentaje, ''));
    l_division   := TO_NUMBER(NULLIF(p_iva_division, ''));
    l_gravada    := TO_NUMBER(NULLIF(p_gravada_division, ''));

    IF l_porcentaje IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"El porcentaje es obligatorio"}';
      RETURN;
    END IF;

    -- Una tasa negativa no existe, y arriba de 100 tampoco tiene sentido: el
    -- impuesto no puede superar al monto.
    IF l_porcentaje < 0 OR l_porcentaje > 100 THEN
      p_status_code := 400;
      p_resultado := '{"error":"El porcentaje tiene que estar entre 0 y 100"}';
      RETURN;
    END IF;

    -- EL DIVISOR SE CALCULA SI NO VIENE, y esa es la parte que evita el error
    -- mas caro de esta tabla: un IVA_DIVISION mal cargado da mal el desglose de
    -- TODAS las facturas que usen la tasa, sin fallar nunca.
    --
    -- La relacion es 100/porcentaje + 1: para 10 da 11, para 5 da 21.
    --
    -- LA EXENTA ES EL CASO ESPECIAL: con porcentaje 0 la formula dividiria por
    -- cero, y ademas el divisor correcto ahi es 0 —no 1—. Con 1, el desglose
    -- diria que TODO el monto es impuesto.
    IF l_division IS NULL THEN
      l_division := CASE
                      WHEN l_porcentaje = 0 THEN 0
                      ELSE ROUND(100 / l_porcentaje + 1, 2)
                    END;
    END IF;

    -- Si lo mandaron, se verifica que sea coherente en vez de aceptarlo tal
    -- cual: es el numero con el que se calcula el impuesto de cada factura, y un
    -- valor equivocado no da ningun error, solo cifras mal.
    IF l_porcentaje = 0 AND l_division != 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"Una tasa exenta tiene que llevar divisor 0"}';
      RETURN;
    END IF;

    IF l_porcentaje > 0
       AND ABS(l_division - (100 / l_porcentaje + 1)) > 0.01 THEN
      p_status_code := 400;
      p_resultado := JSON_OBJECT(
        'error' VALUE 'El divisor de IVA de una tasa del ' || TO_CHAR(l_porcentaje) ||
                      '% tiene que ser ' || TO_CHAR(ROUND(100 / l_porcentaje + 1, 2))
      );
      RETURN;
    END IF;

    -- EL DIVISOR DEL GRAVADO, con la misma logica pero OTRA formula: es
    -- 1 + porcentaje/100 (1.1 para el 10%), no 100/porcentaje + 1.
    --
    -- Y la exenta va en 1, NO en 0 como el de IVA: el monto entero es gravado,
    -- asi que dividir por 1 lo deja igual. Un 0 aca daria division por cero.
    -- Los dos criterios opuestos para el mismo caso son la parte facil de
    -- confundir de esta tabla.
    IF l_gravada IS NULL THEN
      l_gravada := ROUND(1 + l_porcentaje / 100, 2);
    END IF;

    IF ABS(l_gravada - (1 + l_porcentaje / 100)) > 0.01 THEN
      p_status_code := 400;
      p_resultado := JSON_OBJECT(
        'error' VALUE 'El divisor de gravada de una tasa del ' || TO_CHAR(l_porcentaje) ||
                      '% tiene que ser ' || TO_CHAR(ROUND(1 + l_porcentaje / 100, 2))
      );
      RETURN;
    END IF;

    -- El UNIQUE es sobre PORCENTAJE. Se consulta antes de insertar para poder
    -- explicar el choque: DUP_VAL_ON_INDEX no dice cual indice fallo.
    SELECT COUNT(*) INTO l_repetido
      FROM IVA WHERE PORCENTAJE = l_porcentaje;

    IF l_repetido > 0 THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una tasa con ese porcentaje"}';
      RETURN;
    END IF;

    INSERT INTO IVA (PORCENTAJE, IVA_DIVISION, GRAVADA_DIVISION, DESCRIPCION,
                     FECHA_CREACION, FECHA_ACTUALIZACION)
    VALUES (l_porcentaje,
            l_division,
            l_gravada,
            -- Sin descripcion, una armada con el porcentaje: el combobox del
            -- detalle de facturas muestra este campo, y vacio la opcion parece
            -- un bug.
            NVL(TRIM(p_descripcion),
                CASE WHEN l_porcentaje = 0
                     THEN 'Exenta'
                     ELSE 'IVA ' || TO_CHAR(l_porcentaje) || '%' END),
            SYSTIMESTAMP,
            SYSTIMESTAMP)
    RETURNING ID_IVA INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT(
      'id'              VALUE l_id,
      'ivaDivision'     VALUE l_division,
      'gravadaDivision' VALUE l_gravada,
      'ok'              VALUE 'true' FORMAT JSON
    );
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe una tasa con ese porcentaje"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -1722 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El porcentaje y el divisor tienen que ser numericos"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_IVA.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear la tasa de IVA"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization    IN  VARCHAR2,
    p_id               IN  VARCHAR2,
    p_porcentaje       IN  VARCHAR2,
    p_iva_division     IN  VARCHAR2,
    p_gravada_division IN  VARCHAR2,
    p_descripcion      IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  ) IS
    l_sesion          NUMBER;
    l_id              NUMBER;
    l_porcentaje      NUMBER;
    l_division        NUMBER;
    l_gravada         NUMBER;
    l_porc_actual     NUMBER;
    l_division_actual NUMBER;
    l_gravada_actual  NUMBER;
    l_porc_final      NUMBER;
    l_division_final  NUMBER;
    l_gravada_final   NUMBER;
    l_repetido        PLS_INTEGER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id         := TO_NUMBER(NULLIF(p_id, ''));
    l_porcentaje := TO_NUMBER(NULLIF(p_porcentaje, ''));
    l_division   := TO_NUMBER(NULLIF(p_iva_division, ''));
    l_gravada    := TO_NUMBER(NULLIF(p_gravada_division, ''));

    IF l_id IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id es obligatorio"}';
      RETURN;
    END IF;

    -- Se lee la fila actual antes de decidir nada: hay que saber COMO VA A
    -- QUEDAR, no solo que llego. Un PUT que cambia el porcentaje sin mandar los
    -- divisores necesita recalcularlos, y para eso hace falta el valor viejo.
    BEGIN
      SELECT PORCENTAJE, IVA_DIVISION, GRAVADA_DIVISION
        INTO l_porc_actual, l_division_actual, l_gravada_actual
        FROM IVA
       WHERE ID_IVA = l_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_status_code := 404;
        p_resultado := '{"error":"La tasa no existe"}';
        RETURN;
    END;

    l_porc_final := NVL(l_porcentaje, l_porc_actual);

    IF l_porc_final < 0 OR l_porc_final > 100 THEN
      p_status_code := 400;
      p_resultado := '{"error":"El porcentaje tiene que estar entre 0 y 100"}';
      RETURN;
    END IF;

    -- EL DIVISOR SE RECALCULA SI CAMBIO EL PORCENTAJE Y NO LO MANDARON.
    --
    -- Es el caso peligroso de este procedimiento: con NVL(l_division,
    -- l_division_actual) a secas, cambiar el porcentaje de 10 a 5 dejaria el
    -- divisor en 11 —el del 10%— y TODAS las facturas con esa tasa pasarian a
    -- desglosar mal, sin ningun error visible.
    IF l_division IS NOT NULL THEN
      l_division_final := l_division;
    ELSIF l_porcentaje IS NOT NULL AND l_porcentaje != l_porc_actual THEN
      l_division_final := CASE
                            WHEN l_porc_final = 0 THEN 0
                            ELSE ROUND(100 / l_porc_final + 1, 2)
                          END;
    ELSE
      l_division_final := l_division_actual;
    END IF;

    -- Mismo criterio para el divisor del gravado, con dos diferencias:
    --   * la formula es 1 + porcentaje/100, no 100/porcentaje + 1;
    --   * tambien se calcula si venia en NULL, que es el caso de todas las filas
    --     cargadas antes de que la columna existiera. Guardar una tasa vieja la
    --     completa, sin necesidad de migrar nada a mano.
    IF l_gravada IS NOT NULL THEN
      l_gravada_final := l_gravada;
    ELSIF l_gravada_actual IS NULL
          OR (l_porcentaje IS NOT NULL AND l_porcentaje != l_porc_actual) THEN
      l_gravada_final := ROUND(1 + l_porc_final / 100, 2);
    ELSE
      l_gravada_final := l_gravada_actual;
    END IF;

    -- La misma coherencia que exige INSERTAR: el divisor tiene que corresponder
    -- al porcentaje con el que va a quedar la fila.
    IF l_porc_final = 0 AND l_division_final != 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"Una tasa exenta tiene que llevar divisor 0"}';
      RETURN;
    END IF;

    IF l_porc_final > 0
       AND ABS(l_division_final - (100 / l_porc_final + 1)) > 0.01 THEN
      p_status_code := 400;
      p_resultado := JSON_OBJECT(
        'error' VALUE 'El divisor de IVA de una tasa del ' || TO_CHAR(l_porc_final) ||
                      '% tiene que ser ' || TO_CHAR(ROUND(100 / l_porc_final + 1, 2))
      );
      RETURN;
    END IF;

    -- La exenta va en 1 aca (el monto entero es gravado), al reves que el
    -- divisor de IVA que va en 0. La formula lo cubre sola: 1 + 0/100 = 1.
    IF ABS(l_gravada_final - (1 + l_porc_final / 100)) > 0.01 THEN
      p_status_code := 400;
      p_resultado := JSON_OBJECT(
        'error' VALUE 'El divisor de gravada de una tasa del ' || TO_CHAR(l_porc_final) ||
                      '% tiene que ser ' || TO_CHAR(ROUND(1 + l_porc_final / 100, 2))
      );
      RETURN;
    END IF;

    -- El UNIQUE es sobre PORCENTAJE, excluyendo la propia fila: sin el
    -- AND ID_IVA != l_id, guardar una tasa sin cambiarle el porcentaje
    -- chocaria contra si misma.
    IF l_porcentaje IS NOT NULL THEN
      SELECT COUNT(*) INTO l_repetido
        FROM IVA
       WHERE PORCENTAJE = l_porc_final
         AND ID_IVA    != l_id;

      IF l_repetido > 0 THEN
        p_status_code := 409;
        p_resultado := '{"error":"Ya existe otra tasa con ese porcentaje"}';
        RETURN;
      END IF;
    END IF;

    -- El porcentaje y el divisor van con el valor YA RESUELTO de arriba, no con
    -- NVL sobre el parametro: entre los dos hay una relacion que aplicarlos
    -- columna por columna romperia. La descripcion SI usa NVL, que es
    -- independiente.
    UPDATE IVA
       SET PORCENTAJE          = l_porc_final,
           IVA_DIVISION        = l_division_final,
           GRAVADA_DIVISION    = l_gravada_final,
           DESCRIPCION         = NVL(TRIM(p_descripcion), DESCRIPCION),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_IVA = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      -- El SELECT de arriba la encontro, asi que llegar aca significa que otra
      -- sesion la borro en el medio.
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La tasa no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    -- Se devuelven los divisores con los que quedo: si se recalcularon solos, la
    -- pantalla puede mostrarlos sin volver a pedir el listado.
    p_resultado := JSON_OBJECT(
      'ivaDivision'     VALUE l_division_final,
      'gravadaDivision' VALUE l_gravada_final,
      'ok'              VALUE 'true' FORMAT JSON
    );
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Ya existe otra tasa con ese porcentaje"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -1722 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El porcentaje y el divisor tienen que ser numericos"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_IVA.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar la tasa de IVA"}';
      END IF;
  END ACTUALIZAR;

  PROCEDURE ELIMINAR (
    p_authorization  IN  VARCHAR2,
    p_id             IN  VARCHAR2,
    p_status_code    OUT NUMBER,
    p_resultado      OUT CLOB
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
      FROM FACTURAS_COMPRA_DET
     WHERE ID_IVA = l_id;

    IF l_usos > 0 THEN
      p_status_code := 409;
      p_resultado := JSON_OBJECT(
        'error' VALUE 'No se puede eliminar: ' || TO_CHAR(l_usos) ||
                      ' linea(s) de factura usan esta tasa'
      );
      RETURN;
    END IF;

    DELETE FROM IVA WHERE ID_IVA = l_id;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La tasa no existe"}';
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
        -- entre las dos sentencias, o una tabla futura que tambien apunte a IVA.
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay facturas que usan esta tasa"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_IVA.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar la tasa de IVA"}';
      END IF;
  END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'iva',
      p_base_path      => '/iva/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Tasas de IVA (solo lectura): las fija la ley, no el usuario'
    );

    -- ORIGINS_ALLOWED ES POR MODULO, no por workspace: habilitarlo en otro
    -- modulo no lo propaga a este. Sin esto, ORDS rechaza la peticion
    -- cross-origin ANTES de llegar al handler, con un "Service Unavailable" que
    -- ningun WHEN OTHERS captura porque el PL/SQL nunca llega a ejecutarse.
    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'iva',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /iva/listar
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'iva', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'iva',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_IVA.LISTAR(:authorization, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'iva', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'iva', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'iva', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /iva/crear
    -- Body: { porcentaje, ivaDivision?, descripcion? }
    --
    -- NO hay PUT ni DELETE, a proposito: ver la cabecera del archivo.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'iva', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'iva',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_IVA.INSERTAR(:authorization, :porcentaje, :ivaDivision, :gravadaDivision, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'iva', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'iva', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'iva', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /iva/actualizar/:id
    -- Body: { porcentaje?, ivaDivision?, descripcion? }  (ausentes = no cambia)
    --
    -- Cambiar el porcentaje sin mandar el divisor lo RECALCULA solo.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'iva', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'iva',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_IVA.ACTUALIZAR(:authorization, :id, :porcentaje, :ivaDivision, :gravadaDivision, :descripcion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'iva', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'iva', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'iva', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /iva/eliminar/:id
    --
    -- Sin idEmpresa: IVA es un catalogo global, igual que PAISES o PERSONAS.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'iva', p_pattern => 'eliminar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'iva',
      p_pattern     => 'eliminar/:id',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_IVA.ELIMINAR(:authorization, :id, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'iva', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'iva', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'iva', p_pattern => 'eliminar/:id', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_IVA;
/

--------------------------------------------------------------------------------
-- 2. Publicacion del endpoint
--------------------------------------------------------------------------------

BEGIN
  PKG_IVA.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_IVA'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_IVA'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'iva';

-- Cuatro filas: actualizar PUT, crear POST, eliminar DELETE y listar GET.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'iva'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

--------------------------------------------------------------------------------
-- 4. LAS TASAS TIENEN QUE ESTAR CARGADAS
--
-- Este archivo NO las inserta: son datos, no estructura. Si la consulta de abajo
-- viene vacia, el combobox del detalle de facturas va a salir sin opciones.
--
-- LO NORMAL ES CARGARLAS DESDE LA PANTALLA, que ademas calcula el divisor sola.
-- Los INSERT de abajo quedan para el arranque, antes de que la pagina este dada
-- de alta en el menu.
--
-- Las tres tasas de Paraguay:
--
--   INSERT INTO IVA (PORCENTAJE, IVA_DIVISION, GRAVADA_DIVISION, DESCRIPCION)
--   VALUES (10, 11, 1.1, 'IVA 10%');
--   INSERT INTO IVA (PORCENTAJE, IVA_DIVISION, GRAVADA_DIVISION, DESCRIPCION)
--   VALUES (5, 21, 1.05, 'IVA 5%');
--   INSERT INTO IVA (PORCENTAJE, IVA_DIVISION, GRAVADA_DIVISION, DESCRIPCION)
--   VALUES (0, 0, 1, 'Exenta');
--   COMMIT;
--
-- LOS DOS DIVISORES USAN CRITERIOS OPUESTOS PARA LA EXENTA, y es la parte facil
-- de equivocar:
--
--   IVA_DIVISION      va en 0  — "no divide nada, no hay impuesto"
--   GRAVADA_DIVISION  va en 1  — "el monto entero es gravado"
--
-- Con IVA_DIVISION en 1, el desglose diria que TODO el monto es impuesto. Con
-- GRAVADA_DIVISION en 0, seria una division por cero. Ninguno de los dos falla
-- de forma visible: dan cifras mal.
--
-- Si las tasas ya estaban cargadas antes de que existiera GRAVADA_DIVISION,
-- alcanza con completarlas:
--
--   UPDATE IVA SET GRAVADA_DIVISION = ROUND(1 + PORCENTAJE / 100, 2)
--    WHERE GRAVADA_DIVISION IS NULL;
--   COMMIT;
--
-- No es obligatorio: con la columna en NULL el calculo cae al metodo anterior y
-- las facturas siguen mostrando lo mismo. Pero conviene, porque el metodo nuevo
-- garantiza que gravado + iva = total exacto.
--------------------------------------------------------------------------------

SELECT ID_IVA, PORCENTAJE, IVA_DIVISION, GRAVADA_DIVISION, DESCRIPCION
  FROM IVA
 ORDER BY PORCENTAJE DESC;

-- Coherencia de IVA_DIVISION. Debe devolver CERO filas.
--
-- La relacion correcta es 100/PORCENTAJE + 1: para 10 da 11, para 5 da 21. Una
-- fila aca significa que el desglose de esa tasa va a dar mal en todas las
-- facturas que la usen, sin ningun error visible.
SELECT ID_IVA, PORCENTAJE, IVA_DIVISION,
       ROUND(100 / NULLIF(PORCENTAJE, 0) + 1, 2) AS DIVISION_ESPERADA
  FROM IVA
 WHERE PORCENTAJE != 0
   AND ABS(IVA_DIVISION - (100 / NULLIF(PORCENTAJE, 0) + 1)) > 0.01;

-- Y la exenta con divisor de IVA distinto de 0. Tambien CERO filas.
SELECT ID_IVA, PORCENTAJE, IVA_DIVISION
  FROM IVA
 WHERE PORCENTAJE = 0
   AND NVL(IVA_DIVISION, 0) != 0;

-- Coherencia de GRAVADA_DIVISION, con SU formula: 1 + PORCENTAJE/100. Para 10
-- da 1.1, para 5 da 1.05, y para la exenta 1. CERO filas.
--
-- Las que la tengan en NULL no aparecen y no son un error: ahi el calculo cae al
-- metodo anterior. Se listan en la consulta siguiente.
SELECT ID_IVA, PORCENTAJE, GRAVADA_DIVISION,
       ROUND(1 + PORCENTAJE / 100, 2) AS GRAVADA_ESPERADA
  FROM IVA
 WHERE GRAVADA_DIVISION IS NOT NULL
   AND ABS(GRAVADA_DIVISION - (1 + PORCENTAJE / 100)) > 0.01;

-- Tasas sin GRAVADA_DIVISION cargada. NO es un error —el calculo funciona
-- igual— pero esas usan el metodo viejo, donde gravado + iva puede diferir del
-- total en un guarani por redondeo. El UPDATE de arriba las completa.
SELECT ID_IVA, PORCENTAJE, DESCRIPCION
  FROM IVA
 WHERE GRAVADA_DIVISION IS NULL;
