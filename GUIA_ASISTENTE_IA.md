# Guía: asistente con IA en otro proyecto

> **En Ctell Admin Hub (22/10/2026) esta guía se adaptó; no se copió tal cual.** Lo vigente
> está en `db/asistente-ddl.sql`, `db/asistente.sql` (su encabezado lista cada cambio y el
> porqué) y la sección "Asistente con IA" de `CLAUDE.md`. Las diferencias principales:
>
> - **La estructura de la base es secreta para el usuario**, en tres capas: las instrucciones
>   lo prohíben, `OCULTAR_ESTRUCTURA` saca de la respuesta todo identificador del esquema, y los
>   errores que ve el usuario son genéricos (el detalle va a `IA_CONSULTAS.ERROR`). Además se
>   bloquean los sinónimos del diccionario (`TAB`, `COLS`…) que el original dejaba pasar.
> - **Multiempresa:** `idEmpresa` obligatorio (400) y la empresa y la sucursal activas en el
>   contexto, con las reglas de filtrado del proyecto (asistencias por el profesor, etc.).
> - **Privadas:** `IA_*`, `TOKENS` y `USUARIOS`; la IA lee los usuarios por `V_IA_USUARIOS`.
> - **Las convenciones de este proyecto:** `PKG_ASISTENTE` con su módulo ORDS `/asistente/`,
>   CORS con `SET_MODULE_ORIGINS_ALLOWED` (sin `OPTIONS` ni `*`), `{"error": …}`, camelCase y
>   sin las consultas en la respuesta. El usuario sale del token, no del body. La respuesta va
>   por `HTP` porque el parámetro `:resultado` tiene techo de 4000 bytes.
> - **El frontend:** `src/lib/asistente.ts`, `src/components/ctell/Asistente.tsx` y
>   `Markdown.tsx`, montado en `AppLayout`. El manual es `docs/MANUAL-DE-USO.md` sin la
>   introducción ni el anexo. Tope de 30 preguntas por día.
>
> El resto de este archivo es la guía original de ethos, como referencia.

> **En alquiGO (20/10/2026) esta guía se adaptó; no se copió tal cual.** Lo vigente está en
> `backend/asistente-tablas.sql`, `backend/asistente.sql` (su cabecera lista cada cambio y el
> porqué) y [GUIA_BACKEND §6c](backend/GUIA_BACKEND.md). Las diferencias principales:
>
> - **La IA no ve todo el esquema, solo las vistas `V_IA_*`.** Las publicaciones disponibles
>   y las publicaciones y favoritos del propio usuario. Toda otra tabla le está prohibida.
> - **Las tablas `IA_*`, en un DDL aparte** que se corre una vez, como el resto de `backend/`.
>   `IA_CONSULTAS` guarda `ID_USUARIO` (número) en vez de `USUARIO`.
> - **El paquete y el endpoint siguen las convenciones de alquiGO:**
>   - el paquete es `PKG_IA` y el endpoint `POST /asistente/preguntar`, en un módulo propio;
>   - `{"error": …}` con `X-APEX-STATUS-CODE` y CORS por lista blanca, sin `OPTIONS` ni `*`;
>   - la respuesta en camelCase (`usadasHoy`) y sin las consultas.
> - **El frontend es React Native**, no los anexos B, C y D: `src/lib/asistente.ts`,
>   `src/components/AsistenteModal.tsx` y `src/lib/markdown.ts`.
> - **El manual es `MANUAL_USUARIO.md` entero**, sin cortarlo en secciones. Tope de 30
>   preguntas por día.
>
> El resto de este archivo es la guía original de ethos, como referencia.

Cómo llevar el asistente de **editorial-ethos-app** (15/10/2026) a otro proyecto con el mismo
stack (Oracle APEX + ORDS de backend, React + Vite de front), usando **la misma clave de la API
de Claude**. **El código completo va al final, en los anexos**: esta guía es lo único que hay
que llevar al otro proyecto.

| Anexo | Archivo en el otro proyecto | Qué es |
| --- | --- | --- |
| A | `backend/ia_asistente.sql` | Tablas, paquete y endpoints ORDS |
| B | `src/lib/asistente.ts` | La conversación, el pedido al backend y el manual |
| C | `src/components/asistente.tsx` | Botón flotante y chat |
| D | `src/components/markdown.tsx` | Renderer de las respuestas |

En el anexo A, los nombres propios de ethos ya están cambiados por marcadores (`PROY`,
`MI_WORKSPACE_APEX`): se reemplazan con buscar y reemplazar (ver 2.1).

## 0. Cómo funciona

```
Sitio (React)                       Oracle (ORDS + PL/SQL)                    API de Claude
─────────────                       ──────────────────────                    ─────────────
botón flotante → chat
POST ia/preguntar ───────────────►  PKG_IA_PROY.preguntar
{pregunta, historial,               valida token + límite del día
 manual, pantalla, nombre}          arma system = instrucciones + esquema
                                    + manual + contexto ──────────────────►  messages (Haiku 5.5)
                                                          ◄── tool_use consultar_sql
                                    validar + SELECT en READ ONLY
                                    devuelve resultado ───────────────────►  (hasta 8 vueltas)
                                                          ◄── texto final
◄──────────────────────────────────  {respuesta, usadas_hoy, limite}
                                    registra todo en IA_CONSULTAS
```

- **La clave nunca llega al navegador**: vive en la tabla `IA_CONFIG` y la API la llama Oracle
  con `APEX_WEB_SERVICE`.
- **Solo lectura, siempre**: la única herramienta es `consultar_sql`, y Oracle la corre en
  `SET TRANSACTION READ ONLY` además del filtro.
- **El SQL no se le muestra al usuario**: queda en `IA_CONSULTAS.CONSULTAS`.

## 1. Usar la misma clave

1. **No se escribe en ningún archivo ni se pega en un chat.** Se carga a mano en SQL Commands
   de la base del otro proyecto:
   ```sql
   BEGIN PKG_IA_PROY.fijar_clave('sk-ant-...'); END;
   ```
2. La clave actual es de un workspace de la consola de Claude ("fc"), así que no hace falta
   `WORKSPACE_ID`. Solo si la API responde 400 "not scoped to a workspace":
   ```sql
   BEGIN PKG_IA_PROY.fijar_workspace_id('wrkspc_...'); END;
   ```
3. **El gasto es compartido**: los dos proyectos descuentan del mismo tope de la organización
   (US$ 5/mes). Si uno lo agota, el otro también deja de responder (el usuario ve "se llegó al
   límite de la cuenta"). Arrancar el otro con un `LIMITE_DIARIO` más bajo.
4. **Revocar la clave apaga los dos.** Si algún día se quieren separar, se crea otra clave en
   el mismo workspace y se carga con `fijar_clave`; no hay que tocar código.

## 2. Backend

### 2.0 Las estructuras

Todo lo crea `ia_asistente.sql` (si ya existe, no lo toca). Va acá para saber qué queda en la base.

**Tablas**

```sql
-- Configuración: clave / valor. Privada: la IA no la puede consultar (acá está la clave).
CREATE TABLE IA_CONFIG (
  CLAVE         VARCHAR2(60)   NOT NULL,
  VALOR         VARCHAR2(4000),
  MODIFICADO_EL DATE DEFAULT SYSDATE NOT NULL,
  CONSTRAINT PK_IA_CONFIG PRIMARY KEY (CLAVE)
);

-- Cada pregunta: quién, cuándo (hora local), la respuesta, el SQL que corrió y los tokens.
-- Privada. También es el contador del límite diario (las filas con ERROR no cuentan).
CREATE TABLE IA_CONSULTAS (
  ID                    NUMBER GENERATED BY DEFAULT ON NULL AS IDENTITY NOT NULL,
  USUARIO               VARCHAR2(255) NOT NULL,
  FECHA                 DATE          NOT NULL,
  PANTALLA              VARCHAR2(200),
  PREGUNTA              CLOB,
  RESPUESTA             CLOB,
  CONSULTAS             CLOB,          -- JSON: [{motivo, sql, filas, error}]
  VUELTAS               NUMBER,        -- idas y vueltas con la API
  TOKENS_ENTRADA        NUMBER,
  TOKENS_SALIDA         NUMBER,
  TOKENS_CACHE_LEIDOS   NUMBER,
  TOKENS_CACHE_ESCRITOS NUMBER,
  MILISEGUNDOS          NUMBER,
  MODELO                VARCHAR2(60),
  ERROR                 VARCHAR2(4000),
  CONSTRAINT PK_IA_CONSULTAS PRIMARY KEY (ID)
);
CREATE INDEX IX_IA_CONSULTAS_USR ON IA_CONSULTAS (USUARIO, FECHA);
```

**Filas de `IA_CONFIG`**

| CLAVE | Valor de entrada | Quién la carga |
| --- | --- | --- |
| `API_KEY` | — | A mano, con `fijar_clave` (sección 1) |
| `WORKSPACE_ID` | — | A mano, con `fijar_workspace_id`, solo si hace falta |
| `MODELO` | `claude-haiku-5-5` | El script (MERGE, no pisa) |
| `ESFUERZO` | `medium` | El script |
| `LIMITE_DIARIO` | `60` | El script |
| `MAX_FILAS` | `200` | El script |

**Paquete `PKG_IA_PROY`** (la spec; el paquete completo está en el anexo A)

```sql
CREATE OR REPLACE PACKAGE PKG_IA_PROY AS
  -- POST ia/preguntar. p_cuerpo: el body crudo (:body_text).
  PROCEDURE preguntar(p_token IN VARCHAR2, p_cuerpo IN CLOB);
  -- A mano, en SQL Commands:
  PROCEDURE fijar_clave(p_clave IN VARCHAR2);        -- NULL la borra (apaga el asistente)
  PROCEDURE fijar_workspace_id(p_id IN VARCHAR2);    -- NULL lo borra
  PROCEDURE probar;                                  -- conexión + clave, en DBMS_OUTPUT
  PROCEDURE probar_consulta(p_sql IN VARCHAR2);      -- corre un SQL con el mismo filtro
END PKG_IA_PROY;
```

Las partes del body: `llamar` (la API, con reintentos), `mensaje_api` (errores en castellano),
`cargar_esquema` (describe tablas, columnas, comentarios, FKs y bitácoras `_JN`; se refresca
cada 10 minutos), `validar` / `prohibido` (el filtro), `consultar` (READ ONLY),
`instrucciones` / `herramientas` / `contexto` (lo que se le manda a la IA), `registrar`
(transacción autónoma) y `preguntar` (el bucle).

Constantes del body: 8 vueltas, 12 consultas y 16000 tokens de respuesta por pregunta; 12
mensajes de historial; pregunta de 4000 caracteres; 24000 caracteres de resultado por consulta
y 300 por valor.

**ORDS** (en el módulo del proyecto)

| Método | Plantilla | Handler |
| --- | --- | --- |
| POST | `ia/preguntar` | `plsql/block`: saca el token de `Authorization: Bearer ...` y llama `PKG_IA_PROY.PREGUNTAR(p_token, :body_text)`. Parámetro `Authorization` (HEADER → `:authorization`) |
| OPTIONS | `ia/preguntar` | Preflight CORS: `Allow-Origin *`, `Allow-Methods POST, OPTIONS`, `Allow-Headers Authorization, Content-Type` |

**Requisitos de la instancia**: `APEX_WEB_SERVICE` con salida a `https://api.anthropic.com`
(ACL y certificado), `JSON_OBJECT_T` (Oracle 12.2+) y un paquete de auth que valide el token.

### 2.1 Adaptar el script (anexo A)

Copiar el anexo A a `backend/ia_asistente.sql` y cambiar esto:

| Marcador o lugar | Qué es | Qué poner |
| --- | --- | --- |
| `PROY` (en `PKG_IA_PROY`, `PKG_AUTH_PROY`, `PROY_TOKENS`, `PROY\_TOKENS`) | El prefijo de los objetos | El prefijo del otro proyecto. Buscar y reemplazar `PROY` en todo el archivo |
| `'proy'` (minúsculas) | El módulo ORDS, en `DELETE_HANDLER`, `DEFINE_TEMPLATE`, `DEFINE_HANDLER`, `DEFINE_PARAMETER` y un mensaje | El módulo ORDS del otro |
| `'MI_WORKSPACE_APEX'` | `c_workspace`: el workspace de APEX | El workspace APEX del otro |
| `PKG_AUTH_PROY.VALIDAR_TOKEN(p_token)` en `f_usuario`, y `'PKG_AUTH_PROY'` / `'backend/auth.sql'` en la sección 1) | La validación del token | La función de auth del otro (devuelve el usuario, o lanza / NULL) |
| `PROY_TOKENS` en `es_privada` y en los 3 filtros de `cargar_esquema` | Tablas privadas | La tabla de tokens o sesiones del otro. Sumar **cualquier otra sensible** (contraseñas, claves) con otro `OR p_nombre LIKE ...` y su filtro |
| `FN_ANIO_LECTIVO_ACTUAL` en `cargar_esquema`, la descripción de la herramienta y `contexto` | La única función propia que la IA puede llamar | Sacarla, o cambiarla por alguna función propia útil (solo funciones sin efectos). Si no existe, `contexto` la saltea sola |
| `c_desfase := -3 / 24` | La zona horaria (UTC → Paraguay) | La del otro |
| Primer párrafo de `instrucciones()` | Describe Juventud con Valores | El negocio del otro y quién lo usa. Las reglas de SQL y "Cómo responder" quedan tal cual (incluido "no muestres SQL ni nombres de tablas") |
| El bloque que busca `/asistente` en `menu_paginas` (sección 5) | Aviso de una versión vieja de ethos | Borrarlo (si no está la tabla, no hace nada) |

**Si los dos proyectos comparten el mismo esquema de Oracle**, `IA_CONFIG` e `IA_CONSULTAS`
chocarían: renombrarlas (por ejemplo `IA2_CONFIG`, `IA2_CONSULTAS`) y ajustar el patrón de
`es_privada` y de los filtros de `cargar_esquema` (`'IA\_%'` cubre `IA_*`, no `IA2_*`). Si
cada uno tiene su esquema, no hace falta.

**No tocar** (ya está probado en ethos):

- `validar` / `prohibido`: el filtro del SQL.
- `consultar`: `READ ONLY`, `MAX_FILAS` y el corte de textos.
- `llamar`: reintentos ante 429 / 5xx / 529 y el borrado de los headers al final.
- El orden de los bloques de `system`: lo fijo primero con `cache_control`, el contexto al final.
- El bucle de `tool_use`, con `tool_choice: none` en la última vuelta.
- `registrar`, en transacción autónoma.

### 2.2 Ponerlo en marcha

1. Correr el script en SQL Workshop → SQL Scripts (después del de auth). Es idempotente.
2. Cargar la clave (punto 1.1).
3. `BEGIN PKG_IA_PROY.probar; END;` → tiene que decir `[OK] Oracle llega a la API de Claude...`.
   Si da **ORA-24247 o un error de certificado**, esa instancia no deja salir a
   `api.anthropic.com` y el asistente no puede correr ahí (si es la misma instancia que ethos,
   ya está resuelto).
4. Probar el filtro sin gastar tokens:
   ```sql
   BEGIN PKG_IA_PROY.probar_consulta('SELECT COUNT(*) FROM <una_tabla>'); END;   -- [OK]
   BEGIN PKG_IA_PROY.probar_consulta('SELECT * FROM ia_config'); END;             -- [RECHAZADA]
   BEGIN PKG_IA_PROY.probar_consulta('DELETE FROM <una_tabla>'); END;             -- [RECHAZADA]
   ```
5. Ajustar la configuración sin volver a correr el script:
   ```sql
   UPDATE ia_config SET valor = '30' WHERE clave = 'LIMITE_DIARIO'; COMMIT;
   ```
   Claves: `MODELO` (`claude-haiku-5-5`), `ESFUERZO` (`low` / `medium` / `high`),
   `LIMITE_DIARIO`, `MAX_FILAS`.

