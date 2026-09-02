# Guía de implementación — Backend

Cómo agregar tablas y endpoints siguiendo los patrones de este proyecto. Está
escrita sobre el código que ya existe: los ejemplos salen de
[db/auth.sql](../db/auth.sql) y [db/modulos.sql](../db/modulos.sql), que sirven
de plantilla para todo lo demás.

> **Para el frontend hay guía aparte:** [GUIA-FRONTEND.md](GUIA-FRONTEND.md) —
> páginas, formularios, tablas responsive y el menú dinámico.

## Índice

1. [Arquitectura](#1-arquitectura)
2. [Regla: un archivo SQL por tabla](#2-regla-un-archivo-sql-por-tabla)
   - [El estado es `'A'`/`'I'`, nunca 1/0](#21-el-estado-es-ai-nunca-10)
3. [Crear el backend de una tabla](#3-crear-el-backend-de-una-tabla)
   - [Tablas por empresa](#31-tablas-por-empresa)
   - [Tablas por empresa Y sucursal](#311-tablas-por-empresa-y-sucursal)
   - [Imágenes y otros binarios](#32-imágenes-y-otros-binarios)
   - [Cabecera y detalle: una transacción](#33-cabecera-y-detalle-una-transacción)
   - [Columnas calculadas: lo que no se guarda](#34-columnas-calculadas-lo-que-no-se-guarda)
   - [Máquinas de estado y triggers](#35-máquinas-de-estado-y-triggers)
   - [Agregar una columna a una tabla que ya existe](#352-agregar-una-columna-a-una-tabla-que-ya-existe)
   - [Agregar un parámetro a un `LISTAR` que ya usan varias pantallas](#353-agregar-un-parámetro-a-un-listar-que-ya-usan-varias-pantallas)
   - [Transacciones que mueven stock o plata](#36-transacciones-que-mueven-stock-o-plata)
   - [Trampas de PL/SQL que se repiten](#37-trampas-de-plsql-que-se-repiten)
   - [Un `UNIQUE` sobre texto necesita el texto normalizado](#38-un-unique-sobre-texto-necesita-el-texto-normalizado)
4. [Consumir la API desde el frontend](#4-consumir-la-api-desde-el-frontend)
5. [Devolver lo que el consumidor necesita](#5-devolver-lo-que-el-consumidor-necesita)
6. [Seguridad](#6-seguridad)
   - [Enviar correo desde un handler](#61-enviar-correo-desde-un-handler)
7. [Checklist](#7-checklist)

---

## 1. Arquitectura

El proyecto son **dos piezas separadas** que se hablan por HTTP:

| Capa     | Dónde vive             | Qué hace                              |
| -------- | ---------------------- | ------------------------------------- |
| Backend  | Oracle APEX + ORDS     | Paquetes PL/SQL expuestos como REST   |
| Frontend | React + TanStack Start | Consume la API, corre en GitHub Pages |

Base de la API: `https://oracleapex.com/ords/ctell/`

Esto importa: **no se usan server functions de TanStack** (`createServerFn`) ni
se conecta a la base desde ningún servidor intermedio. Toda la lógica de datos
vive en paquetes PL/SQL, y el frontend sólo hace `fetch` contra ORDS —
directo en producción, gracias a CORS habilitado en APEX (ver
[6. Seguridad](#6-seguridad)).

Tres cosas más a tener presentes:

**El ruteo del frontend es por archivo.** Un archivo en `src/routes/` define una
URL. `src/routeTree.gen.ts` se genera solo y **nunca se edita a mano**.

**No hay SSR.** `nitro: false` en [vite.config.ts](../vite.config.ts) fuerza el
build a SPA: GitHub Pages sólo sirve estáticos y no puede correr un servidor.
Aun así, evitá acceder a `window`, `document` o `sessionStorage` fuera de
`useEffect` — el primer render sigue pasando por un paso de prerender en build
time (ver `[prerender]` en la salida de `npm run build`), donde tampoco existen.

**Las rutas protegidas van bajo `_auth.tsx`.** Es un layout de TanStack Router
([src/routes/_auth.tsx](../src/routes/_auth.tsx)) que exige token antes de
renderizar sus hijos; una página nueva que requiera sesión se nombra
`_auth.<algo>.tsx`, no `<algo>.tsx` suelto.

**El token de sesión vive en `sessionStorage`.** Lo maneja
[src/lib/api.ts](../src/lib/api.ts); no lo leas por tu cuenta.

---

## 2. Regla: un archivo SQL por tabla

> **Cada tabla tiene su propio archivo en `db/`, con todo su CRUD adentro.**
>
> Y su corolario del lado del frontend: **cada `db/<tabla>.sql` termina en una
> página `src/routes/_auth.<tabla>.tsx` con su entrada de menú** — también las
> tablas de detalle y las de cruce. Ver
> [Regla: cada tabla del backend lleva su página](GUIA-FRONTEND.md#regla-cada-tabla-del-backend-lleva-su-página).

```
db/
├── auth.sql             PKG_AUTH + /auth/    ← única excepción a la regla
├── usuarios.sql         PKG_USUARIOS + /usuarios/
├── modulos.sql          ─┐
├── paginas.sql           │ Menú y permisos
├── usuario-paginas.sql  ─┘
├── paises.sql           ─┐
├── departamentos.sql     │ Jerarquía geográfica
├── ciudades.sql         ─┘
├── empresas.sql         + logo (BLOB) y listado público del login
├── sucursales.sql
├── bancos.sql           Catálogo global de entidades bancarias
├── cuentas-bancarias.sql Cuentas por empresa, con FK a bancos y monedas
├── talonarios.sql        Numeración fiscal por empresa y sucursal
├── ventas.sql            Venta transaccional con detalle y cuotas
├── ventas-cobros.sql     Cobros y cuenta bancaria destino
├── monedas.sql          ─┐
├── unidades-medida.sql   │ Por empresa (ver 3.1)
├── categorias.sql        │
└── articulos.sql        ─┘ + imagen (BLOB, ver 3.2)
```

**`auth.sql` se ejecuta primero.** Define `PKG_AUTH`, del que depende cualquier
procedimiento que valide un token.

`auth.sql` es la excepción: no representa una tabla sino una responsabilidad
—verificar credenciales y manejar sesiones— que cruza `USUARIOS` y `TOKENS`.
Está separado del ABM porque cambia por motivos distintos: agregar un campo al
alta de usuarios no debería obligar a tocar el login.

El archivo lleva **el nombre de la tabla en minúscula**, sin prefijos numéricos,
y contiene todo lo que esa tabla necesita:

- El `PACKAGE` y el `PACKAGE BODY` con el ABM completo
- El módulo ORDS con sus endpoints
- Datos iniciales, si hacen falta
- Las consultas de verificación al final

Por qué así: cada archivo se ejecuta **de una sola vez y por separado**. Tocar
empresas no obliga a reejecutar usuarios, y el diff de un cambio queda acotado a
la tabla afectada.

### Reglas del archivo

**Idempotente.** Se tiene que poder reejecutar sin romper nada:
`CREATE OR REPLACE` en los paquetes, `ORDS.DELETE_MODULE` antes de
`ORDS.DEFINE_MODULE`, y los datos iniciales sólo si la tabla está vacía.

**Antes de reejecutar, frená `npm run dev`.** El servidor de desarrollo le pega
a ORDS, y esa sesión mantiene tomadas las filas de metadatos que
`DELETE_MODULE` necesita. Con el dev levantado, la reejecución muere con
`ORA-00060` (interbloqueo) y después con `ORA-00001` (nombre duplicado), porque
el módulo viejo nunca llegó a borrarse.

**Nunca uses `WHEN OTHERS THEN NULL` para borrar un módulo.** Parece inofensivo
—"si no existe, seguí de largo"— pero se traga _cualquier_ error, incluido el
interbloqueo. El script termina sin quejarse y vos creés que aplicó los
cambios, cuando en realidad ORDS sigue sirviendo la versión anterior. Usá el
`BORRAR_MODULO` privado del propio paquete (ver [db/modulos.sql](../db/modulos.sql)),
que consulta `USER_ORDS_MODULES` antes de borrar, reintenta ante `ORA-00060` y
**re-lanza** cualquier otro error.

> El código corregido en el repo no cambia nada por sí solo: ORDS solo conoce
> lo que se ejecutó en la hoja SQL de APEX. Si el script falló a mitad, el
> endpoint viejo sigue publicado por más que el archivo esté bien.

**No crea ni altera tablas.** El DDL lo administrás vos aparte. El archivo
asume que la tabla ya existe.

**No llama a `ORDS.ENABLE_SCHEMA`.** En APEX el esquema del workspace ya está
habilitado y esa llamada falla con `ORA-01031`.

**Sin `DBMS_CRYPTO`.** No está concedido en este workspace. Para valores
aleatorios usá `SYS_GUID()`, y para hashes `STANDARD_HASH`.

**Las funciones SQL puras se llaman desde `SELECT … FROM DUAL`.**
`STANDARD_HASH` es SQL, no PL/SQL: usarla como expresión directa en el cuerpo
del paquete falla con `PLS-00201`, que parece falta de grants pero no lo es.

```sql
-- Mal: PLS-00201
RETURN STANDARD_HASH(p_salt || p_password, 'SHA256');

-- Bien
SELECT STANDARD_HASH(p_salt || p_password, 'SHA256') INTO l_hash FROM DUAL;
RETURN l_hash;
```

**No se puede llamar a una función del paquete desde una sentencia SQL.**
Dentro de un `SELECT` o un `UPDATE` estás en contexto SQL, y una función
privada del paquete no es visible ahí (`PLS-00231`). Resolvé el valor antes,
en PL/SQL, y pasalo como variable:

```sql
-- Mal: PLS-00231
SELECT COUNT(*) INTO l_total FROM USUARIOS
 WHERE ACTIVO = NUMERO_A_ESTADO(p_activo);

-- Bien: se calcula en PL/SQL y el SELECT recibe un valor
l_estado := NUMERO_A_ESTADO(p_activo);
SELECT COUNT(*) INTO l_total FROM USUARIOS WHERE ACTIVO = l_estado;
```

---

## 2.1 El estado es `'A'`/`'I'`, nunca 1/0

> **Regla: el código de estado viaja igual de punta a punta — columna, JSON y
> frontend. No se traduce en ningún punto.**

Las columnas `ACTIVO` de `USUARIOS`, `MODULOS` y `PAGINAS` son `VARCHAR2(1)` y
guardan `'A'` (activo) o `'I'` (inactivo). El JSON devuelve **ese mismo
código**, y el frontend lo tipa como `Estado = "A" | "I"`.

Hubo una versión que exponía `activo: 1/0` en la API y traducía en los dos
sentidos. **No lo repitas.** Cada conversión era una oportunidad de
`ORA-01722`, y un `TO_NUMBER(:activo)` sobre un valor de texto mataba el
listado entero con un 500 sin mensaje. La traducción no aportaba nada: solo
creaba puntos donde equivocarse.

```sql
-- Mal: traduce a número en la respuesta
'activo' VALUE CASE WHEN ACTIVO = 'A' THEN 1 ELSE 0 END

-- Bien: el código tal cual está en la columna
'activo' VALUE UPPER(TRIM(ACTIVO))
```

```sql
-- Mal: el filtro exige que llegue numérico; ?activo=A da ORA-01722
p_activo IN NUMBER
l_activo := TO_NUMBER(NULLIF(:activo, ''));

-- Bien: texto contra texto, sin conversiones
p_activo IN VARCHAR2
l_estado := CASE UPPER(TRIM(NULLIF(:activo, '')))
              WHEN 'A' THEN 'A'
              WHEN 'I' THEN 'I'
              ELSE NULL          -- valor inválido = sin filtro
            END;
```

En los `UPDATE`, `NULL` significa **"no cambiar"**, y un valor inválido también
se ignora: es preferible conservar el estado actual a escribir basura en la
columna.

Esto vale para **todas** las tablas, sin excepciones. `TOKENS.ACTIVO` era
`NUMBER(1,0)` con 1/0 y se unificó a `VARCHAR2(1)` con `'A'` (vigente) e `'I'`
(revocado). Dos columnas con el mismo nombre y distinto tipo obligaban a
recordar cuál era cuál en cada comparación; ahora se comparan igual en todos
lados.

Cuando agregues una tabla nueva con estado, usá `VARCHAR2(1)` con `'A'`/`'I'`.

---

## 3. Crear el backend de una tabla

**Plantilla: [db/modulos.sql](../db/modulos.sql).** Es el patrón vigente y el
que hay que copiar. `db/usuarios.sql` y `db/auth.sql` son anteriores y usan un
estilo que ya no se sigue (ver "Lo que NO hay que hacer" más abajo).

> **Si la tabla cuelga de otra, la plantilla es
> [db/departamentos.sql](../db/departamentos.sql)** — ahí está resuelto el
> `LISTAR` con filtro opcional por el padre, el `JOIN` que trae su nombre, y la
> traducción de `ORA-02291` (FK) a 400 y `ORA-02292` (hijos) a 409.
>
> **Copialo tal cual y cambiá los nombres.** El `LISTAR` de una tabla hija
> siempre tiene esta forma, y desviarse de ella cuesta caro:
>
> ```sql
> PROCEDURE LISTAR (
>   p_authorization IN  VARCHAR2,
>   p_id_padre      IN  VARCHAR2,   -- NULL/vacío = todos
>   p_status_code   OUT NUMBER,
>   p_resultado     OUT CLOB
> )
> -- …
> l_id_padre := TO_NUMBER(NULLIF(p_id_padre, ''));
> -- …
> WHERE l_id_padre IS NULL OR ID_PADRE = l_id_padre;
> ```
>
> El `WHERE l_x IS NULL OR col = l_x` es lo que hace funcionar el "todos" del
> filtro. Sacar el parámetro para "simplificar" y filtrar en el cliente rompe
> la simetría con las páginas hermanas sin ganar nada.

Reglas que definen el patrón:

1. **Todo vive dentro de un solo paquete `PKG_<TABLA>`.** Nada de procedimientos
   sueltos en el esquema, ni siquiera helpers.
2. **Cada endpoint tiene nombre propio en la URL** (`/listar`, `/crear`,
   `/actualizar/:id`, `/eliminar/:id`). Nada de patrones `'.'`.
3. **El handler ORDS es una sola línea** que invoca al procedimiento del
   paquete. Cero PL/SQL embebido como texto.
4. **La única sentencia fuera del paquete** es la llamada que publica los
   endpoints.

### Esqueleto

```sql
--------------------------------------------------------------------------------
-- CTELL · EMPRESAS
--
--   GET    /empresas/listar
--   POST   /empresas/crear
--   PUT    /empresas/actualizar/:id
--   DELETE /empresas/eliminar/:id
--
-- REQUIERE db/auth.sql EJECUTADO ANTES (usa PKG_AUTH para validar el token).
-- Base: https://oracleapex.com/ords/ctell/empresas/
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_EMPRESAS AS

  PROCEDURE LISTAR (
    p_authorization IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE INSERTAR (
    p_authorization IN  VARCHAR2,
    p_razon_social  IN  VARCHAR2,
    p_ruc           IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Los parámetros ausentes (NULL) no modifican la columna correspondiente.
  PROCEDURE ACTUALIZAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_razon_social  IN  VARCHAR2,
    p_ruc           IN  VARCHAR2,
    p_activo        IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  PROCEDURE ELIMINAR (
    p_authorization IN  VARCHAR2,
    p_id            IN  VARCHAR2,
    p_status_code   OUT NUMBER,
    p_resultado     OUT CLOB
  );

  -- Borra y republica el módulo ORDS. Se llama al final del archivo.
  PROCEDURE PUBLICAR_ENDPOINTS;

END PKG_EMPRESAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_EMPRESAS AS

  -- Privado: borra el módulo ORDS si existe, reintentando ante interbloqueo.
  -- Copiar tal cual de db/modulos.sql (BORRAR_MODULO).
  PROCEDURE BORRAR_MODULO IS
    -- … ver db/modulos.sql …
  BEGIN
    NULL;
  END BORRAR_MODULO;

  -- … LISTAR, INSERTAR, ACTUALIZAR, ELIMINAR …

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;

    ORDS.DEFINE_MODULE(
      p_module_name    => 'empresas',
      p_base_path      => '/empresas/',
      p_items_per_page => 0,
      p_status         => 'PUBLISHED',
      p_comments       => 'ABM de empresas'
    );

    ORDS.SET_MODULE_ORIGINS_ALLOWED(
      p_module_name     => 'empresas',
      p_origins_allowed => 'https://www.ctell.online,http://localhost:8080'
    );

    ORDS.DEFINE_TEMPLATE(p_module_name => 'empresas', p_pattern => 'listar');

    ORDS.DEFINE_HANDLER(
      p_module_name => 'empresas',
      p_pattern     => 'listar',
      p_method      => 'GET',
      p_source_type => ORDS.source_type_plsql,
      p_source      => 'BEGIN PKG_EMPRESAS.LISTAR(:authorization, :status_code, :resultado); END;'
    );

    -- … los 3 DEFINE_PARAMETER de este handler, y lo mismo para los otros 3 …

    COMMIT;
  END PUBLICAR_ENDPOINTS;

END PKG_EMPRESAS;
/

-- Única sentencia fuera del paquete.
BEGIN
  PKG_EMPRESAS.PUBLICAR_ENDPOINTS;
END;
/
```

### Anatomía de un procedimiento

Los cuatro siguen la misma forma: validan token, hacen lo suyo, devuelven
`p_status_code` + `p_resultado`. Nunca lanzan excepción hacia afuera — el
`WHEN OTHERS` traduce todo a un código HTTP.

```sql
PROCEDURE ELIMINAR (
  p_authorization IN  VARCHAR2,
  p_id            IN  VARCHAR2,
  p_status_code   OUT NUMBER,
  p_resultado     OUT CLOB
) IS
  l_sesion NUMBER;
BEGIN
  -- 1. Token primero. Sin esto el ABM queda abierto a internet.
  l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
  IF l_sesion IS NULL THEN
    p_status_code := 401;
    p_resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  -- 2. La operación.
  DELETE FROM EMPRESAS WHERE ID_EMPRESA = TO_NUMBER(NULLIF(p_id, ''));

  -- 3. Sin esto, borrar un ID inexistente devuelve 200 y quien lo usó cree
  --    que borró algo.
  IF SQL%ROWCOUNT = 0 THEN
    p_status_code := 404;
    p_resultado := '{"error":"La empresa no existe"}';
    RETURN;
  END IF;

  COMMIT;
  p_status_code := 200;
  p_resultado := '{"ok":true}';
EXCEPTION
  WHEN DUP_VAL_ON_INDEX THEN
    ROLLBACK;
    p_status_code := 409;   -- El dato no es inválido: el estado lo rechaza.
    p_resultado := '{"error":"Ya existe"}';
  WHEN OTHERS THEN
    ROLLBACK;
    p_status_code := 500;
    -- El detalle va al log, nunca a la respuesta. Con SQLCODE adelante para
    -- poder buscarlo en APEX_DEBUG_MESSAGES sin cruzar tablas de códigos.
    APEX_DEBUG.ERROR('PKG_EMPRESAS.ELIMINAR: [' || SQLCODE || '] ' || SQLERRM ||
                     ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    p_resultado := '{"error":"Error al eliminar la empresa"}';
END ELIMINAR;
```

**Un `ORDEN` ausente se calcula, no se rellena con 0.** Si la tabla tiene una
columna de posición, el alta sin valor explícito toma el siguiente libre —
`NVL(MAX(ORDEN), 0) + 1` **dentro del grupo con el que se muestra**, no global:

```sql
-- El alcance es (módulo, entrada) porque el menú ordena dentro de cada
-- sección: Reportes de Compras numera aparte de Definiciones de Compras.
SELECT NVL(MAX(ORDEN), 0) + 1
  INTO l_orden
  FROM PAGINAS
 WHERE ID_MODULO = l_id_modulo
   AND ENTRADA = l_entrada;
```

Tres decisiones ahí, todas por algo:

- **`MAX`, no `COUNT`.** Si borraron la última, `COUNT` reutiliza un orden ya
  usado y dos filas quedan empatadas.
- **Se calcula en el backend**, que es el único que ve la tabla entera. El
  frontend tendría que traerse todo para averiguarlo, y dos altas simultáneas se
  pisarían igual.
- **Un valor explícito gana**, para poder intercalar entre dos existentes sin
  renumerar el resto.

Del lado del frontend eso significa que el campo tiene que poder quedar
**vacío**, y que un `z.coerce.number()` no sirve: convierte `""` en `0` y manda
la fila nueva al principio en vez de al final.

**Los `UPDATE` respetan los NULL.** Un parámetro sin valor no pisa la columna:

```sql
-- El código se resuelve ANTES, en PL/SQL: una función del paquete no es
-- visible desde una sentencia SQL (PLS-00231).
l_estado := CASE UPPER(TRIM(p_activo))
              WHEN 'A' THEN 'A'
              WHEN 'I' THEN 'I'
              ELSE NULL          -- valor inválido = no cambiar
            END;

UPDATE EMPRESAS
   SET RAZON_SOCIAL = NVL(TRIM(p_razon_social), RAZON_SOCIAL),
       ACTIVO       = NVL(l_estado, ACTIVO)
 WHERE ID_EMPRESA = TO_NUMBER(NULLIF(p_id, ''));
```

**Todos los parámetros de entrada son `VARCHAR2`, incluso los numéricos.** ORDS
los entrega como texto; convertir adentro con `TO_NUMBER(NULLIF(p_x, ''))`.

### Parámetros ORDS de cada handler

Los tres, siempre, para los cuatro endpoints:

| `p_name`             | `p_bind_variable_name` | `p_source_type` | `p_access_method` |
| -------------------- | ---------------------- | --------------- | ----------------- |
| `authorization`      | `authorization`        | `HEADER`        | `IN`              |
| `resultado`          | `resultado`            | `RESPONSE`      | `OUT`             |
| `X-APEX-STATUS-CODE` | `status_code`          | `HEADER`        | `OUT`             |

Los campos del body (`:razon_social`, `:ruc`, …) **no se declaran**: ORDS
parsea el JSON y los vincula a los binds del mismo nombre. Pasar `'BODY'` como
`p_source_type` aborta el script con `ORA-02290`.

> El token se extrae con `PKG_AUTH.TOKEN_DE_HEADER`, no con un
> `REPLACE(p_authorization, 'Bearer ', '')` a mano. El esquema es
> case-insensitive por RFC: con el `REPLACE` literal, un cliente que mande
> `bearer xxx` deja el prefijo pegado al token y recibe un 401 que no hay forma
> de explicar mirando las credenciales.

### Lo que NO hay que hacer

| ❌ Evitar                                                | ✅ En su lugar                                                     |
| -------------------------------------------------------- | ------------------------------------------------------------------ |
| `p_pattern => '.'`                                       | `'listar'`, `'crear'`, `'actualizar/:id'`, `'eliminar/:id'`        |
| PL/SQL embebido en `q'~ … ~'` dentro de `DEFINE_HANDLER` | Una línea: `'BEGIN PKG_X.LISTAR(…); END;'`                         |
| `CREATE OR REPLACE PROCEDURE` suelto                     | Todo dentro de `PKG_<TABLA>`                                       |
| Depender de helpers externos (`BORRAR_MODULO_ORDS`)      | `BORRAR_MODULO` privado en el propio paquete                       |
| `p_resultado := JSON_OBJECT(… RETURNING CLOB);`          | `SELECT JSON_OBJECT(… RETURNING CLOB) INTO p_resultado FROM DUAL;` |

Ese último merece explicación: **`JSON_OBJECT(... RETURNING CLOB)` como
asignación PL/SQL directa falla con `PLS-00684`** dentro de un package body.
Envuelto en un `SELECT … FROM DUAL` sí compila. Sin `RETURNING CLOB` la
asignación directa funciona (devuelve `VARCHAR2`), pero se trunca a 4000 bytes
— por eso los listados siempre necesitan el `SELECT`.

**El JSON se arma con `JSON_OBJECT` / `JSON_ARRAYAGG`** y `RETURNING CLOB` en
los listados. `JSON_ARRAYAGG` devuelve `NULL` cuando no hay filas, no un array
vacío: sin `NVL(l_items, TO_CLOB('[]'))` el frontend recibe `"items":null` y
revienta al iterarlo.

#### El listado anda con pocas filas y da 500 cuando crece

> **Nunca anides `JSON_OBJECT` dentro de `JSON_ARRAYAGG`.** Armá el objeto en
> una subconsulta y agregá esa columna.

Anidado, el resultado intermedio del agregado se materializa como `VARCHAR2` y
revienta al pasar los **4000 bytes**, aunque los dos `RETURNING CLOB` estén
puestos. El síntoma es venenoso porque **depende de la cantidad de datos**:

- `?idDepartamento=5` → pocas filas, entra en 4000 bytes → **200 OK**
- sin filtro → todas las filas, se pasa → **500**

Parece un problema del filtro "todos", y no lo es. Cuesta encontrarlo porque el
paquete compila perfecto, `USER_ERRORS` está vacío, y el mismo endpoint responde
bien o mal según qué le pidas. Si un listado anda filtrado y falla sin filtrar,
**es esto**, no el `WHERE`.

```sql
-- ❌ Anidado: muere al superar 4000 bytes
SELECT JSON_ARRAYAGG(
         JSON_OBJECT('id' VALUE c.ID, 'nombre' VALUE c.NOMBRE RETURNING CLOB)
         ORDER BY c.NOMBRE
         RETURNING CLOB)
  INTO l_items
  FROM CIUDADES c;

-- ✅ El objeto se arma en la subconsulta; el agregado recibe una columna CLOB.
-- Las claves del ORDER BY se exponen como columnas para poder ordenar afuera.
SELECT JSON_ARRAYAGG(fila ORDER BY nombre RETURNING CLOB)
  INTO l_items
  FROM (
    SELECT JSON_OBJECT('id' VALUE c.ID, 'nombre' VALUE c.NOMBRE RETURNING CLOB) AS fila,
           c.NOMBRE AS nombre
      FROM CIUDADES c
  );
```

Todos los `db/*.sql` con listado usan esta forma. Copiala tal cual.

#### …y si ya está desanidado y IGUAL da 500, es el volumen

La subconsulta arregla el límite de los 4000 bytes del resultado **intermedio**,
no el tamaño del CLOB final. Un listado sin paginar devuelve el catálogo entero
en un solo JSON, y a partir de cierta cantidad de filas vuelve a fallar con el
mismo 500 genérico.

Pasó de verdad con `/articulos/listar`: andaba con una docena de artículos de
prueba, se cargó el catálogo real —cientos de filas, con `DESCRIPCION` de hasta
1000 caracteres cada una— y el endpoint empezó a dar 500 en todas las llamadas.

**Cómo distinguirlo del anidado**, que da el mismo síntoma:

| Señal                                            | Anidado | Volumen                  |
| ------------------------------------------------ | ------- | ------------------------ |
| Andaba y dejó de andar tras una carga de datos   | No      | **Sí**                   |
| Falla sin filtro pero anda filtrado              | Sí      | Sí                       |
| El `JSON_OBJECT` está dentro del `JSON_ARRAYAGG` | Sí      | No                       |
| Se arregla desanidando                           | Sí      | **No** — hay que paginar |

**La regla:** un listado de una tabla que puede crecer sin techo —artículos,
personas, facturas, lotes— **se pagina en el servidor desde el principio**, no
cuando falle. Las tablas de catálogo acotado (monedas, unidades, países) no lo
necesitan.

La forma, tal como quedó en `db/articulos.sql`:

```sql
-- Los cuatro parámetros son opcionales y llegan como VARCHAR2 (ver la trampa
-- del TO_NUMBER más arriba).
l_pagina  := GREATEST(NVL(TO_NUMBER(NULLIF(p_pagina, '')), 1), 1);
l_tamanio := LEAST(GREATEST(NVL(TO_NUMBER(NULLIF(p_tamanio, '')), 20), 1), 200);
l_offset  := (l_pagina - 1) * l_tamanio;

SELECT JSON_ARRAYAGG(fila ORDER BY nombre RETURNING CLOB)
  INTO l_items
  FROM (
    SELECT JSON_OBJECT(...) AS fila, a.NOMBRE_ARTICULO AS nombre
      FROM ARTICULOS a
     WHERE (l_id_empresa IS NULL OR a.ID_EMPRESA = l_id_empresa)
     -- EL ORDER BY VA ACA, no sólo en el JSON_ARRAYAGG: es el que decide QUÉ
     -- filas entran en la página. Sin él, OFFSET/FETCH recorta en un orden que
     -- Oracle no garantiza y la página 2 puede repetir u omitir filas de la 1.
     ORDER BY a.NOMBRE_ARTICULO
     OFFSET l_offset ROWS FETCH NEXT l_tamanio ROWS ONLY
  );
```

Tres detalles que no son opcionales:

1. **Techo al `tamanio`** (200). Sin tope, un `?tamanio=999999` reproduce
   exactamente el 500 que la paginación viene a evitar. **Pero 200 no es un
   tamaño seguro de pedir** — ver la sección siguiente.
2. **`total` cuenta las filas que pasan el filtro**, no las de la página ni la
   tabla entera: es lo que le dice al frontend si queda algo por traer.
3. **La búsqueda y los filtros van en el SQL**, antes de paginar. Filtrando en
   el cliente sólo se mira lo ya traído, y una fila de la página 5 no aparece al
   buscarla. Ver `db/articulos.sql` y el `useInfiniteQuery` de
   `src/routes/_auth.articulos.tsx`.

#### …y si paginás y IGUAL da 500, es el bind de ORDS

Este es el tercer piso del mismo problema, y el más difícil de ver: **el PL/SQL
está sano y aun así la petición falla.**

`ORDS.DEFINE_PARAMETER` publica el `OUT CLOB` así:

```sql
p_name => 'resultado', p_bind_variable_name => 'resultado',
p_source_type => 'RESPONSE', p_param_type => 'STRING', p_access_method => 'OUT');
```

`p_param_type => 'STRING'` vincula ese CLOB a un `VARCHAR2`, **con techo de 4000
bytes**. Es el mismo número de las dos secciones anteriores, pero pega en un
lugar distinto: no dentro del SQL, sino **cuando ORDS lee el resultado**, ya
terminado el procedimiento.

Por eso el síntoma es tan opaco:

- El paquete compila y `USER_ERRORS` está vacío.
- El `WHEN OTHERS` **no registra nada**: el PL/SQL terminó bien, el error es
  posterior.
- `APEX_DEBUG` tampoco tiene la traza, por lo mismo.
- El endpoint responde 200 con `?tamanio=20` y 500 con `?tamanio=200`.

Pasó con `/articulos/listar` y costó varias vueltas: se le echó la culpa al
`WHERE`, a una subconsulta y al largo de `DESCRIPCION` antes de encontrarlo.

**Cómo reconocerlo:** si el listado ya está desanidado, ya pagina, y falla
según el `tamanio` que le pidas, es esto. La prueba definitiva es correr el
procedimiento sin ORDS (ver la sección siguiente) y mirar el largo:

```sql
DECLARE
  l_status NUMBER; l_res CLOB;
BEGIN
  PKG_ARTICULOS.LISTAR('Bearer <token>', '21', NULL, NULL, '1', '200', l_status, l_res);
  DBMS_OUTPUT.PUT_LINE('status: ' || l_status || ' | bytes: ' || DBMS_LOB.GETLENGTH(l_res));
END;
/
```

`status: 200` con más de 4000 bytes confirma el diagnóstico: el problema no está
en el paquete.

**El arreglo de fondo** sería publicar el parámetro como `p_param_type => 'CLOB'`.
**No lo hagas sin verificar antes** que esta instalación lo acepta:
`DEFINE_PARAMETER` valida `p_param_type` contra un check constraint con una
lista cerrada de valores, y uno inválido lanza `ORA-02290` que **aborta
`PUBLICAR_ENDPOINTS` a la mitad y deja el módulo sin ningún endpoint** — se cae
la pantalla entera, no sólo la que falla. Ya pasó dos veces con el BLOB del logo
de empresas (ver 3.2).

La consulta que lo dice es `ALL_CONSTRAINTS` sobre `REST_PARAMS_PARAM_TYPE_CK`,
pero **en APEX cloud suele volver vacía**: la constraint vive en el esquema
`ORDS_METADATA`, al que el usuario del workspace no tiene acceso. Si no podés
verla, la forma segura de probar es un módulo descartable:

```sql
BEGIN
  ORDS.DEFINE_MODULE(p_module_name => 'zz_prueba', p_base_path => '/zz_prueba/');
  ORDS.DEFINE_TEMPLATE(p_module_name => 'zz_prueba', p_pattern => 'x');
  ORDS.DEFINE_HANDLER(p_module_name => 'zz_prueba', p_pattern => 'x', p_method => 'GET',
    p_source_type => ORDS.source_type_plsql, p_source => 'BEGIN NULL; END;');
  ORDS.DEFINE_PARAMETER(
    p_module_name => 'zz_prueba', p_pattern => 'x', p_method => 'GET',
    p_name => 'resultado', p_bind_variable_name => 'resultado',
    p_source_type => 'RESPONSE', p_param_type => 'CLOB', p_access_method => 'OUT');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('CLOB ACEPTADO');
EXCEPTION WHEN OTHERS THEN
  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE('CLOB RECHAZADO: ' || SQLERRM);
END;
/
-- Limpiar despues:
BEGIN ORDS.DELETE_MODULE('zz_prueba'); COMMIT; END;
/
```

**Mientras tanto, el rodeo es pedir páginas chicas.** `/existencias` pide de a
**50**, no de a 200, y por eso funciona. El techo de 200 del backend sigue
siendo correcto como defensa contra un `?tamanio=99999`, pero **200 no es un
tamaño que convenga pedir**: es el máximo que el backend acepta, no el máximo
que ORDS puede devolver.

> **Regla práctica:** en una pantalla que trae el catálogo completo paginando,
> pedí de a 50. Si una respuesta con textos largos sigue fallando, bajá a 25
> antes de buscar el problema en el SQL.

#### Resumen: los tres pisos del mismo 4000

Los tres dan el mismo 500 genérico y se distinguen por qué los arregla:

| Piso                    | Dónde pega                        | Se arregla con           |
| ----------------------- | --------------------------------- | ------------------------ |
| `JSON_OBJECT` anidado   | Resultado intermedio del agregado | Desanidar en subconsulta |
| CLOB final muy grande   | El JSON completo                  | Paginar en el servidor   |
| Bind `'STRING'` de ORDS | Al devolver la respuesta          | Pedir páginas más chicas |

Si desanidaste y paginaste y sigue fallando, **no busques más en el SQL**: bajá
el tamaño de página.

### Probar un procedimiento sin pasar por ORDS

La ventaja de tener todo en un paquete: cada procedimiento se prueba solo en la
hoja SQL, con valores literales. Si falla, el error aparece ahí —no escondido
detrás de un 500 genérico de ORDS.

```sql
DECLARE
  l_status NUMBER;
  l_result CLOB;
BEGIN
  PKG_EMPRESAS.LISTAR('Bearer TU_TOKEN', l_status, l_result);
  DBMS_OUTPUT.PUT_LINE('status: ' || l_status);
  DBMS_OUTPUT.PUT_LINE('resultado: ' || l_result);
END;
/
```

### Parámetros: las tres trampas que ya nos costaron caro

Los query params llegan como **texto**, y hay que convertirlos. Pero convertir
mal produce un 500 sin mensaje que es dificilísimo de diagnosticar. Estas tres
reglas no son estilo: son la diferencia entre un endpoint que anda y uno que
muere.

> Las dos primeras las verifica `npm run lint` sólo de a ratos; la tercera la
> chequea `scripts/verificar-convenciones.mjs` en cada lint. Si tocás handlers,
> corré el lint antes de ejecutar nada en APEX.

#### 1. Un parámetro ausente llega como cadena vacía, no como NULL

`TO_NUMBER('')` lanza **ORA-01722**. Y `:param IS NULL` **no protege**, porque
una cadena vacía no es NULL:

```sql
-- Mal: si el cliente no manda `pagina`, ORA-01722
l_pagina := NVL(TO_NUMBER(:pagina), 1);

-- Mal también: el IS NULL nunca da verdadero con cadena vacía
AND (:activo IS NULL OR ACTIVO = TO_NUMBER(:activo))

-- Bien: NULLIF convierte la cadena vacía en NULL antes de tocar el número
l_pagina := NVL(TO_NUMBER(NULLIF(:pagina, '')), 1);
```

> Pasó de verdad: el listado de usuarios pedía `?tamanio=100` sin `pagina`, y
> ese solo caso tiraba abajo el endpoint entero.

#### 2. Las conversiones van DENTRO del `BEGIN`, nunca en el `DECLARE`

El `DECLARE` se ejecuta **antes de que exista el bloque `EXCEPTION`**. Una
excepción ahí no la captura el `WHEN OTHERS`: escapa del handler y ORDS
responde un 500 genérico, sin que el `EXCEPTION` que escribiste llegue a
correr. Buscás el error en el lugar equivocado durante horas.

```sql
-- Mal: si esto falla, tu WHEN OTHERS no se entera
DECLARE
  l_pagina NUMBER := TO_NUMBER(NULLIF(:pagina, ''));
BEGIN

-- Bien: declarar vacío, asignar adentro
DECLARE
  l_pagina NUMBER;
BEGIN
  l_pagina := TO_NUMBER(NULLIF(:pagina, ''));
```

#### 3. El JSON del body NO se lee con `:body`

Es la que más tiempo nos costó, y la más difícil de ver: **el endpoint responde
400 "son obligatorios" con el body perfectamente armado.**

`:body` es el payload **crudo, como BLOB**. Existe para subir archivos — es lo
que usan `GUARDAR_IMAGEN`, `GUARDAR_FOTO` y `GUARDAR_LOGO`, y ahí está bien.
Para un JSON, en cambio, **ORDS ya lo parsea y crea un bind por cada clave de
primer nivel**, igual que con los query params:

```sql
-- MAL: p_body recibe un BLOB, y JSON_VALUE devuelve NULL en TODOS los campos
p_source => 'BEGIN PKG_X.ACTUALIZAR(:authorization, :id, :body, :status_code, :resultado); END;'
...
  l_empresa := TO_NUMBER(NULLIF(JSON_VALUE(p_body, '$.idEmpresa'), ''));

-- BIEN: cada clave del JSON es su propio bind, como VARCHAR2
p_source => 'BEGIN PKG_X.ACTUALIZAR(:authorization, :id, :idEmpresa, :fecha, :status_code, :resultado); END;'
...
  l_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));
```

Los binds del body **no se declaran con `DEFINE_PARAMETER`**, igual que los
query params: se vinculan solos por nombre. Ver `db/categorias.sql`, que es el
patrón que sigue todo el resto del proyecto.

**Por qué se tarda tanto en encontrarlo:**

- El `GET` y el `DELETE` **siguen andando**, porque toman todo de la ruta. El
  síntoma que llega es _"el delete funciona, el update no"_, que suena a un
  problema del `UPDATE` y no del binding.
- El body viaja bien: se ve entero en la pestaña Network del navegador.
- El paquete compila **VALID**: no hay ningún error que mirar.
- El mensaje que vuelve es el 400 que vos mismo escribiste, así que parece que
  el frontend está mandando mal los datos.

**Y el corolario, del lado del cliente:** mandá siempre todas las claves, con
`""` cuando el valor está vacío. Como ORDS arma un bind por clave, una clave
omitida deja el bind **sin definir** en vez de en NULL. El PL/SQL las normaliza
con `NULLIF(TRIM(p_x), '')`.

### Verificación al final del archivo

```sql
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_TYPE IN ('PACKAGE', 'PACKAGE BODY')
   AND OBJECT_NAME = 'PKG_EMPRESAS';

SELECT NAME, LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_EMPRESAS'
 ORDER BY SEQUENCE;
```

> La columna de `USER_OBJECTS` es `OBJECT_NAME`, **no** `NAME`: usar `NAME` da
> `ORA-00904`.

---

## 3.1 Tablas por empresa

`CUENTAS_BANCARIAS`, `MONEDAS`, `UNIDADES_MEDIDA`, `CATEGORIAS` y `ARTICULOS` cuelgan de `EMPRESAS`:
cada empresa tiene su propio juego. Si la tabla nueva es de este tipo, seguí
`db/monedas.sql` — es el ejemplo más chico y completo.

`CUENTAS_BANCARIAS` agrega dos relaciones: `ID_BANCO` es obligatorio y apunta
al catálogo global `BANCOS`; `ID_MONEDA` es opcional y debe apuntar a una
moneda de la misma empresa. El listado recibe `?idEmpresa=` y las operaciones
de actualización y borrado también exigen ese id para aislar la fila.

`BANCOS` no es una tabla por empresa: se comparte entre todas y sus endpoints
no reciben `idEmpresa`.

### El filtro por empresa va TAMBIÉN en las subconsultas

> **Toda consulta que toque una tabla con `ID_EMPRESA` filtra por empresa.
> Incluidas las subconsultas correlacionadas que calculan un derivado.**

Es fácil poner el filtro en el `WHERE` principal y olvidarlo en la subconsulta
que suma un total. El resultado no es un error: es **un número mal calculado que
nadie detecta**, porque la pantalla se ve perfecta.

Pasó en `/articulos/listar` con el stock:

```sql
-- ❌ Suma los lotes de TODAS las empresas
'cantidadStock' VALUE NVL((SELECT SUM(NVL(l.CANTIDAD_DISPON, l.CANTIDAD))
                             FROM LOTES l
                            WHERE l.ID_ARTICULO = a.ID_ARTICULO), 0),

-- ✅ Acotado a la empresa del artículo
'cantidadStock' VALUE NVL((SELECT SUM(NVL(l.CANTIDAD_DISPON, l.CANTIDAD))
                             FROM LOTES l
                            WHERE l.ID_ARTICULO = a.ID_ARTICULO
                              AND l.ID_EMPRESA  = a.ID_EMPRESA), 0),
```

Un artículo cargado en dos empresas mostraba —y **exportaba a Excel**— la suma
de las dos. El reporte de existencias daba un número que no era el de la empresa
conectada, sin ningún síntoma visible.

**Correlacioná contra la columna de la tabla externa (`a.ID_EMPRESA`), no contra
la variable del parámetro (`l_id_empresa`).** Así el filtro sigue aplicando
cuando el listado se pide sin `idEmpresa`: cada fila suma lo de su propia
empresa, en vez de que el filtro se apague justo en el caso más peligroso.

De paso, el filtro deja usar el índice por empresa. Sin él la subconsulta —que
corre **una vez por fila**— escanea de más, y eso empeora los problemas de
volumen de la sección anterior.

**Cómo auditarlo** en el archivo que estés escribiendo:

```sh
# Cada FROM <tabla> de una subconsulta debería tener su ID_EMPRESA cerca
grep -n "FROM LOTES" db/*.sql
```

Las excepciones legítimas son los **catálogos globales**, que no tienen
`ID_EMPRESA` y por lo tanto no se filtran: `PAISES`, `DEPARTAMENTOS`,
`CIUDADES`, `BANCOS`, `IVA`, `CONDICIONES_PAGO`, `UNIDADES_MEDIDA` y
`PERSONAS`. Si contás usos de un catálogo global cruzando empresas, está bien:
es lo que corresponde.

### Punto de venta

`PKG_VENTAS` maneja cabecera, detalle y cuotas en una única transacción. El
precio llega manualmente por línea y el porcentaje de `LISTAS_DESCUENTOS` se
calcula en el backend. Una condición de 30 días y 3 cuotas genera vencimientos
acumulados a 30, 60 y 90 días.

Antes de insertar la cabecera, recibe `ID_TALONARIO`, busca un talonario activo
de la misma empresa y sucursal y lo bloquea con `FOR UPDATE`. De esa fila copia
`TIPO_COMPROBANTE`, `NRO_TIMBRADO`, `ESTABLECIMIENTO`, `PUNTO_EXPEDICION` y
`NRO_ACTUAL` a `VENTAS_CABECERAS`; luego incrementa `TALONARIOS.NRO_ACTUAL` en
la misma transacción. El cliente no debe enviar `NUMERO_VENTA` ni los datos
fiscales: son datos derivados del talonario y permitirlos abriría una puerta a
duplicados o numeración fuera de rango.

Al confirmar la venta **no se toca ninguna existencia**: el descuento por lote
se retiró junto con `VENTAS_DETALLES.ID_LOTE` (ver
[3.6](#36-transacciones-que-mueven-stock-o-plata)). `PKG_VENTAS_COBROS` registra
luego los cobros y actualiza `VENTAS_CUOTAS.MONTO_PAGADO`.

El DDL original de `VENTAS_COBROS` no trae cuenta bancaria. Ejecutá
`db/ventas-cobros.sql` después de crear la tabla: agrega idempotentemente
`ID_CUENTA_BANCARIA` y su FK a `CUENTAS_BANCARIAS` antes de compilar el paquete.

Tres cosas específicas:

**El listado se filtra por `?idEmpresa=`.** El id sale de la empresa activa de
la sesión, no de un combobox del formulario:

```sql
l_id_empresa := TO_NUMBER(NULLIF(p_id_empresa, ''));

SELECT COUNT(*) INTO l_total
  FROM MONEDAS
 WHERE l_id_empresa IS NULL OR ID_EMPRESA = l_id_empresa;
```

**No hagas `JOIN` contra `EMPRESAS`.** Como el listado ya viene filtrado por una
sola empresa, su nombre sería la misma constante repetida en cada fila, y el
frontend ya lo tiene en la empresa activa. Un `JOIN` que no aporta un dato
distinto por fila no se hace — es la misma razón por la que `ciudades.sql` no
llega hasta `PAISES`.

**El `UNIQUE` casi siempre es compuesto con la empresa.** Fijate cuál es la otra
columna antes de escribir el mensaje del 409, porque cambia según la tabla:

| Tabla             | UNIQUE                           | Mensaje del 409                                |
| ----------------- | -------------------------------- | ---------------------------------------------- |
| `MONEDAS`         | `(ID_EMPRESA, NOMBRE_MONEDA)`    | "…ya tiene una moneda con ese nombre"          |
| `CATEGORIAS`      | `(ID_EMPRESA, NOMBRE_CATEGORIA)` | "…ya tiene una categoría con ese nombre"       |
| `UNIDADES_MEDIDA` | `(ID_EMPRESA, **ABREVIATURA**)`  | "…ya tiene una unidad con esa **abreviatura**" |

En `UNIDADES_MEDIDA` lo único es la **abreviatura**, no el nombre: decir "ya
existe una unidad con ese nombre" mandaría a cambiar el campo equivocado.

---

## 3.1.1 Tablas por empresa Y sucursal

`UBICACIONES` es la primera tabla que cuelga de dos contextos: `ID_EMPRESA` **y**
`ID_SUCURSAL`. El listado acepta los dos filtros y el alta los exige.

`TALONARIOS` usa el mismo contexto y agrega una responsabilidad operativa: sus
columnas de numeración alimentan `VENTAS_CABECERAS`. El alta inicializa
`NRO_ACTUAL` dentro del rango; al emitir una venta, `PKG_VENTAS` bloquea el
talonario, copia sus datos fiscales y avanza el número. No se debe actualizar
`NRO_ACTUAL` desde el frontend ni aceptar un número fiscal enviado por el
cliente.

Los dos ids salen de los providers globales del frontend (`useEmpresa()` y
`useSucursal()`), nunca de un combobox del formulario — igual que el `idEmpresa`
de las tablas por empresa.

### Dos FK no garantizan coherencia entre sí

Este es el detalle que hay que cuidar. El DDL declara las dos FK por separado:

```sql
ALTER TABLE UBICACIONES ADD FOREIGN KEY (ID_EMPRESA)  REFERENCES EMPRESAS (ID_EMPRESA);
ALTER TABLE UBICACIONES ADD FOREIGN KEY (ID_SUCURSAL) REFERENCES SUCURSALES (ID_SUCURSAL);
```

Las dos se validan **contra su propia tabla y nada más**, así que la base acepta
sin chistar una fila con la empresa A y una sucursal de la empresa B. El UNIQUE
tampoco lo detecta. La fila queda colgada de una sucursal ajena, y el listado
filtrado por empresa la muestra igual.

**Hay que validarlo a mano antes de escribir.** En `PKG_UBICACIONES` está en un
helper privado:

```sql
FUNCTION SUCURSAL_ES_DE_EMPRESA (
  p_id_sucursal IN NUMBER,
  p_id_empresa  IN NUMBER
) RETURN BOOLEAN IS
  l_existe PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_existe
    FROM SUCURSALES
   WHERE ID_SUCURSAL = p_id_sucursal
     AND ID_EMPRESA  = p_id_empresa;
  RETURN l_existe > 0;
END;
```

Devolver **400** si no coincide: el dato es inválido, no falló el servidor.

> **En el `ACTUALIZAR` hay que resolver primero cómo va a quedar la fila.**
> Validar sólo los parámetros recibidos no alcanza: un `PUT` que cambia
> únicamente la sucursal —dejando la empresa como estaba— también puede romper la
> coherencia. Se leen los valores actuales, se aplica el `NVL` mentalmente y se
> valida el par final:
>
> ```sql
> SELECT NVL(l_id_empresa, ID_EMPRESA), NVL(l_id_sucursal, ID_SUCURSAL)
>   INTO l_emp_final, l_suc_final
>   FROM UBICACIONES WHERE ID_UBICACION = l_id;
> -- recién ahora: SUCURSAL_ES_DE_EMPRESA(l_suc_final, l_emp_final)
> ```

Conviene dejar al final del `.sql` una consulta de auditoría que **debe devolver
cero filas** — si devuelve alguna, hay datos ya inconsistentes de antes:

```sql
SELECT u.ID_UBICACION, u.ID_EMPRESA AS EMPRESA_UBICACION, s.ID_EMPRESA AS EMPRESA_SUCURSAL
  FROM UBICACIONES u
  JOIN SUCURSALES  s ON s.ID_SUCURSAL = u.ID_SUCURSAL
 WHERE s.ID_EMPRESA != u.ID_EMPRESA;
```

### Columnas de texto que en realidad son datos

`UBICACIONES.ZONA` es `VARCHAR2(10)` y se guarda **en mayúsculas**: sin
normalizar, `a1` y `A1` pasan el UNIQUE como dos ubicaciones distintas siendo la
misma repisa. La normalización va en el paquete (`UPPER(TRIM(...))`), no confiada
al frontend.

El caso hermano está en `DETALLE_MONEDAS.DENOMINACION`, también `VARCHAR2`:
guarda **dígitos pelados** (`'50000'`, no `'50.000'` ni `'Billete de 50'`) porque
como texto el orden sale mal — `'10000'` se ordena antes que `'2000'`. El
`ORDER BY` convierte a número:

```sql
ORDER BY TO_NUMBER(
           REGEXP_REPLACE(DENOMINACION, '[^0-9]', '')
           DEFAULT NULL ON CONVERSION ERROR
         ) NULLS LAST
```

> **`DEFAULT NULL ON CONVERSION ERROR` no es opcional.** Una sola fila con texto
> —cargada a mano antes de que el alta validara— mata el listado entero con
> `ORA-01722`. Con el default, esas filas quedan en NULL y `NULLS LAST` las manda
> al final.
>
> Si la columna va a servir para **calcular** (cantidad × valor en un cierre de
> caja), no la parsees en cada consulta: agregá una columna `NUMBER`.

---

## 3.1.2 Tablas por empresa que NO tienen `ID_EMPRESA`

`MANUALES` cuelga de `INSTITUCIONES`, que sí es por empresa, pero **no tiene la
columna**: su DDL es `ID_MANUAL`, `ID_INSTITUCION`, `GRADO`, `ARCHIVO_PDF` y las
dos fechas.

**No se la agregues.** Sería el mismo dato en dos lugares, con la puerta abierta
a que un manual quede en una empresa y su institución en otra — y el DDL lo
administra otro. El aislamiento se hace **contra el padre**, con un JOIN.

### El filtro por empresa pasa a ser el JOIN

```sql
SELECT ...
  FROM MANUALES m
  JOIN INSTITUCIONES i ON i.ID_INSTITUCION = m.ID_INSTITUCION
 WHERE i.ID_EMPRESA = l_id_empresa
```

**El JOIN es interno a propósito.** `ID_INSTITUCION` es `NOT NULL` con FK, así
que no hay ninguna fila que un `INNER` pueda esconder — y con un `LEFT`, un
manual cuya institución no matchea el `WHERE` se colaría en el listado de otra
empresa. Es la excepción a la regla de "`LEFT JOIN` si la FK es nullable":
justamente porque acá no lo es.

Para el `UPDATE` y el `DELETE`, donde no hay un `FROM` al que sumarle el JOIN, va
un `EXISTS`:

```sql
DELETE FROM MANUALES m
 WHERE m.ID_MANUAL = l_id
   AND EXISTS (SELECT 1 FROM INSTITUCIONES i
                WHERE i.ID_INSTITUCION = m.ID_INSTITUCION
                  AND i.ID_EMPRESA     = l_id_empresa);
```

### Acá `idEmpresa` en el `LISTAR` es OBLIGATORIO

En el resto del proyecto un `idEmpresa` vacío significa "todas las empresas", y
está bien: la pantalla siempre lo manda. Con esta forma, **no**.

La diferencia es que en una tabla con columna propia el olvido se nota —el
listado trae de más y salta a la vista—, mientras que acá la consulta *no se
acota sola*: sin la empresa el `WHERE` desaparece y devuelve los manuales de todo
el sistema, que se ven exactamente igual a los propios hasta que una institución
reconoce los de otra. Devolvé 400.

### La FK valida que el padre exista, no de quién es

Antes de insertar hay que comprobar que la institución sea **de esa empresa**:

```sql
FUNCTION INSTITUCION_ES_DE_EMPRESA (p_id_institucion IN NUMBER, p_id_empresa IN NUMBER)
  RETURN BOOLEAN IS ...
    SELECT COUNT(*) INTO l_existe FROM INSTITUCIONES
     WHERE ID_INSTITUCION = p_id_institucion AND ID_EMPRESA = p_id_empresa;
```

Las dos preguntas en una sola función y con un solo mensaje de error: si la
institución es de otra empresa, para esta sesión es lo mismo que si no
existiera. Un mensaje distinto para cada caso confirmaría que el id existe.

### Y en el `ACTUALIZAR`, la fila Y el destino

Este es el que se olvida. Comprobar que la fila que se edita sea de la empresa
**no alcanza**: un PUT podría mover un manual propio *hacia* la institución de
otra empresa, que es la misma fuga por la puerta de atrás.

```sql
-- 1. ¿La fila es mía?           -> 404 si no
-- 2. ¿El destino es mío?        -> 400 si no  ← el que se olvida
-- 3. ¿Choca con el UNIQUE?      -> 409 si sí
```

En ese orden: el 404 le gana al 409, o el conflicto confirma que el id existe.

---

## 3.2 Imágenes y otros binarios

Un BLOB **no entra en un `JSON_OBJECT`**, así que no viaja en el CRUD. Va por
dos endpoints propios, como el logo en `db/empresas.sql` y la imagen en
`db/articulos.sql`.

### El `GET`: `source_type_media`, no un parámetro de salida

Esto es lo que más caro cuesta descubrir, así que va primero. Lo natural sería
un procedimiento con un `OUT BLOB` declarado como `RESPONSE`:

```sql
-- ✗ NO FUNCIONA
ORDS.DEFINE_PARAMETER(
  …, p_source_type => 'RESPONSE', p_param_type => 'BLOB', …);
```

`DEFINE_PARAMETER` valida `p_param_type` contra `REST_PARAMS_PARAM_TYPE_CK`, y
**ni `'BLOB'` ni `'RESOURCE'` pasan esa restricción**. El `ORA-02290` aborta
`PUBLICAR_ENDPOINTS` a la mitad, y como `BORRAR_MODULO` ya corrió, el módulo
queda **sin ningún endpoint** — se cae la app entera, no solo la imagen.

La forma que sí funciona es una consulta de dos columnas, content-type y BLOB:

```sql
ORDS.DEFINE_HANDLER(
  p_module_name => 'articulos',
  p_pattern     => 'imagen/:id',
  p_method      => 'GET',
  p_source_type => ORDS.source_type_media,
  p_source      => 'SELECT NVL(IMAGEN_MIME, ''image/png''), IMAGEN
                      FROM ARTICULOS
                     WHERE ID_ARTICULO = :id
                       AND IMAGEN IS NOT NULL
                       AND DBMS_LOB.GETLENGTH(IMAGEN) > 0'
);
```

Sin parámetros que declarar, así que la restricción ni entra en juego. Y el 404
sale gratis: si la consulta no devuelve filas, ORDS responde 404 solo — por eso
el `WHERE` filtra los BLOB vacíos en vez de devolverlos.

### El `GET` es público, el `PUT` no

El `GET` lo consume un `<img>`, y **el navegador no manda el header
`Authorization` al descargar una imagen**. No hay forma de autenticarlo sin
recurrir a URLs firmadas, así que el endpoint queda abierto.

Eso obliga a preguntarse qué se está exponiendo: un logo es material de marca y
no cuesta nada, pero la foto de un artículo ya es dato de negocio que cualquiera
con el id puede ver. Se aceptó porque una foto no revela precios ni stock. Si
algún día el binario fuera sensible, esta solución no sirve.

El `PUT` **sí valida token** —escribir nunca es público— y solo acepta
`image/*`: sin ese control, cualquier archivo quedaría guardado y se serviría de
vuelta con su content-type a quien abra el listado.

> **Que sea público es además lo que permite usarlo fuera de un `<img>`.** El
> logo de la empresa entra en los PDF exportados, y ahí quien baja la imagen es
> un `fetch` desde `lib/exportar.ts` — jsPDF necesita los bytes, no una URL. Con
> el endpoint detrás de token habría que resolver lo mismo dos veces. Ver la
> sección de exportación en [GUIA-FRONTEND.md](GUIA-FRONTEND.md).

### `tieneImagen` en el listado, no el binario

El listado devuelve un booleano, así el frontend sabe si pedir la imagen o
dibujar el respaldo sin traerse todos los BLOB:

```sql
'tieneImagen' VALUE CASE
                      WHEN a.IMAGEN IS NOT NULL
                       AND DBMS_LOB.GETLENGTH(a.IMAGEN) > 0
                      THEN 'true' ELSE 'false'
                    END FORMAT JSON
```

`GETLENGTH > 0` y no `IS NOT NULL`: una fila puede tener un BLOB vacío, que no
sirve como imagen y haría fallar el `<img>`.

### La columna `_MIME`

El content-type se guarda junto al binario (`LOGO_MIME`, `IMAGEN_MIME`). Sin
eso habría que adivinar el formato al servirlo, y un PNG servido como
`image/jpeg` no lo renderiza ningún navegador.

Esas columnas son la **única excepción** a la regla de no tocar el DDL, y se
agregan en un paso 0 idempotente:

```sql
DECLARE
  l_existe PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_existe
    FROM USER_TAB_COLUMNS
   WHERE TABLE_NAME = 'ARTICULOS' AND COLUMN_NAME = 'IMAGEN_MIME';

  IF l_existe = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE ARTICULOS ADD (IMAGEN_MIME VARCHAR2(100))';
  END IF;
END;
/
```

El `COUNT` no es adorno: sin él, la segunda ejecución del archivo muere con
`ORA-01430` y nada de lo que viene después llega a ejecutarse.

---

## 3.3 Cabecera y detalle: una transacción

Hasta acá cada tabla era una ficha independiente. Una **factura** no: es una
cabecera con sus líneas, y las dos partes sólo tienen sentido juntas. El modelo
está en [db/facturas-compras.sql](../db/facturas-compras.sql).

### El detalle viaja en el mismo request

**No hagas un endpoint por línea.** Guardar la cabecera y después las líneas de a
una permite que la red se corte en el medio y quede una cabecera sin detalle —que
no es una factura, es basura que después nadie sabe si está a medio cargar.

El detalle llega como un array JSON en el body:

```json
{
  "idEmpresa": 1,
  "numeroFactura": "001-001-0001234",
  "detalle": [{ "idArticulo": 5, "cantidad": 10, "precioUnitario": 5500, "idIva": 1 }]
}
```

y se recorre con `JSON_TABLE`:

```sql
FOR linea IN (
  SELECT d.nro, d.idArticulo, d.cantidad, d.precioUnitario, d.idIva
    FROM JSON_TABLE(
           p_detalle, '$[*]'
           COLUMNS (
             -- FOR ORDINALITY y no ROWNUM: da la posicion REAL dentro del
             -- array, que es la que el usuario ve en el formulario. ROWNUM se
             -- asigna al leer y puede no coincidir con el orden del JSON, asi
             -- que un mensaje de error apuntaria a la linea equivocada.
             nro            FOR ORDINALITY,
             idArticulo     NUMBER PATH '$.idArticulo',
             cantidad       NUMBER PATH '$.cantidad',
             precioUnitario NUMBER PATH '$.precioUnitario',
             idIva          NUMBER PATH '$.idIva'
           )
         ) d
) LOOP
```

**Validá cada línea dentro del bucle, no después.** Es lo que permite decir _qué_
línea está mal: "la cantidad de la línea 3 es negativa" se corrige, "hay una
cantidad negativa" obliga a buscarla.

### Sin `COMMIT` entre medio

La cabecera y el detalle van en una sola transacción. El procedimiento que guarda
el detalle **no hace `COMMIT` ni `ROLLBACK`** —eso lo maneja quien lo llama— y
devuelve el error en un `OUT` en vez de lanzar una excepción, porque el llamador
tiene que poder deshacer también la cabecera:

```sql
INSERT INTO FACTURAS_COMPRAS_CAB (...) RETURNING ID_FACTURA INTO l_id;

GUARDAR_DETALLE(l_id, l_id_empresa, p_detalle, l_lineas, l_error);

IF l_error IS NOT NULL THEN
  ROLLBACK;                    -- deshace TAMBIEN la cabecera
  p_status_code := 400;
  p_resultado := JSON_OBJECT('error' VALUE l_error);
  RETURN;
END IF;

COMMIT;
```

### `ACTUALIZAR` reemplaza el detalle entero

Borra las líneas y las reinserta. Comparar línea por línea —cuál cambió, cuál es
nueva, cuál se borró— es mucho más código para el mismo resultado en facturas de
cinco o diez líneas.

> **Consecuencia:** los `ID_DETALLE` cambian en cada edición. No importa mientras
> nada apunte al detalle; si algún día algo lo hace, esta decisión hay que
> revisarla.

Y el detalle sólo se reemplaza **si vino**: un PUT que cambia únicamente la
observación deja las líneas como estaban.

### `ELIMINAR`: detalle primero

El DDL no declara `ON DELETE CASCADE`, así que el orden lo pone el paquete. Al
revés da `ORA-02292`.

```sql
-- El subselect acota por empresa: sin eso, mandar el id de una factura ajena
-- le borraria las lineas aunque el DELETE de la cabecera no hiciera nada.
DELETE FROM FACTURAS_COMPRA_DET
 WHERE ID_FACTURA IN (
         SELECT ID_FACTURA FROM FACTURAS_COMPRAS_CAB
          WHERE ID_FACTURA = l_id AND ID_EMPRESA = l_id_empresa
       );

DELETE FROM FACTURAS_COMPRAS_CAB
 WHERE ID_FACTURA = l_id AND ID_EMPRESA = l_id_empresa;
```

### Un `OBTENER` aparte para el detalle

El `LISTAR` devuelve **sólo las cabeceras**: cien facturas con todas sus líneas
serían un CLOB enorme para dibujar una tabla que sólo muestra encabezados. El
detalle se pide con `GET /<tabla>/obtener/:id/:idEmpresa` cuando se abre una.

En ese procedimiento, **el detalle se arma aparte y se inyecta con `FORMAT JSON`**:
anidar un `JSON_ARRAYAGG` dentro del `JSON_OBJECT` de la cabecera vuelve a caer en
el límite de 4000 bytes del resultado intermedio.

### Columnas virtuales: no se insertan

Si el DDL declara una columna `GENERATED ALWAYS AS (...) VIRTUAL`, **mencionarla
en un `INSERT` o `UPDATE` da `ORA-54013`**. La calcula Oracle en cada lectura y se
lee como cualquier otra:

```sql
-- SUBTOTAL NO se menciona: es virtual (CANTIDAD * PRECIO_UNITARIO).
INSERT INTO FACTURAS_COMPRA_DET (
  ID_FACTURA, ID_ARTICULO, CANTIDAD, PRECIO_UNITARIO, ID_IVA, FECHA_CREACION
) VALUES (...);
```

Está bien que sea así: no hay forma de que quede desincronizada de sus factores.

---

## 3.4 Columnas calculadas: lo que no se guarda

**Si se puede derivar, se deriva.** Es una regla que ya aparecía en el stock de un
artículo y que las tablas nuevas repiten:

| Dato                        | Cómo se obtiene                      | Por qué no se guarda                                                |
| --------------------------- | ------------------------------------ | ------------------------------------------------------------------- |
| Stock de un artículo        | Hoy nada lo mueve — ver [3.6](#36-transacciones-que-mueven-stock-o-plata) | Va a ser una columna real (`EXISTENCIAS.CANTIDAD`) con su kardex al lado |
| Total de una factura        | `SUM(SUBTOTAL)` de su detalle        | La cabecera podría decir 500.000 y las líneas sumar 480.000         |
| Diferencia de un inventario | `CANTIDAD_FISICA - CANTIDAD_SISTEMA` | Tres columnas derivables entre sí son tres que pueden contradecirse |
| Vencimiento de una factura  | `FECHA_FACTURA + DIAS_PAGO`          | Se desfasa si se corrige la fecha o la condición                    |
| IVA de una línea            | Ver abajo                            | Depende de la tasa, que puede corregirse                            |
| Cobrado de una venta        | `SUM(MONTO)` de `VENTAS_COBROS`      | Una columna podría contradecir a los cobros que la respaldan        |
| Saldo pendiente             | `total - cobrado`                    | Es la resta de dos derivados: guardarla suma un tercer desacuerdo   |
| Pagado de una compra        | `SUM(MONTO)` de `..._PAGOS`          | Ídem, en espejo                                                     |

**`VENTAS_CABECERAS` y `FACTURAS_COMPRAS_CAB` no tienen ninguna columna de
monto.** Total, descuento, gravado, IVA, cobrado y saldo salen todos del detalle
en cada consulta. Las cabeceras guardan **qué** es la operación —quién, cuándo,
con qué comprobante— y el detalle guarda **cuánto**.

**La contrapartida:** editar una tasa de IVA o una condición de pago cambia
retroactivamente el desglose y el vencimiento de todas las facturas que las usan
—incluidas las de períodos ya declarados—. No se bloquea, porque corregir algo
mal cargado es válido, pero **el listado devuelve `usos`** para que la pantalla
avise con el número concreto antes de guardar.

### La excepción: cuando el dato es una foto

`INVENTARIOS.CANTIDAD_SISTEMA` **sí se guarda**, y es lo correcto: es lo que el
sistema creía que había **al momento de contar**. Si se recalculara contra el lote
en cada consulta, la diferencia se movería sola entre que se cuenta y se procesa,
y el registro dejaría de probar nada.

La regla completa es: **derivá lo que describe el presente, guardá lo que
describe un momento**.

### IVA: los precios lo incluyen

En Paraguay se factura con IVA incluido, así que el impuesto **se divide**, no se
multiplica. La tabla `IVA` guarda dos divisores además del porcentaje:

```sql
-- Con GRAVADA_DIVISION cargada (metodo actual):
GRAVADO = ROUND(SUBTOTAL / GRAVADA_DIVISION, 2)   -- 1.1 al 10%
IVA     = SUBTOTAL - GRAVADO

-- Sin ella (tasas anteriores a esa columna):
IVA     = ROUND(SUBTOTAL / IVA_DIVISION, 2)       -- 11 al 10%
GRAVADO = SUBTOTAL - IVA
```

**Nunca `SUBTOTAL * PORCENTAJE / 100`**: con 110.000 al 10% daría 11.000 en vez de
10.000 — cobra impuesto sobre impuesto.

> **Por qué uno se divide y el otro se resta:** las dos divisiones redondean por
> separado y sus redondeos son independientes, así que su suma no tiene por qué
> dar el subtotal. Con una división y una resta, `gravado + iva = total` siempre.
> En un libro de compras una diferencia de un guaraní por línea se acumula.

Tres cosas para no equivocarse:

- **La elección del método es por fila**, con un `CASE` sobre `GRAVADA_DIVISION`,
  no global: las tasas viejas siguen mostrando lo mismo que antes.
- **La exenta usa criterios opuestos**: `IVA_DIVISION` va en **0** y
  `GRAVADA_DIVISION` en **1**. Ninguno de los dos falla visiblemente si se
  invierten — dan cifras mal.
- **Toda división va con `NULLIF(..., 0)`**, o la exenta mata la consulta con
  `ORA-01476`.

Y si el frontend replica el cálculo para mostrarlo en vivo, **tiene que replicar
también los redondeos**: si no, el total que se ve al cargar difiere del que
muestra la factura ya guardada, y esa diferencia es imposible de explicar.

---

## 3.5 Máquinas de estado y triggers

`INVENTARIOS` es la primera tabla con estados y transiciones:

```
ABIERTO ──> PROCESADO   (aplica el conteo al lote)
        └─> ANULADO     (lo descarta sin tocar nada)
```

### Las reglas van en la base, los mensajes en el paquete

Los triggers imponen las transiciones con `RAISE_APPLICATION_ERROR`, y está bien
que sea así: **valen aunque alguien toque la tabla por fuera de la API**.

Lo que hace el paquete es **chequear antes** para devolver un 409 con un mensaje
legible, en vez de dejar salir un `ORA-20002` crudo como error 500:

```sql
-- Se lee el estado ANTES de intentar el UPDATE, y acotado por empresa. Dos
-- motivos: distinguir "no existe / no es tuya" (404) de "ya estaba procesado"
-- (409), y poder decir QUE estado tenia.
SELECT ESTADO INTO l_estado
  FROM INVENTARIOS
 WHERE ID_INVENTARIO = l_id AND ID_EMPRESA = l_id_empresa;

IF l_estado != 'ABIERTO' THEN
  p_status_code := 409;
  p_resultado := JSON_OBJECT('error' VALUE 'El inventario ya esta ' || LOWER(l_estado));
  RETURN;
END IF;
```

Los dos controles no sobran: **el del paquete es para que se entienda, el del
trigger es el que no se puede esquivar**. Y el `WHEN OTHERS` traduce igual los
`ORA-20001..20003` a 409, por si otra sesión cambió la fila entre el `SELECT` y el
`UPDATE`.

### El `UPDATE` repite el `WHERE` del `SELECT`

Entre leer y escribir hay una ventana en la que otra sesión pudo tocar la fila:

```sql
UPDATE INVENTARIOS
   SET ESTADO = p_estado_destino, ID_USUARIO = NVL(l_id_usuario, ID_USUARIO)
 WHERE ID_INVENTARIO = l_id
   AND ID_EMPRESA    = l_id_empresa
   AND ESTADO        = 'ABIERTO';   -- <- lo que el SELECT ya verifico

IF SQL%ROWCOUNT = 0 THEN
  -- La fila existe pero ya no esta ABIERTA: es 409, no 404.
  ROLLBACK;
  p_status_code := 409;
  p_resultado := '{"error":"El inventario cambio de estado, volve a cargar la pagina"}';
  RETURN;
END IF;
```

### Un trigger inválido bloquea toda la tabla

Si un trigger referencia una columna que ya no existe, **no compila — y mientras
esté `INVALID` ningún `INSERT` ni `UPDATE` sobre esa tabla funciona**. Es lo que
pasó cuando el DDL de `INVENTARIOS` reemplazó `USUARIO_PROCESA` por `ID_USUARIO`
sin actualizar `TRG_INVENTARIOS_BIU`.

Verificalo siempre después de un cambio de columnas:

```sql
-- CERO filas. Cualquier trigger que aparezca bloquea la tabla entera.
SELECT TRIGGER_NAME, STATUS
  FROM USER_TRIGGERS
 WHERE TABLE_NAME = 'TU_TABLA'
   AND STATUS != 'ENABLED';
```

> **`TRIGGER_BODY` es de tipo `LONG`** y no se puede pasar por `UPPER()` ni
> comparar con `LIKE`: da `ORA-00932`. Para inspeccionar el cuerpo hay que usar
> `DBMS_METADATA.GET_DDL('TRIGGER', nombre)`, que devuelve un `CLOB` — **y
> filtrando por `TRIGGER_NAME` exacto**, porque Oracle no garantiza el orden de
> evaluación del `WHERE` y la función se llega a ejecutar sobre triggers de otras
> tablas, con `ORA-31603`.

### `USER` no sirve para saber quién hizo algo

Dentro de un handler de ORDS, `USER` devuelve **el esquema del workspace**: el
mismo valor para todas las filas y para todas las personas. El frontend es React
y no hay sesión de base por usuario.

Quien sabe quién es la persona es `PKG_AUTH`, vía el token — y `VALIDAR_TOKEN` ya
devuelve el `ID_USUARIO`, así que el valor a guardar es el que se tiene. Sacá esa
asignación del trigger y hacela en el paquete.

### DDL en `db/`: la excepción, con nombre distinto

La regla es que los archivos de `db/` **no administran DDL**. Cuando hay que
corregir triggers, el archivo va aparte y con otro nombre —
[`db/inventarios-triggers-ddl.sql`](../db/inventarios-triggers-ddl.sql) — para que
quede claro que no es el paquete y que se ejecuta una sola vez, antes.

Ese archivo es hoy el **único** de `db/` sin paquete ni módulo ORDS, y eso es lo
que lo justifica: la regla —un conteo cerrado no se toca, y al cerrarse escribe
`EXISTENCIAS`— tiene que valer aunque alguien corrija la tabla a mano en la hoja
SQL. Sólo el trigger garantiza que no haya puerta de atrás.

El paquete de la tabla va aparte, en
[`db/inventarios.sql`](../db/inventarios.sql), y **se ejecuta después**. No
repite las reglas: las chequea antes —con `SELECT … FOR UPDATE` sobre la fila,
para que entre leer el estado y escribirlo no se meta otra sesión— y traduce los
`ORA-201xx` que el trigger pueda tirar igual. Sin esa traducción, un
`RAISE_APPLICATION_ERROR` llega al navegador como un **500 mudo**: el mensaje que
explicaba qué hacer queda adentro del `SQLERRM` y la pantalla muestra "Error al
guardar".

```plsql
-- El código del trigger decide el status; el TEXTO es el del trigger, no uno
-- propio: dos versiones del mismo mensaje se desincronizan a la primera
-- corrección. Se le saca el prefijo "ORA-20102: " y el backtrace de abajo.
l_estado := CASE p_sqlcode
              WHEN -20102 THEN 409   -- la fila ya no está ABIERTA
              WHEN -20105 THEN 400   -- cerrar sin cantidad contada
              ...
            END;
l_mensaje := SUBSTR(p_sqlerrm, 1, INSTR(p_sqlerrm || CHR(10), CHR(10)) - 1);
l_mensaje := REGEXP_REPLACE(l_mensaje, '^ORA-[0-9]+:[[:space:]]*', '');
```

`SQLCODE` y `SQLERRM` se pasan **por parámetro** al helper que traduce: dentro de
un procedimiento llamado desde un manejador de excepciones no hay garantía de que
sigan apuntando al error original.

---

## 3.5.1 El DDL manda, no los comentarios

Los archivos de `db/` **no crean tablas**: el DDL se administra aparte. Eso
significa que el archivo describe la tabla **de memoria**, y esa descripción
puede quedar desactualizada.

> **Antes de asumir que una columna es obligatoria, mirá el DDL real.**

Pasó con `VENTAS_CABECERAS.ID_LISTA_DESCUENTOS`. Tres capas la trataban como
obligatoria y el punto de venta no dejaba cobrar sin elegir una lista de
descuentos — el cajero tenía que crear una lista de 0% para poder facturar. El
DDL decía:

```sql
"ID_LISTA_DESCUENTOS" NUMBER,   -- sin NOT NULL: siempre aceptó NULL
```

La restricción no existía en la base. Estaba sólo en el código, y el
`COMMENT ON COLUMN` de la tabla decía `OBLIGATORIO` contradiciendo a la columna.

**Las consultas que lo resuelven:**

```sql
-- ¿Esta columna acepta NULL?
SELECT COLUMN_NAME, NULLABLE, DATA_TYPE, DATA_LENGTH
  FROM USER_TAB_COLUMNS
 WHERE TABLE_NAME = 'VENTAS_CABECERAS'
 ORDER BY COLUMN_ID;
```

Un `COMMENT` no es una restricción: describe la intención de quien lo escribió,
y puede contradecir a la columna. **La columna manda.**

Cuando un cambio necesite un `ALTER`, documentalo en la cabecera del archivo,
con la sentencia y la consulta que verifica si hace falta. Pero **verificá
primero**: el `ALTER` puede ser innecesario.

Y cuando una columna **desaparece** del DDL, la consulta de verificación se
invierte: tiene que devolver **cero filas**. Es lo que hacen hoy
`db/ventas.sql` y `db/facturas-compras.sql` con `ID_LOTE` — una columna que el
paquete ya no escribe pero que, si quedó en la tabla de una versión anterior,
sigue aceptando `INSERT` y guarda un NULL que no significa nada.

### Una FK no impide guardar NULL

Detalle de Oracle que confunde: una columna con `FOREIGN KEY` **sí acepta NULL**
mientras no tenga `NOT NULL`. La FK sólo valida las filas que traen un valor.

Por eso `ID_LISTA_DESCUENTOS` puede quedar en NULL aunque referencie a
`LISTAS_DESCUENTOS`, igual que `ID_CLIENTE` en la misma tabla.

### Un dato opcional necesita su `SELECT INTO` protegido

Al hacer opcional un parámetro, revisá si algún `SELECT ... INTO` lo usa: con la
variable en NULL no devuelve filas y lanza `NO_DATA_FOUND`, que cae en el
handler global y sale como un error equivocado.

```sql
-- ✅ El SELECT solo corre si hay dato, y su NO_DATA_FOUND dice el caso real
IF l_lista IS NOT NULL THEN
  BEGIN
    SELECT PORCENTAJE_DESCUENTO INTO l_porcentaje FROM LISTAS_DESCUENTOS
     WHERE ID_LISTA_PRECIOS = l_lista AND ID_EMPRESA = l_empresa;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    ROLLBACK; p_status_code := 400;
    p_resultado := '{"error":"La lista no existe o no esta vigente"}';
    RETURN;
  END;
END IF;
```

Sin el `IF`, pedir una venta sin lista devolvía **409 "la lista de descuentos no
existe"** — un error por un dato que justamente pasó a ser opcional. Y acordate
de sacar el dato del mensaje del handler global, que ya no puede culparlo.

---

## 3.5.2 Agregar una columna a una tabla que ya existe

El DDL se administra aparte, así que cuando aparece una columna nueva el trabajo
es **reflejarla**, no crearla. El caso que sirve de guía es `ARTICULOS.ID_MARCA`,
una FK nullable contra un catálogo.

Recorrido completo, en orden:

| Paso | Archivo          | Qué se toca                                                          |
| ---- | ---------------- | -------------------------------------------------------------------- |
| 1    | `db/[tabla].sql` | El `SELECT` del listado: campo en el `JSON_OBJECT` + `LEFT JOIN`     |
| 2    | `db/[tabla].sql` | Filtro opcional en el `WHERE` — **y en el del `COUNT`, que es otro** |
| 3    | `db/[tabla].sql` | `INSERTAR` y `ACTUALIZAR`: spec, body, conversión, `INSERT`/`UPDATE` |
| 4    | `db/[tabla].sql` | Los `p_source`, que enumeran los binds **por posición**              |
| 5    | `src/lib/api.ts` | El tipo, y los parámetros de `listar`, `crear` y `actualizar`        |
| 6    | `src/routes/…`   | Schema zod, `values`, campo, columna, filtro y mutación              |
| 7    | Otras pantallas  | Las que listan la misma tabla — `/existencias`, en este caso         |

El paso 7 es el que se olvida: `ARTICULOS` lo listan **dos** pantallas, y la
columna nueva tiene que aparecer en las dos o el reporte contradice a la ficha.

### El `LEFT JOIN` no es opcional

Una FK nullable con `JOIN` interno hace **desaparecer del listado** todas las
filas que todavía no tienen el dato — que son todas las anteriores a la columna.
Sin ningún error: simplemente devuelve menos filas.

```sql
-- MAL: los articulos sin marca dejan de existir
JOIN MARCAS mc ON mc.ID_MARCA = a.ID_MARCA

-- BIEN
LEFT JOIN MARCAS mc ON mc.ID_MARCA = a.ID_MARCA
```

### Una FK a otra tabla por empresa se valida a mano

**La FK no alcanza**: comprueba que la fila exista, no de quién es. Sin un
control propio, un artículo de la empresa A puede quedar apuntando a una marca
de la B — la pantalla no lo permite, pero el endpoint es público para cualquiera
con sesión.

```sql
-- Privado del body. TRUE si esa marca se puede usar en esa empresa.
FUNCTION MARCA_VALIDA (p_id_marca IN NUMBER, p_id_empresa IN NUMBER) RETURN BOOLEAN IS
  l_cuenta PLS_INTEGER;
BEGIN
  IF p_id_marca IS NULL THEN
    RETURN TRUE;  -- Sin marca es valido: la columna es nullable.
  END IF;

  SELECT COUNT(*) INTO l_cuenta
    FROM MARCAS
   WHERE ID_MARCA = p_id_marca
     AND (ID_EMPRESA = p_id_empresa OR ID_EMPRESA IS NULL);

  RETURN l_cuenta > 0;
END MARCA_VALIDA;
```

Se llama en un `IF` antes del `INSERT`/`UPDATE`, nunca dentro de la sentencia:
una función privada del body no se puede usar en SQL (`PLS-00231`). Es el mismo
control que `VALIDAR_COHERENCIA` hace en `db/asistencias-profesores.sql` con el
profesor y la institución.

**El `LEFT JOIN` del listado, en cambio, NO filtra por empresa.** Muestra el
nombre de la marca que la fila realmente tiene: filtrar ahí haría que un artículo
con una marca ajena —cargado antes del control— se viera _sin marca_ en vez de
con la que tiene, y eso esconde el problema en lugar de mostrarlo. El lugar de la
validación es la escritura, no la lectura.

### `NVL` en el `UPDATE` significa "no cambiar", no "desvincular"

```sql
ID_MARCA = NVL(l_id_marca, ID_MARCA)
```

Mandar la marca vacía **conserva la que tenía**. Es el criterio de todas las FK
del proyecto y hay que conocerlo: hoy no existe forma de quitarle la marca a un
artículo desde la API, y resolverlo pediría un centinela explícito (un 0) para
todas las relaciones a la vez.

### Un filtro nuevo puede pedir un índice nuevo

`?idMarca=` recorre `ARTICULOS` por una columna que el DDL **no** indexó —sí
tiene `IDX_ARTICULOS_CATEGORIA`, `_EMPRESA`, `_UNIDAD` y `_MONEDA`—. Con pocas
filas no se nota. Se anota en el bloque de verificación del archivo, para que
esté a mano cuando moleste:

```sql
-- CREATE INDEX IDX_ARTICULOS_MARCA ON ARTICULOS (ID_MARCA);
```

No se ejecuta desde `db/`: esos archivos no administran el DDL.

### Verificar que la columna existe, antes que nada

Si el `ALTER TABLE` no se corrió, el SQL estático que la nombra falla con
`ORA-00904` y **el paquete entero queda `INVALID`** — o sea que deja de andar
todo, no sólo lo nuevo. Va en el bloque de verificación del archivo:

```sql
SELECT COLUMN_NAME, NULLABLE, DATA_TYPE
  FROM USER_TAB_COLUMNS
 WHERE TABLE_NAME = 'ARTICULOS' AND COLUMN_NAME = 'ID_MARCA';
```

---

## 3.5.3 Agregar un parámetro a un `LISTAR` que ya usan varias pantallas

Distinto de agregar una columna: acá no hay dato nuevo, hay una **firma que
cambia**. Y una firma de `LISTAR` es un contrato compartido — `/articulos/listar`
lo consumen siete pantallas y `/ubicaciones/listar` cinco.

### El parámetro nuevo va ÚLTIMO entre los `IN`, y con `DEFAULT`

Un parámetro obligatorio en el medio **invalida toda llamada con la firma vieja**.
Y hay un instante en que eso pasa de verdad: entre que se compila el paquete y
`PUBLICAR_ENDPOINTS` republica el módulo, el handler publicado todavía manda los
argumentos viejos. Ahí no se cae sólo lo nuevo — se caen las siete pantallas.

```plsql
-- MAL: en el medio y sin default. Toda llamada posicional vieja deja de compilar.
p_id_marca      IN  VARCHAR2,
p_id_ubicacion  IN  VARCHAR2,
p_id_sucursal   IN  VARCHAR2,

-- MAL TAMBIÉN: el DEFAULT en el medio NO cubre nada en una llamada posicional,
-- sólo alcanza a los argumentos FINALES. Da la misma rotura, con la falsa
-- sensación de estar protegido.
p_id_ubicacion  IN  VARCHAR2 DEFAULT NULL,
p_id_sucursal   IN  VARCHAR2,

-- BIEN: último de los IN, antes de los OUT.
p_pagina        IN  VARCHAR2,
p_tamanio       IN  VARCHAR2,
p_id_ubicacion  IN  VARCHAR2 DEFAULT NULL,
p_status_code   OUT NUMBER,
```

Queda fuera del orden lógico de los demás filtros, y está bien que así sea: la
posición es parte del arreglo, no un descuido de estilo. Un `DEFAULT` seguido de
parámetros `OUT` es válido en PL/SQL — `PKG_AUTH.CREAR_TOKEN` ya lo hace.

> Al reejecutar, pegar **el archivo entero**: compila el paquete y republica el
> módulo de una. Y revisar que el `p_source` del handler enumere los binds en el
> **mismo orden nuevo** — es un string, nadie lo valida hasta que falla.

### Filtrar por una tabla de cruce: `EXISTS`, nunca `JOIN`

Cuando el filtro no es una columna propia sino una relación N:M —"qué artículos
hay en este estante"— un `JOIN` **duplica filas**: un artículo asignado a tres
ubicaciones aparece tres veces, y el `COUNT` del paginador dice cualquier cosa.

```sql
AND (l_id_ubicacion IS NULL
     OR EXISTS (SELECT 1 FROM ARTICULOS_UBICACIONES au
                 WHERE au.ID_ARTICULO  = a.ID_ARTICULO
                   AND au.ID_UBICACION = l_id_ubicacion))
```

Va idéntico en el `WHERE` de la consulta **y en el del `COUNT`**. Si filtran
distinto, el total dice una cosa y las filas otra, y el "Mostrar más" ofrece
páginas vacías.

### Un flag booleano se recibe como `VARCHAR2`, no como `BOOLEAN`

**Un `BOOLEAN` de PL/SQL no se puede usar dentro de una sentencia SQL.** Si el
flag va a terminar en un `WHERE` —que es para lo que suele existir— declararlo
`BOOLEAN` hace que el paquete no compile.

```plsql
-- MAL: l_solo_con es BOOLEAN y abajo entra en un WHERE.
l_solo_con BOOLEAN := UPPER(TRIM(p_con_articulos)) = 'S';

-- BIEN
l_solo_con VARCHAR2(1) := CASE WHEN UPPER(TRIM(p_con_articulos)) = 'S'
                               THEN 'S' ELSE 'N' END;
...
AND (l_solo_con = 'N' OR EXISTS (...))
```

Es la misma familia de trampas que los helpers privados en SQL (`PLS-00231`): lo
que vive sólo en PL/SQL no cruza al motor SQL.

### Un filtro nuevo no cambia el comportamiento por defecto

`?conArticulos=S` recorta; ausente, el listado devuelve lo de siempre. Eso es lo
que permite que las cinco pantallas que ya lo usaban sigan igual sin tocarlas —
y es deliberado que el ABM de la propia tabla **no** lo use: ahí las filas vacías
son justamente las que se pueden editar o borrar sin romper nada.

---

## 3.6 Transacciones que mueven stock o plata

Comprar hace entrar mercadería, vender la saca, cobrar y pagar mueven dinero.
Todas comparten la misma regla:

> **Lo que una operación movió, su baja tiene que revertirlo — o la baja se
> rechaza.**

### Comprar crea lotes; vender los descuenta

Cada línea de una factura de compra crea **su propio lote**, con la cantidad y el
precio unitario como costo. Uno por línea y no acumulado en uno existente: cada
compra entró a un precio distinto, y mezclarlas perdería a cuánto entró cada
unidad.

Cada línea de venta descuenta de **un solo lote**, el que elige el cajero.
`VENTAS_DETALLES.ID_LOTE` guarda cuál, y `FACTURAS_COMPRAS_DET.ID_LOTE` guarda el
que la compra creó. Las dos columnas existen por el mismo motivo:

> **Sin registrar de qué lote salió cada unidad, la baja no sabe dónde
> reponerla.** `CANTIDAD_DISPON` es una columna real, no se deriva de nada: si se
> pierde el vínculo, el stock queda por debajo del físico para siempre y sólo se
> descubre en el próximo inventario.

### Se lee con `FOR UPDATE`, siempre

Entre leer un saldo y grabar el movimiento puede entrar otra caja. Sin el lock,
las dos ven existencia o saldo suficiente y las dos graban:

```sql
-- El lock va sobre la CABECERA aunque el monto salga del detalle: es lo que
-- serializa los movimientos de esa operación.
SELECT ID_VENTA INTO l_existe
  FROM VENTAS_CABECERAS
 WHERE ID_VENTA = l_id AND ID_EMPRESA = l_empresa
   FOR UPDATE;

SELECT NVL(SUM(TOTAL), 0) INTO l_total FROM VENTAS_DETALLES WHERE ID_VENTA = l_id;
SELECT NVL(SUM(MONTO), 0) INTO l_cobrado FROM VENTAS_COBROS WHERE ID_VENTA = l_id;
```

### Cuándo rechazar con 409

| Situación                                      | Por qué no se permite                                  |
| ---------------------------------------------- | ------------------------------------------------------ |
| Borrar una venta con cobros                    | El `DELETE` en cascada se lleva plata que entró        |
| Borrar o editar una compra con pagos           | Ídem, y rehacer cuotas rompería la FK de los pagos     |
| Borrar o editar una compra ya vendida en parte | Sacar del stock lo que ya salió lo deja bajo el físico |
| Cobrar o pagar de más                          | El saldo quedaría negativo                             |
| Vender más de lo que tiene el lote             | No hay existencia que descontar                        |

En todos los casos el mensaje dice **qué hacer**, no sólo que no se puede:
`"La venta tiene cobros registrados: anulalos antes de eliminarla"`.

### Lo que la baja no deshace, se avisa

Eliminar una venta **no devuelve el número de comprobante**: `NRO_ACTUAL` del
talonario ya avanzó y la secuencia queda con un hueco. Fiscalmente es lo
correcto —un comprobante emitido no se reutiliza— pero la pantalla tiene que
decirlo antes de confirmar, no descubrirse después.

> Los helpers que aparecen acá —`ESTADO_CUOTA`, `TIENE_SALIDAS`— son funciones
> privadas del body, y llamarlas desde un `UPDATE` no compila. Ver
> [3.7 Trampas de PL/SQL](#37-trampas-de-plsql-que-se-repiten).

### Reponer agrupando, no fila por fila

Dos líneas distintas pueden salir del mismo lote. Sumar de a una hace dos
`UPDATE` sobre la misma fila, y el segundo lee el valor viejo:

```sql
FOR reposicion IN (SELECT ID_LOTE, SUM(CANTIDAD) AS cantidad
                     FROM VENTAS_DETALLES WHERE ID_VENTA = l_id AND ID_LOTE IS NOT NULL
                    GROUP BY ID_LOTE) LOOP
  UPDATE LOTES SET CANTIDAD_DISPON = NVL(CANTIDAD_DISPON, CANTIDAD) + reposicion.cantidad
   WHERE ID_LOTE = reposicion.ID_LOTE;
END LOOP;
```

---

## 3.7 Trampas de PL/SQL que se repiten

Cuatro errores de compilación que aparecieron más de una vez en este proyecto. No
son casos raros: salen del estilo normal del código de acá —helpers privados y
`JSON_OBJECT` para armar la respuesta— así que conviene reconocerlos de memoria.

Las tres primeras son la misma idea vista de tres formas: **lo que vive sólo en
PL/SQL no cruza al motor SQL**. Ni una función del body, ni un `BOOLEAN`.

### Un `BOOLEAN` no se puede usar dentro de una sentencia SQL

Aparece al recibir un flag por parámetro y usarlo en un `WHERE`:

```plsql
-- MAL: el paquete no compila
l_solo_con BOOLEAN := UPPER(TRIM(p_con_articulos)) = 'S';
...
AND (NOT l_solo_con OR EXISTS (...))

-- BIEN: VARCHAR2 con el mismo criterio 'S'/'N' del resto del proyecto
l_solo_con VARCHAR2(1) := CASE WHEN UPPER(TRIM(p_con_articulos)) = 'S'
                               THEN 'S' ELSE 'N' END;
...
AND (l_solo_con = 'N' OR EXISTS (...))
```

Un `BOOLEAN` sí sirve para un `IF` o para el retorno de un helper que se llama
desde PL/SQL — `ERROR_DE_NEGOCIO` en `db/inventarios.sql` devuelve uno. El
problema es únicamente cruzarlo a SQL.

### `PLS-00231`: una función privada del _body_ no se puede usar en SQL

Sólo las declaradas en el **spec** del paquete valen dentro de una sentencia SQL.
Una función definida sólo en el body sirve para PL/SQL, no para el `SET` de un
`UPDATE` ni el `VALUES` de un `INSERT`:

```sql
-- MAL: PLS-00231
UPDATE CUOTAS SET ESTADO = ESTADO_CUOTA(l_pagado, l_monto) WHERE ...;
INSERT INTO PAGINAS (RUTA) VALUES (NORMALIZAR_RUTA(p_ruta));

-- BIEN: se calcula antes, y en la sentencia va la variable
l_estado := ESTADO_CUOTA(l_pagado, l_monto);
UPDATE CUOTAS SET ESTADO = l_estado WHERE ...;

l_ruta := NORMALIZAR_RUTA(p_ruta);
INSERT INTO PAGINAS (RUTA) VALUES (l_ruta);
```

**Declararla en el spec también compila**, pero publica un detalle interno en la
interfaz del paquete. Preferir la variable, salvo que la función sea realmente
parte de la API.

> Este error se cometió **dos veces**, la segunda después de haber escrito esta
> misma nota. Si estás por llamar un helper dentro de una sentencia SQL, mirá
> primero dónde está declarado.

### `ORA-00942`: un nombre de tabla mal escrito no se ve hasta que se llama

El paquete con una tabla inexistente en SQL estático **no compila**: queda
`INVALID`, y la primera llamada devuelve `ORA-04063` que ORDS traduce a un **500
sin ningún mensaje útil**. El `WHEN OTHERS` no lo captura: el error ocurre antes
de entrar al procedimiento.

Pasó en `db/iva.sql`, que era el único archivo del backend que escribía
`FACTURAS_COMPRA_DET` en vez de `FACTURAS_COMPRAS_DET` (con S). Rompía
`/iva/listar` y `/iva/eliminar` por igual.

**Cómo se detecta al instante:** el bloque de verificación del final del archivo
ya lo dice. Por eso hay que **mirar la salida**, no sólo ejecutar:

```sql
SELECT OBJECT_TYPE, STATUS FROM USER_OBJECTS WHERE OBJECT_NAME = 'PKG_IVA';
SELECT LINE, POSITION, TEXT FROM USER_ERRORS WHERE NAME = 'PKG_IVA' ORDER BY SEQUENCE;
```

`INVALID` + un `ORA-00942` apuntando a una línea es exactamente esto.

**Cómo evitarlo:** antes de escribir un nombre de tabla que no sea la propia,
verificá cómo la escriben los demás archivos.

```sh
grep -rn "FACTURAS_COMPRAS_DET" db/ | head
```

Si tu archivo es el único que la nombra de una forma, la forma equivocada es la
tuya.

### `PLS-00684`: `RETURNING CLOB` no va en una asignación suelta

`RETURNING CLOB` sólo se acepta dentro de una sentencia SQL:

```sql
-- MAL: PLS-00684
p_resultado := JSON_OBJECT('a' VALUE 1 RETURNING CLOB);

-- BIEN
SELECT JSON_OBJECT('a' VALUE 1 RETURNING CLOB) INTO p_resultado FROM DUAL;
```

Sin `RETURNING CLOB` la asignación directa sí funciona, y es lo que hacen los
paquetes cuando la respuesta es corta:

```sql
p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
```

### `ORA-00932`: a una columna `LONG` no se le aplican funciones

`USER_TAB_COLS.DATA_DEFAULT` es `LONG`. En SQL no se puede envolver en nada; en
PL/SQL, en cambio, se lee `INTO` un `VARCHAR2` y Oracle lo convierte solo:

```sql
-- MAL: ORA-00932
SELECT ... WHERE INSTR(DATA_DEFAULT, 'MONTO_IVA') > 0;

-- BIEN
DECLARE l_def VARCHAR2(4000);
BEGIN
  SELECT DATA_DEFAULT INTO l_def FROM USER_TAB_COLS WHERE ...;
  IF INSTR(UPPER(l_def), 'MONTO_IVA') > 0 THEN ...
END;
```

---

## 3.8 Un `UNIQUE` sobre texto necesita el texto normalizado

`PAGINAS` tiene `UNIQUE (ID_MODULO, RUTA, ENTRADA)` para que la misma ruta no se
cargue dos veces en el mismo lugar. Pero la restricción compara **strings**:
`/Ventas`, `ventas` y `/ventas/` son tres valores distintos para Oracle, así que
las tres entran como páginas separadas apuntando al mismo destino. **El `UNIQUE`
no falla — simplemente no aplica.**

La restricción sólo hace lo que se espera si el valor llega en una forma
canónica. Va en una función privada, y se aplica en el alta y en la modificación:

```sql
FUNCTION NORMALIZAR_RUTA (p_ruta IN VARCHAR2) RETURN VARCHAR2 IS
  l_ruta VARCHAR2(200);
BEGIN
  l_ruta := LOWER(TRIM(p_ruta));
  IF l_ruta IS NULL THEN RETURN NULL; END IF;
  IF SUBSTR(l_ruta, 1, 1) != '/' THEN l_ruta := '/' || l_ruta; END IF;
  IF LENGTH(l_ruta) > 1 THEN l_ruta := RTRIM(l_ruta, '/'); END IF;
  RETURN NVL(NULLIF(l_ruta, ''), '/');
END NORMALIZAR_RUTA;
```

Devolver `NULL` ante `NULL` es deliberado: deja intacto el
`RUTA = NVL(l_ruta, RUTA)` del `UPDATE`, donde un parámetro ausente no modifica
la columna.

### Y el choque se traduce a 409

Sin capturarlo, el `ORA-00001` del `UNIQUE` llega al frontend como un 500
genérico y el usuario no sabe si el error es suyo o del sistema:

```sql
EXCEPTION
  WHEN DUP_VAL_ON_INDEX THEN
    ROLLBACK;
    p_status_code := 409;
    p_resultado := '{"error":"Esa ruta ya esta cargada en ese modulo y seccion"}';
```

**El mensaje dice qué hacer, no sólo que no se puede.** Y va tanto en `INSERTAR`
como en `ACTUALIZAR`: mover una página a un módulo donde esa ruta ya existe choca
con la misma restricción.

### Normalizar hacia atrás es un paso aparte

La función arregla lo que entra de ahora en más. Lo ya cargado se revisa a mano:

```sql
SELECT ID_PAGINA, ID_MODULO, RUTA FROM PAGINAS
 WHERE RUTA != LOWER(RUTA) OR RUTA LIKE '%/' OR RUTA NOT LIKE '/%';
```

---

## 4. Consumir la API desde el frontend

Agregá el bloque de la tabla nueva en [src/lib/api.ts](../src/lib/api.ts),
junto a `usuarios`:

```ts
export type Empresa = {
  id: number;
  razonSocial: string;
  ruc: string;
  // El mismo código que la columna. Para preguntar si está activa,
  // usá el helper: esActivo(empresa.activo) — no `=== 1`.
  activo: Estado;
};

export const api = {
  // … login, logout, me, usuarios …

  empresas: {
    listar: (params: { busqueda?: string; pagina?: number } = {}) => {
      const qs = new URLSearchParams();
      if (params.busqueda) qs.set("busqueda", params.busqueda);
      if (params.pagina) qs.set("pagina", String(params.pagina));
      const q = qs.toString();
      return request<{ items: Empresa[]; total: number }>(`/empresas/${q ? `?${q}` : ""}`);
    },

    obtener: (id: number) => request<Empresa>(`/empresas/${id}`),

    crear: (datos: { razonSocial: string; ruc: string }) =>
      request<{ id: number }>("/empresas/", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    actualizar: (id: number, datos: Partial<Empresa>) =>
      request<{ ok: string }>(`/empresas/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    inactivar: (id: number) =>
      request<{ ok: string }>(`/empresas/${id}/inactivar`, { method: "POST" }),
  },
};
```

`request()` ya adjunta el `Authorization`, parsea el JSON y lanza `ApiError` con
el status. Un 401 limpia el token automáticamente.

---

## 5. Devolver lo que el consumidor necesita

Un endpoint que devuelve la mitad de los campos rompe al consumidor de una
forma difícil de diagnosticar: no falla, **funciona a medias**. Pasó de verdad
con `/usuario-paginas/listar`.

### El caso: el menú que se veía pero no navegaba

`PKG_USUARIO_PAGINAS.LISTAR` devolvía `idUsuario, usuario, idPagina, pagina,
idModulo, modulo, fechaAlta`. Suficiente para la pantalla de permisos, que era
lo único que lo consumía cuando se escribió.

Cuando el menú dinámico empezó a usar el mismo endpoint, faltaban `ruta` y
`entrada`. El resultado:

- El menú **mostraba** "Base › Paises" perfectamente — `modulo` y `pagina` sí venían.
- El link no navegaba a ningún lado — `ruta` llegaba `undefined` y el frontend
  caía en un fallback `"#"`.
- **Ningún error, en ningún lado.** Ni en PL/SQL, ni en la consola del navegador.

Se buscó el problema en el CSS del menú, en el z-index, en TanStack Router y en
tres instancias del dev server corriendo a la vez. Estaba en el `JSON_OBJECT`.

### La regla

**Si el listado hace `JOIN` con una tabla, devolvé los campos de esa tabla que
el consumidor va a necesitar** — no sólo el nombre para mostrar. El `JOIN` ya
está hecho: agregar una columna al `JSON_OBJECT` no cuesta nada, y omitirla
obliga a una segunda petición o a un bug silencioso.

```sql
-- Antes: alcanzaba para la pantalla de permisos, rompía el menú
SELECT JSON_ARRAYAGG(
         JSON_OBJECT(
           'idPagina' VALUE up.ID_PAGINA,
           'pagina'   VALUE p.NOMBRE,
           'modulo'   VALUE m.NOMBRE
           RETURNING CLOB)
         RETURNING CLOB)
  INTO l_items
  FROM USUARIO_PAGINAS up
  JOIN PAGINAS p ON p.ID_PAGINA = up.ID_PAGINA
  JOIN MODULOS m ON m.ID_MODULO = p.ID_MODULO;

-- Después: RUTA y ENTRADA salen del mismo JOIN que ya estaba
SELECT JSON_ARRAYAGG(
         JSON_OBJECT(
           'idPagina'    VALUE up.ID_PAGINA,
           'pagina'      VALUE p.NOMBRE,
           'ruta'        VALUE p.RUTA,      -- adónde navega
           'entrada'     VALUE p.ENTRADA,   -- bajo qué sección agrupa
           'orden'       VALUE p.ORDEN,     -- en qué posición
           'modulo'      VALUE m.NOMBRE,
           'moduloIcono' VALUE m.ICONO      -- con qué ícono
           RETURNING CLOB)
         RETURNING CLOB)
  INTO l_items
  FROM USUARIO_PAGINAS up
  JOIN PAGINAS p ON p.ID_PAGINA = up.ID_PAGINA
  JOIN MODULOS m ON m.ID_MODULO = p.ID_MODULO;
```

### Cómo evitarlo

**El tipo de TypeScript es el contrato.** Cuando agregues un campo al
`JSON_OBJECT`, agregalo también al tipo en `src/lib/api.ts`. Si el frontend usa
un campo que el tipo no declara, `npx tsc --noEmit` lo marca:

```
Property 'ruta' does not exist on type 'UsuarioPagina'.
```

Ese error estuvo visible todo el tiempo. **Corré `npx tsc --noEmit` antes de
dar por perdido un bug raro de UI** — el compilador suele saber la respuesta.

### Un cambio en `db/` no existe hasta reejecutarlo

Editar el `.sql` del repo no cambia nada por sí solo: ORDS sólo conoce lo que
se ejecutó en APEX. Después de tocar un archivo `db/`:

1. **Frená `npm run dev`** — la sesión dev mantiene tomadas las filas de
   metadatos que `DELETE_MODULE` necesita, y sin eso da `ORA-00060` con el
   endpoint viejo todavía publicado.
2. Ejecutá el archivo completo en la hoja de trabajo SQL de APEX.
3. Revisá las consultas de verificación del final.

---

## 6. Seguridad

**Nunca devuelvas `CONTRASENA_HASH` ni `SALT`.** Ningún `SELECT` de un handler
debe incluirlos.

**Mensajes genéricos en el login.** Distinguir "no existe" de "clave incorrecta"
permite enumerar cuentas válidas. `/auth/login` responde el mismo 401 en los
tres casos: usuario inexistente, clave incorrecta y cuenta inactiva.

**Todo handler que no sea login valida el token**, con
`PKG_AUTH.VALIDAR_TOKEN`. Esa función comprueba además que la cuenta siga
activa, no sólo que el token no haya vencido.

### Autenticar no es autorizar: lo administrativo pide `VALIDAR_TOKEN_ADMIN`

`VALIDAR_TOKEN` responde "¿quién sos?". No responde "¿podés hacer esto?".

> **Regla: si la operación sólo tiene sentido para un administrador, el handler
> valida con `PKG_AUTH.VALIDAR_TOKEN_ADMIN` y responde 403, no 401.**

```sql
-- Autenticación: cualquier usuario con sesión.
l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
IF l_sesion IS NULL THEN
  p_status_code := 401;
  p_resultado := '{"error":"Sesion invalida o vencida"}';
  RETURN;
END IF;

-- Autorización: además, que sea admin.
l_sesion := PKG_AUTH.VALIDAR_TOKEN_ADMIN(PKG_AUTH.TOKEN_DE_HEADER(p_authorization));
IF l_sesion IS NULL THEN
  p_status_code := 403;
  p_resultado := '{"error":"Se requieren permisos de administrador"}';
  RETURN;
END IF;
```

**401 y 403 no son lo mismo, y el frontend los trata distinto.** Un 401 limpia
el token y manda al login (la sesión murió); un 403 sólo muestra el mensaje (la
sesión está viva, lo que falta es el permiso). Devolver 401 por falta de
permisos desloguearía a alguien que tiene la sesión perfectamente válida.

**Esconder la pantalla en el frontend no es seguridad.** La página de
Administración ya redirigía a `/home` a quien no fuera admin, y aun así
cualquier usuario con sesión podía hacer `GET /usuarios/listar` con su propio
token y recibir la lista completa de cuentas —nombres, correos y quién es
administrador—, que es justo el mapa que hace falta para elegir a quién atacar.
Peor todavía: `POST /usuario-paginas/crear` le permitía **asignarse a sí mismo
cualquier página, incluida Administración**, escalando privilegios con una sola
petición. El guard del cliente evita el acceso accidental; el del backend evita
el deliberado.

Hoy validan como administrativos:

| Archivo               | Alcance                                         |
| --------------------- | ----------------------------------------------- |
| `usuarios.sql`        | los 4 procedimientos                            |
| `modulos.sql`         | los 4                                           |
| `paginas.sql`         | los 4                                           |
| `usuario-paginas.sql` | `ASIGNAR` y `QUITAR`; `LISTAR` es mixto (abajo) |

**El caso mixto: cada uno ve lo suyo, un admin ve el de cualquiera.**
`usuario-paginas/listar` alimenta **el menú de todos los usuarios** —cada uno
pidiendo sus propios permisos— y además el ABM de Permisos. Restringirlo a
admins dejaría sin menú a todo el mundo. La regla que cubre los dos usos se
resuelve dentro del procedimiento:

```sql
-- Pedir los permisos de OTRO usuario (o los de todos) es administrativo.
IF (l_id_usuario IS NULL OR l_id_usuario != l_sesion)
   AND NOT PKG_AUTH.ES_ADMINISTRADOR(l_sesion) THEN
  p_status_code := 403;
  …
END IF;
```

Cuando un endpoint sirve a dos consumidores con distinto nivel de privilegio,
el control va sobre **el parámetro**, no sobre el endpoint entero.

**Inactivar o eliminar un usuario revoca sus tokens**, con
`PKG_AUTH.REVOCAR_TOKENS_USUARIO`. Sin eso seguiría navegando con la sesión que
ya tenía abierta.

**El hash se genera con `PKG_AUTH.HASH_PASSWORD`,** nunca reimplementándolo en
otro paquete. Si el alta calculara el hash distinto del login, el usuario se
crearía sin poder entrar.

**Nada de credenciales en el repo.** Para el frontend, sólo variables `VITE_*`
que sean públicas por definición. Los datos que sí requieren generarse al
azar (como una contraseña inicial) se imprimen por `DBMS_OUTPUT` en el
momento, nunca hardcodeados en el script.

### Aislamiento por empresa: filtrar el listado no alcanza

> **Regla: en una tabla por empresa, `ACTUALIZAR` y `ELIMINAR` exigen
> `idEmpresa` y lo llevan en el `WHERE`. Es una condición sobre QUÉ fila se
> toca, no un campo más a modificar.**

El listado ya se filtra con `?idEmpresa=`, y es fácil suponer que con eso
alcanza. No alcanza: eso decide lo que **se muestra**, no lo que se **puede
tocar**.

```sql
-- ❌ Cualquiera con sesión modifica el artículo 57, sea de la empresa que sea.
UPDATE ARTICULOS
   SET NOMBRE_ARTICULO = NVL(TRIM(p_nombre_articulo), NOMBRE_ARTICULO), …
 WHERE ID_ARTICULO = l_id;

-- ✅ El idEmpresa acota la fila.
UPDATE ARTICULOS
   SET NOMBRE_ARTICULO = NVL(TRIM(p_nombre_articulo), NOMBRE_ARTICULO), …
 WHERE ID_ARTICULO = l_id
   AND ID_EMPRESA  = l_id_empresa;
```

La pantalla no permite llegar ahí —sólo lista lo de tu empresa— pero el
endpoint es público para cualquiera con sesión. **El guard del cliente evita el
acceso accidental; sólo el del backend evita el deliberado.**

**Tres cosas que cierran la puerta de atrás:**

**1. `ID_EMPRESA` no va en el `SET`.** Si se puede modificar, se puede **mover
una fila a otra empresa**, que es lo mismo que el `WHERE` estaba impidiendo. En
`SUCURSALES` era lo más grave: arrastraría con ella todas sus ubicaciones y
lotes.

**2. La respuesta es 404, no 403.** Decir "existe pero no es tuya" confirma que
el id existe — información que quien pregunta no debería obtener:

```sql
IF SQL%ROWCOUNT = 0 THEN
  p_status_code := 404;              -- vale para "no existe" Y "es de otra"
  p_resultado := '{"error":"El articulo no existe"}';
  RETURN;
END IF;
```

**3. Las FK de destino también se validan.** Reasignar una denominación a una
moneda ajena, o un lote a un artículo de otra empresa, es la misma fuga por
otro camino.

#### Si la tabla no tiene `ID_EMPRESA`

Las de detalle y las de cruce heredan la empresa del padre. Ahí se valida con
una función privada **antes** de escribir:

```sql
FUNCTION ES_DE_EMPRESA (p_id_detalle IN NUMBER, p_id_empresa IN NUMBER)
  RETURN BOOLEAN IS
  l_existe PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_existe
    FROM DETALLE_MONEDAS d
    JOIN MONEDAS         m ON m.ID_MONEDA = d.ID_MONEDA
   WHERE d.ID_DETALLE_MONEDA = p_id_detalle
     AND m.ID_EMPRESA        = p_id_empresa;
  RETURN l_existe > 0;
END ES_DE_EMPRESA;
```

Es el mismo patrón de `SUCURSAL_ES_DE_EMPRESA` en `db/ubicaciones.sql`.

#### La ruta del borrado cambia

El `idEmpresa` va en la URL, porque un `DELETE` no lleva body:

```
DELETE /<tabla>/eliminar/:id/:idEmpresa
```

Y el cliente lo pasa desde la entidad, que ya lo trae — es más preciso que la
empresa activa:

```ts
mutationFn: (articulo: Articulo) => api.articulos.eliminar(articulo.id, articulo.idEmpresa),
```

> **Los catálogos globales quedan afuera**: `PAISES`, `DEPARTAMENTOS`,
> `CIUDADES`, `MODULOS`, `PAGINAS` y `USUARIOS` no cuelgan de ninguna empresa.
> `EMPRESAS` tampoco — ahí `ID_EMPRESA` es la PK, no una FK.

**CORS en producción se habilita en APEX, no con un proxy — y es POR MÓDULO.**
ORDS no manda `Access-Control-Allow-Origin` por defecto, y `src/lib/api.ts`
pega directo a `oracleapex.com` cuando `import.meta.env.DEV` es falso. Los
orígenes permitidos son `https://www.ctell.online` (producción) y
`http://localhost:8080` (desarrollo, sólo si se prueba sin el proxy de Vite).

A pesar de que la pantalla en APEX se llama _Administración del Workspace →
RESTful Services → orígenes permitidos_ —lo que sugiere un ajuste global—,
`ORIGINS_ALLOWED` se guarda **por módulo**, no a nivel de workspace. Cargarlo
para `auth` no lo propaga a `usuarios` ni a ningún módulo nuevo: hay que
repetirlo en cada uno con `ORDS.SET_MODULE_ORIGINS_ALLOWED(p_module_name,
p_origins_allowed)`, llamado aparte de `ORDS.DEFINE_MODULE` (no es un
parámetro de esa llamada). Cada archivo `db/<tabla>.sql` lo declara al lado
de su `DEFINE_MODULE` — ver `db/auth.sql` para el ejemplo.

Sin ese origen cargado en el módulo correspondiente, la petición ni siquiera
llega al handler: ORDS la rechaza con un "Service Unavailable" genérico antes
de ejecutar el PL/SQL, así que el `WHEN OTHERS` con `SQLERRM` tampoco ayuda a
diagnosticarlo — este fue justamente el origen de un 500 real en producción
que costó varias vueltas encontrar.

---

## 6.1 Enviar correo desde un handler

El sistema manda la contraseña por mail en dos momentos: al crear un usuario
(`PKG_USUARIOS.INSERTAR`) y al recuperar el acceso (`PKG_AUTH.RECUPERAR_PASSWORD`).
Los dos pasan por `PKG_AUTH.ENVIAR_PASSWORD_INICIAL`.

### Un handler de ORDS no está parado en ningún workspace

`APEX_MAIL` necesita saber bajo qué workspace corre. Un handler de ORDS no lo
establece, así que hay que fijarlo **antes** de llamar a `SEND` o el envío muere
con:

```
ORA-20987: APEX - El identificador de grupo de seguridad (identidad de espacio
de trabajo) no es válido.
```

La forma correcta es fijar el security group id, resolviéndolo **por nombre** de
workspace:

```sql
l_security_group_id := APEX_UTIL.FIND_SECURITY_GROUP_ID(p_workspace => 'CTELL');
APEX_UTIL.SET_SECURITY_GROUP_ID(p_security_group_id => l_security_group_id);
```

Está encapsulado en `PKG_AUTH.ESTABLECER_WORKSPACE_MAIL`: cualquier procedimiento
que mande correo lo llama primero y no repite estas dos líneas.

> **No uses `APEX_SESSION.CREATE_SESSION` para esto.** Crear sesión exige una
> aplicación APEX, y **este workspace no tiene ninguna** — el frontend es React.
> El código llamaba a `CREATE_SESSION` con un `p_app_id => 100` inventado, esa
> app no existía, y **ningún correo se envió nunca**. Peor: el `WHEN OTHERS` de
> `ENVIAR_PASSWORD_INICIAL` se tragaba el `ORA-20987` y devolvía `'I'` en
> silencio, así que el alta funcionaba y el correo desaparecía sin dejar rastro.
>
> Tampoco hardcodees el security group id: es un número de 20 dígitos que cambia
> si el workspace se recrea. Resolvelo por nombre, que es lo que hace
> `FIND_SECURITY_GROUP_ID`.

### El resto del envío

```sql
APEX_MAIL.SEND(p_to => …, p_from => NULL, p_body => …, p_subj => …);
APEX_MAIL.PUSH_QUEUE;   -- sin esto queda encolado hasta el próximo barrido
COMMIT;                 -- APEX_MAIL escribe en APEX_MAIL_QUEUE
```

- **`p_from => NULL`**: lo resuelve APEX con el parámetro de instancia
  `EMAIL_FROM`. En el free tier Oracle sólo acepta como origen el correo de la
  cuenta; una dirección ajena se rechaza y el mensaje **ni siquiera se encola**
  (por eso `APEX_MAIL_QUEUE` y `APEX_MAIL_LOG` aparecen vacías).
- **`PUSH_QUEUE`** fuerza la salida inmediata. Una clave que se espera al
  instante no puede quedar esperando el barrido automático.
- **`COMMIT`** o el mensaje se pierde si la transacción del handler termina en
  rollback.

### Un fallo de correo nunca deshace la operación

`ENVIAR_PASSWORD_INICIAL` **no propaga excepciones**: cuando corre, el usuario ya
está creado y confirmado, y un SMTP caído no debe deshacer una cuenta que ya
existe. Avisa por `p_enviado` (`'A'` envió / `'I'` no), y quien llama decide:

```sql
-- PKG_USUARIOS.INSERTAR: la clave se devuelve SOLO si el correo no salió.
'correoEnviado'   VALUE CASE WHEN l_enviado = 'A' THEN 'true' ELSE 'false' END,
'passwordInicial' VALUE CASE WHEN l_enviado != 'A' THEN l_password END
```

Ese `passwordInicial` es el **respaldo**: si el correo falla, nadie más conoce la
clave y la cuenta quedaría inaccesible.

`RECUPERAR_PASSWORD` no puede hacer lo mismo — devolver la clave ahí se la
regalaría a cualquiera que adivine un usuario. Responde siempre igual y anota el
fallo en el log.

### Diagnosticar cuando el correo no llega

Los envíos se tragan el error a propósito, así que **el síntoma es siempre el
mismo: no llega nada**. Para ver la causa real hay una función que corre el mismo
camino pero **devuelve** el error en vez de tragárselo:

```sql
SELECT PKG_AUTH.PROBAR_CORREO('destino@ejemplo.com') FROM DUAL;
```

Si devuelve `OK…` pero el mensaje no aparece, el problema es de entrega y no de
código — revisá la cola y el log:

```sql
SELECT MAIL_ID, MAIL_TO, MAIL_SEND_ERROR, LAST_UPDATED_ON
  FROM APEX_MAIL_QUEUE ORDER BY LAST_UPDATED_ON DESC FETCH FIRST 10 ROWS ONLY;

SELECT MAIL_ID, MAIL_TO, MAIL_SUBJECT, LAST_UPDATED_ON
  FROM APEX_MAIL_LOG ORDER BY LAST_UPDATED_ON DESC FETCH FIRST 10 ROWS ONLY;
```

En `QUEUE` con `MAIL_SEND_ERROR` = falló el envío. En `LOG` = APEX lo mandó y el
problema está del lado del destinatario (spam, o restricción del free tier sobre
direcciones no verificadas).

---

## 7. Checklist

Backend (`db/<tabla>.sql`):

- [ ] Un archivo por tabla, nombrado como la tabla
- [ ] **Todo dentro de `PKG_<TABLA>`** — ni un `CREATE PROCEDURE` suelto
- [ ] **Endpoints con nombre**: `/listar`, `/crear`, `/actualizar/:id`,
      `/eliminar/:id` — nada de `p_pattern => '.'`
- [ ] **Cada `DEFINE_HANDLER` es una línea** que invoca al paquete — nada de
      PL/SQL embebido en `q'~ … ~'`
- [ ] `BORRAR_MODULO` privado en el paquete, no un helper externo
- [ ] La única sentencia fuera del paquete es `PKG_<TABLA>.PUBLICAR_ENDPOINTS`
- [ ] `ORDS.SET_MODULE_ORIGINS_ALLOWED` para este módulo (es por módulo)
- [ ] No crea ni altera tablas
- [ ] Sin `ORDS.ENABLE_SCHEMA` ni `DBMS_CRYPTO`
- [ ] Todos los procedimientos validan el token con `PKG_AUTH.VALIDAR_TOKEN`
- [ ] **Lo administrativo valida con `PKG_AUTH.VALIDAR_TOKEN_ADMIN` y devuelve
      403**, no 401 (un 401 desloguea a quien tiene la sesión sana). Si el
      endpoint sirve a dos consumidores con distinto privilegio, el control va
      sobre el parámetro — ver [6. Seguridad](#6-seguridad)
- [ ] **Si la tabla es por empresa: `ACTUALIZAR` y `ELIMINAR` exigen
      `idEmpresa` y lo llevan en el `WHERE`**, `ID_EMPRESA` NO está en el `SET`,
      y la respuesta es 404 (no 403) cuando la fila es de otra empresa
- [ ] **Si no tiene columna `ID_EMPRESA`** (detalle o cruce): se valida contra
      el padre con un `JOIN` antes de escribir
- [ ] La ruta del borrado es `/eliminar/:id/:idEmpresa` en las tablas por
      empresa
- [ ] Los `UPDATE`/`DELETE` verifican `SQL%ROWCOUNT` (si no, un ID inexistente
      devuelve 200)
- [ ] Consultas de verificación al final (con `OBJECT_NAME`)
- [ ] **El estado es `'A'`/`'I'` en la columna, el JSON y el frontend** — sin
      traducir a 1/0 en ningún punto
- [ ] **Todos los parámetros de entrada son `VARCHAR2`**, y todo `TO_NUMBER`
      lleva `NULLIF(p_x, '')`
- [ ] `JSON_OBJECT(… RETURNING CLOB)` va dentro de un `SELECT … FROM DUAL`,
      nunca como asignación directa (`PLS-00684`)
- [ ] `NVL(l_items, TO_CLOB('[]'))` en los listados
- [ ] **Los listados con `JOIN` devuelven los campos que el consumidor necesita**,
      no sólo el nombre para mostrar (ver [5](#5-devolver-lo-que-el-consumidor-necesita))
- [ ] **`LEFT JOIN` si la FK es nullable.** Con el interno, una fila sin ese
      dato desaparece del listado sin ningún error visible
- [ ] Si es una tabla por empresa: se filtra por `?idEmpresa=` y **no** hace
      `JOIN` contra `EMPRESAS` (ver [3.1](#31-tablas-por-empresa))
- [ ] **Si tiene dos FK de contexto (empresa + sucursal): se valida a mano que
      una pertenezca a la otra** y se devuelve 400 si no. Las FK sueltas no lo
      garantizan (ver [3.1.1](#311-tablas-por-empresa-y-sucursal))
- [ ] **Si es `TALONARIOS`:** `NRO_ACTUAL` inicia dentro de
      `[NRO_INICIAL, NRO_FINAL]`; sus datos fiscales sólo se copian a Ventas
      desde el backend y el avance del número ocurre en la misma transacción
      que la venta
- [ ] **Si el `ACTUALIZAR` puede romper una coherencia entre columnas**, se
      resuelven los valores finales (`NVL` contra la fila actual) **antes** de
      validar — no sólo los parámetros recibidos
- [ ] El mensaje del 409 nombra **la columna del `UNIQUE`**, que no siempre es
      el nombre (en `UNIDADES_MEDIDA` es la abreviatura)
- [ ] Si hay BLOB: `source_type_media` para el `GET`, **nunca** un
      `p_param_type => 'BLOB'` (ver [3.2](#32-imágenes-y-otros-binarios))
- [ ] **Las columnas de texto que representan códigos se normalizan en el
      paquete** (`UPPER(TRIM(...))`), no en el frontend: sin eso el `UNIQUE` deja
      pasar `a1` y `A1` como dos filas
- [ ] **Si se ordena por una columna `VARCHAR2` que guarda números**, la
      conversión lleva `DEFAULT NULL ON CONVERSION ERROR` — una fila con texto
      tumba el listado entero con `ORA-01722`
- [ ] **Lo que se puede derivar, se deriva**: totales, stock, diferencias y
      vencimientos se calculan en la consulta, no se guardan en una columna que
      puede quedar desfasada (ver [3.4](#34-columnas-calculadas-lo-que-no-se-guarda))
- [ ] **Si el borrado depende de que nadie use la fila**, el listado devuelve
      `usos` — así la pantalla explica por qué no se puede en vez de mostrar un
      botón que siempre falla

Si es una **cabecera con detalle** (ver [3.3](#33-cabecera-y-detalle-una-transacción)):

- [ ] El detalle llega como **array JSON en el mismo request**, no en llamadas
      sueltas: es lo único que garantiza que entren juntos
- [ ] `JSON_TABLE` con **`FOR ORDINALITY`**, no `ROWNUM`, para numerar las líneas
      en los mensajes de error
- [ ] El procedimiento que guarda el detalle **no hace `COMMIT` ni `ROLLBACK`**:
      devuelve el error en un `OUT` y la transacción la maneja el llamador
- [ ] Una cabecera **sin líneas se rechaza con 400** — incluido el caso del array
      vacío `[]`, que pasa el chequeo de longitud pero no inserta nada
- [ ] `ELIMINAR` borra **el detalle primero** (el DDL no tiene `ON DELETE CASCADE`)
- [ ] Las **columnas virtuales** (`GENERATED ALWAYS AS`) no se mencionan en el
      `INSERT`: da `ORA-54013`
- [ ] Hay un `OBTENER` aparte que trae la cabecera **con** su detalle, porque el
      `LISTAR` no lo incluye

Si la tabla tiene **estados y triggers** (ver [3.5](#35-máquinas-de-estado-y-triggers)):

- [ ] El paquete **chequea el estado antes** para devolver un 409 legible, aunque
      el trigger ya lo impida — los dos controles no sobran
- [ ] El `UPDATE` **repite en el `WHERE` lo que el `SELECT` verificó**: entre los
      dos hay una ventana en la que otra sesión pudo cambiar la fila
- [ ] Ningún trigger de la tabla quedó `INVALID` — uno solo bloquea todos los
      `INSERT` y `UPDATE`
- [ ] Ningún trigger usa `USER` para saber quién hizo algo: dentro de ORDS es el
      esquema del workspace, igual para todos

Después de ejecutarlo en APEX:

- [ ] Se frenó `npm run dev` antes de reejecutar
- [ ] Las consultas de verificación del final no muestran `INVALID` ni errores
- [ ] **Las consultas de auditoría del final devuelven cero filas** — las que
      verifican coherencias que el DDL no puede expresar
- [ ] El tipo en `src/lib/api.ts` refleja todos los campos del `JSON_OBJECT`
- [ ] `npx tsc --noEmit` pasa sin errores

Para que la página sea alcanzable (el backend listo no alcanza):

- [ ] **El archivo `src/routes/_auth.<tabla>.tsx` creado — TODA tabla del backend
      lleva su página propia**, incluidas las de detalle y las de cruce. No la
      conviertas en un diálogo dentro de otra pantalla: queda sin ruta, sin menú y
      sin forma de darla de alta. Con el archivo creado, la ruta ya aparece sola
      en el alta de páginas, que deriva sus opciones del router
      ([rutas-app.ts](../src/lib/rutas-app.ts))
- [ ] Registrada en Administración → Páginas **y** asignada en Permisos, con la
      empresa elegida (un permiso con `ID_EMPRESA` en null no se ve en el menú)

> El checklist del frontend está en [GUIA-FRONTEND.md](GUIA-FRONTEND.md).

### Errores frecuentes

| Síntoma                                                                           | Causa                                                                                                                                                                                                                                                                                                 |
| --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PLS-00201: DBMS_CRYPTO`                                                          | No hay grant; usá `SYS_GUID`/`STANDARD_HASH`                                                                                                                                                                                                                                                          |
| `PLS-00201: STANDARD_HASH`                                                        | Es función SQL: envolvela en `SELECT … FROM DUAL`                                                                                                                                                                                                                                                     |
| `PLS-00231` en un `SELECT`/`UPDATE`                                               | Función del paquete invocada desde SQL: resolvé el valor antes en PL/SQL                                                                                                                                                                                                                              |
| **`PLS-00684: tipo de datos no válido para el valor de retorno de JSON`**         | `JSON_OBJECT(… RETURNING CLOB)` como asignación directa dentro de un package body. Envolvelo en `SELECT … INTO … FROM DUAL`                                                                                                                                                                           |
| `ORA-01031` en `ENABLE_SCHEMA`                                                    | En APEX ya está habilitado: quitá la llamada                                                                                                                                                                                                                                                          |
| `ORA-00904: "NAME"`                                                               | En `USER_OBJECTS` la columna es `OBJECT_NAME`                                                                                                                                                                                                                                                         |
| `ORA-01722` al filtrar por estado                                                 | `TO_NUMBER` sobre `ACTIVO`, que es `VARCHAR2` con `'A'`/`'I'`                                                                                                                                                                                                                                         |
| `ORA-06550` al compilar el handler                                                | Comillas del `q'~ … ~'` sin cerrar                                                                                                                                                                                                                                                                    |
| **500 sin mensaje, con el `EXCEPTION` escrito**                                   | La conversión está en el `DECLARE`: se ejecuta antes de que exista el `EXCEPTION` y escapa del handler                                                                                                                                                                                                |
| **500 solo cuando falta un query param**                                          | `TO_NUMBER('')`: un parámetro ausente llega como cadena vacía. Usá `NULLIF(:param, '')`                                                                                                                                                                                                               |
| **El listado anda filtrado (`?idX=5`) pero da 500 sin filtro**                    | `JSON_OBJECT` anidado dentro de `JSON_ARRAYAGG`: el intermedio se materializa como VARCHAR2 y se pasa de 4000 bytes. Armá el objeto en una subconsulta — ver [3](#3-crear-el-backend-de-una-tabla). El paquete compila bien y `USER_ERRORS` está vacío, por eso despista                              |
| El endpoint devuelve 404                                                          | Falta `DEFINE_TEMPLATE` para ese patrón                                                                                                                                                                                                                                                               |
| Devuelve 200 pero no guardó                                                       | Falta chequear `SQL%ROWCOUNT`                                                                                                                                                                                                                                                                         |
| 401 en todo                                                                       | El token venció (8 h) o falta el header                                                                                                                                                                                                                                                               |
| 401 al loguearse con datos correctos                                              | `USUARIO` guardado con mayúsculas (el login compara contra `LOWER`), `ACTIVO` distinto de `'A'`, o el hash no se generó con el paquete                                                                                                                                                                |
| `ORA-00060` al reejecutar el script                                               | Otra sesión tiene tomados los metadatos de ORDS: frená `npm run dev` antes                                                                                                                                                                                                                            |
| `ORA-00001` en `DEFINE_MODULE`                                                    | El `DELETE_MODULE` falló y su error se tragó un `WHEN OTHERS THEN NULL`                                                                                                                                                                                                                               |
| `PLS-00306` al llamar a `DEFINE_MODULE`                                           | Le pasaste `p_origins_allowed`: esa versión de ORDS no tiene ese parámetro ahí. Usá `ORDS.SET_MODULE_ORIGINS_ALLOWED(p_module_name, p_origins_allowed)` aparte                                                                                                                                        |
| **"Service Unavailable" (HTML de Oracle, no JSON) en un módulo que compila bien** | Falta `SET_MODULE_ORIGINS_ALLOWED` para ESE módulo. ORIGINS_ALLOWED es por módulo, no por workspace — configurarlo en `auth` no lo propaga a `usuarios` ni a ninguno nuevo. La petición cross-origin la rechaza ORDS antes de llegar al handler, así que ni el `WHEN OTHERS` con `SQLERRM` lo captura |
| `window is not defined`                                                           | Acceso al DOM fuera de `useEffect` (corre en el prerender de build)                                                                                                                                                                                                                                   |
| La lista no se actualiza tras guardar                                             | Falta `invalidateQueries`                                                                                                                                                                                                                                                                             |
| **La UI muestra los datos pero una acción no hace nada**                          | El `JSON_OBJECT` no devuelve un campo que el consumidor necesita: llega `undefined` y el frontend cae en un fallback silencioso. Corré `npx tsc --noEmit` — el tipo lo delata                                                                                                                         |
| El cambio del `.sql` no surte efecto                                              | No se reejecutó en APEX: el repo y ORDS son dos cosas distintas                                                                                                                                                                                                                                       |
| **`ORA-02290: REST_PARAMS_PARAM_TYPE_CK` al publicar**                            | Un `DEFINE_PARAMETER` usa un `p_param_type` que el check no admite — pasa al intentar devolver un BLOB con `'BLOB'` o `'RESOURCE'`. Usá `ORDS.source_type_media`, que no necesita parámetro de salida. **Ojo: el error corta la publicación y deja el módulo sin NINGÚN endpoint**, no solo sin ese   |
| **500 y "blocked by CORS policy" juntos en la consola**                           | El problema es el **500**, no el CORS: cuando el handler revienta, ORDS responde con una página de error que no lleva `Access-Control-Allow-Origin`, y el navegador reporta el bloqueo tapando la causa real. Ejecutá el procedimiento a mano en APEX para ver el `SQLERRM`                           |
| **Una fila existe en la tabla pero no aparece en el listado**                     | `JOIN` interno sobre una FK nullable: la fila que no tiene ese dato se descarta en silencio. Va `LEFT JOIN`                                                                                                                                                                                           |
| El `<img>` de un logo o imagen no carga                                           | El endpoint todavía no se publicó en APEX, o la fila tiene el BLOB vacío. El componente cae al respaldo por `onError`, así que se ve el ícono o las iniciales — no un ícono de imagen rota                                                                                                            |
| **`ORA-20987` al mandar correo (identificador de grupo de seguridad no válido)**  | El handler no fijó el workspace antes de `APEX_MAIL.SEND`. Llamá a `PKG_AUTH.ESTABLECER_WORKSPACE_MAIL`. **No uses `APEX_SESSION.CREATE_SESSION`**: exige una app APEX y este workspace no tiene ninguna — ver [6.1](#61-enviar-correo-desde-un-handler)                                              |
| **El correo no llega y no hay ningún error en ningún lado**                       | Los envíos se tragan la excepción a propósito (`p_enviado = 'I'`) y la mandan a `APEX_DEBUG`, que no está activo. Diagnosticá con `SELECT PKG_AUTH.PROBAR_CORREO('vos@ejemplo.com') FROM DUAL;`, que sí devuelve el error                                                                             |
| **La página existe pero el ítem del menú no navega a ningún lado**                | `PAGINAS.RUTA` está vacía o no coincide con ningún archivo de `src/routes/`. Editá la página en Administración → Páginas y elegí la ruta del desplegable (que hoy se deriva del router, así que las lista todas)                                                                                      |
| **La página no aparece en el menú, aunque esté creada**                           | Falta el permiso **en esa empresa**: la PK de `USUARIO_PAGINAS` es `(ID_EMPRESA, ID_USUARIO, ID_PAGINA)`, así que los accesos se asignan por empresa. Entrá con la empresa que corresponda y asignalo desde Permisos                                                                                  |
| **Se puede editar/borrar un registro de OTRA empresa llamando al endpoint**       | El `UPDATE`/`DELETE` filtra sólo por el id. Va `AND ID_EMPRESA = l_id_empresa` en el `WHERE`, y `ID_EMPRESA` **fuera del `SET`** — ver [Aislamiento por empresa](#aislamiento-por-empresa-filtrar-el-listado-no-alcanza)                                                                              |
| **Quitar un permiso se lo saca al usuario en todas las empresas**                 | El `DELETE` no lleva `ID_EMPRESA`, que integra la PK. Las tres claves van en la URL: `/quitar/:idUsuario/:idPagina/:idEmpresa`                                                                                                                                                                        |
| **404 al eliminar desde la app, y el registro existe**                            | La ruta cambió a `/eliminar/:id/:idEmpresa` y ese `.sql` todavía no se reejecutó en APEX: ORDS no conoce la URL nueva                                                                                                                                                                                 |
| **El ítem del menú no queda resaltado al entrar a la página**                     | `<AppLayout active="…">` recibe el nombre en vez de la ruta. Va la ruta: `active="/ubicaciones"`, y el nombre visible va en `title`                                                                                                                                                                   |
| **Una fila guarda la sucursal de otra empresa**                                   | Las dos FK se validan por separado y ninguna comprueba la relación entre sí. Hay que verificarlo en el paquete antes de escribir — ver [3.1.1](#311-tablas-por-empresa-y-sucursal)                                                                                                                    |
| **`ORA-01722` al ordenar un listado que antes funcionaba**                        | El `ORDER BY` convierte a número una columna `VARCHAR2` y alguien cargó una fila con texto. Usá `TO_NUMBER(… DEFAULT NULL ON CONVERSION ERROR)` con `NULLS LAST`                                                                                                                                      |
| **Dos filas que parecen iguales pasan el `UNIQUE`**                               | Una columna de texto sin normalizar: `a1` y `A1` son distintas para el índice. El `UPPER(TRIM(...))` va en el paquete, no en el frontend                                                                                                                                                              |
