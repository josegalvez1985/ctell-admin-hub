# Guía de implementación

Cómo agregar tablas, endpoints, páginas y formularios siguiendo los patrones de
este proyecto. Está escrita sobre el código que ya existe: los ejemplos salen de
`db/usuarios.sql` y `src/`, que sirven de plantilla para todo lo demás.

## Índice

1. [Arquitectura](#1-arquitectura)
2. [Regla: un archivo SQL por tabla](#2-regla-un-archivo-sql-por-tabla)
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
| Frontend | React + TanStack Start    | Consume la API, corre en Cloudflare  |

Base de la API: `https://oracleapex.com/ords/ctell/`

Esto importa: **no se usan server functions de TanStack** (`createServerFn`) ni
se conecta a la base desde el Worker. Toda la lógica de datos vive en paquetes
PL/SQL, y el frontend sólo hace `fetch` contra ORDS.

Tres cosas más a tener presentes:

**El ruteo del frontend es por archivo.** Un archivo en `src/routes/` define una
URL. `src/routeTree.gen.ts` se genera solo y **nunca se edita a mano**.

**Hay SSR.** El primer render ocurre en el servidor, así que todo acceso a
`window`, `document` o `sessionStorage` va dentro de `useEffect` o detrás de
`typeof window === "undefined"`.

**El token de sesión vive en `sessionStorage`.** Lo maneja
[src/lib/api.ts](../src/lib/api.ts); no lo leas por tu cuenta.

---

## 2. Regla: un archivo SQL por tabla

> **Cada tabla tiene su propio archivo en `db/`, con todo su CRUD adentro.**

```
db/
├── usuarios.sql     PKG_USUARIOS + PKG_TOKENS + /auth/ + /usuarios/
├── empresas.sql     PKG_EMPRESAS + /empresas/
├── clientes.sql     PKG_CLIENTES + /clientes/
└── articulos.sql    PKG_ARTICULOS + /articulos/
```

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

---

## 3. Crear el backend de una tabla

Tomá [db/usuarios.sql](../db/usuarios.sql) como plantilla. La estructura es
siempre la misma; abajo va condensada con `EMPRESAS` de ejemplo.

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

  PROCEDURE ACTUALIZAR (
    p_id_empresa   IN NUMBER,
    p_razon_social IN VARCHAR2 DEFAULT NULL,
    p_ruc          IN VARCHAR2 DEFAULT NULL,
    p_activo       IN NUMBER   DEFAULT NULL
  );

  PROCEDURE INACTIVAR (p_id_empresa IN NUMBER);
  PROCEDURE ACTIVAR   (p_id_empresa IN NUMBER);
  PROCEDURE ELIMINAR  (p_id_empresa IN NUMBER);

  FUNCTION CONTAR (
    p_busqueda IN VARCHAR2 DEFAULT NULL,
    p_activo   IN NUMBER   DEFAULT NULL
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
       ACTIVO              = NVL(p_activo, ACTIVO),
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
  l_sesion := PKG_TOKENS.VALIDAR_TOKEN(REPLACE(:authorization, 'Bearer ', ''));
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

**Los parámetros de query llegan como texto**: convertí con `TO_NUMBER(:activo)`,
nunca los uses directo en comparaciones numéricas.

**El JSON se arma con `JSON_OBJECT` / `JSON_ARRAYAGG`** y `RETURNING CLOB` en
los listados, que pueden superar los 4000 bytes de un `VARCHAR2`.

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
  activo: number;
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

Creá el archivo en `src/routes/`. El nombre define la URL:

| Archivo              | URL               |
| -------------------- | ----------------- |
| `empresas.tsx`       | `/empresas`       |
| `empresas.$id.tsx`   | `/empresas/:id`   |
| `empresas.nuevo.tsx` | `/empresas/nuevo` |

```tsx
import { createFileRoute } from "@tanstack/react-router";

import { AppLayout } from "@/components/ctell/AppLayout";

export const Route = createFileRoute("/empresas")({
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

> El `loader` de la ruta también sirve, pero necesita el token — que en SSR no
> existe todavía. Para datos detrás de sesión usá `useQuery`.

---

## 8. Seguridad

**Nunca devuelvas `CONTRASENA_HASH` ni `SALT`.** Ningún `SELECT` de un handler
debe incluirlos.

**Mensajes genéricos en el login.** Distinguir "no existe" de "clave incorrecta"
permite enumerar cuentas válidas.

**Todo handler que no sea login valida el token.**

**Inactivar un usuario revoca sus tokens.** Si no, sigue navegando con la sesión
abierta.

**Nada de credenciales en el repo.** Para el frontend, sólo variables `VITE_*`
que sean públicas por definición.

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
| `ORA-01031` en `ENABLE_SCHEMA`         | En APEX ya está habilitado: quitá la llamada    |
| `ORA-00904: "NAME"`                    | En `USER_OBJECTS` la columna es `OBJECT_NAME`  |
| `ORA-06550` al compilar el handler     | Comillas del `q'~ … ~'` sin cerrar             |
| El endpoint devuelve 404               | Falta `DEFINE_TEMPLATE` para ese patrón        |
| Devuelve 200 pero no guardó            | Falta chequear `SQL%ROWCOUNT`                  |
| 401 en todo                            | El token venció (8 h) o falta el header        |
| `window is not defined`                | Acceso al DOM fuera de `useEffect` (hay SSR)   |
| La lista no se actualiza tras guardar  | Falta `invalidateQueries`                      |
