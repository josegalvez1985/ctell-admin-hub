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
   - [Empresa y sucursal activas](#empresa-y-sucursal-activas)
2. [Agregar una página](#2-agregar-una-página)
3. [Registrarla en el menú](#3-registrarla-en-el-menú)
4. [Consumir la API](#4-consumir-la-api)
5. [Listados: tabla y tarjetas](#5-listados-tabla-y-tarjetas)
   - [Todo listado busca y ordena](#51-todo-listado-busca-y-ordena)
6. [Formularios](#6-formularios)
   - [Un formulario entra en un pantallazo](#un-formulario-entra-en-un-pantallazo)
   - [Elegir un valor de otra tabla: SelectorModal](#elegir-un-valor-de-otra-tabla-selectormodal-no-select)
   - [Si la tabla de origen está paginada: selector en modal propio](#si-la-tabla-de-origen-está-paginada-selector-en-modal-propio)
   - [Formularios con detalle: cabecera y líneas](#61-formularios-con-detalle-cabecera-y-líneas)
7. [El menú dinámico por dentro](#7-el-menú-dinámico-por-dentro)
   - [Imágenes: siempre con respaldo](#71-imágenes-siempre-con-respaldo)
   - [Archivos que no van a la base: subida directa](#711-archivos-que-no-van-a-la-base-subida-directa)
   - [Paneles con scroll: `scrollbar-fino`](#72-paneles-con-scroll-scrollbar-fino)
   - [Montos: `InputMoneda` y `lib/moneda.ts`](#721-montos-inputmoneda-y-libmonedats)
   - [Texto largo: `truncate` no alcanza](#73-texto-largo-truncate-no-alcanza-y-en-un-diálogo-molesta)
8. [Checklist](#8-checklist)

---

## 1. Lo que hay que saber antes de escribir

> **Regla cero: copiá la página equivalente que ya funciona y cambiá los
> nombres. No inventes una variante.**
>
> Cuál copiar según el caso:
>
> | La tabla nueva…                | Copiá                                                            |
> | ------------------------------ | ---------------------------------------------------------------- |
> | no depende de nada             | [_auth.paises.tsx](../src/routes/_auth.paises.tsx)               |
> | cuelga de otra (padre visible) | [_auth.departamentos.tsx](../src/routes/_auth.departamentos.tsx) |
> | **es por empresa**             | [_auth.monedas.tsx](../src/routes/_auth.monedas.tsx)             |
> | por empresa y con imagen       | [_auth.articulos.tsx](../src/routes/_auth.articulos.tsx)         |
>
> Todas traen lo mismo: filtro en el header de la columna que filtra
> (`TableHeadFiltrable`), corte de a 20 con "Mostrar más", tabla en escritorio +
> tarjetas en móvil, y diálogo de alta/edición.

> Para `CUENTAS_BANCARIAS`, usá el patrón por empresa y agregá selectores para
> las FK: banco obligatorio y moneda opcional. El banco se obtiene de
> `api.bancos.listar()` y las monedas de `api.monedas.listar({ idEmpresa })`;
> mostrá sólo opciones activas.

Para el punto de venta, la pantalla recomendada es `/punto-venta`: catálogo de
artículos buscable, carrito sticky, precios manuales por línea y checkout en el
mismo panel. El resumen muestra subtotal, porcentaje de la lista, descuento y
total antes de confirmar. Cliente, lista, condición de pago, moneda y talonario
se eligen en el checkout; la cuenta bancaria se reserva para el registro
posterior del cobro.

El talonario se consulta con `api.talonarios.listar({ idEmpresa, idSucursal })`
y se muestran sólo los registros activos de la sucursal. El POS envía únicamente
`idTalonario` a `api.ventas.crear`; nunca genera `numeroVenta` ni permite editar
timbrado, establecimiento, punto de expedición o número actual. El backend
resuelve esos datos al confirmar para evitar numeración duplicada.

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

### Empresa y sucursal activas

El login pide credenciales **y** a qué empresa conectarse. Varias tablas
—Monedas, Unidades de medida, Categorías, Artículos— cuelgan de `EMPRESAS`, y su
listado se filtra por la empresa elegida.

```tsx
import { useEmpresa } from "@/components/ctell/empresa-provider";

const { empresa } = useEmpresa(); // { id, nombreEmpresa, tieneLogo } | null
```

**Toda página cuya tabla tenga `ID_EMPRESA` se acota a la empresa activa**, y el
recorte lo hace el backend, no la pantalla. Traer las filas de todas para
esconder casi todas manda por la red datos de empresas que nadie está mirando, y
tarde o temprano alguna se filtra en un total.

Sucursales lo hacía al revés —traía todas y filtraba con un combo en el header
de la columna Empresa— y se corrigió. Al acotar la consulta, tres cosas quedaron
sin sentido y se fueron con ella:

- **La columna Empresa**, que repetía el mismo valor en cada fila. La reemplazó
  Dirección, un campo que ya venía en el JSON y no se mostraba.
- **Su filtro**, que quedaba con una sola opción.
- **El selector de empresa del formulario**, que dejaba crear una sucursal en
  otra empresa — que después no aparecía en la lista. El alta va a la empresa
  activa; en edición el id sale de la propia fila, no del provider, para que el
  registro no se mude de empresa si alguien cambia de empresa con el diálogo
  abierto.

En una página por empresa hay **dos cosas que no se pueden olvidar**:

```tsx
const { data } = useQuery({
  // 1. El id va en la queryKey. Sin esto, al cambiar de empresa TanStack Query
  //    sirve en caché el listado de la anterior.
  queryKey: ["monedas", empresa?.id ?? null],
  queryFn: () => api.monedas.listar({ idEmpresa: empresa!.id }),
  // 2. `enabled` evita pedir sin empresa. El provider hidrata desde
  //    localStorage DESPUÉS de montar, así que en el primer render `empresa`
  //    todavía es null: sin esto la petición sale con idEmpresa vacío y trae
  //    las filas de TODAS las empresas por un instante.
  enabled: empresa !== null,
});
```

El `!` en `empresa!.id` es seguro justamente por el `enabled`: la query no corre
hasta que haya empresa.

Y contemplá el caso `empresa === null` en el render — pasa si alguien entró con
una sesión anterior a que el login pidiera elegirla:

```tsx
{
  empresa === null && !isPending && (
    <p>No hay una empresa activa. Cerrá sesión y volvé a entrar eligiendo una.</p>
  );
}
```

**El `idEmpresa` del formulario no es un campo.** Sale de la empresa activa y se
pasa como prop al diálogo; no hay combobox de empresa en ninguna de estas
pantallas.

> El menú también filtra por empresa: solo muestra las páginas cuyo permiso
> corresponde a la empresa activa (ver [7](#7-el-menú-dinámico-por-dentro)).

#### La sucursal activa

Algunas tablas cuelgan de la empresa **y** de la sucursal — `UBICACIONES` es la
primera. La sucursal vive en su propio provider, con la misma forma de uso:

```tsx
import { useSucursal } from "@/components/ctell/sucursal-provider";

const { sucursal, sucursales, cargando, setSucursal } = useSucursal();
// sucursal: { id, idEmpresa, nombreSucursal } | null
```

**No se elige en el login sino en el home**, y se elige sola cuando no hay
ambigüedad: si la empresa tiene una sola sucursal queda esa, y si tiene varias se
toma la primera hasta que el usuario cambie. Obligar a elegir entre una sola
opción es un click sin información.

En una página por empresa y sucursal van **las dos** en la `queryKey` y en el
`enabled`:

```tsx
const { empresa } = useEmpresa();
const { sucursal, cargando: cargandoSucursal } = useSucursal();

const { data } = useQuery({
  queryKey: ["ubicaciones", empresa?.id ?? null, sucursal?.id ?? null],
  queryFn: () => api.ubicaciones.listar({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
  enabled: empresa !== null && sucursal !== null,
});
```

Y hay un estado más que contemplar, que no existe con la empresa: **la empresa
puede no tener ninguna sucursal activa**. Ahí `sucursal` queda en null para
siempre, así que hay que distinguirlo de "todavía cargando" o el usuario ve una
tabla vacía que parece un depósito sin ubicaciones:

```tsx
const sinSucursal = !cargandoSucursal && sucursal === null;
// → "La empresa no tiene sucursales activas. Cargá una antes de…"
```

> **Cambiar de empresa invalida la sucursal.** Una sucursal pertenece a una sola
> empresa: el provider guarda el `idEmpresa` junto a la sucursal y la descarta si
> no coincide con la empresa activa, o si fue borrada o inactivada. También se
> limpia en el logout y ante un 401, igual que la empresa.

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

### Regla: cada tabla del backend lleva su página

**Si hay un `db/<tabla>.sql`, hay un `src/routes/_auth.<tabla>.tsx` y una entrada
de menú.** Sin excepciones, y sin preguntar: el flujo del proyecto es backend
primero y frontend después, así que cada paquete PL/SQL nuevo termina en una
página propia con su listado, su alta y su baja.

Esto vale **también para las tablas de detalle y las de cruce**. `DETALLE_MONEDAS`
y `ARTICULOS_UBICACIONES` cuelgan de otra tabla, y aun así cada una tiene su
página: se cargan y se revisan de corrido, y una pantalla propia es lo que
permite hacerlo sin entrar por la cabecera de a una fila.

> **No conviertas una tabla en un diálogo anidado dentro de otra pantalla.** Es
> tentador razonar que "el detalle sólo tiene sentido dentro de su cabecera", y es
> el error que ya costó dos vueltas acá: la tabla quedó sin ruta, sin entrada de
> menú y sin forma de darla de alta, mientras el backend estaba listo. El acceso
> desde la cabecera es un **agregado** —un botón en la fila, cómodo para el caso
> "¿dónde está este artículo?"— nunca el único camino.
>
> Las dos cosas conviven bien: `ARTICULOS_UBICACIONES` tiene la página
> `/articulos-ubicaciones` **y** el botón de ubicación en cada fila de Artículos.
> Comparten el mismo endpoint, que acepta `?idArticulo=` y `?idUbicacion=`.

Para una tabla de cruce, el ABM es **asignar y quitar**, sin edición: la fila no
tiene datos propios, así que cambiar cualquiera de los dos ids es otra
asignación. El alta son dos combobox (uno por cada lado del cruce) y conviene
ofrecer sólo los pares libres — el `UNIQUE` devuelve 409 si se repite uno.

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
   del desplegable**. Las opciones **se derivan del router** ([rutas-app.ts](../src/lib/rutas-app.ts)),
   así que crear `src/routes/_auth.<algo>.tsx` alcanza para que la ruta aparezca
   sola: no hay lista que mantener.
2. **Permisos** — elegí el usuario y tildá la página, **con la empresa**: un
   permiso con `ID_EMPRESA` en null no se ve en ningún menú.

> Antes las opciones salían de un array escrito a mano en `PaginasDialog.tsx` y
> se desincronizaba con cada página nueva: la ruta existía como archivo pero no
> aparecía en el desplegable, así que la página quedaba registrada sin ruta
> válida y su ítem de menú no navegaba a ningún lado. Se reemplazó por la
> derivación del `routeTree`, que el build regenera solo.
>
> Sigue siendo un desplegable y no texto libre: la ruta la carga una persona, y
> un typo (`/ubicacion` por `/ubicaciones`) daba un ítem muerto sin ningún aviso.

### La ruta en la base tiene que existir en el router

Este es el error más caro de diagnosticar del proyecto. Si `PAGINAS.RUTA` dice
`/base/paises` pero el archivo es `_auth.paises.tsx` (que sirve `/paises`), el
menú muestra el item pero el clic no lleva a ningún lado.

**Convención:** el nombre de la página en la base coincide con el archivo.

| Archivo              | Nombre en `PAGINAS` | `PAGINAS.RUTA` |
| -------------------- | ------------------- | -------------- |
| `_auth.empresas.tsx` | Empresas            | `/empresas`    |
| `_auth.paises.tsx`   | Paises              | `/paises`      |

### La misma ruta puede repetirse — en otro módulo

`PAGINAS` tiene `UNIQUE (ID_MODULO, RUTA, ENTRADA)`: lo que no se puede es
cargar la misma ruta **dos veces en el mismo módulo y la misma sección**. En
otro módulo sí, y es deliberado — "Artículos" bajo _Stock_ y también bajo
_Compras_ son dos entradas de menú al mismo destino, para dos perfiles que lo
buscan en lugares distintos.

Por eso el alta **avisa en vez de bloquear**. El desplegable muestra dónde está
ya cargada cada ruta:

```
Ventas          /ventas · Ya está en Operaciones › Ventas
Cobros          /cobros
```

**Se muestran, no se esconden.** Si la opción desaparece de la lista, el usuario
no entiende por qué falta y termina cargándola con otro nombre o dudando de si
existe; diciendo _dónde_ está, decide él. Y como repetir en otro módulo es
válido, sacarla sería directamente incorrecto.

Cuando la combinación exacta ya existe —mismo módulo, misma ruta, misma
sección— aparece un aviso rojo mientras se completa el formulario, no al
guardar: descubrirlo recién al confirmar obliga a rehacer nombre, orden y
estado. El backend igual lo rechaza con 409, por si alguien llama al endpoint
directo.

> El backend **normaliza la ruta** antes de guardarla (minúsculas, barra inicial,
> sin barra final). Sin eso el `UNIQUE` no serviría: para Oracle `/Ventas`,
> `ventas` y `/ventas/` son tres valores distintos. Ver
> [3.8 en la guía de backend](GUIA-IMPLEMENTACION.md#38-un-unique-sobre-texto-necesita-el-texto-normalizado).

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

#### Qué columna lleva filtro

> **Regla: toda tabla lleva al menos un filtro.** Las 17 pantallas con tabla del
> proyecto lo tienen, y que una no lo tenga obliga a recordar cuál sí y cuál no.

La que filtra es **la columna con valores repetidos** — la que agrupa filas:

| Tipo de columna     | Ejemplos                                             |
| ------------------- | ---------------------------------------------------- |
| Estado `'A'`/`'I'`  | Países, monedas, categorías, unidades de medida      |
| La entidad padre    | Ciudades → departamento, artículos → categoría       |
| Una clasificación   | Personas → tipo, inventarios → estado                |
| Agrupador físico    | Ubicaciones → zona, artículos-ubicaciones → sucursal |
| "En uso / sin usar" | IVA y condiciones de pago                            |

Ese último merece explicación: en tablas donde **borrar depende de si algo la
usa**, filtrar por "sin usar" responde _"cuáles puedo borrar"_ de un click, en vez
de abrir una por una. El backend devuelve `usos` en el listado justamente para
eso.

Las columnas que **no** llevan filtro son las de valores únicos —un nombre, un
número de factura, un importe—: ahí filtrar es lo mismo que buscar, y para eso
está el campo de búsqueda.

#### De dónde salen las opciones

Hay dos formas, y elegir mal deja opciones que nunca devuelven nada:

**Del listado que se está mostrando**, cuando el catálogo padre es mucho más
grande que lo que aparece:

```tsx
// El padrón puede tener cientos de personas y sólo unas pocas facturaron en
// esta sucursal. Ofrecer las demás daría opciones que devuelven cero filas.
const proveedoresOpciones = Array.from(
  new Map(items.map((f) => [String(f.idProveedor), f.proveedor])).entries(),
)
  .map(([valor, etiqueta]) => ({ valor, etiqueta }))
  // Alfabético: el orden del listado —por fecha— no significa nada acá.
  .sort((a, b) => a.etiqueta.localeCompare(b.etiqueta, "es"));
```

**De su propia query**, cuando el catálogo es chico y conviene ver todas las
opciones aunque alguna no tenga filas todavía — es lo que hace Artículos con las
categorías, reusando la misma `queryKey` que la página de Categorías.

#### Los nulos necesitan su propia opción

Si la columna es nullable, las filas sin valor **no aparecen en ninguna opción** y
no hay forma de aislarlas. Agregá una entrada explícita:

```tsx
const SIN_CONDICION = "__sin_condicion__";

// "Sin condición" sólo si hay alguna: una opción que no filtra nada es ruido.
const hayFacturasSinCondicion = items.some((f) => f.idCondicion === null);

opciones={
  hayFacturasSinCondicion
    ? [...condicionesOpciones, { valor: SIN_CONDICION, etiqueta: "Sin condición" }]
    : condicionesOpciones
}
```

Encontrar las facturas sin plazo cargado **para completarlas** es un caso real, y
sin esa entrada no habría cómo.

#### El paginado se resetea con los filtros

Seguir en "80 de 90" después de filtrar a 12 resultados mostraría todo de golpe.
Con más de un filtro, la clave los concatena:

```tsx
const claveVista = `${filtroProveedor}|${filtroCondicion}|${termino}`;
const [claveAnterior, setClaveAnterior] = useState(claveVista);
if (claveVista !== claveAnterior) {
  setClaveAnterior(claveVista);
  setVisibles(POR_PAGINA);
}
```

Ajuste **en render, no en `useEffect`**: React re-renderiza antes de pintar, así
que no hay parpadeo.

Y el estado vacío tiene que mirar **todos** los filtros, no sólo la búsqueda:

```tsx
const hayFiltro =
  termino !== "" || filtroProveedor !== SIN_FILTRO || filtroCondicion !== SIN_FILTRO;

{
  hayFiltro ? "Ninguna factura coincide con los filtros." : "Todavía no hay facturas.";
}
```

### Cuando lo que falta importa tanto como lo que hay

Un ABM lista lo que existe. Hay pantallas donde el dato que se busca es **lo que
todavía no existe**: qué clases no tienen su reporte, qué días nadie cargó. En
esos casos lo pendiente va **en la misma lista y en su lugar cronológico**, no
en una segunda pestaña.

`/reportes-actividades` es una línea de tiempo por mes donde cada día muestra sus
reportes y, debajo, las marcaciones sin reporte como tarjeta de borde punteado
con el botón para escribirlo. En una pestaña aparte el hueco hay que acordarse de
ir a mirarlo; en el hilo se ve donde está.

Lo que hay que resolver para que funcione:

- **Las dos listas se traen enteras y se ordenan una sola vez.** Con paginado
  incremental de a dos fuentes, un día aparecería, desaparecería y volvería según
  cuánto se haya cargado de cada una. Un mes tiene volumen acotado: se pagina
  hasta el final (ver la sección siguiente) y recién ahí se agrupa.
- **El buscador no aplica igual a las dos.** Los reportes se filtran por texto en
  el SQL; lo pendiente no tiene texto que buscar, así que se filtra en memoria
  por profesor e institución. Sin eso, escribir en el buscador dejaría la línea
  de tiempo a medias sin explicación.
- **El encabezado cuenta las dos cosas**, y lo pendiente se pinta distinto
  (`variant="destructive"` sólo si hay): es el número que dice cuánto trabajo
  queda.

### El listado recorta el texto largo; la ficha lo trae entero

Cuando una columna de texto libre no entra en la respuesta —el techo del bind de
ORDS— el backend la manda **recortada** en el listado y completa en `/obtener`.
Eso deja una trampa lista para el próximo que edite la pantalla:

> **El formulario de edición carga con `obtener()`, nunca con la fila del
> listado.** Si toma la fila, guarda el resumen de 200 caracteres encima de los
> 2000 que había, y el texto original no vuelve.

Ya pasó con `INVENTARIOS.OBSERVACIONES` y se repite en
`REPORTES_ACTIVIDADES.DESCRIPCION`. La fila del listado sirve para mostrar; para
editar hay que pedir la ficha. Si el backend manda un `truncada: 'S'`, usalo para
poner el "seguir leyendo" en vez de calcular el largo a ojo.

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

### Una consulta que se exporta trae TODO, paginando de a 50

"Mostrar más" sirve para un ABM, pero **no para una pantalla que se exporta**. Si
la tabla muestra 20 filas y el Excel sale con 600 —o al revés—, nadie sabe cuál
de los dos números creer.

`/existencias` trae el catálogo entero y **lo que se exporta es exactamente lo
que se ve**, con los mismos filtros aplicados:

```tsx
/**
 * Cuántos artículos se piden por vuelta. NO es el techo del endpoint (200), y
 * bajarlo es deliberado — ver abajo.
 */
const POR_PAGINA = 50;
const MAX_PAGINAS = 50; // Corte de seguridad: 2.500 artículos

async function traerCatalogo(idEmpresa: number): Promise<Articulo[]> {
  const todos: Articulo[] = [];
  for (let pagina = 1; pagina <= MAX_PAGINAS; pagina++) {
    const respuesta = await api.articulos.listar({ idEmpresa, pagina, tamanio: POR_PAGINA });
    todos.push(...respuesta.items);
    // Dos cortes: el total del backend y una página incompleta. El segundo cubre
    // el caso de que `total` venga mal — sin él, una página vacía repetida daría
    // vueltas hasta MAX_PAGINAS.
    if (todos.length >= respuesta.total || respuesta.items.length < POR_PAGINA) break;
  }
  return todos;
}
```

> **No pidas `tamanio=200` aunque el backend lo acepte.** ORDS devuelve el JSON
> por un parámetro tipado como `STRING`, con techo de **4000 bytes**. Una página
> de 200 artículos con descripciones largas lo pasa y la petición muere con un
> **500 sin diagnóstico** — el PL/SQL terminó bien, falla el bind al devolver.

Ese 500 costó varias vueltas de encontrar: se le echó la culpa al `WHERE`, a una
subconsulta y al largo de `DESCRIPCION` antes de dar con el bind. El detalle
completo está en
[GUIA-IMPLEMENTACION.md](GUIA-IMPLEMENTACION.md#y-si-paginás-y-igual-da-500-es-el-bind-de-ords).

**La regla:** 50 por vuelta. Si una respuesta con textos largos igual falla,
bajá a 25 antes de buscar el problema en otro lado. El costo de una petición más
cada 50 filas es imperceptible; el de un reporte que no abre, no.

### Un filtro ofrece lo que tiene datos, no el catálogo entero

En una consulta por período, poblar los combos con `/instituciones/listar` y
`/profesores/listar` ofrece **decenas de opciones que en ese mes no tienen
ninguna marcación**. Elegir una devuelve una pantalla vacía, y no hay forma de
saber cuáles sí tienen sin probarlas de a una.

`asistencias` las deriva de una consulta del período **sin filtrar**:

```tsx
// De acá salen los dos combos. No se puede reusar la consulta principal: esa ya
// viene filtrada, así que al elegir una institución el combo quedaría con esa
// sola opción y no habría cómo volver a otra.
const delPeriodo = useQuery({
  queryKey: ["asistencias", empresa?.id ?? null, anio, mes, "periodo-completo"],
  queryFn: () => api.asistenciasProfesores.listar({ idEmpresa: empresa!.id, anio, mes }),
  enabled: empresa !== null,
});
```

Y **los filtros se encadenan**: elegida una institución, el combo de profesor
ofrece sólo a quienes dieron clase ahí.

Dos cosas que hay que resolver al hacerlo:

- **Un filtro elegido puede dejar de existir.** Al cambiar de mes —o de
  institución— lo que estaba seleccionado puede no tener marcaciones en el nuevo
  recorte: queda filtrando por algo que ya no está en la lista y la pantalla se
  ve vacía sin decir por qué. Se vuelve a "Todos" en cuanto deja de ser una
  opción, corrigiendo el estado durante el render (no hace falta un `useEffect`:
  es estado derivado, no un efecto sobre datos externos).
- **La guarda `!isPending` no es opcional.** Mientras la consulta del período
  está en vuelo la lista está vacía, y sin ella el filtro **se resetearía solo
  en cada cambio de mes**, justo antes de que lleguen los datos.

Los estados de carga y error siguen colgando de la consulta principal, no de
esta: los combos no deben bloquear la pantalla.

#### Cuando el filtro es el período, va un endpoint agregado

Derivar las opciones del listado sirve mientras el recorte ya esté acotado. Con
**el año y el mes** no alcanza: para saber qué meses tienen datos habría que
pedir el año entero —miles de marcaciones bajando al navegador para calcular
doce números—, y es justo el volumen que hace saltar el techo de bytes de ORDS.

`/asistencias-profesores/periodos` devuelve **una fila por mes con datos**
(`{anio, mes, cantidad}`). Es el mismo criterio que `/dashboard/resumen`: si el
listado está paginado o es grande, el agregado se calcula en la base.

```tsx
// Una sola vez por empresa: la respuesta ya trae todos los años, así que
// cambiar de año no dispara otra consulta.
const periodos = useQuery({
  queryKey: ["asistencias", "periodos", empresa?.id ?? null],
  queryFn: () => api.asistenciasProfesores.periodos(empresa!.id),
  enabled: empresa !== null,
});
```

Dos detalles que cuestan un rato si se pasan por alto:

- **La queryKey tiene que compartir prefijo con el listado.** `["asistencias",
"periodos", id]` y no `["asistencias-periodos", id]`: TanStack compara las
  keys **elemento por elemento**, no como texto, así que con la segunda forma el
  `invalidateQueries(["asistencias"])` del alta no la alcanza y la primera
  marcación de un mes nuevo no aparece en el combo hasta recargar la página.
- **Si el combo sólo ofrece lo que existe, el estado inicial puede no existir.**
  La pantalla arranca en el mes de hoy, que puede no tener nada cargado: hay que
  caer al período más reciente con datos, con la misma corrección durante el
  render de arriba. Y tenerlo presente: un mes vacío deja de ser alcanzable, así
  que no se puede navegar hasta él para cargarle la primera marcación.

#### Y si el listado tampoco se puede traer entero, van los pares

Derivar los combos de una consulta sin filtrar supone que esa consulta se puede
traer completa. En `/reportes-actividades` no: cada fila lleva texto libre, así
que el listado pagina de a 20 y traerlo entero sólo para poblar dos combos es
justamente lo que el paginado vino a evitar.

`/reportes-actividades/vinculos` devuelve **los pares (profesor, institución) con
marcaciones en el período**, sin repetir: dos números por par, decenas de filas.
Elegido un profesor, el combo de institución se queda con las suyas.

```tsx
// No depende de los filtros, sólo del período: si dependiera del profesor
// elegido, el combo quedaría con la única opción ya seleccionada.
const vinculos = useQuery({
  queryKey: ["reportes-actividades", "vinculos", empresa?.id ?? null, desde, hasta],
  queryFn: () => api.reportesActividades.vinculos({ idEmpresa: empresa!.id, desde, hasta }),
  enabled: empresa !== null,
});
```

Dos cosas que no cambian respecto de lo anterior:

- **Se limpia lo que dejó de ser opción.** Acá la corrección va en el handler del
  combo que manda (`elegirProfesor`) y no durante el render, porque el cambio
  tiene un disparador concreto: si el profesor nuevo no estuvo en la institución
  elegida, la institución vuelve a "Todas".
- **Se dice por qué la lista es corta.** Un cartel bajo el combo —"Sólo donde
  marcó este mes (3)"— evita que un colegio ausente parezca un dato perdido. Sin
  eso, la única lectura posible es que el sistema se comió algo.

Y una que sí: **la relación no sale de ninguna tabla**. `PROFESORES` no tiene
institución y no hay cruce entre ambas; el vínculo lo escribe el historial de
marcaciones. Vale la pena tenerlo presente antes de buscar la FK que no existe.

### La empresa va en la queryKey de todo catálogo

`["categorias", empresa?.id]`, `["marcas", empresa?.id]`. **Todos** los
catálogos del proyecto cuelgan de la empresa, así que la clave lo tiene que
reflejar: sin ella, cambiar de empresa activa serviría la lista de la anterior
desde la caché, y nadie relaciona ese síntoma con una queryKey.

```tsx
const { empresa } = useEmpresa();

const { data: marcas } = useQuery({
  queryKey: ["marcas", empresa?.id ?? null],
  queryFn: () => api.marcas.listar({ idEmpresa: empresa!.id }),
  // El provider hidrata después de montar: sin esto sale un pedido con
  // `undefined` como empresa.
  enabled: empresa !== null,
});
```

**Usá la MISMA clave en todas las pantallas** que consultan ese catálogo: la de
Artículos, la de Existencias y su propio ABM comparten `["marcas", id]` y por lo
tanto la respuesta. Por eso mismo, un alta desde cualquiera de ellas invalida la
de todas.

> `MARCAS` fue por un tiempo un catálogo global, sin empresa. Si ves un
> `queryKey: ["marcas"]` pelado en un ejemplo viejo, está desactualizado.

**`npm run lint` lo verifica** (chequeo 4 de `verificar-convenciones`): si el
`queryFn` nombra la empresa y la `queryKey` no, falla. Es el mismo síntoma que
una consulta mal filtrada —ver datos de otra empresa— pero sin ninguna petición
mal hecha: la petición nunca salió, se sirvió la caché.

Dos cosas que se rompen al agregar la empresa a una clave que ya existía:

- **La invalidación deja de matchear.** TanStack compara las claves **elemento
  por elemento**: `["detalle-monedas", idMoneda]` no alcanza a
  `["detalle-monedas", idEmpresa, idMoneda]`, y el alta deja de refrescar la
  lista. Invalidá por el **prefijo solo** —`["detalle-monedas"]`— salvo que
  tengas una razón concreta para acotar.
- **El relleno `?? 0` es una trampa.** Si la empresa todavía no hidrató, un cero
  es *falsy*: un armador de query string escrito como
  `if (params.idEmpresa) q.set(...)` lo descarta y la petición sale sin empresa.
  Con el backend exigiéndola ahora da 400, pero el hábito correcto es `?? null`
  en la clave y un `enabled` que no deje correr la consulta.

**Ojo con las tablas de cruce**, que son las que más fácil se escapan: no tienen
`ID_EMPRESA` propia, así que ni la consulta se acota sola ni el tipo te avisa.
`/articulos-ubicaciones` mostraba el cruce de **todas** las empresas por esto.

### El logo de la empresa en un PDF

`abrirPdf` acepta `urlLogo` y lo dibuja arriba a la derecha. Va **sólo si la
empresa tiene uno cargado**, para no pedir una imagen que ya se sabe que da 404:

```tsx
...(empresa?.tieneLogo ? { urlLogo: urlLogoEmpresa(empresa.id) } : {}),
```

Tres cosas que no son obvias:

**jsPDF no acepta una URL.** Necesita los bytes, así que hay que bajar la imagen
con `fetch` y pasarla a data URL con `FileReader`. Y además hace falta medirla
con un `Image`: el PDF no sabe cuánto mide un PNG, y sin las dimensiones reales
no se puede escalar sin deformarlo. Se escala **por el lado más largo**, así un
logo apaisado toca el ancho máximo y uno cuadrado el alto.

**El helper nunca lanza.** Los tres motivos por los que puede fallar —la empresa
no tiene logo, el endpoint no está publicado todavía, la red— terminan en
`null`, y el PDF sale sin él. Un reporte sin logo sigue siendo válido; uno que no
se genera porque una imagen dio 404 no le sirve a nadie.

**La tabla arranca debajo de lo más bajo del encabezado**, no debajo del texto:

```ts
startY: Math.max(62 + subtitulos.length * 12, finLogo) + 10,
```

El bloque de título y subtítulos crece según cuántos filtros haya. Con pocos, el
logo es lo más alto de la página y la primera fila se le monta encima. `finLogo`
vale 0 cuando no hay logo, así que la fórmula vieja sigue valiendo.

> **El logo no reemplaza al nombre de la empresa**, que sigue en los subtítulos.
> Un reporte se fotocopia en blanco y negro y se archiva: ahí un logo recortado
> puede no decir de quién es.

El logo va anclado a la **derecha** justamente porque el encabezado izquierdo
tiene alto variable. Sobre el título habría que recalcular la posición del texto
según haya logo o no.

### Agrupar filas de un reporte: `rowSpan` en las tres salidas

La planilla de asistencias tiene una columna **Sem.** que abarca los días de su
semana con una sola celda. La regla de corte se calcula **una vez** y viaja como
dato (`FilaPlanilla.semana`), en vez de que cada salida la reimplemente:

```tsx
// Un solo helper alimenta la grilla y las dos exportaciones.
function agruparPorSemana(dias) {
  let semana = 1;
  const conSemana = dias.map((d, i) => {
    if (i > 0 && d.diaSemana === 1) semana += 1; // cada lunes abre una semana
    return { ...d, semana };
  });
  // …además devuelve `abreSemana` y `diasDeLaSemana`, que es el rowSpan.
}
```

**Las celdas tapadas por el span se manejan al revés en cada formato**, y es
fácil equivocarse:

| Salida                    | Filas cubiertas por el span              |
| ------------------------- | ---------------------------------------- |
| HTML / `write-excel-file` | Van como `null` — si no, se corren       |
| PDF (`jspdf-autotable`)   | **No** llevan celda: autoTable las corre |

Dos detalles que sólo se ven al mirar el resultado:

- **La celda agrupada necesita fondo propio.** Si la fila que abre el grupo es
  fin de semana —pasa en la primera semana del mes— hereda ese gris y la columna
  queda de dos colores. En pantalla se resuelve con `bg-card`; en el PDF,
  excluyendo la columna 0 del `didParseCell`.
- **Una columna nueva desalinea el resto del Excel.** Hay que mover los anchos
  de columna, los `null` de la segunda fila de cabecera y el `columnSpan` del
  bloque de totales, o el importe cae una celda antes.

**Todas las filas tienen que medir lo mismo, y el compilador no lo verifica.**
Un `columnSpan` mal contado no rompe nada: genera un `.xlsx` válido con las
columnas corridas, y sólo se ve abriendo el archivo. Agregar dos columnas a la
planilla dejó el encabezado una celda corto y el bloque de totales a la mitad —
los dos "funcionaban".

Vale la pena verificarlo con un script suelto antes de abrir Excel: sumar a mano
las celdas que produce cada tipo de fila (encabezado, cabeceras, día, resumen)
para varios anchos de grilla, y comparar contra `anchoTotal`.

```js
// n = pares Ent./Sal. Si alguna fila no da anchoTotal, las columnas se corren.
for (const n of [2, 3, 4, 6]) {
  const anchoTotal = 3 + n * 2 + 3;
  const dia = 1 + 2 + n * 2 + 3; // semana + día/fecha + pares + tres totales
  console.log(n, dia === anchoTotal ? "OK" : "DESCUADRE");
}
```

Un helper `completar()` que rellene con `null` hasta `anchoTotal` cubre las filas
cortas, pero **no** las que se pasan ni las que ponen el valor en la columna
equivocada — para eso hay que contar.

### Líneas divisorias: un selector, no una clase por celda

```tsx
const COLUMNAS_DIVIDIDAS = "[&_th:not(:last-child)]:border-r [&_td:not(:last-child)]:border-r";
```

Se aplica al `<Table>` y alcanza a todas las celdas. Repetir `border-r` en cada
`<TableHead>` y `<TableCell>` son treinta lugares donde ponerlo y uno donde
olvidarse.

- `:not(:last-child)` evita la línea pegada al filo de la tarjeta.
- El color sale del reset global de `styles.css`, que da `--color-border` a todo:
  `border-r` solo alcanza y sigue al tema claro y oscuro.

**`:last-child` mira las celdas que la FILA declara, no la columna visual.** Con
`rowSpan`, las filas intermedias no declaran las celdas estiradas desde arriba,
así que la "última" pasa a ser otra y el selector se la saltea — dejando sin
separador justo la columna que se sigue con el dedo. Esas celdas llevan
`border-r` explícito.

El otro efecto del mismo selector: **`TableBody` de shadcn trae
`[&_tr:last-child]:border-0`**, que le quita el borde inferior a la última fila
porque normalmente coincide con el de `surface-card`. Cuando la tabla vive en un
contenedor con `overflow-x-auto`, sólo coinciden **si no hay barra de scroll** —
con barra, ésta ocupa lugar y los separa. Resultado: la última fila se ve "sin
cerrar" exactamente cuando la tabla es angosta. Se le devuelve con un helper al
lado de `COLUMNAS_DIVIDIDAS`:

```tsx
const CIERRA_ULTIMA_FILA = "[&_tbody_tr:last-child]:border-b";
```

No se toca `ui/table.tsx`: el resto de las pantallas depende de ese
comportamiento para no mostrar la línea doble.

### Un documento que se firma sale uno por persona, no uno mezclado

La planilla de asistencias se imprime y **se firma**: su encabezado dice
"Profesor/a: …", así que un solo documento con las marcas de varios sería un
papel que nadie puede firmar.

La primera versión resolvió eso **bloqueando** la exportación mientras el filtro
de profesor estuviera en "Todos". Funcionaba, pero dejaba afuera el caso real:
liquidar **una institución completa**, donde justamente participan varios.

Hoy `asistencias` arma **una planilla por profesor** y las manda todas juntas.

> **Y la pantalla también.** Durante un tiempo sólo el archivo salía separado: la
> vista mostraba una grilla con las marcas de todos mezcladas, y la diferencia
> hubo que explicarla con un cartel ("al exportar sale una planilla para cada
> uno"). Un cartel que avisa que lo que ves no es lo que bajás es la señal de que
> falta arreglar algo, no de que falte explicarlo mejor.
>
> Peor todavía, la grilla mezclada era **ambigua**: un día con dos entradas puede
> ser alguien que entró y salió dos veces, o dos personas distintas. Sobre un
> papel que se firma eso no se puede sostener.

**La agrupación se hace UNA vez y la usan las dos salidas.** Es lo que garantiza
que no vuelvan a divergir:

```tsx
// Una sola fuente: la pantalla renderiza un <Planilla> por cada elemento, y
// `planillas` (lo que va al Excel) se deriva de esta misma lista.
const grillasPorProfesor = useMemo(() => {
  const porProfesor = new Map<number, AsistenciaProfesor[]>();
  for (const a of items) {
    /* agrupar por a.idProfesor */
  }
  return [...porProfesor.entries()]
    .map(([idProfesor, marcas]) => ({
      idProfesor,
      marcas,
      porDia: /* … las marcas de ESTE profesor, por fecha */,
      // POR PROFESOR y no el máximo global: si otro tuvo cuatro marcas en un
      // día, no tiene por qué agregar dos columnas vacías a esta grilla.
      maxMarcas: /* … */,
      // Cada uno con SU hora cátedra y SU precio: ver abajo.
      catedra: catedraDe(idProfesor),
      precio: precioDe(idProfesor),
    }))
    .sort((a, b) => a.profesor.localeCompare(b.profesor, "es"));
}, [items, catedraPorProfesor, precioPorProfesor]);
```

### Un parámetro de cálculo que no es igual para todos va por fila, no arriba

La hora cátedra y el precio por hora empezaron como **dos campos globales** en la
barra de filtros. Era lo simple, y estaba mal: no todos los profesores dan
cátedras de la misma duración —45 minutos en un colegio, 60 en otro— ni cobran lo
mismo. Con un solo valor, el total de horas de alguno salía mal **sin que nada lo
avisara**: la planilla se veía completa y correcta.

Hoy cada planilla los trae en su encabezado, con un mapa por id y un valor de
arranque:

```tsx
const [catedraPorProfesor, setCatedraPorProfesor] = useState<Record<number, string>>({});

const catedraDe = (idProfesor: number) =>
  Number(catedraPorProfesor[idProfesor] ?? CATEDRA_POR_DEFECTO) || 60;
```

**Al hacer un cambio así hay que perseguir TODOS los consumidores**, no sólo el
que motivó el cambio. Acá eran cinco: los KPI del período —que ahora acumulan por
profesor y recién después totalizan—, la columna Importe del Detalle, el modal
del día (que puede tener marcas de varias personas), el consolidado del pie y el
Excel. TypeScript ayuda a encontrarlos: al borrar las variables globales, el
compilador marca uno por uno.

> No se guardan en la base: `PROFESORES` no tiene columna para esto y agregarla
> es un cambio de DDL. Se pierden al recargar, como los globales que reemplazaron.

Tres cosas que hay que respetar al hacer esto:

- **Los totales se recalculan por persona.** Los de la pantalla son del período
  entero; reusarlos pondría el total de todos en la planilla de cada uno.
- **`columnasMarca` también es por persona.** Es el máximo de marcas en un día
  **de ese profesor**: usar el máximo global le agrega columnas vacías a quien
  marcó menos veces.
- **Un archivo, no N descargas.** En PDF cada profesor abre en su propia página
  (`doc.addPage()`); en Excel, en su propia hoja. Disparar una descarga por
  profesor hace que el navegador frene todas menos la primera.

> **Los nombres de hoja de Excel tienen reglas propias.** No admiten `: \ / ? * [ ]`,
> se cortan en 31 caracteres y **no puede haber dos iguales** — con dos
> homónimos, o con dos nombres largos que al truncarse coinciden, el `.xlsx` sale
> corrupto. `nombreHoja()` en [exportar.ts](../src/lib/exportar.ts) limpia,
> trunca y desduplica con un sufijo.

Y el aviso de la pantalla cambió de sentido: antes explicaba por qué el botón
estaba gris, ahora avisa que **lo que se ve y lo que se baja no coinciden** — la
grilla en pantalla muestra el período mezclado, el archivo sale separado por
persona.

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

### Un reporte también se corrige: acciones desde la grilla

La planilla de asistencias es la vista con la que se liquida, y es donde se ve
el problema —un día en blanco, una entrada sin salida—. Antes había que cambiar
a la vista Detalle y buscar esa fila entre las del mes entero.

Tocar un día abre un modal con **las marcaciones de ese día** y sus acciones:

- Es una **lista, no un formulario**: un día puede tener varias entradas y
  salidas, y cuál corregir lo elige la persona.
- **No duplica el formulario.** Delega en el mismo diálogo de carga y en la
  misma confirmación de baja que usa la otra vista; dos formularios serían dos
  validaciones que mantener sincronizadas.
- **El modal del día queda abierto detrás.** El de edición se abre encima, y al
  cerrarse se vuelve a ver el día actualizado — la lista se lee de `porDia` en
  cada render, así que la invalidación de la mutación la refresca sola.
- **La fila entera es clickeable, y además hay un `<button>` real** en la celda
  del día: una fila con `onClick` es cómoda con el mouse pero no la alcanza
  nadie con teclado ni la anuncia un lector de pantalla. El botón hace
  `stopPropagation` para que el click no cuente dos veces.

Si el alta hereda la fecha del filtro, conviene guardarla en su propio estado
(`fechaAlta`) en vez de leer cuál modal está abierto: son cosas distintas y el
acoplamiento se rompe apenas los diálogos se superponen.

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

### Los hijos de `ui/form` van DENTRO de un `<FormItem>`, o revientan

`FormLabel`, `FormControl`, `FormDescription` y `FormMessage` llaman a
`useFormField()`, que **lanza** si no encuentra el contexto de su campo. No es
un warning: se lleva puesta la página entera y el `CatchBoundary` del root
muestra _"This page didn't load"_ — con el formulario perfectamente escrito.

El caso real fue una nota al pie del formulario, que no pertenece a ningún campo
y por eso no tenía dónde colgarse:

```tsx
// MAL: tira abajo la página apenas se abre el diálogo
<div className="grid gap-4 sm:grid-cols-2">…</div>
<FormDescription>Dejá la salida vacía si todavía no salió.</FormDescription>

// BIEN: es una nota del formulario, no de un campo
<p className="text-[0.8rem] text-muted-foreground">
  Dejá la salida vacía si todavía no salió.
</p>
```

Esas son exactamente las clases que aplica `FormDescription`, así que se ve
igual.

Un `<Field>` propio que renderice el `<FormItem>` **sí** vale como contenedor
aunque el JSX no lo muestre anidado: el contexto de React viaja por el árbol de
render, no por cómo esté escrito.

`npm run lint` lo detecta — ver `scripts/verificar-convenciones.mjs`.

### Un formulario entra en un pantallazo

> **Regla: el formulario se ve entero sin scrollear, con el botón de guardar
> visible. Si no entra en una columna, se usan dos — no se scrollea.**

Este es un sistema de gestión: quien carga artículos abre el mismo diálogo
cincuenta veces por día. Un formulario que obliga a scrollear para llegar a
"Guardar" esconde la mitad de los campos en cada carga, y no deja revisar lo
escrito antes de confirmar.

**El ancho se elige por la cantidad de campos, no por costumbre:**

| Campos  | Ancho          | Disposición                       |
| ------- | -------------- | --------------------------------- |
| hasta 4 | `sm:max-w-md`  | una columna                       |
| 5 a 8   | `sm:max-w-2xl` | dos columnas (`sm:grid-cols-2`)   |
| 9 o más | `sm:max-w-3xl` | dos o tres columnas, en secciones |

```tsx
// Once campos: a una columna el footer quedaba fuera de la pantalla.
<DialogContent className="scrollbar-fino max-h-[92vh] overflow-y-auto sm:max-w-3xl">
```

**`max-h-[92vh]` se deja igual**, como red de seguridad para pantallas muy bajas
o zoom alto. La diferencia es que deja de ser el caso normal: con el ancho
correcto no se activa en un portátil.

**Agrupá en secciones con título, no en una lista plana.** Los campos se ordenan
por significado y cada grupo lleva un `<h3>`; así el ojo salta al bloque que
busca en vez de recorrer once etiquetas:

```tsx
<section className="space-y-3">
  <h3 className="text-sm font-semibold text-foreground">Precios y stock</h3>
  <div className="grid gap-4 sm:grid-cols-3">{/* … */}</div>
</section>
```

Tres detalles que se aprendieron rehaciendo el formulario de Artículos:

- **Un campo va al lado de los que le dan sentido.** La moneda estaba suelta
  abajo, lejos de los precios que denomina, y la unidad de medida lejos de las
  cantidades. Agruparlas con sus números ahorró dos secciones.
- **Lo largo (un `<Textarea>`) va al final**, en su propia sección: en el medio
  de una grilla parte las dos columnas y deja un hueco.
- **`space-y-4`, no `space-y-6`.** Con varias secciones, el aire de más es lo
  que termina empujando el footer fuera de la pantalla.

> **Cuidado con `<fieldset disabled>` dentro de una grilla.** Para que los
> campos participen de la grilla del padre, el fieldset necesita
> `display: contents`, que varios navegadores soportan de forma irregular — y si
> falla, **el bloqueo se pierde en silencio**. Cuando el `disabled` protege algo
> que importa, poné `disabled` en cada `Input`.

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

### Elegir un valor de otra tabla: `SelectorModal`, no `Select`

**Regla: toda lista de valores —país, módulo, usuario, cualquier FK— usa
`SelectorModal`, que abre un MODAL. No hay popover pegado al campo.**

**El modal se usa siempre, aunque la lista traiga un solo ítem.** Es una decisión
de consistencia, no de tamaño: si el control cambiara de forma según cuántas
filas haya, la misma acción se vería distinta en cada pantalla y habría que
aprender dos interacciones para lo mismo. El buscador dentro del modal sí se
oculta con pocas opciones (menos de 7), porque ahí la lista entra entera.

> El `Combobox` de popover que usaba el proyecto **ya no existe**: se eliminó al
> migrar las 21 listas de valores. Si ves `<Combobox>` en un ejemplo viejo, es
> `<SelectorModal>` con la misma API.

`<Select>` sigue siendo correcto para listas **fijas y cortas que no salen de una
tabla** —"Activo/Inactivo", la `entrada` de una página (`D`/`O`/`R`)—, donde no
hay nada que buscar ni datos que cargar.

[SelectorModal.tsx](../src/components/ctell/SelectorModal.tsx) no pide datos por
su cuenta: arma `opciones` a partir de lo que ya haya cargado con `useQuery`,
igual que antes se armaban los `<SelectItem>`.

> **El texto largo ya está resuelto adentro del componente**: el disparador crece
> a dos líneas y la lista del modal envuelve el nombre entero. Si armás otro
> selector con `<Button>` por fuera de estos dos, leé
> [Texto largo](#73-texto-largo-truncate-no-alcanza-y-en-un-diálogo-molesta)
> antes — la clase base del botón impide el salto de línea y el desborde no se
> nota hasta que alguien carga un nombre de 80 caracteres.

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
        <SelectorModal
          opciones={paisesOpciones}
          value={field.value}
          onChange={field.onChange}
          placeholder="Elegí un país"
          // Título del modal. Nombrá la entidad: con el default genérico todos
          // los modales de la app dirían lo mismo.
          titulo="Elegí un país"
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

### Crear la opción que falta sin salir del formulario

El caso: se está cargando un artículo y su marca todavía no existe. Sin esto hay
que **descartar lo escrito**, ir a /marcas, crearla y empezar de nuevo — y eso
pasa justo cuando la persona está cargando datos en serie.

La prop `alta` de `SelectorModal` lo resuelve. Sin ella, el selector se comporta
como siempre:

```tsx
<SelectorModal
  opciones={marcasOpciones}
  value={field.value}
  onChange={field.onChange}
  placeholder="Sin marca"
  titulo="Elegí una marca"
  cargando={cargandoMarcas}
  alta={{
    titulo: "Nueva marca",
    etiquetaCampo: "Descripción",
    placeholder: "Sakura",
    crear: async (descripcion) => {
      const { id } = await api.marcas.crear({ descripcion });
      await queryClient.invalidateQueries({ queryKey: ["marcas"] });
      return { valor: String(id), etiqueta: descripcion };
    },
  }}
/>
```

Aparece en **tres lugares**, porque con uno solo no alcanza:

| Dónde                         | Para quién                                                    |
| ----------------------------- | ------------------------------------------------------------- |
| Un "+" pegado al selector     | El que ya sabe que no existe y no quiere abrir la lista       |
| "Crear «Sakura»" al no hallar | El que lo descubre buscando — arranca con lo que ya tipeó     |
| Un botón al pie del modal     | El que revisó la lista entera; va fuera del área que scrollea |

Al crear, **la opción queda elegida**: crearla y tener que buscarla después
sería la mitad del trabajo.

#### Lo que hay que saber para usarla

**El selector no sabe de queries.** El `crear` lo arma el llamador: pega a su
endpoint, invalida su catálogo y devuelve la opción. El id sale de la respuesta
del POST, así que la opción se arma ahí mismo — esperar a que el refetch traiga
el catálogo nuevo dejaría un hueco en el que el selector todavía no conoce el
valor que acaba de recibir.

**El campo NO es un `<form>`.** Esto vive dentro del formulario de la pantalla,
y un form anidado no es HTML válido: el submit del de adentro dispararía el de
afuera y guardaría el registro entero. Enter guarda con un `onKeyDown` y
`preventDefault`.

**Si falla, el diálogo no se cierra**: conserva lo tipeado para corregirlo. Un
409 por nombre duplicado es el caso típico, y el mensaje del backend ya dice qué
hacer.

#### Cuándo NO ponerla

**El alta rápida pide un solo campo.** Sirve para un catálogo simple, donde el
resto de los datos es opcional o tiene default:

| Catálogo                                                          | ¿Entra?                                  |
| ----------------------------------------------------------------- | ---------------------------------------- |
| Marcas, categorías, canales de pago, condiciones de pago, monedas | Sí                                       |
| Unidades de medida                                                | No: `abreviatura` también es obligatoria |
| Ubicaciones                                                       | No: exige zona, estante y nivel          |

Forzar una entidad de varios campos obligatorios acá crea **filas a medio
llenar** que después hay que ir a completar a mano, y nadie se acuerda. Esas
necesitan su propio diálogo.

**También en los filtros**, no sólo en el alta/edición. El filtro de columna
(`TableHeadFiltrable`) abre el mismo modal desde el embudo del encabezado: no
hay que hacer nada, ya lo usa por dentro. Un filtro suelto arriba de la tabla es
un `SelectorModal` común con la opción "todos" al principio:

```tsx
<SelectorModal
  opciones={[{ valor: TODOS, etiqueta: "Todos los países" }, ...paisesOpciones]}
  value={filtroPais}
  onChange={setFiltroPais}
  placeholder="Todos los países"
  titulo="Filtrar por país"
/>
```

### Si la tabla de origen está paginada: selector en modal propio

**El `SelectorModal` sólo sirve cuando el listado de origen viene entero.** Filtra en
memoria sobre las `opciones` que recibe, así que contra un endpoint paginado ve
únicamente la primera página: el registro 300 no aparece por más que se lo
escriba, y el que ya estaba guardado se muestra vacío si no cayó en esa página.

Pasó con Artículos: al paginar `/articulos/listar` de a 20, los selectores de
Lotes, Facturas de compra y Artículos-Ubicaciones quedaron viendo 20 de golpe.

**La regla:** si el endpoint pagina, el selector va en **modal propio** y busca
contra el servidor. El modelo es
[SelectorArticulo.tsx](../src/components/ctell/SelectorArticulo.tsx).

Tres cosas que ese componente resuelve y que hay que copiar:

1. **Modal independiente, no popover pegado al campo.** La lista necesita su
   espacio —buscador, filas de dos líneas, botón de paginar— y anclada al ancho
   del input queda apretada. Es además el patrón visual elegido para las listas
   de valores del proyecto.
2. **La etiqueta seleccionada se recibe por prop** (`etiquetaSeleccionada`), no
   se resuelve buscando el id en la lista cargada. Al editar, el registro
   guardado puede no estar en la primera página; sin este dato el campo se ve
   vacío como si no hubiera nada elegido. Por eso `onChange` devuelve
   **`(valor, etiqueta)`** y el formulario guarda las dos cosas.
3. **El contenido se monta sólo con el modal abierto.** Con varios selectores en
   un formulario, montarlos siempre dispara una consulta por cada uno al abrir
   la pantalla.
4. **La fila muestra TODO lo que la búsqueda mira**, y la etiqueta elegida lleva
   lo que identifica al registro. En artículos son tres líneas —nombre; código
   OEM · marca; equivalencias— porque el término tecleado puede no estar en el
   nombre, y sin ver por dónde coincidió el resultado parece un error. Por lo
   mismo `etiquetaDe()` devuelve `"Filtro de aceite · Toyota"`: dos artículos
   con el mismo nombre son piezas distintas según de quién sean, y con el
   nombre pelado el campo ya cerrado no deja saber cuál quedó.

> **Esa etiqueta es SÓLO presentación.** Ningún formulario la manda al backend
> —viaja `idArticulo` y nada más—, y por eso se le puede agregar la marca sin
> ensuciar ningún dato guardado. Una pantalla que necesite persistir el nombre
> tiene que guardarlo por su cuenta, no reusar la etiqueta.
>
> El contrapeso: la etiqueta la arma el selector **sólo al elegir**. Al reabrir
> un registro guardado, el formulario la reconstruye con lo que le devuelva su
> propio endpoint — así que ese endpoint tiene que devolver los mismos campos
> (`/inventarios/obtener` devuelve `marca` justamente por esto). Si no, el mismo
> campo se lee distinto según se acabe de elegir el artículo o se esté editando.

**El `onChange` de `SelectorArticulo` recibe un tercer argumento opcional: el
artículo entero.** Los formularios que sólo guardan el id siguen escribiendo
`(valor, etiqueta) => …` sin enterarse; el que necesita más lo pide ahí. Existe
porque `/articulos/listar` **no busca por id**, así que volver a pedir el
artículo elegido no es una opción. Llega `undefined` cuando el valor vino de un
alta rápida, que sólo conoce lo que acaba de crear.

### Completar el dato que falta en el momento en que se lo tiene

El conteo de inventario lo usa así: si el artículo elegido no tiene marca —o no
tiene categoría—, el diálogo ofrece elegirla o crearla ahí mismo (`SelectorModal`
+ `AltaRapida`) y la asigna con `api.articulos.actualizar(id, { idEmpresa, idMarca })`
o `{ idEmpresa, idCategoria }`. Son dos avisos independientes: un artículo puede
tener marca y no categoría, o al revés, y cada uno se resuelve por separado.

**El criterio, que vale para cualquier pantalla operativa:** quien cuenta tiene
la pieza en la mano y ve de quién es; el que después abra la ficha del artículo,
no. Mandarlo a `/articulos` a completarla significa perder lo que estaba
cargando, así que en la práctica no lo hace nadie y el catálogo se queda
incompleto para siempre.

Tres cosas que hay que respetar al hacerlo:

1. **Es un botón aparte, no un campo del formulario.** Modifica OTRA entidad
   —el artículo, no el conteo— y se aplica al tocarlo, sin esperar al guardado.
   Mezclarlo con los campos hace pensar que se descarta al cancelar.
2. **`type="button"`.** Dentro de un `<form>`, un botón sin `type` dispara el
   submit: guardaría el registro a medio cargar en vez de asignar el dato.
3. **No se ofrece en modo sólo lectura**, aunque técnicamente se podría: en un
   diálogo que no edita nada, un botón que sí escribe hace dudar de todo lo
   demás.

Y el aviso se cierra con **el 200 del backend**, no con haber podido resolver el
nombre de lo asignado buscándolo en el catálogo cargado: si esa búsqueda falla
—una marca recién creada cuyo refetch no llegó— el aviso quedaría en pantalla
sobre un artículo que ya tiene marca.

#### Cuando el dato es una tabla de cruce, no una columna

El conteo lo hace con tres datos —marca, categoría y **ubicación**— y el tercero
no se implementa igual, aunque en pantalla se vea idéntico:

|                   | Marca / Categoría         | Ubicación                        |
| ----------------- | ------------------------- | -------------------------------- |
| Relación          | FK en `ARTICULOS`         | **cruce N:M**                    |
| "No tiene"        | la columna en `NULL`      | **sin filas** en el cruce        |
| Se asigna con     | `articulos.actualizar`    | `articulosUbicaciones.asignar`   |
| Asignar…          | reemplaza                 | **suma**: el artículo queda en los dos estantes |
| Alcance           | la empresa                | **una sucursal**                 |

Tres consecuencias que hay que tener presentes:

1. **El dato hay que consultarlo**, no viene en el artículo. Y el aviso tiene que
   esperar a que esa consulta responda: una lista vacía y una que todavía no
   llegó se ven igual, así que sin el `isPending` el cartel parpadea sobre
   artículos que sí tienen ubicación.
2. **No hace falta el flag "ya asigné"**. El aviso sale de una consulta que se
   invalida al terminar, así que se apaga solo — es la ventaja de que el dato no
   viva en una columna del artículo.
3. **Filtrar por la sucursal es responsabilidad de la pantalla.** El catálogo de
   ubicaciones es de toda la empresa y el backend sólo rechaza el cruce entre
   empresas, no entre sucursales. Sin ese recorte se puede asignar el artículo a
   un estante de otro depósito, y un artículo ubicado sólo allá se leería como
   "ya tiene ubicación" — justo cuando lo que falta es la de acá.

```tsx
// El nombre va en estado propio: no se puede derivar del id contra una lista
// que viene paginada.
const [nombreArticulo, setNombreArticulo] = useState(lote?.nombreArticulo ?? "");

<SelectorArticulo
  idEmpresa={idEmpresa}
  value={field.value}
  etiquetaSeleccionada={nombreArticulo}
  onChange={(valor, etiqueta) => {
    field.onChange(valor);
    setNombreArticulo(etiqueta);
  }}
/>;
```

Adentro es un `useInfiniteQuery` con búsqueda debounced (350 ms) que manda
`?busqueda=` al backend y un "Mostrar más" que pide la página siguiente — la
misma forma que la pantalla de Artículos. Ver la sección de paginación en
[GUIA-IMPLEMENTACION.md](GUIA-IMPLEMENTACION.md) para el lado del PL/SQL.

> Los `SelectorModal` que quedan (país, módulo, moneda, unidad, categoría) siguen
> siendo correctos: esas tablas son catálogos acotados y su `LISTAR` no pagina.
> Si alguna crece y se pagina, ese selector hay que migrarlo también.
>
> **Los dos son modales y se ven igual** —mismo ancho, misma lista, mismo
> comportamiento—; la diferencia es de dónde salen los datos, no de forma.

#### Al paginar un listado, revisá TODOS sus consumidores

Migrar el selector no alcanza. La misma consulta suele alimentar otras cosas de
la pantalla que también asumen el listado completo, y ésas fallan en silencio —
no dan error, sólo muestran de menos:

| Uso                     | Qué le pasa al paginar                     | Cómo se arregla                                            |
| ----------------------- | ------------------------------------------ | ---------------------------------------------------------- |
| Filtro de una columna   | Ofrece 20 opciones de un catálogo de 300   | Armalo desde **las filas ya listadas**, no del catálogo    |
| "¿Hay al menos uno?"    | `items.length` mira la página, no el total | Usá `total`, y pedí `tamanio: 1` — no hacen falta 20 filas |
| Resolver un id → nombre | El id de la página 5 no está en la lista   | Que el nombre venga en el dato que ya tenés, o por prop    |

El filtro de columna en Lotes es el ejemplo: sus opciones salen de los lotes
listados y no de `/articulos/listar`. Además de esquivar la paginación es lo
correcto, porque filtrar por un artículo sin lotes vaciaría la tabla.

```tsx
// Opciones del filtro, desde las filas que ya están en pantalla.
const articulosDelListado = Array.from(
  new Map(items.map((l) => [l.idArticulo, l.nombreArticulo])).entries(),
)
  .sort((a, b) => a[1].localeCompare(b[1], "es"))
  .map(([id, nombre]) => ({ valor: String(id), etiqueta: nombre }));

// "¿La empresa tiene artículos?": sólo interesa el total, no las filas.
const { data: articulos } = useQuery({
  queryKey: ["articulos", "existen", empresa?.id ?? null],
  queryFn: () => api.articulos.listar({ idEmpresa: empresa!.id, tamanio: 1 }),
});
const sinArticulos = (articulos?.total ?? 0) === 0;
```

Buscá los consumidores con `grep -rn "api.<tabla>.listar" src/` antes de dar por
cerrada la migración: quedan queries que ya nadie usa y otras que siguen
funcionando pero con datos incompletos.

### Una fila con estados: qué se ofrece y qué se esconde

`INVENTARIOS` es la única tabla con máquina de estados, y la pantalla la refleja
sin repetir sus reglas:

| Estado    | Qué ofrece la fila                    |
| --------- | ------------------------------------- |
| `ABIERTO` | Editar · Anular · Eliminar            |
| `CERRADO` | **Ver** — nada más                    |
| `ANULADO` | **Ver** — nada más                    |

El diálogo se abre en `soloLectura`, con los campos deshabilitados y sin botón de
guardar. Y los avisos de "completá la marca / la categoría / la ubicación"
**tampoco aparecen ahí**: aunque toquen el artículo y no el conteo, un botón que
escribe dentro de un diálogo que no edita nada hace dudar de todo lo demás.

> **Esconder el botón no es la regla, es la cortesía.** El endpoint sigue siendo
> público para cualquiera con sesión, y quien lo llame igual recibe un 409 del
> paquete — y detrás, un trigger que rechaza el `UPDATE` aunque se toque la tabla
> a mano. La pantalla sólo evita ofrecer una acción que va a fallar. Ver
> [README](../README.md#máquina-de-estados-inventarios).

Corolario para cualquier tabla con estados: **las acciones se derivan del estado
de la fila**, no de un permiso ni de una bandera aparte. Si hay que mirar dos
cosas para saber si un botón va, la de más es probablemente redundante.

> **No todo lo que el estado permite va en la fila.** `ABIERTO` habilita también
> **cerrar**, y aun así no está acá: aplicar un conteo escribe `EXISTENCIAS` y no
> se deshace, así que no puede ser un ícono más al lado de editar y borrar, donde
> se toca de paso. Anular sí está, porque no mueve nada.
>
> El criterio: **el estado dice qué es posible; el peso de la acción dice dónde
> ponerla.** Una acción irreversible que toca otra tabla va en su propio flujo,
> no en la fila de un listado. El endpoint existe y está probado — lo usará la
> pantalla que se haga para eso.

### `SelectorModal` como filtro: la opción "todas" va ADENTRO

`SelectorModal` **no ofrece un "ninguna" propio**. Una vez abierto el modal sólo
se puede elegir algo de la lista, así que si el único modo de limpiar el filtro
es una ✕ al lado del campo, hay que **cerrar el modal para encontrarla** — y
mientras tanto no hay forma de deshacer lo que se acaba de elegir.

La opción de "sin filtrar" va como **la primera fila de `opciones`**:

```tsx
// No es "": el selector trata la cadena vacía como "nada elegido", así que una
// opción con ese valor no se vería tildada aunque fuera justamente la elegida.
const TODAS_UBICACIONES = "todas";

const opciones = [
  { valor: TODAS_UBICACIONES, etiqueta: "Todo el depósito" },
  ...items.map((u) => ({ valor: String(u.id), etiqueta: etiquetaUbicacion(u) })),
];

// Y al consumirlo, el centinela se traduce a "sin filtro":
const idUbicacion = filtro === TODAS_UBICACIONES ? undefined : Number(filtro);
```

Dentro de un diálogo alcanza con eso. En una barra de filtros —donde el control
convive con otros y se ve de un vistazo cuáles están puestos— conviene además la
✕ al lado, que ahorra abrir el modal para algo que ya se sabe que se quiere
descartar.

> **Un filtro que acota otro selector tiene que limpiar lo ya elegido.** Si el
> artículo seleccionado no está en el estante nuevo, dejarlo muestra un nombre
> que no figura en la lista de abajo. Lo mismo al reabrir el diálogo: el filtro
> se resetea, o el próximo alta arranca acotada a algo que nadie eligió esta vez.

### Fechas con hora: `datetime-local` necesita `step="1"`

Cuando el dato es un **momento** y no un día —la hora de un conteo físico, que
desempata dos conteos del mismo artículo— el campo va `type="datetime-local"`
**con `step="1"`**. Sin ese atributo el navegador redondea a minutos y descarta
los segundos, incluidos los que ya estaban guardados al reabrir para editar.

```tsx
<Input type="datetime-local" step="1" {...field} />
```

Y el valor se arma **a mano, en hora local**:

```tsx
// MAL: toISOString() devuelve UTC. En Paraguay adelanta hasta cuatro horas, y
// pasadas las 20:00 adelanta también el día.
new Date().toISOString().slice(0, 19);

// BIEN
const d = (n: number) => String(n).padStart(2, "0");
`${f.getFullYear()}-${d(f.getMonth() + 1)}-${d(f.getDate())}T${d(f.getHours())}:${d(f.getMinutes())}:${d(f.getSeconds())}`;
```

Para precargar desde el backend, `valor.slice(0, 19)` — el ISO ya viene sin zona
y en hora local, así que pasarlo por `Date` sólo agrega una oportunidad de
correrlo de huso.

Al mostrarlo, los segundos van **sólo donde se mira una fila sola**. En una
columna de tabla son ruido: nadie escanea una lista por el segundo en que se
contó.

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

## 6.1 Formularios con detalle: cabecera y líneas

El modelo es
[_auth.facturas-compras.tsx](../src/routes/_auth.facturas-compras.tsx). Un
formulario con detalle tiene dos partes que se guardan juntas, y eso cambia tres
cosas respecto de un ABM normal.

### Las líneas NO van en react-hook-form

Van en un `useState` con su propio tipo:

```tsx
type LineaDetalle = {
  /** Sólo para el `key` de React: no viaja al backend. */
  clave: number;
  idArticulo: string;
  cantidad: string;
  precioUnitario: string;
  idIva: string;
};

const [lineas, setLineas] = useState<LineaDetalle[]>([]);
const [proximaClave, setProximaClave] = useState(1);
```

Modelarlas como campos del formulario obligaría a un `useFieldArray` con nombres
indexados para algo que se resuelve con un array. El schema de zod cubre **sólo
la cabecera**.

> **La `clave` no es el índice del array.** Al borrar una línea del medio los
> índices se corren, y React reusaría el estado del input equivocado — el valor
> de una fila aparecería en otra.

Los importes son **strings**, igual que en Lotes y Artículos: un campo vacío no se
convierte solo en 0.

### Validar el detalle a mano

Como no está en el schema, el submit no lo valida. Se cuenta antes:

```tsx
// Las líneas incompletas se descartan en vez de mandarse: la última suele
// quedar vacía porque se agregó y no se completó, y mandarla daría un 400 por
// algo que el usuario no considera parte de la factura.
const detalle = lineas
  .filter((l) => l.idArticulo !== "" && l.cantidad !== "" && l.precioUnitario !== "")
  .map((l) => ({ idArticulo: Number(l.idArticulo), /* … */ }));

// Y el botón se deshabilita si no queda ninguna: sin esto, guardar gastaría un
// viaje a la red para recibir el 400 del backend.
const lineasValidas = lineas.filter(/* … */).length;
<Button type="submit" disabled={guardar.isPending || lineasValidas === 0}>
```

### Totales en vivo, con los mismos redondeos que el backend

Quien carga una factura tiene el papel adelante con su total impreso. **Ver si
cuadra antes de guardar es lo que evita cargarla mal**, así que el pie del
formulario calcula el total mientras se escribe.

> **Los redondeos tienen que coincidir exactamente con los del SQL.** Si el
> frontend hace `monto / divisor` y el backend `ROUND(monto / divisor, 2)`, el
> total que se ve al cargar difiere del que muestra la factura ya guardada — y
> esa diferencia de un guaraní es imposible de explicar.

### La cabecera, compacta

El detalle es la parte larga y la que se completa mirando el papel: **tiene que
quedar visible sin scrollear**. Tres cosas que ganan altura en la cabecera:

- **Grilla de 3 columnas**, no de 2. Seis campos en dos columnas son cuatro filas;
  en tres, son dos.
- **Campos relacionados comparten celda.** Moneda y tipo de cambio: el segundo
  sólo tiene sentido junto al primero y casi siempre vale 1, así que no merece una
  columna entera.
- **Sin `FormDescription` salvo donde aporte.** Cada una suma una línea de alto por
  campo; lo que dicen suele caber en el placeholder o el label.

En el detalle, **las etiquetas van una sola vez como encabezado**, no repetidas en
cada línea:

```tsx
{
  /* Se oculta en móvil, donde las líneas se apilan y cada campo sí necesita
    su etiqueta para saber qué es. */
}
<div className="hidden gap-2 px-3 sm:grid sm:grid-cols-[2fr_1fr_1.2fr_1fr_auto]">
  <span className="text-xs text-muted-foreground">Artículo</span>
  {/* … */}
</div>;
```

Con cinco artículos, repetirlas eran cinco encabezados idénticos empujando el pie
fuera de la pantalla.

### Un diálogo aparte para ver

El listado no trae el detalle (ver la guía de backend), así que hay dos diálogos:
uno de **sólo lectura** que lo pide al abrir, y el de edición. El de ver muestra
el desglose completo —gravado, impuesto, total— que es lo que se compara contra el
comprobante.

### Invalidar lo que depende

Guardar una factura invalida su propio listado **y el detalle en caché**:

```tsx
queryClient.invalidateQueries({ queryKey: ["facturas-compras"] });
// Si se editó, el diálogo de ver tiene la versión vieja.
queryClient.invalidateQueries({ queryKey: ["factura-compra"] });
```

Lo mismo al revés: editar una tasa de IVA o una condición de pago cambia el
desglose y el vencimiento de las facturas, así que **esas pantallas invalidan las
facturas** aunque no las toquen.

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

### El menú se filtra por la empresa activa

`useMenuUsuario` pide **todos** los permisos del usuario y recorta en el cliente
los que corresponden a la empresa de la sesión:

```ts
const permisos = (data?.items ?? []).filter((p) => empresa !== null && p.idEmpresa === empresa.id);
```

El recorte se hace acá y no en la consulta para no repetir el pedido cada vez
que se cambia de empresa.

La consecuencia que explica el 90% de los "me quedé sin menú": **sin permisos en
esa empresa, el menú queda vacío.** Es lo esperado, no un bug — hay que
asignarle las páginas entrando con esa empresa.

> **La PK es `(ID_EMPRESA, ID_USUARIO, ID_PAGINA)`**, así que los permisos son
> por empresa de verdad: el mismo usuario puede ver un menú en la empresa A y
> otro distinto en la B. La contrapartida es que las páginas se asignan **en
> cada empresa**, no una sola vez.
>
> Por eso `quitar` lleva las tres claves (`/quitar/:idUsuario/:idPagina/:idEmpresa`):
> sin la empresa, el borrado le sacaría el acceso en todas.

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

#### Regla: cada página nueva estrena ícono propio

**Toda página que se crea se agrega a `ICONOS_PAGINA` con un ícono que no use
ninguna otra entrada.** No es opcional ni cosmético: sin la entrada, la página
cae en el fallback `FileText` — y como el fallback lo comparten TODAS las páginas
sin mapear, dos páginas nuevas del mismo módulo salen con el mismo dibujo.

Pasó con "Ubicaciones de artículos" en Stock: nadie la había mapeado y se veía
igual que las otras páginas sin mapear del módulo.

**El fallback cuenta como una entrada tomada.** Un ícono que además es fallback
no puede usarse para nada mapeado: `Módulos` no lleva `LayoutGrid` porque ése es
el fallback de módulo, y `Páginas` lleva `Files` y no `FileText` por lo mismo.
Es el caso más difícil de ver a ojo, porque cada mapa por separado se ve bien.

**Verificalo, no lo confíes a la vista:**

```sh
npm run verificar-iconos
```

Corre también dentro de `npm run lint`. Compara módulos, páginas, entradas **y
fallbacks** entre sí, y falla nombrando el ícono repetido y quiénes lo comparten.
Los sinónimos legítimos (singular/plural, `categorías`/`rubros`) se declaran en
`SINONIMOS` dentro del script — esos SÍ deben compartir ícono: son la misma
página escrita distinto.

**Si la página pertenece a una jerarquía, un ícono por nivel.** Países /
Departamentos / Ciudades usan `Globe` / `Map` / `MapPin`: repetido, el menú no
deja distinguir un nivel de otro de un vistazo.

**Y el módulo nunca repite el ícono de una de sus páginas.** El módulo es el
encabezado que agrupa; con el mismo dibujo que una página de adentro, el grupo se
confunde con su propio contenido. Por eso Ventas es `TrendingUp` y no `Store`
(que ya es Sucursales), y Stock es `Archive` y no `Warehouse` (que ya es
Depósito).

Ejemplos del criterio para elegir: Monedas quedó con `Banknote` y no `Coins`
porque `Coins` ya era "cobros"; Categorías con `Tags` (la agrupación) y no
`Package`, que es el artículo; Facturas de compra y de venta con `FileInput` /
`FileOutput`, porque con el mismo `Receipt` sólo las distinguía el texto.

En el catálogo financiero, `Bancos` usa `Landmark` y `Cuentas bancarias` usa
`PiggyBank`: son páginas relacionadas, pero cada una conserva un ícono propio.

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

## 7.1 Imágenes: siempre con respaldo

Los binarios (logo de empresa, imagen de artículo) no vienen en el JSON: se
piden a su propio endpoint público con `urlLogoEmpresa(id)` /
`urlImagenArticulo(id)`. Ya están resueltos en dos componentes:

| Componente                                                       | Respaldo cuando no hay imagen  |
| ---------------------------------------------------------------- | ------------------------------ |
| [LogoEmpresa.tsx](../src/components/ctell/LogoEmpresa.tsx)       | Iniciales de la empresa ("CS") |
| [ImagenArticulo.tsx](../src/components/ctell/ImagenArticulo.tsx) | Un ícono de paquete            |

La diferencia es deliberada: una empresa se reconoce por sus iniciales, un
artículo no —"CE" no dice nada de "Cemento Portland"—, así que ahí un marcador
neutro comunica mejor.

**Los dos caminos al respaldo importan por igual:**

```tsx
// 1. El listado dice que no hay imagen: ni se intenta la petición.
const mostrarImagen = tieneImagen && !falloCarga;

// 2. La petición falló (404, endpoint sin publicar todavía).
<img src={urlImagenArticulo(id)} onError={() => setFalloCarga(true)} />;
```

Sin el `onError`, mientras el endpoint no esté publicado en APEX se vería el
ícono de imagen rota del navegador en cada fila.

Y `useEffect` reseteando `falloCarga` cuando cambia el `id`: sin eso, una fila
reutilizada de la tabla arrastra el fallo de la anterior.

**Al subir**, la imagen va por su propia mutación y no por el submit del
formulario —son dos peticiones distintas, y encadenarlas haría que un error al
guardar perdiera también la imagen. Validá tipo y tamaño antes de enviar, y
limpiá el `input.value` siempre:

```tsx
const archivo = event.target.files?.[0];
// Sin esto, elegir el mismo archivo dos veces seguidas no dispara el change.
event.target.value = "";
```

---

## 7.1.1 Archivos que no van a la base: subida directa

Las evidencias de `/reportes-actividades` no viajan a Oracle: el navegador las
sube **directo a Cloudinary** y la fila guarda la URL
([src/lib/cloudinary.ts](../src/lib/cloudinary.ts)). Es la excepción a todo lo
anterior, y conviene cuando los archivos son muchos, pesados o hay que mostrarlos
en varios tamaños — un video de 80 MB no tiene por qué atravesar ORDS.

**El orden importa: primero sube el archivo, después se guarda la fila.** La fila
exige la URL, que sólo existe una vez subido. Se sube de a varios, así que un
fallo no corta el lote: se avisa cuál falló y los demás siguen.

```tsx
for (const archivo of seleccionados) {
  try {
    const resultado = await subirACloudinary(archivo);
    await api.reportesMultimedia.crear({ ...resultado, idReporte, idEmpresa });
  } catch (error) {
    toast.error(`${archivo.name}: ${mensajeError(error, "no se pudo subir")}`);
  }
}
```

Cuatro cosas que no son obvias:

- **Las credenciales van por `import.meta.env`, y no son secretas.** El
  `cloud_name` y un `upload_preset` en modo _unsigned_ terminan en el bundle,
  como la URL de ORDS: están pensados para eso. Firmar la subida exigiría la
  `api_secret`, que en un frontend estático no tiene dónde vivir. Los límites de
  tamaño y formato se configuran **en el preset**, que es el único lugar donde se
  hacen cumplir: lo que valide el navegador se puede saltear.
- **Sin configuración, la pantalla ofrece otra cosa.** Un botón que falla siempre
  es peor que un campo donde pegar una URL. `subidaDirectaDisponible` decide cuál
  de los dos se muestra, así que el módulo funciona antes de que exista la cuenta.
- **El identificador del archivo lo manda la app.** Con `use_filename` y sin
  `unique_filename`, dos fotos llamadas `IMG_0001.jpg` —dos celulares— comparten
  identificador, y Cloudinary responde 200 con la URL de la primera **sin subir la
  segunda**: la evidencia de una clase termina mostrando la foto de otra, sin
  ningún error. Mandando un `public_id` propio y único, eso no depende de cómo
  quede configurado un panel que cualquiera puede tocar.
- **Las miniaturas se piden transformando la URL**, no bajando el original: una
  tira de seis fotos de 4 MB para mostrarlas de 80 píxeles es media pantalla de
  espera. De un video se pide su primer cuadro; de un PDF no hay miniatura y va
  el ícono.

### Bajar el archivo con un nombre útil

El atributo `download` de un `<a>` **se ignora cuando el archivo es de otro
origen**. Un link común, entonces, no baja nada: abre la foto en una pestaña con
el nombre ilegible que tiene en el proveedor. Se resuelve del lado de Cloudinary,
con el flag `fl_attachment:<nombre>` en la URL, que hace que responda con
`Content-Disposition: attachment` y ese nombre:

```
https://res.cloudinary.com/<cuenta>/image/upload/
  fl_attachment:2026-09-02-0730-Maria-Duarte-Colegio-San-Jose-01/v1712/...jpg
```

La otra salida —`fetch` + blob + object URL— pasa el archivo **entero por la
memoria de la pestaña**, que con un video de 80 MB es justo lo que se quería
evitar al no mandarlo por ORDS.

Sobre el nombre en sí: fuera de la app el archivo pierde todo su contexto —queda
una `IMG_0001.jpg` en Descargas—, así que carga lo que después permite
identificarlo (cuándo, quién, dónde) y termina en un número de posición, porque
cinco fotos de la misma clase comparten todo lo demás. Hay que sanearlo: la coma
y la barra **separan componentes de la transformación**, así que un nombre con
cualquiera de las dos no ensucia el archivo, rompe la URL.

Y lo que hay que decir en la interfaz: **borrar la evidencia borra la
referencia, no el archivo**. El binario queda en Cloudinary —limpiarlo exige la
credencial secreta—, así que el diálogo lo dice en lugar de dar a entender que
la foto dejó de existir.

---

## 7.2 Paneles con scroll: `scrollbar-fino`

La barra de desplazamiento nativa de Windows son 17px de gris opaco con flechas:
contra el sidebar oscuro se ve como un recorte de otra aplicación. Cualquier
contenedor con scroll propio lleva la utilidad `scrollbar-fino`, definida en
[styles.css](../src/styles.css):

```tsx
<nav className="scrollbar-fino flex-1 overflow-y-auto">
```

Son 6px, redondeada y **translúcida**: toma su color de `currentColor`, así que
la misma clase sirve sobre el sidebar oscuro y sobre una tarjeta clara sin
repintarla.

Lleva las dos sintaxis porque ningún navegador soporta ambas —
`scrollbar-width` (Firefox, Chrome 121+) y `::-webkit-scrollbar` (Safari y
Chrome anteriores). Cada navegador aplica la que entiende.

---

## 7.2.1 Montos: `InputMoneda` y `lib/moneda.ts`

**Todo campo de dinero usa `<InputMoneda>`.** Separa los miles mientras se
escribe y devuelve el texto ya formateado:

```tsx
<InputMoneda value={montoCobro} onChange={setMontoCobro} placeholder="Monto *" />
```

Para parsear lo que devuelve, `numeroMoneda()`. Para mostrar un número,
`formatearMoneda()`. Las dos viven en [lib/moneda.ts](../src/lib/moneda.ts) y son
el **único** lugar donde se formatea o se parsea plata.

### Por qué no alcanza con formatear en `onBlur`

Era como estaba: el número sólo se leía bien al salir del campo, justo cuando ya
se dejó de mirar. Quien carga un monto largo lo cuenta con el dedo en la
pantalla — y ahí es donde `34200` y `342000` se confunden.

### El problema real es el cursor

Reformatear en cada tecla reemplaza el valor del input, y el navegador manda el
cursor al final: corregir un dígito en medio de `1.234.567` lo tira al fondo y la
siguiente tecla cae en el lugar equivocado.

Se resuelve contando los **caracteres significativos** a la izquierda del cursor
—dígitos y coma, lo único que sobrevive al formateo— y reubicándolo después de
esa misma cantidad. Va en `useLayoutEffect` y no en el `onChange`: el valor lo
controla el padre, así que recién después de que React pinta el texto nuevo tiene
sentido mover el cursor.

### Nunca `Number()` sobre un monto

```ts
Number("34.200"); // 34.2   ← un importe mil veces menor
numeroMoneda("34.200"); // 34200
```

No tira error: guarda el número mal y nadie se entera. Era el bug que había en
compras, inventarios, lotes y cuentas bancarias, invisible mientras los inputs no
separaban miles.

Lo mismo al precargar desde un número: va `formatearMoneda(n)`, no `String(n)`.
`String(34200.5)` da `"34200.5"` con punto decimal de JS, que el componente
leería como separador de miles.

### Los porcentajes y las cantidades no son montos

`InputMoneda` es sólo para plata. Una cantidad de unidades o un porcentaje de IVA
siguen con `<Input>` común: separarles los miles no ayuda, y en Lotes hay un
`montoOpcional` de zod aparte del `numeroOpcional` justamente para no aflojar la
validación de las cantidades.

---

## 7.3 Texto largo: `truncate` no alcanza, y en un diálogo molesta

Los nombres de artículo del catálogo real llegan a 80 caracteres. En cualquier
lugar donde se muestre un dato que viene de la base hay que decidir **qué pasa
cuando no entra**, y la respuesta no es la misma en todos lados.

### `min-w-0` es lo que evita el desborde, no `truncate`

Es la parte contraintuitiva y la que ya nos costó una pantalla rota. Dentro de un
contenedor flex, un hijo **no se encoge por debajo del ancho de su contenido**
salvo que se lo declares: ese es el valor inicial `min-width: auto` de la
especificación. Sin `min-w-0`, un texto largo **estira el contenedor** y se sale
del diálogo — y `truncate` no lo impide, porque nunca llega a activarse.

```tsx
// ✗ Desborda el diálogo: el span estira el botón hasta donde le pida el texto
<div className="flex">
  <span className="truncate">{nombreLargo}</span>
</div>

// ✓ El span se achica y recién ahí trunca
<div className="flex">
  <span className="min-w-0 flex-1 truncate">{nombreLargo}</span>
</div>
```

**La regla: todo `truncate` dentro de un flex lleva `min-w-0` en el mismo
elemento o en su contenedor.** Si ves un `truncate` sin `min-w-0` cerca, es un
desborde esperando a que alguien cargue un nombre largo.

### Truncar o envolver: depende de para qué se lee el dato

| Dónde                                        | Qué hacer               | Por qué                                                                                      |
| -------------------------------------------- | ----------------------- | -------------------------------------------------------------------------------------------- |
| Celda de tabla, tarjeta de listado           | `min-w-0` + `truncate`  | Son filas repetidas: la altura pareja es lo que hace la lista legible de un vistazo          |
| **Dentro de un diálogo**                     | `break-words`, envolver | El diálogo es angosto y el dato es el que se está por elegir o tildar: hay que leerlo entero |
| Disparador de un selector (el valor elegido) | Ver abajo               | Necesita crecer, pero con techo                                                              |

El caso del medio es el que más se equivoca. En una lista de permisos, dos
páginas que empiezan igual se ven **idénticas** truncadas, y quien tilda no
tiene forma de saber cuál marcó. Lo mismo con la descripción de una ubicación:
truncada se pierde justo lo que la distingue de la de al lado.

### El `<Button>` no salta de línea solo

La clase base de shadcn trae **`whitespace-nowrap` y altura fija** (`h-9`), así
que un botón cuyo contenido es un dato variable —el disparador de un selector,
que muestra el valor elegido— no puede pasar a una segunda línea aunque le pongas
`break-words`. Hay que anular las dos cosas:

```tsx
<Button
  className={cn(
    // `h-auto` + `min-h-9`: con la altura fija el texto se sale del borde.
    // `whitespace-normal` anula el `whitespace-nowrap` de la clase base.
    "h-auto min-h-9 w-full justify-between whitespace-normal py-1.5 text-left font-normal",
    className,
  )}
  {...(seleccionada ? { title: seleccionada.etiqueta } : {})}
>
  {/* `line-clamp-2` y no `break-words` a secas: crece hasta dos líneas y recién
      ahí corta, para que un nombre disparatado no estire el botón sin techo. */}
  <span className="line-clamp-2 min-w-0 flex-1 break-words">{etiqueta}</span>
  <ChevronsUpDown className="ml-2 size-4 shrink-0 self-center opacity-50" />
</Button>
```

Los dos selectores del proyecto —[SelectorModal](../src/components/ctell/SelectorModal.tsx)
y [SelectorArticulo](../src/components/ctell/SelectorArticulo.tsx)— ya lo tienen
resuelto, así que **usándolos no hay nada que hacer**. Esto importa si algún día
armás otro disparador con `<Button>`.

Y el `title` con el texto completo va siempre: dos líneas alcanzan casi siempre,
pero cuando no, el hover es la única forma de leer el resto sin abrir el modal.

### La lista dentro del modal siempre envuelve

Es el lugar donde se elige, así que ahí el nombre va entero:

```tsx
<span className="flex min-w-0 flex-1 flex-col">
  <span className="break-words">{opcion.etiqueta}</span>
  {/* La descripción sí trunca: es corta, de apoyo, y sale de campos acotados
      (un código, un RUC, "12 en sistema"). */}
  {opcion.descripcion && (
    <span className="truncate text-xs text-muted-foreground">{opcion.descripcion}</span>
  )}
</span>
```

### Tablas anchas dentro de un diálogo

Ahí el problema no es una celda sino el conjunto de columnas. La solución no es
truncar cada una sino envolver la tabla:

```tsx
<div className="overflow-x-auto">
  <Table>…</Table>
</div>
```

`TableCell` **no** trae `whitespace-nowrap`, así que el texto de cada celda
envuelve solo — y la tabla scrollea de costado si aun así no entra.

---

## 8. Checklist

Antes de dar por terminada una pantalla:

- [ ] `npx tsc --noEmit` y `npm run lint` sin errores
- [ ] Tipo y bloque agregados en `src/lib/api.ts`
- [ ] El tipo declara **todos** los campos que devuelve el `JSON_OBJECT`
- [ ] Página envuelta en `<AppLayout>` con `active="/la-ruta"` (la ruta, no el nombre)
- [ ] `pb-28` en el `<main>` para el botón flotante de móvil
- [ ] ~~La ruta agregada a `RUTAS_DISPONIBLES`~~ — **ya no hace falta**: las
      opciones del alta se derivan del router ([rutas-app.ts](../src/lib/rutas-app.ts)).
      Crear el archivo en `src/routes/` alcanza
- [ ] **El nombre de la página sumado a `ICONOS_PAGINA`** en `menu-iconos.ts`,
      con un ícono que no esté ya usado por otra entrada
- [ ] Registrada en Administración → Páginas, y asignada en Permisos
- [ ] Si es una tabla por empresa: `empresa.id` en la `queryKey`, `enabled:
empresa !== null`, y el caso `empresa === null` contemplado en el render
- [ ] **`empresa.id` en la `queryKey` de TODA consulta que lo mande, incluidas
      las de los diálogos.** Sin él, cambiar de empresa sirve la caché de la
      anterior: la pantalla muestra datos ajenos sin haber hecho ninguna
      petición mal. Y si agregás la empresa a una clave que ya existía,
      **revisá las invalidaciones**: TanStack compara elemento por elemento y
      `["x", idHijo]` deja de alcanzar a `["x", idEmpresa, idHijo]`
- [ ] **Nada de `?? 0` como relleno de `idEmpresa`.** Un cero es *falsy* y un
      armador de query string lo descarta: la petición sale sin empresa. Va
      `?? null` en la clave y un `enabled` que impida correr la consulta
- [ ] **Si la tabla es un cruce o un detalle** (sin `ID_EMPRESA` propia), el
      endpoint igual lleva `idEmpresa`: son las que más fácil se escapan, porque
      ni la consulta se acota sola ni el tipo avisa
- [ ] Si tiene FK a otro catálogo: selector con datos de la API relacionada,
      filtrando opciones inactivas y validando en backend la pertenencia a la
      empresa cuando corresponda
- [ ] Si además cuelga de una sucursal: **`sucursal.id` también** en la
      `queryKey` y en el `enabled`, y el caso "la empresa no tiene sucursales"
      resuelto en el render — ver [Empresa y sucursal activas](#empresa-y-sucursal-activas)
- [ ] Los contenedores con scroll propio llevan `scrollbar-fino`
- [ ] **Todo `truncate` dentro de un flex tiene `min-w-0`** en el mismo elemento
      o en su contenedor — sin eso el texto largo desborda en vez de cortarse
- [ ] **Dentro de un diálogo el texto envuelve (`break-words`), no trunca** — el
      nombre que se está por elegir o tildar hay que poder leerlo entero. En
      celdas de tabla y tarjetas de listado sí se trunca. Ver
      [Texto largo](#73-texto-largo-truncate-no-alcanza-y-en-un-diálogo-molesta)
- [ ] Probado con **el nombre más largo del catálogo real**, no con datos de
      prueba cortos: es lo único que revela un desborde
- [ ] Los cuatro estados del listado: cargando, error, vacío con acción, con datos
- [ ] Tarjetas abajo de `sm`, tabla arriba
- [ ] **Buscador con `useTablaListado`** que filtra por los campos visibles
- [ ] **Headers ordenables (`TableHeadOrdenable`)** en cada columna de la tabla desktop
- [ ] **Al menos un filtro con `TableHeadFiltrable`**, en el header y no en un
      campo suelto arriba. La columna es la que tiene valores repetidos: estado,
      la entidad padre, una clasificación, o "en uso / sin usar"
- [ ] Si la columna filtrada es **nullable**, una opción explícita para los nulos
      ("Sin condición", "Sin categoría") — si no, esas filas no se pueden aislar
- [ ] El paginado y el estado vacío miran **todos** los filtros, no sólo `termino`
- [ ] **Corte de a 20 con "Mostrar más"**, y `mostrados` (no `resultado`) en la
      tabla y en las tarjetas
- [ ] **Listas de valores con `SelectorModal`** (abre modal), no `<Select>` ni popover
- [ ] …salvo que el endpoint de origen **pagine**: ahí va un **selector en modal**
      que busca contra el servidor (ver `SelectorArticulo`). Un `SelectorModal` sobre
      un listado paginado sólo ve la primera página
- [ ] **`idEmpresa` en el `actualizar`**, no sólo en el `crear` — el backend lo
      exige para acotar la fila y responde 400 sin él
- [ ] **La página está en `ICONOS_PAGINA` con un ícono que nadie más usa** —
      verificado con `npm run verificar-iconos`, no a ojo
- [ ] Formularios con `values`/`defaultValues` y validación zod
- [ ] **El formulario entra sin scrollear**, con el botón de guardar visible: dos
      columnas y ancho acorde a la cantidad de campos, agrupados en secciones
- [ ] Toggle de activo sólo en edición, no en el alta
- [ ] Las mutaciones invalidan sus queries — **y las que dependen**: editar una
      tasa de IVA o una condición de pago cambia lo que muestran las facturas
- [ ] Si el formulario tiene **detalle** (cabecera + líneas): las líneas en
      `useState` con clave propia, validadas a mano, y totales en vivo con los
      **mismos redondeos que el SQL** — ver
      [Formularios con detalle](#61-formularios-con-detalle-cabecera-y-líneas)
- [ ] Probado en claro/oscuro y en ancho de móvil

### Errores frecuentes

| Síntoma                                                                   | Causa                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| El item aparece en el menú pero el clic no navega                         | `PAGINAS.RUTA` no coincide con ninguna ruta del router                                                                                                                                                                                          |
| El menú no muestra una página asignada                                    | El módulo o la página están inactivos, o falta el permiso                                                                                                                                                                                       |
| Todo se ve bien pero una acción no hace nada                              | La API no devuelve un campo: llega `undefined`. Corré `npx tsc --noEmit`                                                                                                                                                                        |
| El texto no se lee en hover en el sidebar                                 | Falta `variant="dark"`: las clases claras no contrastan sobre el navy                                                                                                                                                                           |
| El formulario muestra datos del registro anterior                         | Se usó `defaultValues` en vez de `values` en un dialog reutilizado                                                                                                                                                                              |
| Hay que scrollear para llegar al botón de guardar                         | El diálogo quedó en una columna con demasiados campos: subí el ancho y pasá a `sm:grid-cols-2`                                                                                                                                                  |
| Un campo bloqueado se puede editar igual                                  | El `<fieldset disabled>` está con `display:contents` dentro de una grilla: poné `disabled` en cada `Input`                                                                                                                                      |
| El error del backend no se ve al borrar                                   | Falta `e.preventDefault()` en el `AlertDialogAction`                                                                                                                                                                                            |
| La lista no se actualiza tras guardar                                     | Falta `invalidateQueries` — o su clave dejó de matchear porque a la de la consulta se le agregó la empresa en el medio. TanStack compara **elemento por elemento**: invalidá por el prefijo solo                                               |
| **Veo registros de otra empresa**                                         | La `queryKey` no lleva `empresa?.id` (se sirvió la caché de la empresa anterior), o la consulta no manda `idEmpresa` y el backend lo trata como "todas". Es lo que pasó en `/articulos-ubicaciones`: `npm run lint` ahora detecta las dos formas |
| `window is not defined`                                                   | Acceso al DOM fuera de `useEffect` (corre en el prerender de build)                                                                                                                                                                             |
| Cambios que no aparecen por más que recargues                             | Hay más de un `npm run dev` corriendo: mirá en qué puerto estás                                                                                                                                                                                 |
| El buscador no encuentra nada que sí está en pantalla                     | Falta agregar ese campo al array que devuelve la función de `useTablaListado`                                                                                                                                                                   |
| El selector no filtra por lo que se ve en pantalla                        | `SelectorModal` busca contra `etiqueta` y `descripcion`, nunca contra `valor` (que es el id). Si armaste una lista a mano con `Command`, ese es el error: el `filter` de cmdk compara contra el `value`                                         |
| **El menú quedó vacío después de entrar**                                 | El usuario no tiene permisos **en esa empresa**, o los tiene con `idEmpresa` en null (cargados antes de que existiera la columna). Reasignalos desde el ABM de permisos entrando con la empresa que corresponda                                 |
| **Un listado por empresa trae filas de otra**                             | Falta `enabled: empresa !== null`: en el primer render `empresa` todavía es null y la petición sale sin `idEmpresa`                                                                                                                             |
| **400 al MODIFICAR, pero el alta funciona**                               | Falta `idEmpresa` en el `actualizar`. El backend lo exige para acotar a cuál fila se aplica el cambio, y es fácil de olvidar porque no es un campo del formulario. Pasó en 7 pantallas a la vez: se copió el formulario y se arrastró el olvido |
| **El selector no encuentra un registro que sí existe**                    | Ese endpoint pagina y se está usando `SelectorModal`, que filtra en memoria sobre la primera página. Usar un selector que consulte al servidor (ver `SelectorArticulo`)                                                                         |
| **Dos páginas del menú tienen el mismo ícono**                            | Alguna no está en `ICONOS_PAGINA` y cae en el fallback `FileText`, que comparten todas las no mapeadas. Corré `npm run verificar-iconos`: nombra el ícono y quiénes lo comparten                                                                |
| **Un filtro de columna ofrece pocas opciones**                            | Se está armando desde un `listar` paginado. Armalo desde las filas ya listadas (como el filtro de artículo en Lotes): además evita ofrecer valores que dejarían la tabla vacía                                                                  |
| **Al cambiar de empresa se ven los datos de la anterior**                 | Falta `empresa.id` en la `queryKey`: TanStack Query cree que es la misma consulta                                                                                                                                                               |
| **Un nombre largo se sale del diálogo**                                   | Falta `min-w-0` en el elemento con `truncate` (o en su contenedor flex): sin él el texto estira el contenedor y `truncate` nunca llega a activarse. Ver [Texto largo](#73-texto-largo-truncate-no-alcanza-y-en-un-diálogo-molesta)              |
| **El texto de un botón no salta de línea aunque le pongas `break-words`** | La clase base del `<Button>` de shadcn trae `whitespace-nowrap` y `h-9`. Hay que anular las dos: `h-auto min-h-9 whitespace-normal`                                                                                                             |
| **Dos opciones de una lista se ven idénticas**                            | Están truncadas y comparten el prefijo. Dentro de un diálogo el texto envuelve (`break-words`), no trunca                                                                                                                                       |
| Las imágenes se ven como ícono roto                                       | Falta el `onError` que cae al respaldo. Si además es en todas, el endpoint de imagen no está publicado en APEX                                                                                                                                  |
| Elegir el mismo archivo dos veces no hace nada                            | Falta `event.target.value = ""` en el `onChange` del input file                                                                                                                                                                                 |
