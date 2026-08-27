import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Eye, Loader2, Pencil, Plus, Search, Trash2, X } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { InputMoneda } from "@/components/ctell/InputMoneda";
import { SelectorModal } from "@/components/ctell/SelectorModal";
import { SelectorArticulo } from "@/components/ctell/SelectorArticulo";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, type FacturaCompra, type Iva } from "@/lib/api";
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
import { formatearMoneda, numeroMoneda } from "@/lib/moneda";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/** Cuántas filas se muestran de entrada, y cuántas suma cada "Mostrar más". */
const POR_PAGINA = 20;

/** Sólo la cabecera. El detalle NO va en el schema: ver `LineaDetalle`. */
const schema = z.object({
  idProveedor: z.string().min(1, "Elegí un proveedor"),
  numeroFactura: z.string().trim().min(1, "Obligatorio").max(50, "Máximo 50 caracteres"),
  fechaFactura: z
    .string()
    .trim()
    .regex(/^\d{4}-\d{2}-\d{2}$/, "Fecha inválida"),
  idMoneda: z.string().min(1, "Elegí una moneda"),
  tipoCambio: z
    .string()
    .trim()
    .refine((v) => v === "" || !Number.isNaN(Number(v)), "Tiene que ser un número")
    .refine((v) => v === "" || Number(v) > 0, "Tiene que ser mayor a cero"),
  // Opcional: una factura sin condición cargada es válida. Vacío significa
  // "sin condición", no un error.
  idCondicion: z.string(),
  observacion: z.string().trim().max(500, "Máximo 500 caracteres"),
});

type FormValues = z.infer<typeof schema>;

/**
 * Una línea del detalle **mientras se edita**.
 *
 * No vive en el schema de zod ni en react-hook-form: es una lista dinámica que
 * se agrega y se quita, y modelarla como campos del formulario obligaría a un
 * `useFieldArray` con nombres indexados para algo que se resuelve con un
 * `useState` y un array.
 *
 * Los importes son strings porque salen de inputs de texto — igual que en Lotes
 * y Artículos, para que un campo vacío no se convierta solo en 0.
 */
type LineaDetalle = {
  /** Sólo para el `key` de React: no viaja al backend. */
  clave: number;
  idArticulo: string;
  /** Nombre del artículo elegido, para mostrarlo en el selector sin re-buscarlo. */
  nombreArticulo: string;
  cantidad: string;
  precioUnitario: string;
  idIva: string;
};

/** Hoy en ISO de sólo día, para precargar la fecha. */
function hoyISO(): string {
  const hoy = new Date();
  const mes = String(hoy.getMonth() + 1).padStart(2, "0");
  const dia = String(hoy.getDate()).padStart(2, "0");
  return `${hoy.getFullYear()}-${mes}-${dia}`;
}

/** "2026-08-19" → "19 ago 2026". */
function formatearFecha(valor: string): string {
  // Se parsea a mano en vez de con `new Date("2026-08-19")`: ese formato lo
  // interpreta como UTC, y al mostrarlo en una zona al oeste retrocede un día.
  const [anio, mes, dia] = valor.split("-").map(Number);
  if (!anio || !mes || !dia) return valor;
  return new Intl.DateTimeFormat("es-PY", { dateStyle: "medium" }).format(
    new Date(anio, mes - 1, dia),
  );
}

/**
 * El impuesto **contenido** en un monto que ya lo incluye.
 *
 * Replica exactamente el cálculo del backend, incluidos los redondeos: si no
 * coincidieran, el total que se ve al cargar diferiría del que muestra la
 * factura ya guardada, y esa diferencia de un guaraní es imposible de explicar.
 *
 * **Con `gravadaDivision`** (el método actual): se divide para obtener el
 * gravado y el IVA sale por resta, así `gravado + iva` da el subtotal exacto.
 *
 * **Sin ella** (tasas anteriores a esa columna): se cae al método viejo, el IVA
 * por división. Se mantiene para que las facturas cargadas antes sigan
 * mostrando lo mismo.
 *
 * Nunca `monto * porcentaje / 100`: eso cobraría impuesto sobre impuesto —
 * 110.000 al 10% contiene 10.000, no 11.000.
 */
function ivaContenido(monto: number, tasa: Iva | undefined): number {
  if (!tasa) return 0;

  if (tasa.gravadaDivision !== null && tasa.gravadaDivision > 0) {
    // ROUND a 2 decimales, igual que el SQL: sin esto la vista previa y lo
    // guardado difieren en centésimas.
    const gravado = Math.round((monto / tasa.gravadaDivision) * 100) / 100;
    return monto - gravado;
  }

  // La exenta tiene `ivaDivision = 0`: sin la guarda, la división daría
  // `Infinity` y el total se rompería en pantalla.
  if (!tasa.ivaDivision || tasa.ivaDivision <= 0) return 0;
  return Math.round((monto / tasa.ivaDivision) * 100) / 100;
}

/**
 * Facturas de compra: cabecera y detalle.
 *
 * ES LA PRIMERA PANTALLA TRANSACCIONAL del proyecto, y por eso se sale del molde
 * de las anteriores en dos cosas:
 *
 * 1. El formulario tiene DOS partes —cabecera y líneas— que se guardan juntas en
 *    un solo request. Las líneas se editan en memoria y viajan como array.
 * 2. Hay un diálogo de sólo lectura para VER una factura, porque el listado no
 *    trae el detalle: pedirlo entero para dibujar una tabla de encabezados sería
 *    traerse todo el libro de compras en cada carga.
 *
 * Cuelga de empresa y sucursal, las dos de los providers.
 */
function FacturasComprasPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<FacturaCompra | null>(null);
  const [creando, setCreando] = useState(false);
  const [viendo, setViendo] = useState<FacturaCompra | null>(null);
  const [aEliminar, setAEliminar] = useState<FacturaCompra | null>(null);
  const [filtroProveedor, setFiltroProveedor] = useState<string>(SIN_FILTRO);
  const [filtroCondicion, setFiltroCondicion] = useState<string>(SIN_FILTRO);
  const [visibles, setVisibles] = useState(POR_PAGINA);

  const { empresa } = useEmpresa();
  const { sucursal, cargando: cargandoSucursal } = useSucursal();

  // Las dos entran en la queryKey: al cambiar cualquiera, TanStack Query trata
  // el listado como otra consulta en vez de mostrar en caché el de la anterior.
  const { data, isPending, isError } = useQuery({
    queryKey: ["facturas-compras", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => api.facturasCompras.listar({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
    enabled: empresa !== null && sucursal !== null,
  });

  const items = data?.items ?? [];

  /**
   * Las opciones de los dos filtros salen del PROPIO LISTADO, no de las tablas
   * de proveedores y condiciones.
   *
   * Es distinto de lo que hace Artículos —que pide las categorías aparte— y
   * acá es lo correcto: el padrón de personas puede tener cientos de nombres y
   * sólo unos pocos facturaron en esta sucursal. Ofrecer los demás daría
   * opciones que siempre devuelven cero facturas.
   *
   * Se ordenan alfabéticamente porque el orden en que aparecen en el listado
   * —por fecha— no significa nada en un desplegable.
   */
  const proveedoresOpciones = Array.from(
    new Map(items.map((f) => [String(f.idProveedor), f.proveedor])).entries(),
  )
    .map(([valor, etiqueta]) => ({ valor, etiqueta }))
    .sort((a, b) => a.etiqueta.localeCompare(b.etiqueta, "es"));

  const condicionesOpciones = Array.from(
    new Map(
      items
        // Las facturas sin condición no aportan una opción: para esas está la
        // entrada "Sin condición" de abajo.
        .filter((f) => f.idCondicion !== null && f.condicionPago !== null)
        .map((f) => [String(f.idCondicion), f.condicionPago!]),
    ).entries(),
  )
    .map(([valor, etiqueta]) => ({ valor, etiqueta }))
    .sort((a, b) => a.etiqueta.localeCompare(b.etiqueta, "es"));

  // "Sin condición" como opción propia: son las facturas que no tienen plazo
  // cargado, y encontrarlas para completarlas es un caso real. Sin esta entrada
  // no habría forma de aislarlas.
  const hayFacturasSinCondicion = items.some((f) => f.idCondicion === null);
  const SIN_CONDICION = "__sin_condicion__";

  const filtrados = items.filter((f) => {
    if (filtroProveedor !== SIN_FILTRO && String(f.idProveedor) !== filtroProveedor) return false;
    if (filtroCondicion === SIN_FILTRO) return true;
    if (filtroCondicion === SIN_CONDICION) return f.idCondicion === null;
    return String(f.idCondicion) === filtroCondicion;
  });

  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    filtrados,
    (f) => [
      f.numeroFactura,
      f.proveedor,
      f.rucProveedor,
      f.observacion,
      f.condicionPago,
      formatearFecha(f.fechaFactura),
    ],
  );

  const mostrados = resultado.slice(0, visibles);

  // Se resetea al cambiar filtros o búsqueda: seguir en "80 de 90" después de
  // filtrar a 12 resultados mostraría todo de golpe. Ajuste en render, no
  // useEffect: React re-renderiza antes de pintar.
  const claveVista = `${filtroProveedor}|${filtroCondicion}|${termino}`;
  const [claveAnterior, setClaveAnterior] = useState(claveVista);
  if (claveVista !== claveAnterior) {
    setClaveAnterior(claveVista);
    setVisibles(POR_PAGINA);
  }

  const hayFiltro =
    termino !== "" || filtroProveedor !== SIN_FILTRO || filtroCondicion !== SIN_FILTRO;

  const eliminar = useMutation({
    mutationFn: (factura: FacturaCompra) =>
      api.facturasCompras.eliminar(factura.id, factura.idEmpresa),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["facturas-compras"] });
      toast.success("Factura eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar la factura"));
      setAEliminar(null);
    },
  });

  // Sin sucursal no hay dónde cargar ni qué listar.
  const sinSucursal = !cargandoSucursal && sucursal === null;

  // El total de lo que se está viendo, que es la pregunta que justifica mirar
  // esta pantalla: cuánto se compró en el período filtrado.
  const totalListado = resultado.reduce((suma, f) => suma + f.total, 0);

  return (
    <AppLayout active="/facturas-compras" title="Facturas de compra">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Facturas de compra</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Comprobantes recibidos de proveedores
              {sucursal ? ` en ${sucursal.nombreSucursal}` : ""}.
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={sucursal === null}>
            <Plus className="size-4" />
            Nueva factura
          </Button>
        </div>

        {sinSucursal ? (
          <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
            La empresa no tiene sucursales activas. Cargá una sucursal antes de registrar facturas.
          </p>
        ) : (
          <>
            <div className="relative max-w-sm">
              <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={busqueda}
                onChange={(e) => setBusqueda(e.target.value)}
                placeholder="Buscar por número, proveedor o RUC…"
                className="pl-9"
                aria-label="Buscar facturas"
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
                No se pudieron cargar las facturas.
              </p>
            ) : resultado.length === 0 ? (
              <div className="surface-card px-3 py-16 text-center">
                <p className="text-sm text-muted-foreground">
                  {hayFiltro
                    ? "Ninguna factura coincide con los filtros."
                    : "Todavía no hay facturas cargadas en esta sucursal."}
                </p>
                {!hayFiltro && (
                  <Button className="mt-4" onClick={() => setCreando(true)}>
                    Cargar la primera
                  </Button>
                )}
              </div>
            ) : (
              <>
                {/* Móvil: tarjetas. Una tabla de 6 columnas en 360px obliga a
                    scrollear de costado para leer una fila entera. */}
                <ul className="space-y-3 sm:hidden">
                  {mostrados.map((factura) => (
                    <li key={factura.id} className="surface-card p-4">
                      <div className="flex items-start justify-between gap-3">
                        <div className="min-w-0 flex-1">
                          <p className="truncate font-semibold text-foreground">
                            {factura.proveedor}
                          </p>
                          <p className="mt-0.5 text-xs text-muted-foreground">
                            N° {factura.numeroFactura} · {formatearFecha(factura.fechaFactura)}
                          </p>
                        </div>
                        <p className="shrink-0 text-right font-semibold tabular-nums text-foreground">
                          {factura.simboloMoneda ? `${factura.simboloMoneda} ` : ""}
                          {formatearMoneda(factura.total)}
                        </p>
                      </div>

                      <p className="mt-2 text-xs text-muted-foreground">
                        {factura.lineas} línea{factura.lineas === 1 ? "" : "s"}
                        {factura.condicionPago ? ` · ${factura.condicionPago}` : ""}
                        {factura.fechaVencimiento
                          ? ` · vence ${formatearFecha(factura.fechaVencimiento)}`
                          : ""}
                      </p>

                      <div className="mt-3 space-y-2 border-t border-border pt-3">
                        <Button
                          variant="outline"
                          size="sm"
                          className="w-full"
                          onClick={() => setViendo(factura)}
                        >
                          <Eye className="size-4" />
                          Ver detalle
                        </Button>
                        <div className="flex gap-2">
                          <Button
                            variant="outline"
                            size="sm"
                            className="flex-1"
                            onClick={() => setEditando(factura)}
                          >
                            <Pencil className="size-4" />
                            Editar
                          </Button>
                          <Button
                            variant="outline"
                            size="sm"
                            className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                            onClick={() => setAEliminar(factura)}
                          >
                            <Trash2 className="size-4" />
                            Eliminar
                          </Button>
                        </div>
                      </div>
                    </li>
                  ))}
                </ul>

                <div className="surface-card hidden overflow-x-auto sm:block">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "fechaFactura" ? orden.direccion : null}
                          onClick={() => alternarOrden("fechaFactura")}
                        >
                          Fecha
                        </TableHeadOrdenable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "numeroFactura" ? orden.direccion : null}
                          onClick={() => alternarOrden("numeroFactura")}
                        >
                          Número
                        </TableHeadOrdenable>
                        <TableHeadFiltrable
                          direccion={orden?.campo === "proveedor" ? orden.direccion : null}
                          onOrdenar={() => alternarOrden("proveedor")}
                          opciones={proveedoresOpciones}
                          valor={filtroProveedor}
                          onFiltrar={setFiltroProveedor}
                          buscarPlaceholder="Buscar proveedor…"
                        >
                          Proveedor
                        </TableHeadFiltrable>
                        <TableHeadFiltrable
                          direccion={orden?.campo === "condicionPago" ? orden.direccion : null}
                          onOrdenar={() => alternarOrden("condicionPago")}
                          opciones={
                            hayFacturasSinCondicion
                              ? [
                                  ...condicionesOpciones,
                                  { valor: SIN_CONDICION, etiqueta: "Sin condición" },
                                ]
                              : condicionesOpciones
                          }
                          valor={filtroCondicion}
                          onFiltrar={setFiltroCondicion}
                          buscarPlaceholder="Buscar condición…"
                        >
                          Condición
                        </TableHeadFiltrable>
                        <TableHead className="text-right">Líneas</TableHead>
                        <TableHead className="text-right">Total</TableHead>
                        <TableHead className="text-right">Acciones</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {mostrados.map((factura) => (
                        <TableRow key={factura.id}>
                          <TableCell className="text-muted-foreground">
                            {formatearFecha(factura.fechaFactura)}
                            {/* El vencimiento debajo de la fecha y no en columna
                                propia: sólo lo tienen las facturas con condición
                                cargada, y una columna vacía en la mitad de las
                                filas no paga su ancho. */}
                            {factura.fechaVencimiento && (
                              <span className="block text-xs">
                                Vence {formatearFecha(factura.fechaVencimiento)}
                              </span>
                            )}
                          </TableCell>
                          <TableCell className="font-medium text-foreground">
                            {factura.numeroFactura}
                          </TableCell>
                          <TableCell>
                            {factura.proveedor}
                            {factura.rucProveedor && (
                              <span className="block text-xs text-muted-foreground">
                                RUC {factura.rucProveedor}
                              </span>
                            )}
                          </TableCell>
                          <TableCell className="text-muted-foreground">
                            {factura.condicionPago ?? "—"}
                          </TableCell>
                          <TableCell className="text-right tabular-nums text-muted-foreground">
                            {factura.lineas}
                          </TableCell>
                          <TableCell className="text-right font-semibold tabular-nums">
                            {factura.simboloMoneda ? `${factura.simboloMoneda} ` : ""}
                            {formatearMoneda(factura.total)}
                          </TableCell>
                          <TableCell className="text-right">
                            <div className="flex justify-end gap-1">
                              <Button
                                variant="ghost"
                                size="icon"
                                title="Ver detalle"
                                aria-label={`Ver la factura ${factura.numeroFactura}`}
                                onClick={() => setViendo(factura)}
                              >
                                <Eye className="size-4" />
                              </Button>
                              <Button
                                variant="ghost"
                                size="icon"
                                title="Editar"
                                aria-label={`Editar la factura ${factura.numeroFactura}`}
                                onClick={() => setEditando(factura)}
                              >
                                <Pencil className="size-4" />
                              </Button>
                              <Button
                                variant="ghost"
                                size="icon"
                                title="Eliminar"
                                aria-label={`Eliminar la factura ${factura.numeroFactura}`}
                                onClick={() => setAEliminar(factura)}
                              >
                                <Trash2 className="size-4 text-destructive" />
                              </Button>
                            </div>
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>

                {resultado.length > mostrados.length && (
                  <div className="flex justify-center">
                    <Button variant="outline" onClick={() => setVisibles((v) => v + POR_PAGINA)}>
                      Mostrar {Math.min(resultado.length - mostrados.length, POR_PAGINA)} más
                    </Button>
                  </div>
                )}

                {/* El total de lo filtrado, no sólo de lo visible: "mostrando 20
                    de 50" con el total de esas 20 sería un número que no
                    responde ninguna pregunta. */}
                <p className="text-center text-xs text-muted-foreground">
                  Mostrando {mostrados.length} de {resultado.length} factura
                  {resultado.length === 1 ? "" : "s"} · Total {formatearMoneda(totalListado)}
                  {hayFiltro ? ` (${items.length} en total)` : ""}
                </p>
              </>
            )}
          </>
        )}

        {/* Sin empresa ni sucursal no se abre: el alta necesita los dos ids. */}
        {empresa !== null && sucursal !== null && (
          <FacturaFormDialog
            open={creando || editando !== null}
            factura={editando}
            idEmpresa={empresa.id}
            idSucursal={sucursal.id}
            onClose={() => {
              setCreando(false);
              setEditando(null);
            }}
          />
        )}

        <FacturaVerDialog
          factura={viendo}
          onOpenChange={(abierto) => !abierto && setViendo(null)}
        />

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar la factura {aEliminar?.numeroFactura}?</AlertDialogTitle>
              <AlertDialogDescription>
                Se borran también sus {aEliminar?.lineas} línea
                {aEliminar?.lineas === 1 ? "" : "s"} de detalle. No se puede deshacer.
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
                className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
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

