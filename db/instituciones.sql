--------------------------------------------------------------------------------
-- CTELL · INSTITUCIONES
--
-- Un paquete (PKG_INSTITUCIONES) con los 4 procedimientos — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — y la publicacion de los endpoints ORDS. Todo vive
-- dentro del paquete: no hay procedimientos sueltos ni PL/SQL embebido como
-- texto dentro de los handlers.
--
--   1. LISTAR      GET    /instituciones/listar
--                         (?idEmpresa= &idPais= &idDepartamento= &idCiudad=)
--   2. INSERTAR    POST   /instituciones/crear
--   3. ACTUALIZAR  PUT    /instituciones/actualizar/:id
--   4. ELIMINAR    DELETE /instituciones/eliminar/:id/:idEmpresa
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/instituciones/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   INSTITUCIONES  ID_INSTITUCION, ID_EMPRESA, ID_PAIS, ID_DEPARTAMENTO,
--                  ID_CIUDAD, NOMBRE_INSTITUCION, DIRECCION, DIRECTOR,
--                  CONTACTO, CORREO, UBICACION, FECHA_CREACION,
--                  FECHA_ACTUALIZACION
--
-- LA INSTITUCION ES POR EMPRESA. Cada empresa tiene su propio padron: el
-- idEmpresa sale de la empresa que se eligio al iniciar sesion, no de un
-- combobox del formulario. Por eso el listado se filtra por ?idEmpresa= y el
-- alta lo recibe como dato obligatorio.
--
--------------------------------------------------------------------------------
-- LA JERARQUIA GEOGRAFICA VIENE DESNORMALIZADA, Y ESO HAY QUE VALIDARLO
--
-- El DDL guarda las TRES columnas —ID_PAIS, ID_DEPARTAMENTO e ID_CIUDAD— aunque
-- el pais se deduce del departamento y el departamento de la ciudad:
--
--   PAISES  <--  DEPARTAMENTOS  <--  CIUDADES
--
-- Cada FK se valida CONTRA SU PROPIA TABLA Y NADA MAS, asi que la base acepta
-- sin chistar una institucion con el pais de Paraguay, un departamento de
-- Argentina y una ciudad de Brasil. Las tres filas existen; que no tengan nada
-- que ver entre si no lo detecta ninguna constraint.
--
-- Es el mismo problema que db/ubicaciones.sql resolvio con
-- SUCURSAL_ES_DE_EMPRESA, y se resuelve igual: helpers privados que comprueban
-- la cadena ANTES de escribir, y 400 si no cierra.
--
--   DEPARTAMENTO_ES_DE_PAIS(dep, pais)     DEPARTAMENTOS.ID_PAIS = pais
--   CIUDAD_ES_DE_DEPARTAMENTO(ciu, dep)    CIUDADES.ID_DEPARTAMENTO = dep
--
-- EN EL ACTUALIZAR SE VALIDA LA FILA FINAL, no los parametros recibidos: un PUT
-- que cambia solo la ciudad —dejando el departamento como estaba— tambien puede
-- romper la cadena. Se leen los valores actuales, se aplica el NVL y recien
-- entonces se valida el trio resultante.
--
-- ID_CIUDAD ES OPCIONAL (el DDL la deja nullable) y las otras dos no. Una
-- institucion en una zona rural puede no tener ciudad asignada; pais y
-- departamento siempre se saben.
--
--------------------------------------------------------------------------------
-- NO HAY COLUMNA ACTIVO
--
-- El DDL no la trae, asi que la baja es FISICA, como en DETALLE_MONEDAS y
-- LISTAS_DESCUENTOS. No hay /inactivar ni /activar, y el ACTUALIZAR no recibe
-- p_activo. Una institucion existe o no existe.
--
--------------------------------------------------------------------------------
-- CON JOIN CONTRA LA GEOGRAFIA, SIN JOIN CONTRA EMPRESAS
--
-- El listado devuelve los NOMBRES de pais, departamento y ciudad ademas de sus
-- ids: son un dato DISTINTO POR FILA —cada institucion esta en un lugar— y sin
-- ellos la pantalla tendria que pedir las tres tablas enteras para mostrar una
-- linea legible.
--
-- El nombre de la empresa NO se devuelve: el listado ya viene filtrado por una
-- sola —la de la sesion— asi que seria la misma constante repetida en cada
-- fila. Mismo criterio que db/monedas.sql.
--
-- LEFT JOIN CONTRA CIUDADES, INNER contra las otras dos: ID_CIUDAD es nullable
-- y con un JOIN interno las instituciones sin ciudad desapareceran del listado
-- sin ningun error visible.
--
--------------------------------------------------------------------------------
-- UBICACION ES TEXTO LIBRE, NO UNA FK
--
-- A pesar del nombre no tiene nada que ver con la tabla UBICACIONES (que son
-- posiciones dentro de un deposito). Aca es la ubicacion geografica en texto
-- —coordenadas, un link de mapa, una referencia— y por eso es VARCHAR2(500)
-- suelto. El comentario del DDL lo confirma.
--
-- SIN UNIQUE: el DDL no declara ninguno. Dos instituciones con el mismo nombre
-- en la misma empresa son legales —dos sedes del mismo colegio, por ejemplo— y
-- por eso este paquete NO maneja DUP_VAL_ON_INDEX: no hay indice unico que
-- pueda violarse.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_INSTITUCIONES
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_INSTITUCIONES.LISTAR('Bearer TU_TOKEN', NULL, NULL, NULL, NULL,
--                              l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_INSTITUCIONES AS

  -- Los filtros NULL o vacios no filtran. En la app siempre viaja idEmpresa
  -- (la de la sesion); los geograficos solo cuando se acota la busqueda.
  PROCEDURE LISTAR (
    p_authorization   IN  VARCHAR2,
    p_id_empresa      IN  VARCHAR2,
    p_id_pais         IN  VARCHAR2,
    p_id_departamento IN  VARCHAR2,
    p_id_ciudad       IN  VARCHAR2,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  );

  -- idEmpresa, idPais, idDepartamento y nombreInstitucion son obligatorios.
  -- idCiudad es opcional (el DDL la deja nullable).
  PROCEDURE INSERTAR (
    p_authorization      IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_id_pais            IN  VARCHAR2,
    p_id_departamento    IN  VARCHAR2,
    p_id_ciudad          IN  VARCHAR2,
    p_nombre_institucion IN  VARCHAR2,
    p_direccion          IN  VARCHAR2,
    p_director           IN  VARCHAR2,
    p_contacto           IN  VARCHAR2,
    p_correo             IN  VARCHAR2,
    p_ubicacion          IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  );

  -- Los parametros ausentes (NULL) no modifican la columna correspondiente.
  --
  -- CONSECUENCIA EN LOS OPCIONALES: mandarlos vacios significa "no cambiar", no
  -- "borrar el dato". Para vaciar idCiudad se manda el literal 'null' — ver
  -- LIMPIA en el body.
  PROCEDURE ACTUALIZAR (
    p_authorization      IN  VARCHAR2,
    p_id                 IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_id_pais            IN  VARCHAR2,
    p_id_departamento    IN  VARCHAR2,
    p_id_ciudad          IN  VARCHAR2,
    p_nombre_institucion IN  VARCHAR2,
    p_direccion          IN  VARCHAR2,
    p_director           IN  VARCHAR2,
    p_contacto           IN  VARCHAR2,
    p_correo             IN  VARCHAR2,
    p_ubicacion          IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  );

  -- p_id_empresa es OBLIGATORIO: acota el borrado a la empresa de la sesion.
  -- Sin el, un DELETE con el id de una institucion ajena la borraba igual.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /instituciones/ con sus 4 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_INSTITUCIONES;
/

CREATE OR REPLACE PACKAGE BODY PKG_INSTITUCIONES AS

  -- Valor que el cliente manda para BORRAR un campo opcional, distinto de "no
  -- lo mando" (que significa no cambiar). Ver ACTUALIZAR.
  C_BORRAR CONSTANT VARCHAR2(4) := 'null';

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
         WHERE NAME = 'instituciones';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'instituciones');
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
  -- Privado: texto -> NUMBER, tolerando el vacio y el literal 'null'.
  --
  -- NULLIF antes de TO_NUMBER: el parametro ausente llega como cadena vacia y
  -- TO_NUMBER('') da ORA-01722.
  ------------------------------------------------------------------------------
  FUNCTION A_NUMERO (p_texto IN VARCHAR2) RETURN NUMBER IS
  BEGIN
    IF LOWER(TRIM(p_texto)) = C_BORRAR THEN
      RETURN NULL;
    END IF;
    RETURN TO_NUMBER(NULLIF(TRIM(p_texto), ''));
  END A_NUMERO;

  ------------------------------------------------------------------------------
  -- Privado: true si el cliente pidio explicitamente BORRAR el campo.
  --
  -- Hace falta porque en el ACTUALIZAR "no mandar nada" ya significa "no
  -- cambiar": sin un valor distinto, quitarle la ciudad a una institucion que
  -- ya la tiene seria imposible por la API.
  ------------------------------------------------------------------------------
  FUNCTION LIMPIA (p_texto IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN LOWER(TRIM(p_texto)) = C_BORRAR;
  END LIMPIA;

  ------------------------------------------------------------------------------
  -- Privado: el departamento pertenece a ese pais?
  --
  -- Las FK garantizan que los dos existan, no que tengan que ver entre si. Ver
  -- la explicacion en la cabecera del archivo.
  ------------------------------------------------------------------------------
  FUNCTION DEPARTAMENTO_ES_DE_PAIS (
    p_id_departamento IN NUMBER,
    p_id_pais         IN NUMBER
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_existe
      FROM DEPARTAMENTOS
     WHERE ID_DEPARTAMENTO = p_id_departamento
       AND ID_PAIS         = p_id_pais;

    RETURN l_existe > 0;
  END DEPARTAMENTO_ES_DE_PAIS;

  ------------------------------------------------------------------------------
  -- Privado: la ciudad pertenece a ese departamento?
  --
  -- Con la de arriba alcanza para cerrar la cadena entera: si la ciudad es del
  -- departamento y el departamento es del pais, la ciudad es del pais.
  ------------------------------------------------------------------------------
  FUNCTION CIUDAD_ES_DE_DEPARTAMENTO (
    p_id_ciudad       IN NUMBER,
    p_id_departamento IN NUMBER
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_existe
      FROM CIUDADES
     WHERE ID_CIUDAD       = p_id_ciudad
       AND ID_DEPARTAMENTO = p_id_departamento;

    RETURN l_existe > 0;
  END CIUDAD_ES_DE_DEPARTAMENTO;

  PROCEDURE LISTAR (
    p_authorization   IN  VARCHAR2,
    p_id_empresa      IN  VARCHAR2,
    p_id_pais         IN  VARCHAR2,
    p_id_departamento IN  VARCHAR2,
    p_id_ciudad       IN  VARCHAR2,
    p_status_code     OUT NUMBER,
    p_resultado       OUT CLOB
  ) IS
    l_sesion          NUMBER;
    l_id_empresa      NUMBER;
    l_id_pais         NUMBER;
    l_id_departamento NUMBER;
    l_id_ciudad       NUMBER;
    l_total           NUMBER;
    l_items           CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Las conversiones van aca, dentro del BEGIN: en el DECLARE se ejecutarian
    -- antes de que exista el EXCEPTION y el error escaparia del procedimiento.
    l_id_empresa      := A_NUMERO(p_id_empresa);
    l_id_pais         := A_NUMERO(p_id_pais);
    l_id_departamento := A_NUMERO(p_id_departamento);
    l_id_ciudad       := A_NUMERO(p_id_ciudad);

    SELECT COUNT(*)
      INTO l_total
      FROM INSTITUCIONES
     WHERE (l_id_empresa      IS NULL OR ID_EMPRESA      = l_id_empresa)
       AND (l_id_pais         IS NULL OR ID_PAIS         = l_id_pais)
       AND (l_id_departamento IS NULL OR ID_DEPARTAMENTO = l_id_departamento)
       AND (l_id_ciudad       IS NULL OR ID_CIUDAD       = l_id_ciudad);

    -- LEFT JOIN contra CIUDADES, INNER contra PAISES y DEPARTAMENTOS: ID_CIUDAD
    -- es nullable y con un JOIN interno las instituciones sin ciudad se caerian
    -- del listado sin ningun error visible. Las otras dos son NOT NULL.
    --
    -- Se devuelven los ids Y los nombres: el formulario necesita los ids para
    -- precargar los combobox, y la tabla los nombres para mostrarlos.
    --
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: con DIRECCION de hasta 500 caracteres y UBICACION de otros 500 por
    -- fila, ese techo se alcanza con tres o cuatro instituciones.
    SELECT JSON_ARRAYAGG(fila ORDER BY nombre_institucion RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'                VALUE i.ID_INSTITUCION,
                 'idEmpresa'         VALUE i.ID_EMPRESA,
                 'idPais'            VALUE i.ID_PAIS,
                 'pais'              VALUE p.NOMBRE_PAIS,
                 'idDepartamento'    VALUE i.ID_DEPARTAMENTO,
                 'departamento'      VALUE d.NOMBRE_DEPARTAMENTO,
                 'idCiudad'          VALUE i.ID_CIUDAD,
                 'ciudad'            VALUE c.NOMBRE_CIUDAD,
                 'nombreInstitucion' VALUE i.NOMBRE_INSTITUCION,
                 'direccion'         VALUE i.DIRECCION,
                 'director'          VALUE i.DIRECTOR,
                 'contacto'          VALUE i.CONTACTO,
                 'correo'            VALUE i.CORREO,
                 'ubicacion'         VALUE i.UBICACION
                 RETURNING CLOB
               ) AS fila,
               i.NOMBRE_INSTITUCION AS nombre_institucion
          FROM INSTITUCIONES i
          JOIN PAISES        p ON p.ID_PAIS         = i.ID_PAIS
          JOIN DEPARTAMENTOS d ON d.ID_DEPARTAMENTO = i.ID_DEPARTAMENTO
          LEFT JOIN CIUDADES c ON c.ID_CIUDAD       = i.ID_CIUDAD
         WHERE (l_id_empresa      IS NULL OR i.ID_EMPRESA      = l_id_empresa)
           AND (l_id_pais         IS NULL OR i.ID_PAIS         = l_id_pais)
           AND (l_id_departamento IS NULL OR i.ID_DEPARTAMENTO = l_id_departamento)
           AND (l_id_ciudad       IS NULL OR i.ID_CIUDAD       = l_id_ciudad)
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
      APEX_DEBUG.ERROR('PKG_INSTITUCIONES.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      -- El SQLERRM viaja en la respuesta, como en db/lotes.sql: el mensaje
      -- generico deja el 500 sin diagnostico y APEX_DEBUG escribe en un log del
      -- workspace que hay que ir a buscar. REPLACE saca las comillas y los
      -- saltos de linea, que romperian el JSON.
      p_resultado := '{"error":"Error al listar las instituciones: ' ||
                     REPLACE(
                       REPLACE(
                         REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                         CHR(10), ' '),
                       CHR(13), ' ') ||
                     '"}';
  END LISTAR;

  PROCEDURE INSERTAR (
    p_authorization      IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_id_pais            IN  VARCHAR2,
    p_id_departamento    IN  VARCHAR2,
    p_id_ciudad          IN  VARCHAR2,
    p_nombre_institucion IN  VARCHAR2,
    p_direccion          IN  VARCHAR2,
    p_director           IN  VARCHAR2,
    p_contacto           IN  VARCHAR2,
    p_correo             IN  VARCHAR2,
    p_ubicacion          IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  ) IS
    l_sesion          NUMBER;
    l_id_empresa      NUMBER;
    l_id_pais         NUMBER;
    l_id_departamento NUMBER;
    l_id_ciudad       NUMBER;
    l_id              NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_empresa      := A_NUMERO(p_id_empresa);
    l_id_pais         := A_NUMERO(p_id_pais);
    l_id_departamento := A_NUMERO(p_id_departamento);
    l_id_ciudad       := A_NUMERO(p_id_ciudad);

    -- Las cuatro columnas NOT NULL del DDL. Sin esto el INSERT moriria con
    -- ORA-01400 (500); validado aca devuelve un 400 que dice cual falta.
    IF l_id_empresa IS NULL
       OR l_id_pais IS NULL
       OR l_id_departamento IS NULL
       OR TRIM(p_nombre_institucion) IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, idPais, idDepartamento y nombreInstitucion son obligatorios"}';
      RETURN;
    END IF;

    -- LA CADENA GEOGRAFICA, antes de escribir. Las FK ya garantizan que las
    -- filas existan; esto garantiza que tengan que ver entre si.
    IF NOT DEPARTAMENTO_ES_DE_PAIS(l_id_departamento, l_id_pais) THEN
      p_status_code := 400;
      p_resultado := '{"error":"El departamento no pertenece al pais indicado"}';
      RETURN;
    END IF;

    -- Solo si vino: la ciudad es opcional.
    IF l_id_ciudad IS NOT NULL
       AND NOT CIUDAD_ES_DE_DEPARTAMENTO(l_id_ciudad, l_id_departamento) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La ciudad no pertenece al departamento indicado"}';
      RETURN;
    END IF;

    INSERT INTO INSTITUCIONES (
      ID_EMPRESA, ID_PAIS, ID_DEPARTAMENTO, ID_CIUDAD,
      NOMBRE_INSTITUCION, DIRECCION, DIRECTOR, CONTACTO, CORREO, UBICACION,
      FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_empresa,
      l_id_pais,
      l_id_departamento,
      l_id_ciudad,
      TRIM(p_nombre_institucion),
      TRIM(p_direccion),
      TRIM(p_director),
      TRIM(p_contacto),
      TRIM(p_correo),
      TRIM(p_ubicacion),
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_INSTITUCION INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    -- SIN `WHEN DUP_VAL_ON_INDEX`: el DDL no declara ningun UNIQUE. Dos
    -- instituciones con el mismo nombre en la misma empresa son legales (dos
    -- sedes del mismo colegio).
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: alguna de las cuatro FK no encontro el padre. Es un dato
      -- invalido del cliente (400), no un fallo del servidor.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La empresa, el pais, el departamento o la ciudad no existen"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_INSTITUCIONES.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear la institucion: ' ||
                       REPLACE(
                         REPLACE(
                           REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                           CHR(10), ' '),
                         CHR(13), ' ') ||
                       '"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization      IN  VARCHAR2,
    p_id                 IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_id_pais            IN  VARCHAR2,
    p_id_departamento    IN  VARCHAR2,
    p_id_ciudad          IN  VARCHAR2,
    p_nombre_institucion IN  VARCHAR2,
    p_direccion          IN  VARCHAR2,
    p_director           IN  VARCHAR2,
    p_contacto           IN  VARCHAR2,
    p_correo             IN  VARCHAR2,
    p_ubicacion          IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  ) IS
    l_sesion          NUMBER;
    l_id              NUMBER;
    l_id_empresa      NUMBER;
    l_id_pais         NUMBER;
    l_id_departamento NUMBER;
    l_id_ciudad       NUMBER;
    l_borra_ciudad    BOOLEAN;
    -- Valores FINALES tras aplicar el cambio, para validar la cadena completa.
    l_pais_final      NUMBER;
    l_dep_final       NUMBER;
    l_ciudad_final    NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id              := A_NUMERO(p_id);
    l_id_empresa      := A_NUMERO(p_id_empresa);
    l_id_pais         := A_NUMERO(p_id_pais);
    l_id_departamento := A_NUMERO(p_id_departamento);
    l_id_ciudad       := A_NUMERO(p_id_ciudad);
    l_borra_ciudad    := LIMPIA(p_id_ciudad);

    -- AISLAMIENTO POR EMPRESA: el idEmpresa acota A CUAL fila se le aplica el
    -- cambio, no es solo un campo mas a modificar. Sin el WHERE, un PUT con el
    -- id de una institucion de OTRA empresa la modificaba igual — la pantalla
    -- no lo permite, pero el endpoint es publico para cualquiera con sesion.
    --
    -- ID_EMPRESA sale del SET a proposito: mover una fila de empresa es lo que
    -- este control busca impedir, y dejarlo modificable seria la puerta de
    -- atras al mismo problema.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- LA CADENA SE VALIDA CONTRA LA FILA FINAL, no contra lo que llego: un PUT
    -- que cambia solo la ciudad —dejando el departamento como estaba— tambien
    -- puede romperla, y ese caso se escaparia mirando unicamente los
    -- parametros recibidos.
    --
    -- El SELECT ademas hace de control de existencia dentro de la empresa: si
    -- no devuelve fila, ya se sabe que el UPDATE no iba a tocar nada.
    BEGIN
      SELECT NVL(l_id_pais, ID_PAIS),
             NVL(l_id_departamento, ID_DEPARTAMENTO),
             CASE WHEN l_borra_ciudad THEN NULL
                  ELSE NVL(l_id_ciudad, ID_CIUDAD)
             END
        INTO l_pais_final, l_dep_final, l_ciudad_final
        FROM INSTITUCIONES
       WHERE ID_INSTITUCION = l_id
         AND ID_EMPRESA     = l_id_empresa;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        -- 404 y no 403 cuando la institucion es de otra empresa: responder
        -- "existe pero no es tuya" confirmaria que el id existe, que es
        -- informacion que quien pregunta no deberia obtener.
        p_status_code := 404;
        p_resultado := '{"error":"La institucion no existe"}';
        RETURN;
    END;

    IF NOT DEPARTAMENTO_ES_DE_PAIS(l_dep_final, l_pais_final) THEN
      p_status_code := 400;
      p_resultado := '{"error":"El departamento no pertenece al pais indicado"}';
      RETURN;
    END IF;

    IF l_ciudad_final IS NOT NULL
       AND NOT CIUDAD_ES_DE_DEPARTAMENTO(l_ciudad_final, l_dep_final) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La ciudad no pertenece al departamento indicado"}';
      RETURN;
    END IF;

    -- Los tres ids geograficos se escriben con el valor final ya resuelto
    -- arriba, no con NVL sobre la columna: el CASE de l_ciudad_final es lo que
    -- permite que 'null' borre la ciudad y un parametro ausente la conserve.
    UPDATE INSTITUCIONES
       SET ID_PAIS             = l_pais_final,
           ID_DEPARTAMENTO     = l_dep_final,
           ID_CIUDAD           = l_ciudad_final,
           NOMBRE_INSTITUCION  = NVL(TRIM(p_nombre_institucion), NOMBRE_INSTITUCION),
           DIRECCION           = NVL(TRIM(p_direccion), DIRECCION),
           DIRECTOR            = NVL(TRIM(p_director), DIRECTOR),
           CONTACTO            = NVL(TRIM(p_contacto), CONTACTO),
           CORREO              = NVL(TRIM(p_correo), CORREO),
           UBICACION           = NVL(TRIM(p_ubicacion), UBICACION),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_INSTITUCION = l_id
       AND ID_EMPRESA     = l_id_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"La institucion no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El pais, el departamento o la ciudad no existen"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_INSTITUCIONES.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar la institucion: ' ||
                       REPLACE(
                         REPLACE(
                           REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                           CHR(10), ' '),
                         CHR(13), ' ') ||
                       '"}';
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

    l_id         := A_NUMERO(p_id);
    l_id_empresa := A_NUMERO(p_id_empresa);

    -- Obligatorio: sin empresa el DELETE alcanzaria filas de cualquiera.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- AISLAMIENTO POR EMPRESA: las dos condiciones. Con solo el id, un DELETE
    -- con el id de una institucion de otra empresa la borraba.
    --
    -- BAJA FISICA: la tabla no tiene columna ACTIVO, asi que no hay baja
    -- logica posible. Es el mismo caso que DETALLE_MONEDAS.
    DELETE FROM INSTITUCIONES
     WHERE ID_INSTITUCION = l_id
       AND ID_EMPRESA     = l_id_empresa;

    -- 404 tambien cuando existe pero es de otra empresa: no se confirma que el
    -- id exista.
    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"La institucion no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos apuntando a esta fila. Es un conflicto de estado
      -- (409), no un error del servidor: el dato que mandaron era valido.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de esta institucion"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_INSTITUCIONES.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar la institucion: ' ||
                       REPLACE(
                         REPLACE(
                           REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                           CHR(10), ' '),
                         CHR(13), ' ') ||
                       '"}';
      END IF;
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Publica el modulo ORDS /instituciones/ con sus 4 endpoints.
  --
  -- Cada handler es una sola linea: invoca al procedimiento del paquete pasando
  -- los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un parametro
  -- de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin esto, toda
  -- peticion cross-origin a /instituciones/* la rechaza ORDS antes de llegar a
  -- cualquiera de los 4 handlers. Ver la explicacion en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'instituciones',
      p_base_path      => '/instituciones/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'ABM de instituciones por empresa con ubicacion geografica'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'instituciones',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /instituciones/listar?idEmpresa=&idPais=&idDepartamento=&idCiudad=
    --
    -- Los query params no se declaran con DEFINE_PARAMETER: se vinculan solos
    -- al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'instituciones', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'instituciones',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INSTITUCIONES.LISTAR(:authorization, :idEmpresa, :idPais, :idDepartamento, :idCiudad, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'instituciones', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'instituciones', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'instituciones', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /instituciones/crear
    -- Body: { idEmpresa, idPais, idDepartamento, idCiudad?, nombreInstitucion,
    --         direccion?, director?, contacto?, correo?, ubicacion? }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'instituciones', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'instituciones',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INSTITUCIONES.INSERTAR(:authorization, :idEmpresa, :idPais, :idDepartamento, :idCiudad, :nombreInstitucion, :direccion, :director, :contacto, :correo, :ubicacion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'instituciones', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'instituciones', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'instituciones', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /instituciones/actualizar/:id
    -- Body: { idEmpresa, idPais?, idDepartamento?, idCiudad?,
    --         nombreInstitucion?, direccion?, director?, contacto?, correo?,
    --         ubicacion? }
    --       (ausentes = no cambia; idCiudad: "null" = quitarla)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'instituciones', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'instituciones',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INSTITUCIONES.ACTUALIZAR(:authorization, :id, :idEmpresa, :idPais, :idDepartamento, :idCiudad, :nombreInstitucion, :direccion, :director, :contacto, :correo, :ubicacion, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'instituciones', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'instituciones', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'instituciones', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /instituciones/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'instituciones', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'instituciones',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INSTITUCIONES.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'instituciones', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'instituciones', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'instituciones', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_INSTITUCIONES;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_INSTITUCIONES.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_INSTITUCIONES'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_INSTITUCIONES'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'instituciones';

SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'instituciones'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- Las instituciones cargadas, con su geografia resuelta.
SELECT i.ID_INSTITUCION, e.NOMBRE_EMPRESA, i.NOMBRE_INSTITUCION,
       p.NOMBRE_PAIS, d.NOMBRE_DEPARTAMENTO, c.NOMBRE_CIUDAD,
       i.DIRECTOR, i.CONTACTO
  FROM INSTITUCIONES i
  JOIN EMPRESAS      e ON e.ID_EMPRESA      = i.ID_EMPRESA
  JOIN PAISES        p ON p.ID_PAIS         = i.ID_PAIS
  JOIN DEPARTAMENTOS d ON d.ID_DEPARTAMENTO = i.ID_DEPARTAMENTO
  LEFT JOIN CIUDADES c ON c.ID_CIUDAD       = i.ID_CIUDAD
 ORDER BY e.NOMBRE_EMPRESA, i.NOMBRE_INSTITUCION;

--------------------------------------------------------------------------------
-- AUDITORIA DE COHERENCIA GEOGRAFICA — LAS DOS CONSULTAS DEBEN DAR CERO FILAS.
--
-- Si devuelven algo, hay filas cargadas antes de este paquete con la cadena
-- rota: el departamento no es del pais, o la ciudad no es del departamento. Las
-- FK no lo impiden y el paquete ya no deja crear mas, pero las viejas siguen
-- ahi y hay que corregirlas a mano.
--------------------------------------------------------------------------------

SELECT i.ID_INSTITUCION, i.NOMBRE_INSTITUCION,
       i.ID_PAIS AS PAIS_INSTITUCION, d.ID_PAIS AS PAIS_DEPARTAMENTO
  FROM INSTITUCIONES i
  JOIN DEPARTAMENTOS d ON d.ID_DEPARTAMENTO = i.ID_DEPARTAMENTO
 WHERE d.ID_PAIS != i.ID_PAIS;

SELECT i.ID_INSTITUCION, i.NOMBRE_INSTITUCION,
       i.ID_DEPARTAMENTO AS DEP_INSTITUCION, c.ID_DEPARTAMENTO AS DEP_CIUDAD
  FROM INSTITUCIONES i
  JOIN CIUDADES      c ON c.ID_CIUDAD = i.ID_CIUDAD
 WHERE c.ID_DEPARTAMENTO != i.ID_DEPARTAMENTO;
