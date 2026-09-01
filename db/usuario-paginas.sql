--------------------------------------------------------------------------------
-- CTELL · USUARIO_PAGINAS
--
-- Permisos: qué páginas puede ver cada usuario. Es una tabla puente, así que
-- el ABM no es el de siempre — no hay "actualizar" (un permiso existe o no) y
-- la fila se identifica por las dos claves juntas, no por un ID propio:
--
--   1. LISTAR   GET    /usuario-paginas/listar?idUsuario=
--   2. ASIGNAR  POST   /usuario-paginas/asignar  { idUsuario, idPagina, idEmpresa? }
--   3. QUITAR   DELETE /usuario-paginas/quitar/:idUsuario/:idPagina
--
-- Se ejecuta una sola vez en la hoja de trabajo SQL de APEX, conectado con el
-- esquema del workspace. REQUIERE db/auth.sql EJECUTADO ANTES (usa PKG_AUTH
-- para validar el token).
--
-- Base de los endpoints: https://oracleapex.com/ords/ctell/usuario-paginas/
--
-- Tabla (no la crea ni la altera; el DDL se administra aparte):
--   USUARIO_PAGINAS  ID_USUARIO, ID_PAGINA, FECHA_ALTA, ID_EMPRESA
--   PK compuesta USUARIO_PAGINAS_PK (ID_EMPRESA, ID_USUARIO, ID_PAGINA): el
--   mismo permiso no se puede duplicar dentro de una empresa — el segundo
--   INSERT da ORA-00001, que se traduce a 409.
--   FK: USUARIO_PAGINAS_FK_USUARIOS, _FK_PAGINAS, _FK_EMPRESAS.
--   Indice IDX_UP_PAGINA sobre ID_PAGINA.
--
-- LOS PERMISOS SON POR EMPRESA. La empresa integra la PK, asi que un usuario
-- puede tener accesos DISTINTOS segun con que empresa entre: vendedor en la
-- empresa A y solo consulta en la B. El menu muestra unicamente las paginas
-- cuyo permiso corresponde a la empresa de la sesion (ver
-- src/hooks/use-menu-usuario.ts). Sin permisos en esa empresa, el menu queda
-- vacio, y eso es lo esperado.
--
-- LAS TRES CLAVES VIAJAN EN TODAS LAS OPERACIONES. Es la consecuencia directa
-- de la PK y el error mas facil de cometer aca: QUITAR filtrando solo por
-- (ID_USUARIO, ID_PAGINA) borraria el permiso en TODAS las empresas, no solo en
-- la que se esta editando. Por eso ELIMINAR recibe tambien el idEmpresa.
--
-- ID_EMPRESA FIGURA COMO NULLABLE en el DDL aunque integre la PK, y no hace
-- falta corregirlo: Oracle no permite un NULL en una columna de la clave
-- primaria, asi que USUARIO_PAGINAS_PK ya la fuerza a NOT NULL. La declaracion
-- de la columna miente; la restriccion manda.
--
-- LAS TRES FK EXISTEN: contra USUARIOS, contra PAGINAS y contra EMPRESAS. Un id
-- inexistente en cualquiera de las tres da ORA-02291, que ASIGNAR traduce a un
-- 400 nombrando CUAL de las tres fallo —el texto del error trae el nombre de la
-- constraint— en vez de a un 500 mudo.
--
-- ASIGNAR IGUAL VERIFICA A MANO QUE LA PAGINA EXISTA, aunque ahora la FK lo
-- cubra. No es redundante: el chequeo previo devuelve "La pagina indicada no
-- existe" antes de intentar el INSERT, y la FK queda como la red que no se puede
-- esquivar. Es el mismo criterio de todo el proyecto — el paquete valida para
-- que se entienda, la base para que no pase.
--
-- EL INDICE IDX_UP_PAGINA NO ES DECORATIVO. La PK indexa por
-- (ID_EMPRESA, ID_USUARIO, ID_PAGINA) y ID_PAGINA es la ULTIMA columna, asi que
-- no sirve para buscar por pagina sola. Sin ese indice, cada borrado de pagina
-- —que cuenta cuantos usuarios la tienen, ver PKG_PAGINAS.ELIMINAR— y cada
-- verificacion de la FK recorrerian la tabla entera.
--
-- El listado hace JOIN con PAGINAS y MODULOS para devolver los nombres: el
-- frontend necesita mostrar "Compras › Órdenes", no dos números sueltos.
--
-- CORS: ORIGINS_ALLOWED es POR MODULO ORDS, no a nivel de workspace. Se
-- declara en PUBLICAR_ENDPOINTS. Ver la explicación completa en db/auth.sql.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. PKG_USUARIO_PAGINAS
--
-- Probar un procedimiento solo, sin pasar por ORDS:
--   DECLARE
--     l_status NUMBER;
--     l_result CLOB;
--   BEGIN
--     PKG_USUARIO_PAGINAS.LISTAR('Bearer TU_TOKEN', '21', l_status, l_result);
--     DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
--     DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
--   END;
--   /
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_USUARIO_PAGINAS AS

  -- p_id_usuario filtra los permisos de un usuario. NULL o vacío = todos.
  --
  -- PAGINADO, Y NO ES OPCIONAL: cada fila trae el nombre de la página, el del
  -- módulo, la ruta y el ícono —unos 200 bytes—, y ORDS devuelve el JSON por un
  -- bind tipado STRING con techo de 4000. Sin paginar, a partir de ~20 permisos
  -- la respuesta se corta y sale un 500 que ni el WHEN OTHERS registra, porque
  -- el PL/SQL ya termino bien.
  --
  -- El cliente junta las paginas: tanto el menu como el ABM necesitan la lista
  -- completa. Ver api.usuarioPaginas.listar.
  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Da permiso a un usuario sobre una página. Si ya lo tenía, 409 — incluso
  -- con otra empresa: ID_EMPRESA no integra la PK.
  --
  -- p_id_empresa define en qué empresa vale el permiso. Es técnicamente
  -- opcional (la columna es nullable), pero un permiso sin empresa no aparece
  -- en ningún menú. Ver la explicación completa en el encabezado del archivo.
  PROCEDURE ASIGNAR (
    p_authorization IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_id_pagina     IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Le saca el permiso EN UNA EMPRESA. Hacen falta las TRES claves: la PK es
  -- (ID_EMPRESA, ID_USUARIO, ID_PAGINA), y omitir la empresa borraria el acceso
  -- en todas a la vez.
  PROCEDURE QUITAR (
    p_authorization IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_id_pagina     IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el módulo ORDS /usuario-paginas/ con sus 3 endpoints.
  -- Se llama una sola vez, al final de este archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_USUARIO_PAGINAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_USUARIO_PAGINAS AS

  -- 15 por pagina, y 15 de techo.
  --
  -- El numero sale de una cuenta, no de una costumbre: una fila de este listado
  -- pesa unos 190 bytes con nombres normales de pagina y modulo, y el bind
  -- STRING de ORDS corta a los 4000. 15 x 190 = 2850, con margen para un modulo
  -- de nombre largo. Subirlo a 25 vuelve a poner el 500 a un nombre de
  -- distancia.
  --
  -- VAN ACA ARRIBA, ANTES DE TODO PROCEDIMIENTO: en el cuerpo de un paquete las
  -- declaraciones tienen que preceder a la primera definicion. Puestas mas
  -- abajo —entre dos procedimientos, que es donde parecen quedar mejor— el
  -- compilador corta con PLS-00103 sobre el nombre de la constante, y arrastra
  -- un segundo error de sintaxis inventado decenas de lineas despues.
  C_TAMANIO_DEFECTO CONSTANT PLS_INTEGER := 15;
  C_TAMANIO_MAXIMO  CONSTANT PLS_INTEGER := 15;

  ------------------------------------------------------------------------------
  -- Privado: borra el módulo ORDS si existe, reintentando ante un interbloqueo.
  --
  -- Nunca usar `WHEN OTHERS THEN NULL` acá: se tragaría también un ORA-00060,
  -- el DELETE fallaría en silencio, y el DEFINE_MODULE de después moriría con
  -- ORA-00001 (nombre duplicado) contra el módulo que nunca se llegó a borrar.
  ------------------------------------------------------------------------------
  PROCEDURE BORRAR_MODULO IS
    C_INTENTOS CONSTANT PLS_INTEGER := 3;
    l_existe   PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. C_INTENTOS LOOP
      BEGIN
        -- Se consulta en vez de capturar el error de "no existe": así el
        -- EXCEPTION queda libre para los fallos que sí importan.
        SELECT COUNT(*)
          INTO l_existe
          FROM USER_ORDS_MODULES
         WHERE NAME = 'usuario-paginas';

        IF l_existe = 0 THEN
          RETURN;  -- No existía: nada que borrar.
        END IF;

        ORDS.DELETE_MODULE(p_module_name => 'usuario-paginas');
        COMMIT;  -- Libera los locks antes de que DEFINE_MODULE los vuelva a pedir.
        RETURN;

      EXCEPTION
        WHEN OTHERS THEN
          -- ORA-00060 (interbloqueo) y ORA-04020 (lock de objeto) son
          -- transitorios: la otra sesión termina y el reintento pasa.
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
    p_id_usuario    IN  VARCHAR2,
    p_pagina        IN  VARCHAR2,
    p_tamanio       IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_usuario NUMBER;
    l_pagina     PLS_INTEGER;
    l_tamanio    PLS_INTEGER;
    l_desplaza   PLS_INTEGER;
    l_total      NUMBER;
    l_items      CLOB;
  BEGIN
    l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 401;
      p_resultado := '{"error":"Sesion invalida o vencida"}';
      RETURN;
    END IF;

    -- La conversión va acá, dentro del BEGIN: en el DECLARE se ejecutaría
    -- antes de que exista el EXCEPTION y el error escaparía del procedimiento.
    -- NULLIF convierte la cadena vacía del parámetro ausente en NULL antes de
    -- que TO_NUMBER la toque (si no, ORA-01722).
    l_id_usuario := TO_NUMBER(NULLIF(p_id_usuario, ''));

    -- ESTE LISTAR TIENE DOS USOS Y SOLO UNO ES ADMINISTRATIVO:
    --
    --   1. El MENU de cada usuario, que pide SUS PROPIOS permisos
    --      (?idUsuario=<el suyo>). Lo usa toda la app en cada carga, asi que
    --      exigir admin lo dejaria sin menu a todo el mundo.
    --   2. El ABM de Permisos, que consulta los de OTRO usuario.
    --
    -- La regla que cubre los dos: cada uno puede ver los suyos, y solo un
    -- administrador puede ver los de otro. Sin este control, cualquiera podia
    -- mapear los accesos de cualquier cuenta pasando otro id.
    --
    -- El filtro vacio (todos los usuarios) tambien es administrativo: devuelve
    -- el mapa de permisos completo del sistema.
    IF (l_id_usuario IS NULL OR l_id_usuario != l_sesion)
       AND NOT PKG_AUTH.ES_ADMINISTRADOR(l_sesion) THEN
      p_status_code := 403;
      p_resultado := '{"error":"Solo un administrador puede ver los permisos de otro usuario"}';
      RETURN;
    END IF;

    l_pagina   := GREATEST(NVL(TO_NUMBER(NULLIF(p_pagina, '')), 1), 1);
    l_tamanio  := LEAST(NVL(TO_NUMBER(NULLIF(p_tamanio, '')), C_TAMANIO_DEFECTO),
                        C_TAMANIO_MAXIMO);
    l_desplaza := (l_pagina - 1) * l_tamanio;

    -- EL COUNT REPITE EL MISMO FILTRO que la consulta de abajo: si cuentan
    -- distinto, el cliente pide paginas que no existen o se detiene antes de
    -- traerlas todas.
    SELECT COUNT(*)
      INTO l_total
      FROM USUARIO_PAGINAS up
      JOIN USUARIOS u ON u.ID_USUARIO = up.ID_USUARIO
      JOIN PAGINAS  p ON p.ID_PAGINA  = up.ID_PAGINA
      JOIN MODULOS  m ON m.ID_MODULO  = p.ID_MODULO
     WHERE l_id_usuario IS NULL OR up.ID_USUARIO = l_id_usuario;

    -- Los JOIN traen los nombres: el frontend muestra "Compras › Órdenes", no
    -- dos números sueltos. Van como INNER JOIN a propósito — una fila que
    -- apunte a una página inexistente no debería aparecer como si fuera un
    -- permiso válido. Por eso el COUNT de arriba los repite: contando sobre la
    -- tabla sola, una fila huérfana inflaba el total y el cliente pedía una
    -- página que nunca llegaba.
    --
    -- RUTA y ENTRADA salen de PAGINAS porque el menú dinámico las necesita:
    -- sin RUTA el item no sabe adónde navegar, y sin ENTRADA no puede
    -- agruparse bajo Definiciones / Operaciones / Reportes.
    --
    -- SIN 'usuario' NI 'fechaAlta', que estaban y nadie leía: el nombre del
    -- usuario se repetía en CADA fila —el cliente ya tiene la lista de
    -- usuarios— y la fecha de alta no se muestra en ninguna pantalla. Juntos
    -- eran unos 60 bytes por fila contra un techo de 4000.
    --
    -- El JSON_OBJECT se arma en una subconsulta y el JSON_ARRAYAGG agrega esa
    -- columna, que ya viene tipada como CLOB. Anidado, el resultado intermedio
    -- del agregado se materializa como VARCHAR2 y revienta a los 4000 bytes.
    SELECT JSON_ARRAYAGG(fila ORDER BY orden_usuario, orden_modulo, orden_pagina
                         RETURNING CLOB)
      INTO l_items
      FROM (
        SELECT JSON_OBJECT(
                 'idUsuario'  VALUE up.ID_USUARIO,
                 'idPagina'   VALUE up.ID_PAGINA,
                 'pagina'     VALUE p.NOMBRE,
                 'ruta'       VALUE p.RUTA,
                 -- UPPER(TRIM(...)): el frontend agrupa el menu con esta letra
                 -- como clave de un objeto ('D'/'O'/'R'). Una 'o' minuscula o
                 -- con un espacio no matchea, y el grupo entero —"Operaciones"—
                 -- no se dibuja aunque el permiso exista. Mismo criterio que
                 -- ACTIVO.
                 'entrada'    VALUE UPPER(TRIM(p.ENTRADA)),
                 'orden'      VALUE p.ORDEN,
                 'idModulo'   VALUE m.ID_MODULO,
                 'modulo'     VALUE m.NOMBRE,
                 'moduloIcono' VALUE m.ICONO,
                 -- Empresa en la que vale el permiso. El frontend filtra por
                 -- esto: solo muestra en el menú las páginas cuya empresa
                 -- coincide con la de la sesión. Null = no aparece en ninguna.
                 'idEmpresa'  VALUE up.ID_EMPRESA
                 RETURNING CLOB
               ) AS fila,
               u.USUARIO AS orden_usuario,
               m.ORDEN   AS orden_modulo,
               p.ORDEN   AS orden_pagina
          FROM USUARIO_PAGINAS up
          JOIN USUARIOS u ON u.ID_USUARIO = up.ID_USUARIO
          JOIN PAGINAS  p ON p.ID_PAGINA  = up.ID_PAGINA
          JOIN MODULOS  m ON m.ID_MODULO  = p.ID_MODULO
         WHERE l_id_usuario IS NULL OR up.ID_USUARIO = l_id_usuario
         -- EL ORDER BY VA ACA ADEMAS DE EN EL AGREGADO: es el que decide QUE
         -- filas entran en la pagina. Sin el, OFFSET/FETCH recorta en un orden
         -- que Oracle no garantiza y la misma fila puede venir en dos paginas
         -- —o no venir en ninguna, que en un menu significa una entrada que
         -- desaparece sin motivo—.
         ORDER BY u.USUARIO, m.ORDEN, m.NOMBRE, p.ORDEN, p.NOMBRE
         OFFSET l_desplaza ROWS FETCH NEXT l_tamanio ROWS ONLY
      );

    p_status_code := 200;
    -- JSON_OBJECT(... RETURNING CLOB) como asignación PL/SQL directa (sin
    -- SELECT) falla con PLS-00684 dentro de un package body.
    --
    -- JSON_ARRAYAGG devuelve NULL cuando no hay filas, no un array vacio: sin
    -- el NVL el frontend recibiria "items":null y reventaria al iterarlo.
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
      APEX_DEBUG.ERROR('PKG_USUARIO_PAGINAS.LISTAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al listar los permisos"}';
  END LISTAR;

  PROCEDURE ASIGNAR (
    p_authorization IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_id_pagina     IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_usuario NUMBER;
    l_id_pagina  NUMBER;
    l_id_empresa NUMBER;
    l_existe     PLS_INTEGER;
  BEGIN
    -- SOLO ADMINISTRADORES: otorgar accesos es la operacion mas sensible del
    -- sistema. Sin este control, cualquier usuario con sesion podia asignarse a
    -- si mismo cualquier pagina —incluida Administracion— y escalar privilegios
    -- con una sola peticion.
    l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 403;
      p_resultado := '{"error":"Se requieren permisos de administrador"}';
      RETURN;
    END IF;

    l_id_usuario := TO_NUMBER(NULLIF(p_id_usuario, ''));
    l_id_pagina  := TO_NUMBER(NULLIF(p_id_pagina, ''));
    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    -- LAS TRES SON OBLIGATORIAS: la empresa integra la PK, asi que un NULL ni
    -- siquiera puede insertarse. Se valida aca para responder un 400 con un
    -- mensaje claro en vez del ORA-01400 crudo que devolveria el INSERT.
    IF l_id_usuario IS NULL OR l_id_pagina IS NULL OR l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idUsuario, idPagina e idEmpresa son obligatorios"}';
      RETURN;
    END IF;

    -- LA PAGINA TIENE QUE EXISTIR. La FK (USUARIO_PAGINAS_FK_PAGINAS) ya lo
    -- garantiza, pero este chequeo va igual: da un 400 que dice QUE falta, en
    -- vez del ORA-02291 generico que habria que desarmar mirando el nombre de la
    -- constraint. La FK queda de red — entre este SELECT y el INSERT alguien
    -- puede borrar la pagina.
    SELECT COUNT(*)
      INTO l_existe
      FROM PAGINAS
     WHERE ID_PAGINA = l_id_pagina;

    IF l_existe = 0 THEN
      p_status_code := 400;
      p_resultado := '{"error":"La pagina indicada no existe"}';
      RETURN;
    END IF;

    INSERT INTO USUARIO_PAGINAS (ID_USUARIO, ID_PAGINA, FECHA_ALTA, ID_EMPRESA)
    VALUES (l_id_usuario, l_id_pagina, SYSTIMESTAMP, l_id_empresa);

    COMMIT;
    p_status_code := 201;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      -- La PK compuesta lo rechaza: el usuario ya tenía ese permiso EN ESA
      -- EMPRESA. Es 409 y no 400 — el dato no es inválido, el estado del
      -- servidor lo rechaza.
      p_status_code := 409;
      p_resultado := '{"error":"El usuario ya tiene acceso a esa pagina en esta empresa"}';
    WHEN OTHERS THEN
      ROLLBACK;
      -- ORA-02291: alguna FK no encontró el padre. Son TRES (USUARIOS, PAGINAS y
      -- EMPRESAS), así que el mensaje mira el nombre de la constraint dentro del
      -- texto del error para nombrar la correcta: decir "el usuario no existe"
      -- cuando lo que falla es la empresa manda a revisar el dato equivocado.
      IF SQLCODE = -2291 THEN
        p_status_code := 400;
        IF INSTR(UPPER(SQLERRM), 'FK_EMPRESAS') > 0 THEN
          p_resultado := '{"error":"La empresa indicada no existe"}';
        ELSIF INSTR(UPPER(SQLERRM), 'FK_PAGINAS') > 0 THEN
          -- Llega acá sólo si la página se borró entre el chequeo de arriba y
          -- este INSERT: el mensaje lo dice tal cual, porque "no existe" a secas
          -- contradiría lo que la pantalla acaba de mostrar.
          p_resultado := '{"error":"La pagina se borro mientras se asignaba el permiso"}';
        ELSE
          p_resultado := '{"error":"El usuario indicado no existe"}';
        END IF;
      ELSE
        p_status_code := 500;
        APEX_DEBUG.ERROR('PKG_USUARIO_PAGINAS.ASIGNAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                         DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        p_resultado := '{"error":"Error al asignar el permiso"}';
      END IF;
  END ASIGNAR;

  PROCEDURE QUITAR (
    p_authorization IN  VARCHAR2,
    p_id_usuario    IN  VARCHAR2,
    p_id_pagina     IN  VARCHAR2,
    p_id_empresa    IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  ) IS
    l_sesion     NUMBER;
    l_id_empresa NUMBER;
  BEGIN
    -- SOLO ADMINISTRADORES, igual que ASIGNAR: quitarle el acceso a alguien es
    -- tan sensible como darselo.
    l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
    IF l_sesion IS NULL THEN
      p_status_code := 403;
      p_resultado := '{"error":"Se requieren permisos de administrador"}';
      RETURN;
    END IF;

    l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

    -- La empresa es OBLIGATORIA y se exige explicitamente: sin ella el DELETE
    -- de abajo borraria la fila de todas las empresas. Es preferible un 400 a
    -- quitarle a alguien accesos que nadie pidio revocar.
    IF l_id_empresa IS NULL THEN
      p_status_code := 400;
      p_resultado := '{"error":"idEmpresa es obligatorio para quitar un permiso"}';
      RETURN;
    END IF;

    -- Las TRES claves de la PK. Filtrar solo por usuario y pagina borraria el
    -- permiso en todas las empresas, no solo en la que se esta editando.
    DELETE FROM USUARIO_PAGINAS
     WHERE ID_USUARIO = TO_NUMBER(NULLIF(p_id_usuario, ''))
       AND ID_PAGINA  = TO_NUMBER(NULLIF(p_id_pagina, ''))
       AND ID_EMPRESA = l_id_empresa;

    -- Sin esto, quitar un permiso inexistente devuelve 200 y quien lo usó cree
    -- que hizo algo.
    IF SQL%ROWCOUNT = 0 THEN
      p_status_code := 404;
      p_resultado := '{"error":"El usuario no tenia acceso a esa pagina en esta empresa"}';
      RETURN;
    END IF;

    COMMIT;
    p_status_code := 200;
    p_resultado := '{"ok":true}';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status_code := 500;
      APEX_DEBUG.ERROR('PKG_USUARIO_PAGINAS.QUITAR: [' || SQLCODE || '] ' || SQLERRM || ' | ' ||
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      p_resultado := '{"error":"Error al quitar el permiso"}';
  END QUITAR;

  ------------------------------------------------------------------------------
  -- Publica el módulo ORDS /usuario-paginas/ con sus 3 endpoints.
  --
  -- Cada handler es una sola línea: invoca al procedimiento del paquete
  -- pasando los binds de ORDS como argumentos. Nada de PL/SQL embebido.
  --
  -- ORIGINS_ALLOWED es POR MODULO, no a nivel de workspace, y NO es un
  -- parámetro de DEFINE_MODULE (falla con PLS-00306 si se le pasa ahí). Sin
  -- esto, toda petición cross-origin a /usuario-paginas/* la rechaza ORDS
  -- antes de llegar a los handlers. Ver la explicación en db/auth.sql.
  ------------------------------------------------------------------------------
  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'usuario-paginas',
      p_base_path      => '/usuario-paginas/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'Permisos de usuarios sobre paginas'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'usuario-paginas',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ----------------------------------------------------------------------------
    -- GET /usuario-paginas/listar
    -- Query param opcional: ?idUsuario=  (sin él, devuelve todos los permisos)
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'usuario-paginas', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'usuario-paginas',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_USUARIO_PAGINAS.LISTAR(:authorization, :idUsuario, :pagina, :tamanio, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'listar', p_method => 'GET',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- POST /usuario-paginas/asignar
    -- Body: { idUsuario, idPagina }
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(p_module_name => 'usuario-paginas', p_pattern => 'asignar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'usuario-paginas',
      p_pattern     => 'asignar',
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_USUARIO_PAGINAS.ASIGNAR(:authorization, :idUsuario, :idPagina, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'asignar', p_method => 'POST',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'asignar', p_method => 'POST',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'asignar', p_method => 'POST',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    ----------------------------------------------------------------------------
    -- DELETE /usuario-paginas/quitar/:idUsuario/:idPagina/:idEmpresa
    --
    -- Las TRES claves van en la URL porque la PK es (ID_EMPRESA, ID_USUARIO,
    -- ID_PAGINA): sin la empresa, el DELETE borraria el permiso en todas.
    ----------------------------------------------------------------------------
    ORDS.DEFINE_TEMPLATE(
      p_module_name => 'usuario-paginas',
      p_pattern     => 'quitar/:idUsuario/:idPagina/:idEmpresa'
    );

    ORDS.DEFINE_HANDLER(
      p_module_name => 'usuario-paginas',
      p_pattern     => 'quitar/:idUsuario/:idPagina/:idEmpresa',
      p_method      => 'DELETE',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_USUARIO_PAGINAS.QUITAR(:authorization, :idUsuario, :idPagina, :idEmpresa, :status_code, :resultado); END;'
    );

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'quitar/:idUsuario/:idPagina/:idEmpresa',
      p_method => 'DELETE',
      p_name => 'authorization', p_bind_variable_name => 'authorization',
      p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'quitar/:idUsuario/:idPagina/:idEmpresa',
      p_method => 'DELETE',
      p_name => 'resultado', p_bind_variable_name => 'resultado',
      p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');

    ORDS.DEFINE_PARAMETER(
      p_module_name => 'usuario-paginas', p_pattern => 'quitar/:idUsuario/:idPagina/:idEmpresa',
      p_method => 'DELETE',
      p_name => 'X-APEX-STATUS-CODE', p_bind_variable_name => 'status_code',
      p_source_type => 'HEADER', p_param_type => 'INT', p_access_method => 'OUT');

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_USUARIO_PAGINAS;
/

--------------------------------------------------------------------------------
-- 2. Publicación de los endpoints
--
-- Única sentencia fuera del paquete: la llamada que publica el módulo ORDS.
--------------------------------------------------------------------------------

BEGIN
  PKG_USUARIO_PAGINAS.PUBLICAR_ENDPOINTS;
END;
/

--------------------------------------------------------------------------------
-- 3. Verificación
--------------------------------------------------------------------------------

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_USUARIO_PAGINAS'
 ORDER BY OBJECT_TYPE;

-- LA ESTRUCTURA QUE EL PAQUETE DA POR SENTADA. Tienen que aparecer la PK y las
-- TRES FK: sin USUARIO_PAGINAS_FK_PAGINAS, el borrado de una pagina asignada
-- solo lo frena el chequeo de PKG_PAGINAS.ELIMINAR y una carrera lo esquiva.
SELECT CONSTRAINT_NAME, CONSTRAINT_TYPE, R_CONSTRAINT_NAME, STATUS
  FROM USER_CONSTRAINTS
 WHERE TABLE_NAME = 'USUARIO_PAGINAS'
   AND CONSTRAINT_TYPE IN ('P', 'R')
 ORDER BY CONSTRAINT_TYPE, CONSTRAINT_NAME;

-- Y el indice por pagina. ID_PAGINA es la ULTIMA columna de la PK, asi que sin
-- IDX_UP_PAGINA toda busqueda por pagina —el conteo de PKG_PAGINAS.ELIMINAR, la
-- validacion de la FK— recorre la tabla entera.
SELECT INDEX_NAME, COLUMN_NAME, COLUMN_POSITION
  FROM USER_IND_COLUMNS
 WHERE TABLE_NAME = 'USUARIO_PAGINAS'
 ORDER BY INDEX_NAME, COLUMN_POSITION;

-- Si algo salió INVALID arriba, acá está el motivo.
SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_USUARIO_PAGINAS'
 ORDER BY SEQUENCE;

SELECT NAME, STATUS, ORIGINS_ALLOWED
  FROM USER_ORDS_MODULES
 WHERE NAME = 'usuario-paginas';

SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'usuario-paginas'
 ORDER BY t.URI_TEMPLATE, h.METHOD;

-- El mapa completo: quien tiene que, y en que empresa. JOIN interno contra
-- EMPRESAS porque ID_EMPRESA integra la PK y ya no puede ser NULL.
SELECT e.NOMBRE_EMPRESA, u.USUARIO, m.NOMBRE AS MODULO, p.NOMBRE AS PAGINA,
       up.FECHA_ALTA
  FROM USUARIO_PAGINAS up
  JOIN USUARIOS u ON u.ID_USUARIO = up.ID_USUARIO
  JOIN PAGINAS  p ON p.ID_PAGINA  = up.ID_PAGINA
  JOIN MODULOS  m ON m.ID_MODULO  = p.ID_MODULO
  JOIN EMPRESAS e ON e.ID_EMPRESA = up.ID_EMPRESA
 ORDER BY e.NOMBRE_EMPRESA, u.USUARIO, m.ORDEN, p.ORDEN;

-- Cuantas paginas tiene cada usuario en cada empresa. Es la vista que responde
-- "por que fulano no ve el menu cuando entra con esta empresa": si no aparece
-- para esa combinacion, no tiene ningun permiso ahi.
SELECT e.NOMBRE_EMPRESA, u.USUARIO, COUNT(*) AS PAGINAS
  FROM USUARIO_PAGINAS up
  JOIN USUARIOS u ON u.ID_USUARIO = up.ID_USUARIO
  JOIN EMPRESAS e ON e.ID_EMPRESA = up.ID_EMPRESA
 GROUP BY e.NOMBRE_EMPRESA, u.USUARIO
 ORDER BY e.NOMBRE_EMPRESA, u.USUARIO;

-- Usuarios ACTIVOS sin ningun permiso en ninguna empresa: entran al sistema y
-- se encuentran con el menu vacio.
SELECT u.ID_USUARIO, u.USUARIO, u.NOMBRE_APELLIDO
  FROM USUARIOS u
 WHERE UPPER(TRIM(u.ACTIVO)) = 'A'
   AND NOT EXISTS (SELECT 1 FROM USUARIO_PAGINAS up WHERE up.ID_USUARIO = u.ID_USUARIO)
 ORDER BY u.USUARIO;

-- Copiar TODOS los permisos de un usuario a otro dentro de la misma empresa
-- (lo mismo que hace el boton "Copiar permisos" del ABM). El MERGE evita el
-- ORA-00001 si el destino ya tiene alguna de las paginas.
--
--   MERGE INTO USUARIO_PAGINAS d
--   USING (SELECT <ID_EMPRESA> AS ID_EMPRESA, <ID_DESTINO> AS ID_USUARIO, ID_PAGINA
--            FROM USUARIO_PAGINAS
--           WHERE ID_USUARIO = <ID_ORIGEN> AND ID_EMPRESA = <ID_EMPRESA>) o
--      ON (d.ID_EMPRESA = o.ID_EMPRESA AND d.ID_USUARIO = o.ID_USUARIO
--          AND d.ID_PAGINA = o.ID_PAGINA)
--   WHEN NOT MATCHED THEN
--     INSERT (ID_EMPRESA, ID_USUARIO, ID_PAGINA, FECHA_ALTA)
--     VALUES (o.ID_EMPRESA, o.ID_USUARIO, o.ID_PAGINA, SYSTIMESTAMP);
--   COMMIT;
