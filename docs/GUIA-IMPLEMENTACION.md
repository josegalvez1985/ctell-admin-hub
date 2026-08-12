# Guía de implementación

Cómo agregar tablas, endpoints, páginas y formularios siguiendo los patrones de
este proyecto. Está escrita sobre el código que ya existe: los ejemplos salen de
[db/auth.sql](../db/auth.sql) y `src/`, que sirven de plantilla para todo lo
demás.

## Índice

1. [Arquitectura](#1-arquitectura)
2. [Regla: un archivo SQL por tabla](#2-regla-un-archivo-sql-por-tabla)
   - [El estado es `'A'`/`'I'`, nunca 1/0](#21-el-estado-es-ai-nunca-10)
3. [Crear el backend de una tabla](#3-crear-el-backend-de-una-tabla)
4. [Consumir la API desde el frontend](#4-consumir-la-api-desde-el-frontend)
5. [Agregar una página](#5-agregar-una-página)
6. [Formularios](#6-formularios)
7. [Leer y mutar datos](#7-leer-y-mutar-datos)
8. [Seguridad](#8-seguridad)
9. [Checklist](#9-checklist)

---

## 1. Arquitectura

El proyecto son **dos piezas separadas** que se hablan por HTTP:

| Capa     | Dónde vive                | Qué hace                             |
| -------- | ------------------------- | ------------------------------------ |
| Backend  | Oracle APEX + ORDS        | Paquetes PL/SQL expuestos como REST  |
| Frontend | React + TanStack Start    | Consume la API, corre en GitHub Pages |

Base de la API: `https://oracleapex.com/ords/ctell/`

Esto importa: **no se usan server functions de TanStack** (`createServerFn`) ni
se conecta a la base desde ningún servidor intermedio. Toda la lógica de datos
vive en paquetes PL/SQL, y el frontend sólo hace `fetch` contra ORDS —
directo en producción, gracias a CORS habilitado en APEX (ver
[8. Seguridad](#8-seguridad)).

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

**`auth.sql` se ejecuta primero.** Define `BORRAR_MODULO_ORDS`, que usan todos
los demás, y `PKG_AUTH`, del que depende cualquier handler que valide un token.

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
—"si no existe, seguí de largo"— pero se traga *cualquier* error, incluido el
interbloqueo. El script termina sin quejarse y vos creés que aplicó los
cambios, cuando en realidad ORDS sigue sirviendo la versión anterior. Usá
`BORRAR_MODULO_ORDS`, que consulta `USER_ORDS_MODULES` antes de borrar,
reintenta ante `ORA-00060` y **re-lanza** cualquier otro error.

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

Tomá [db/usuarios.sql](../db/usuarios.sql) como plantilla: tiene el ABM
completo —listado paginado, alta, detalle, modificación, bajas lógica y física—
con todos los patrones de este documento aplicados. La estructura es siempre la
misma; abajo va condensada con `EMPRESAS` de ejemplo.

> `BORRAR_MODULO_ORDS` lo define [db/auth.sql](../db/auth.sql) y los demás
> archivos lo reutilizan. No lo copies en cada uno.

### Esqueleto

```sql
--------------------------------------------------------------------------------
-- CTELL · EMPRESAS
-- Script único: paquete PL/SQL + endpoints ORDS.
-- Base: https://oracleapex.com/ords/ctell/empresas/
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_EMPRESAS AS

  C_ERR_DUPLICADO   CONSTANT PLS_INTEGER := -20001;
  C_ERR_NO_EXISTE   CONSTANT PLS_INTEGER := -20002;
  C_ERR_DATOS       CONSTANT PLS_INTEGER := -20004;

  PROCEDURE CREAR (
    p_razon_social IN  VARCHAR2,
    p_ruc          IN  VARCHAR2,
    p_id_empresa   OUT NUMBER
  );

  -- p_activo es el código de la columna: 'A' o 'I'. NULL = no cambiar.
  PROCEDURE ACTUALIZAR (
    p_id_empresa   IN NUMBER,
    p_razon_social IN VARCHAR2 DEFAULT NULL,
    p_ruc          IN VARCHAR2 DEFAULT NULL,
    p_activo       IN VARCHAR2 DEFAULT NULL
  );

  PROCEDURE INACTIVAR (p_id_empresa IN NUMBER);
  PROCEDURE ACTIVAR   (p_id_empresa IN NUMBER);
  PROCEDURE ELIMINAR  (p_id_empresa IN NUMBER);

  -- p_activo: 'A' o 'I'. NULL = sin filtro.
  FUNCTION CONTAR (
    p_busqueda IN VARCHAR2 DEFAULT NULL,
    p_activo   IN VARCHAR2 DEFAULT NULL
  ) RETURN NUMBER;

END PKG_EMPRESAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_EMPRESAS AS
  -- … implementación …
END PKG_EMPRESAS;
/
```

### Convenciones del paquete

**Los `UPDATE` respetan los NULL.** Un parámetro sin valor no debe pisar la
columna:

```sql
UPDATE EMPRESAS
   SET RAZON_SOCIAL        = NVL(TRIM(p_razon_social), RAZON_SOCIAL),
       -- 'A'/'I' tal cual. NULL conserva el valor actual, y un código
       -- inválido también: mejor ignorarlo que escribir basura.
       ACTIVO              = CASE UPPER(TRIM(p_activo))
                               WHEN 'A' THEN 'A'
                               WHEN 'I' THEN 'I'
                               ELSE ACTIVO
                             END,
       FECHA_ACTUALIZACION = SYSTIMESTAMP
 WHERE ID_EMPRESA = p_id_empresa;

IF SQL%ROWCOUNT = 0 THEN
  RAISE_APPLICATION_ERROR(C_ERR_NO_EXISTE, 'La empresa no existe');
END IF;
```

**Siempre verificá `SQL%ROWCOUNT`.** Sin eso, actualizar un ID inexistente
devuelve 200 y el usuario cree que guardó.

**Preferí la baja lógica.** `ELIMINAR` sólo si de verdad hay que borrar el
rastro; si hay tablas hijas, limpialas primero o la FK aborta el `DELETE`.

**Códigos de error de negocio en `-20001..-20004`.** Los handlers los traducen
a HTTP 400/404; cualquier otro código se oculta como 500.

### Endpoints ORDS

Un módulo por tabla, con este patrón de rutas:

| Método   | Ruta                    | Qué hace           |
| -------- | ----------------------- | ------------------ |
| `GET`    | `/empresas/`            | listado paginado   |
| `POST`   | `/empresas/`            | alta               |
| `GET`    | `/empresas/:id`         | detalle            |
| `PUT`    | `/empresas/:id`         | modificación       |
| `DELETE` | `/empresas/:id`         | baja física        |
| `POST`   | `/empresas/:id/inactivar` | baja lógica      |
| `POST`   | `/empresas/:id/activar` | alta lógica        |

El template para el listado y el alta es `'.'`; para el resto, `':id'` o
`':id/accion'`.

**Todo handler valida el token primero.** Sin esto el ABM queda abierto a
internet:

```sql
DECLARE
  l_sesion NUMBER;
BEGIN
  l_sesion := PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(:authorization));
  IF l_sesion IS NULL THEN
    :status_code := 401;
    :resultado := '{"error":"Sesion invalida o vencida"}';
    RETURN;
  END IF;

  -- … la operación …

  COMMIT;
  :status_code := 200;
  :resultado := '{"ok":true}';
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    IF SQLCODE = -20002 THEN
      :status_code := 404;
      :resultado := '{"error":"No existe"}';
    ELSIF SQLCODE BETWEEN -20004 AND -20001 THEN
      :status_code := 400;
      :resultado := JSON_OBJECT('error' VALUE SUBSTR(SQLERRM, 12));
    ELSE
      :status_code := 500;
      :resultado := '{"error":"Error interno"}';
    END IF;
END;
```

Cada handler necesita sus tres parámetros declarados con
`ORDS.DEFINE_PARAMETER`: `authorization` (HEADER/IN), `resultado`
(RESPONSE/OUT) y `X-APEX-STATUS-CODE` (HEADER/OUT, bind `status_code`).

> El token se extrae con `PKG_AUTH.TOKEN_DE_HEADER`, no con un
> `REPLACE(:authorization, 'Bearer ', '')` a mano. El esquema es
> case-insensitive por RFC: con el `REPLACE` literal, un cliente que mande
> `bearer xxx` deja el prefijo pegado al token y recibe un 401 que no hay forma
> de explicar mirando las credenciales.

**El JSON se arma con `JSON_OBJECT` / `JSON_ARRAYAGG`** y `RETURNING CLOB` en
los listados, que pueden superar los 4000 bytes de un `VARCHAR2`.

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
      return request<{ items: Empresa[]; total: number }>(
        `/empresas/${q ? `?${q}` : ""}`,
      );
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

## 5. Agregar una página

Creá el archivo en `src/routes/`. El nombre define la URL. Si la página exige
sesión —el caso normal— llevá el prefijo `_auth.`, que la ubica bajo el layout
protegido de [_auth.tsx](../src/routes/_auth.tsx):

| Archivo                      | URL               |
| ----------------------------- | ----------------- |
| `_auth.empresas.tsx`          | `/empresas`       |
| `_auth.empresas.$id.tsx`      | `/empresas/:id`   |
| `_auth.empresas.nuevo.tsx`    | `/empresas/nuevo` |

```tsx
import { createFileRoute } from "@tanstack/react-router";

import { AppLayout } from "@/components/ctell/AppLayout";

export const Route = createFileRoute("/_auth/empresas")({
  head: () => ({
    meta: [{ title: "Empresas | CTELL" }],
  }),
  component: EmpresasPage,
});

function EmpresasPage() {
  return (
    <AppLayout active="Empresas" title="Empresas">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Empresas</h1>
      </main>
    </AppLayout>
  );
}
```

- **Envolvé siempre en `<AppLayout>`** — da el menú, el header y la barra móvil.
- **`active`** debe coincidir con el `label` del item del menú.
- **`pb-28`** evita que la barra inferior de móvil tape el contenido.

Registrá la entrada en `navModules` de
[AppLayout.tsx](../src/components/ctell/AppLayout.tsx).

---

## 6. Formularios

**react-hook-form + zod**, con los componentes de `@/components/ui/form`.

```tsx
const schema = z.object({
  razonSocial: z.string().trim().min(3, "Mínimo 3 caracteres"),
  ruc: z.string().regex(/^\d{6,8}-\d$/, "Formato: 1234567-8"),
});

type FormValues = z.infer<typeof schema>;

function NuevaEmpresaPage() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Sin defaults React avisa por inputs no controlados.
    defaultValues: { razonSocial: "", ruc: "" },
  });

  const mutation = useMutation({
    mutationFn: (values: FormValues) => api.empresas.crear(values),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["empresas"] });
      toast.success("Empresa creada");
      navigate({ to: "/empresas" });
    },
    onError: (error) => {
      // El backend manda el motivo real en los 400.
      toast.error(error instanceof ApiError ? error.message : "No se pudo guardar");
    },
  });

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit((v) => mutation.mutate(v))} className="space-y-5">
        <FormField
          control={form.control}
          name="razonSocial"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Razón social</FormLabel>
              <FormControl>
                <Input {...field} />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <Button type="submit" disabled={mutation.isPending}>
          {mutation.isPending ? "Guardando…" : "Guardar"}
        </Button>
      </form>
    </Form>
  );
}
```

**Validá en los dos lados.** El zod del formulario mejora la experiencia, pero
la validación que cuenta es la del paquete PL/SQL: cualquiera puede llamar al
endpoint sin pasar por tu formulario.

---

## 7. Leer y mutar datos

```tsx
const { data, isLoading } = useQuery({
  queryKey: ["empresas", { busqueda }],
  queryFn: () => api.empresas.listar({ busqueda }),
});
```

Después de mutar, invalidá o la lista queda desactualizada:

```tsx
queryClient.invalidateQueries({ queryKey: ["empresas"] });
```

> El `loader` de la ruta también sirve, pero corre antes de que el layout
> `_auth.tsx` termine de resolver el token. Para datos detrás de sesión usá
> `useQuery`.

---

## 8. Seguridad

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

**CORS en producción se habilita en APEX, no con un proxy.** ORDS no manda
`Access-Control-Allow-Origin` por defecto, y `src/lib/api.ts` pega directo a
`oracleapex.com` cuando `import.meta.env.DEV` es falso. Los orígenes
permitidos se cargan en _Administración del Workspace → RESTful Services →
orígenes permitidos_ — hoy son `https://www.ctell.online` (producción) y
`http://localhost:8080` (desarrollo, sólo si se prueba sin el proxy de Vite).
Sin ese origen cargado, el navegador bloquea la respuesta como cualquier otra
llamada cross-origin. Se configura **una sola vez para todo el workspace**:
un módulo nuevo (`empresas`, `articulos`, etc.) hereda esos orígenes sin tocar
nada.

---

## 9. Checklist

Backend (`db/<tabla>.sql`):

- [ ] Un archivo por tabla, nombrado como la tabla
- [ ] Reejecutable: `CREATE OR REPLACE` + `ORDS.DELETE_MODULE`
- [ ] No crea ni altera tablas
- [ ] Sin `ORDS.ENABLE_SCHEMA` ni `DBMS_CRYPTO`
- [ ] Todos los handlers validan el token
- [ ] Los `UPDATE` verifican `SQL%ROWCOUNT`
- [ ] Errores de negocio en `-20001..-20004`, traducidos a 400/404
- [ ] Consultas de verificación al final (con `OBJECT_NAME`)
- [ ] **El estado es `'A'`/`'I'` en la columna, el JSON y el frontend** — sin
      traducir a 1/0 en ningún punto
- [ ] **Todo `TO_NUMBER(:param)` lleva `NULLIF(:param, '')`** — un parámetro
      ausente llega como cadena vacía, no como NULL
- [ ] **Las conversiones van dentro del `BEGIN`**, nunca en el `DECLARE`
- [ ] Ninguna función del paquete se invoca desde una sentencia SQL

Frontend:

- [ ] `npx tsc --noEmit` y `npm run lint` sin errores
- [ ] Bloque agregado en `src/lib/api.ts`
- [ ] Página envuelta en `<AppLayout>` y registrada en `navModules`
- [ ] Formularios con `defaultValues` y validación zod
- [ ] Mutaciones invalidan sus queries
- [ ] Probado en claro/oscuro y en ancho de móvil

### Errores frecuentes

| Síntoma                                | Causa                                          |
| -------------------------------------- | ---------------------------------------------- |
| `PLS-00201: DBMS_CRYPTO`               | No hay grant; usá `SYS_GUID`/`STANDARD_HASH`   |
| `PLS-00201: STANDARD_HASH`             | Es función SQL: envolvela en `SELECT … FROM DUAL` |
| `PLS-00231` en un `SELECT`/`UPDATE`    | Función del paquete invocada desde SQL: resolvé el valor antes en PL/SQL |
| `ORA-01031` en `ENABLE_SCHEMA`         | En APEX ya está habilitado: quitá la llamada    |
| `ORA-00904: "NAME"`                    | En `USER_OBJECTS` la columna es `OBJECT_NAME`  |
| `ORA-01722` al filtrar por estado      | `TO_NUMBER` sobre `ACTIVO`, que es `VARCHAR2` con `'A'`/`'I'` |
| `ORA-06550` al compilar el handler     | Comillas del `q'~ … ~'` sin cerrar             |
| **500 sin mensaje, con el `EXCEPTION` escrito** | La conversión está en el `DECLARE`: se ejecuta antes de que exista el `EXCEPTION` y escapa del handler |
| **500 solo cuando falta un query param** | `TO_NUMBER('')`: un parámetro ausente llega como cadena vacía. Usá `NULLIF(:param, '')` |
| El endpoint devuelve 404               | Falta `DEFINE_TEMPLATE` para ese patrón        |
| Devuelve 200 pero no guardó            | Falta chequear `SQL%ROWCOUNT`                  |
| 401 en todo                            | El token venció (8 h) o falta el header        |
| 401 al loguearse con datos correctos   | `USUARIO` guardado con mayúsculas (el login compara contra `LOWER`), `ACTIVO` distinto de `'A'`, o el hash no se generó con el paquete |
| `ORA-00060` al reejecutar el script    | Otra sesión tiene tomados los metadatos de ORDS: frená `npm run dev` antes |
| `ORA-00001` en `DEFINE_MODULE`         | El `DELETE_MODULE` falló y su error se tragó un `WHEN OTHERS THEN NULL` |
| `window is not defined`                | Acceso al DOM fuera de `useEffect` (corre en el prerender de build) |
| La lista no se actualiza tras guardar  | Falta `invalidateQueries`                      |
