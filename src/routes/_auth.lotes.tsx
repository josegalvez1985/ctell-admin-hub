import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { Combobox } from "@/components/ctell/Combobox";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import { TableHeadFiltrable, SIN_FILTRO } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
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

/** Cuántas filas se muestran de entrada, y cuántas suma cada "Mostrar más". */
const POR_PAGINA = 20;

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
    costo: numeroOpcional("El costo"),
    fechaEntrada: fechaOpcional,
    fechaVencimiento: fechaOpcional,
    observaciones: z.string().trim().max(1000, "Máximo 1000 caracteres"),
  })
  // Mismo control que hace el backend. Acá se valida además para no gastar un
  // viaje a la red en un error que se ve en el formulario.
  .refine((v) => !v.fechaEntrada || !v.fechaVencimiento || v.fechaVencimiento >= v.fechaEntrada, {
    message: "No puede vencer antes de entrar",
    path: ["fechaVencimiento"],
  });

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
  if (dias === 0) return { texto: "Vence hoy", variante: "destructive" };
  if (dias <= DIAS_AVISO) return { texto: `${dias} d`, variante: "secondary" };
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
  const [visibles, setVisibles] = useState(POR_PAGINA);

  const { empresa } = useEmpresa();
  const { sucursal, cargando: cargandoSucursal } = useSucursal();

  // Las dos entran en la queryKey: al cambiar cualquiera, TanStack Query trata
  // el listado como otra consulta en vez de mostrar en caché el de la anterior.
  const { data, isPending, isError } = useQuery({
    queryKey: ["lotes", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => api.lotes.listar({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
    // Los providers hidratan después de montar: sin esto la primera petición
    // saldría sin filtros y traería los lotes de todas las sucursales.
    enabled: empresa !== null && sucursal !== null,
  });

  // Los artículos alimentan el filtro de la columna y el formulario. Misma
  // queryKey que usa la página de Artículos, así se comparte la respuesta.
  const { data: articulos, isPending: cargandoArticulos } = useQuery({
    queryKey: ["articulos", empresa?.id ?? null],
    queryFn: () => api.articulos.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  const items = data?.items ?? [];

  // El endpoint acepta ?idArticulo=, pero el filtro se aplica en el cliente: el
  // listado ya vino entero, así que cambiar de artículo es instantáneo.
  const filtrados = items.filter(
    (l) => filtroArticulo === SIN_FILTRO || String(l.idArticulo) === filtroArticulo,
  );

  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    filtrados,
    (l) => [
      l.nombreArticulo,
      l.codigoArticulo,
      l.numeroLote === null ? "Sin número" : String(l.numeroLote),
      l.observaciones,
      // El texto que se ve, no el ISO: en pantalla dice "3 abr 2026".
      formatearFecha(l.fechaVencimiento),
      estadoVencimiento(l)?.texto,
    ],
  );

  /**
   * `useTablaListado` ordena con `localeCompare` sobre texto, y varias columnas
   * de acá son numéricas o fechas: como texto, la cantidad 10 iría antes que la
   * 2. Esas se reordenan a mano; el resto usa el orden del hook.
   *
   * Las fechas en ISO ordenan bien como texto (por eso no están acá), pero los
   * nulos tienen que ir al final igual que en el SQL.
   */
  const mostrados = useMemo(() => {
    const numericas = ["numeroLote", "cantidad", "costo"] as const;
    type CampoNumerico = (typeof numericas)[number];
    const esNumerica = (campo: string): campo is CampoNumerico =>
      (numericas as readonly string[]).includes(campo);

    let lista = resultado;

    if (orden && esNumerica(orden.campo)) {
      const factor = orden.direccion === "asc" ? 1 : -1;
      // El campo se copia a una constante: leerlo como `a[orden.campo]` dentro
      // del sort deja el tipo como la unión de las tres columnas y TypeScript no
      // lo estrecha a number.
      const campo: CampoNumerico = orden.campo;
      lista = [...resultado].sort((a, b) => {
        const va = a[campo];
        const vb = b[campo];
        // Los nulos al final en las dos direcciones: "sin costo" no es ni el
        // más caro ni el más barato.
        if (va === null && vb === null) return 0;
        if (va === null) return 1;
        if (vb === null) return -1;
        return factor * (va - vb);
      });
    } else if (orden?.campo === "fechaVencimiento") {
      const factor = orden.direccion === "asc" ? 1 : -1;
      lista = [...resultado].sort((a, b) => {
        if (a.fechaVencimiento === null && b.fechaVencimiento === null) return 0;
        if (a.fechaVencimiento === null) return 1;
        if (b.fechaVencimiento === null) return -1;
        return factor * a.fechaVencimiento.localeCompare(b.fechaVencimiento);
      });
    }

    return lista.slice(0, visibles);
  }, [resultado, orden, visibles]);

  // Se resetea al cambiar filtro o búsqueda: seguir en "80 de 90" después de
  // filtrar a 12 resultados mostraría todo de golpe. Ajuste en render, no
  // useEffect: React re-renderiza antes de pintar.
  const claveVista = `${filtroArticulo}|${termino}`;
  const [claveAnterior, setClaveAnterior] = useState(claveVista);
  if (claveVista !== claveAnterior) {
    setClaveAnterior(claveVista);
    setVisibles(POR_PAGINA);
  }

  const articulosOpciones = (articulos?.items ?? []).map((a) => ({
    valor: String(a.id),
    etiqueta: a.nombreArticulo,
    descripcion: a.codigoArticulo ?? undefined,
  }));

  const eliminar = useMutation({
    mutationFn: (lote: Lote) => api.lotes.eliminar(lote.id),
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
  const sinArticulos = !cargandoArticulos && (articulos?.items.length ?? 0) === 0;

  return (
    <AppLayout active="/lotes" title="Lotes">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Lotes</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Partidas de mercadería con su vencimiento y su costo
              {sucursal ? ` en ${sucursal.nombreSucursal}` : ""}.
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={sucursal === null || sinArticulos}>
            <Plus className="size-4" />
            Nuevo lote
          </Button>
        </div>

        {sinSucursal ? (
          <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
            La empresa no tiene sucursales activas. Cargá una sucursal antes de registrar lotes.
          </p>
        ) : sinArticulos ? (
          // Un lote sin artículo no existe: el formulario no se podría completar.
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
            ) : resultado.length === 0 ? (
              <div className="surface-card px-3 py-16 text-center">
                <p className="text-sm text-muted-foreground">
                  {termino || filtroArticulo !== SIN_FILTRO
                    ? "Ningún lote coincide con la búsqueda."
                    : "Todavía no hay lotes cargados en esta sucursal."}
                </p>
                {!termino && filtroArticulo === SIN_FILTRO && (
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
                            <p className="mt-0.5 text-xs text-muted-foreground">
                              {lote.numeroLote === null
                                ? "Sin número de lote"
                                : `Lote ${lote.numeroLote}`}
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
                            <dt className="inline text-muted-foreground">Cantidad: </dt>
                            <dd className="inline tabular-nums text-foreground">{lote.cantidad}</dd>
                          </div>
                          <div>
                            <dt className="inline text-muted-foreground">Costo: </dt>
                            <dd className="inline tabular-nums text-foreground">
                              {formatearImporte(lote.costo)}
                            </dd>
                          </div>
                          <div>
                            <dt className="inline text-muted-foreground">Entrada: </dt>
                            <dd className="inline tabular-nums text-foreground">
                              {formatearFecha(lote.fechaEntrada)}
                            </dd>
                          </div>
                          <div>
                            <dt className="inline text-muted-foreground">Vence: </dt>
                            <dd className="inline tabular-nums text-foreground">
                              {formatearFecha(lote.fechaVencimiento)}
                            </dd>
                          </div>
                        </dl>

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
                          opciones={articulosOpciones.map((a) => ({
                            valor: a.valor,
                            etiqueta: a.etiqueta,
                          }))}
                          valor={filtroArticulo}
                          onFiltrar={setFiltroArticulo}
                          buscarPlaceholder="Buscar artículo…"
                        >
                          Artículo
                        </TableHeadFiltrable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "numeroLote" ? orden.direccion : null}
                          onClick={() => alternarOrden("numeroLote")}
                        >
                          Lote
                        </TableHeadOrdenable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "cantidad" ? orden.direccion : null}
                          onClick={() => alternarOrden("cantidad")}
                        >
                          Cantidad
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
                        <TableHead className="text-right">Acciones</TableHead>
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
                              {lote.numeroLote ?? "—"}
                            </TableCell>
                            <TableCell className="tabular-nums text-muted-foreground">
                              {lote.cantidad}
                            </TableCell>
                            <TableCell className="tabular-nums text-muted-foreground">
                              {formatearImporte(lote.costo)}
                            </TableCell>
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
                              <span className="block text-xs text-muted-foreground">
                                Entró {formatearFecha(lote.fechaEntrada)}
                              </span>
                            </TableCell>
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
                          </TableRow>
                        );
                      })}
                    </TableBody>
                  </Table>
                </div>

                {resultado.length > mostrados.length && (
                  <div className="flex justify-center">
                    <Button variant="outline" onClick={() => setVisibles((v) => v + POR_PAGINA)}>
                      Mostrar más ({resultado.length - mostrados.length} restantes)
                    </Button>
                  </div>
                )}
              </>
            )}
          </>
        )}

        {/* Sin empresa Y sucursal no se abre: el alta necesita los dos ids. */}
        {empresa !== null && sucursal !== null && (
          <LoteFormDialog
            open={creando || editando !== null}
            lote={editando}
            idEmpresa={empresa.id}
            idSucursal={sucursal.id}
            articulosOpciones={articulosOpciones}
            cargandoArticulos={cargandoArticulos}
            onClose={() => {
              setCreando(false);
              setEditando(null);
            }}
          />
        )}

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar el lote?</AlertDialogTitle>
              <AlertDialogDescription>
                Se va a eliminar la partida de {aEliminar?.nombreArticulo}
                {aEliminar?.numeroLote !== null && aEliminar !== null
                  ? ` (lote ${aEliminar.numeroLote})`
                  : ""}
                . Esta acción no se puede deshacer.
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
  articulosOpciones,
  cargandoArticulos,
  onClose,
}: {
  open: boolean;
  /** `null` en el alta. */
  lote: Lote | null;
  idEmpresa: number;
  idSucursal: number;
  // `descripcion` admite undefined explícito y no sólo la ausencia de la clave:
  // el proyecto tiene `exactOptionalPropertyTypes`, y el `?? undefined` con el
  // que se arman las opciones produce la propiedad presente y en undefined.
  articulosOpciones: { valor: string; etiqueta: string; descripcion: string | undefined }[];
  cargandoArticulos: boolean;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = lote !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // `values` y no `defaultValues`: el mismo diálogo sirve para alta y edición,
    // y sin esto conserva los datos del lote anterior al reabrirse.
    values: {
      idArticulo: lote ? String(lote.idArticulo) : "",
      numeroLote: lote?.numeroLote != null ? String(lote.numeroLote) : "",
      cantidad: lote ? String(lote.cantidad) : "0",
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
        ...(v.costo ? { costo: Number(v.costo) } : {}),
        ...(v.fechaEntrada ? { fechaEntrada: v.fechaEntrada } : {}),
        ...(v.fechaVencimiento ? { fechaVencimiento: v.fechaVencimiento } : {}),
        ...(v.observaciones ? { observaciones: v.observaciones } : {}),
      };

      return esEdicion
        ? api.lotes.actualizar(lote.id, datos)
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
                      <Combobox
                        opciones={articulosOpciones}
                        value={field.value}
                        onChange={field.onChange}
                        placeholder="Elegí un artículo"
                        buscarPlaceholder="Buscar artículo…"
                        cargando={cargandoArticulos}
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
                    <FormLabel>Cantidad</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        inputMode="decimal"
                        placeholder="0"
                        autoComplete="off"
                        className="tabular-nums"
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />

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
