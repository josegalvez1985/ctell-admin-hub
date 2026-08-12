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
4. [Consumir la API desde el frontend](#4-consumir-la-api-desde-el-frontend)
5. [Devolver lo que el consumidor necesita](#5-devolver-lo-que-el-consumidor-necesita)
6. [Seguridad](#6-seguridad)
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

```
db/
├── auth.sql         PKG_AUTH + /auth/        ← única excepción a la regla
├── usuarios.sql     PKG_USUARIOS + /usuarios/
├── empresas.sql     PKG_EMPRESAS + /empresas/
└── articulos.sql    PKG_ARTICULOS + /articulos/
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

### Parámetros: las dos trampas que ya nos costaron caro

Los query params llegan como **texto**, y hay que convertirlos. Pero convertir
mal produce un 500 sin mensaje que es dificilísimo de diagnosticar. Estas dos
reglas no son estilo: son la diferencia entre un endpoint que anda y uno que
muere.

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

Después de ejecutarlo en APEX:

- [ ] Se frenó `npm run dev` antes de reejecutar
- [ ] Las consultas de verificación del final no muestran `INVALID` ni errores
- [ ] El tipo en `src/lib/api.ts` refleja todos los campos del `JSON_OBJECT`
- [ ] `npx tsc --noEmit` pasa sin errores

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
