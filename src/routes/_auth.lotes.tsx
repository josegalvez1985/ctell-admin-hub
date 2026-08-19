import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { SelectorArticulo } from "@/components/ctell/SelectorArticulo";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import { TableHeadFiltrable, SIN_FILTRO } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { api, ApiError, type Lote } from "@/lib/api";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { tituloPagina } from "@/lib/marca";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

export const Route = createFileRoute("/_auth/lotes")({
  head: () => ({
    meta: [
      { title: tituloPagina("Lotes") },
      {
        name: "description",
        content: "Partidas de mercadería con su vencimiento, cantidad y costo.",
      },
    ],
  }),
  component: LotesPage,
});

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Lotes está en SOLO CONSULTA por ahora: no se puede crear, editar ni borrar.
 *
 * Es una decisión temporal, no una limitación técnica — el backend
 * (`PKG_LOTES`) sigue aceptando las tres operaciones y otras pantallas las usan:
 * Inventarios ajusta `CANTIDAD_DISPON` al procesar un conteo. Lo único que se
 * apaga es la escritura DESDE ESTA PANTALLA.
 *
 * **Para volver a habilitarla, poné esto en `false`.** El formulario, las
 * mutaciones y los botones siguen en el archivo y compilando: no hay nada que
 * reescribir. Se hizo con un flag y no borrando el código justamente porque la
 * intención declarada es rehabilitarlo.
 */
const SOLO_CONSULTA = true;

/**
 * Cuántas filas trae cada página DEL SERVIDOR, y cuántas suma "Mostrar más".
 *
 * Antes el endpoint devolvía la tabla entera y esto era un recorte en el
 * navegador: se pagaba el tráfico y el parseo de todos los lotes de la sucursal
 * para dibujar 20 filas. Ahora el corte lo hace el SQL con OFFSET/FETCH.
 */
const POR_PAGINA = 20;

/** Lo que se espera entre teclas antes de mandar la búsqueda al servidor. */
const ESPERA_BUSQUEDA_MS = 350;

/** Días antes del vencimiento a partir de los cuales el lote se marca. */
const DIAS_AVISO = 30;

/**
 * Campo de fecha: ISO de sólo día, que es lo que el backend espera y devuelve.
 *
 * `z.string()` y no `z.date()` porque el `<input type="date">` entrega el string
 * ya en ese formato — convertirlo a Date y de vuelta sólo agregaría zonas
 * horarias que acá no significan nada (un vencimiento es un día del calendario).
 */
const fechaOpcional = z
  .string()
  .trim()
  .regex(/^\d{4}-\d{2}-\d{2}$/, "Fecha inválida")
  .optional()
  .or(z.literal(""));

/**
 * Los numéricos se validan como texto y se convierten al enviar, igual que en
 * Artículos: el input es de texto y un `z.coerce.number()` sobre "" da 0, que
 * acá significaría "costo cero" en vez de "sin costo cargado".
 */
const numeroOpcional = (etiqueta: string) =>
  z
    .string()
    .trim()
    .refine((v) => v === "" || !Number.isNaN(Number(v)), `${etiqueta} tiene que ser un número`)
    .refine((v) => v === "" || Number(v) >= 0, `${etiqueta} no puede ser negativo`);

const schema = z
  .object({
    idArticulo: z.string().min(1, "Elegí un artículo"),
    numeroLote: numeroOpcional("El número de lote"),
    cantidad: numeroOpcional("La cantidad"),
    cantidadDispon: numeroOpcional("La cantidad disponible"),
    costo: numeroOpcional("El costo"),
    fechaEntrada: fechaOpcional,
    fechaVencimiento: fechaOpcional,
    observaciones: z.string().trim().max(1000, "Máximo 1000 caracteres"),
  })
  // Mismos controles que hace el backend. Acá se validan además para no gastar
  // un viaje a la red en un error que se ve en el formulario.
  .refine((v) => !v.fechaEntrada || !v.fechaVencimiento || v.fechaVencimiento >= v.fechaEntrada, {
    message: "No puede vencer antes de entrar",
    path: ["fechaVencimiento"],
  })
  // No puede quedar disponible más de lo que entró.
  .refine(
    (v) => !v.cantidadDispon || !v.cantidad || Number(v.cantidadDispon) <= Number(v.cantidad),
    {
      message: "No puede superar la cantidad que entró",
      path: ["cantidadDispon"],
    },
  );

type FormValues = z.infer<typeof schema>;

