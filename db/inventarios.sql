--------------------------------------------------------------------------------
-- CTELL · INVENTARIOS
--
-- Un paquete (PKG_INVENTARIOS) con la carga de conteos fisicos, y la
-- publicacion de su modulo ORDS.
--
--   1. LISTAR      GET    /inventarios/listar
--                         (?idEmpresa= &idSucursal= &idArticulo= &estado=
--                          &busqueda= &pagina= &tamanio=)
--   2. OBTENER     GET    /inventarios/obtener/:id/:idEmpresa
--   3. INSERTAR    POST   /inventarios/crear
--   4. ACTUALIZAR  PUT    /inventarios/actualizar/:id
--   5. CERRAR      POST   /inventarios/cerrar/:id
--   6. ANULAR      POST   /inventarios/anular/:id
--   7. ELIMINAR    DELETE /inventarios/eliminar/:id/:idEmpresa
--
--------------------------------------------------------------------------------
-- ESTE PAQUETE NO ES EL DUENIO DE LAS REGLAS: LOS TRIGGERS LO SON
--
-- db/inventarios-triggers-ddl.sql pone dos triggers sobre INVENTARIOS y son
-- ellos los que deciden: que un conteo nace ABIERTO, que fuera de ABIERTO no se
-- toca nada, que cerrar exige una CANTIDAD_FISICA, y que al cerrar se escriba
-- EXISTENCIAS. Valen aunque alguien corrija la tabla a mano en la hoja SQL.
--
-- LO QUE HACE ESTE PAQUETE ES CHEQUEAR ANTES. Un RAISE_APPLICATION_ERROR que
-- llega sin traducir sale como un 500 mudo con un ORA-20102 adentro, y el
-- frontend muestra "Error al guardar" tapando un mensaje que explicaba
-- exactamente que pasaba. Aca cada regla se verifica primero para devolver
-- 404/409/400 con ese mismo texto, y ADEMAS el WHEN OTHERS traduce los
-- ORA-201xx por si el trigger llega a disparar igual — dos sesiones cerrando el
-- mismo conteo, por ejemplo.
--
-- La lista de codigos y su traduccion esta en ERROR_DE_NEGOCIO. Si se agrega
-- una regla al trigger, su codigo va tambien ahi.
--
--------------------------------------------------------------------------------
-- LA MAQUINA DE ESTADOS, DESDE LA API
--
--   POST   /crear        ──> ABIERTO
--   PUT    /actualizar   ──> sigue ABIERTO   (cantidad, fecha, observaciones)
--   POST   /cerrar       ──> CERRADO         escribe EXISTENCIAS
--   POST   /anular       ──> ANULADO         descarta, no toca nada
--   DELETE /eliminar     ──> solo si ABIERTO
--
-- CERRAR NO ES UN /actualizar CON EL ESTADO ADENTRO, y por eso tiene endpoint
-- propio. Contar y aplicar son dos actos distintos: el primero se corrige
-- cuantas veces haga falta, el segundo mueve el stock y no se deshace. Un PUT
-- que aceptara "estado" dejaria que un formulario de carga cierre el conteo sin
-- que nadie lo haya decidido.
--
-- PROCESADO no se acepta en ningun lado: es un valor legado de cuando el stock
-- vivia en lotes. Las filas historicas que lo tengan se listan y no se tocan.
--
--------------------------------------------------------------------------------
-- UN SOLO CONTEO ABIERTO POR ARTICULO Y SUCURSAL
--
-- El DDL no lo impide —no hay UNIQUE, y no podria haberlo porque los cerrados
-- SI se repiten: son el historico— asi que lo chequea INSERTAR y devuelve 409.
--
-- El motivo: dos conteos abiertos del mismo articulo en el mismo deposito son
-- dos personas contando el mismo estante. Al cerrarlos, el segundo pisa al
-- primero sin dejar rastro de que hubo dos numeros distintos, y la existencia
-- termina valiendo la del que se cerro ultimo por casualidad.
--
--------------------------------------------------------------------------------
-- CANTIDAD_SISTEMA NO LA ESCRIBE ESTE PAQUETE
--
-- La sella el trigger EN EL CIERRE, con lo que EXISTENCIAS decia un instante
-- antes de pisarla. Mientras el conteo esta ABIERTO la columna es NULL, y eso
-- es correcto: todavia no hay ajuste que explicar.
--
-- Para que la pantalla pueda mostrar "el sistema dice 12" mientras se cuenta,
-- el listado y el obtener devuelven ADEMAS `existenciaActual`, leida en vivo de
-- EXISTENCIAS. Son dos numeros distintos a proposito:
--
--   existenciaActual  lo que hay AHORA          (cambia solo, es una consulta)
--   cantidadSistema   lo que habia AL CERRAR    (congelado, es evidencia)
--
-- La diferencia de un conteo cerrado se calcula contra cantidadSistema. Contra
-- existenciaActual daria cero siempre, porque el cierre acaba de igualarlas.
--
--------------------------------------------------------------------------------
-- OBSERVACIONES NO VIENE ENTERA EN EL LISTADO, Y POR ESO EXISTE /obtener
--
-- La columna acepta 1000 caracteres. Veinte filas con la observacion completa
-- pasan holgado el techo de 4000 BYTES del bind de salida de ORDS, y la
-- peticion muere con un 500 que el WHEN OTHERS ni alcanza a registrar porque el
-- PL/SQL ya termino bien.
--
-- El listado manda `observacionesResumen`: los primeros 150 caracteres, para
-- que la fila muestre algo. El texto entero se pide con /obtener, que trae una
-- sola fila. EL FORMULARIO DE EDICION TIENE QUE USAR /obtener: si cargara el
-- resumen y lo guardara, el PUT escribiria los 150 caracteres encima de los
-- 1000 y se perderia el resto sin ningun error a la vista.
--
--------------------------------------------------------------------------------
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace.
--
-- REQUIERE, EN ESTE ORDEN:
--   1. db/auth.sql                        (PKG_AUTH, para validar el token)
--   2. db/inventarios-triggers-ddl.sql    (las reglas; este paquete las supone)
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/inventarios/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   INVENTARIOS  ID_INVENTARIO, ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO,
--                CANTIDAD_FISICA, ESTADO, FECHA_INVENTARIO, OBSERVACIONES,
--                FECHA_CREACION, FECHA_ACTUALIZACION, CANTIDAD_SISTEMA,
--                ID_USUARIO
--   FK a EMPRESAS, SUCURSALES, ARTICULOS y USUARIOS
--   Indices IDX_INVENTARIOS_EMPRESA / _SUCURSAL / _ARTICULO / _ESTADO
--           y IDX_INVENTARIOS_EMPRESA_SUCURSAL
--
-- ID_USUARIO SALE DEL TOKEN, no del body: es quien conto. Mandarlo desde el
-- cliente dejaria firmar un conteo a nombre de otro. USER dentro de un handler
-- de ORDS devuelve el esquema del workspace, igual para todo el mundo, asi que
-- no sirve — el dato lo da PKG_AUTH.VALIDAR_TOKEN, que YA devuelve el id del
-- usuario de la sesion.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO, no del workspace. Ver db/auth.sql.
--
-- COMO EJECUTAR
--   1. Frena `npm run dev` (evita ORA-00060 al borrar el modulo).
--   2. Pega este archivo entero en la hoja SQL de APEX y ejecutalo.
--   3. Revisa que PKG_INVENTARIOS quede VALID y USER_ERRORS vacio.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_INVENTARIOS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_INVENTARIOS.LISTAR('Bearer TU_TOKEN', '1', NULL, NULL, NULL, NULL,
--                            NULL, NULL, l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_INVENTARIOS AS

  -- Conteos de la empresa, del mas reciente al mas viejo.
  --
  -- idEmpresa es OBLIGATORIO; el resto de los filtros son opcionales y se
  -- combinan. `estado` acepta ABIERTO, CERRADO, ANULADO o PROCESADO (este
  -- ultimo solo para ver filas historicas).
  --
  -- NO trae OBSERVACIONES completa: ver el encabezado del archivo.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_estado        IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Un conteo con su OBSERVACIONES entera. Es el que tiene que usar el
  -- formulario de edicion, no la fila del listado.
  PROCEDURE OBTENER (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Alta del conteo. Nace ABIERTO (lo impone el trigger) y firmado por el
  -- usuario del token.
  --
  -- p_cantidad_fisica es OPCIONAL en el alta: deja abrir la planilla y cargar
  -- el numero despues de ir al deposito. Lo que no se puede es CERRAR sin el.
  PROCEDURE INSERTAR (
    p_authorization    IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_id_sucursal      IN  VARCHAR2,
    p_id_articulo      IN  VARCHAR2,
    p_cantidad_fisica  IN  VARCHAR2,
    p_fecha_inventario IN  VARCHAR2,
    p_observaciones    IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  );

  -- Corrige un conteo ABIERTO. Empresa, sucursal y articulo NO se modifican
  -- (lo rechaza el trigger): contar otra cosa es cargar otro inventario.
  --
  -- A diferencia del resto del proyecto, un campo vacio NO conserva el valor:
  -- lo borra. Ver la nota del procedimiento en el body.
  PROCEDURE ACTUALIZAR (
    p_authorization    IN  VARCHAR2,
    p_id               IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_cantidad_fisica  IN  VARCHAR2,
    p_fecha_inventario IN  VARCHAR2,
    p_observaciones    IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  );

  -- Aplica el conteo: ESTADO pasa a CERRADO y el trigger escribe EXISTENCIAS.
  -- Devuelve lo que decia el sistema y lo que quedo, para que la pantalla pueda
  -- confirmar el ajuste sin volver a consultar.
  PROCEDURE CERRAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Descarta el conteo. No toca EXISTENCIAS y no deja de ser evidencia de que
  -- alguien fue a contar: por eso se anula en vez de borrarse.
  PROCEDURE ANULAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Baja fisica, SOLO mientras esta ABIERTO. Un conteo cerrado ya movio el
  -- stock; borrarlo dejaria la existencia sin la explicacion de por que dice lo
  -- que dice.
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el modulo ORDS /inventarios/ con sus 7 endpoints.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_INVENTARIOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_INVENTARIOS AS

  -- 20 por pagina, con techo de 50. Mismo criterio que db/existencias.sql: el
  -- JSON sale por un bind tipado STRING con limite de 4000 BYTES, y una pagina
  -- grande lo pasa y muere con un 500 que el WHEN OTHERS no llega a registrar.
  C_TAMANIO_DEFECTO CONSTANT PLS_INTEGER := 20;
  C_TAMANIO_MAXIMO  CONSTANT PLS_INTEGER := 50;

  -- Cuanto de OBSERVACIONES entra en la fila del listado. Ver el encabezado:
  -- el texto completo se pide con OBTENER.
  C_LARGO_RESUMEN CONSTANT PLS_INTEGER := 150;

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
        SELECT COUNT(*)
          INTO l_existe
          FROM USER_ORDS_MODULES
         WHERE NAME = 'inventarios';

        IF l_existe = 0 THEN
          RETURN;
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'inventarios');
        COMMIT;
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
          -- ORA-00060 (interbloqueo) y ORA-04020 (lock de objeto) son
          -- transitorios: la otra sesion termina y el reintento pasa.
          --
          -- DBMS_SESSION.SLEEP y NO DBMS_LOCK.SLEEP: este workspace no tiene
          -- GRANT EXECUTE sobre SYS.DBMS_LOCK, y usarlo hace que el BODY no
          -- compile con PLS-00201.
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
  -- Privado: traduce un RAISE_APPLICATION_ERROR de los triggers a HTTP.
  --
  -- Devuelve TRUE si el error era de negocio (y deja p_status_code/p_resultado
  -- cargados); FALSE si no lo reconoce, para que el llamador lo trate como 500.
  --
  -- SQLCODE Y SQLERRM SE RECIBEN POR PARAMETRO, no se leen aca adentro: dentro
  -- de un procedimiento llamado desde un manejador de excepciones no hay
  -- garantia de que sigan apuntando al error original.
  --
  -- EL MENSAJE ES EL DEL TRIGGER, no uno propio. Los triggers explican QUE
  -- hacer ("carga un conteo nuevo"), y reescribirlos aca daria dos textos que se
  -- desincronizan a la primera correccion. Se le saca el prefijo "ORA-20102: " y
  -- las lineas de backtrace que Oracle agrega debajo.
  --
  -- LOS CODIGOS SALEN DE db/inventarios-triggers-ddl.sql:
  --   -20101  estado invalido                             400 dato mal formado
  --   -20102  la fila ya no esta ABIERTA                   409 conflicto
  --   -20103  no se elimina lo que no esta ABIERTO         409 conflicto
  --   -20104  un inventario nace ABIERTO                   400
  --   -20105  cerrar sin cantidad contada, o negativa      400
  --   -20106  ids de empresas distintas, o cambiados       400
  ------------------------------------------------------------------------------
  FUNCTION ERROR_DE_NEGOCIO (
    p_sqlcode     IN  PLS_INTEGER,
    p_sqlerrm     IN  VARCHAR2,
    p_status_code OUT NUMBER,
    p_resultado   OUT CLOB
  ) RETURN BOOLEAN IS
    l_estado  NUMBER;
    l_mensaje VARCHAR2(4000);
  BEGIN
    l_estado := CASE p_sqlcode
                  WHEN -20101 THEN 400
                  WHEN -20102 THEN 409
                  WHEN -20103 THEN 409
                  WHEN -20104 THEN 400
                  WHEN -20105 THEN 400
                  WHEN -20106 THEN 400
                  ELSE NULL
                END;

    IF l_estado IS NULL THEN
      RETURN FALSE;
    END IF;

    -- Primera linea nada mas: debajo vienen los ORA-06512 del backtrace, que al
    -- usuario no le dicen nada.
    l_mensaje := SUBSTR(p_sqlerrm, 1, INSTR(p_sqlerrm || CHR(10), CHR(10)) - 1);
    l_mensaje := REGEXP_REPLACE(l_mensaje, '^ORA-[0-9]+:[[:space:]]*', '');

    p_status_code := l_estado;

    -- JSON_OBJECT y no concatenar: el mensaje del trigger trae comillas dobles
    -- (los estados van entrecomillados) y armarlo a mano daria un JSON roto que
    -- el frontend no puede parsear.
    SELECT JSON_OBJECT('error' VALUE l_mensaje RETURNING CLOB)
      INTO p_resultado
      FROM DUAL;

    RETURN TRUE;
  END ERROR_DE_NEGOCIO;

  ------------------------------------------------------------------------------
  -- Privado: el texto de fecha que manda el cliente -> TIMESTAMP.
  --
  -- LA HORA IMPORTA, no alcanza con el dia. Dos conteos del mismo articulo el
  -- mismo dia se ordenan entre si por la hora, y el que se cierra despues es el
  -- que manda: sin hora, los dos empatan a medianoche y el orden lo decide el
  -- id, que es la hora de CARGA y no la del conteo.
  --
  -- ACEPTA TRES FORMAS, y no es por comodidad:
  --
  --   2026-09-02T14:30:05   lo normal
  --   2026-09-02T14:30      un <input type="datetime-local"> OMITE los segundos
  --                         cuando estan en cero; el mismo formulario manda una
  --                         u otra segun lo que se haya tipeado
  --   2026-09-02            por si alguien llama al endpoint a mano
  --
  -- La ultima vale MEDIANOCHE. Es lo unico razonable —no se puede inventar la
  -- hora de un conteo— pero deja la fila ordenada antes que cualquier otra del
  -- mismo dia, que es justamente lo que la hora vino a resolver.
  --
  -- El orden de los intentos NO es intercambiable: TO_TIMESTAMP con la mascara
  -- corta sobre un texto largo falla con ORA-01830 ("se ha encontrado el
  -- caracter no valido"), asi que se prueba de la mas larga a la mas corta. La
  -- ultima se deja PROPAGAR: es la que le dice al llamador que devuelva 400.
  ------------------------------------------------------------------------------
  FUNCTION A_TIMESTAMP (p_texto IN VARCHAR2) RETURN TIMESTAMP IS
    l_texto VARCHAR2(40);
  BEGIN
    l_texto := NULLIF(TRIM(p_texto), '');

    IF l_texto IS NULL THEN
      RETURN NULL;
    END IF;

    -- La T de ISO pasa a espacio para no arrastrar el literal "T" en cada
    -- mascara. Lo demas son digitos, guiones y dos puntos.
    l_texto := REPLACE(UPPER(l_texto), 'T', ' ');

    BEGIN
      RETURN TO_TIMESTAMP(l_texto, 'YYYY-MM-DD HH24:MI:SS');
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;

    BEGIN
      RETURN TO_TIMESTAMP(l_texto, 'YYYY-MM-DD HH24:MI');
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;

    RETURN TO_TIMESTAMP(l_texto, 'YYYY-MM-DD');
  END A_TIMESTAMP;

  ------------------------------------------------------------------------------
  -- Privado: lee la fila de un conteo BLOQUEADA, o avisa que no es de esa
  -- empresa.
  --
  -- FOR UPDATE, y no es un detalle: entre leer el ESTADO para decidir si se
  -- puede tocar y hacer el UPDATE hay una ventana en la que otra sesion puede
  -- cerrar el mismo conteo. Sin el bloqueo, las dos pasan el chequeo y la
  -- segunda se lleva el ORA-20102 del trigger como error crudo; con el, la
  -- segunda espera, vuelve a leer el estado ya cambiado y responde 409 con el
  -- texto que corresponde.
  --
  -- Es el mismo `SELECT ... FOR UPDATE` que va a necesitar PKG_STOCK cuando
  -- exista, por exactamente la misma razon.
  ------------------------------------------------------------------------------
  PROCEDURE LEER_PARA_MODIFICAR (
    p_id       IN  NUMBER,
    p_empresa  IN  NUMBER,
    p_estado   OUT VARCHAR2,
    p_cantidad OUT NUMBER,
    p_existe   OUT BOOLEAN
  ) IS
  BEGIN
    SELECT NVL(UPPER(TRIM(ESTADO)), 'ABIERTO'), CANTIDAD_FISICA
      INTO p_estado, p_cantidad
      FROM INVENTARIOS
     WHERE ID_INVENTARIO = p_id
       AND ID_EMPRESA    = p_empresa
       FOR UPDATE;

    p_existe := TRUE;
  EXCEPTION
    -- Inexistente o de otra empresa: son lo mismo para quien pregunta. Decir
    -- "existe pero no es tuyo" filtraria que ese id esta en uso.
    WHEN NO_DATA_FOUND THEN
      p_existe   := FALSE;
      p_estado   := NULL;
      p_cantidad := NULL;
  END LEER_PARA_MODIFICAR;

  ------------------------------------------------------------------------------
  -- LISTAR
  ------------------------------------------------------------------------------
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_id_sucursal   IN  VARCHAR2,
    p_id_articulo   IN  VARCHAR2,
    p_estado        IN  VARCHAR2,
    p_busqueda      IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_empresa  NUMBER;
    l_sucursal NUMBER;
    l_articulo NUMBER;
    l_estado   VARCHAR2(20);
    l_busqueda VARCHAR2(200);
    l_pagina   PLS_INTEGER;
    l_tamanio  PLS_INTEGER;
    l_desplaza PLS_INTEGER;
    l_total    NUMBER;
    l_items    CLOB;
    -- Copia local de la constante del paquete: en el SELECT de abajo entra como
    -- bind, y con una variable local no hay dudas de que el motor la vincula.
    -- Misma precaucion que con los helpers privados, que directamente no se
    -- pueden llamar desde una sentencia SQL (PLS-00231).
    l_resumen  PLS_INTEGER := C_LARGO_RESUMEN;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- Un parametro ausente llega como cadena vacia, no como NULL: NULLIF lo
    -- convierte antes de que el filtro lo tome como un valor real.
    l_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    l_articulo := TO_NUMBER(NULLIF(p_id_articulo, ''));
    l_estado   := UPPER(NULLIF(TRIM(p_estado), ''));
    l_busqueda := LOWER(NULLIF(TRIM(p_busqueda), ''));

    IF l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio"}';
      RETURN;
    END IF;

    l_pagina  := GREATEST(NVL(TO_NUMBER(NULLIF(p_pagina, '')), 1), 1);
    l_tamanio := LEAST(NVL(TO_NUMBER(NULLIF(p_tamanio, '')), C_TAMANIO_DEFECTO),
                       C_TAMANIO_MAXIMO);
    l_desplaza := (l_pagina - 1) * l_tamanio;

    -- EL COUNT REPITE EXACTAMENTE EL MISMO WHERE que la consulta de abajo. Si
    -- filtran distinto, el total dice una cosa y las filas otra, y el paginador
    -- de la pantalla ofrece paginas vacias.
    SELECT COUNT(*)
      INTO l_total
      FROM INVENTARIOS i
      JOIN ARTICULOS   a ON a.ID_ARTICULO = i.ID_ARTICULO
     WHERE i.ID_EMPRESA = l_empresa
       AND (l_sucursal IS NULL OR i.ID_SUCURSAL = l_sucursal)
       AND (l_articulo IS NULL OR i.ID_ARTICULO = l_articulo)
       AND (l_estado   IS NULL OR NVL(UPPER(TRIM(i.ESTADO)), 'ABIERTO') = l_estado)
       -- SE BUSCA POR CUALQUIER DATO CON EL QUE SE RECONOCE LA PIEZA: nombre,
       -- codigo del fabricante, marca y equivalencias. Es el mismo criterio de
       -- la lista de valores de db/articulos.sql, y tiene que serlo: si se
       -- eligio el articulo tecleando una equivalencia, buscar despues su
       -- conteo con esa misma equivalencia no puede no encontrarlo.
       --
       -- EXISTS y no JOIN: un articulo con cinco equivalencias duplicaria su
       -- conteo cinco veces en el COUNT, y el total diria cualquier cosa.
       AND (l_busqueda IS NULL
            OR LOWER(a.NOMBRE_ARTICULO) LIKE '%' || l_busqueda || '%'
            OR LOWER(a.CODIGO_ARTICULO) LIKE '%' || l_busqueda || '%'
            OR EXISTS (SELECT 1 FROM MARCAS mb
                        WHERE mb.ID_MARCA = a.ID_MARCA
                          AND LOWER(mb.DESCRIPCION) LIKE '%' || l_busqueda || '%')
            -- Correlacionado TAMBIEN por empresa: el UNIQUE de esa tabla la
            -- incluye, asi que el mismo codigo puede existir en dos empresas
            -- sobre articulos distintos.
            OR EXISTS (SELECT 1 FROM CODIGOS_EQUIVALENTES cb
                        WHERE cb.ID_ARTICULO = a.ID_ARTICULO
                          AND cb.ID_EMPRESA  = a.ID_EMPRESA
                          AND LOWER(cb.CODIGO_EQUIVALENTE) LIKE '%' || l_busqueda || '%'));

    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta al pasar los 4000
    -- bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden_fecha DESC, orden_id DESC RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'id'             VALUE i.ID_INVENTARIO,
                 'idEmpresa'      VALUE i.ID_EMPRESA,
                 'idSucursal'     VALUE i.ID_SUCURSAL,
                 'sucursal'       VALUE s.NOMBRE_SUCURSAL,
                 'idArticulo'     VALUE i.ID_ARTICULO,
                 -- Del JOIN: sin el nombre la fila son numeros sueltos y la
                 -- pantalla tendria que traer el catalogo entero para leerla.
                 'nombreArticulo' VALUE a.NOMBRE_ARTICULO,
                 'codigoArticulo' VALUE a.CODIGO_ARTICULO,
                 -- LA MARCA IDENTIFICA LA PIEZA. Dos articulos que se llaman
                 -- "Filtro de aceite" son cosas distintas segun de quien sean, y
                 -- en un conteo lo que se tiene en la mano es la pieza, no el
                 -- nombre generico. Es lo mismo que muestra la lista de valores
                 -- al elegirlo: no devolverla haria que al reabrir el conteo se
                 -- perdiera el dato con el que se lo eligio.
                 'marca'          VALUE mc.DESCRIPCION,
                 -- Misma razon que la marca: es el otro dato que el dialogo de
                 -- conteo ofrece completar si esta en NULL.
                 'categoria'      VALUE cc.NOMBRE_CATEGORIA,
                 -- Lo contado. NULL mientras la planilla este abierta y nadie
                 -- haya ido al deposito todavia.
                 'cantidadFisica' VALUE i.CANTIDAD_FISICA,
                 -- Lo que decia el sistema AL CERRAR. NULL en los abiertos: no
                 -- hay ajuste que explicar hasta que se aplique.
                 'cantidadSistema' VALUE i.CANTIDAD_SISTEMA,
                 -- Lo que dice EXISTENCIAS AHORA, leido en vivo. Es contra esto
                 -- que se compara mientras se cuenta, y contra cantidadSistema
                 -- despues de cerrar. Ver el encabezado del archivo.
                 'existenciaActual' VALUE NVL(e.CANTIDAD_DISPONIBLE, 0),
                 'estado'         VALUE NVL(UPPER(TRIM(i.ESTADO)), 'ABIERTO'),
                 'fechaInventario' VALUE TO_CHAR(i.FECHA_INVENTARIO,
                                                 'YYYY-MM-DD"T"HH24:MI:SS'),
                 'fechaActualizacion' VALUE TO_CHAR(i.FECHA_ACTUALIZACION,
                                                    'YYYY-MM-DD"T"HH24:MI:SS'),
                 'idUsuario'      VALUE i.ID_USUARIO,
                 -- Quien conto. Un ajuste de stock sin firma no se le puede
                 -- preguntar a nadie.
                 'usuario'        VALUE u.NOMBRE_APELLIDO,
                 -- RECORTADA: el texto entero se pide con /obtener. Ver el
                 -- encabezado — mandarla completa revienta el bind de ORDS.
                 'observacionesResumen' VALUE SUBSTR(i.OBSERVACIONES, 1, l_resumen)
                 RETURNING CLOB
               ) AS fila,
               i.FECHA_INVENTARIO AS orden_fecha,
               i.ID_INVENTARIO    AS orden_id
          FROM INVENTARIOS i
          JOIN ARTICULOS   a ON a.ID_ARTICULO = i.ID_ARTICULO
          -- LEFT EN LAS CINCO: con JOIN interno, un articulo sin marca o sin
          -- categoria, una sucursal borrada, un usuario dado de baja o un
          -- articulo que nunca tuvo existencia harian DESAPARECER el conteo del
          -- listado sin ningun error. Un conteo que no se ve es peor que uno sin
          -- nombre.
          LEFT JOIN MARCAS      mc ON mc.ID_MARCA    = a.ID_MARCA
          LEFT JOIN CATEGORIAS  cc ON cc.ID_CATEGORIA = a.ID_CATEGORIA
          LEFT JOIN SUCURSALES  s ON s.ID_SUCURSAL = i.ID_SUCURSAL
          LEFT JOIN USUARIOS    u ON u.ID_USUARIO  = i.ID_USUARIO
          LEFT JOIN EXISTENCIAS e ON e.ID_EMPRESA  = i.ID_EMPRESA
                                 AND e.ID_SUCURSAL = i.ID_SUCURSAL
                                 AND e.ID_ARTICULO = i.ID_ARTICULO
         WHERE i.ID_EMPRESA = l_empresa
           AND (l_sucursal IS NULL OR i.ID_SUCURSAL = l_sucursal)
           AND (l_articulo IS NULL OR i.ID_ARTICULO = l_articulo)
           AND (l_estado   IS NULL OR NVL(UPPER(TRIM(i.ESTADO)), 'ABIERTO') = l_estado)
           -- IDENTICO AL DEL COUNT DE ARRIBA. Si filtran distinto, el total dice
           -- una cosa y las filas otra, y el "Mostrar mas" ofrece paginas
           -- vacias.
           AND (l_busqueda IS NULL
                OR LOWER(a.NOMBRE_ARTICULO) LIKE '%' || l_busqueda || '%'
                OR LOWER(a.CODIGO_ARTICULO) LIKE '%' || l_busqueda || '%'
                OR EXISTS (SELECT 1 FROM MARCAS mb
                            WHERE mb.ID_MARCA = a.ID_MARCA
                              AND LOWER(mb.DESCRIPCION) LIKE '%' || l_busqueda || '%')
                OR EXISTS (SELECT 1 FROM CODIGOS_EQUIVALENTES cb
                            WHERE cb.ID_ARTICULO = a.ID_ARTICULO
                              AND cb.ID_EMPRESA  = a.ID_EMPRESA
                              AND LOWER(cb.CODIGO_EQUIVALENTE) LIKE '%' || l_busqueda || '%'))
         -- EL ORDER BY VA ACA, en la subconsulta, ademas de en el
         -- JSON_ARRAYAGG: es el que decide QUE filas entran en la pagina. Sin
         -- el, OFFSET/FETCH recorta en un orden que Oracle no garantiza y la
         -- misma fila puede aparecer en dos paginas.
         --
         -- El id desempata: dos conteos cargados el mismo instante quedarian en
         -- un orden arbitrario, que es el mismo problema en chico.
         ORDER BY i.FECHA_INVENTARIO DESC, i.ID_INVENTARIO DESC
         OFFSET l_desplaza ROWS FETCH NEXT l_tamanio ROWS ONLY
      );

    p_status_code := 200;
    -- SELECT ... INTO y no una asignacion directa: `RETURNING CLOB` no se acepta
    -- en una expresion PL/SQL suelta (PLS-00684).
    --
    -- NVL sobre l_items: JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un
    -- array vacio, y el frontend reventaria al iterar "items":null.
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
      APEX_DEBUG.ERROR('PKG_INVENTARIOS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los inventarios"}';
  END LISTAR;

  ------------------------------------------------------------------------------
  -- OBTENER
  ------------------------------------------------------------------------------
  PROCEDURE OBTENER (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
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

    -- AISLAMIENTO POR EMPRESA en el WHERE, no en el cliente: el endpoint es
    -- publico para cualquiera con sesion, y sin la empresa se leeria el conteo
    -- de otra con solo adivinar el id.
    --
    -- Aca SI va OBSERVACIONES entera: es una fila sola, no hay techo que pasar.
    SELECT JSON_OBJECT(
             'id'             VALUE i.ID_INVENTARIO,
             'idEmpresa'      VALUE i.ID_EMPRESA,
             'idSucursal'     VALUE i.ID_SUCURSAL,
             'sucursal'       VALUE s.NOMBRE_SUCURSAL,
             'idArticulo'     VALUE i.ID_ARTICULO,
             'nombreArticulo' VALUE a.NOMBRE_ARTICULO,
             'codigoArticulo' VALUE a.CODIGO_ARTICULO,
             'marca'          VALUE mc.DESCRIPCION,
             'categoria'      VALUE cc.NOMBRE_CATEGORIA,
             'cantidadFisica' VALUE i.CANTIDAD_FISICA,
             'cantidadSistema' VALUE i.CANTIDAD_SISTEMA,
             'existenciaActual' VALUE NVL(e.CANTIDAD_DISPONIBLE, 0),
             'estado'         VALUE NVL(UPPER(TRIM(i.ESTADO)), 'ABIERTO'),
             'fechaInventario' VALUE TO_CHAR(i.FECHA_INVENTARIO,
                                             'YYYY-MM-DD"T"HH24:MI:SS'),
             'fechaActualizacion' VALUE TO_CHAR(i.FECHA_ACTUALIZACION,
                                                'YYYY-MM-DD"T"HH24:MI:SS'),
             'idUsuario'      VALUE i.ID_USUARIO,
             'usuario'        VALUE u.NOMBRE_APELLIDO,
             'observaciones'  VALUE i.OBSERVACIONES
             RETURNING CLOB
           )
      INTO p_resultado
      FROM INVENTARIOS i
      JOIN ARTICULOS   a ON a.ID_ARTICULO = i.ID_ARTICULO
      LEFT JOIN MARCAS      mc ON mc.ID_MARCA    = a.ID_MARCA
      LEFT JOIN CATEGORIAS  cc ON cc.ID_CATEGORIA = a.ID_CATEGORIA
      LEFT JOIN SUCURSALES  s ON s.ID_SUCURSAL = i.ID_SUCURSAL
      LEFT JOIN USUARIOS    u ON u.ID_USUARIO  = i.ID_USUARIO
      LEFT JOIN EXISTENCIAS e ON e.ID_EMPRESA  = i.ID_EMPRESA
                             AND e.ID_SUCURSAL = i.ID_SUCURSAL
                             AND e.ID_ARTICULO = i.ID_ARTICULO
     WHERE i.ID_INVENTARIO = l_id
       AND i.ID_EMPRESA    = l_empresa;

    p_status_code := 200;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_status_code := 404;
      p_resultado := '{"error":"El inventario no existe"}';
    WHEN OTHERS THEN
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_INVENTARIOS.OBTENER: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al obtener el inventario"}';
  END OBTENER;

  ------------------------------------------------------------------------------
  -- INSERTAR
  ------------------------------------------------------------------------------
  PROCEDURE INSERTAR (
    p_authorization    IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_id_sucursal      IN  VARCHAR2,
    p_id_articulo      IN  VARCHAR2,
    p_cantidad_fisica  IN  VARCHAR2,
    p_fecha_inventario IN  VARCHAR2,
    p_observaciones    IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_empresa  NUMBER;
    l_sucursal NUMBER;
    l_articulo NUMBER;
    l_cantidad NUMBER;
    l_fecha    TIMESTAMP;
    l_abiertos PLS_INTEGER;
    l_id       NUMBER;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_empresa  := TO_NUMBER(NULLIF(p_id_empresa, ''));
    l_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    l_articulo := TO_NUMBER(NULLIF(p_id_articulo, ''));

    IF l_empresa IS NULL OR l_sucursal IS NULL OR l_articulo IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa, idSucursal e idArticulo son obligatorios"}';
      RETURN;
    END IF;

    -- La cantidad es OPCIONAL en el alta (se abre la planilla y se cuenta
    -- despues), pero si viene tiene que ser un numero valido y no negativo:
    -- guardarla mal aca la convierte en un rechazo recien al cerrar, cuando ya
    -- nadie se acuerda de que cargo.
    --
    -- El TO_NUMBER va con su propio manejador y no suelto entre las
    -- asignaciones: "12,5" o "abc" darian ORA-01722, que sin esto sale como un
    -- 500 generico en vez de decir cual campo esta mal.
    BEGIN
      l_cantidad := TO_NUMBER(NULLIF(TRIM(p_cantidad_fisica), ''));
    EXCEPTION
      WHEN OTHERS THEN
        p_status_code := 400;
        p_resultado := '{"error":"La cantidad contada tiene que ser un numero"}';
        RETURN;
    END;

    IF l_cantidad IS NOT NULL AND l_cantidad < 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La cantidad contada no puede ser negativa"}';
      RETURN;
    END IF;

    -- Fecha Y HORA, opcionales: sirven para cargar hoy un conteo hecho ayer a
    -- las tres de la tarde. Sin ellas el trigger pone SYSTIMESTAMP, que es el
    -- momento de la carga — correcto sólo cuando se cuenta y se carga a la vez.
    -- Los formatos aceptados están en A_TIMESTAMP.
    IF NULLIF(TRIM(p_fecha_inventario), '') IS NOT NULL THEN
      BEGIN
        l_fecha := A_TIMESTAMP(p_fecha_inventario);
      EXCEPTION
        WHEN OTHERS THEN
          p_status_code := 400;
          p_resultado := '{"error":"La fecha del conteo tiene que venir como YYYY-MM-DDTHH:MI:SS"}';
          RETURN;
      END;
    END IF;

    -- UN SOLO CONTEO ABIERTO POR ARTICULO Y SUCURSAL. Ver el encabezado: dos
    -- planillas abiertas del mismo estante terminan en que la que se cierre
    -- ultima pisa a la otra sin dejar rastro.
    SELECT COUNT(*)
      INTO l_abiertos
      FROM INVENTARIOS
     WHERE ID_EMPRESA  = l_empresa
       AND ID_SUCURSAL = l_sucursal
       AND ID_ARTICULO = l_articulo
       AND NVL(UPPER(TRIM(ESTADO)), 'ABIERTO') = 'ABIERTO';

    IF l_abiertos > 0 THEN
      p_status_code := 409;
      p_resultado := '{"error":"Ya hay un conteo abierto de este articulo en esta sucursal. Cerralo o anulalo antes de cargar otro"}';
      RETURN;
    END IF;

    -- ESTADO, FECHA_CREACION y FECHA_ACTUALIZACION NO se escriben aca: los pone
    -- el trigger, que ademas rechaza cualquier estado que no sea ABIERTO.
    --
    -- ID_USUARIO sale de la sesion, no del body: es la firma del conteo.
    INSERT INTO INVENTARIOS (
      ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO, ID_USUARIO,
      CANTIDAD_FISICA, FECHA_INVENTARIO, OBSERVACIONES
    ) VALUES (
      l_empresa, l_sucursal, l_articulo, l_sesion,
      l_cantidad, l_fecha, NULLIF(TRIM(p_observaciones), '')
    )
    RETURNING ID_INVENTARIO INTO l_id;

    COMMIT;
    p_status_code := 201;
    p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      DECLARE
        l_codigo  PLS_INTEGER    := SQLCODE;
        l_mensaje VARCHAR2(4000) := SQLERRM;
      BEGIN
        IF ERROR_DE_NEGOCIO(l_codigo, l_mensaje, p_status_code, p_resultado) THEN
          NULL;
        ELSIF l_codigo = -2291 THEN
          -- La FK no encontro el padre. Es un dato invalido del cliente (400),
          -- no un fallo del servidor.
          p_status_code := 400;
          p_resultado := '{"error":"La empresa, la sucursal o el articulo indicados no existen"}';
        ELSE
          p_status_code := 500;
          APEX_DEBUG.ERROR('PKG_INVENTARIOS.INSERTAR: [' || l_codigo || '] ' || l_mensaje || ' | ' ||
                           DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
          p_resultado := '{"error":"Error al crear el inventario"}';
        END IF;
      END;
  END INSERTAR;

  ------------------------------------------------------------------------------
  -- ACTUALIZAR
  --
  -- OJO, ROMPE EL CRITERIO DEL RESTO DEL PROYECTO: aca un campo vacio NO
  -- conserva el valor, lo BORRA. Vale para la cantidad y para las
  -- observaciones.
  --
  -- El motivo: en las demas tablas el NVL cubre llamadas parciales sobre campos
  -- que siempre tienen algo. Aca el campo central es un NUMERO QUE PUEDE QUEDAR
  -- VACIO —una planilla abierta sin contar todavia— y con NVL no habria forma
  -- de volver a vaciarlo: quien cargo 12 por error quedaria con 12 para
  -- siempre, y cerrar aplicaria ese 12 al stock.
  --
  -- Consecuencia para el cliente: el PUT manda SIEMPRE los tres campos, con lo
  -- que el formulario tenga. Es lo que hace la pantalla de /inventarios.
  --
  -- FECHA_INVENTARIO es la excepcion de la excepcion: un NULL ahi dejaria la
  -- planilla sin fecha, y la fecha de un conteo no es opcional una vez que
  -- existe. Se conserva la que tenga.
  ------------------------------------------------------------------------------
  PROCEDURE ACTUALIZAR (
    p_authorization    IN  VARCHAR2,
    p_id               IN  VARCHAR2,
    p_id_empresa       IN  VARCHAR2,
    p_cantidad_fisica  IN  VARCHAR2,
    p_fecha_inventario IN  VARCHAR2,
    p_observaciones    IN  VARCHAR2,
    p_status_code      OUT NUMBER,
    p_resultado        OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_id       NUMBER;
    l_empresa  NUMBER;
    l_cantidad NUMBER;
    l_fecha    TIMESTAMP;
    l_estado   VARCHAR2(20);
    l_actual   NUMBER;
    l_existe   BOOLEAN;
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

    BEGIN
      l_cantidad := TO_NUMBER(NULLIF(TRIM(p_cantidad_fisica), ''));
    EXCEPTION
      WHEN OTHERS THEN
        p_status_code := 400;
        p_resultado := '{"error":"La cantidad contada tiene que ser un numero"}';
        RETURN;
    END;

    IF l_cantidad IS NOT NULL AND l_cantidad < 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La cantidad contada no puede ser negativa"}';
      RETURN;
    END IF;

    IF NULLIF(TRIM(p_fecha_inventario), '') IS NOT NULL THEN
      BEGIN
        l_fecha := A_TIMESTAMP(p_fecha_inventario);
      EXCEPTION
        WHEN OTHERS THEN
          p_status_code := 400;
          p_resultado := '{"error":"La fecha del conteo tiene que venir como YYYY-MM-DDTHH:MI:SS"}';
          RETURN;
      END;
    END IF;

    LEER_PARA_MODIFICAR(l_id, l_empresa, l_estado, l_actual, l_existe);

    IF NOT l_existe THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El inventario no existe"}';
      RETURN;
    END IF;

    -- El trigger lo rechazaria igual; se chequea antes para responder 409 con
    -- un texto que dice que hacer, en vez de un ORA-20102 crudo como 500.
    IF l_estado != 'ABIERTO' THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"El conteo esta ' || l_estado ||
                     ' y ya no se modifica. Si el numero cambio, carga un conteo nuevo"}';
      RETURN;
    END IF;

    UPDATE INVENTARIOS
       SET CANTIDAD_FISICA  = l_cantidad,
           FECHA_INVENTARIO = NVL(l_fecha, FECHA_INVENTARIO),
           OBSERVACIONES    = NULLIF(TRIM(p_observaciones), '')
     WHERE ID_INVENTARIO = l_id
       AND ID_EMPRESA    = l_empresa;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      DECLARE
        l_codigo  PLS_INTEGER    := SQLCODE;
        l_mensaje VARCHAR2(4000) := SQLERRM;
      BEGIN
        IF ERROR_DE_NEGOCIO(l_codigo, l_mensaje, p_status_code, p_resultado) THEN
          NULL;
        ELSE
          p_status_code := 500;
          APEX_DEBUG.ERROR('PKG_INVENTARIOS.ACTUALIZAR: [' || l_codigo || '] ' || l_mensaje || ' | ' ||
                           DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
          p_resultado := '{"error":"Error al actualizar el inventario"}';
        END IF;
      END;
  END ACTUALIZAR;

  ------------------------------------------------------------------------------
  -- CERRAR
  --
  -- El UPDATE toca UNA sola columna. Todo lo demas —validar que haya cantidad,
  -- sellar CANTIDAD_SISTEMA con lo que EXISTENCIAS decia, y escribir la
  -- existencia nueva— lo hacen los triggers. Repetirlo aca daria dos versiones
  -- de la misma regla que se desincronizan a la primera correccion.
  ------------------------------------------------------------------------------
  PROCEDURE CERRAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_id       NUMBER;
    l_empresa  NUMBER;
    l_estado   VARCHAR2(20);
    l_cantidad NUMBER;
    l_existe   BOOLEAN;
    l_sistema  NUMBER;
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

    LEER_PARA_MODIFICAR(l_id, l_empresa, l_estado, l_cantidad, l_existe);

    IF NOT l_existe THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El inventario no existe"}';
      RETURN;
    END IF;

    IF l_estado != 'ABIERTO' THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"El conteo ya esta ' || l_estado || ' y no se puede volver a cerrar"}';
      RETURN;
    END IF;

    IF l_cantidad IS NULL THEN
      ROLLBACK;
      p_status_code := 400;
      p_resultado := '{"error":"No se puede cerrar sin la cantidad contada: es el numero que va a quedar como existencia"}';
      RETURN;
    END IF;

    UPDATE INVENTARIOS
       SET ESTADO = 'CERRADO'
     WHERE ID_INVENTARIO = l_id
       AND ID_EMPRESA    = l_empresa;

    -- Lo que el trigger sello, releido DESPUES del UPDATE. Es lo que decia el
    -- sistema antes del ajuste, y sirve para que la pantalla confirme cuanto se
    -- corrigio sin volver a pedir el listado entero.
    SELECT CANTIDAD_SISTEMA
      INTO l_sistema
      FROM INVENTARIOS
     WHERE ID_INVENTARIO = l_id;

    COMMIT;
    p_status_code := 200;
    SELECT JSON_OBJECT(
             'ok'              VALUE 'true' FORMAT JSON,
             'cantidadSistema' VALUE l_sistema,
             'cantidadFisica'  VALUE l_cantidad,
             'diferencia'      VALUE l_cantidad - NVL(l_sistema, 0)
             RETURNING CLOB
           )
      INTO p_resultado
      FROM DUAL;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      DECLARE
        l_codigo  PLS_INTEGER    := SQLCODE;
        l_mensaje VARCHAR2(4000) := SQLERRM;
      BEGIN
        IF ERROR_DE_NEGOCIO(l_codigo, l_mensaje, p_status_code, p_resultado) THEN
          NULL;
        ELSE
          p_status_code := 500;
          APEX_DEBUG.ERROR('PKG_INVENTARIOS.CERRAR: [' || l_codigo || '] ' || l_mensaje || ' | ' ||
                           DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
          p_resultado := '{"error":"Error al cerrar el inventario"}';
        END IF;
      END;
  END CERRAR;

  ------------------------------------------------------------------------------
  -- ANULAR
  ------------------------------------------------------------------------------
  PROCEDURE ANULAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_id       NUMBER;
    l_empresa  NUMBER;
    l_estado   VARCHAR2(20);
    l_cantidad NUMBER;
    l_existe   BOOLEAN;
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

    LEER_PARA_MODIFICAR(l_id, l_empresa, l_estado, l_cantidad, l_existe);

    IF NOT l_existe THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El inventario no existe"}';
      RETURN;
    END IF;

    IF l_estado != 'ABIERTO' THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"El conteo esta ' || l_estado || ' y ya no se puede anular"}';
      RETURN;
    END IF;

    -- ANULADO no dispara el trigger del ajuste (su WHEN pide CERRADO): la
    -- existencia queda como estaba, que es exactamente lo que significa
    -- descartar un conteo.
    UPDATE INVENTARIOS
       SET ESTADO = 'ANULADO'
     WHERE ID_INVENTARIO = l_id
       AND ID_EMPRESA    = l_empresa;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      DECLARE
        l_codigo  PLS_INTEGER    := SQLCODE;
        l_mensaje VARCHAR2(4000) := SQLERRM;
      BEGIN
        IF ERROR_DE_NEGOCIO(l_codigo, l_mensaje, p_status_code, p_resultado) THEN
          NULL;
        ELSE
          p_status_code := 500;
          APEX_DEBUG.ERROR('PKG_INVENTARIOS.ANULAR: [' || l_codigo || '] ' || l_mensaje || ' | ' ||
                           DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
          p_resultado := '{"error":"Error al anular el inventario"}';
        END IF;
      END;
  END ANULAR;

  ------------------------------------------------------------------------------
  -- ELIMINAR
  --
  -- EXISTE ADEMAS DE /anular, y no se pisan: eliminar es para el borrador que
  -- se cargo por error y todavia no significa nada; anular es para el conteo
  -- que se hizo y se decide no aplicar. El primero no deja rastro porque no
  -- habia nada que dejar; el segundo si, porque alguien fue al deposito.
  ------------------------------------------------------------------------------
  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion   NUMBER;
    l_id       NUMBER;
    l_empresa  NUMBER;
    l_estado   VARCHAR2(20);
    l_cantidad NUMBER;
    l_existe   BOOLEAN;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    l_id      := TO_NUMBER(NULLIF(p_id, ''));
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    -- Obligatorio: sin empresa el DELETE alcanzaria filas de cualquiera.
    IF l_id IS NULL OR l_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"id e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    LEER_PARA_MODIFICAR(l_id, l_empresa, l_estado, l_cantidad, l_existe);

    IF NOT l_existe THEN
      ROLLBACK;
      p_status_code := 404;
      p_resultado := '{"error":"El inventario no existe"}';
      RETURN;
    END IF;

    IF l_estado != 'ABIERTO' THEN
      ROLLBACK;
      p_status_code := 409;
      p_resultado := '{"error":"El conteo esta ' || l_estado ||
                     ' y no se puede eliminar: ya movio el stock o quedo como evidencia de lo que se conto. Anda a anularlo o carga un conteo nuevo"}';
      RETURN;
    END IF;

    DELETE FROM INVENTARIOS
     WHERE ID_INVENTARIO = l_id
       AND ID_EMPRESA    = l_empresa;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      DECLARE
        l_codigo  PLS_INTEGER    := SQLCODE;
        l_mensaje VARCHAR2(4000) := SQLERRM;
      BEGIN
        IF ERROR_DE_NEGOCIO(l_codigo, l_mensaje, p_status_code, p_resultado) THEN
          NULL;
        ELSIF l_codigo = -2292 THEN
          p_status_code := 409;
          p_resultado := '{"error":"No se puede eliminar: hay registros que dependen de este inventario"}';
        ELSE
          p_status_code := 500;
          APEX_DEBUG.ERROR('PKG_INVENTARIOS.ELIMINAR: [' || l_codigo || '] ' || l_mensaje || ' | ' ||
                           DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
          p_resultado := '{"error":"Error al eliminar el inventario"}';
        END IF;
      END;
  END ELIMINAR;

  ------------------------------------------------------------------------------
  -- Publica el modulo ORDS /inventarios/ con sus 7 endpoints.
  --
  -- Cada handler es una sola linea: invoca al procedimiento del paquete pasando
  -- los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- EL BODY DE UN POST/PUT NO SE LEE CON :body. `:body` es el payload CRUDO
  -- (BLOB) y sirve para subir archivos; para un JSON, ORDS crea un bind por
  -- cada clave de primer nivel —:idEmpresa, :cantidadFisica— que se vincula
  -- solo, sin DEFINE_PARAMETER. Del lado del cliente hay que mandar TODAS las
  -- claves aunque vayan en "": una clave omitida deja el bind sin definir.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no del workspace, y NO es un parametro de
  -- DEFINE_MODULE (falla con PLS-00306 si se le pasa ahi). Sin esto, toda
  -- peticion cross-origin la rechaza ORDS ANTES de llegar al handler, con un
  -- "Service Unavailable" que ningun WHEN OTHERS puede capturar.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'inventarios',
      p_base_path      => '/inventarios/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Carga de conteos fisicos: al cerrar ajustan EXISTENCIAS'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'inventarios',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /inventarios/listar?idEmpresa=&idSucursal=&idArticulo=&estado=
    --                        &busqueda=&pagina=&tamanio=
    --
    -- Los query params se vinculan solos al bind del mismo nombre; no se
    -- declaran con DEFINE_PARAMETER.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'inventarios', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'inventarios',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INVENTARIOS.LISTAR(:authorization, :idEmpresa, :idSucursal, :idArticulo, :estado, :busqueda, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- GET /inventarios/obtener/:id/:idEmpresa
    --
    -- Trae OBSERVACIONES entera. Es el que usa el formulario de edicion; la
    -- fila del listado viene recortada a 150 caracteres.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'inventarios', p_pattern => 'obtener/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'inventarios',
      p_pattern     => 'obtener/:id/:idEmpresa',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INVENTARIOS.OBTENER(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'obtener/:id/:idEmpresa', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /inventarios/crear
    -- Body: { idEmpresa, idSucursal, idArticulo, cantidadFisica,
    --         fechaInventario, observaciones }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'inventarios', p_pattern => 'crear');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'inventarios',
      p_pattern     => 'crear',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INVENTARIOS.INSERTAR(:authorization, :idEmpresa, :idSucursal, :idArticulo, :cantidadFisica, :fechaInventario, :observaciones, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'crear', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'crear', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'crear', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- PUT /inventarios/actualizar/:id
    -- Body: { idEmpresa, cantidadFisica, fechaInventario, observaciones }
    --
    -- LOS CUATRO SIEMPRE: aca un campo vacio BORRA, no conserva. Ver la nota
    -- del procedimiento ACTUALIZAR.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'inventarios', p_pattern => 'actualizar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'inventarios',
      p_pattern     => 'actualizar/:id',
      p_method      => 'PUT',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INVENTARIOS.ACTUALIZAR(:authorization, :id, :idEmpresa, :cantidadFisica, :fechaInventario, :observaciones, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'actualizar/:id', p_method => 'PUT',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /inventarios/cerrar/:id
    -- Body: { idEmpresa }
    --
    -- ENDPOINT PROPIO Y NO UN CAMPO DEL PUT: cerrar mueve el stock y no se
    -- deshace. Ver la maquina de estados en el encabezado del archivo.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'inventarios', p_pattern => 'cerrar/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'inventarios',
      p_pattern     => 'cerrar/:id',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INVENTARIOS.CERRAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'cerrar/:id', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'cerrar/:id', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'cerrar/:id', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /inventarios/anular/:id
    -- Body: { idEmpresa }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'inventarios', p_pattern => 'anular/:id');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'inventarios',
      p_pattern     => 'anular/:id',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INVENTARIOS.ANULAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'anular/:id', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'anular/:id', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'anular/:id', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /inventarios/eliminar/:id/:idEmpresa
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'inventarios', p_pattern => 'eliminar/:id/:idEmpresa');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'inventarios',
      p_pattern     => 'eliminar/:id/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_INVENTARIOS.ELIMINAR(:authorization, :id, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'inventarios', p_pattern => 'eliminar/:id/:idEmpresa', p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_INVENTARIOS;
/

--------------------------------------------------------------------------------
-- 2. Publicacion de los endpoints
--
-- Unica sentencia fuera del paquete: la llamada que publica el modulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_INVENTARIOS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificacion
--
-- MIRA ESTA SALIDA. Un paquete INVALID da un 500 mudo: el WHEN OTHERS no
-- captura errores de compilacion.
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_INVENTARIOS'
 ORDER BY OBJECT_TYPE;

-- Si algo salio INVALID arriba, aca esta el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_INVENTARIOS'
 ORDER BY LINE, POSITION;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'inventarios';

-- Los 7 endpoints.
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'inventarios'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- LOS TRIGGERS TIENEN QUE ESTAR: este paquete NO repite sus reglas. Sin ellos,
-- un conteo cerrado se puede volver a editar y cerrar NO ajusta la existencia.
-- Los dos, ENABLED y VALID. Si faltan, corre db/inventarios-triggers-ddl.sql.
SELECT TRIGGER_NAME, TRIGGER_TYPE, STATUS
  FROM USER_TRIGGERS
 WHERE TABLE_NAME = 'INVENTARIOS'
 ORDER BY TRIGGER_NAME;

--------------------------------------------------------------------------------
-- 4. Consultas utiles
--------------------------------------------------------------------------------

-- Los conteos abiertos: la planilla pendiente de aplicar.
--
-- SISTEMA_HOY sale de EXISTENCIAS en vivo, no de CANTIDAD_SISTEMA: esa columna
-- esta en NULL hasta el cierre, que es cuando se sella.
SELECT i.ID_INVENTARIO,
       s.NOMBRE_SUCURSAL,
       a.CODIGO_ARTICULO,
       a.NOMBRE_ARTICULO,
       NVL(e.CANTIDAD_DISPONIBLE, 0)                     AS SISTEMA_HOY,
       i.CANTIDAD_FISICA,
       i.CANTIDAD_FISICA - NVL(e.CANTIDAD_DISPONIBLE, 0) AS DIFERENCIA,
       u.NOMBRE_APELLIDO                                 AS CARGADO_POR,
       TO_CHAR(i.FECHA_INVENTARIO, 'YYYY-MM-DD HH24:MI') AS FECHA
  FROM INVENTARIOS i
  JOIN ARTICULOS   a ON a.ID_ARTICULO = i.ID_ARTICULO
  LEFT JOIN SUCURSALES  s ON s.ID_SUCURSAL = i.ID_SUCURSAL
  LEFT JOIN USUARIOS    u ON u.ID_USUARIO  = i.ID_USUARIO
  LEFT JOIN EXISTENCIAS e ON e.ID_EMPRESA  = i.ID_EMPRESA
                         AND e.ID_SUCURSAL = i.ID_SUCURSAL
                         AND e.ID_ARTICULO = i.ID_ARTICULO
 WHERE NVL(UPPER(TRIM(i.ESTADO)), 'ABIERTO') = 'ABIERTO'
 ORDER BY i.FECHA_INVENTARIO DESC;

-- Lo que corrigio cada cierre. DIFERENCIA es contra CANTIDAD_SISTEMA —lo que el
-- sistema decia al momento del ajuste—, no contra la existencia de hoy: esa ya
-- la piso el propio cierre y daria cero siempre.
SELECT i.ID_INVENTARIO,
       s.NOMBRE_SUCURSAL,
       a.NOMBRE_ARTICULO,
       i.CANTIDAD_SISTEMA,
       i.CANTIDAD_FISICA,
       i.CANTIDAD_FISICA - NVL(i.CANTIDAD_SISTEMA, 0) AS DIFERENCIA,
       u.NOMBRE_APELLIDO AS CARGADO_POR,
       TO_CHAR(i.FECHA_ACTUALIZACION, 'YYYY-MM-DD HH24:MI') AS CERRADO_EL
  FROM INVENTARIOS i
  JOIN ARTICULOS   a ON a.ID_ARTICULO = i.ID_ARTICULO
  LEFT JOIN SUCURSALES s ON s.ID_SUCURSAL = i.ID_SUCURSAL
  LEFT JOIN USUARIOS   u ON u.ID_USUARIO  = i.ID_USUARIO
 WHERE NVL(UPPER(TRIM(i.ESTADO)), 'ABIERTO') = 'CERRADO'
 ORDER BY i.FECHA_ACTUALIZACION DESC;

-- Mas de un conteo ABIERTO del mismo articulo y sucursal. INSERTAR lo impide de
-- ahora en mas; esto muestra lo que haya entrado antes o por fuera de la API.
-- Cero filas es lo correcto.
SELECT ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO, COUNT(*) AS ABIERTOS
  FROM INVENTARIOS
 WHERE NVL(UPPER(TRIM(ESTADO)), 'ABIERTO') = 'ABIERTO'
 GROUP BY ID_EMPRESA, ID_SUCURSAL, ID_ARTICULO
HAVING COUNT(*) > 1;

-- Conteos sin firma. ID_USUARIO es nullable en el DDL y el paquete siempre lo
-- escribe desde el token: una fila aca entro por fuera de la API.
SELECT ID_INVENTARIO, ID_SUCURSAL, ID_ARTICULO, ESTADO, FECHA_INVENTARIO
  FROM INVENTARIOS
 WHERE ID_USUARIO IS NULL
 ORDER BY FECHA_INVENTARIO DESC;