### 2.3 Contrato del endpoint

```
POST ia/preguntar      Authorization: Bearer <token de sesión>
{ pregunta: string (≤ 4000),
  historial: [{ rol: "usuario" | "asistente", texto }],   // se usan los últimos 12
  manual: string,       // markdown, puede pasar de 32K (por eso se lee :body_text)
  pantalla: string,     // "Nombre (/ruta)"
  nombre: string }

200 { success, respuesta (markdown), consultas: [{motivo, sql, filas, error}], usadas_hoy, limite }
400 JSON inválido o sin pregunta · 401 token · 429 límite del día · 503 sin clave · 502 la API falló
```

### 2.4 Costo por mes

```sql
SELECT TRUNC(fecha, 'MM') mes, COUNT(*) preguntas,
       ROUND((SUM(tokens_entrada) * 0.10 + SUM(tokens_cache_leidos) * 0.01
            + SUM(tokens_cache_escritos) * 0.125 + SUM(tokens_salida) * 0.50) / 1e6, 2) dolares
  FROM ia_consultas GROUP BY TRUNC(fecha, 'MM') ORDER BY 1;
```

El tope de US$ 5 es de los dos proyectos juntos: sumar lo de ambos.

## 3. Frontend

### 3.1 Archivos

| Anexo | Archivo | Qué es | Qué adaptar |
| --- | --- | --- | --- |
| B | `src/lib/asistente.ts` | Store de módulo (la conversación), `preguntar`, `reintentar`, el manual | Ver 3.2 |
| C | `src/components/asistente.tsx` | Botón flotante, panel de escritorio y hoja del celular | Ver 3.3 |
| D | `src/components/markdown.tsx` | Renderer de markdown propio, sin dependencias; nunca arma HTML (todo son nodos de React) | Nada |

Dependencias:

- `lucide-react` y `sonner` (toast).
- El `Drawer` de shadcn: `npx shadcn@latest add drawer` crea `components/ui/drawer.tsx` (usa
  `vaul`).
- `cn` de `@/lib/utils` (el de shadcn: `clsx` + `tailwind-merge`).
- `@tanstack/react-router`, solo por `useRouterState`. Con otro router, cambiarlo por el hook
  que dé el `pathname`.

### 3.2 `lib/asistente.ts`

- **`authFetch` y `getSesion`** vienen de `@/lib/api`. En el otro proyecto tienen que hacer lo
  mismo: `authFetch(path, init)` agrega `Authorization: Bearer`, arma la URL base de ORDS, lanza
  un `Error` con el `message` del backend si no es 2xx y devuelve el JSON; `getSesion()` devuelve
  `{token, nombre}`.
- **La conversación va atada al token**: con otro login arranca de cero. Vive solo en memoria,
  no se persiste (puede traer datos de cualquier tabla).
- **El manual**: `cargarManual()` importa `../../README.md?raw` (Vite lo soporta) y
  `armarManual()` corta secciones por título. Cambiar:
  - los títulos de `seccion(md, "## ...", "### ...")` por las secciones del README del otro que
    describen pantallas, menú y permisos;
  - `GUIA_BASICA`: login, duración de la sesión, navegación en celular y escritorio, cómo pedir
    permisos.

  Así cada pantalla que se documente en ese README la conoce el asistente con el deploy, sin
  tocar Oracle.

### 3.3 `components/asistente.tsx`

- **`usePantallaActual()`**: usa `usePermisos().paginaDeRuta(pathname)?.nombre` y casos
  especiales (`/home` → Inicio, `/account` → Mi cuenta). Cambiarlo por cómo el otro proyecto sabe
  el nombre de la ruta; si no hay, alcanza con mandar el `pathname`.