/* -------------------------------------------------------------------------- */
/* Ver una factura (solo lectura)                                              */
/* -------------------------------------------------------------------------- */

/**
 * El detalle de una factura, sin poder editarlo.
 *
 * Existe porque el listado NO trae las líneas: se piden acá, al abrir. Es el
 * mismo criterio que `ArticuloUbicacionesDialog` — un diálogo sobre la fila en
 * vez de una ruta propia, porque siempre se mira "el detalle de ESTA factura".
 */
function FacturaVerDialog({
  factura,
  onOpenChange,
}: {
  factura: FacturaCompra | null;
  onOpenChange: (abierto: boolean) => void;
}) {
  const { data, isPending } = useQuery({
    queryKey: ["factura-compra", factura?.id ?? null],
    queryFn: () => api.facturasCompras.obtener(factura!.id, factura!.idEmpresa),
    enabled: factura !== null,
  });

  const simbolo = factura?.simboloMoneda ? `${factura.simboloMoneda} ` : "";

  return (
    <Dialog open={factura !== null} onOpenChange={onOpenChange}>
      <DialogContent className="scrollbar-fino max-h-[92vh] overflow-y-auto sm:max-w-3xl">
        <DialogHeader>
          <DialogTitle>Factura {factura?.numeroFactura}</DialogTitle>
          <DialogDescription>
            {factura?.proveedor}
            {factura ? ` · ${formatearFecha(factura.fechaFactura)}` : ""}
            {/* La condición y el vencimiento acá arriba: es lo primero que se
                pregunta al abrir una factura de compra, antes que el detalle. */}
            {factura?.condicionPago ? ` · ${factura.condicionPago}` : ""}
            {factura?.fechaVencimiento
              ? ` · vence ${formatearFecha(factura.fechaVencimiento)}`
              : ""}
          </DialogDescription>
        </DialogHeader>

        {isPending ? (
          <div className="space-y-2">
            {[0, 1, 2].map((i) => (
              <Skeleton key={i} className="h-10 w-full" />
            ))}
          </div>
        ) : !data ? (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
            No se pudo cargar el detalle.
          </p>
        ) : (
          <>
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Artículo</TableHead>
                    <TableHead className="text-right">Cant.</TableHead>
                    <TableHead className="text-right">Precio</TableHead>
                    <TableHead className="text-right">IVA</TableHead>
                    <TableHead className="text-right">Subtotal</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {data.detalle.map((linea) => (
                    <TableRow key={linea.id}>
                      <TableCell className="font-medium text-foreground">
                        {linea.nombreArticulo}
                        {linea.codigoArticulo && (
                          <span className="block text-xs font-normal text-muted-foreground">
                            {linea.codigoArticulo}
                          </span>
                        )}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">{linea.cantidad}</TableCell>
                      <TableCell className="text-right tabular-nums">
                        {formatearMoneda(linea.precioUnitario)}
                      </TableCell>
                      <TableCell className="text-right tabular-nums text-muted-foreground">
                        {linea.porcentajeIva === null ? "—" : `${linea.porcentajeIva}%`}
                      </TableCell>
                      <TableCell className="text-right font-medium tabular-nums">
                        {formatearMoneda(linea.subtotal)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>

            {/* EL DESGLOSE, no una suma más: los precios ya incluyen IVA, así
                que gravado + IVA = total. Es lo que va al libro de compras. */}
            <dl className="space-y-1 border-t border-border pt-3 text-sm">
              <div className="flex justify-between text-muted-foreground">
                <dt>Gravado</dt>
                <dd className="tabular-nums">
                  {simbolo}
                  {formatearMoneda(data.totalGravado)}
                </dd>
              </div>
              <div className="flex justify-between text-muted-foreground">
                <dt>IVA incluido</dt>
                <dd className="tabular-nums">
                  {simbolo}
                  {formatearMoneda(data.totalIva)}
                </dd>
              </div>
              <div className="flex justify-between text-base font-semibold text-foreground">
                <dt>Total</dt>
                <dd className="tabular-nums">
                  {simbolo}
                  {formatearMoneda(data.total)}
                </dd>
              </div>
            </dl>

            {data.observacion && (
              <p className="rounded-lg border border-border bg-muted px-3 py-2 text-sm text-muted-foreground">
                {data.observacion}
              </p>
            )}
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}

/* -------------------------------------------------------------------------- */
/* Formulario                                                                  */
/* -------------------------------------------------------------------------- */

function FacturaFormDialog({
  open,
  factura,
  idEmpresa,
  idSucursal,
  onClose,
}: {
  open: boolean;
  factura: FacturaCompra | null;
  idEmpresa: number;
  idSucursal: number;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = factura !== null;

  // Las líneas viven fuera de react-hook-form: ver el comentario de LineaDetalle.
  const [lineas, setLineas] = useState<LineaDetalle[]>([]);
  // Contador para las claves de React. No es el índice del array: al borrar una
  // línea del medio, los índices se corren y React reusaría el estado del input
  // equivocado.
  const [proximaClave, setProximaClave] = useState(1);

  const { data: personas } = useQuery({
    queryKey: ["personas"],
    queryFn: () => api.personas.listar(),
  });

  const { data: monedas } = useQuery({
    queryKey: ["monedas", idEmpresa],
    queryFn: () => api.monedas.listar({ idEmpresa }),
  });

  // No se consultan los artículos acá: cada línea del detalle usa
  // SelectorArticulo, que va contra el endpoint paginado por su cuenta. Traer
  // una lista completa para el formulario era imposible desde que ese listado
  // devuelve 20 filas.

  const { data: tasasIva } = useQuery({
    queryKey: ["iva"],
    queryFn: () => api.iva.listar(),
    // Las tasas no cambian nunca: se cachean por toda la sesión en vez de
    // pedirlas cada vez que se abre el formulario.
    staleTime: Infinity,
  });

  // Misma queryKey que la página de Condiciones de pago, así se comparte la
  // respuesta en vez de pedirla de nuevo.
  const { data: condiciones, isPending: cargandoCondiciones } = useQuery({
    queryKey: ["condiciones-pago"],
    queryFn: () => api.condicionesPago.listar(),
  });

  // El detalle de la factura que se está editando. Sólo se pide en edición: en
  // un alta no hay nada que traer.
  const { data: completa } = useQuery({
    queryKey: ["factura-compra", factura?.id ?? null],
    queryFn: () => api.facturasCompras.obtener(factura!.id, factura!.idEmpresa),
    enabled: factura !== null,
  });

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    values: {
      idProveedor: factura ? String(factura.idProveedor) : "",
      numeroFactura: factura?.numeroFactura ?? "",
      fechaFactura: factura?.fechaFactura ?? hoyISO(),
      idMoneda: factura ? String(factura.idMoneda) : "",
      tipoCambio: factura ? String(factura.tipoCambio) : "1",
      idCondicion: factura?.idCondicion ? String(factura.idCondicion) : "",
      observacion: factura?.observacion ?? "",
    },
  });

  /**
   * Carga las líneas cuando llega el detalle de la factura que se edita.
   *
   * Se compara contra el id ya cargado en vez de usar un `useEffect`: el efecto
   * correría después de pintar y la tabla parpadearía vacía por un frame. Este
   * ajuste en render lo evita — React re-renderiza antes de mostrar nada.
   */
  const [idCargado, setIdCargado] = useState<number | null>(null);
  if (completa && completa.id !== idCargado) {
    setIdCargado(completa.id);
    setLineas(
      completa.detalle.map((d, i) => ({
        clave: i + 1,
        idArticulo: String(d.idArticulo),
        nombreArticulo: d.nombreArticulo,
        cantidad: String(d.cantidad),
        precioUnitario: formatearMoneda(d.precioUnitario),
        idIva: d.idIva === null ? "" : String(d.idIva),
      })),
    );
    setProximaClave(completa.detalle.length + 1);
  }
  // Un alta arranca con una línea vacía, para no obligar a apretar "Agregar"
  // antes de poder escribir nada.
  if (!esEdicion && idCargado !== null) {
    setIdCargado(null);
    setLineas([
      { clave: 1, idArticulo: "", nombreArticulo: "", cantidad: "", precioUnitario: "", idIva: "" },
    ]);
    setProximaClave(2);
  }
  if (!esEdicion && lineas.length === 0) {
    setLineas([
      { clave: 1, idArticulo: "", nombreArticulo: "", cantidad: "", precioUnitario: "", idIva: "" },
    ]);
    setProximaClave(2);
  }

  function agregarLinea() {
    setLineas((actuales) => [
      ...actuales,
      {
        clave: proximaClave,
        idArticulo: "",
        nombreArticulo: "",
        cantidad: "",
        precioUnitario: "",
        idIva: "",
      },
    ]);
    setProximaClave((c) => c + 1);
  }

  function quitarLinea(clave: number) {
    setLineas((actuales) => actuales.filter((l) => l.clave !== clave));
  }

  function cambiarLinea(clave: number, campo: keyof Omit<LineaDetalle, "clave">, valor: string) {
    setLineas((actuales) =>
      actuales.map((l) => (l.clave === clave ? { ...l, [campo]: valor } : l)),
    );
  }

  const personasOpciones = (personas?.items ?? []).map((p) => ({
    valor: String(p.id),
    etiqueta: p.nombreCompleto,
    descripcion: p.ruc ?? p.numeroCi ?? undefined,
  }));

  const condicionesOpciones = (condiciones?.items ?? []).map((c) => ({
    valor: String(c.id),
    etiqueta: c.nombreCondicion,
    // El plazo como descripción: el nombre solo puede no decir a cuántos días
    // es, y esa es justamente la información que se busca al elegir.
    descripcion: c.diasPago === 0 ? "Contado" : `${c.diasPago} días`,
  }));

  const monedasOpciones = (monedas?.items ?? []).map((m) => ({
    valor: String(m.id),
    etiqueta: m.nombreMoneda,
    descripcion: m.simbolo ?? undefined,
  }));

  const ivaPorId = new Map<string, Iva>((tasasIva?.items ?? []).map((i) => [String(i.id), i]));

  /**
   * Los totales en vivo, mientras se carga.
   *
   * Se calculan acá y no se piden al backend por una razón práctica: quien carga
   * una factura ya tiene el papel adelante con su total impreso, y ver si cuadra
   * ANTES de guardar es lo que evita cargarla mal.
   *
   * La fórmula es la misma que usa el SQL — el IVA se DIVIDE, no se multiplica.
   */
  const totales = lineas.reduce(
    (acumulado, linea) => {
      const cantidad = Number(linea.cantidad);
      const precio = numeroMoneda(linea.precioUnitario);
      if (Number.isNaN(cantidad) || Number.isNaN(precio)) return acumulado;

      const subtotal = cantidad * precio;
      const iva = ivaContenido(subtotal, ivaPorId.get(linea.idIva));

      return { total: acumulado.total + subtotal, iva: acumulado.iva + iva };
    },
    { total: 0, iva: 0 },
  );

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      // Las líneas incompletas se descartan en vez de mandarse: la última suele
      // quedar vacía porque se agregó y no se completó, y mandarla daría un 400
      // por algo que el usuario no considera parte de la factura.
      const detalle = lineas
        .filter((l) => l.idArticulo !== "" && l.cantidad !== "" && l.precioUnitario !== "")
        .map((l) => ({
          idArticulo: Number(l.idArticulo),
          cantidad: Number(l.cantidad),
          precioUnitario: numeroMoneda(l.precioUnitario),
          ...(l.idIva ? { idIva: Number(l.idIva) } : {}),
        }));

      const cabecera = {
        idProveedor: Number(v.idProveedor),
        numeroFactura: v.numeroFactura,
        fechaFactura: v.fechaFactura,
        idMoneda: Number(v.idMoneda),
        tipoCambio: v.tipoCambio ? Number(v.tipoCambio) : 1,
        // Vacío se omite: el backend trata lo ausente como "no cambiar". Ojo,
        // eso significa que no hay forma de QUITARLE la condición a una factura
        // que ya la tiene — habría que anularla y cargarla de nuevo.
        ...(v.idCondicion ? { idCondicion: Number(v.idCondicion) } : {}),
        ...(v.observacion ? { observacion: v.observacion } : {}),
      };

      return esEdicion
        ? api.facturasCompras.actualizar(factura.id, {
            idEmpresa,
            idSucursal,
            ...cabecera,
            detalle,
          })
        : api.facturasCompras.crear({ idEmpresa, idSucursal, ...cabecera, detalle });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["facturas-compras"] });
      // También el detalle: si se editó, el diálogo de ver tiene la versión
      // vieja en caché.
      queryClient.invalidateQueries({ queryKey: ["factura-compra"] });
      toast.success(esEdicion ? "Factura actualizada" : "Factura registrada");
      onClose();
    },
    onError: (e) =>
      toast.error(MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo registrar")),
  });

  // Cuántas líneas están completas. Se valida acá y no en zod porque el detalle
  // no vive en el formulario: sin esto, guardar una factura sin líneas gastaría
  // un viaje a la red para recibir el 400 del backend.
  const lineasValidas = lineas.filter(
    (l) => l.idArticulo !== "" && l.cantidad !== "" && l.precioUnitario !== "",
  ).length;

  const simbolo =
    monedasOpciones.find((m) => m.valor === form.watch("idMoneda"))?.descripcion ?? "";

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      {/* ANCHO DE ERP: el detalle es una tabla de cinco columnas, y en un
          diálogo angosto cada línea se apila y deja de leerse como una fila. */}
      <DialogContent className="scrollbar-fino max-h-[92vh] overflow-y-auto sm:max-w-4xl">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar factura" : "Nueva factura de compra"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá la factura. Las líneas se reemplazan por completo al guardar."
              : "Cargá el comprobante recibido del proveedor. No mueve stock: el ingreso al depósito se registra en Lotes."}
          </DialogDescription>
        </DialogHeader>
        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            {/* CABECERA — de quién es la factura, con qué número y cómo se paga.

                A TRES COLUMNAS Y SIN TÍTULO DE SECCIÓN: son seis campos que en
                dos columnas ocupaban cuatro filas y empujaban el detalle fuera
                de la pantalla. Con tres entran en dos filas, y el detalle —que
                es la parte larga y la que se completa mirando el papel— queda
                visible sin scrollear.

                Las descripciones salieron por lo mismo: cada una sumaba una
                línea de alto por campo. Lo que decían quedó en el placeholder
                o en el label, que es donde igual se lee. */}
            <section>
              <div className="grid gap-3 sm:grid-cols-3">
                <FormField
                  control={form.control}
                  name="idProveedor"
                  render={({ field }) => (
                    <FormItem className="sm:col-span-2">
                      <FormLabel>Proveedor</FormLabel>
                      <FormControl>
                        <SelectorModal
                          opciones={personasOpciones}
                          value={field.value}
                          onChange={field.onChange}
                          placeholder="Elegí el proveedor"
                          titulo="Elegí el proveedor"
                          buscarPlaceholder="Buscar por nombre o RUC…"
                        />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <FormField
                  control={form.control}
                  name="fechaFactura"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Fecha</FormLabel>
                      <FormControl>
                        <Input {...field} type="date" />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <FormField
                  control={form.control}
                  name="numeroFactura"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Número</FormLabel>
                      <FormControl>
                        <Input {...field} placeholder="001-001-0001234" autoComplete="off" />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                {/* Moneda y tipo de cambio comparten celda: el segundo sólo
                    tiene sentido junto al primero, y separados gastaban dos
                    columnas para un campo que casi siempre vale 1. */}
                <FormField
                  control={form.control}
                  name="idMoneda"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Moneda</FormLabel>
                      <div className="flex gap-2">
                        <FormControl>
                          <div className="min-w-0 flex-1">
                            <SelectorModal
                              opciones={monedasOpciones}
                              value={field.value}
                              onChange={field.onChange}
                              placeholder="Moneda"
                              titulo="Elegí una moneda"
                              buscarPlaceholder="Buscar moneda…"
                            />
                          </div>
                        </FormControl>
                        <Input
                          {...form.register("tipoCambio")}
                          inputMode="decimal"
                          placeholder="1"
                          autoComplete="off"
                          aria-label="Tipo de cambio"
                          title="Tipo de cambio (1 si es la moneda local)"
                          className="w-20 shrink-0 tabular-nums"
                        />
                      </div>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <FormField
                  control={form.control}
                  name="idCondicion"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Condición de pago</FormLabel>
                      <FormControl>
                        <SelectorModal
                          opciones={condicionesOpciones}
                          value={field.value}
                          onChange={field.onChange}
                          placeholder="Sin condición"
                          titulo="Elegí la condición de pago"
                          buscarPlaceholder="Buscar condición…"
                          cargando={cargandoCondiciones}
                        />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
              </div>
            </section>

            {/* DETALLE — la parte que hace de esto una transacción y no una
                ficha. Se edita en memoria y viaja entera al guardar. */}
            <section className="space-y-3">
              <div className="flex items-center justify-between">
                <h3 className="text-sm font-semibold text-foreground">Detalle</h3>
                <Button type="button" variant="outline" size="sm" onClick={agregarLinea}>
                  <Plus className="size-4" />
                  Agregar línea
                </Button>
              </div>

              {/* LAS ETIQUETAS, UNA SOLA VEZ. Antes cada línea repetía las
                  cuatro y sumaba una fila de alto por línea: con cinco
                  artículos eran cinco encabezados idénticos empujando el pie
                  fuera de la pantalla.

                  Se oculta en móvil, donde las líneas se apilan y cada campo sí
                  necesita su propia etiqueta para saber qué es. */}
              <div className="hidden gap-2 px-3 sm:grid sm:grid-cols-[2fr_1fr_1.2fr_1fr_auto]">
                <span className="text-xs text-muted-foreground">Artículo</span>
                <span className="text-xs text-muted-foreground">Cantidad</span>
                <span className="text-xs text-muted-foreground">Precio (con IVA)</span>
                <span className="text-xs text-muted-foreground">IVA</span>
                {/* Ancho fijo igual al de la celda de subtotal + botón, para que
                    la columna del encabezado caiga sobre la de las filas. */}
                <span className="w-24 text-right text-xs text-muted-foreground">Subtotal</span>
              </div>

              <div className="space-y-2">
                {lineas.map((linea) => {
                  const cantidad = Number(linea.cantidad);
                  const precio = numeroMoneda(linea.precioUnitario);
                  const subtotal =
                    Number.isNaN(cantidad) || Number.isNaN(precio) ? 0 : cantidad * precio;

                  return (
                    <div
                      key={linea.clave}
                      // Borde sólo en móvil, donde separa una línea de la siguiente. En
                      // escritorio las columnas ya alinean solas bajo el encabezado, y
                      // un recuadro por línea sumaba altura sin agregar información.
                      className="grid gap-2 rounded-lg border border-border p-3 sm:grid-cols-[2fr_1fr_1.2fr_1fr_auto] sm:items-center sm:rounded-none sm:border-0 sm:border-b sm:border-border/50 sm:py-1.5"
                    >
                      <div className="space-y-1 sm:space-y-0">
                        <label className="text-xs text-muted-foreground sm:hidden">Artículo</label>
                        <SelectorArticulo
                          idEmpresa={idEmpresa}
                          value={linea.idArticulo}
                          etiquetaSeleccionada={linea.nombreArticulo || undefined}
                          onChange={(v, etiqueta) => {
                            cambiarLinea(linea.clave, "idArticulo", v);
                            cambiarLinea(linea.clave, "nombreArticulo", etiqueta);
                          }}
                          placeholder="Elegí el artículo"
                        />
                      </div>

                      <div className="space-y-1 sm:space-y-0">
                        <label className="text-xs text-muted-foreground sm:hidden">Cantidad</label>
                        <Input
                          value={linea.cantidad}
                          onChange={(e) => cambiarLinea(linea.clave, "cantidad", e.target.value)}
                          inputMode="decimal"
                          placeholder="0"
                          className="tabular-nums"
                        />
                      </div>

                      <div className="space-y-1 sm:space-y-0">
                        <label className="text-xs text-muted-foreground sm:hidden">
                          Precio (con IVA)
                        </label>
                        <InputMoneda
                          value={linea.precioUnitario}
                          onChange={(valor) => cambiarLinea(linea.clave, "precioUnitario", valor)}
                          placeholder="0"
                        />
                      </div>

                      <div className="space-y-1 sm:space-y-0">
                        <label className="text-xs text-muted-foreground sm:hidden">IVA</label>
                        <SelectorModal
                          opciones={(tasasIva?.items ?? []).map((i) => ({
                            valor: String(i.id),
                            etiqueta: i.descripcion,
                          }))}
                          value={linea.idIva}
                          onChange={(v) => cambiarLinea(linea.clave, "idIva", v)}
                          placeholder="Sin IVA"
                          titulo="Elegí la tasa de IVA"
                          buscarPlaceholder="Buscar tasa…"
                        />
                      </div>

                      <div className="flex items-center justify-between gap-2 sm:flex-col sm:items-end">
                        <span className="text-sm font-medium tabular-nums text-foreground">
                          {formatearMoneda(subtotal)}
                        </span>
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon"
                          title="Quitar línea"
                          aria-label="Quitar esta línea"
                          onClick={() => quitarLinea(linea.clave)}
                          // La última no se puede quitar: una factura sin
                          // líneas no existe, y dejar la tabla vacía obligaría
                          // a apretar "Agregar" para volver a empezar.
                          disabled={lineas.length === 1}
                        >
                          <X className="size-4 text-destructive" />
                        </Button>
                      </div>
                    </div>
                  );
                })}
              </div>

              {lineasValidas === 0 && (
                <p className="text-sm text-destructive">
                  Cargá al menos una línea con artículo, cantidad y precio.
                </p>
              )}

              {/* LOS TOTALES EN VIVO: es lo que permite comparar contra el papel
                  antes de guardar, que es cuando todavía se puede corregir. */}
              {/* El mismo desglose que muestra el diálogo de ver, en el mismo
                  orden: gravado, IVA, total. Que las dos vistas coincidan es lo
                  que permite verificar de un vistazo que se guardó bien. */}
              <dl className="space-y-1 border-t border-border pt-3 text-sm">
                <div className="flex justify-between text-muted-foreground">
                  <dt>Gravado</dt>
                  <dd className="tabular-nums">
                    {simbolo} {formatearMoneda(totales.total - totales.iva)}
                  </dd>
                </div>
                <div className="flex justify-between text-muted-foreground">
                  <dt>IVA incluido</dt>
                  <dd className="tabular-nums">
                    {simbolo} {formatearMoneda(totales.iva)}
                  </dd>
                </div>
                <div className="flex justify-between text-base font-semibold text-foreground">
                  <dt>Total</dt>
                  <dd className="tabular-nums">
                    {simbolo} {formatearMoneda(totales.total)}
                  </dd>
                </div>
              </dl>
            </section>

            <FormField
              control={form.control}
              name="observacion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Observación</FormLabel>
                  <FormControl>
                    <Textarea
                      {...field}
                      rows={2}
                      placeholder="Nota de recepción, condición de pago…"
                      className="scrollbar-fino"
                    />
                  </FormControl>
                  <FormDescription>Opcional. Hasta 500 caracteres.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onClose}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending || lineasValidas === 0}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {guardar.isPending
                  ? "Guardando…"
                  : esEdicion
                    ? "Guardar cambios"
                    : "Registrar factura"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/facturas-compras")({
  head: () => ({
    meta: [
      { title: tituloPagina("Facturas de compra") },
      {
        name: "description",
        content: "Comprobantes de compra recibidos de proveedores, con su detalle.",
      },
    ],
  }),
  component: FacturasComprasPage,
});