/** "2026-04-03" → "3 abr 2026". Sin hora: el backend manda sólo el día. */
function formatearFecha(valor: string | null): string {
  if (!valor) return "—";
  // Se parsea a mano en vez de con `new Date("2026-04-03")`: ese formato lo
  // interpreta como UTC, y al mostrarlo en una zona al oeste retrocede un día.
  const [anio, mes, dia] = valor.split("-").map(Number);
  if (!anio || !mes || !dia) return valor;
  return new Intl.DateTimeFormat("es-PY", { dateStyle: "medium" }).format(
    new Date(anio, mes - 1, dia),
  );
}

/** Días que faltan para el vencimiento. Negativo si ya venció, null si no vence. */
function diasParaVencer(valor: string | null): number | null {
  if (!valor) return null;
  const [anio, mes, dia] = valor.split("-").map(Number);
  if (!anio || !mes || !dia) return null;
  const hoy = new Date();
  const vence = new Date(anio, mes - 1, dia);
  // Se comparan días, no instantes: sin esto un lote que vence hoy da -0.4 y
  // aparecería como vencido según la hora en que se mire la pantalla.
  const truncar = (f: Date) => new Date(f.getFullYear(), f.getMonth(), f.getDate()).getTime();
  return Math.round((truncar(vence) - truncar(hoy)) / 86_400_000);
}

/** Importe con separador de miles. Sin decimales fijos: 1500 no es "1.500,00". */
function formatearImporte(valor: number | null): string {
  if (valor === null) return "—";
  return new Intl.NumberFormat("es-PY", { maximumFractionDigits: 2 }).format(valor);
}

/**
 * Estado de vencimiento, para la insignia del listado.
 *
 * Es lo que justifica mirar esta pantalla: sin el color hay que leer fecha por
 * fecha y restar mentalmente contra hoy.
 */
function estadoVencimiento(lote: Lote): {
  texto: string;
  variante: "secondary" | "outline" | "destructive";
} | null {
  const dias = diasParaVencer(lote.fechaVencimiento);
  if (dias === null) return null;
  if (dias < 0) return { texto: "Vencido", variante: "destructive" };
  // El aviso arranca en 1 día, no en 0: el que vence hoy todavía no está
  // vencido y no se le muestra insignia. Con `dias >= 1` el "0 d" queda fuera.
  if (dias >= 1 && dias <= DIAS_AVISO) return { texto: `${dias} d`, variante: "secondary" };
  return null;
}

/**
 * Lotes: las partidas de mercadería de la sucursal activa.
 *
 * Cuelga de empresa y sucursal como Ubicaciones —las dos salen de los providers,
 * no de un combobox— y además de un artículo, que sí se elige en el formulario
 * porque es el dato que da sentido al lote.
 *
 * El listado viene ordenado por vencimiento (lo que vence primero, primero), que
 * es la pregunta que justifica la tabla.
 */
function LotesPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Lote | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Lote | null>(null);
  const [filtroArticulo, setFiltroArticulo] = useState<string>(SIN_FILTRO);

  // Dos estados para la búsqueda: `busqueda` es lo que se ve en el input
  // (inmediato, sin lag al tipear) y `busquedaEnvio` lo que entra en la
  // queryKey, para no disparar una consulta por tecla.
  const [busqueda, setBusqueda] = useState("");
  const [busquedaEnvio, setBusquedaEnvio] = useState("");

  useEffect(() => {
    const id = setTimeout(() => setBusquedaEnvio(busqueda), ESPERA_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  const { empresa } = useEmpresa();
  const { sucursal, cargando: cargandoSucursal } = useSucursal();

  // Empresa, sucursal, búsqueda y filtro entran en la queryKey: al cambiar
  // cualquiera, TanStack Query trata el listado como otra consulta —y descarta
  // las páginas ya traídas, que eran de otro filtro— en vez de mostrar la caché
  // anterior.
  //
  // useInfiniteQuery y no useQuery: "Mostrar más" ACUMULA páginas del servidor.
  // Con useQuery cada página reemplazaría a la anterior y el botón navegaría en
  // vez de agregar filas.
  const { data, isPending, isError, fetchNextPage, hasNextPage, isFetchingNextPage } =
    useInfiniteQuery({
      queryKey: [
        "lotes",
        empresa?.id ?? null,
        sucursal?.id ?? null,
        busquedaEnvio.trim(),
        filtroArticulo,
      ],
      queryFn: ({ pageParam }) =>
        api.lotes.listar({
          idEmpresa: empresa!.id,
          idSucursal: sucursal!.id,
          idArticulo: filtroArticulo === SIN_FILTRO ? undefined : Number(filtroArticulo),
          busqueda: busquedaEnvio,
          pagina: pageParam,
          tamanio: POR_PAGINA,
        }),
      // Los providers hidratan después de montar: sin esto la primera petición
      // saldría sin filtros y traería los lotes de todas las sucursales.
      enabled: empresa !== null && sucursal !== null,
      initialPageParam: 1,
      // `total` es el de las filas que pasan el filtro, así que sumar lo ya
      // traído y compararlo dice si queda otra página. Devolver undefined es lo
      // que apaga `hasNextPage` y esconde el botón.
      getNextPageParam: (ultima, paginas) => {
        const traidos = paginas.reduce((suma, p) => suma + p.items.length, 0);
        return traidos < ultima.total ? paginas.length + 1 : undefined;
      },
    });

  // Los artículos alimentan el filtro de la columna y el formulario. Misma
  // queryKey que usa la página de Artículos, así se comparte la respuesta.
  // SÓLO para saber si la empresa tiene artículos: el selector del formulario ya
  // no se alimenta de acá (usa SelectorArticulo, que consulta paginado por su
  // cuenta) y el filtro de la columna sale de los lotes listados.
  //
  // Por eso pide `tamanio: 1`: lo único que se mira es `total`, y traer 20 filas
  // que nadie dibuja sería tráfico al pedo. La queryKey lleva "existen" para no
  // pisar en caché la del listado completo de la pantalla de Artículos.
  const { data: articulos, isPending: cargandoArticulos } = useQuery({
    queryKey: ["articulos", "existen", empresa?.id ?? null],
    queryFn: () => api.articulos.listar({ idEmpresa: empresa!.id, tamanio: 1 }),
    enabled: empresa !== null,
  });

  // Todas las páginas traídas hasta ahora, aplanadas. Es lo que la tabla pinta:
  // NO hay recorte en el cliente, porque cada fila que llegó ya la eligió el
  // servidor.
  const cargados = (data?.pages ?? []).flatMap((p) => p.items);

  /**
   * El orden por click en el header ORDENA SOLO LO YA CARGADO, no la sucursal
   * entera. Es la misma diferencia que en Artículos: con 40 de 300 lotes
   * traídos, "ordenar por cantidad descendente" muestra el mayor de esos 40.
   *
   * Se mantiene así porque el uso es reordenar lo que se está mirando; para
   * encontrar un lote puntual está la búsqueda, que sí va al servidor.
   *
   * `useTablaListado` ya no sirve: su filtrado por término era en memoria y
   * ahora esa parte la hace el SQL. Sólo se conserva el orden, y con los
   * comparadores propios que esta tabla necesitaba —varias columnas son
   * numéricas o fechas, y como texto la cantidad 10 iría antes que la 2.
   */
  const [orden, setOrden] = useState<{
    campo: keyof Lote;
    direccion: "asc" | "desc";
  } | null>(null);

  function alternarOrden(campo: keyof Lote) {
    setOrden((actual) => {
      if (!actual || actual.campo !== campo) return { campo, direccion: "asc" };
      if (actual.direccion === "asc") return { campo, direccion: "desc" };
      return null; // Tercer click: vuelve al orden del backend (por vencimiento).
    });
  }

  const mostrados = useMemo(() => {
    // `id` entra acá y no en el comparador de texto: como string, el lote 10
    // iría antes que el 2. `numeroLote` salió de la lista junto con su columna:
    // ningún header lo ordena ya.
    const numericas = ["id", "cantidad", "cantidadDispon", "costo"] as const;
    type CampoNumerico = (typeof numericas)[number];
    const esNumerica = (campo: string): campo is CampoNumerico =>
      (numericas as readonly string[]).includes(campo);

    if (orden && esNumerica(orden.campo)) {
      const factor = orden.direccion === "asc" ? 1 : -1;
      // El campo se copia a una constante: leerlo como `a[orden.campo]` dentro
      // del sort deja el tipo como la unión de las tres columnas y TypeScript no
      // lo estrecha a number.
      const campo: CampoNumerico = orden.campo;
      return [...cargados].sort((a, b) => {
        const va = a[campo];
        const vb = b[campo];
        // Los nulos al final en las dos direcciones: "sin costo" no es ni el
        // más caro ni el más barato.
        if (va === null && vb === null) return 0;
        if (va === null) return 1;
        if (vb === null) return -1;
        return factor * (va - vb);
      });
    }

    if (orden?.campo === "fechaVencimiento") {
      const factor = orden.direccion === "asc" ? 1 : -1;
      // Las fechas en ISO ordenan bien como texto, pero los nulos tienen que ir
      // al final igual que en el SQL.
      return [...cargados].sort((a, b) => {
        if (a.fechaVencimiento === null && b.fechaVencimiento === null) return 0;
        if (a.fechaVencimiento === null) return 1;
        if (b.fechaVencimiento === null) return -1;
        return factor * a.fechaVencimiento.localeCompare(b.fechaVencimiento);
      });
    }

    if (orden) {
      const factor = orden.direccion === "asc" ? 1 : -1;
      const campo = orden.campo;
      return [...cargados].sort(
        (a, b) => factor * String(a[campo] ?? "").localeCompare(String(b[campo] ?? ""), "es"),
      );
    }

    return cargados;
  }, [cargados, orden]);

  // El total del backend son las filas que pasan el filtro, no las traídas.
  const total = data?.pages[0]?.total ?? 0;
  const quedan = total - cargados.length;

  // El término que el servidor está respondiendo, no el que se está tipeando:
  // los mensajes de "sin resultados" tienen que nombrar lo que se buscó de
  // verdad, no lo que quedó a medio escribir.
  const termino = busquedaEnvio.trim();

  // Las opciones del FILTRO de la columna salen de un endpoint propio, no de
  // los lotes ya listados: con el listado paginado, esas 20 filas darían un
  // desplegable a medias que empeoraría al filtrar.
  //
  // Tampoco de /articulos/listar: ese ofrece artículos sin ningún lote, y
  // elegirlos vaciaría la tabla. Las únicas opciones útiles son las que de
  // verdad tienen mercadería, que es lo que /lotes/articulos devuelve.
  //
  // NO lleva la búsqueda ni el filtro en la queryKey a propósito: las opciones
  // tienen que seguir completas mientras se filtra, si no elegir un artículo
  // vaciaría el desplegable del que se acaba de elegir.
  const { data: articulosConLotes } = useQuery({
    queryKey: ["lotes", "articulos", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => api.lotes.articulos({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
    enabled: empresa !== null && sucursal !== null,
  });

  const articulosDelListado = (articulosConLotes?.items ?? []).map((a) => ({
    valor: String(a.id),
    etiqueta: a.nombreArticulo,
  }));

  const eliminar = useMutation({
    mutationFn: (lote: Lote) => api.lotes.eliminar(lote.id, lote.idEmpresa),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["lotes"] });
      toast.success("Lote eliminado");
      setAEliminar(null);
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo eliminar el lote")),
  });

  // Sin sucursal no hay dónde crear ni qué listar: la pantalla lo dice en vez de
  // mostrar una tabla vacía que parecería un depósito sin mercadería.
  const sinSucursal = !cargandoSucursal && sucursal === null;
  // `total` y NO `items.length`: el listado de artículos viene paginado, así que
  // items son 20 como mucho. Da igual para saber si hay CERO —que es lo único
  // que se pregunta acá—, pero usar el total deja claro contra qué se compara y
  // no se rompe si algún día cambia el tamaño de página.
  const sinArticulos = !cargandoArticulos && (articulos?.total ?? 0) === 0;

  return (
    <AppLayout active="/lotes" title="Lotes">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Lotes</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Partidas de mercadería con su vencimiento y su costo
              {sucursal ? ` en ${sucursal.nombreSucursal}` : ""}.
              {SOLO_CONSULTA && " Sólo consulta: los lotes se cargan desde otro proceso."}
            </p>
          </div>
          {/* En solo consulta el botón no se deshabilita: se saca. Un botón gris
              invita a averiguar por qué no anda; ausente, la pantalla se lee
              como lo que es, un listado. El aviso está en el subtítulo. */}
          {!SOLO_CONSULTA && (
            <Button onClick={() => setCreando(true)} disabled={sucursal === null || sinArticulos}>
              <Plus className="size-4" />
              Nuevo lote
            </Button>
          )}
        </div>

        {sinSucursal ? (
          <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
            La empresa no tiene sucursales activas. Cargá una sucursal antes de registrar lotes.
          </p>
        ) : sinArticulos && !SOLO_CONSULTA ? (
          // Un lote sin artículo no existe: el formulario no se podría completar.
          //
          // El aviso REEMPLAZA a la tabla, así que en solo consulta no va: no
          // hay formulario que completar y esconder los lotes ya cargados por
          // un alta que nadie puede hacer sería ocultar justo lo que se viene a
          // mirar.
          <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
            La empresa no tiene artículos cargados. Cargá un artículo antes de registrar lotes.
          </p>
        ) : (
          <>
            <div className="relative max-w-sm">
              <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={busqueda}
                onChange={(e) => setBusqueda(e.target.value)}
                placeholder="Buscar artículo, lote u observaciones…"
                className="pl-9"
                aria-label="Buscar lotes"
              />
            </div>

            {isPending || cargandoSucursal ? (
              <div className="space-y-2">
                {[0, 1, 2, 3].map((i) => (
                  <Skeleton key={i} className="h-14 w-full" />
                ))}
              </div>
            ) : isError ? (
              <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
                No se pudieron cargar los lotes.
              </p>
            ) : mostrados.length === 0 ? (
              <div className="surface-card px-3 py-16 text-center">
                <p className="text-sm text-muted-foreground">
                  {termino || filtroArticulo !== SIN_FILTRO
                    ? "Ningún lote coincide con la búsqueda."
                    : "Todavía no hay lotes cargados en esta sucursal."}
                </p>
                {!SOLO_CONSULTA && !termino && filtroArticulo === SIN_FILTRO && (
                  <Button className="mt-4" onClick={() => setCreando(true)}>
                    Cargar el primero
                  </Button>
                )}
              </div>
            ) : (
              <>
                {/* Móvil: tarjetas. Una tabla de 6 columnas en 360px obliga a
                    scrollear de costado para leer una fila entera. */}
                <ul className="space-y-3 sm:hidden">
                  {mostrados.map((lote) => {
                    const estado = estadoVencimiento(lote);

                    return (
                      <li key={lote.id} className="surface-card p-4">
                        <div className="flex items-start justify-between gap-3">
                          <div className="min-w-0 flex-1">
                            <p className="truncate font-semibold text-foreground">
                              {lote.nombreArticulo}
                            </p>
                            {/* El ID y el código del artículo: el número de
                                partida se ocultó de esta pantalla. */}
                            <p className="mt-0.5 text-xs text-muted-foreground">
                              ID {lote.id}
                              {lote.codigoArticulo ? ` · ${lote.codigoArticulo}` : ""}
                            </p>
                          </div>
                          {estado && (
                            <Badge variant={estado.variante} className="shrink-0">
                              {estado.texto}
                            </Badge>
                          )}
                        </div>

                        <dl className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
                          <div>
                            <dt className="inline text-muted-foreground">Disponible: </dt>
                            <dd className="inline tabular-nums text-foreground">
                              {lote.cantidadDispon}
                              {/* Siempre, igual que en la tabla de escritorio. */}
                              <span className="text-muted-foreground"> de {lote.cantidad}</span>
                            </dd>
                          </div>
                          <div>
                            <dt className="inline text-muted-foreground">Costo: </dt>
                            <dd className="inline tabular-nums text-foreground">
                              {formatearImporte(lote.costo)}
                            </dd>
                          </div>
                          {/* Sin "Entrada": una sola fecha, igual que en la
                              tabla de escritorio. */}
                          <div>
                            <dt className="inline text-muted-foreground">Vence: </dt>
                            <dd className="inline tabular-nums text-foreground">
                              {formatearFecha(lote.fechaVencimiento)}
                            </dd>
                          </div>
                        </dl>

                        {!SOLO_CONSULTA && (
                          <div className="mt-3 flex gap-2 border-t border-border pt-3">
                            <Button
                              variant="outline"
                              size="sm"
                              className="flex-1"
                              onClick={() => setEditando(lote)}
                            >
                              <Pencil className="size-4" />
                              Editar
                            </Button>
                            <Button
                              variant="outline"
                              size="sm"
                              className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                              onClick={() => setAEliminar(lote)}
                            >
                              <Trash2 className="size-4" />
                              Eliminar
                            </Button>
                          </div>
                        )}
                      </li>
                    );
                  })}
                </ul>

                <div className="surface-card hidden overflow-x-auto sm:block">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHeadFiltrable
                          direccion={orden?.campo === "nombreArticulo" ? orden.direccion : null}
                          onOrdenar={() => alternarOrden("nombreArticulo")}
                          opciones={articulosDelListado}
                          valor={filtroArticulo}
                          onFiltrar={setFiltroArticulo}
                          buscarPlaceholder="Buscar artículo…"
                        >
                          Artículo
                        </TableHeadFiltrable>
                        {/* El ID_LOTE de la base, no el NUMERO_LOTE: el número
                            de partida se ocultó y lo que se necesita ver es el
                            identificador con el que el lote se referencia desde
                            el resto del sistema. */}
                        <TableHeadOrdenable
                          direccion={orden?.campo === "id" ? orden.direccion : null}
                          onClick={() => alternarOrden("id")}
                        >
                          ID
                        </TableHeadOrdenable>
                        {/* Ordena por lo DISPONIBLE, que es lo que la columna
                            muestra primero. */}
                        <TableHeadOrdenable
                          direccion={orden?.campo === "cantidadDispon" ? orden.direccion : null}
                          onClick={() => alternarOrden("cantidadDispon")}
                        >
                          Disponible / Entró
                        </TableHeadOrdenable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "costo" ? orden.direccion : null}
                          onClick={() => alternarOrden("costo")}
                        >
                          Costo
                        </TableHeadOrdenable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "fechaVencimiento" ? orden.direccion : null}
                          onClick={() => alternarOrden("fechaVencimiento")}
                        >
                          Vence
                        </TableHeadOrdenable>
                        {!SOLO_CONSULTA && <TableHead className="text-right">Acciones</TableHead>}
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {mostrados.map((lote) => {
                        const estado = estadoVencimiento(lote);

                        return (
                          <TableRow key={lote.id}>
                            <TableCell className="font-medium text-foreground">
                              {lote.nombreArticulo}
                              {lote.codigoArticulo && (
                                <span className="block text-xs font-normal text-muted-foreground">
                                  {lote.codigoArticulo}
                                </span>
                              )}
                            </TableCell>
                            <TableCell className="tabular-nums text-muted-foreground">
                              {lote.id}
                            </TableCell>
                            {/* "queda / entró": lo primero es el dato operativo
                                —cuánto hay— y lo segundo el contexto. Cuando el
                                lote está entero se muestra un solo número, para
                                no repetirlo. */}
                            <TableCell className="tabular-nums">
                              <span
                                className={
                                  lote.cantidadDispon === 0
                                    ? "text-muted-foreground"
                                    : "font-medium text-foreground"
                                }
                              >
                                {lote.cantidadDispon}
                              </span>
                              {/* El "/ entró" se muestra SIEMPRE, también con el
                                  lote entero: ocultarlo cuando los dos números
                                  coinciden dejaba la celda con un valor suelto y
                                  no se sabía si era lo que queda o lo que entró. */}
                              <span className="text-xs text-muted-foreground">
                                {" "}
                                / {lote.cantidad}
                              </span>
                            </TableCell>
                            <TableCell className="tabular-nums text-muted-foreground">
                              {formatearImporte(lote.costo)}
                            </TableCell>
                            {/* Sólo el vencimiento: la fecha de entrada iba
                                debajo y, cuando coinciden, la fila repetía dos
                                veces el mismo día sin que se notara que eran
                                cosas distintas. La entrada sigue en el detalle
                                del formulario. */}
                            <TableCell>
                              <div className="flex items-center gap-2">
                                <span className="tabular-nums text-muted-foreground">
                                  {formatearFecha(lote.fechaVencimiento)}
                                </span>
                                {estado && (
                                  <Badge variant={estado.variante} className="shrink-0">
                                    {estado.texto}
                                  </Badge>
                                )}
                              </div>
                            </TableCell>
                            {!SOLO_CONSULTA && (
                              <TableCell className="text-right">
                                <div className="flex justify-end gap-1">
                                  <Button
                                    variant="ghost"
                                    size="icon"
                                    title="Editar"
                                    aria-label={`Editar lote de ${lote.nombreArticulo}`}
                                    onClick={() => setEditando(lote)}
                                  >
                                    <Pencil className="size-4" />
                                  </Button>
                                  <Button
                                    variant="ghost"
                                    size="icon"
                                    title="Eliminar"
                                    aria-label={`Eliminar lote de ${lote.nombreArticulo}`}
                                    onClick={() => setAEliminar(lote)}
                                  >
                                    <Trash2 className="size-4 text-destructive" />
                                  </Button>
                                </div>
                              </TableCell>
                            )}
                          </TableRow>
                        );
                      })}
                    </TableBody>
                  </Table>
                </div>

                {/* Trae la página siguiente DEL SERVIDOR y la acumula; antes
                    sólo levantaba el corte de un listado que ya estaba entero
                    en memoria. */}
                {hasNextPage && (
                  <div className="flex justify-center">
                    <Button
                      variant="outline"
                      onClick={() => fetchNextPage()}
                      disabled={isFetchingNextPage}
                    >
                      {isFetchingNextPage && <Loader2 className="size-4 animate-spin" />}
                      {isFetchingNextPage
                        ? "Cargando…"
                        : `Mostrar más (${quedan} ${quedan === 1 ? "restante" : "restantes"})`}
                    </Button>
                  </div>
                )}
              </>
            )}
          </>
        )}

        {/* Sin empresa Y sucursal no se abre: el alta necesita los dos ids.
            En solo consulta tampoco se monta: nada puede abrirlo, y dejarlo
            armado igual haría trabajo por una pantalla que no se va a ver. */}
        {!SOLO_CONSULTA && empresa !== null && sucursal !== null && (
          <LoteFormDialog
            open={creando || editando !== null}
            lote={editando}
            idEmpresa={empresa.id}
            idSucursal={sucursal.id}
            onClose={() => {
              setCreando(false);
              setEditando(null);
            }}
          />
        )}

        <AlertDialog
          open={!SOLO_CONSULTA && aEliminar !== null}
          onOpenChange={(o) => !o && setAEliminar(null)}
        >
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar el lote?</AlertDialogTitle>
              <AlertDialogDescription>
                Se va a eliminar la partida de {aEliminar?.nombreArticulo}
                {aEliminar !== null ? ` (ID ${aEliminar.id})` : ""}. Esta acción no se puede
                deshacer.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancelar</AlertDialogCancel>
              <AlertDialogAction
                onClick={(e) => {
                  // Sin esto el AlertDialog se cierra antes de que la mutación
                  // termine y el error nunca se llega a mostrar.
                  e.preventDefault();
                  if (aEliminar) eliminar.mutate(aEliminar);
                }}
                disabled={eliminar.isPending}
              >
                {eliminar.isPending && <Loader2 className="size-4 animate-spin" />}
                Eliminar
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </main>
    </AppLayout>
  );
}

/** Alta y edición. Los ids de empresa y sucursal vienen del contexto activo. */
function LoteFormDialog({
  open,
  lote,
  idEmpresa,
  idSucursal,
  onClose,
}: {
  open: boolean;
  /** `null` en el alta. */
  lote: Lote | null;
  idEmpresa: number;
  idSucursal: number;
  // Ya no recibe las opciones de artículos: SelectorArticulo las consulta por su
  // cuenta contra el endpoint paginado.
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = lote !== null;

  // El NOMBRE del artículo elegido, para mostrarlo en el botón del selector.
  //
  // Va en estado y no se busca por id contra una lista: el listado de artículos
  // viene paginado, así que el artículo de este lote puede no estar entre los
  // que el selector trajo, y el campo se vería vacío al editar.
  const [nombreArticulo, setNombreArticulo] = useState(lote?.nombreArticulo ?? "");

  // El mismo diálogo sirve para alta y edición: sin esto, al abrirlo para otro
  // lote seguiría mostrando el nombre del anterior.
  useEffect(() => {
    setNombreArticulo(lote?.nombreArticulo ?? "");
  }, [lote]);

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // `values` y no `defaultValues`: el mismo diálogo sirve para alta y edición,
    // y sin esto conserva los datos del lote anterior al reabrirse.
    values: {
      idArticulo: lote ? String(lote.idArticulo) : "",
      numeroLote: lote?.numeroLote != null ? String(lote.numeroLote) : "",
      cantidad: lote ? String(lote.cantidad) : "0",
      // En el alta queda vacío: el backend lo iguala a la cantidad, que es lo
      // correcto para una partida recién ingresada. Poner "0" acá haría que el
      // lote naciera sin nada disponible.
      cantidadDispon: lote ? String(lote.cantidadDispon) : "",
      costo: lote?.costo != null ? String(lote.costo) : "",
      // El alta arranca con la fecha de hoy: lo habitual es cargar el lote el
      // día que entró la mercadería.
      fechaEntrada: lote?.fechaEntrada ?? hoyISO(),
      fechaVencimiento: lote?.fechaVencimiento ?? "",
      observaciones: lote?.observaciones ?? "",
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      // Los campos vacíos se omiten en vez de mandarse como "" o 0: el backend
      // trata lo ausente como "no cambiar", y un 0 explícito en costo pisaría
      // el valor real con un dato que nadie ingresó.
      const datos = {
        idArticulo: Number(v.idArticulo),
        ...(v.numeroLote ? { numeroLote: Number(v.numeroLote) } : {}),
        ...(v.cantidad ? { cantidad: Number(v.cantidad) } : {}),
        ...(v.cantidadDispon ? { cantidadDispon: Number(v.cantidadDispon) } : {}),
        ...(v.costo ? { costo: Number(v.costo) } : {}),
        ...(v.fechaEntrada ? { fechaEntrada: v.fechaEntrada } : {}),
        ...(v.fechaVencimiento ? { fechaVencimiento: v.fechaVencimiento } : {}),
        ...(v.observaciones ? { observaciones: v.observaciones } : {}),
      };

      return esEdicion
        ? // idEmpresa es OBLIGATORIO en el update aunque no sea un campo del
          // formulario: el backend lo usa en el WHERE para acotar a cuál fila
          // se aplica el cambio. Sin él responde 400.
          api.lotes.actualizar(lote.id, { idEmpresa: lote.idEmpresa, ...datos })
        : api.lotes.crear({ idEmpresa, idSucursal, ...datos });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["lotes"] });
      toast.success(esEdicion ? "Lote actualizado" : "Lote creado");
      onClose();
    },
    onError: (e) =>
      form.setError("root", { message: MENSAJE_ERROR(e, "No se pudo guardar el lote") }),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      {/* Dos columnas: son siete campos y a una columna el botón de guardar
          quedaba fuera de la pantalla. Ver "Un formulario entra en un
          pantallazo" en docs/GUIA-FRONTEND.md. */}
      <DialogContent className="scrollbar-fino max-h-[92vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar lote" : "Nuevo lote"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos de la partida."
              : "Registrá una partida de mercadería en la sucursal activa."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="idArticulo"
                render={({ field }) => (
                  <FormItem className="sm:col-span-2">
                    <FormLabel>Artículo</FormLabel>
                    <FormControl>
                      <SelectorArticulo
                        idEmpresa={idEmpresa}
                        value={field.value}
                        etiquetaSeleccionada={nombreArticulo}
                        onChange={(valor, etiqueta) => {
                          field.onChange(valor);
                          setNombreArticulo(etiqueta);
                        }}
                      />
                    </FormControl>
                    <FormDescription>De qué artículo es esta partida.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="numeroLote"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Número de lote</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        inputMode="numeric"
                        placeholder="Opcional"
                        autoComplete="off"
                        className="tabular-nums"
                      />
                    </FormControl>
                    <FormDescription>Vacío si la mercadería no lo trae.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="cantidad"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Cantidad que entró</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        inputMode="decimal"
                        placeholder="0"
                        autoComplete="off"
                        className="tabular-nums"
                      />
                    </FormControl>
                    <FormDescription>Histórico de la partida.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              {/* Sólo en EDICIÓN: en el alta el backend lo iguala a la cantidad
                  —una partida que recién entró no se consumió— y pedirlo sería
                  un campo más para escribir el mismo número dos veces. */}
              {esEdicion && (
                <FormField
                  control={form.control}
                  name="cantidadDispon"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Disponible</FormLabel>
                      <FormControl>
                        <Input
                          {...field}
                          inputMode="decimal"
                          placeholder="0"
                          autoComplete="off"
                          className="tabular-nums"
                        />
                      </FormControl>
                      <FormDescription>Lo que queda sin consumir.</FormDescription>
                      <FormMessage />
                    </FormItem>
                  )}
                />
              )}

              <FormField
                control={form.control}
                name="costo"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Costo</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        inputMode="decimal"
                        placeholder="0"
                        autoComplete="off"
                        className="tabular-nums"
                      />
                    </FormControl>
                    <FormDescription>Costo de esta partida.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="fechaEntrada"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Fecha de entrada</FormLabel>
                    <FormControl>
                      {/* type="date" y no un campo de texto: el selector nativo
                          evita que alguien escriba 03/04/2026 y quede ambiguo
                          entre marzo y abril. */}
                      <Input {...field} type="date" className="tabular-nums" />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="fechaVencimiento"
                render={({ field }) => (
                  <FormItem className="sm:col-span-2">
                    <FormLabel>Fecha de vencimiento</FormLabel>
                    <FormControl>
                      <Input {...field} type="date" className="tabular-nums" />
                    </FormControl>
                    <FormDescription>
                      Dejala vacía si la mercadería no vence.
                      {esEdicion && " Una vez cargada no se puede borrar desde acá."}
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="observaciones"
                render={({ field }) => (
                  <FormItem className="sm:col-span-2">
                    <FormLabel>Observaciones</FormLabel>
                    <FormControl>
                      <Textarea
                        {...field}
                        rows={2}
                        placeholder="Opcional."
                        className="resize-none"
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            {form.formState.errors.root && (
              <p
                role="alert"
                className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive"
              >
                {form.formState.errors.root.message}
              </p>
            )}

            <DialogFooter className="gap-2 sm:gap-2">
              <Button type="button" variant="outline" onClick={onClose}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                Guardar
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

/** Hoy en ISO de sólo día, para el valor inicial de la fecha de entrada. */
function hoyISO(): string {
  const hoy = new Date();
  const mes = String(hoy.getMonth() + 1).padStart(2, "0");
  const dia = String(hoy.getDate()).padStart(2, "0");
  return `${hoy.getFullYear()}-${mes}-${dia}`;
}
