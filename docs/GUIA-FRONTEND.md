# Guía de implementación — Frontend

Cómo agregar páginas, formularios y listados siguiendo los patrones de este
proyecto. Los ejemplos salen del código que ya existe:
[_auth.paises.tsx](../src/routes/_auth.paises.tsx) es la plantilla de una
pantalla ABM completa.

> **Para el backend hay guía aparte:**
> [GUIA-IMPLEMENTACION.md](GUIA-IMPLEMENTACION.md) — tablas, paquetes PL/SQL y
> endpoints ORDS.

## Índice

1. [Lo que hay que saber antes de escribir](#1-lo-que-hay-que-saber-antes-de-escribir)
2. [Agregar una página](#2-agregar-una-página)
3. [Registrarla en el menú](#3-registrarla-en-el-menú)
4. [Consumir la API](#4-consumir-la-api)
5. [Listados: tabla y tarjetas](#5-listados-tabla-y-tarjetas)
6. [Formularios](#6-formularios)
7. [El menú dinámico por dentro](#7-el-menú-dinámico-por-dentro)
8. [Checklist](#8-checklist)

---

## 1. Lo que hay que saber antes de escribir

**El ruteo es por archivo.** Un archivo en `src/routes/` define una URL.
`src/routeTree.gen.ts` se genera solo y **nunca se edita a mano**.

**No hay SSR.** El build es SPA porque GitHub Pages sólo sirve estáticos. Aun
así, evitá `window`, `document` o `sessionStorage` fuera de `useEffect`: el
primer render pasa por un prerender en build time donde tampoco existen.

**Las rutas con sesión van bajo `_auth.`** —
[_auth.tsx](../src/routes/_auth.tsx) exige token antes de renderizar sus hijos.
Una página nueva se llama `_auth.<algo>.tsx`, no `<algo>.tsx` suelto.

**El estado es `'A'`/`'I'`, no booleano.** Viene así de la base y se tipa como
`Estado`. Para preguntar si algo está activo se usa el helper `esActivo(x)`, no
`x.activo === "A"` suelto por ahí.

**`npx tsc --noEmit` antes de dar por perdido un bug de UI.** El proyecto tiene
`exactOptionalPropertyTypes` activado y el compilador detecta cosas que en
runtime fallan en silencio — un campo que la API no devuelve, por ejemplo.

---

## 2. Agregar una página

El nombre del archivo define la URL:

| Archivo                    | URL               |
| -------------------------- | ----------------- |
| `_auth.empresas.tsx`       | `/empresas`       |
| `_auth.empresas.$id.tsx`   | `/empresas/:id`   |
| `_auth.empresas.nuevo.tsx` | `/empresas/nuevo` |

```tsx
import { createFileRoute } from "@tanstack/react-router";

import { AppLayout } from "@/components/ctell/AppLayout";

function EmpresasPage() {
  return (
    <AppLayout active="/empresas" title="Empresas">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Empresas</h1>
      </main>
    </AppLayout>
  );
}

export const Route = createFileRoute("/_auth/empresas")({
  head: () => ({ meta: [{ title: "Empresas | CTELL" }] }),
  component: EmpresasPage,
});
```

Tres detalles que importan:

- **`active` lleva la ruta, no el nombre.** `active="/empresas"`, no
  `active="Empresas"`. El menú compara contra `pagina.ruta`, que viene de la
  base; usar el nombre falla apenas difiere un acento (`Países` vs `Paises`).
- **`pb-28`** deja lugar para el botón flotante del menú móvil, que si no tapa
  el final del contenido.
- **Envolvé siempre en `<AppLayout>`** — da el sidebar, el header y el menú
  móvil.

### Una página es una página, no un modal

Si la pantalla existe en el menú, tiene que mostrar su contenido al entrar. Una
página cuyo cuerpo es sólo un título y un `<Dialog>` que se abre solo no es una
página: es un modal con URL.

```tsx
// Mal: entrar a /paises muestra un título vacío y un modal encima
function PaisesPage() {
  const [abierto, setAbierto] = useState(true);
  return (
    <AppLayout active="/paises">
      <h1>Catálogo de Países</h1>
      <PaisesDialog open={abierto} onOpenChange={setAbierto} />
    </AppLayout>
  );
}

// Bien: la lista está en la página; el modal es sólo para alta y edición
function PaisesPage() {
  const [editando, setEditando] = useState<Pais | null>(null);
  const [creando, setCreando] = useState(false);
  const { data } = useQuery({ queryKey: ["paises"], queryFn: () => api.paises.listar() });
  // … tabla/tarjetas con data.items, y <PaisFormDialog> sólo cuando hace falta
}
```

Los `*Dialog.tsx` de `src/components/ctell/` son la excepción histórica: viven
dentro del panel de Administración, que agrupa varios ABM chicos en una sola
pantalla. Para una entidad con su propia entrada de menú, hacé página.

---

## 3. Registrarla en el menú

El menú **no se declara en el código**: sale de las tablas `MODULOS`, `PAGINAS`
y `USUARIO_PAGINAS`. Crear el archivo `.tsx` no la hace aparecer.

Después de crear la página, desde **Administración**:

1. **Páginas → Nueva** — elegí el módulo, poné el nombre, y **seleccioná la ruta
   del desplegable**. Las opciones salen de `RUTAS_DISPONIBLES` en
   [PaginasDialog.tsx](../src/components/ctell/PaginasDialog.tsx): **cuando
   agregues una ruta nueva, agregala también a ese array**, o no va a estar
   disponible para elegir.
2. **Permisos** — elegí el usuario y tildá la página.

### La ruta en la base tiene que existir en el router

Este es el error más caro de diagnosticar del proyecto. Si `PAGINAS.RUTA` dice
`/base/paises` pero el archivo es `_auth.paises.tsx` (que sirve `/paises`), el
menú muestra el item pero el clic no lleva a ningún lado.

**Convención:** el nombre de la página en la base coincide con el archivo.

| Archivo               | Nombre en `PAGINAS` | `PAGINAS.RUTA` |
| --------------------- | ------------------- | -------------- |
| `_auth.empresas.tsx`  | Empresas            | `/empresas`    |
| `_auth.paises.tsx`    | Paises              | `/paises`      |

---

## 4. Consumir la API

Agregá el tipo y el bloque en [src/lib/api.ts](../src/lib/api.ts):

```ts
export type Pais = {
  id: number;
  nombrePais: string;
  codigoPais: string | null;
  activo: Estado;
};

export const api = {
  // … resto …

  paises: {
    listar: () => request<{ items: Pais[]; total: number }>("/paises/listar"),

    crear: (datos: { nombrePais: string; codigoPais?: string }) =>
      request<{ id: number; ok: boolean }>("/paises/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: { nombrePais?: string; codigoPais?: string; activo?: Estado },
    ) =>
      request<{ ok: boolean }>(`/paises/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/paises/eliminar/${id}`, { method: "DELETE" }),
  },
};
```

`request()` adjunta el `Authorization`, parsea el JSON y lanza `ApiError` con el
status. Un 401 limpia el token y avisa al layout para volver al login.

### El tipo es el contrato con el backend

**Cada campo del tipo tiene que existir en el `JSON_OBJECT` del PL/SQL.** Si no,
llega `undefined` en runtime y el bug es silencioso. TypeScript lo detecta:

```
Property 'ruta' does not exist on type 'UsuarioPagina'.
```

Ese error real estuvo visible mientras se buscaba el problema en el CSS del
menú. Ver el caso completo en
[la guía de backend, sección 5](GUIA-IMPLEMENTACION.md#5-devolver-lo-que-el-consumidor-necesita).

---

## 5. Listados: tabla y tarjetas

**Una tabla de 4 columnas no entra en 360px.** El patrón del proyecto es
tarjetas abajo de `sm`, tabla de `sm` para arriba:

```tsx
{/* Móvil: tarjetas. Una tabla de 4 columnas en 360px obliga a scrollear
    de costado para leer una fila entera. */}
<ul className="space-y-3 sm:hidden">
  {paises.map((pais) => (
    <li key={pais.id} className="surface-card p-4">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <p className="truncate font-semibold text-foreground">{pais.nombrePais}</p>
          <p className="mt-0.5 text-xs text-muted-foreground">
            {pais.codigoPais || "Sin código"}
          </p>
        </div>
        <Badge variant={esActivo(pais.activo) ? "secondary" : "outline"} className="shrink-0">
          {esActivo(pais.activo) ? "Activo" : "Inactivo"}
        </Badge>
      </div>

      <div className="mt-3 flex gap-2 border-t border-border pt-3">
        <Button variant="outline" size="sm" className="flex-1" onClick={() => setEditando(pais)}>
          <Pencil className="size-4" />
          Editar
        </Button>
        {/* … eliminar … */}
      </div>
    </li>
  ))}
</ul>

{/* Escritorio: tabla */}
<div className="surface-card hidden overflow-x-auto sm:block">
  <Table>{/* … */}</Table>
</div>
```

Los cuatro estados de un listado se manejan siempre, en este orden:

```tsx
{isPending && <Skeleton className="h-14 w-full" />}
{isError && <p className="…text-destructive">{MENSAJE_ERROR(error, "No se pudo cargar")}</p>}
{!isPending && !isError && items.length === 0 && (
  <div className="surface-card px-3 py-16 text-center">
    <p className="text-sm text-muted-foreground">Todavía no hay países cargados.</p>
    <Button className="mt-4" onClick={() => setCreando(true)}>Cargar el primero</Button>
  </div>
)}
{items.length > 0 && /* … lista … */}
```

El vacío con acción —"cargar el primero"— evita la pantalla muerta donde el
usuario no sabe qué hacer.

---

## 6. Formularios

**react-hook-form + zod**, con los componentes de `@/components/ui/form`.

```tsx
const schema = z.object({
  nombrePais: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
  codigoPais: z.string().trim().max(3, "Máximo 3 caracteres").optional().or(z.literal("")),
  activo: z.boolean(),
});

type FormValues = z.infer<typeof schema>;

const form = useForm<FormValues>({
  resolver: zodResolver(schema),
  // `values` y no `defaultValues`: el mismo dialog sirve para alta y edición,
  // y sin esto conserva los datos del registro anterior al reabrirse.
  values: {
    nombrePais: pais?.nombrePais ?? "",
    codigoPais: pais?.codigoPais ?? "",
    activo: pais ? esActivo(pais.activo) : true,
  },
});
```

**Siempre `defaultValues` o `values`** — sin eso React avisa por inputs no
controlados. Usá `values` cuando el formulario se reutiliza para editar
registros distintos.

### El toggle de activo va sólo en edición

El backend fuerza `'A'` en los INSERT: crear algo para dejarlo inactivo de
entrada no tiene sentido. En edición sí, con un `Switch`:

```tsx
{esEdicion && (
  <FormField
    control={form.control}
    name="activo"
    render={({ field }) => (
      <FormItem className="flex items-center justify-between rounded-lg border border-border p-3">
        <div className="space-y-0.5">
          <FormLabel>Activo</FormLabel>
          <FormDescription>Un país inactivo deja de ofrecerse en los formularios.</FormDescription>
        </div>
        <FormControl>
          <Switch checked={field.value} onCheckedChange={field.onChange} />
        </FormControl>
      </FormItem>
    )}
  />
)}
```

El booleano del formulario se traduce a `Estado` al enviar:

```tsx
const activo: Estado = v.activo ? "A" : "I";
```

### Mutaciones

```tsx
const guardar = useMutation({
  mutationFn: (v: FormValues) => api.paises.actualizar(pais.id, { …v, activo }),
  onSuccess: () => {
    // Sin esto la lista queda desactualizada.
    queryClient.invalidateQueries({ queryKey: ["paises"] });
    toast.success("País actualizado");
    onClose();
  },
  onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo actualizar")),
});
```

**El backend manda el mensaje real en los 400 y 409** ("Ya existe un país con
ese nombre"). El helper lo usa y cae en un texto genérico sólo si no llegó:

```tsx
const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;
```

**Validá en los dos lados.** El zod mejora la experiencia; la validación que
cuenta es la del paquete PL/SQL, porque cualquiera puede llamar al endpoint sin
pasar por el formulario.

### Confirmación de borrado

```tsx
<AlertDialogAction
  onClick={(e) => {
    // Sin esto el AlertDialog se cierra antes de que la mutación termine
    // y el error nunca se llega a mostrar.
    e.preventDefault();
    if (aEliminar) eliminar.mutate(aEliminar);
  }}
  disabled={eliminar.isPending}
>
```

---

## 7. El menú dinámico por dentro

Tres piezas:

| Archivo                                                              | Qué hace                                        |
| -------------------------------------------------------------------- | ----------------------------------------------- |
| [use-menu-usuario.ts](../src/hooks/use-menu-usuario.ts)               | Pide los permisos y los agrupa módulo → entrada  |
| [MenuDinamico.tsx](../src/components/ctell/MenuDinamico.tsx)           | Renderiza el acordeón                            |
| [menu-iconos.ts](../src/components/ctell/menu-iconos.ts)               | Resuelve el ícono de cada módulo, entrada y página |

Se monta en dos lugares de [AppLayout.tsx](../src/components/ctell/AppLayout.tsx):
el sidebar de escritorio (`variant="dark"`) y el panel móvil (`variant="light"`,
el default).

### `variant` existe porque el sidebar es oscuro

El sidebar usa `gradient-navy`; el panel móvil usa `bg-card`, que es claro. Las
clases `text-muted-foreground` sobre fondo oscuro quedan ilegibles en hover. Por
eso el componente cambia de paleta: `sidebar-*` en oscuro, las normales en claro.

Si agregás un menú en otro contexto oscuro, pasale `variant="dark"`.

### Los íconos se resuelven por nombre

`menu-iconos.ts` busca en tres niveles, del más específico al más genérico:

1. Un mapa por nombre conocido — `Compras` → carrito, `Paises` → globo.
2. `MODULOS.ICONO`, lo que se haya cargado en el ABM.
3. Un default: grilla para módulos, documento para páginas.

Las entradas tienen ícono fijo por tipo, porque definen la sección:
Definiciones → sliders, Operaciones → planilla, Reportes → gráfico.

**Para agregar un ícono nuevo** hay que sumarlo a `POR_NOMBRE` (el import
explícito) y al mapa que corresponda. No se resuelve dinámicamente contra
lucide-react a propósito: el bundler necesita saber en compilación qué se
importa, y el paquete entero son miles de componentes.

### Por qué el link es un `<a>` y no un `<Link>`

`<Link to>` de TanStack Router espera un literal del árbol de rutas. La ruta del
menú sale de la base como string cualquiera, así que se navega imperativamente:

```tsx
<a
  href={destino || "#"}
  onClick={(e) => {
    e.preventDefault();
    if (destino) router.navigate({ to: destino });
  }}
>
```

`normalizarRuta()` limpia el valor antes: lo carga una persona en el ABM y puede
venir con espacios o sin la barra inicial.

---

## 8. Checklist

Antes de dar por terminada una pantalla:

- [ ] `npx tsc --noEmit` y `npm run lint` sin errores
- [ ] Tipo y bloque agregados en `src/lib/api.ts`
- [ ] El tipo declara **todos** los campos que devuelve el `JSON_OBJECT`
- [ ] Página envuelta en `<AppLayout>` con `active="/la-ruta"` (la ruta, no el nombre)
- [ ] `pb-28` en el `<main>` para el botón flotante de móvil
- [ ] La ruta agregada a `RUTAS_DISPONIBLES` en `PaginasDialog.tsx`
- [ ] Registrada en Administración → Páginas, y asignada en Permisos
- [ ] Los cuatro estados del listado: cargando, error, vacío con acción, con datos
- [ ] Tarjetas abajo de `sm`, tabla arriba
- [ ] Formularios con `values`/`defaultValues` y validación zod
- [ ] Toggle de activo sólo en edición, no en el alta
- [ ] Las mutaciones invalidan sus queries
- [ ] Probado en claro/oscuro y en ancho de móvil

### Errores frecuentes

| Síntoma                                          | Causa                                                                 |
| ------------------------------------------------ | --------------------------------------------------------------------- |
| El item aparece en el menú pero el clic no navega | `PAGINAS.RUTA` no coincide con ninguna ruta del router                |
| El menú no muestra una página asignada            | El módulo o la página están inactivos, o falta el permiso              |
| Todo se ve bien pero una acción no hace nada      | La API no devuelve un campo: llega `undefined`. Corré `npx tsc --noEmit` |
| El texto no se lee en hover en el sidebar         | Falta `variant="dark"`: las clases claras no contrastan sobre el navy  |
| El formulario muestra datos del registro anterior | Se usó `defaultValues` en vez de `values` en un dialog reutilizado     |
| El error del backend no se ve al borrar           | Falta `e.preventDefault()` en el `AlertDialogAction`                   |
| La lista no se actualiza tras guardar             | Falta `invalidateQueries`                                             |
| `window is not defined`                           | Acceso al DOM fuera de `useEffect` (corre en el prerender de build)    |
| Cambios que no aparecen por más que recargues     | Hay más de un `npm run dev` corriendo: mirá en qué puerto estás        |