- **`Bienvenida`**: las sugerencias son de ethos ("intervenciones", "instituciones sin
  facilitador"...). Poner 3 o 4 preguntas típicas del otro y dejar la primera dinámica
  (`¿Cómo se usa ${pantalla}?`).
- **Clases de Tailwind del tema de ethos** que hay que mapear a las del otro: `bg-hero-gradient`,
  `text-on-brand`, `shadow-elegant`, `shadow-soft`, `tap`, `font-display`, `bg-primary-soft`,
  `bg-brand-red`. El resto (`bg-primary`, `bg-muted`, `border-border`, `text-muted-foreground`,
  `destructive`) es estándar de shadcn.
- **Posición del botón**: en el celular es `bottom-[calc(5.75rem+env(safe-area-inset-bottom))]`
  para quedar sobre la barra inferior de ethos. Si el otro no tiene barra abajo, `bottom-4`.

### 3.4 Montarlo

En el layout que envuelve todas las pantallas con sesión (en ethos, `AppShell`):

```tsx
import { Asistente } from "@/components/asistente";
import { useAsistente } from "@/lib/asistente";

const { abierto: asistenteAbierto } = useAsistente();
// ...
<main className={cn("...", asistenteAbierto && "lg:mr-[420px]")}>   {/* el panel no tapa */}
  ...
</main>
<Asistente />
```

Solo en pantallas con sesión (en el login no hay token). No es una página del menú ni pide
permiso: lo ve todo el que entra.

## 4. Reglas que se mantienen

- **Solo consultas, siempre.** No agregarle herramientas que inserten, modifiquen o borren. Si
  piden cargar algo, explica en qué pantalla se hace.
- **El SQL no se muestra** en el chat; se revisa en `IA_CONSULTAS`.
- **Tablas privadas** (`IA_*`, sesiones, contraseñas) fuera del esquema y del filtro.
- **Ve todas las tablas sin filtrar por permisos** (así se decidió en ethos). Si el otro proyecto
  tiene datos que no todos deberían ver, decidirlo antes: o se suman a `es_privada` o se filtra
  por usuario.

## 5. Prueba final

1. `probar` → OK.
2. `probar_consulta` → acepta un SELECT, rechaza `ia_config` y un DELETE.
3. En el sitio:
   - "¿cómo se usa esta pantalla?" responde con lo del README, sin nombrar archivos;
   - una pregunta de datos ("¿cuántos X hay este mes?") da números;
   - el pie muestra "Hoy: 1 de N".
4. `SELECT * FROM ia_consultas ORDER BY id DESC FETCH FIRST 5 ROWS ONLY` → aparecen la
   pregunta, el SQL y los tokens.
5. Revisar en la consola de Claude (workspace "fc") que el gasto del mes subió.

---

## Anexo A: `backend/ia_asistente.sql`

Con los marcadores de la sección 2.1 (`PROY`, `'proy'`, `MI_WORKSPACE_APEX`).

```sql
--------------------------------------------------------------------------------
-- IA_ASISTENTE  —  El asistente con IA del sitio (botón flotante)
--------------------------------------------------------------------------------
--
-- Pantalla NUEVA del sitio (15/10/2026), no viene de APEX. No es una página
-- del menú: es un botón flotante en todas las pantallas que abre un chat. Se le
-- pregunta de todo: cómo se usa una pantalla, un formulario, un permiso, o
-- sobre los registros ("¿cuántas intervenciones hubo en mayo?").
--
-- CÓMO FUNCIONA (decisiones de Jose, 15/10/2026)
--
--   - La IA corre ACÁ, en Oracle, y no en el navegador: la clave de la API no
--     puede viajar al sitio (es estático, cualquiera la vería). El paquete
--     llama a la API de Claude con APEX_WEB_SERVICE.
--   - Modelo: Claude Haiku 5.5 (`claude-haiku-5-5`), el más barato. Se cambia
--     en IA_CONFIG (MODELO) sin tocar este script.
--   - Para los datos, la IA escribe un SELECT y este paquete lo corre en una
--     TRANSACCIÓN DE SOLO LECTURA. Ve todas las tablas y vistas del esquema
--     SIN FILTRAR POR PERMISOS (pedido de Jose), salvo las privadas: las IA_*
--     (acá está la clave) y PROY_TOKENS (las sesiones). Ver "LAS CONSULTAS".
--   - Para el uso del sistema, el sitio manda el "manual": las secciones del
--     README que describen cada pantalla (src/lib/asistente.ts). Así queda al
--     día con cada deploy sin volver a correr este script.
--   - SOLO CONSULTAS, SIEMPRE (Jose, 15/10/2026): la IA no inserta, modifica
--     ni borra nada, y no hay que darle herramientas que lo hagan. Si piden
--     cargar o cambiar algo, explica en qué pantalla se hace.
--   - Quién lo usa: CUALQUIER USUARIO CON SESIÓN, sin página ni permiso en
--     Roles de páginas (Jose, 15/10/2026; la primera versión pedía la página
--     /asistente). El gasto lo controla LIMITE_DIARIO, por usuario.
--
-- QUÉ PUBLICA ESTE SCRIPT
--
--   POST  ia/preguntar   {pregunta, historial:[{rol, texto}], manual, pantalla,
--                         nombre}  ->  {respuesta, consultas:[{motivo, sql,
--                         filas, error}], usadas_hoy, limite}
--
--   El body se lee CRUDO (:body_text) y se parsea acá, a diferencia del resto
--   de los scripts (ver inventarios.sql): `historial` es un array y `manual`
--   pasa los 32K, y ORDS bindea solo campos escalares y cortos.
--
-- CORRER DESPUÉS de auth.sql.
--
--   SQL Workshop -> SQL Scripts -> Upload -> este archivo -> Run
--
-- Idempotente: se puede correr las veces que haga falta.
--
--------------------------------------------------------------------------------
-- Y DESPUÉS, DOS PASOS A MANO
--------------------------------------------------------------------------------
--
--   1. LA CLAVE DE LA API. Se crea en https://platform.claude.com (API Keys) y
--      se carga en SQL Workshop -> SQL Commands, NUNCA en este archivo (se
--      subiría al repositorio):
--
--        BEGIN PKG_IA_PROY.fijar_clave('sk-ant-...'); END;
--
--      Si la clave NO es de un workspace de la consola, la API responde 400
--      "This API key is not scoped to a workspace": o se crea la clave dentro
--      de un workspace, o se carga el ID del workspace (Settings -> Workspaces):
--
--        BEGIN PKG_IA_PROY.fijar_workspace_id('wrkspc_...'); END;
--
--   2. PROBAR LA CONEXIÓN, en SQL Commands. Dice si Oracle llega a la API y si
--      la clave sirve:
--
--        BEGIN PKG_IA_PROY.probar; END;
--
--   No hay nada que dar de alta en Crear páginas ni en Roles de páginas: el
--   botón le aparece a todo el que entra.
--
--------------------------------------------------------------------------------
-- LAS CONSULTAS (lo que puede leer la IA)
--------------------------------------------------------------------------------
--
--   Cada consulta pasa por `validar` y después por `consultar`:
--
--   - Una sola sentencia, que empieza con SELECT o WITH. Sin punto y coma, sin
--     comentarios, sin @dblink, sin literales q'...', sin WITH FUNCTION y sin
--     FOR UPDATE.
--   - Ningún identificador puede ser un paquete, función, procedimiento, tipo,
--     sinónimo o secuencia del esquema (salvo FN_ANIO_LECTIVO_ACTUAL), ni del
--     sistema (DBMS_*, UTL_*, APEX_*, OWA, HTP, las vistas USER_/ALL_/DBA_/V$,
--     XMLQUERY y compañía), ni una tabla privada (IA_*, PROY_TOKENS).
--   - Corre en SET TRANSACTION READ ONLY: aunque algo pasara el filtro, Oracle
--     rechaza cualquier escritura.
--   - Devuelve hasta MAX_FILAS filas (IA_CONFIG, 200 de entrada) y corta los
--     textos largos: si hay más, avisa ("cortado") para que la IA agregue.
--
--   NO hay tope de tiempo por consulta: un SELECT muy pesado puede tardar. Es
--   el mismo riesgo que un reporte de APEX mal filtrado.
--
--------------------------------------------------------------------------------
-- CONFIGURACIÓN (IA_CONFIG, clave / valor)
--------------------------------------------------------------------------------
--
--   API_KEY        la clave de la API de Claude (con fijar_clave, ver arriba)
--   WORKSPACE_ID   el workspace de la consola, solo si la clave no es de uno
--                  (con fijar_workspace_id): va en anthropic-workspace-id
--   MODELO         claude-haiku-5-5
--   ESFUERZO       medium (low | medium | high): cuánto piensa antes de
--                  responder; más es más lento y un poco más caro
--   LIMITE_DIARIO  60 preguntas por usuario y por día (las que fallan no
--                  cuentan)
--   MAX_FILAS      200 filas por consulta
--
--   Este script crea las que faltan y NO pisa las que ya están: para cambiar
--   una, UPDATE ia_config SET valor = '...' WHERE clave = '...'; y COMMIT.
--
--------------------------------------------------------------------------------
-- LO QUE CUESTA (IA_CONSULTAS)
--------------------------------------------------------------------------------
--
--   Cada pregunta queda en IA_CONSULTAS: quién, cuándo (hora de Paraguay), en
--   qué pantalla, la pregunta, la respuesta, las consultas que corrió, los
--   tokens y cuánto tardó. Con Haiku 5.5 (US$ 0,10 / 0,50 por millón de tokens
--   de entrada / salida; lo cacheado se lee a 0,1x) el costo aproximado es:
--
--     SELECT TRUNC(fecha, 'MM') mes, COUNT(*) preguntas,
--            ROUND((SUM(tokens_entrada) * 0.10 + SUM(tokens_cache_leidos) * 0.01
--                 + SUM(tokens_cache_escritos) * 0.125
--                 + SUM(tokens_salida) * 0.50) / 1e6, 2) dolares
--       FROM ia_consultas GROUP BY TRUNC(fecha, 'MM') ORDER BY 1;
--
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON
SET DEFINE OFF

--------------------------------------------------------------------------------
-- === 1) VERIFICACIÓN PREVIA =================================================
--------------------------------------------------------------------------------

DECLARE
  l_n PLS_INTEGER;
BEGIN
  FOR o IN (SELECT 'PKG_AUTH_PROY' AS nombre, 'backend/auth.sql' AS script FROM dual) LOOP
    SELECT COUNT(*) INTO l_n FROM all_objects
     WHERE object_name = o.nombre AND object_type = 'PACKAGE BODY';
    IF l_n = 0 THEN
      DBMS_OUTPUT.PUT_LINE('[ERROR] Falta ' || o.nombre || '. Corre ' || o.script || ' primero.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('[OK]   ' || o.nombre || ' encontrado.');
    END IF;
  END LOOP;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('[ERROR] ' || SQLERRM);
END;
/

--------------------------------------------------------------------------------
-- === 2) ESTRUCTURA: IA_CONFIG e IA_CONSULTAS (si faltan) ===================
--------------------------------------------------------------------------------

DECLARE
  PROCEDURE ejecutar(p_sql IN VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
  END ejecutar;

  FUNCTION existe(p_tabla IN VARCHAR2) RETURN BOOLEAN IS
    l_c PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO l_c FROM user_tables WHERE table_name = p_tabla;
    IF l_c > 0 THEN
      DBMS_OUTPUT.PUT_LINE('[SKIP] La tabla ' || p_tabla || ' ya existia.');
    END IF;
    RETURN l_c > 0;
  END existe;
BEGIN
  IF NOT existe('IA_CONFIG') THEN
    ejecutar(q'~
      CREATE TABLE IA_CONFIG (
        CLAVE         VARCHAR2(60)   NOT NULL,
        VALOR         VARCHAR2(4000),
        MODIFICADO_EL DATE DEFAULT SYSDATE NOT NULL,
        CONSTRAINT PK_IA_CONFIG PRIMARY KEY (CLAVE)
      )~');
    ejecutar(q'~COMMENT ON TABLE IA_CONFIG IS 'Configuración del asistente con IA (clave de la API, modelo, límites). Privada: la IA no la puede consultar'~');
    DBMS_OUTPUT.PUT_LINE('[OK]   Tabla IA_CONFIG creada.');
  END IF;

  IF NOT existe('IA_CONSULTAS') THEN
    ejecutar(q'~
      CREATE TABLE IA_CONSULTAS (
        ID                    NUMBER GENERATED BY DEFAULT ON NULL AS IDENTITY NOT NULL,
        USUARIO               VARCHAR2(255) NOT NULL,
        FECHA                 DATE          NOT NULL,
        PANTALLA              VARCHAR2(200),
        PREGUNTA              CLOB,
        RESPUESTA             CLOB,
        CONSULTAS             CLOB,
        VUELTAS               NUMBER,
        TOKENS_ENTRADA        NUMBER,
        TOKENS_SALIDA         NUMBER,
        TOKENS_CACHE_LEIDOS   NUMBER,
        TOKENS_CACHE_ESCRITOS NUMBER,
        MILISEGUNDOS          NUMBER,
        MODELO                VARCHAR2(60),
        ERROR                 VARCHAR2(4000),
        CONSTRAINT PK_IA_CONSULTAS PRIMARY KEY (ID)
      )~');
    ejecutar('CREATE INDEX IX_IA_CONSULTAS_USR ON IA_CONSULTAS (USUARIO, FECHA)');
    ejecutar(q'~COMMENT ON TABLE IA_CONSULTAS IS 'Cada pregunta al asistente con IA: quién, cuándo (hora de Paraguay), la respuesta, las consultas SQL y los tokens. Privada'~');
    DBMS_OUTPUT.PUT_LINE('[OK]   Tabla IA_CONSULTAS creada.');
  END IF;

  -- Los valores de entrada. Los que ya están no se tocan.
  FOR c IN (SELECT 'MODELO' AS clave, 'claude-haiku-5-5' AS valor FROM dual
            UNION ALL SELECT 'ESFUERZO', 'medium' FROM dual
            UNION ALL SELECT 'LIMITE_DIARIO', '60' FROM dual
            UNION ALL SELECT 'MAX_FILAS', '200' FROM dual) LOOP
    EXECUTE IMMEDIATE q'~
      MERGE INTO ia_config t
      USING (SELECT :1 AS clave, :2 AS valor FROM dual) s
         ON (t.clave = s.clave)
       WHEN NOT MATCHED THEN INSERT (clave, valor) VALUES (s.clave, s.valor)~'
      USING c.clave, c.valor;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('[OK]   IA_CONFIG con sus valores de entrada.');
END;
/

--------------------------------------------------------------------------------
-- === 3) PAQUETE =============================================================
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE PKG_IA_PROY AS

  -- POST ia/preguntar. p_cuerpo: el body crudo (ver el encabezado).
  PROCEDURE preguntar(p_token IN VARCHAR2, p_cuerpo IN CLOB);

  -- Guarda la clave de la API (NULL la borra). Se corre a mano en SQL Commands.
  PROCEDURE fijar_clave(p_clave IN VARCHAR2);

  -- El workspace de la consola de Claude, para una clave que no es de uno
  -- (NULL lo borra). A mano, en SQL Commands.
  PROCEDURE fijar_workspace_id(p_id IN VARCHAR2);

  -- Prueba la conexión con la API y la clave. Escribe en DBMS_OUTPUT.
  PROCEDURE probar;

  -- Corre una consulta como la correría la IA (mismo filtro, solo lectura) y
  -- escribe el resultado en DBMS_OUTPUT. Para probar a mano.
  PROCEDURE probar_consulta(p_sql IN VARCHAR2);

END PKG_IA_PROY;
/

CREATE OR REPLACE PACKAGE BODY PKG_IA_PROY AS

  -- El workspace, como en auth.sql: APEX_WEB_SERVICE lo necesita fuera de una
  -- sesión de APEX (desde ORDS no hay).
  c_workspace CONSTANT VARCHAR2(64)  := 'MI_WORKSPACE_APEX';
  c_api       CONSTANT VARCHAR2(100) := 'https://api.anthropic.com/v1/';
  c_version   CONSTANT VARCHAR2(20)  := '2023-06-01';
  -- Hora del servidor (UTC) -> hora de Paraguay, como el resto del backend.
  c_desfase   CONSTANT NUMBER        := -3 / 24;

  -- Topes de una pregunta: idas y vueltas con la API, consultas SQL, tokens de
  -- la respuesta (incluye lo que piensa), mensajes previos que se mandan y
  -- largo de la pregunta.
  c_max_vueltas   CONSTANT PLS_INTEGER := 8;
  c_max_consultas CONSTANT PLS_INTEGER := 12;
  c_max_tokens    CONSTANT PLS_INTEGER := 16000;
  c_max_historial CONSTANT PLS_INTEGER := 12;
  c_max_pregunta  CONSTANT PLS_INTEGER := 4000;
  -- El resultado de una consulta que ve la IA: caracteres en total y por valor.
  c_tope_resultado CONSTANT PLS_INTEGER := 24000;
  c_tope_valor     CONSTANT PLS_INTEGER := 300;
  -- Cada cuánto se vuelve a leer el diccionario para describir el esquema.
  c_vida_esquema   CONSTANT NUMBER := 10 / 1440;

  -- Tipos de DBMS_SQL.DESCRIBE_COLUMNS2 que se leen distinto.
  c_tipo_fecha CONSTANT PLS_INTEGER := 12;
  c_tipo_clob  CONSTANT PLS_INTEGER := 112;

  TYPE t_set IS TABLE OF BOOLEAN INDEX BY VARCHAR2(128);

  -- El esquema que se le describe a la IA, con lo que puede y no puede usar.
  -- Vive en la sesión (ORDS la reusa) y se refresca cada c_vida_esquema.
  g_prohibidos t_set;
  g_permitidos t_set;
  g_esquema    CLOB;
  g_esquema_al DATE;

  -- Una consulta rechazada o con error: g_msg dice por qué y se le devuelve a
  -- la IA para que la corrija.
  e_sql EXCEPTION;
  -- La API respondió con error: g_msg lo explica.
  e_api EXCEPTION;
  g_msg VARCHAR2(4000);

  ------------------------------------------------------------------------------
  -- RESPUESTA HTTP
  ------------------------------------------------------------------------------

  PROCEDURE abrir_json IS
  BEGIN
    OWA_UTIL.MIME_HEADER('application/json', FALSE);
    HTP.P('Cache-Control: no-store');
    HTP.P('Access-Control-Allow-Origin: *');
    OWA_UTIL.HTTP_HEADER_CLOSE;
  END abrir_json;

  -- SOLO antes de haber abierto la respuesta: emite headers.
  PROCEDURE p_error(p_status IN NUMBER, p_titulo IN VARCHAR2, p_detalle IN VARCHAR2) IS
  BEGIN
    OWA_UTIL.STATUS_LINE(p_status, p_titulo, FALSE);
    abrir_json;
    APEX_JSON.OPEN_OBJECT;
    APEX_JSON.WRITE('success', FALSE);
    APEX_JSON.WRITE('message', p_detalle);
    APEX_JSON.CLOSE_OBJECT;
  END p_error;

  -- Un CLOB al cuerpo de la respuesta, de a pedazos (HTP.PRN no toma más de 32K).
  PROCEDURE imprimir(p_clob IN CLOB) IS
    l_pos PLS_INTEGER := 1;
    l_len PLS_INTEGER := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
  BEGIN
    WHILE l_pos <= l_len LOOP
      HTP.PRN(DBMS_LOB.SUBSTR(p_clob, 8000, l_pos));
      l_pos := l_pos + 8000;
    END LOOP;
  END imprimir;

  ------------------------------------------------------------------------------
  -- AUXILIARES
  ------------------------------------------------------------------------------

  FUNCTION config(p_clave IN VARCHAR2, p_defecto IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    l_v ia_config.valor%TYPE;
  BEGIN
    SELECT valor INTO l_v FROM ia_config WHERE clave = p_clave;
    RETURN NVL(TRIM(l_v), p_defecto);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN p_defecto;
  END config;

  FUNCTION config_num(p_clave IN VARCHAR2, p_defecto IN NUMBER) RETURN NUMBER IS
  BEGIN
    RETURN NVL(TO_NUMBER(config(p_clave)), p_defecto);
  EXCEPTION
    WHEN OTHERS THEN RETURN p_defecto;
  END config_num;

  FUNCTION ahora RETURN DATE IS
  BEGIN
    RETURN CAST(SYS_EXTRACT_UTC(SYSTIMESTAMP) AS DATE) + c_desfase;
  END ahora;

  FUNCTION f_usuario(p_token IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN PKG_AUTH_PROY.VALIDAR_TOKEN(p_token);
  EXCEPTION
    WHEN OTHERS THEN RETURN NULL;
  END f_usuario;

  FUNCTION cache_efimero RETURN JSON_OBJECT_T IS
  BEGIN
    RETURN JSON_OBJECT_T.parse('{"type":"ephemeral"}');
  END cache_efimero;

  ------------------------------------------------------------------------------
  -- LA API DE CLAUDE
  ------------------------------------------------------------------------------

  -- Un pedido a la API. Reintenta dos veces lo que suele ser pasajero
  -- (saturación, 5xx). Lanza si no hay conexión.
  FUNCTION llamar(
      p_ruta   IN VARCHAR2,
      p_metodo IN VARCHAR2,
      p_cuerpo IN CLOB,
      p_status OUT NUMBER
  ) RETURN CLOB IS
    l_resp CLOB;
  BEGIN
    BEGIN
      APEX_UTIL.SET_SECURITY_GROUP_ID(APEX_UTIL.FIND_SECURITY_GROUP_ID(p_workspace => c_workspace));
    EXCEPTION
      WHEN OTHERS THEN NULL;  -- en SQL Workshop ya hay workspace
    END;

    FOR l_intento IN 1 .. 3 LOOP
      APEX_WEB_SERVICE.g_request_headers.DELETE;
      APEX_WEB_SERVICE.g_request_headers(1).name  := 'Content-Type';
      APEX_WEB_SERVICE.g_request_headers(1).value := 'application/json; charset=utf-8';
      APEX_WEB_SERVICE.g_request_headers(2).name  := 'x-api-key';
      APEX_WEB_SERVICE.g_request_headers(2).value := config('API_KEY');
      APEX_WEB_SERVICE.g_request_headers(3).name  := 'anthropic-version';
      APEX_WEB_SERVICE.g_request_headers(3).value := c_version;
      -- Una clave que no es de un workspace de la consola de Claude tiene que
      -- decir a cuál va cada pedido (15/10/2026: así era la primera clave).
      IF config('WORKSPACE_ID') IS NOT NULL THEN
        APEX_WEB_SERVICE.g_request_headers(4).name  := 'anthropic-workspace-id';
        APEX_WEB_SERVICE.g_request_headers(4).value := config('WORKSPACE_ID');
      END IF;

      l_resp := APEX_WEB_SERVICE.MAKE_REST_REQUEST(
                  p_url              => c_api || p_ruta,
                  p_http_method      => p_metodo,
                  p_body             => p_cuerpo,
                  p_transfer_timeout => 120);
      p_status := APEX_WEB_SERVICE.g_status_code;

      EXIT WHEN p_status NOT IN (408, 429, 500, 502, 503, 504, 529) OR l_intento = 3;
      DBMS_SESSION.SLEEP(l_intento * 2);
    END LOOP;

    -- La clave no queda dando vueltas en la sesión que ORDS reusa.
    APEX_WEB_SERVICE.g_request_headers.DELETE;
    RETURN l_resp;
  END llamar;

  -- Un error de la API, en castellano para quien está usando el asistente.
  FUNCTION mensaje_api(p_status IN NUMBER, p_resp IN CLOB) RETURN VARCHAR2 IS
    l_msg VARCHAR2(2000);
  BEGIN
    BEGIN
      l_msg := SUBSTR(JSON_OBJECT_T.parse(p_resp).get_object('error').get_string('message'), 1, 1500);
    EXCEPTION
      WHEN OTHERS THEN l_msg := SUBSTR(DBMS_LOB.SUBSTR(p_resp, 500, 1), 1, 500);
    END;
    RETURN CASE
      WHEN p_status IN (401, 403) THEN
        'La clave de la API de Claude no es válida o no tiene permiso. Hay que cargar una nueva '
        || 'con PKG_IA_PROY.fijar_clave (ver backend/ia_asistente.sql).'
      WHEN p_status = 429 THEN
        'La API de Claude está saturada o se llegó al límite de la cuenta. Probá en un rato.'
      WHEN p_status IN (500, 502, 503, 504, 529) THEN
        'La API de Claude no está disponible en este momento. Probá en un rato.'
      ELSE
        'La API de Claude respondió ' || p_status || ': ' || l_msg
    END;
  END mensaje_api;

  ------------------------------------------------------------------------------
  -- EL ESQUEMA QUE VE LA IA
  ------------------------------------------------------------------------------

  -- Tablas que la IA no puede leer ni ver: la configuración (la clave) y el
  -- registro del asistente, y las sesiones.
  FUNCTION es_privada(p_nombre IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN p_nombre LIKE 'IA\_%' ESCAPE '\' OR p_nombre LIKE 'PROY\_TOKENS%' ESCAPE '\';
  END es_privada;

  ------------------------------------------------------------------------------
  -- Arma la descripción del esquema (tablas y vistas con sus columnas y
  -- comentarios, relaciones y bitácoras) y las listas de identificadores
  -- permitidos y prohibidos. El texto tiene que salir IGUAL mientras no cambie
  -- la estructura (todo con ORDER BY): va en la parte cacheada del pedido.
  ------------------------------------------------------------------------------
  PROCEDURE cargar_esquema IS
    l_txt   CLOB;
    l_cols  VARCHAR2(32767);
    l_jn    VARCHAR2(32767);
    l_fks   CLOB;
  BEGIN
    IF g_esquema IS NOT NULL AND g_esquema_al > SYSDATE - c_vida_esquema THEN
      RETURN;
    END IF;
    g_prohibidos.DELETE;
    g_permitidos.DELETE;

    -- Código del esquema: nada de eso se puede llamar desde una consulta.
    FOR p IN (SELECT DISTINCT object_name FROM user_objects
               WHERE object_type IN ('PACKAGE', 'PACKAGE BODY', 'PROCEDURE', 'FUNCTION', 'TYPE',
                                     'SYNONYM', 'SEQUENCE', 'LIBRARY', 'OPERATOR',
                                     'JAVA SOURCE', 'JAVA CLASS', 'JAVA RESOURCE')
                 AND object_name <> 'FN_ANIO_LECTIVO_ACTUAL') LOOP
      g_prohibidos(p.object_name) := TRUE;
    END LOOP;
    FOR p IN (SELECT object_name FROM user_objects WHERE object_type IN ('TABLE', 'VIEW')) LOOP
      IF es_privada(p.object_name) THEN
        g_prohibidos(p.object_name) := TRUE;
      END IF;
    END LOOP;

    l_txt := 'ESQUEMA DE LA BASE (Oracle). Las tablas y vistas que podés consultar, con sus '
          || 'columnas (NOMBRE TIPO) y, entre corchetes, su comentario:' || CHR(10);

    FOR o IN (SELECT o.object_name AS nombre, o.object_type AS tipo, tc.comments AS comentario
                FROM user_objects o
                LEFT JOIN user_tab_comments tc ON tc.table_name = o.object_name
               WHERE o.object_type IN ('TABLE', 'VIEW')
                 AND o.generated = 'N'
                 AND o.object_name NOT LIKE '%$%'
                 AND o.object_name NOT LIKE '%\_JN' ESCAPE '\'
                 AND o.object_name NOT LIKE 'IA\_%' ESCAPE '\'
                 AND o.object_name NOT LIKE 'PROY\_TOKENS%' ESCAPE '\'
                 AND o.object_name NOT IN ('PLAN_TABLE', 'HTMLDB_PLAN_TABLE')
               ORDER BY o.object_name) LOOP
      g_permitidos(o.nombre) := TRUE;
      l_cols := NULL;
      FOR c IN (SELECT tc.column_name, tc.data_type, cc.comments
                  FROM user_tab_columns tc
                  LEFT JOIN user_col_comments cc
                    ON cc.table_name = tc.table_name AND cc.column_name = tc.column_name
                 WHERE tc.table_name = o.nombre
                 ORDER BY tc.column_id) LOOP
        g_permitidos(c.column_name) := TRUE;
        l_cols := SUBSTR(l_cols || CASE WHEN l_cols IS NOT NULL THEN '; ' END
                  || c.column_name || ' ' || c.data_type
                  || CASE WHEN TRIM(c.comments) IS NOT NULL
                          THEN ' [' || SUBSTR(TRIM(c.comments), 1, 90) || ']' END,
                  1, 30000);
      END LOOP;
      l_txt := l_txt || CHR(10) || o.nombre
            || CASE WHEN o.tipo = 'VIEW' THEN ' (vista)' END
            || CASE WHEN TRIM(o.comentario) IS NOT NULL
                    THEN ' [' || SUBSTR(TRIM(o.comentario), 1, 200) || ']' END
            || ': ' || l_cols;
    END LOOP;

    -- Las relaciones, para que sepa cómo unir.
    FOR f IN (SELECT a.table_name AS tabla, ac.column_name AS columna,
                     r.table_name AS ref_tabla, rc.column_name AS ref_columna
                FROM user_constraints a
                JOIN user_cons_columns ac ON ac.constraint_name = a.constraint_name
                JOIN user_constraints r
                  ON r.constraint_name = a.r_constraint_name AND r.owner = a.r_owner
                JOIN user_cons_columns rc
                  ON rc.constraint_name = r.constraint_name AND rc.position = ac.position
               WHERE a.constraint_type = 'R'
                 AND a.table_name NOT LIKE '%$%'
                 AND a.table_name NOT LIKE '%\_JN' ESCAPE '\'
                 AND a.table_name NOT LIKE 'IA\_%' ESCAPE '\'
                 AND a.table_name NOT LIKE 'PROY\_TOKENS%' ESCAPE '\'
               ORDER BY a.table_name, ac.column_name, r.table_name) LOOP
      l_fks := l_fks || CHR(10) || f.tabla || '.' || f.columna
            || ' -> ' || f.ref_tabla || '.' || f.ref_columna;
    END LOOP;
    IF l_fks IS NOT NULL THEN
      l_txt := l_txt || CHR(10) || CHR(10) || 'RELACIONES (claves foráneas):' || l_fks;
    END IF;

    -- Las bitácoras: se pueden consultar, sin describir cada una.
    FOR j IN (SELECT table_name FROM user_tables
               WHERE table_name LIKE '%\_JN' ESCAPE '\'
                 AND table_name NOT LIKE '%$%'
                 AND table_name NOT LIKE 'IA\_%' ESCAPE '\'
                 AND table_name NOT LIKE 'PROY\_TOKENS%' ESCAPE '\'
               ORDER BY table_name) LOOP
      g_permitidos(j.table_name) := TRUE;
      l_jn := SUBSTR(l_jn || CASE WHEN l_jn IS NOT NULL THEN ', ' END || j.table_name, 1, 30000);
    END LOOP;
    IF l_jn IS NOT NULL THEN
      l_txt := l_txt || CHR(10) || CHR(10)
            || 'BITÁCORAS: cada tabla X_JN tiene las columnas de X más JN_OPERATION (''INS'', '
            || '''UPD'' o ''DEL''), JN_ORACLE_USER (el usuario que hizo el cambio) y JN_DATETIME '
            || '(fecha y hora del cambio, en UTC: restale 3 horas para Paraguay). En un UPD guardan '
            || 'cómo quedó la fila. Sirven para "quién cargó / modificó / borró". Son: ' || l_jn;
    END IF;

    g_esquema    := l_txt;
    g_esquema_al := SYSDATE;
  END cargar_esquema;

  ------------------------------------------------------------------------------
  -- LAS CONSULTAS DE LA IA
  ------------------------------------------------------------------------------

  -- Un identificador de la consulta que no se puede usar. Ver el encabezado.
  FUNCTION prohibido(p_tok IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    IF g_prohibidos.EXISTS(p_tok) THEN
      RETURN TRUE;
    END IF;
    IF p_tok IN ('NEXTVAL', 'CURRVAL', 'SYS', 'SYSTEM', 'PUBLIC', 'DICT', 'DICTIONARY',
                 'XMLQUERY', 'XMLTABLE', 'XMLEXISTS', 'XMLTYPE', 'URIFACTORY', 'DBURITYPE',
                 'HTTPURITYPE', 'XDBURITYPE', 'SYS_DBURIGEN', 'SYS_XMLGEN', 'HTP', 'HTF', 'OWA') THEN
      RETURN TRUE;
    END IF;
    -- Una tabla, vista o columna del sistema puede empezar como las de abajo
    -- (USER_ID, por ejemplo): esas valen.
    IF g_permitidos.EXISTS(p_tok) THEN
      RETURN FALSE;
    END IF;
    RETURN REGEXP_LIKE(p_tok,
      '^(DBMS_|UTL_|APEX_|WWV_|OWA_|ORDS_|HTMLDB_|USER_|ALL_|DBA_|CDB_|V\$|GV\$|X\$)');
  END prohibido;

  -- La consulta lista para correr, o e_sql con el motivo en g_msg.
  FUNCTION validar(p_sql IN VARCHAR2) RETURN VARCHAR2 IS
    c_patron CONSTANT VARCHAR2(30) := '[A-Z_$#][A-Z0-9_$#]*';
    l_sql VARCHAR2(32767);
    l_s   VARCHAR2(32767);
    l_pos PLS_INTEGER := 1;
    l_tok VARCHAR2(32767);

    PROCEDURE rechazar(p_msg IN VARCHAR2) IS
    BEGIN
      g_msg := p_msg;
      RAISE e_sql;
    END rechazar;
  BEGIN
    l_sql := RTRIM(TRIM(p_sql), ' ;' || CHR(9) || CHR(10) || CHR(13));
    IF l_sql IS NULL THEN
      rechazar('La consulta vino vacía.');
    END IF;
    IF LENGTH(l_sql) > 12000 THEN
      rechazar('La consulta es demasiado larga (más de 12000 caracteres).');
    END IF;
    -- La q pegada a una comilla, sin letra ni comilla antes: un literal 'q' no cuenta.
    IF REGEXP_LIKE(l_sql, '(^|[^[:alnum:]_$#''])n?q''', 'i') THEN
      rechazar('No uses literales q''...'': escribí el texto entre comillas simples, duplicando las internas.');
    END IF;

    -- Sin los textos entre comillas (ahí puede haber cualquier cosa) y sin las
    -- comillas dobles de los identificadores: lo que queda es el SQL en sí.
    l_s := UPPER(REGEXP_REPLACE(l_sql, '''([^'']|'''')*''', ' '));
    l_s := REGEXP_REPLACE(l_s, '"([^"]*)"', ' \1 ');

    IF INSTR(l_s, '''') > 0 THEN
      rechazar('Hay una comilla sin cerrar.');
    END IF;
    IF INSTR(l_s, ';') > 0 THEN
      rechazar('Una sola consulta por vez, sin punto y coma.');
    END IF;
    IF INSTR(l_s, '--') > 0 OR INSTR(l_s, '/*') > 0 THEN
      rechazar('Sin comentarios en la consulta.');
    END IF;
    IF INSTR(l_s, '@') > 0 THEN
      rechazar('Sin enlaces a otras bases (@).');
    END IF;
    IF NOT REGEXP_LIKE(l_s, '^[[:space:](]*(SELECT|WITH)[[:space:](]') THEN
      rechazar('Solo consultas SELECT (o WITH ... SELECT): el asistente no modifica datos.');
    END IF;
    IF REGEXP_LIKE(l_s, '(^|[^A-Z0-9_$#])WITH[[:space:]]+(FUNCTION|PROCEDURE)([^A-Z0-9_$#]|$)') THEN
      rechazar('Sin WITH FUNCTION ni WITH PROCEDURE.');
    END IF;
    IF REGEXP_LIKE(l_s, 'FOR[[:space:]]+UPDATE') THEN
      rechazar('Sin FOR UPDATE: el asistente solo lee.');
    END IF;

    LOOP
      l_pos := REGEXP_INSTR(l_s, c_patron, l_pos);
      EXIT WHEN l_pos = 0;
      l_tok := REGEXP_SUBSTR(l_s, c_patron, l_pos);
      IF prohibido(l_tok) THEN
        rechazar('No se puede usar ' || l_tok || ' en las consultas del asistente: solo las '
                 || 'tablas y vistas del esquema y las funciones de SQL de Oracle.');
      END IF;
      l_pos := l_pos + LENGTH(l_tok);
    END LOOP;

    RETURN l_sql;
  END validar;

  ------------------------------------------------------------------------------
  -- Corre una consulta en solo lectura y devuelve el JSON que ve la IA:
  -- {columnas, filas (arrays), cantidad_filas, cortado}. Un error de Oracle
  -- sale como e_sql con el mensaje, para que la IA lo corrija.
  ------------------------------------------------------------------------------
  PROCEDURE consultar(p_sql IN VARCHAR2, p_resultado OUT CLOB, p_filas OUT PLS_INTEGER) IS
    l_sql     VARCHAR2(32767);
    l_max     PLS_INTEGER := config_num('MAX_FILAS', 200);
    l_cur     INTEGER;
    l_desc    DBMS_SQL.DESC_TAB2;
    l_n       INTEGER;
    l_txt     VARCHAR2(32767);
    l_fecha   DATE;
    l_clob    CLOB;
    l_ign     INTEGER;
    l_res     JSON_OBJECT_T := JSON_OBJECT_T();
    l_cols    JSON_ARRAY_T  := JSON_ARRAY_T();
    l_lista   JSON_ARRAY_T  := JSON_ARRAY_T();
    l_fila    JSON_ARRAY_T;
    l_valor   VARCHAR2(4000);
    l_tam     PLS_INTEGER := 0;
    l_cortado BOOLEAN := FALSE;

    -- Tipos que no se leen: LONG, RAW, LONG RAW, objetos, REF, BLOB, BFILE, JSON.
    FUNCTION se_saltea(p_tipo IN PLS_INTEGER) RETURN BOOLEAN IS
    BEGIN
      RETURN p_tipo IN (8, 23, 24, 109, 111, 113, 114, 119);
    END se_saltea;
  BEGIN
    p_filas := 0;
    l_sql := validar(p_sql);

    -- La transacción de solo lectura tiene que ser la primera sentencia: se
    -- cierra lo anterior (no hay nada pendiente: el asistente no escribe hasta
    -- el final, en una transacción autónoma).
    COMMIT;
    SET TRANSACTION READ ONLY;

    l_cur := DBMS_SQL.OPEN_CURSOR;
    DBMS_SQL.PARSE(l_cur, l_sql, DBMS_SQL.NATIVE);
    DBMS_SQL.DESCRIBE_COLUMNS2(l_cur, l_n, l_desc);
    FOR i IN 1 .. l_n LOOP
      l_cols.append(l_desc(i).col_name);
      IF l_desc(i).col_type = c_tipo_fecha THEN
        DBMS_SQL.DEFINE_COLUMN(l_cur, i, l_fecha);
      ELSIF l_desc(i).col_type = c_tipo_clob THEN
        DBMS_SQL.DEFINE_COLUMN(l_cur, i, l_clob);
      ELSIF NOT se_saltea(l_desc(i).col_type) THEN
        DBMS_SQL.DEFINE_COLUMN(l_cur, i, l_txt, 32767);
      END IF;
    END LOOP;

    l_ign := DBMS_SQL.EXECUTE(l_cur);
    WHILE DBMS_SQL.FETCH_ROWS(l_cur) > 0 LOOP
      IF p_filas >= l_max OR l_tam > c_tope_resultado THEN
        l_cortado := TRUE;
        EXIT;
      END IF;
      l_fila := JSON_ARRAY_T();
      FOR i IN 1 .. l_n LOOP
        IF l_desc(i).col_type = c_tipo_fecha THEN
          DBMS_SQL.COLUMN_VALUE(l_cur, i, l_fecha);
          l_valor := REPLACE(TO_CHAR(l_fecha, 'YYYY-MM-DD HH24:MI:SS'), ' 00:00:00');
        ELSIF l_desc(i).col_type = c_tipo_clob THEN
          DBMS_SQL.COLUMN_VALUE(l_cur, i, l_clob);
          l_valor := DBMS_LOB.SUBSTR(l_clob, c_tope_valor, 1);
        ELSIF se_saltea(l_desc(i).col_type) THEN
          l_valor := '[dato binario]';
        ELSE
          DBMS_SQL.COLUMN_VALUE(l_cur, i, l_txt);
          l_valor := SUBSTR(l_txt, 1, c_tope_valor);
        END IF;
        IF l_valor IS NULL THEN
          l_fila.append_null;
        ELSE
          l_fila.append(l_valor);
          l_tam := l_tam + LENGTH(l_valor) + 3;
        END IF;
      END LOOP;
      l_lista.append(l_fila);
      p_filas := p_filas + 1;
    END LOOP;
    DBMS_SQL.CLOSE_CURSOR(l_cur);
    COMMIT;  -- termina la transacción de solo lectura

    l_res.put('columnas', l_cols);
    l_res.put('filas', l_lista);
    l_res.put('cantidad_filas', p_filas);
    l_res.put('cortado', l_cortado);
    IF l_cortado THEN
      l_res.put('aviso', 'Hay más filas de las que se devolvieron: agregá (COUNT, SUM, GROUP BY) '
                         || 'o filtrá en la consulta.');
    END IF;
    p_resultado := l_res.to_clob;
  EXCEPTION
    WHEN e_sql THEN
      RAISE;
    WHEN OTHERS THEN
      g_msg := SUBSTR(SQLERRM, 1, 1000);
      IF l_cur IS NOT NULL AND DBMS_SQL.IS_OPEN(l_cur) THEN
        DBMS_SQL.CLOSE_CURSOR(l_cur);
      END IF;
      ROLLBACK;
      RAISE e_sql;
  END consultar;

  ------------------------------------------------------------------------------
  -- LO QUE SE LE DICE A LA IA
  ------------------------------------------------------------------------------

  -- Las instrucciones. Fijas (salvo MAX_FILAS): van en la parte cacheada.
  FUNCTION instrucciones(p_max IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN REPLACE(q'~Sos el asistente del sistema de gestión de Juventud con Valores (Paraguay), un programa de formación en valores que trabaja en instituciones educativas: los facilitadores dan intervenciones (clases) en las instituciones siguiendo los índices de los manuales Ser, Hacer, Tener, Carácter, Visión, Coraje y Liderazgo. Usan el sistema coordinadores, administrativos y facilitadores, desde la web y desde la app de Android (que es el mismo sitio).

Respondés dos tipos de preguntas.

1. Cómo se usa el sistema: pantallas, formularios, filtros, reportes, permisos. Basate en el MANUAL DEL SISTEMA que viene más abajo. Está escrito para el programador: traducilo a lo que el usuario ve y toca (qué botón, dónde, qué pasa) y no menciones archivos, paquetes, scripts, endpoints ni nombres de tablas, salvo que te los pidan. Si el manual no cubre algo, decilo en vez de suponer cómo funciona.

2. Preguntas sobre los datos: cuántos, quiénes, cuándo, totales, listados. Usá la herramienta consultar_sql, con SQL de Oracle sobre el ESQUEMA de más abajo.
- Nunca inventes ni estimes datos: cada número o nombre que des tiene que salir de una consulta de esta conversación. Si no hay datos, decilo.
- Resolvé en la base lo que puedas (COUNT, SUM, GROUP BY, FETCH FIRST n ROWS ONLY) en vez de traer filas sueltas: cada consulta devuelve como máximo {MAX_FILAS} filas.
- Para buscar por nombre usá UPPER(columna) LIKE UPPER('%texto%') y probá variantes con y sin tilde. Si hay varias coincidencias, mostralas o preguntá cuál.
- Si una columna o un código no es obvio (un ESTADO 'A'/'I', 'S'/'N'), mirá primero sus valores distintos.
- Si una consulta da error, leé el mensaje, corregila y volvé a intentar.
- Las fechas de las tablas están en hora de Paraguay, salvo JN_DATETIME de las bitácoras, que está en UTC.
- Si la pregunta no dice el período (o el año lectivo, la institución...), elegí el más razonable y decí cuál usaste.
- Solo podés leer. Si te piden cargar, cambiar o borrar algo, explicá en qué pantalla y cómo se hace.

Cómo responder:
- En español, con voseo, como el resto del sistema ("tocá", "elegí", "podés").
- Breve y al punto: primero la respuesta, después el detalle si hace falta.
- En markdown: negrita para los números clave, listas cortas y tablas cuando haya varias filas (hasta unas 15; si hay más, resumí y decí cuántas son).
- El usuario ve solo tu respuesta: no muestres SQL ni nombres de tablas o columnas. Si pregunta cómo sacaste un número, explicalo con palabras (qué contaste, de qué período, con qué filtro).
- Si la pregunta es ambigua, respondé la interpretación más razonable, decí cuál fue y ofrecé la otra.~',
      '{MAX_FILAS}', TO_CHAR(p_max));
  END instrucciones;

  FUNCTION herramientas(p_max IN PLS_INTEGER) RETURN JSON_ARRAY_T IS
  BEGIN
    RETURN JSON_ARRAY_T.parse(REPLACE(q'~[{
      "name": "consultar_sql",
      "description": "Corre UNA consulta SELECT (o WITH ... SELECT) de solo lectura en la base Oracle del sistema y devuelve las columnas y hasta {MAX_FILAS} filas en JSON. Usala para toda pregunta sobre registros. Sin punto y coma, sin comentarios, sin @dblink y sin llamar paquetes ni funciones propias del esquema (salvo FN_ANIO_LECTIVO_ACTUAL()); las funciones de SQL de Oracle (TO_CHAR, TRUNC, COUNT, LISTAGG...) sí. Si el resultado viene con cortado = true hay más filas: agregá o filtrá.",
      "input_schema": {
        "type": "object",
        "properties": {
          "sql": {"type": "string", "description": "La consulta, en SQL de Oracle."},
          "motivo": {"type": "string", "description": "Qué averigua esta consulta, en pocas palabras y en español. Queda en el registro del asistente."}
        },
        "required": ["sql", "motivo"],
        "additionalProperties": false
      }
    }]~', '{MAX_FILAS}', TO_CHAR(p_max)));
  END herramientas;

  -- Lo que cambia en cada pregunta: va después de lo cacheado.
  FUNCTION contexto(p_usuario IN VARCHAR2, p_nombre IN VARCHAR2, p_pantalla IN VARCHAR2)
    RETURN VARCHAR2
  IS
    l_anio VARCHAR2(20);
  BEGIN
    BEGIN
      EXECUTE IMMEDIATE 'SELECT TO_CHAR(FN_ANIO_LECTIVO_ACTUAL()) FROM dual' INTO l_anio;
    EXCEPTION
      WHEN OTHERS THEN l_anio := NULL;
    END;
    RETURN 'CONTEXTO DE ESTA PREGUNTA' || CHR(10)
      || '- Usuario de la sesión: ' || p_usuario
      || CASE WHEN p_nombre IS NOT NULL AND UPPER(p_nombre) <> p_usuario
              THEN ' (' || p_nombre || ')' END
      || '. Si pregunta por "mis" datos, buscalo por ese usuario.' || CHR(10)
      || '- Ahora: ' || TO_CHAR(ahora, 'fmDay dd/mm/yyyy HH24:MI', 'NLS_DATE_LANGUAGE=SPANISH')
      || ' (hora de Paraguay).' || CHR(10)
      || CASE WHEN l_anio IS NOT NULL
              THEN '- Año lectivo vigente: ' || l_anio || ' (FN_ANIO_LECTIVO_ACTUAL()).' || CHR(10) END
      || '- Pantalla que tiene abierta: ' || NVL(p_pantalla, 'ninguna (el Inicio)')
      || '. "Esta pantalla" es esa.';
  END contexto;

  ------------------------------------------------------------------------------
  -- REGISTRO: en una transacción autónoma, para que quede aunque algo falle
  -- y sin tocar la de solo lectura.
  ------------------------------------------------------------------------------
  PROCEDURE registrar(
      p_usuario IN VARCHAR2, p_pantalla IN VARCHAR2, p_pregunta IN CLOB, p_respuesta IN CLOB,
      p_consultas IN CLOB, p_vueltas IN NUMBER, p_entrada IN NUMBER, p_salida IN NUMBER,
      p_cache_leidos IN NUMBER, p_cache_escritos IN NUMBER, p_ms IN NUMBER,
      p_modelo IN VARCHAR2, p_error IN VARCHAR2)
  IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    -- En una variable: una función privada del paquete no se puede usar en SQL.
    l_fecha DATE := ahora;
  BEGIN
    INSERT INTO ia_consultas (usuario, fecha, pantalla, pregunta, respuesta, consultas, vueltas,
                              tokens_entrada, tokens_salida, tokens_cache_leidos,
                              tokens_cache_escritos, milisegundos, modelo, error)
    VALUES (p_usuario, l_fecha, SUBSTR(p_pantalla, 1, 200), p_pregunta, p_respuesta, p_consultas,
            p_vueltas, p_entrada, p_salida, p_cache_leidos, p_cache_escritos, p_ms,
            p_modelo, SUBSTR(p_error, 1, 4000));
    COMMIT;
  END registrar;

  /* ---------------------------------------------------------------------- */
  /* PREGUNTAR                                                              */
  /* ---------------------------------------------------------------------- */

  PROCEDURE preguntar(p_token IN VARCHAR2, p_cuerpo IN CLOB) IS
    l_usuario   VARCHAR2(255) := f_usuario(p_token);
    l_inicio    PLS_INTEGER   := DBMS_UTILITY.GET_TIME;
    l_cuerpo    JSON_OBJECT_T;
    l_pregunta  VARCHAR2(32767);
    l_hist      JSON_ARRAY_T;
    l_manual    CLOB;
    l_pantalla  VARCHAR2(200);
    l_nombre    VARCHAR2(200);
    l_modelo    VARCHAR2(60);
    l_esfuerzo  VARCHAR2(20);
    l_limite    NUMBER;
    l_max_filas PLS_INTEGER;
    l_usadas    NUMBER;
    l_hoy       DATE;

    l_sistema   JSON_ARRAY_T := JSON_ARRAY_T();
    l_mensajes  JSON_ARRAY_T := JSON_ARRAY_T();
    l_herr      JSON_ARRAY_T;
    l_consultas JSON_ARRAY_T := JSON_ARRAY_T();
    l_req       JSON_OBJECT_T;
    l_resp      JSON_OBJECT_T;
    l_uso       JSON_OBJECT_T;
    l_bloque    JSON_OBJECT_T;
    l_msg       JSON_OBJECT_T;
    l_item      JSON_OBJECT_T;
    l_input     JSON_OBJECT_T;
    l_res_tool  JSON_OBJECT_T;
    l_contenido JSON_ARRAY_T;
    l_results   JSON_ARRAY_T;

    l_status    NUMBER;
    l_txt_resp  CLOB;
    l_stop      VARCHAR2(40);
    l_texto     CLOB;
    l_respuesta CLOB;
    l_rol       VARCHAR2(20);
    l_resultado CLOB;
    l_filas     PLS_INTEGER;
    l_sql       VARCHAR2(32767);
    l_motivo    VARCHAR2(4000);
    l_vueltas   PLS_INTEGER := 0;
    l_n_sql     PLS_INTEGER := 0;
    l_entrada   NUMBER := 0;
    l_salida    NUMBER := 0;
    l_leidos    NUMBER := 0;
    l_escritos  NUMBER := 0;
    l_out       JSON_OBJECT_T;

    PROCEDURE anotar_consulta(p_filas IN PLS_INTEGER, p_error IN VARCHAR2) IS
      l_c JSON_OBJECT_T := JSON_OBJECT_T();
    BEGIN
      l_c.put('motivo', l_motivo);
      l_c.put('sql', l_sql);
      IF p_filas IS NULL THEN l_c.put_null('filas'); ELSE l_c.put('filas', p_filas); END IF;
      IF p_error IS NULL THEN l_c.put_null('error'); ELSE l_c.put('error', p_error); END IF;
      l_consultas.append(l_c);
    END anotar_consulta;

    FUNCTION ms RETURN NUMBER IS
    BEGIN
      RETURN (DBMS_UTILITY.GET_TIME - l_inicio) * 10;
    END ms;

    PROCEDURE fallar(p_status IN NUMBER, p_titulo IN VARCHAR2, p_detalle IN VARCHAR2) IS
    BEGIN
      registrar(l_usuario, l_pantalla, l_pregunta, NULL, l_consultas.to_clob, l_vueltas,
                l_entrada, l_salida, l_leidos, l_escritos, ms, l_modelo, p_detalle);
      p_error(p_status, p_titulo, p_detalle);
    END fallar;
  BEGIN
    -- Solo sesión: lo usa cualquiera que entró (Jose, 15/10/2026).
    IF l_usuario IS NULL THEN
      p_error(401, 'Unauthorized', 'Token invalido o expirado');
      RETURN;
    END IF;

    -- El pedido.
    BEGIN
      l_cuerpo   := JSON_OBJECT_T.parse(p_cuerpo);
      l_pregunta := TRIM(l_cuerpo.get_string('pregunta'));
      l_hist     := l_cuerpo.get_array('historial');
      l_manual   := l_cuerpo.get_clob('manual');
      l_pantalla := SUBSTR(TRIM(l_cuerpo.get_string('pantalla')), 1, 200);
      l_nombre   := SUBSTR(TRIM(l_cuerpo.get_string('nombre')), 1, 200);
    EXCEPTION
      WHEN OTHERS THEN
        p_error(400, 'Bad Request', 'El pedido no es un JSON válido: ' || SQLERRM);
        RETURN;
    END;
    IF l_pregunta IS NULL THEN
      p_error(400, 'Bad Request', 'Falta la pregunta');
      RETURN;
    END IF;
    IF LENGTH(l_pregunta) > c_max_pregunta THEN
      p_error(400, 'Bad Request', 'La pregunta no puede pasar de ' || c_max_pregunta || ' caracteres');
      RETURN;
    END IF;

    -- Configuración y límite del día.
    IF config('API_KEY') IS NULL THEN
      p_error(503, 'Service Unavailable', 'El asistente no está configurado: falta cargar la clave '
              || 'de la API (ver backend/ia_asistente.sql)');
      RETURN;
    END IF;
    l_modelo    := config('MODELO', 'claude-haiku-5-5');
    l_esfuerzo  := LOWER(config('ESFUERZO', 'medium'));
    IF l_esfuerzo NOT IN ('low', 'medium', 'high') THEN
      l_esfuerzo := 'medium';
    END IF;
    l_limite    := config_num('LIMITE_DIARIO', 60);
    l_max_filas := config_num('MAX_FILAS', 200);

    l_hoy := TRUNC(ahora);
    SELECT COUNT(*) INTO l_usadas FROM ia_consultas
     WHERE usuario = l_usuario AND fecha >= l_hoy AND error IS NULL;
    IF l_usadas >= l_limite THEN
      p_error(429, 'Too Many Requests', 'Llegaste al límite de ' || l_limite
              || ' preguntas por día. Mañana se renueva.');
      RETURN;
    END IF;

    -- Lo fijo primero (herramientas, instrucciones + esquema, manual) y con
    -- cache_control al final de eso; lo que cambia en cada pregunta, después.
    cargar_esquema;
    l_herr := herramientas(l_max_filas);

    l_bloque := JSON_OBJECT_T();
    l_bloque.put('type', 'text');
    l_bloque.put('text', instrucciones(l_max_filas) || CHR(10) || CHR(10) || g_esquema);
    IF l_manual IS NULL OR DBMS_LOB.GETLENGTH(l_manual) = 0 THEN
      l_bloque.put('cache_control', cache_efimero);
    END IF;
    l_sistema.append(l_bloque);

    IF l_manual IS NOT NULL AND DBMS_LOB.GETLENGTH(l_manual) > 0 THEN
      l_bloque := JSON_OBJECT_T();
      l_bloque.put('type', 'text');
      l_bloque.put('text', 'MANUAL DEL SISTEMA (la documentación de cada pantalla, en markdown):'
                           || CHR(10) || CHR(10) || l_manual);
      l_bloque.put('cache_control', cache_efimero);
      l_sistema.append(l_bloque);
    END IF;

    l_bloque := JSON_OBJECT_T();
    l_bloque.put('type', 'text');
    l_bloque.put('text', contexto(l_usuario, l_nombre, l_pantalla));
    l_sistema.append(l_bloque);

    -- La conversación: los últimos mensajes (solo texto) y la pregunta nueva.
    -- Tiene que empezar con uno del usuario.
    IF l_hist IS NOT NULL THEN
      FOR i IN GREATEST(0, l_hist.get_size - c_max_historial) .. l_hist.get_size - 1 LOOP
        IF l_hist.get(i).is_object THEN
          l_item := TREAT(l_hist.get(i) AS JSON_OBJECT_T);
          l_rol := CASE l_item.get_string('rol')
                     WHEN 'usuario'   THEN 'user'
                     WHEN 'asistente' THEN 'assistant'
                   END;
          l_texto := l_item.get_clob('texto');
          IF l_rol IS NOT NULL AND NVL(DBMS_LOB.GETLENGTH(l_texto), 0) > 0
             AND (l_mensajes.get_size > 0 OR l_rol = 'user') THEN
            l_msg := JSON_OBJECT_T();
            l_msg.put('role', l_rol);
            l_msg.put('content', l_texto);
            l_mensajes.append(l_msg);
          END IF;
        END IF;
      END LOOP;
    END IF;
    l_msg := JSON_OBJECT_T();
    l_msg.put('role', 'user');
    l_msg.put('content', l_pregunta);
    l_mensajes.append(l_msg);

    -- Idas y vueltas: mientras la IA pida consultas, se corren y se le
    -- devuelven. En la última vuelta ya no puede pedir más (tool_choice none).
    FOR l_vuelta IN 1 .. c_max_vueltas LOOP
      l_vueltas := l_vuelta;
      l_req := JSON_OBJECT_T();
      l_req.put('model', l_modelo);
      l_req.put('max_tokens', c_max_tokens);
      l_req.put('system', l_sistema);
      l_req.put('tools', l_herr);
      l_req.put('messages', l_mensajes);
      l_req.put('output_config', JSON_OBJECT_T.parse('{"effort":"' || l_esfuerzo || '"}'));
      -- Cachea también la conversación entre una vuelta y la siguiente.
      l_req.put('cache_control', cache_efimero);
      IF l_vuelta = c_max_vueltas THEN
        l_req.put('tool_choice', JSON_OBJECT_T.parse('{"type":"none"}'));
      END IF;

      BEGIN
        l_txt_resp := llamar('messages', 'POST', l_req.to_clob, l_status);
      EXCEPTION
        WHEN OTHERS THEN
          g_msg := 'No se pudo conectar con la API de Claude: ' || SUBSTR(SQLERRM, 1, 500);
          RAISE e_api;
      END;
      IF NVL(l_status, 0) <> 200 THEN
        g_msg := mensaje_api(l_status, l_txt_resp);
        RAISE e_api;
      END IF;

      l_resp := JSON_OBJECT_T.parse(l_txt_resp);
      l_uso  := l_resp.get_object('usage');
      IF l_uso IS NOT NULL THEN
        l_entrada  := l_entrada  + NVL(l_uso.get_number('input_tokens'), 0);
        l_salida   := l_salida   + NVL(l_uso.get_number('output_tokens'), 0);
        l_leidos   := l_leidos   + NVL(l_uso.get_number('cache_read_input_tokens'), 0);
        l_escritos := l_escritos + NVL(l_uso.get_number('cache_creation_input_tokens'), 0);
      END IF;
      l_stop      := l_resp.get_string('stop_reason');
      l_contenido := l_resp.get_array('content');

      l_texto := NULL;
      FOR i IN 0 .. l_contenido.get_size - 1 LOOP
        l_bloque := TREAT(l_contenido.get(i) AS JSON_OBJECT_T);
        IF l_bloque.get_string('type') = 'text' THEN
          IF l_texto IS NOT NULL THEN
            l_texto := l_texto || CHR(10) || CHR(10);
          END IF;
          l_texto := l_texto || l_bloque.get_clob('text');
        END IF;
      END LOOP;

      IF l_stop = 'tool_use' THEN
        -- La respuesta va ENTERA a la conversación (con lo que pensó, tal cual):
        -- la API la necesita así para seguir.
        l_msg := JSON_OBJECT_T();
        l_msg.put('role', 'assistant');
        l_msg.put('content', l_contenido);
        l_mensajes.append(l_msg);

        -- Todas las consultas que pidió, y todas las respuestas en UN mensaje.
        l_results := JSON_ARRAY_T();
        FOR i IN 0 .. l_contenido.get_size - 1 LOOP
          l_bloque := TREAT(l_contenido.get(i) AS JSON_OBJECT_T);
          IF l_bloque.get_string('type') = 'tool_use' THEN
            l_res_tool := JSON_OBJECT_T();
            l_res_tool.put('type', 'tool_result');
            l_res_tool.put('tool_use_id', l_bloque.get_string('id'));
            l_input  := l_bloque.get_object('input');
            l_sql    := NULL;
            l_motivo := NULL;
            IF l_input IS NOT NULL THEN
              l_sql    := l_input.get_string('sql');
              l_motivo := SUBSTR(l_input.get_string('motivo'), 1, 500);
            END IF;

            IF l_bloque.get_string('name') <> 'consultar_sql' THEN
              l_res_tool.put('content', 'Esa herramienta no existe: solo está consultar_sql.');
              l_res_tool.put('is_error', TRUE);
            ELSIF l_n_sql >= c_max_consultas THEN
              l_res_tool.put('content', 'Ya se corrieron ' || c_max_consultas || ' consultas para '
                             || 'esta pregunta: respondé con lo que tenés.');
              l_res_tool.put('is_error', TRUE);
            ELSE
              l_n_sql := l_n_sql + 1;
              BEGIN
                consultar(l_sql, l_resultado, l_filas);
                l_res_tool.put('content', l_resultado);
                anotar_consulta(l_filas, NULL);
              EXCEPTION
                WHEN e_sql THEN
                  l_res_tool.put('content', 'Error: ' || g_msg);
                  l_res_tool.put('is_error', TRUE);
                  anotar_consulta(NULL, g_msg);
              END;
            END IF;
            l_results.append(l_res_tool);
          END IF;
        END LOOP;

        l_msg := JSON_OBJECT_T();
        l_msg.put('role', 'user');
        l_msg.put('content', l_results);
        l_mensajes.append(l_msg);
      ELSIF l_stop = 'refusal' THEN
        l_respuesta := 'No puedo ayudarte con esa pregunta. Probá reformularla.';
        EXIT;
      ELSE
        -- end_turn, y también max_tokens: lo que haya escrito.
        l_respuesta := l_texto;
        IF l_stop = 'max_tokens' AND l_respuesta IS NOT NULL THEN
          l_respuesta := l_respuesta || CHR(10) || CHR(10) || '_(La respuesta quedó cortada por larga.)_';
        END IF;
        EXIT;
      END IF;
    END LOOP;

    IF l_respuesta IS NULL OR DBMS_LOB.GETLENGTH(l_respuesta) = 0 THEN
      l_respuesta := 'No llegué a una respuesta. Probá con una pregunta más concreta.';
    END IF;

    registrar(l_usuario, l_pantalla, l_pregunta, l_respuesta, l_consultas.to_clob, l_vueltas,
              l_entrada, l_salida, l_leidos, l_escritos, ms, l_modelo, NULL);

    l_out := JSON_OBJECT_T();
    l_out.put('success', TRUE);
    l_out.put('respuesta', l_respuesta);
    l_out.put('consultas', l_consultas);
    l_out.put('usadas_hoy', l_usadas + 1);
    l_out.put('limite', l_limite);
    abrir_json;
    imprimir(l_out.to_clob);
  EXCEPTION
    WHEN e_api THEN
      ROLLBACK;
      fallar(502, 'Bad Gateway', g_msg);
    WHEN OTHERS THEN
      ROLLBACK;
      fallar(500, 'Internal Server Error', 'Error: ' || SUBSTR(SQLERRM, 1, 1000));
  END preguntar;

  /* ---------------------------------------------------------------------- */
  /* A MANO, EN SQL COMMANDS                                                */
  /* ---------------------------------------------------------------------- */

  PROCEDURE fijar_clave(p_clave IN VARCHAR2) IS
  BEGIN
    IF TRIM(p_clave) IS NULL THEN
      DELETE FROM ia_config WHERE clave = 'API_KEY';
      COMMIT;
      DBMS_OUTPUT.PUT_LINE('[OK]   Clave borrada: el asistente queda apagado.');
      RETURN;
    END IF;
    MERGE INTO ia_config t
    USING (SELECT 'API_KEY' AS clave, TRIM(p_clave) AS valor FROM dual) s
       ON (t.clave = s.clave)
     WHEN MATCHED THEN UPDATE SET t.valor = s.valor, t.modificado_el = SYSDATE
     WHEN NOT MATCHED THEN INSERT (clave, valor) VALUES (s.clave, s.valor);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('[OK]   Clave guardada (termina en ...' || SUBSTR(TRIM(p_clave), -4)
                         || '). Probala con: BEGIN PKG_IA_PROY.probar; END;');
  END fijar_clave;

  PROCEDURE fijar_workspace_id(p_id IN VARCHAR2) IS
  BEGIN
    IF TRIM(p_id) IS NULL THEN
      DELETE FROM ia_config WHERE clave = 'WORKSPACE_ID';
      COMMIT;
      DBMS_OUTPUT.PUT_LINE('[OK]   Workspace borrado: la clave tiene que ser de un workspace.');
      RETURN;
    END IF;
    MERGE INTO ia_config t
    USING (SELECT 'WORKSPACE_ID' AS clave, TRIM(p_id) AS valor FROM dual) s
       ON (t.clave = s.clave)
     WHEN MATCHED THEN UPDATE SET t.valor = s.valor, t.modificado_el = SYSDATE
     WHEN NOT MATCHED THEN INSERT (clave, valor) VALUES (s.clave, s.valor);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('[OK]   Workspace ' || TRIM(p_id) || ' guardado.');
    probar;
  END fijar_workspace_id;

  PROCEDURE probar IS
    l_status NUMBER;
    l_resp   CLOB;
    l_modelo VARCHAR2(60) := config('MODELO', 'claude-haiku-5-5');
  BEGIN
    IF config('API_KEY') IS NULL THEN
      DBMS_OUTPUT.PUT_LINE('[ERROR] Falta la clave: BEGIN PKG_IA_PROY.fijar_clave(''sk-ant-...''); END;');
      RETURN;
    END IF;
    l_resp := llamar('models/' || l_modelo, 'GET', NULL, l_status);
    IF l_status = 200 THEN
      DBMS_OUTPUT.PUT_LINE('[OK]   Oracle llega a la API de Claude y la clave sirve. Modelo: '
                           || JSON_OBJECT_T.parse(l_resp).get_string('display_name')
                           || ' (' || l_modelo || ').');
    ELSE
      DBMS_OUTPUT.PUT_LINE('[ERROR] ' || mensaje_api(l_status, l_resp));
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('[ERROR] No se pudo conectar con https://api.anthropic.com: ' || SQLERRM);
      DBMS_OUTPUT.PUT_LINE('        Si es ORA-24247 (ACL) o un error de certificado, la instancia no');
      DBMS_OUTPUT.PUT_LINE('        deja salir a ese host: el asistente no puede correr en Oracle.');
  END probar;

  PROCEDURE probar_consulta(p_sql IN VARCHAR2) IS
    l_res   CLOB;
    l_filas PLS_INTEGER;
  BEGIN
    g_esquema := NULL;  -- que tome la estructura de este momento
    cargar_esquema;
    consultar(p_sql, l_res, l_filas);
    DBMS_OUTPUT.PUT_LINE('[OK]   ' || l_filas || ' fila(s):');
    DBMS_OUTPUT.PUT_LINE(DBMS_LOB.SUBSTR(l_res, 4000, 1));
  EXCEPTION
    WHEN e_sql THEN
      DBMS_OUTPUT.PUT_LINE('[RECHAZADA] ' || g_msg);
  END probar_consulta;

END PKG_IA_PROY;
/

--------------------------------------------------------------------------------
-- === 4) ENDPOINTS ORDS ======================================================
--------------------------------------------------------------------------------

DECLARE
  c_token CONSTANT VARCHAR2(400) := '
    l_token := :authorization;
    IF l_token IS NOT NULL THEN
        l_pos := INSTR(UPPER(l_token), ''BEARER '');
        IF l_pos > 0 THEN
            l_token := TRIM(SUBSTR(l_token, l_pos + 7));
        END IF;
    END IF;';
BEGIN
  FOR m IN (SELECT 'POST' AS v FROM dual UNION ALL SELECT 'OPTIONS' FROM dual) LOOP
    BEGIN ORDS.DELETE_HANDLER('proy', 'ia/preguntar', m.v); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
  BEGIN ORDS.DELETE_TEMPLATE('proy', 'ia/preguntar'); EXCEPTION WHEN OTHERS THEN NULL; END;

  ORDS.DEFINE_TEMPLATE(p_module_name => 'proy', p_pattern => 'ia/preguntar',
                       p_priority => 0, p_etag_type => 'NONE');

  -- :body_text y no campos sueltos: ver el encabezado.
  ORDS.DEFINE_HANDLER(
      p_module_name => 'proy',
      p_pattern     => 'ia/preguntar',
      p_method      => 'POST',
      p_source_type => 'plsql/block',
      p_source      => 'DECLARE l_token VARCHAR2(256); l_pos PLS_INTEGER; BEGIN' || c_token || '
    PKG_IA_PROY.PREGUNTAR(p_token => l_token, p_cuerpo => :body_text);
END;');
  ORDS.DEFINE_PARAMETER(
      p_module_name        => 'proy',
      p_pattern            => 'ia/preguntar',
      p_method             => 'POST',
      p_name               => 'Authorization',
      p_bind_variable_name => 'authorization',
      p_source_type        => 'HEADER',
      p_param_type         => 'STRING',
      p_access_method      => 'IN');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('[OK]   Handler de ia/preguntar publicado.');
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('[ERROR] No se pudo publicar: ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('        Revisa que el modulo ORDS proy exista (corre backend/auth.sql).');
    RAISE;
END;
/

-- Preflight CORS: producción (Pages) y el APK le pegan DIRECTO a ORDS.
BEGIN
  ORDS.DEFINE_HANDLER(
      p_module_name => 'proy',
      p_pattern     => 'ia/preguntar',
      p_method      => 'OPTIONS',
      p_source_type => 'plsql/block',
      p_source      => q'~
BEGIN
    OWA_UTIL.MIME_HEADER('text/plain', FALSE);
    HTP.P('Access-Control-Allow-Origin: *');
    HTP.P('Access-Control-Allow-Methods: POST, OPTIONS');
    HTP.P('Access-Control-Allow-Headers: Authorization, Content-Type');
    HTP.P('Access-Control-Max-Age: 86400');
    OWA_UTIL.HTTP_HEADER_CLOSE;
END;
~');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('[OK]   Preflight OPTIONS publicado.');
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('[WARN] Preflight OPTIONS no se pudo publicar: ' || SQLERRM);
END;
/

--------------------------------------------------------------------------------
-- === 5) VERIFICACIÓN ========================================================
--------------------------------------------------------------------------------

DECLARE
  l_estado user_objects.status%TYPE;
  l_pagina NUMBER;
  l_clave  NUMBER;
BEGIN
  FOR o IN (SELECT 'PKG_IA_PROY' AS nombre, 'PACKAGE BODY' AS tipo FROM dual) LOOP
    BEGIN
      SELECT status INTO l_estado FROM user_objects
       WHERE object_name = o.nombre AND object_type = o.tipo;
      IF l_estado = 'VALID' THEN
        DBMS_OUTPUT.PUT_LINE('[OK]   ' || o.nombre || ' compilado.');
      ELSE
        DBMS_OUTPUT.PUT_LINE('[ERROR] ' || o.nombre || ' quedo INVALID.');
        FOR e IN (SELECT line, text FROM user_errors
                   WHERE name = o.nombre ORDER BY type, sequence) LOOP
          DBMS_OUTPUT.PUT_LINE('        L' || e.line || ': ' || e.text);
        END LOOP;
      END IF;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('[ERROR] ' || o.nombre || ' no se creo.');
    END;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('       POST   ia/preguntar');

  -- La primera versión pedía la página /asistente: si quedó cargada, sobra.
  BEGIN
    EXECUTE IMMEDIATE 'SELECT MAX(app_page_id) FROM menu_paginas WHERE ruta = ''/asistente'''
      INTO l_pagina;
  EXCEPTION
    WHEN OTHERS THEN l_pagina := NULL;
  END;
  IF l_pagina IS NOT NULL THEN
    DBMS_OUTPUT.PUT_LINE('[INFO] La pagina ' || l_pagina || ' (/asistente) ya no hace falta: el asistente');
    DBMS_OUTPUT.PUT_LINE('       es para todos. Se puede borrar en Crear paginas.');
  END IF;

  SELECT COUNT(*) INTO l_clave FROM ia_config WHERE clave = 'API_KEY' AND valor IS NOT NULL;
  IF l_clave = 0 THEN
    DBMS_OUTPUT.PUT_LINE('[INFO] Falta la clave de la API. En SQL Commands:');
    DBMS_OUTPUT.PUT_LINE('       BEGIN PKG_IA_PROY.fijar_clave(''sk-ant-...''); END;');
  ELSE
    EXECUTE IMMEDIATE 'BEGIN PKG_IA_PROY.probar; END;';
  END IF;
END;
/
```

## Anexo B: `src/lib/asistente.ts`

Adaptar según 3.2 (`armarManual`, `GUIA_BASICA`).

```ts
/**
 * El asistente con IA (15/10/2026): un chat en un botón flotante, en todas las
 * pantallas. Contrato del backend: `backend/ia_asistente.sql`.
 *
 * La IA corre en Oracle (`PKG_IA_PROY`, que llama a la API de Claude): acá
 * solo se manda la pregunta con lo que el backend no sabe —la conversación, la
 * pantalla abierta y el manual— y se muestra la respuesta.
 *
 * - **Quién lo ve:** todos los que entran (Jose, 15/10/2026). No depende de
 *   Roles de páginas ni es una pantalla del menú; el gasto lo frena el límite
 *   de preguntas por día del backend.
 * - **La conversación vive solo en memoria y dura lo que la sesión**: va
 *   atada al token, así que recargar, salir o entrar con otro usuario la
 *   borra. Puede traer datos de cualquier tabla; no se escribe en el disco.
 * - **El manual es el README** (las secciones de las pantallas), importado como
 *   texto: así la IA sabe de cada pantalla nueva con el deploy, sin volver a
 *   correr el `.sql`. Se descarga recién al abrir el chat.
 */

import { useSyncExternalStore } from "react";

import { authFetch, getSesion } from "@/lib/api";

/*
 * El backend devuelve también `consultas` (el SQL que corrió la IA), pero no
 * se muestra: el usuario ve solo la respuesta (15/10/2026, a pedido). Queda en
 * IA_CONSULTAS.CONSULTAS para revisarlo desde Oracle.
 */
export type MensajeIA = {
  id: string;
  rol: "usuario" | "asistente";
  texto: string;
  /** Un fallo (sin respuesta): no se le manda a la IA como historial. */
  error?: boolean;
};

type Estado = {
  /**
   * De qué sesión es: el token, que cambia en cada login. Con otro, la
   * conversación arranca de cero.
   */
  sesion: string;
  mensajes: MensajeIA[];
  /** Esperando la respuesta (puede tardar: la IA corre consultas). */
  pendiente: boolean;
  usadasHoy: number | null;
  limite: number | null;
  /**
   * El panel abierto. Acá y no en el componente: cada pantalla monta su
   * AppShell, y en la computadora el panel sigue abierto al navegar (para
   * preguntar por la pantalla nueva).
   */
  abierto: boolean;
};

const VACIO: Omit<Estado, "sesion"> = {
  mensajes: [],
  pendiente: false,
  usadasHoy: null,
  limite: null,
  abierto: false,
};

/* -------------------------------------------------------------------------- */
/* La conversación: un store de módulo                                         */
/* -------------------------------------------------------------------------- */

/*
 * De módulo y no en un componente: el chat sobrevive a la navegación (cada
 * pantalla monta su propio AppShell) y una respuesta que llega con el panel
 * cerrado no se pierde.
 */
let estado: Estado = { sesion: "", ...VACIO };
const oyentes = new Set<() => void>();

function fijar(parcial: Partial<Estado>) {
  estado = { ...estado, ...parcial };
  oyentes.forEach((f) => f());
}

const tokenActual = () => getSesion()?.token ?? "";

/** La conversación de esta sesión (la de una anterior, si quedó, se descarta). */
function actual(): Estado {
  const sesion = tokenActual();
  if (estado.sesion !== sesion) estado = { sesion, ...VACIO };
  return estado;
}

function suscribir(f: () => void) {
  oyentes.add(f);
  return () => oyentes.delete(f);
}

export function useAsistente() {
  return useSyncExternalStore(suscribir, actual, actual);
}

export function abrirAsistente(abierto: boolean) {
  actual();
  fijar({ abierto });
}

export function nuevaConversacion() {
  if (actual().pendiente) return;
  fijar({ mensajes: [] });
}

let secuencia = 0;
const nuevoId = () => `m${Date.now()}-${++secuencia}`;

/** Cuántos mensajes previos viajan como contexto (el backend corta en 12). */
const HISTORIAL = 12;

/**
 * Manda una pregunta y agrega la respuesta (o el error) a la conversación.
 * `pantalla`: la que está abierta, para "¿cómo uso esta pantalla?".
 */
export async function preguntar(texto: string, pantalla: string | null) {
  const pregunta = texto.trim();
  const previo = actual();
  if (!pregunta || previo.pendiente) return;

  const historial = previo.mensajes
    .filter((m) => !m.error)
    .slice(-HISTORIAL)
    .map((m) => ({ rol: m.rol, texto: m.texto }));

  fijar({
    mensajes: [...previo.mensajes, { id: nuevoId(), rol: "usuario", texto: pregunta }],
    pendiente: true,
  });

  try {
    const r = (await authFetch("ia/preguntar", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        pregunta,
        historial,
        manual: await cargarManual(),
        pantalla,
        nombre: getSesion()?.nombre ?? "",
      }),
    })) as {
      respuesta?: string;
      usadas_hoy?: number;
      limite?: number;
    };
    agregar({ id: nuevoId(), rol: "asistente", texto: String(r.respuesta ?? "") });
    fijar({ usadasHoy: r.usadas_hoy ?? null, limite: r.limite ?? null });
  } catch (e) {
    agregar({
      id: nuevoId(),
      rol: "asistente",
      texto: e instanceof Error ? e.message : "No se pudo obtener la respuesta.",
      error: true,
    });
  } finally {
    fijar({ pendiente: false });
  }
}

/** Agrega al final, salvo que la sesión haya cambiado mientras se esperaba. */
function agregar(m: MensajeIA) {
  if (estado.sesion !== tokenActual()) return;
  fijar({ mensajes: [...estado.mensajes, m] });
}

/** Vuelve a mandar la última pregunta que falló. */
export function reintentar(pantalla: string | null) {
  const { mensajes, pendiente } = actual();
  const ultimo = mensajes[mensajes.length - 1];
  const pregunta = mensajes[mensajes.length - 2];
  if (pendiente || !ultimo?.error || pregunta?.rol !== "usuario") return;
  fijar({ mensajes: mensajes.slice(0, -2) });
  void preguntar(pregunta.texto, pantalla);
}

/* -------------------------------------------------------------------------- */
/* El manual                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * Lo básico de usar el sistema que el README no dice (o dice para el
 * programador). Va antes de las secciones del README.
 */
const GUIA_BASICA = `## Lo básico

- Se entra con el usuario y la contraseña del sistema. El check "Recordar usuario y contraseña" deja la contraseña guardada en ese equipo: no conviene en una computadora compartida.
- La sesión dura 6 horas. Recargar la página o cerrar la app cierra la sesión y hay que volver a entrar.
- En el celular (y en la app de Android, que es el mismo sitio) la barra de abajo tiene Inicio, Menú (todas las pantallas, agrupadas por menú principal: tocá uno para abrirlo), Perfil (Mi cuenta: tema, color y cerrar sesión) y Salir.
- En la computadora el menú está a la izquierda, agrupado por menú principal.
- Cada usuario ve solo las pantallas que tiene habilitadas. Si falta una, hay que pedírsela a quien administra los permisos (Administrador → Roles de páginas).
- Este asistente se abre con el botón redondo de abajo a la derecha; recuerda la conversación hasta que se recarga la página.`;

/** Desde el título `desde` hasta antes de `hasta` (o el final). */
function seccion(md: string, desde: string, hasta?: string) {
  const i = md.indexOf(desde);
  if (i < 0) return "";
  const j = hasta ? md.indexOf(hasta, i + desde.length) : -1;
  return md.slice(i, j < 0 ? undefined : j).trim();
}

/**
 * Las secciones del README que describen el menú, los permisos, cada
 * pantalla y la sesión. Si un título cambia, esa sección falta (la IA dice
 * que no sabe) pero nada se rompe: revisar estos títulos al reordenar el
 * README.
 */
function armarManual(md: string) {
  return [
    GUIA_BASICA,
    seccion(md, "## Módulos y menú", "### Sumar un módulo"),
    seccion(md, "### Cómo se ve el menú", "### Reportes: siempre con Excel"),
    seccion(md, "## Sesión y datos en el dispositivo", "## ¿Hay que repartir"),
  ]
    .filter(Boolean)
    .join("\n\n");
}

let manual: Promise<string> | null = null;

/**
 * El manual, una vez por carga del sitio. Import dinámico: el README (unos
 * 70 KB) no pesa en el bundle de nadie que no abra el chat.
 */
export function cargarManual(): Promise<string> {
  manual ??= import("../../README.md?raw")
    .then((m) => armarManual(m.default))
    .catch(() => GUIA_BASICA);
  return manual;
}
```

## Anexo C: `src/components/asistente.tsx`

Adaptar según 3.3 (`usePantallaActual`, sugerencias de `Bienvenida`, clases del tema, posición del botón).

```tsx
import { useRouterState } from "@tanstack/react-router";
import {
  AlertTriangle,
  ArrowUp,
  Check,
  Copy,
  RotateCcw,
  SquarePen,
  Sparkles,
  X,
} from "lucide-react";
import { useEffect, useRef, useState, useSyncExternalStore, type KeyboardEvent } from "react";
import { toast } from "sonner";

import { Markdown } from "@/components/markdown";
import { Drawer, DrawerContent, DrawerDescription, DrawerTitle } from "@/components/ui/drawer";
import {
  abrirAsistente,
  cargarManual,
  nuevaConversacion,
  preguntar,
  reintentar,
  useAsistente,
  type MensajeIA,
} from "@/lib/asistente";
import { usePermisos } from "@/lib/permisos";

/**
 * El asistente con IA (15/10/2026): botón flotante y chat, en todas las
 * pantallas con sesión (lo monta `AppShell`). Lógica y contrato en
 * `lib/asistente.ts`; el backend, `backend/ia_asistente.sql`.
 *
 * | | Botón | Chat |
 * | --- | --- | --- |
 * | Celular y APK (`< lg`) | abajo a la derecha, encima de la barra | hoja casi a pantalla completa |
 * | Escritorio (`≥ lg`) | abajo a la derecha | panel fijo a la derecha, **sin tapar** la pantalla: `AppShell` le hace lugar, y sigue abierto al navegar |
 *
 * Lo ven todos los que entran: no depende de Roles de páginas (Jose,
 * 15/10/2026; la primera versión pedía la página `/asistente`).
 */
export function Asistente() {
  const { abierto, pendiente } = useAsistente();
  const escritorio = useEscritorio();

  return (
    <>
      {!(escritorio && abierto) && (
        <button
          type="button"
          onClick={() => {
            void cargarManual(); // que esté listo para la primera pregunta
            abrirAsistente(true);
          }}
          aria-label="Abrir el asistente"
          title="Asistente"
          className="tap bg-hero-gradient fixed right-4 bottom-[calc(5.75rem+env(safe-area-inset-bottom))] z-40 grid size-14 place-items-center rounded-full text-on-brand shadow-elegant lg:right-6 lg:bottom-6"
        >
          <Sparkles className="size-6" />
          {pendiente && (
            <span className="absolute top-0.5 right-0.5 flex size-3.5">
              <span className="absolute inline-flex size-full animate-ping rounded-full bg-on-brand/70" />
              <span className="relative inline-flex size-3.5 rounded-full border-2 border-on-brand bg-brand-red" />
            </span>
          )}
        </button>
      )}

      {escritorio ? (
        abierto && (
          <aside
            aria-label="Asistente"
            className="animate-in slide-in-from-right fade-in fixed inset-y-0 right-0 z-40 flex w-[420px] flex-col border-l border-border/70 bg-background shadow-elegant duration-200"
          >
            <PanelChat escritorio />
          </aside>
        )
      ) : (
        <Drawer open={abierto} onOpenChange={abrirAsistente} shouldScaleBackground={false}>
          <DrawerContent className="h-[94dvh] rounded-t-3xl border-border/60 lg:hidden">
            <DrawerTitle className="sr-only">Asistente</DrawerTitle>
            <DrawerDescription className="sr-only">
              Preguntale sobre el sistema o sobre los datos
            </DrawerDescription>
            <PanelChat escritorio={false} />
          </DrawerContent>
        </Drawer>
      )}
    </>
  );
}

/** `≥ lg`, el mismo corte que la sidebar. */
function useEscritorio() {
  return useSyncExternalStore(
    (f) => {
      const mq = window.matchMedia("(min-width: 1024px)");
      mq.addEventListener("change", f);
      return () => mq.removeEventListener("change", f);
    },
    () => window.matchMedia("(min-width: 1024px)").matches,
    () => false,
  );
}

/* -------------------------------------------------------------------------- */
/* El chat                                                                     */
/* -------------------------------------------------------------------------- */

function PanelChat({ escritorio }: { escritorio: boolean }) {
  const { mensajes, pendiente, usadasHoy, limite } = useAsistente();
  const pantalla = usePantallaActual();
  const [texto, setTexto] = useState("");
  const lista = useRef<HTMLDivElement>(null);
  const entrada = useRef<HTMLTextAreaElement>(null);

  // Siempre a la vista lo último: la pregunta recién mandada y la respuesta.
  useEffect(() => {
    lista.current?.scrollTo({ top: lista.current.scrollHeight, behavior: "smooth" });
  }, [mensajes.length, pendiente]);

  // En la computadora se escribe enseguida; en el celular no se abre el
  // teclado solo, que tapa la mitad de la hoja.
  useEffect(() => {
    if (escritorio) entrada.current?.focus();
  }, [escritorio]);

  // Escape cierra el panel de la computadora (la hoja del celular ya lo hace).
  useEffect(() => {
    if (!escritorio) return;
    const onKey = (e: globalThis.KeyboardEvent) => {
      if (e.key === "Escape") abrirAsistente(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [escritorio]);

  const enviar = (t = texto) => {
    if (!t.trim() || pendiente) return;
    void preguntar(t, pantalla.texto);
    setTexto("");
    entrada.current?.style.removeProperty("height");
  };

  const onKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      enviar();
    }
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* Cabecera */}
      <div className="flex items-center gap-3 border-b border-border/60 px-4 py-3">
        <span className="bg-hero-gradient grid size-9 shrink-0 place-items-center rounded-full text-on-brand">
          <Sparkles className="size-[18px]" />
        </span>
        <div className="min-w-0 flex-1">
          <h2 className="font-display text-[15px] leading-tight font-bold">Asistente</h2>
          <p className="truncate text-[11.5px] leading-tight text-muted-foreground">
            Sobre el sistema o sobre los datos
          </p>
        </div>
        {mensajes.length > 0 && (
          <button
            type="button"
            onClick={nuevaConversacion}
            disabled={pendiente}
            title="Nueva conversación"
            aria-label="Nueva conversación"
            className="tap grid size-9 place-items-center rounded-full text-muted-foreground hover:bg-muted disabled:opacity-40"
          >
            <SquarePen className="size-[18px]" />
          </button>
        )}
        <button
          type="button"
          onClick={() => abrirAsistente(false)}
          title="Cerrar"
          aria-label="Cerrar el asistente"
          className="tap grid size-9 place-items-center rounded-full text-muted-foreground hover:bg-muted"
        >
          <X className="size-5" />
        </button>
      </div>

      {/* Conversación */}
      <div ref={lista} className="min-h-0 flex-1 space-y-4 overflow-y-auto px-4 py-4">
        {mensajes.length === 0 ? (
          <Bienvenida pantalla={pantalla.nombre} onElegir={enviar} />
        ) : (
          mensajes.map((m, i) => (
            <Mensaje
              key={m.id}
              m={m}
              ultimo={i === mensajes.length - 1}
              onReintentar={() => reintentar(pantalla.texto)}
            />
          ))
        )}
        {pendiente && <Pensando />}
      </div>

      {/* Entrada */}
      <div className="border-t border-border/60 px-3 pt-3 pb-[max(0.75rem,env(safe-area-inset-bottom))]">
        <div className="flex items-end gap-2 rounded-2xl border border-border bg-card px-3 py-2 focus-within:border-primary/60 focus-within:ring-2 focus-within:ring-primary/15">
          <textarea
            ref={entrada}
            value={texto}
            onChange={(e) => {
              setTexto(e.target.value);
              // Crece con el texto hasta unas 6 líneas.
              e.target.style.height = "auto";
              e.target.style.height = `${Math.min(e.target.scrollHeight, 150)}px`;
            }}
            onKeyDown={onKeyDown}
            rows={1}
            maxLength={4000}
            enterKeyHint="send"
            placeholder="Escribí tu pregunta…"
            aria-label="Tu pregunta"
            className="max-h-[150px] min-h-[24px] flex-1 resize-none bg-transparent py-1 text-[14.5px] leading-snug outline-none placeholder:text-muted-foreground"
          />
          <button
            type="button"
            onClick={() => enviar()}
            disabled={!texto.trim() || pendiente}
            aria-label="Enviar"
            className="tap grid size-9 shrink-0 place-items-center rounded-full bg-primary text-primary-foreground disabled:bg-muted disabled:text-muted-foreground"
          >
            <ArrowUp className="size-[18px]" />
          </button>
        </div>
        <p className="mt-1.5 px-1 text-center text-[10.5px] leading-tight text-muted-foreground">
          Lo responde una IA con los datos del sistema: revisá lo importante.
          {usadasHoy != null && limite != null && (
            <>
              {" "}
              Hoy: {usadasHoy} de {limite} preguntas.
            </>
          )}
        </p>
      </div>
    </div>
  );
}

/**
 * La pantalla abierta, para la IA ("¿cómo uso esta pantalla?") y para la
 * primera sugerencia. El nombre sale del menú; Inicio y Mi cuenta no son
 * páginas.
 */
function usePantallaActual(): { nombre: string | null; texto: string } {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const { paginaDeRuta } = usePermisos();
  const nombre =
    paginaDeRuta(pathname)?.nombre ??
    (pathname.startsWith("/home")
      ? "Inicio"
      : pathname.startsWith("/account")
        ? "Mi cuenta"
        : null);
  return { nombre, texto: nombre ? `${nombre} (${pathname})` : pathname };
}

function Bienvenida({
  pantalla,
  onElegir,
}: {
  pantalla: string | null;
  onElegir: (t: string) => void;
}) {
  const sugerencias = [
    pantalla && pantalla !== "Inicio" ? `¿Cómo se usa ${pantalla}?` : null,
    "¿Cuántas intervenciones se hicieron este mes?",
    "¿Qué instituciones no tienen facilitador este año?",
    "¿Quiénes cumplen años este mes?",
    "¿Cómo le doy permisos a un usuario?",
  ].filter((s): s is string => !!s);

  return (
    <div className="flex flex-col items-center pt-6 text-center">
      <span className="bg-hero-gradient grid size-14 place-items-center rounded-2xl text-on-brand shadow-soft">
        <Sparkles className="size-7" />
      </span>
      <p className="font-display mt-3 text-lg font-bold">¿En qué te ayudo?</p>
      <p className="mt-1 max-w-[19rem] text-[13px] text-muted-foreground">
        Preguntame cómo se usa una pantalla o cualquier cosa sobre los datos: intervenciones,
        facilitadores, instituciones, manuales…
      </p>
      <div className="mt-5 flex w-full flex-col gap-2">
        {sugerencias.map((s) => (
          <button
            key={s}
            type="button"
            onClick={() => onElegir(s)}
            className="tap rounded-xl border border-border/70 bg-card px-3.5 py-2.5 text-left text-[13.5px] hover:border-primary/40 hover:bg-primary-soft"
          >
            {s}
          </button>
        ))}
      </div>
    </div>
  );
}

function Mensaje({
  m,
  ultimo,
  onReintentar,
}: {
  m: MensajeIA;
  ultimo: boolean;
  onReintentar: () => void;
}) {
  if (m.rol === "usuario") {
    return (
      <div className="flex justify-end">
        <p className="max-w-[85%] rounded-2xl rounded-br-md bg-primary px-3.5 py-2 text-[14px] leading-snug whitespace-pre-wrap text-primary-foreground">
          {m.texto}
        </p>
      </div>
    );
  }

  if (m.error) {
    return (
      <div className="rounded-2xl border border-destructive/30 bg-destructive/5 px-3.5 py-3">
        <p className="flex items-start gap-2 text-[13.5px] text-destructive">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          <span>{m.texto}</span>
        </p>
        {ultimo && (
          <button
            type="button"
            onClick={onReintentar}
            className="tap mt-2.5 inline-flex h-9 items-center gap-1.5 rounded-xl bg-muted px-3.5 text-[13px] font-semibold"
          >
            <RotateCcw className="size-3.5" />
            Reintentar
          </button>
        )}
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <Markdown texto={m.texto} />
      {/*
        Sin "Ver consultas" (15/10/2026, a pedido): el usuario ve solo la
        respuesta. El SQL que corrió queda en IA_CONSULTAS.CONSULTAS.
      */}
      <BotonCopiar texto={m.texto} />
    </div>
  );
}

function BotonCopiar({ texto }: { texto: string }) {
  const [copiado, setCopiado] = useState(false);
  return (
    <button
      type="button"
      onClick={() => {
        navigator.clipboard
          ?.writeText(texto)
          .then(() => {
            setCopiado(true);
            setTimeout(() => setCopiado(false), 1500);
          })
          .catch(() => toast.error("No se pudo copiar"));
      }}
      className="tap inline-flex h-7 items-center gap-1 rounded-lg px-2 text-[11.5px] font-medium text-muted-foreground hover:bg-muted"
    >
      {copiado ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
      {copiado ? "Copiado" : "Copiar"}
    </button>
  );
}

/**
 * Mientras espera. No hay avance real que mostrar (la respuesta llega
 * entera), así que el texto cambia con el tiempo: una pregunta sobre datos
 * suele llevar varias consultas.
 */
function Pensando() {
  const [segundos, setSegundos] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setSegundos((s) => s + 1), 1000);
    return () => clearInterval(t);
  }, []);
  const texto =
    segundos < 4
      ? "Pensando…"
      : segundos < 15
        ? "Buscando en los datos…"
        : `Sigue trabajando… (${segundos} s)`;

  return (
    <div className="flex items-center gap-2.5 text-[13px] text-muted-foreground" aria-live="polite">
      <span className="flex gap-1" aria-hidden>
        {[0, 1, 2].map((i) => (
          <span
            key={i}
            className="size-1.5 animate-bounce rounded-full bg-primary/70"
            style={{ animationDelay: `${i * 150}ms` }}
          />
        ))}
      </span>
      {texto}
    </div>
  );
}
```

## Anexo D: `src/components/markdown.tsx`

Va tal cual.

````tsx
import { Fragment, type ReactNode } from "react";

import { cn } from "@/lib/utils";

/**
 * Markdown chico para las respuestas del asistente (15/10/2026).
 *
 * Propio y no `react-markdown`: la IA usa un subconjunto conocido (títulos,
 * listas, tablas, negrita, código, enlaces) y así no se suma una dependencia ni
 * su peso. **Nunca arma HTML a partir del texto**: todo sale como nodos de
 * React, así que una respuesta no puede inyectar nada en la página.
 *
 * Lo que entiende:
 *
 * - Bloques: `#`/`##`/`###`, listas con `-`, `*` o `1.` (la sangría se respeta
 *   como un nivel más), tablas con `|` y su fila `---`, bloques de código con
 *   tres comillas invertidas, citas con `>` y `---` como separador.
 * - En línea: `**negrita**`, `*cursiva*` / `_cursiva_`, `` `código` `` y
 *   `[texto](https://...)` (solo enlaces http/https, en pestaña nueva).
 */
export function Markdown({ texto, className }: { texto: string; className?: string }) {
  return (
    <div className={cn("space-y-2.5 text-[14px] leading-relaxed break-words", className)}>
      {bloques(texto.replace(/\r\n?/g, "\n"))}
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Bloques                                                                     */
/* -------------------------------------------------------------------------- */

const RE_LISTA = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
const RE_TITULO = /^(#{1,6})\s+(.*)$/;
const RE_SEPARADOR_TABLA = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;
const RE_SEPARADOR = /^\s*([-*_])(\s*\1){2,}\s*$/;
const esFilaTabla = (l: string) => l.trim().startsWith("|") || /\S\s*\|\s*\S/.test(l);
/** La fila de guiones de una tabla: con al menos un `|`, para no confundirla con `---`. */
const esSeparadorTabla = (l = "") => l.includes("|") && RE_SEPARADOR_TABLA.test(l);
const empiezaTabla = (lineas: string[], i: number) =>
  esFilaTabla(lineas[i]) && esSeparadorTabla(lineas[i + 1]);

function bloques(md: string): ReactNode[] {
  const lineas = md.split("\n");
  const out: ReactNode[] = [];
  let i = 0;
  let k = 0;

  while (i < lineas.length) {
    const linea = lineas[i];

    if (!linea.trim()) {
      i++;
      continue;
    }

    // Código
    if (linea.trim().startsWith("```")) {
      const codigo: string[] = [];
      i++;
      while (i < lineas.length && !lineas[i].trim().startsWith("```")) codigo.push(lineas[i++]);
      i++; // la que cierra
      out.push(
        <pre
          key={k++}
          className="overflow-x-auto rounded-xl bg-muted px-3 py-2.5 font-mono text-[12px] leading-snug"
        >
          {codigo.join("\n")}
        </pre>,
      );
      continue;
    }

    // Título
    const titulo = RE_TITULO.exec(linea);
    if (titulo) {
      const nivel = titulo[1].length;
      out.push(
        <p
          key={k++}
          className={cn(
            "font-display font-bold",
            nivel <= 2 ? "pt-1 text-[16px]" : "text-[14.5px]",
          )}
        >
          {enLinea(titulo[2])}
        </p>,
      );
      i++;
      continue;
    }

    // Separador
    if (RE_SEPARADOR.test(linea)) {
      out.push(<hr key={k++} className="border-border/70" />);
      i++;
      continue;
    }

    // Tabla: una fila con | seguida de la fila de guiones.
    if (empiezaTabla(lineas, i)) {
      const encabezado = celdas(linea);
      const alineacion = celdas(lineas[i + 1]).map((c) =>
        c.endsWith(":") ? (c.startsWith(":") ? "center" : "right") : "left",
      ) as ("left" | "center" | "right")[];
      const filas: string[][] = [];
      i += 2;
      while (i < lineas.length && lineas[i].trim() && esFilaTabla(lineas[i])) {
        filas.push(celdas(lineas[i++]));
      }
      out.push(<Tabla key={k++} encabezado={encabezado} alineacion={alineacion} filas={filas} />);
      continue;
    }

    // Lista: los ítems seguidos (y sus líneas de continuación, con sangría).
    if (RE_LISTA.test(linea)) {
      const items: { nivel: number; ordenada: boolean; marca: string; texto: string }[] = [];
      while (i < lineas.length) {
        const m = RE_LISTA.exec(lineas[i]);
        if (m) {
          items.push({
            nivel: Math.min(3, Math.floor(m[1].replace(/\t/g, "  ").length / 2)),
            ordenada: /\d/.test(m[2]),
            marca: m[2],
            texto: m[3],
          });
          i++;
        } else if (lineas[i].trim() && /^\s+/.test(lineas[i]) && items.length) {
          items[items.length - 1].texto += " " + lineas[i].trim();
          i++;
        } else break;
      }
      out.push(
        <ul key={k++} className="space-y-1">
          {items.map((it, j) => (
            <li key={j} className="flex gap-2" style={{ paddingLeft: `${it.nivel * 1.1}rem` }}>
              <span
                aria-hidden
                className={cn(
                  "shrink-0 text-muted-foreground tabular-nums",
                  it.ordenada ? "min-w-[1.1rem] text-right" : "pt-[0.55em]",
                )}
              >
                {it.ordenada ? (
                  it.marca.replace(")", ".")
                ) : (
                  <span className="block size-1.5 rounded-full bg-current" />
                )}
              </span>
              <span className="min-w-0 flex-1">{enLinea(it.texto)}</span>
            </li>
          ))}
        </ul>,
      );
      continue;
    }

    // Cita
    if (linea.trimStart().startsWith(">")) {
      const cita: string[] = [];
      while (i < lineas.length && lineas[i].trimStart().startsWith(">")) {
        cita.push(lineas[i++].trimStart().replace(/^>\s?/, ""));
      }
      out.push(
        <div key={k++} className="border-l-2 border-primary/40 pl-3 text-muted-foreground">
          {bloques(cita.join("\n"))}
        </div>,
      );
      continue;
    }

    // Párrafo: hasta una línea vacía o el comienzo de otro bloque. Cada salto
    // de línea se respeta (la IA los usa como tales).
    const parrafo: string[] = [];
    while (
      i < lineas.length &&
      lineas[i].trim() &&
      !RE_TITULO.test(lineas[i]) &&
      !RE_SEPARADOR.test(lineas[i]) &&
      !RE_LISTA.test(lineas[i]) &&
      !lineas[i].trim().startsWith("```") &&
      !lineas[i].trimStart().startsWith(">") &&
      !empiezaTabla(lineas, i)
    ) {
      parrafo.push(lineas[i++].trim());
    }
    // Nunca quedarse en la misma línea: si ningún bloque la tomó, va sola.
    if (!parrafo.length) parrafo.push(lineas[i++].trim());
    out.push(
      <p key={k++}>
        {parrafo.map((l, j) => (
          <Fragment key={j}>
            {j > 0 && <br />}
            {enLinea(l)}
          </Fragment>
        ))}
      </p>,
    );
  }
  return out;
}

function celdas(linea: string) {
  return linea
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split(/(?<!\\)\|/)
    .map((c) => c.trim().replace(/\\\|/g, "|"));
}

function Tabla({
  encabezado,
  alineacion,
  filas,
}: {
  encabezado: string[];
  alineacion: ("left" | "center" | "right")[];
  filas: string[][];
}) {
  return (
    <div className="overflow-x-auto rounded-xl border border-border/70">
      <table className="w-full border-collapse text-[12.5px]">
        <thead className="bg-muted/70">
          <tr>
            {encabezado.map((c, j) => (
              <th
                key={j}
                style={{ textAlign: alineacion[j] ?? "left" }}
                className="px-2.5 py-1.5 font-semibold whitespace-nowrap"
              >
                {enLinea(c)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {filas.map((f, i) => (
            <tr key={i} className="border-t border-border/60 even:bg-muted/30">
              {encabezado.map((_, j) => (
                <td
                  key={j}
                  style={{ textAlign: alineacion[j] ?? "left" }}
                  className="px-2.5 py-1.5 align-top tabular-nums"
                >
                  {enLinea(f[j] ?? "")}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* En línea                                                                    */
/* -------------------------------------------------------------------------- */

const RE_EN_LINEA =
  /(`[^`]+`)|(\*\*(?=\S)[\s\S]*?\S\*\*)|(__(?=\S)[\s\S]*?\S__)|(\[[^\]]+\]\(https?:\/\/[^)\s]+\))|(\*(?=\S)[^*]*?\S\*)|((?<![\p{L}\p{N}])_(?=\S)[^_]*?\S_(?![\p{L}\p{N}]))/gu;

function enLinea(texto: string): ReactNode[] {
  const out: ReactNode[] = [];
  let ultimo = 0;
  let k = 0;
  for (const m of texto.matchAll(RE_EN_LINEA)) {
    const desde = m.index ?? 0;
    if (desde > ultimo) out.push(texto.slice(ultimo, desde));
    const t = m[0];
    if (m[1]) {
      out.push(
        <code key={k++} className="rounded bg-muted px-1 py-0.5 font-mono text-[0.88em]">
          {t.slice(1, -1)}
        </code>,
      );
    } else if (m[2] || m[3]) {
      out.push(
        <strong key={k++} className="font-semibold">
          {enLinea(t.slice(2, -2))}
        </strong>,
      );
    } else if (m[4]) {
      const enlace = /^\[([^\]]+)\]\((.+)\)$/.exec(t);
      out.push(
        <a
          key={k++}
          href={enlace?.[2]}
          target="_blank"
          rel="noopener noreferrer"
          className="font-medium text-primary underline underline-offset-2"
        >
          {enLinea(enlace?.[1] ?? t)}
        </a>,
      );
    } else {
      out.push(<em key={k++}>{enLinea(t.slice(1, -1))}</em>);
    }
    ultimo = desde + t.length;
  }
  if (ultimo < texto.length) out.push(texto.slice(ultimo));
  return out;
}
````
