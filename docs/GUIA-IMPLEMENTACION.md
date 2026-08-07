# Guía de implementación

Cómo agregar páginas, formularios y endpoints siguiendo los patrones de este
proyecto. Está escrita sobre el código que ya existe: los ejemplos usan las
mismas librerías y convenciones que vas a encontrar en `src/`.

## Índice

1. [Conceptos base](#1-conceptos-base)
2. [Agregar una página](#2-agregar-una-página)
3. [Crear un endpoint (server function)](#3-crear-un-endpoint-server-function)
4. [API REST tradicional](#4-api-rest-tradicional)
5. [Formularios](#5-formularios)
6. [Leer y mutar datos](#6-leer-y-mutar-datos)
7. [Conectar la base de datos](#7-conectar-la-base-de-datos)
8. [Autenticación](#8-autenticación)
9. [Checklist](#9-checklist)

---

## 1. Conceptos base

El proyecto usa **TanStack Start**: un framework full-stack sobre React donde el
mismo repositorio contiene frontend y backend.

Tres cosas que conviene entender antes de escribir código:

**El ruteo es por archivo.** Un archivo en `src/routes/` define una URL. No hay
un archivo central de rutas que editar — `src/routeTree.gen.ts` se genera solo
y **nunca se edita a mano**.

**Las server functions corren solo en el servidor.** Se declaran con
`createServerFn`, se importan como una función normal en el cliente, y Start se
encarga de la llamada HTTP. El código dentro nunca llega al bundle del
navegador, así que ahí van las credenciales y las consultas a la base.

**Hay SSR.** El primer render ocurre en el servidor. Por eso todo acceso a
`window`, `document` o `localStorage` va dentro de `useEffect` o detrás de
`typeof window === "undefined"`.

---

## 2. Agregar una página

Creá el archivo en `src/routes/`. El nombre define la URL:

| Archivo              | URL               |
| -------------------- | ----------------- |
| `clientes.tsx`       | `/clientes`       |
| `clientes.index.tsx` | `/clientes`       |
| `clientes.$id.tsx`   | `/clientes/:id`   |
| `clientes.nuevo.tsx` | `/clientes/nuevo` |

### Plantilla

```tsx
// src/routes/clientes.tsx
import { createFileRoute } from "@tanstack/react-router";

import { AppLayout } from "@/components/ctell/AppLayout";

export const Route = createFileRoute("/clientes")({
  head: () => ({
    meta: [
      { title: "Clientes | CTELL" },
      { name: "description", content: "Gestión de clientes de CTELL." },
    ],
  }),
  component: ClientesPage,
});

function ClientesPage() {
  return (
    <AppLayout active="Clientes" title="Clientes">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Clientes</h1>
      </main>
    </AppLayout>
  );
}
```

Puntos a respetar:

- **Envolvé siempre en `<AppLayout>`** — da el menú lateral, el header y la
  barra móvil. Sin él la página queda huérfana, sin navegación.
- **`active`** debe coincidir con el `label` del item del menú para que se
  marque como activo.
- **`pb-28`** en el `<main>` evita que la barra inferior de móvil tape el
  contenido.

### Registrar en el menú

Agregá la entrada en `navModules` de
[src/components/ctell/AppLayout.tsx](../src/components/ctell/AppLayout.tsx):

```tsx
export const navModules = [
  { name: "Compras", icon: ShoppingCart, to: "/compras" },
  { name: "Clientes", icon: Users, to: "/clientes" }, // nuevo
];
```

---

## 3. Crear un endpoint (server function)

Es la forma preferida en este proyecto: type-safe de punta a punta, sin escribir
rutas HTTP ni parsear JSON a mano.

Poné las funciones de cada dominio en `src/server/<dominio>.ts`.

```ts
// src/server/clientes.ts
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

// El schema valida la entrada Y genera el tipo. No declares el tipo aparte.
const listarInput = z.object({
  busqueda: z.string().trim().max(100).optional(),
  pagina: z.number().int().min(1).default(1),
});

export const listarClientes = createServerFn({ method: "GET" })
  .validator(listarInput)
  .handler(async ({ data }) => {
    // Este código corre SOLO en el servidor.
    const { busqueda, pagina } = data;

    // TODO: reemplazar por la consulta real
    return {
      items: [] as Array<{ id: string; razonSocial: string; ruc: string }>,
      total: 0,
      pagina,
      busqueda,
    };
  });

const crearInput = z.object({
  razonSocial: z.string().trim().min(3, "Mínimo 3 caracteres"),
  ruc: z.string().regex(/^\d{6,8}-\d$/, "Formato de RUC inválido"),
  email: z.string().email("Email inválido").optional().or(z.literal("")),
});

export const crearCliente = createServerFn({ method: "POST" })
  .validator(crearInput)
  .handler(async ({ data }) => {
    // La validación ya corrió: `data` está tipado y limpio.
    return { id: crypto.randomUUID(), ...data };
  });
```

### Reglas

**Usá `method: "GET"` solo para lecturas.** Las mutaciones van con `"POST"`, y
el middleware CSRF configurado en
[src/start.ts](../src/start.ts) las protege automáticamente.

**Validá siempre con `.validator()`.** La entrada de un cliente HTTP no es
confiable, aunque tu formulario ya valide: cualquiera puede llamar al endpoint
directamente.

**Nunca importes una server function dentro de otro módulo del cliente** salvo
para llamarla. Si necesitás compartir lógica, ponela en un archivo aparte que
sólo importe el servidor.

### Errores

Para errores esperados (validación de negocio, permisos), lanzá un objeto con
`statusCode` — el middleware de [src/start.ts](../src/start.ts) lo respeta y no
lo convierte en un 500 genérico:

```ts
if (yaExiste) {
  throw { statusCode: 409, message: "Ya existe un cliente con ese RUC" };
}
```

---

## 4. API REST tradicional

Sólo si necesitás exponer un endpoint a un consumidor externo (una app móvil,
un webhook, otro sistema). Para el frontend propio usá server functions.

```ts
// src/routes/api.clientes.ts  →  /api/clientes
import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/api/clientes")({
  server: {
    handlers: {
      GET: async () => Response.json({ items: [] }),
      POST: async ({ request }) => {
        const body = await request.json();
        return Response.json({ ok: true, body }, { status: 201 });
      },
    },
  },
});
```

> El middleware CSRF filtra por `handlerType === "serverFn"`, así que **no**
> cubre estas rutas. Si exponés un endpoint público que muta datos, agregá
> autenticación por token vos mismo.

---

## 5. Formularios

El stack es **react-hook-form + zod**, con los componentes de `@/components/ui/form`.

```tsx
// src/routes/clientes.nuevo.tsx
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation } from "@tanstack/react-query";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { Button } from "@/components/ui/button";
import {
  Form,
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form";
import { Input } from "@/components/ui/input";
import { crearCliente } from "@/server/clientes";

// Mismo schema que el servidor: reusalo si podés importarlo.
const schema = z.object({
  razonSocial: z.string().trim().min(3, "Mínimo 3 caracteres"),
  ruc: z.string().regex(/^\d{6,8}-\d$/, "Formato: 1234567-8"),
  email: z.string().email("Email inválido").optional().or(z.literal("")),
});

type FormValues = z.infer<typeof schema>;

export const Route = createFileRoute("/clientes/nuevo")({
  component: NuevoClientePage,
});

function NuevoClientePage() {
  const navigate = useNavigate();

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Siempre definí defaults: sin esto React avisa por inputs no controlados.
    defaultValues: { razonSocial: "", ruc: "", email: "" },
  });

  const mutation = useMutation({
    mutationFn: (values: FormValues) => crearCliente({ data: values }),
    onSuccess: () => {
      toast.success("Cliente creado");
      navigate({ to: "/clientes" });
    },
    onError: (error) => {
      toast.error(error instanceof Error ? error.message : "No se pudo guardar");
    },
  });

  return (
    <AppLayout active="Clientes" title="Nuevo cliente">
      <main className="mx-auto max-w-2xl space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Nuevo cliente</h1>

        <Form {...form}>
          <form
            onSubmit={form.handleSubmit((values) => mutation.mutate(values))}
            className="surface-card space-y-5 p-5"
          >
            <FormField
              control={form.control}
              name="razonSocial"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Razón social</FormLabel>
                  <FormControl>
                    <Input placeholder="Distribuidora Aurora S.A." {...field} />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="ruc"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>RUC</FormLabel>
                  <FormControl>
                    <Input placeholder="1234567-8" {...field} />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <div className="flex justify-end gap-2">
              <Button type="button" variant="ghost" onClick={() => navigate({ to: "/clientes" })}>
                Cancelar
              </Button>
              <Button type="submit" disabled={mutation.isPending}>
                {mutation.isPending ? "Guardando…" : "Guardar"}
              </Button>
            </div>
          </form>
        </Form>
      </main>
    </AppLayout>
  );
}
```

### Reglas

- **`defaultValues` siempre**, con string vacío para los opcionales.
- **`FormMessage`** muestra el error de zod automáticamente: no armes el mensaje
  a mano.
- **Deshabilitá el submit** mientras `isPending` para evitar el doble envío.
- **El mismo schema en cliente y servidor.** Si el schema vive en un archivo
  compartido (`src/lib/schemas/`), importalo en los dos lados y no lo dupliques.

---

## 6. Leer y mutar datos

### Lectura con el loader de la ruta

Es lo mejor para el contenido principal: los datos vienen ya resueltos en el
HTML del servidor, sin spinner inicial.

```tsx
export const Route = createFileRoute("/clientes")({
  loader: () => listarClientes({ data: { pagina: 1 } }),
  component: ClientesPage,
});

function ClientesPage() {
  const { items } = Route.useLoaderData(); // tipado, sin estado de carga
  // …
}
```

### Lectura con TanStack Query

Para datos que se refrescan, dependen de interacción o se comparten entre
componentes:

```tsx
const { data, isLoading } = useQuery({
  queryKey: ["clientes", { busqueda }],
  queryFn: () => listarClientes({ data: { busqueda, pagina: 1 } }),
});
```

### Invalidar después de mutar

Sin esto la lista queda desactualizada tras crear o editar:

```tsx
const queryClient = useQueryClient();

const mutation = useMutation({
  mutationFn: (v: FormValues) => crearCliente({ data: v }),
  onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: ["clientes"] });
  },
});
```

---

## 7. Conectar la base de datos

Hoy el login es sólo frontend ([src/routes/index.tsx](../src/routes/index.tsx)
navega con un `setTimeout`). Para conectar la base:

**1. Elegí un driver compatible con Workers.** El runtime es Cloudflare Workers,
no Node: `pg` y `mysql2` **no funcionan**. Opciones válidas:

| Base        | Driver                                    |
| ----------- | ----------------------------------------- |
| PostgreSQL  | `@neondatabase/serverless`, `postgres.js` |
| MySQL       | `@planetscale/database`                   |
| SQLite (CF) | D1 (`env.DB`, nativo)                     |
| Cualquiera  | Drizzle ORM sobre los anteriores          |

**2. Guardá las credenciales como secrets de Cloudflare**, nunca en el repo:

```sh
npm run build
npx wrangler secret put DATABASE_URL -c .output/server/wrangler.json
```

**3. Creá el cliente en un módulo de servidor:**

```ts
// src/server/db.ts
import { neon } from "@neondatabase/serverless";

export function getDb() {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("Falta DATABASE_URL");
  return neon(url);
}
```

**4. Usalo dentro del handler**, nunca en el nivel superior del módulo — en
Workers no hay conexiones persistentes entre requests.

> Para desarrollo local poné las variables en `.dev.vars`, que ya está listado
> en `.gitignore` y no se sube al repositorio.

---

## 8. Autenticación

Cuando reemplaces el login simulado:

**Hasheá las contraseñas** con bcrypt o argon2 — nunca en texto plano ni con
SHA sin salt.

**Usá cookies `httpOnly`** para la sesión, no `localStorage`: JavaScript no debe
poder leer el token.

```ts
export const login = createServerFn({ method: "POST" })
  .validator(z.object({ usuario: z.string(), password: z.string() }))
  .handler(async ({ data }) => {
    const user = await verificarCredenciales(data);
    if (!user) throw { statusCode: 401, message: "Usuario o contraseña incorrectos" };

    const token = await crearSesion(user.id);
    return new Response(null, {
      status: 200,
      headers: {
        "Set-Cookie": `sesion=${token}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=86400`,
      },
    });
  });
```

**Protegé las rutas privadas** con `beforeLoad`:

```tsx
export const Route = createFileRoute("/home")({
  beforeLoad: async () => {
    const sesion = await obtenerSesion();
    if (!sesion) throw redirect({ to: "/" });
  },
  component: HomePage,
});
```

**Mensajes de error genéricos en el login.** Decir "el usuario no existe"
permite enumerar cuentas válidas.

---

## 9. Checklist

Antes de abrir un PR:

- [ ] `npx tsc --noEmit` sin errores
- [ ] `npm run lint` sin errores
- [ ] `npm run build` pasa
- [ ] La página está envuelta en `<AppLayout>` y el item del menú se marca activo
- [ ] Los formularios validan con zod **en cliente y servidor**
- [ ] Las mutaciones invalidan las queries afectadas
- [ ] Probado en modo claro y oscuro
- [ ] Probado en ancho de móvil (la barra inferior no tapa contenido)
- [ ] Sin credenciales ni claves en el código
- [ ] Los colores usan variables del design system, no hex sueltos

### Errores frecuentes

| Síntoma                               | Causa                                        |
| ------------------------------------- | -------------------------------------------- |
| `window is not defined`               | Acceso al DOM fuera de `useEffect` (hay SSR) |
| El menú desaparece en una página      | Falta envolver en `<AppLayout>`              |
| La lista no se actualiza tras guardar | Falta `invalidateQueries`                    |
| Warning de input no controlado        | Falta `defaultValues` en `useForm`           |
| El color no cambia con el tema        | Hex hardcodeado en vez de variable CSS       |
| `pg`/`mysql2` no funcionan            | Workers no es Node: usá un driver serverless |
