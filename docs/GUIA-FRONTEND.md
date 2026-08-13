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
   - [Todo listado busca y ordena](#51-todo-listado-busca-y-ordena)
6. [Formularios](#6-formularios)
   - [Elegir un valor de otra tabla: Combobox](#elegir-un-valor-de-otra-tabla-combobox-no-select)
7. [El menú dinámico por dentro](#7-el-menú-dinámico-por-dentro)
8. [Checklist](#8-checklist)

---

## 1. Lo que hay que saber antes de escribir

> **Regla cero: copiá la página equivalente que ya funciona y cambiá los
> nombres. No inventes una variante.**
>
> Para una tabla hija de otra (Ciudades cuelga de Departamentos, que cuelga de
> Países), la referencia es
> [_auth.departamentos.tsx](../src/routes/_auth.departamentos.tsx): filtro por
> el padre en el header de su columna (`TableHeadFiltrable`), corte de a 20 con
> "Mostrar más", tabla + tarjetas, diálogo de alta/edición. Para una tabla sin
> padre, [_auth.paises.tsx](../src/routes/_auth.paises.tsx).
>
> Esto no es pereza, es la lección más cara de este proyecto. Implementar
> Ciudades "parecido pero a mi manera" —columnas de más, otra `queryKey`, otra
> forma de filtrar— costó media docena de idas y vueltas para terminar
> exactamente en el patrón de Departamentos. Cada desviación parecía una mejora
> aislada y ninguna lo era.
>
> Si creés que el patrón existente está mal, cambialo **en todas las páginas a
> la vez**, no sólo en la nueva. Dos páginas hermanas que hacen lo mismo de
> forma distinta es peor que dos páginas con el mismo defecto.

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

| Archivo              | Nombre en `PAGINAS` | `PAGINAS.RUTA` |
| -------------------- | ------------------- | -------------- |
| `_auth.empresas.tsx` | Empresas            | `/empresas`    |
| `_auth.paises.tsx`   | Paises              | `/paises`      |

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
{
  /* Móvil: tarjetas. Una tabla de 4 columnas en 360px obliga a scrollear
    de costado para leer una fila entera. */
}
<ul className="space-y-3 sm:hidden">
  {paises.map((pais) => (
    <li key={pais.id} className="surface-card p-4">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <p className="truncate font-semibold text-foreground">{pais.nombrePais}</p>
          <p className="mt-0.5 text-xs text-muted-foreground">{pais.codigoPais || "Sin código"}</p>
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
</ul>;

{
  /* Escritorio: tabla */
}
<div className="surface-card hidden overflow-x-auto sm:block">
  <Table>{/* … */}</Table>
</div>;
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

## 5.1 Todo listado busca y ordena

**Regla: todo listado del proyecto —página o diálogo, tabla o `<ul>`— lleva un
buscador que filtra por cualquier campo visible. Si se muestra como `<Table>`,
además cada columna ordena al hacer click en su header.**

Es la misma regla para todos: no hay pantallas "simples" exentas. Un listado
de 6 filas hoy puede tener 60 en seis meses, y agregarlo después implica tocar
un componente que ya está en producción en vez de escribirlo bien la primera
vez.

### El hook: `useTablaListado`

[use-tabla-listado.ts](../src/hooks/use-tabla-listado.ts) hace las dos cosas.
Es client-side a propósito: los listados de este proyecto son catálogos
chicos —países, departamentos, módulos— que el backend ya trae completos de
una sola vez (ver [3. Crear el backend](GUIA-IMPLEMENTACION.md#3-crear-el-backend-de-una-tabla)),
así que no se justifica un ida y vuelta al servidor por cada tecla o cada
click en un header.

```tsx
const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
  data?.items ?? [],
  // Qué campos entran en la búsqueda. Una función, no una lista de keys:
  // "activo" hay que traducirlo a texto antes de que alguien pueda buscar
  // "Activo" o "Inactivo" — buscar el código "A" a mano no ocurre.
  (departamento) => [
    departamento.nombreDepartamento,
    departamento.pais,
    esActivo(departamento.activo) ? "Activo" : "Inactivo",
  ],
);
```

`resultado` reemplaza a `data.items` en todo lo que sigue: el `.map()` de la
tabla, el de las tarjetas, el conteo del pie de página. `termino` sirve para
distinguir "no hay nada cargado" de "no hay nada que coincida" en el estado
vacío (ver más abajo).

### Filtrar por una columna: `TableHeadFiltrable`

> **El filtro vive en el header de la columna que filtra, no en un campo suelto
> arriba de la tabla.**

[TableHeadFiltrable](../src/components/ctell/TableHeadFiltrable.tsx) es
`TableHeadOrdenable` más un embudo que abre un desplegable con buscador. El
texto del header ordena; el embudo filtra. Son dos botones porque son dos
acciones distintas sobre la misma columna.

```tsx
const [filtroPais, setFiltroPais] = useState<string>(SIN_FILTRO);

// El endpoint trae todo; el filtro recorta en memoria.
const filtrados = (data?.items ?? []).filter(
  (d) => filtroPais === SIN_FILTRO || String(d.idPais) === filtroPais,
);

// …y `filtrados` —no `data.items`— es lo que entra a useTablaListado.

<TableHeadFiltrable
  direccion={orden?.campo === "pais" ? orden.direccion : null}
  onOrdenar={() => alternarOrden("pais")}
  opciones={paisesOpciones.map((p) => ({ valor: p.valor, etiqueta: p.etiqueta }))}
  valor={filtroPais}
  onFiltrar={setFiltroPais}
  buscarPlaceholder="Buscar país…"
>
  País
</TableHeadFiltrable>;
```

`SIN_FILTRO` lo exporta el componente y vale `"__todos__"` — no `""`, que cmdk
no admite, ni `"todos"`, que podría chocar con un valor real. La opción "Todos"
la agrega el componente: no la pases en `opciones`.

**El filtro se aplica en el cliente**, aunque el endpoint acepte `?idX=`. El
listado ya viene entero, así que cambiar de valor es instantáneo y no dispara un
viaje a la red. El parámetro del backend se deja igual: sigue siendo útil y
quitarlo no gana nada.

**El embudo se pinta resaltado cuando hay un filtro activo.** Un filtro que no
se ve es un filtro que hace parecer que faltan datos.

### Listados largos: cortar de a 20 con "Mostrar más"

Traer todo de una vez está bien para la red y mal para el DOM: sin corte, un
listado grande traba la página al abrirla. Las tablas muestran `POR_PAGINA = 20`
y suman de a 20:

```tsx
const [visibles, setVisibles] = useState(POR_PAGINA);

// Se resetea al cambiar filtro o búsqueda: seguir en "80 de 90" después de
// filtrar a 12 resultados mostraría todo de golpe.
const claveVista = `${filtroPais}|${termino}`;
const [claveAnterior, setClaveAnterior] = useState(claveVista);
if (claveVista !== claveAnterior) {
  setClaveAnterior(claveVista);
  setVisibles(POR_PAGINA);
}

const mostrados = resultado.slice(0, visibles);
const quedan = resultado.length - mostrados.length;
```

Ese reset es **ajuste de estado en render, no `useEffect`**: React re-renderiza
antes de pintar, así que la lista nunca se ve un frame con el valor viejo.

El corte va sobre `resultado` —lo que ya salió de la búsqueda y el orden—, así
que **buscar sigue buscando sobre todas las filas**, no sólo sobre las visibles.
Tanto la tabla como las tarjetas de móvil iteran `mostrados`.

### El input de búsqueda

Mismo lugar en todas las pantallas: al lado del botón "Nuevo", con el ícono
`Search` de lucide-react superpuesto.

```tsx
<div className="flex flex-wrap items-center gap-2">
  <div className="relative min-w-48 flex-1">
    <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
    <Input
      value={busqueda}
      onChange={(e) => setBusqueda(e.target.value)}
      placeholder="Buscar por departamento, país…"
      className="pl-9"
    />
  </div>
  <Button onClick={() => setCreando(true)}>
    <Plus className="size-4" />
    Nuevo
  </Button>
</div>
```

El placeholder nombra los campos que realmente busca — no un genérico
"Buscar…" que no le dice a quien usa el sistema qué puede escribir ahí.

### El estado vacío distingue "sin datos" de "sin resultados"

```tsx
{
  !isPending && !isError && resultado.length === 0 && (
    <div className="surface-card px-3 py-16 text-center">
      <p className="text-sm text-muted-foreground">
        {termino
          ? `Sin resultados para "${busqueda.trim()}".`
          : "Todavía no hay departamentos cargados."}
      </p>
      {/* "Cargar el primero" no tiene sentido cuando lo que falta es afinar
        la búsqueda, no cargar datos que ya existen. */}
      {!termino && (
        <Button className="mt-4" onClick={() => setCreando(true)}>
          Cargar el primero
        </Button>
      )}
    </div>
  );
}
```

### Headers ordenables: `TableHeadOrdenable`

Sólo aplica a listados en `<Table>` (desktop). Las tarjetas de móvil no tienen
headers — ahí el orden no se ofrece, y está bien así.

[TableHeadOrdenable.tsx](../src/components/ctell/TableHeadOrdenable.tsx)
reemplaza a `<TableHead>` en las columnas que tenga sentido ordenar (no en
"Acciones"):

```tsx
<TableHeader>
  <TableRow>
    <TableHeadOrdenable
      direccion={orden?.campo === "nombreDepartamento" ? orden.direccion : null}
      onClick={() => alternarOrden("nombreDepartamento")}
    >
      Departamento
    </TableHeadOrdenable>
    <TableHeadOrdenable
      direccion={orden?.campo === "pais" ? orden.direccion : null}
      onClick={() => alternarOrden("pais")}
    >
      País
    </TableHeadOrdenable>
    <TableHead className="text-right">Acciones</TableHead>
  </TableRow>
</TableHeader>
```

Tres clicks en el mismo header: ascendente → descendente → vuelve al orden
original que trajo el backend. El ícono cambia solo (flecha doble gris sin
ordenar, arriba/abajo con la dirección activa).

### Diálogos con `<ul>` en vez de `<Table>`

`UsuariosDialog`, `ModulosDialog` y `PaginasDialog` muestran una lista simple,
no una tabla con columnas — ahí sólo aplica el buscador, no hay headers que
ordenar. El criterio es el mismo: si son más de un puñado de filas, buscan.

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
{
  esEdicion && (
    <FormField
      control={form.control}
      name="activo"
      render={({ field }) => (
        <FormItem className="flex items-center justify-between rounded-lg border border-border p-3">
          <div className="space-y-0.5">
            <FormLabel>Activo</FormLabel>
            <FormDescription>
              Un país inactivo deja de ofrecerse en los formularios.
            </FormDescription>
          </div>
          <FormControl>
            <Switch checked={field.value} onCheckedChange={field.onChange} />
          </FormControl>
        </FormItem>
      )}
    />
  );
}
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

### Elegir un valor de otra tabla: `Combobox`, no `Select`

**Regla: todo selector de una FK —país, módulo, usuario, cualquier lista que
salga de otra tabla— usa `Combobox`, no el `<Select>` de shadcn.**

Un `<Select>` nativo no filtra: con 200 países cargados, buscar "Paraguay"
significa scrollear a mano por una lista alfabética. `<Select>` sigue siendo
correcto para listas fijas y cortas que no salen de una tabla —"Activo/Inactivo",
la `entrada` de una página (`D`/`O`/`R`)—, donde no hay nada que buscar.

[Combobox.tsx](../src/components/ctell/Combobox.tsx) es un botón que abre un
popover con un input de búsqueda arriba y las opciones filtrándose en vivo
(`Command` + `Popover` de shadcn, ya instalados). No pide datos por su cuenta:
arma `opciones` a partir de lo que ya haya cargado con `useQuery`, igual que
antes se armaban los `<SelectItem>`.

```tsx
const { data: paises, isPending: cargandoPaises } = useQuery({
  queryKey: ["paises"],
  queryFn: () => api.paises.listar(),
});

const paisesOpciones = (paises?.items ?? []).map((p) => ({
  valor: String(p.id),
  etiqueta: p.nombrePais,
  // Opcional: texto chico y gris debajo de la etiqueta — el código de país,
  // el usuario de login, lo que ayude a distinguir entre opciones parecidas.
  descripcion: p.codigoPais ?? undefined,
}));

<FormField
  control={form.control}
  name="idPais"
  render={({ field }) => (
    <FormItem>
      <FormLabel>País</FormLabel>
      <FormControl>
        <Combobox
          opciones={paisesOpciones}
          value={field.value}
          onChange={field.onChange}
          placeholder="Elegí un país"
          buscarPlaceholder="Buscar país…"
          cargando={cargandoPaises}
        />
      </FormControl>
      <FormDescription>El departamento pertenece a este país.</FormDescription>
      <FormMessage />
    </FormItem>
  )}
/>;
```

El `value` sigue siendo el `id` como string, igual que con `<Select>`: el
`schema` de zod y la conversión a `Number(...)` al enviar no cambian.

**También en los filtros de listado**, no sólo en el alta/edición — el
selector de país en el filtro de Departamentos es el mismo componente:

```tsx
<Combobox
  opciones={[{ valor: TODOS, etiqueta: "Todos los países" }, ...paisesOpciones]}
  value={filtroPais}
  onChange={setFiltroPais}
  placeholder="Todos los países"
/>
```

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

| Archivo                                                      | Qué hace                                           |
| ------------------------------------------------------------ | -------------------------------------------------- |
| [use-menu-usuario.ts](../src/hooks/use-menu-usuario.ts)      | Pide los permisos y los agrupa módulo → entrada    |
| [MenuDinamico.tsx](../src/components/ctell/MenuDinamico.tsx) | Renderiza el acordeón                              |
| [menu-iconos.ts](../src/components/ctell/menu-iconos.ts)     | Resuelve el ícono de cada módulo, entrada y página |

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

**Al crear una página, sumá su nombre a `ICONOS_PAGINA`.** Es un paso fácil de
olvidar y no rompe nada —cae en el documento genérico—, pero deja la página
nueva visualmente indistinguible del resto del menú.

Y si la página pertenece a una jerarquía, **dale un ícono propio a cada nivel**.
Países / Departamentos / Ciudades usan `Globe` / `Map` / `MapPin`: con el mismo
ícono repetido, el menú no deja distinguir un nivel de otro de un vistazo.

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

### Todo arranca cerrado, y lo que se abre queda abierto

Módulos y entradas (Definiciones / Operaciones / Reportes) **arrancan
colapsados**. El usuario despliega lo que necesita; abrir cosas de entrada llena
el sidebar de páginas que nadie pidió ver.

Y una vez abiertos, **no se cierran solos al navegar**. Eso obliga a dos cosas,
y las dos se aprendieron rompiéndolas:

**1. El estado no se deriva en render.**

```tsx
// ❌ La entrada queda TRABADA abierta.
// Parado en una página de Definiciones, contieneActivo es true, el OR gana
// en cada render, y plegarla no hace nada visible.
const [abierta, setAbierta] = useState(true);
const desplegada = abierta || contieneActivo;
```

Si un valor se puede cambiar por interacción, no lo combines con un `||` contra
una condición externa: el toggle queda muerto, sin error, sólo un click que
aparentemente no hace nada. El bug además se disfraza — sólo pasa en la entrada
que contiene la página activa, así que parece un problema de esa sección.

**2. El estado tiene que vivir FUERA del componente.**

`AppLayout` lo monta cada página, así que **navegar desmonta y remonta
`MenuDinamico`**. Un `useState` vuelve a su valor inicial y cierra todo el menú
justo al hacer click en una página — que es exactamente cuando el usuario menos
lo espera.

Por eso lo desplegado vive en un store module-level respaldado en
`sessionStorage`, y se consume con `useSyncExternalStore`:

```tsx
const abiertos = useAbiertos();          // ReadonlySet<string>
onClick={() => alternarClave(`m:${modulo.id}`)}
```

Las claves son `m:<idModulo>` y `e:<idModulo>:<entrada>`. Dos detalles que
`useSyncExternalStore` no perdona: el `getSnapshot` tiene que devolver **la
misma referencia** mientras nada cambie (reconstruir el Set en cada lectura es
un bucle de renders), y el snapshot de servidor tiene que ser una **constante**,
no una llamada que cree un objeto nuevo.

Este patrón sirve para cualquier estado de UI que deba sobrevivir a la
navegación. No lo pongas en `useState` dentro de algo que `AppLayout` monte.

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
- [ ] **Buscador con `useTablaListado`** que filtra por los campos visibles
- [ ] **Headers ordenables (`TableHeadOrdenable`)** en cada columna de la tabla desktop
- [ ] **Filtro por columna con `TableHeadFiltrable`** si la tabla filtra por una FK —
      en el header, no en un campo suelto arriba
- [ ] **Corte de a 20 con "Mostrar más"**, y `mostrados` (no `resultado`) en la
      tabla y en las tarjetas
- [ ] **Selectores de FK con `Combobox`**, no `<Select>` — país, módulo, usuario, etc.
- [ ] Formularios con `values`/`defaultValues` y validación zod
- [ ] Toggle de activo sólo en edición, no en el alta
- [ ] Las mutaciones invalidan sus queries
- [ ] Probado en claro/oscuro y en ancho de móvil

### Errores frecuentes

| Síntoma                                               | Causa                                                                                                                                                        |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| El item aparece en el menú pero el clic no navega     | `PAGINAS.RUTA` no coincide con ninguna ruta del router                                                                                                       |
| El menú no muestra una página asignada                | El módulo o la página están inactivos, o falta el permiso                                                                                                    |
| Todo se ve bien pero una acción no hace nada          | La API no devuelve un campo: llega `undefined`. Corré `npx tsc --noEmit`                                                                                     |
| El texto no se lee en hover en el sidebar             | Falta `variant="dark"`: las clases claras no contrastan sobre el navy                                                                                        |
| El formulario muestra datos del registro anterior     | Se usó `defaultValues` en vez de `values` en un dialog reutilizado                                                                                           |
| El error del backend no se ve al borrar               | Falta `e.preventDefault()` en el `AlertDialogAction`                                                                                                         |
| La lista no se actualiza tras guardar                 | Falta `invalidateQueries`                                                                                                                                    |
| `window is not defined`                               | Acceso al DOM fuera de `useEffect` (corre en el prerender de build)                                                                                          |
| Cambios que no aparecen por más que recargues         | Hay más de un `npm run dev` corriendo: mirá en qué puerto estás                                                                                              |
| El buscador no encuentra nada que sí está en pantalla | Falta agregar ese campo al array que devuelve la función de `useTablaListado`                                                                                |
| El Combobox no filtra por lo que se ve en pantalla    | El `filter` de `Command` compara contra `value` (el id): revisá que `Combobox` esté resolviendo `opcion.etiqueta`, no uses `Command` pelado sin ese `filter` |
