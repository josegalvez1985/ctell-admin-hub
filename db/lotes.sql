--------------------------------------------------------------------------------
-- CTELL · LOTES
--
-- Un paquete (PKG_LOTES) con los procedimientos del ABM — LISTAR, INSERTAR,
-- ACTUALIZAR, ELIMINAR — mas LISTAR_ARTICULOS para el filtro, y la publicacion
-- de los endpoints ORDS. Todo vive dentro del paquete: no hay procedimientos
-- sueltos ni PL/SQL embebido como texto dentro de los handlers.
--
--   1. LISTAR            GET    /lotes/listar
--                               (?idEmpresa= &idSucursal= &idArticulo=
--                                &busqueda= &pagina= &tamanio=)
--   2. LISTAR_ARTICULOS  GET    /lotes/articulos  (?idEmpresa= &idSucursal=)
--   3. INSERTAR          POST   /lotes/crear
--   4. ACTUALIZAR        PUT    /lotes/actualizar/:id
--   5. ELIMINAR          DELETE /lotes/eliminar/:id/:idEmpresa
--
-- EL LISTADO VIENE PAGINADO, 20 POR PAGINA. Antes devolvia la tabla entera y la
-- pantalla recortaba a 20 en el navegador: el trafico y el JSON crecian con
-- cada lote cargado aunque solo se vieran 20 filas, que es el mismo problema
-- que ya se habia corregido en db/articulos.sql.
--
-- La BUSQUEDA y el filtro por articulo van en el SQL por la misma razon:
-- filtrando en el cliente solo se mira la pagina traida, asi que un lote de la
-- pagina 5 no aparecia al escribir su numero.
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES: usa PKG_AUTH
-- para validar el token.
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/lotes/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   LOTES  ID_LOTE, ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO, NUMERO_LOTE,
--          CANTIDAD, CANTIDAD_DISPON, COSTO, FECHA_VENCIMIENTO, FECHA_ENTRADA,
--          OBSERVACIONES, FECHA_CREACION, FECHA_ACTUALIZACION
--
-- CANTIDAD vs CANTIDAD_DISPON — LA DISTINCION CLAVE DE ESTA TABLA:
--
--   CANTIDAD         cuanto ENTRO en la partida. Es historico: no se toca
--                    despues del alta, salvo para corregir un error de carga.
--   CANTIDAD_DISPON  cuanto QUEDA sin consumir hoy. Arranca igual a CANTIDAD y
--                    baja a medida que se usa la mercaderia.
--
-- La diferencia entre las dos es lo consumido, y por eso conviene tener las dos
-- en vez de una sola que se pise: sin CANTIDAD no hay forma de saber si un lote
-- con 2 unidades entro con 2 o entro con 500.
--
-- EL STOCK DE UN ARTICULO SUMA CANTIDAD_DISPON, NO CANTIDAD. Es el error mas
-- facil de cometer al leer esta tabla: sumar CANTIDAD daria todo lo que alguna
-- vez entro al deposito, no lo que hay ahora. Ver el listado de db/articulos.sql.
--
-- EN EL ALTA, disponible = cantidad si no viene: una partida recien ingresada
-- todavia no se consumio. Que el INSERT lo resuelva evita el estado incoherente
-- de un lote que entra ya con 0 disponible sin que nadie lo haya usado.
--
-- QUE ES: cada partida de mercaderia que entro al deposito, con su numero de
-- lote, su cantidad, su costo y su vencimiento. Es lo que permite responder
-- "que me vence primero" y "a que costo entro esta partida".
--
-- CUELGA DE EMPRESA, SUCURSAL **Y** ARTICULO. Las dos primeras salen del
-- contexto activo de la sesion (los providers del frontend, no combobox del
-- formulario), igual que en db/ubicaciones.sql. El ARTICULO si se elige en el
-- formulario: es el dato que da sentido al lote.
--
-- OJO CON LA COHERENCIA: el DDL NO garantiza nada entre las tres FK. Son
-- independientes, asi que por si solo acepta la sucursal de otra empresa y el
-- articulo de otra empresa todavia. INSERTAR y ACTUALIZAR lo validan a mano
-- contra SUCURSALES y ARTICULOS antes de escribir, y devuelven 400 si no
-- coinciden. Es la misma verificacion de db/ubicaciones.sql pero sobre DOS
-- tablas en vez de una — el mismo problema que db/articulos-ubicaciones.sql
-- resuelve cruzando articulo y ubicacion.
--
-- CON JOIN CONTRA ARTICULOS: a diferencia de UBICACIONES, el listado SI trae el
-- nombre y el codigo del articulo. No es una constante repetida — cada lote es
-- de un articulo distinto, y sin el JOIN el frontend tendria que pedir la tabla
-- de articulos entera para mostrar una lista legible. Los nombres de empresa y
-- sucursal NO se devuelven: el listado ya viene filtrado por una sola de cada
-- una y el frontend las tiene en sus providers.
--
-- NO TIENE COLUMNA ACTIVO, igual que UBICACIONES y DETALLE_MONEDAS: el DDL no la
-- trae, asi que la baja es fisica y no hay estado 'A'/'I' en el JSON ni
-- endpoints de activar/inactivar. Un lote existe o no existe.
--
-- NUMERO_LOTE ES NUMBER Y NULLABLE, pero forma parte del UNIQUE. Ojo con esto:
-- en Oracle NULL nunca choca con NULL en un indice unico, asi que se pueden
-- cargar VARIOS lotes sin numero para el mismo articulo y el UNIQUE no lo
-- impide. Es intencional — mercaderia que entra sin identificar el lote — y el
-- frontend lo refleja mostrando "Sin numero".
--
-- El UNIQUE (ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO, NUMERO_LOTE) impide repetir
-- el mismo numero de lote para el mismo articulo en la misma sucursal, pero si
-- permite el mismo numero en OTRA sucursal o para OTRO articulo. El
-- DUP_VAL_ON_INDEX se traduce a 409 con ese matiz en el mensaje.
--
-- CANTIDAD, CANTIDAD_DISPON y COSTO se validan >= 0. Un lote con cantidad
-- negativa no existe, y un costo negativo tampoco: los dos ensucian cualquier
-- suma de stock o de valorizacion. El 0 SI se acepta — un lote consumido entero
-- se conserva como historia, con CANTIDAD_DISPON en 0 y CANTIDAD intacta.
--
-- Y CANTIDAD_DISPON <= CANTIDAD: no puede quedar mas de lo que entro. Se valida
-- contra los valores FINALES en el ACTUALIZAR, porque cambiar una sola de las
-- dos tambien puede romper la relacion.
--
-- LAS FECHAS VIAJAN COMO TEXTO ISO ('YYYY-MM-DD'). ORDS entrega los binds como
-- VARCHAR2, asi que se convierten aca adentro con TO_TIMESTAMP y un formato
-- EXPLICITO: sin el formato, Oracle usa el NLS de la sesion y el mismo
-- '03-04-2026' se interpreta como 3 de abril o 4 de marzo segun donde corra.
-- Al devolverlas se usa TO_CHAR con el mismo formato, por el mismo motivo — un
-- TIMESTAMP crudo en el JSON sale como '17-AGO-26' y `new Date()` no lo parsea.
--
-- SOLO LA FECHA, SIN HORA. Las dos columnas son TIMESTAMP pero se manejan a
-- nivel de dia: un vencimiento es un dia del calendario, y la hora en que se
-- descargo el camion no cambia ninguna decision. Guardar la hora obligaria a
-- mostrarla y a que alguien la cargue.
--
-- FECHA_VENCIMIENTO ES NULLABLE Y ESO IMPORTA: no toda mercaderia vence. El DDL
-- le pone DEFAULT SYSTIMESTAMP, que para un vencimiento es un default
-- PELIGROSO —un lote sin vencimiento cargado sin ese campo quedaria venciendo
-- hoy—, asi que el INSERT escribe NULL EXPLICITO cuando no viene. Nunca se
-- omite la columna del INSERT.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace. Se declara en
-- PUBLICAR_ENDPOINTS. Ver la explicacion completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_LOTES
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_LOTES.LISTAR('Bearer TU_TOKEN', NULL, NULL, NULL, NULL, NULL, NULL,
--                      l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_LOTES AS

  -- Los filtros NULL o vacios no filtran. En la app siempre viajan empresa y
  -- sucursal (las activas); idArticulo solo cuando se miran los lotes de un
  -- articulo puntual.
  --
  -- PAGINADO, 20 por pagina por defecto y 200 de techo. p_busqueda filtra en
  -- SQL por articulo, codigo, numero de lote y observaciones: buscando en el
  -- cliente solo se miraria la pagina traida, y un lote de la pagina 5 no
  -- apareceria al escribir su numero.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Los articulos que TIENEN al menos un lote en la empresa/sucursal, para el
  -- desplegable del filtro de la columna Articulo.
  --
  -- Va aparte y no sale del listado: con el listado paginado, las opciones
  -- saldrian solo de las 20 filas traidas. Y no se usa /articulos/listar
  -- porque ese ofrece articulos sin ningun lote, que al elegirlos darian una
  -- lista vacia.
  PROCEDURE LISTAR_ARTICULOS (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Las fechas llegan como texto ISO 'YYYY-MM-DD'.
  PROCEDURE INSERTAR (
    p_authorization      IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_id_sucursal        IN  VARCHAR2,
    p_id_articulo        IN  VARCHAR2,
    p_numero_lote        IN  VARCHAR2,
    p_cantidad           IN  VARCHAR2,
    p_cantidad_dispon    IN  VARCHAR2,
    p_costo              IN  VARCHAR2,
    p_fecha_vencimiento  IN  VARCHAR2,
    p_fecha_entrada      IN  VARCHAR2,
    p_observaciones      IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  );

  -- Los parametros ausentes (NULL) no modifican la columna correspondiente.
  PROCEDURE ACTUALIZAR (
    p_authorization      IN  VARCHAR2,
    p_id                 IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_id_sucursal        IN  VARCHAR2,
    p_id_articulo        IN  VARCHAR2,
    p_numero_lote        IN  VARCHAR2,
    p_cantidad           IN  VARCHAR2,
    p_cantidad_dispon    IN  VARCHAR2,
    p_costo              IN  VARCHAR2,
    p_fecha_vencimiento  IN  VARCHAR2,
    p_fecha_entrada      IN  VARCHAR2,
    p_observaciones      IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  );

  -- p_id_empresa es OBLIGATORIO: acota el borrado a la empresa de la sesion.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /lotes/ con sus 4 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_LOTES;
/

CREATE OR REPLACE PACKAGE BODY PKG_LOTES AS

  -- Formato UNICO de las fechas, de entrada y de salida. Constante para que no
  -- se desincronicen: si TO_TIMESTAMP y TO_CHAR usaran mascaras distintas, lo
  -- que se guarda y lo que se devuelve dejarian de ser el mismo dia.
  C_FORMATO_FECHA CONSTANT VARCHAR2(10) := 'YYYY-MM-DD';

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
         WHERE NAME = 'lotes';

        IF l_existe = 0 THEN
          RETURN;  -- No existia: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'lotes');
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
  -- El DDL tiene las FK por separado, asi que por si solo acepta la sucursal de
  -- otra empresa. Esto lo cierra antes de escribir.
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

  ------------------------------------------------------------------------------
  -- Privado: el articulo existe y pertenece a esa empresa.
  --
  -- Mismo problema que la sucursal: sin esto se podria cargar un lote de un
  -- articulo de otra empresa, y el listado por empresa lo mostraria igual con
  -- el nombre del articulo ajeno.
  ------------------------------------------------------------------------------
  FUNCTION ARTICULO_ES_DE_EMPRESA (
    p_id_articulo IN NUMBER,
    p_id_empresa  IN NUMBER
  ) RETURN BOOLEAN IS
    l_existe PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_existe
      FROM ARTICULOS
     WHERE ID_ARTICULO = p_id_articulo
       AND ID_EMPRESA  = p_id_empresa;

    RETURN l_existe > 0;
  END ARTICULO_ES_DE_EMPRESA;

  ------------------------------------------------------------------------------
  -- Privado: texto ISO 'YYYY-MM-DD' a TIMESTAMP.
  --
  -- Devuelve NULL si viene vacio. Con formato EXPLICITO: sin el, Oracle usa el
  -- NLS de la sesion y '03-04-2026' cambia de significado segun donde corra.
  --
  -- Una fecha con formato invalido levanta ORA-01843/ORA-01861, que el WHEN
  -- OTHERS del procedimiento traduce a 400.
  ------------------------------------------------------------------------------
  FUNCTION A_TIMESTAMP (p_texto IN VARCHAR2) RETURN TIMESTAMP IS
  BEGIN
    IF TRIM(p_texto) IS NULL THEN
      RETURN NULL;
    END IF;
    -- SUBSTR(1,10): tolera que llegue un ISO completo con hora
    -- ('2026-04-03T00:00:00.000Z') en vez de solo el dia. El frontend manda
    -- solo el dia, pero un cliente cualquiera puede mandar el ISO entero y no
    -- hay razon para rechazarlo.
    RETURN TO_TIMESTAMP(SUBSTR(TRIM(p_texto), 1, 10), C_FORMATO_FECHA);
  END A_TIMESTAMP;

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id_empresa  NUMBER;
    l_id_sucursal NUMBER;
    l_id_articulo NUMBER;
    l_busqueda    VARCHAR2(4000);
    l_pagina      NUMBER;
    l_tamanio     NUMBER;
    l_offset      NUMBER;
    l_total       NUMBER;
    l_items       CLOB;
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
    l_id_articulo := TO_NUMBER(NULLIF(p_id_articulo, ''));

    -- En minusculas una sola vez aca, no por fila: el WHERE compara contra
    -- LOWER() de cada columna, asi que subir el termino tambien dentro del SQL
    -- haria el trabajo tantas veces como filas tenga la tabla.
    --
    -- NULL cuando llega vacio: el WHERE esta escrito como "l_busqueda IS NULL
    -- OR ...", asi que una cadena vacia sin normalizar filtraria por '%%' en vez
    -- de saltear el filtro.
    l_busqueda := LOWER(TRIM(NULLIF(p_busqueda, '')));

    -- Pagina 1 y 20 por pagina son los valores de la app. GREATEST(1) descarta
    -- un ?pagina=0 o negativo, que daria un OFFSET negativo y ORA-06502.
    l_pagina  := GREATEST(NVL(TO_NUMBER(NULLIF(p_pagina, '')), 1), 1);

    -- 200 de techo, el mismo que el resto del proyecto: sin limite, un
    -- ?tamanio=99999 traeria la tabla entera y volveria el problema que esta
    -- paginacion viene a resolver.
    l_tamanio := LEAST(GREATEST(NVL(TO_NUMBER(NULLIF(p_tamanio, '')), 20), 1), 200);
    l_offset  := (l_pagina - 1) * l_tamanio;

    -- El total cuenta las filas que pasan LOS MISMOS filtros, no la tabla
    -- entera: es lo que la pantalla muestra como "N lotes" y lo que decide si
    -- queda algo por traer. Contando todo, el boton "Mostrar mas" seguiria
    -- ofreciendo paginas vacias cuando hay una busqueda activa.
    --
    -- El JOIN contra ARTICULOS hace falta aca tambien: la busqueda mira el
    -- nombre y el codigo del articulo, que no estan en LOTES. Sin el, el total
    -- contaria mas filas de las que el listado devuelve.
    SELECT COUNT(*)
      INTO l_total
      FROM LOTES     l
      JOIN ARTICULOS a ON a.ID_ARTICULO = l.ID_ARTICULO
     WHERE (l_id_empresa  IS NULL OR l.ID_EMPRESA  = l_id_empresa)
       AND (l_id_sucursal IS NULL OR l.ID_SUCURSAL = l_id_sucursal)
       AND (l_id_articulo IS NULL OR l.ID_ARTICULO = l_id_articulo)
       AND (l_busqueda IS NULL
            OR LOWER(a.NOMBRE_ARTICULO)        LIKE '%' || l_busqueda || '%'
            OR LOWER(a.CODIGO_ARTICULO)        LIKE '%' || l_busqueda || '%'
            OR TO_CHAR(l.ID_LOTE)              LIKE '%' || l_busqueda || '%'
            OR LOWER(TO_CHAR(l.NUMERO_LOTE))   LIKE '%' || l_busqueda || '%'
            OR LOWER(l.OBSERVACIONES)          LIKE '%' || l_busqueda || '%');

    -- CON JOIN contra ARTICULOS (INNER, no LEFT): ID_ARTICULO es NOT NULL en el
    -- DDL, asi que todo lote tiene articulo y un LEFT JOIN no cambiaria nada.
    --
    -- ORDEN: por vencimiento ascendente — lo que vence primero, primero. Es la
    -- pregunta que justifica mirar esta tabla. NULLS LAST deja al final la
    -- mercaderia que no vence, que si no coparia el encabezado del listado.
    --
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes: con OBSERVACIONES de hasta 1000 caracteres por fila, ese techo se
    -- alcanza con tres o cuatro lotes.
    -- SIN `ORDER BY` EN EL AGREGADO, a diferencia del resto de los paquetes.
    --
    -- Aca la subconsulta ya sale ordenada Y recortada por OFFSET/FETCH, asi que
    -- reordenar de nuevo no cambia el resultado — pero obliga a Oracle a
    -- materializar el agregado intermedio, y con `tamanio=200` y OBSERVACIONES
    -- de hasta 1000 caracteres por fila eso desbordaba en un 500.
    --
    -- Los otros paquetes lo llevan porque agregan SIN paginar, y ahi el orden
    -- del agregado es el unico que hay.
    SELECT JSON_ARRAYAGG(fila RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'                VALUE l.ID_LOTE,
                 'idEmpresa'         VALUE l.ID_EMPRESA,
                 'idSucursal'        VALUE l.ID_SUCURSAL,
                 'idArticulo'        VALUE l.ID_ARTICULO,
                 -- Del articulo (JOIN): sin esto el frontend tendria que pedir
                 -- la tabla entera para mostrar una lista legible.
                 'nombreArticulo'    VALUE a.NOMBRE_ARTICULO,
                 'codigoArticulo'    VALUE a.CODIGO_ARTICULO,
                 'numeroLote'        VALUE l.NUMERO_LOTE,
                 -- Lo que ENTRO (historico) y lo que QUEDA (hoy). La resta es
                 -- lo consumido. NVL en disponible: las filas cargadas antes de
                 -- que existiera la columna la tienen en null, y ahi lo
                 -- razonable es asumir que no se consumio nada.
                 'cantidad'          VALUE l.CANTIDAD,
                 'cantidadDispon'    VALUE NVL(l.CANTIDAD_DISPON, l.CANTIDAD),
                 'costo'             VALUE l.COSTO,
                 -- TO_CHAR y no la columna pelada: un TIMESTAMP crudo sale en el
                 -- JSON con el formato NLS de la sesion ('17-AGO-26 10.30.00'),
                 -- que `new Date()` no parsea y deja "Invalid Date" en pantalla.
                 'fechaVencimiento'  VALUE TO_CHAR(l.FECHA_VENCIMIENTO, C_FORMATO_FECHA),
                 'fechaEntrada'      VALUE TO_CHAR(l.FECHA_ENTRADA, C_FORMATO_FECHA),
                 'observaciones'     VALUE l.OBSERVACIONES
                 RETURNING CLOB
               ) AS fila
          FROM LOTES     l
          JOIN ARTICULOS a ON a.ID_ARTICULO = l.ID_ARTICULO
         WHERE (l_id_empresa  IS NULL OR l.ID_EMPRESA  = l_id_empresa)
           AND (l_id_sucursal IS NULL OR l.ID_SUCURSAL = l_id_sucursal)
           AND (l_id_articulo IS NULL OR l.ID_ARTICULO = l_id_articulo)
           AND (l_busqueda IS NULL
                OR LOWER(a.NOMBRE_ARTICULO)      LIKE '%' || l_busqueda || '%'
                OR LOWER(a.CODIGO_ARTICULO)      LIKE '%' || l_busqueda || '%'
                -- ID_LOTE es la columna que la pantalla muestra, asi que tiene
                -- que ser buscable. NUMERO_LOTE se conserva aunque la columna
                -- este oculta: sigue siendo un dato real de la partida.
                OR TO_CHAR(l.ID_LOTE)            LIKE '%' || l_busqueda || '%'
                OR LOWER(TO_CHAR(l.NUMERO_LOTE)) LIKE '%' || l_busqueda || '%'
                OR LOWER(l.OBSERVACIONES)        LIKE '%' || l_busqueda || '%')
         -- ESTE ES EL UNICO ORDER BY, y decide dos cosas a la vez: QUE filas
         -- entran en la pagina (por el OFFSET/FETCH de abajo) y en que orden
         -- salen. Sin el, OFFSET/FETCH recortaria en un orden que Oracle no
         -- garantiza y la pagina 2 podria repetir u omitir lotes de la 1.
         --
         -- El JSON_ARRAYAGG de arriba NO reordena: preserva este orden y evita
         -- la materializacion que desbordaba con tamanio=200.
         --
         -- ID_LOTE como ultimo criterio: el vencimiento y el nombre pueden
         -- repetirse entre varias filas, y sin un desempate estable esas filas
         -- podrian intercambiarse entre una pagina y la siguiente.
         ORDER BY l.FECHA_VENCIMIENTO NULLS LAST, a.NOMBRE_ARTICULO, l.ID_LOTE
         OFFSET l_offset ROWS FETCH NEXT l_tamanio ROWS ONLY
      );

    p_status_code := 200;
    -- JSON_OBJECT(... RETURNING CLOB) como asignacion PL/SQL directa (sin
    -- SELECT) falla con PLS-00684 dentro de un package body.
    --
    -- JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un array vacio: sin
    -- el NVL el frontend recibiria "items":null y reventaria al iterarlo.
    --
    -- `total` son las filas que pasan el filtro, NO las de esta pagina: con
    -- items.length el frontend no podria saber si quedan mas. `pagina` y
    -- `tamanio` viajan de vuelta para que la pantalla no tenga que asumir el
    -- tamaño que el backend efectivamente aplico (que pudo recortarse al techo
    -- de 200).
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
      APEX_DEBUG.ERROR('PKG_LOTES.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      -- El SQLERRM VIAJA EN LA RESPUESTA, a diferencia del resto del proyecto.
      --
      -- El mensaje generico dejaba el 500 sin diagnostico: APEX_DEBUG.ERROR
      -- escribe en un log del workspace que hay que ir a buscar, y desde el
      -- navegador no se ve nada util. Con el codigo y el mensaje en el JSON, el
      -- error se lee en la misma consola donde aparece el 500.
      --
      -- Es informacion de la base expuesta al cliente, asi que se limita a los
      -- primeros 300 caracteres —sin el backtrace, que dice nombres de
      -- procedimientos y numeros de linea— y REPLACE saca las comillas dobles
      -- que romperian el JSON.
      -- Los saltos de linea tambien salen: SQLERRM los trae y un salto crudo
      -- dentro de una cadena JSON es invalido, asi que el cliente no podria
      -- parsear justo la respuesta que explica el problema.
      p_resultado := '{"error":"Error al listar los lotes: ' ||
                     REPLACE(
                       REPLACE(
                         REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                         CHR(10), ' '),
                       CHR(13), ' ') ||
                     '"}';
  END LISTAR;

  ------------------------------------------------------------------------------
  -- Articulos que tienen al menos un lote, para el desplegable del filtro.
  --
  -- DISTINCT y no GROUP BY: solo interesa el par (id, nombre), no cuantos lotes
  -- tiene cada uno. Devuelve la lista completa sin paginar — son los articulos
  -- con stock cargado en UNA sucursal, un conjunto chico por definicion, y un
  -- desplegable a medias no serviria para filtrar.
  ------------------------------------------------------------------------------
  PROCEDURE LISTAR_ARTICULOS (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id_empresa  NUMBER;
    l_id_sucursal NUMBER;
    l_items       CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, ''));

    SELECT JSON_ARRAYAGG(fila ORDER BY nombre_articulo RETURNING CLOB)
      INTO l_items
      FROM (
        -- EL DISTINCT VA EN LA SUBCONSULTA DE ADENTRO, sobre el id y el nombre,
        -- y el JSON_OBJECT se arma DESPUES.
        --
        -- Un `SELECT DISTINCT` que incluya la columna del JSON_OBJECT falla con
        -- ORA-00932: el `RETURNING CLOB` la tipa como CLOB, y Oracle no puede
        -- comparar CLOBs para decidir si dos filas son iguales. Con el DISTINCT
        -- sobre los dos escalares el problema no se presenta, y el resultado es
        -- el mismo: un articulo por fila.
        SELECT JSON_OBJECT(
                 'id'             VALUE d.ID_ARTICULO,
                 'nombreArticulo' VALUE d.NOMBRE_ARTICULO
                 RETURNING CLOB
               ) AS fila,
               d.NOMBRE_ARTICULO AS nombre_articulo
          FROM (
            SELECT DISTINCT a.ID_ARTICULO, a.NOMBRE_ARTICULO
              FROM LOTES     l
              JOIN ARTICULOS a ON a.ID_ARTICULO = l.ID_ARTICULO
             WHERE (l_id_empresa  IS NULL OR l.ID_EMPRESA  = l_id_empresa)
               AND (l_id_sucursal IS NULL OR l.ID_SUCURSAL = l_id_sucursal)
          ) d
      );

    p_status_code := 200;
    SELECT JSON_OBJECT(
             'items' VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON
             RETURNING CLOB
           )
      INTO p_resultado
      FROM DUAL;
  EXCEPTION
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_LOTES.LISTAR_ARTICULOS: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      -- Mismo criterio que LISTAR: el error real viaja al cliente. Este
      -- endpoint es nuevo y todavia no se probo contra la base.
      p_resultado := '{"error":"Error al listar los articulos con lotes: ' ||
                     REPLACE(
                       REPLACE(
                         REPLACE(SUBSTR(SQLCODE || ' ' || SQLERRM, 1, 300), '"', ''''),
                         CHR(10), ' '),
                       CHR(13), ' ') ||
                     '"}';
  END LISTAR_ARTICULOS;

  PROCEDURE INSERTAR (
    p_authorization      IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_id_sucursal        IN  VARCHAR2,
    p_id_articulo        IN  VARCHAR2,
    p_numero_lote        IN  VARCHAR2,
    p_cantidad           IN  VARCHAR2,
    p_cantidad_dispon    IN  VARCHAR2,
    p_costo              IN  VARCHAR2,
    p_fecha_vencimiento  IN  VARCHAR2,
    p_fecha_entrada      IN  VARCHAR2,
    p_observaciones      IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id_empresa  NUMBER;
    l_id_sucursal NUMBER;
    l_id_articulo NUMBER;
    l_numero_lote NUMBER;
    l_cantidad    NUMBER;
    l_dispon      NUMBER;
    l_costo       NUMBER;
    l_vence       TIMESTAMP;
    l_entrada     TIMESTAMP;
    l_id          NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Todas las conversiones juntas y dentro del BEGIN: si alguna falla, el
    -- ORA-01722 (numero) u ORA-01843 (fecha) lo captura el WHEN OTHERS de abajo
    -- y se traduce a 400.
    l_id_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_id_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    l_id_articulo := TO_NUMBER(NULLIF(p_id_articulo, ''));
    l_numero_lote := TO_NUMBER(NULLIF(p_numero_lote, ''));
    l_cantidad    := TO_NUMBER(NULLIF(p_cantidad, ''));
    l_dispon      := TO_NUMBER(NULLIF(p_cantidad_dispon, ''));
    l_costo       := TO_NUMBER(NULLIF(p_costo, ''));
    l_vence       := A_TIMESTAMP(p_fecha_vencimiento);
    l_entrada     := A_TIMESTAMP(p_fecha_entrada);

    -- Las tres FK son NOT NULL en el DDL. NUMERO_LOTE, CANTIDAD, COSTO y las
    -- fechas son opcionales.
    IF l_id_empresa IS NULL OR l_id_sucursal IS NULL OR l_id_articulo IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, idSucursal e idArticulo son obligatorios"}';
      RETURN;
    END IF;

    -- Cantidad y costo negativos ensucian cualquier suma de stock o de
    -- valorizacion. El 0 SI se acepta: un lote consumido que se conserva como
    -- historia, o mercaderia sin costo cargado todavia.
    IF NVL(l_cantidad, 0) < 0 OR NVL(l_dispon, 0) < 0 OR NVL(l_costo, 0) < 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"Las cantidades y el costo no pueden ser negativos"}';
      RETURN;
    END IF;

    -- No puede quedar disponible mas de lo que entro. Solo se compara si vino:
    -- cuando falta, el INSERT lo iguala a la cantidad y la relacion se cumple
    -- por construccion.
    IF l_dispon IS NOT NULL AND l_dispon > NVL(l_cantidad, 0) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La cantidad disponible no puede superar la cantidad que entro"}';
      RETURN;
    END IF;

    -- Un numero de lote negativo no es un identificador valido.
    IF l_numero_lote IS NOT NULL AND l_numero_lote < 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"El numero de lote no puede ser negativo"}';
      RETURN;
    END IF;

    -- Vencer antes de entrar es un error de carga (dos campos cruzados), no un
    -- dato posible. Se avisa en vez de guardarlo: un lote asi aparece siempre
    -- primero en el listado por vencimiento y ensucia la lectura.
    IF l_vence IS NOT NULL AND l_entrada IS NOT NULL AND l_vence < l_entrada THEN
      p_status_code := 400;
      p_resultado := '{"error":"El vencimiento no puede ser anterior a la fecha de entrada"}';
      RETURN;
    END IF;

    -- Las FK son independientes entre si: sin estas dos verificaciones se
    -- podria guardar la sucursal o el articulo de OTRA empresa, y el listado
    -- por empresa los mostraria igual.
    IF NOT SUCURSAL_ES_DE_EMPRESA(l_id_sucursal, l_id_empresa) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La sucursal no pertenece a la empresa indicada"}';
      RETURN;
    END IF;

    IF NOT ARTICULO_ES_DE_EMPRESA(l_id_articulo, l_id_empresa) THEN
      p_status_code := 400;
      p_resultado := '{"error":"El articulo no pertenece a la empresa indicada"}';
      RETURN;
    END IF;

    -- FECHA_VENCIMIENTO se escribe SIEMPRE, incluso NULL. El DDL le pone
    -- DEFAULT SYSTIMESTAMP, que para un vencimiento es peligroso: omitir la
    -- columna dejaria venciendo HOY a un lote que no vence. Lo mismo con
    -- FECHA_ENTRADA, pero ahi el default si tiene sentido y se aplica con NVL.
    --
    -- NVL en cantidad: el DDL la declara DEFAULT 0, pero mandar NULL explicito
    -- pisaria ese default y dejaria la columna en NULL, que despues rompe
    -- cualquier suma de stock.
    --
    -- CANTIDAD_DISPON arranca igual a CANTIDAD si no viene: una partida recien
    -- ingresada todavia no se consumio. Resolverlo aca —y no dejarlo en null—
    -- evita que el stock del articulo dependa de un NVL en cada consulta.
    INSERT INTO LOTES (
      ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO, NUMERO_LOTE,
      CANTIDAD, CANTIDAD_DISPON, COSTO, FECHA_VENCIMIENTO, FECHA_ENTRADA,
      OBSERVACIONES, FECHA_CREACION, FECHA_ACTUALIZACION
    ) VALUES (
      l_id_empresa,
      l_id_sucursal,
      l_id_articulo,
      l_numero_lote,
      NVL(l_cantidad, 0),
      NVL(l_dispon, NVL(l_cantidad, 0)),
      l_costo,
      l_vence,
      NVL(l_entrada, SYSTIMESTAMP),
      TRIM(p_observaciones),
      SYSTIMESTAMP,
      SYSTIMESTAMP
    )
    RETURNING ID_LOTE INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- El UNIQUE es (ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO, NUMERO_LOTE): el
      -- choque es contra el mismo articulo en la misma sucursal, no global.
      p_status_code := 409;
      p_resultado := '{"error":"Este articulo ya tiene un lote con ese numero en esta sucursal"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: alguna FK no encontro el padre. Es un dato invalido del
      -- cliente (400), no un fallo del servidor.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La empresa, la sucursal o el articulo indicado no existe"}';
      ELSIF SQLCODE = -1722 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El numero de lote, la cantidad y el costo deben ser numericos"}';
      ELSIF SQLCODE IN (-1843, -1861, -1858, -1830) THEN
        -- Fecha con formato invalido. Se espera 'YYYY-MM-DD'.
        p_status_code := 400;
        p_resultado := '{"error":"Las fechas deben tener el formato AAAA-MM-DD"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_LOTES.INSERTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al crear el lote"}';
      END IF;
  END INSERTAR;

  PROCEDURE ACTUALIZAR (
    p_authorization      IN  VARCHAR2,
    p_id                 IN  VARCHAR2,
    p_id_empresa         IN  VARCHAR2,
    p_id_sucursal        IN  VARCHAR2,
    p_id_articulo        IN  VARCHAR2,
    p_numero_lote        IN  VARCHAR2,
    p_cantidad           IN  VARCHAR2,
    p_cantidad_dispon    IN  VARCHAR2,
    p_costo              IN  VARCHAR2,
    p_fecha_vencimiento  IN  VARCHAR2,
    p_fecha_entrada      IN  VARCHAR2,
    p_observaciones      IN  VARCHAR2,
    p_status_code        OUT NUMBER,
    p_resultado          OUT CLOB
  ) IS
    l_sesion      NUMBER;
    l_id          NUMBER;
    l_id_empresa  NUMBER;
    l_id_sucursal NUMBER;
    l_id_articulo NUMBER;
    l_numero_lote NUMBER;
    l_cantidad    NUMBER;
    l_dispon      NUMBER;
    l_costo       NUMBER;
    l_vence       TIMESTAMP;
    l_entrada     TIMESTAMP;
    -- Los valores que van a quedar tras el UPDATE, para validar la coherencia
    -- incluso cuando el pedido cambia solo uno de los tres ids o una sola fecha.
    l_emp_final   NUMBER;
    l_suc_final   NUMBER;
    l_art_final   NUMBER;
    l_vence_final TIMESTAMP;
    l_entra_final TIMESTAMP;
    l_cant_final  NUMBER;
    l_disp_final  NUMBER;
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
    l_id_articulo := TO_NUMBER(NULLIF(p_id_articulo, ''));
    l_numero_lote := TO_NUMBER(NULLIF(p_numero_lote, ''));
    l_cantidad    := TO_NUMBER(NULLIF(p_cantidad, ''));
    l_dispon      := TO_NUMBER(NULLIF(p_cantidad_dispon, ''));
    l_costo       := TO_NUMBER(NULLIF(p_costo, ''));
    l_vence       := A_TIMESTAMP(p_fecha_vencimiento);
    l_entrada     := A_TIMESTAMP(p_fecha_entrada);

    IF (l_cantidad IS NOT NULL AND l_cantidad < 0)
       OR (l_dispon IS NOT NULL AND l_dispon < 0)
       OR (l_costo IS NOT NULL AND l_costo < 0) THEN
      p_status_code := 400;
      p_resultado := '{"error":"Las cantidades y el costo no pueden ser negativos"}';
      RETURN;
    END IF;

    IF l_numero_lote IS NOT NULL AND l_numero_lote < 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"El numero de lote no puede ser negativo"}';
      RETURN;
    END IF;

    -- AISLAMIENTO POR EMPRESA: el idEmpresa acota A CUAL fila se le aplica el
    -- cambio, no es solo un campo mas a modificar. Sin el, un PUT con el id de
    -- un lote de OTRA empresa lo modificaba igual — la pantalla no lo permite,
    -- pero el endpoint es publico para cualquiera con sesion.
    --
    -- Va ANTES del SELECT porque ese SELECT tambien se acota con el.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    -- Que sucursal, articulo y fechas van a quedar despues del UPDATE. Se
    -- resuelve ANTES de escribir porque cambiar solo uno de ellos —dejando los
    -- otros como estaban— tambien puede romper la coherencia.
    --
    -- El SELECT lleva el AND ID_EMPRESA: si el lote es de otra empresa, cae en
    -- NO_DATA_FOUND y responde 404 sin llegar a tocar nada.
    BEGIN
      SELECT l_id_empresa,
             NVL(l_id_sucursal, ID_SUCURSAL),
             NVL(l_id_articulo, ID_ARTICULO),
             NVL(l_vence,       FECHA_VENCIMIENTO),
             NVL(l_entrada,     FECHA_ENTRADA),
             NVL(l_cantidad,    CANTIDAD),
             NVL(l_dispon,      NVL(CANTIDAD_DISPON, CANTIDAD))
        INTO l_emp_final, l_suc_final, l_art_final, l_vence_final, l_entra_final,
             l_cant_final, l_disp_final
        FROM LOTES
       WHERE ID_LOTE    = l_id
         AND ID_EMPRESA = l_id_empresa;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_status_code := 404;
        p_resultado := '{"error":"El lote no existe"}';
        RETURN;
    END;

    -- Contra los valores FINALES: bajar solo la cantidad por debajo del
    -- disponible que ya estaba guardado tambien deja el lote incoherente.
    IF l_disp_final > l_cant_final THEN
      p_status_code := 400;
      p_resultado := '{"error":"La cantidad disponible no puede superar la cantidad que entro"}';
      RETURN;
    END IF;

    IF NOT SUCURSAL_ES_DE_EMPRESA(l_suc_final, l_emp_final) THEN
      p_status_code := 400;
      p_resultado := '{"error":"La sucursal no pertenece a la empresa indicada"}';
      RETURN;
    END IF;

    IF NOT ARTICULO_ES_DE_EMPRESA(l_art_final, l_emp_final) THEN
      p_status_code := 400;
      p_resultado := '{"error":"El articulo no pertenece a la empresa indicada"}';
      RETURN;
    END IF;

    -- Se compara contra los valores FINALES: cambiar solo el vencimiento a una
    -- fecha anterior a la entrada que ya estaba guardada tambien es invalido.
    IF l_vence_final IS NOT NULL AND l_entra_final IS NOT NULL
       AND l_vence_final < l_entra_final THEN
      p_status_code := 400;
      p_resultado := '{"error":"El vencimiento no puede ser anterior a la fecha de entrada"}';
      RETURN;
    END IF;

    -- NVL en cada columna: un parametro ausente conserva el valor actual.
    --
    -- CONSECUENCIA EN FECHA_VENCIMIENTO: mandarla vacia significa "no cambiar",
    -- NO "quitar el vencimiento". Para poder borrarlo haria falta un centinela
    -- explicito que hoy no existe; es el mismo criterio que las FK opcionales
    -- de db/articulos.sql.
    --
    -- ID_EMPRESA fuera del SET a proposito: mover una fila de empresa es lo que
    -- el aislamiento busca impedir.
    UPDATE LOTES
       SET ID_SUCURSAL         = NVL(l_id_sucursal, ID_SUCURSAL),
           ID_ARTICULO         = NVL(l_id_articulo, ID_ARTICULO),
           NUMERO_LOTE         = NVL(l_numero_lote, NUMERO_LOTE),
           CANTIDAD            = NVL(l_cantidad, CANTIDAD),
           -- El NVL anidado cubre las filas viejas con CANTIDAD_DISPON en null:
           -- sin el, un PUT que no manda el disponible lo dejaria en null para
           -- siempre y esa fila no sumaria al stock.
           CANTIDAD_DISPON     = NVL(l_dispon, NVL(CANTIDAD_DISPON, CANTIDAD)),
           COSTO               = NVL(l_costo, COSTO),
           FECHA_VENCIMIENTO   = NVL(l_vence, FECHA_VENCIMIENTO),
           FECHA_ENTRADA       = NVL(l_entrada, FECHA_ENTRADA),
           OBSERVACIONES       = NVL(TRIM(p_observaciones), OBSERVACIONES),
           FECHA_ACTUALIZACION = SYSTIMESTAMP
     WHERE ID_LOTE    = l_id
       AND ID_EMPRESA = l_id_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El lote no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"Este articulo ya tiene un lote con ese numero en esta sucursal"}';
    WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        p_resultado := '{"error":"La empresa, la sucursal o el articulo indicado no existe"}';
      ELSIF SQLCODE = -1722 THEN
        p_status_code := 400;
        p_resultado := '{"error":"El numero de lote, la cantidad y el costo deben ser numericos"}';
      ELSIF SQLCODE IN (-1843, -1861, -1858, -1830) THEN
        p_status_code := 400;
        p_resultado := '{"error":"Las fechas deben tener el formato AAAA-MM-DD"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_LOTES.ACTUALIZAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al actualizar el lote"}';
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
    DELETE FROM LOTES
     WHERE ID_LOTE = l_id
       AND ID_EMPRESA = l_id_empresa;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El lote no existe"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02292: hay hijos (movimientos, ventas, lo que cuelgue del lote)
      -- apuntando a esta fila. Es un conflicto de estado (409), no un error del
      -- servidor: el dato que mandaron era valido.
      IF SQLCODE = -2292 THEN
        p_status_code := 409;
        p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de este lote"}';
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_LOTES.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al eliminar el lote"}';
      END IF;
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Publica el modulo ORDS /lotes/ con sus 4 endpoints.
  --
  -- Cada handler es una sola linea: invoca al procedimiento del paquete pasando
  -- los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parametro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin
  -- esto, toda peticion cross-origin a /lotes/* la rechaza ORDS antes de llegar
  -- a cualquiera de los 4 handlers. Ver la explicacion en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'lotes',
      p_base_path      => '/lotes/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Lotes de mercaderia por empresa, sucursal y articulo'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'lotes',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /lotes/listar?idEmpresa=&idSucursal=&idArticulo=
    --
    -- Los query params no se declaran con DEFINE_PARAMETER: se vinculan solos
    -- al bind del mismo nombre.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'lotes', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'lotes',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_LOTES.LISTAR(:authorization, :idEmpresa, :idSucursal, :idArticulo, :busqueda, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /lotes/articulos?idEmpresa=&idSucursal=
    --
    -- Los articulos que tienen al menos un lote, para el desplegable del filtro
    -- de la columna. Va aparte porque el listado ahora viene paginado y sus 20
    -- filas no alcanzan para armar las opciones.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'lotes', p_pattern => 'articulos');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'lotes',
      p_pattern     => 'articulos',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_LOTES.LISTAR_ARTICULOS(:authorization, :idEmpresa, :idSucursal, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'articulos', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'articulos', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'articulos', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /lotes/crear
    -- Body: { idEmpresa, idSucursal, idArticulo, numeroLote?, cantidad?, cantidadDispon?,
    --         costo?, fechaVencimiento?, fechaEntrada?, observaciones? }
    -- Las fechas en formato 'YYYY-MM-DD'.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'lotes', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'lotes',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_LOTES.INSERTAR(:authorization, :idEmpresa, :idSucursal, :idArticulo, :numeroLote, :cantidad, :cantidadDispon, :costo, :fechaVencimiento, :fechaEntrada, :observaciones, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /lotes/actualizar/:id
    -- Body: { idEmpresa?, idSucursal?, idArticulo?, numeroLote?, cantidad?, cantidadDispon?,
    --         costo?, fechaVencimiento?, fechaEntrada?, observaciones? }
    --       (ausentes = no cambia)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'lotes', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'lotes',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_LOTES.ACTUALIZAR(:authorization, :id, :idEmpresa, :idSucursal, :idArticulo, :numeroLote, :cantidad, :cantidadDispon, :costo, :fechaVencimiento, :fechaEntrada, :observaciones, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /lotes/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'lotes', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'lotes',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_LOTES.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'lotes', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_LOTES;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_LOTES.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_LOTES'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_LOTES'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'lotes';

-- Rutas publicadas: listar (GET), crear (POST), actualizar/:id (PUT),
-- eliminar/:id (DELETE).
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'lotes'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

SELECT l.ID_LOTE, e.NOMBRE_EMPRESA, s.NOMBRE_SUCURSAL, a.NOMBRE_ARTICULO,
       l.NUMERO_LOTE,
       l.CANTIDAD                                 AS ENTRO,
       NVL(l.CANTIDAD_DISPON, l.CANTIDAD)         AS QUEDA,
       l.CANTIDAD - NVL(l.CANTIDAD_DISPON, l.CANTIDAD) AS CONSUMIDO,
       l.COSTO,
       TO_CHAR(l.FECHA_ENTRADA, 'YYYY-MM-DD')     AS ENTRADA,
       TO_CHAR(l.FECHA_VENCIMIENTO, 'YYYY-MM-DD') AS VENCE
  FROM LOTES      l
  JOIN EMPRESAS   e ON e.ID_EMPRESA   = l.ID_EMPRESA
  JOIN SUCURSALES s ON s.ID_SUCURSAL  = l.ID_SUCURSAL
  JOIN ARTICULOS  a ON a.ID_ARTICULO  = l.ID_ARTICULO
 ORDER BY l.FECHA_VENCIMIENTO NULLS LAST, a.NOMBRE_ARTICULO;

-- Lotes incoherentes: mas disponible que lo que entro. Tiene que devolver CERO
-- filas — el paquete lo impide, pero una carga a mano por SQL no.
SELECT l.ID_LOTE, a.NOMBRE_ARTICULO, l.NUMERO_LOTE,
       l.CANTIDAD AS ENTRO, l.CANTIDAD_DISPON AS QUEDA
  FROM LOTES     l
  JOIN ARTICULOS a ON a.ID_ARTICULO = l.ID_ARTICULO
 WHERE l.CANTIDAD_DISPON > l.CANTIDAD;

-- Coherencia empresa/sucursal/articulo: el DDL no la garantiza (las tres FK son
-- independientes). Estas dos consultas tienen que devolver CERO filas; si
-- devuelven alguna, ese lote quedo colgado de una sucursal o un articulo de otra
-- empresa.
SELECT l.ID_LOTE, l.ID_EMPRESA AS EMPRESA_LOTE,
       s.ID_EMPRESA AS EMPRESA_SUCURSAL, l.NUMERO_LOTE
  FROM LOTES      l
  JOIN SUCURSALES s ON s.ID_SUCURSAL = l.ID_SUCURSAL
 WHERE s.ID_EMPRESA != l.ID_EMPRESA;

SELECT l.ID_LOTE, l.ID_EMPRESA AS EMPRESA_LOTE,
       a.ID_EMPRESA AS EMPRESA_ARTICULO, a.NOMBRE_ARTICULO, l.NUMERO_LOTE
  FROM LOTES     l
  JOIN ARTICULOS a ON a.ID_ARTICULO = l.ID_ARTICULO
 WHERE a.ID_EMPRESA != l.ID_EMPRESA;

-- Lo que vence en los proximos 30 dias. Es la consulta que justifica la tabla.
--
-- Filtra por CANTIDAD_DISPON y no por CANTIDAD: un lote consumido entero no se
-- pierde aunque venza, asi que no deberia aparecer en el aviso.
SELECT a.NOMBRE_ARTICULO, s.NOMBRE_SUCURSAL, l.NUMERO_LOTE,
       NVL(l.CANTIDAD_DISPON, l.CANTIDAD) AS QUEDA,
       TO_CHAR(l.FECHA_VENCIMIENTO, 'YYYY-MM-DD') AS VENCE,
       TRUNC(l.FECHA_VENCIMIENTO) - TRUNC(SYSDATE) AS DIAS
  FROM LOTES      l
  JOIN ARTICULOS  a ON a.ID_ARTICULO = l.ID_ARTICULO
  JOIN SUCURSALES s ON s.ID_SUCURSAL = l.ID_SUCURSAL
 WHERE l.FECHA_VENCIMIENTO IS NOT NULL
   AND l.FECHA_VENCIMIENTO <= SYSTIMESTAMP + INTERVAL '30' DAY
   AND NVL(l.CANTIDAD_DISPON, l.CANTIDAD) > 0
 ORDER BY l.FECHA_VENCIMIENTO;
