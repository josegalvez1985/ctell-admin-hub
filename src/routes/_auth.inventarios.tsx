import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Ban, CheckCircle2, Loader2, Pencil, Plus, Search } from "lucide-react";
import { useMemo, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { SelectorModal } from "@/components/ctell/SelectorModal";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import {
  api,
  ApiError,
  inventarioAbierto,
  type EstadoInventario,
  type Inventario,
  type Lote,
} from "@/lib/api";
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

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/** Cuántas filas se muestran de entrada, y cuántas suma cada "Mostrar más". */
const POR_PAGINA = 20;

/**
 * Igual que en Lotes: el `<input type="date">` entrega el string ya en ISO de
 * sólo día, y convertirlo a `Date` y de vuelta sólo agregaría zonas horarias que
 * acá no significan nada.
 */
const schema = z.object({
  idLote: z.string().min(1, "Elegí un lote"),
  // Obligatoria y numérica: un conteo sin número no es un conteo. El 0 sí es
  // válido —el lote se agotó— por eso no alcanza con `min(1)` sobre el texto.
  cantidadFisica: z
    .string()
    .trim()
    .min(1, "Obligatoria")
    .refine((v) => !Number.isNaN(Number(v)), "Tiene que ser un número")
    .refine((v) => Number(v) >= 0, "No puede ser negativa"),
  fechaInventario: z
    .string()
    .trim()
    .regex(/^\d{4}-\d{2}-\d{2}$/, "Fecha inválida")
    .or(z.literal("")),
  observaciones: z.string().trim().max(1000, "Máximo 1000 caracteres"),
});

type FormValues = z.infer<typeof schema>;

/** "2026-08-18T14:30:00" → "18 ago 2026". */
function formatearFecha(valor: string | null): string {
  if (!valor) return "—";
  const fecha = new Date(valor);
  if (Number.isNaN(fecha.getTime())) return valor;
  return new Intl.DateTimeFormat("es-PY", { dateStyle: "medium" }).format(fecha);
}

/** Hoy en ISO de sólo día, para precargar la fecha del conteo. */
function hoyISO(): string {
  const hoy = new Date();
  const mes = String(hoy.getMonth() + 1).padStart(2, "0");
  const dia = String(hoy.getDate()).padStart(2, "0");
  return `${hoy.getFullYear()}-${mes}-${dia}`;
}

/**
 * Cómo se pinta cada estado.
 *
 * El procesado va en `secondary` y no en algo más llamativo a propósito: es el
 * final feliz y esperado, y resaltarlo le quitaría contraste al abierto, que es
 * el único que pide una acción de quien mira la pantalla.
 */
const ESTILO_ESTADO: Record<
  EstadoInventario,
  { texto: string; variante: "default" | "secondary" | "outline" }
> = {
  ABIERTO: { texto: "Abierto", variante: "default" },
  PROCESADO: { texto: "Procesado", variante: "secondary" },
  ANULADO: { texto: "Anulado", variante: "outline" },
};

/**
 * La diferencia entre lo contado y lo que decía el sistema, con su color.
 *
 * Es el dato que justifica mirar esta tabla: un cero se lee como "todo en orden"
 * y no necesita destacarse, mientras que cualquier otro número es un faltante o
 * un sobrante que alguien tiene que explicar.
 */
function textoDiferencia(diferencia: number): { texto: string; clase: string } {
  if (diferencia === 0) return { texto: "0", clase: "text-muted-foreground" };
  // El signo explícito en el positivo: "+3" se lee como sobrante de un vistazo,
  // "3" a secas obliga a compararlo mentalmente contra la columna de al lado.
  const texto = diferencia > 0 ? `+${diferencia}` : String(diferencia);
  return { texto, clase: "font-semibold text-destructive" };
}

/**
 * Inventarios: los conteos físicos de stock, uno por lote.
 *
 * Cuelga de empresa y sucursal —las dos salen de los providers— y de un lote,
 * que se elige en el formulario porque es el dato que da sentido al conteo.
 *
 * SE PARECE A UN ABM PERO NO LO ES. Las tablas anteriores tienen editar y
 * eliminar en todas las filas; acá lo que se puede hacer depende del estado:
 *
 *   ABIERTO    corregir, procesar o anular.
 *   PROCESADO  nada. Ya se aplicó al lote.
 *   ANULADO    nada. Se descartó.
 *
 * Y no hay eliminar en ninguno: un conteo es evidencia de que alguien fue al
 * depósito y contó. La base directamente prohíbe el DELETE.
 */
function InventariosPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Inventario | null>(null);
  const [creando, setCreando] = useState(false);
  const [aProcesar, setAProcesar] = useState<Inventario | null>(null);
  const [aAnular, setAAnular] = useState<Inventario | null>(null);
  const [filtroEstado, setFiltroEstado] = useState<string>(SIN_FILTRO);
  const [visibles, setVisibles] = useState(POR_PAGINA);

  const { empresa } = useEmpresa();
  const { sucursal, cargando: cargandoSucursal } = useSucursal();

  // Las dos entran en la queryKey: al cambiar cualquiera, TanStack Query trata
  // el listado como otra consulta en vez de mostrar en caché el de la anterior.
  const { data, isPending, isError } = useQuery({
    queryKey: ["inventarios", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => api.inventarios.listar({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
    // Los providers hidratan después de montar: sin esto la primera petición
    // saldría sin filtros y traería los conteos de todas las sucursales.
    enabled: empresa !== null && sucursal !== null,
  });

  // Los lotes alimentan el formulario. Misma queryKey que usa la página de
  // Lotes, así se comparte la respuesta en vez de pedirla de nuevo.
  const { data: lotes, isPending: cargandoLotes } = useQuery({
    queryKey: ["lotes", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => api.lotes.listar({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
    enabled: empresa !== null && sucursal !== null,
  });

  const items = data?.items ?? [];

  // El endpoint acepta ?estado=, pero el filtro se aplica en el cliente: el
  // listado ya vino entero, así que cambiar de estado es instantáneo.
  const filtrados = items.filter((i) => filtroEstado === SIN_FILTRO || i.estado === filtroEstado);

  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    filtrados,
    (i) => [
      i.nombreArticulo,
      i.codigoArticulo,
      i.numeroLote === null ? "Sin número" : String(i.numeroLote),
      i.observaciones,
      // Los dos: se busca tanto por "jgalvez" como por "Jose Galvez".
      i.usuarioProcesa,
      i.nombreProcesa,
      ESTILO_ESTADO[i.estado].texto,
      // El texto que se ve, no el ISO: en pantalla dice "18 ago 2026".
      formatearFecha(i.fechaInventario),
    ],
  );

  /**
   * `useTablaListado` ordena con `localeCompare` sobre texto, y tres columnas de
   * acá son numéricas: como texto, una diferencia de 10 iría antes que la de 2 —
   * y peor, -5 quedaría entre medio en vez de en un extremo.
   */
  const mostrados = useMemo(() => {
    const numericas = ["cantidadSistema", "cantidadFisica", "diferencia"] as const;
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
        // Los nulos al final en las dos direcciones, igual que en Lotes.
        if (va === null && vb === null) return 0;
        if (va === null) return 1;
        if (vb === null) return -1;
        return factor * (va - vb);
      });
    }

    return lista.slice(0, visibles);
  }, [resultado, orden, visibles]);

  // Se resetea al cambiar filtro o búsqueda: seguir en "80 de 90" después de
  // filtrar a 12 resultados mostraría todo de golpe. Ajuste en render, no
  // useEffect: React re-renderiza antes de pintar.
  const claveVista = `${filtroEstado}|${termino}`;
  const [claveAnterior, setClaveAnterior] = useState(claveVista);
  if (claveVista !== claveAnterior) {
    setClaveAnterior(claveVista);
    setVisibles(POR_PAGINA);
  }

  /**
   * Procesar y anular invalidan además los lotes y los artículos, no sólo los
   * inventarios: procesar ajusta la cantidad disponible del lote, y el stock del
   * artículo es la suma de esas cantidades. Sin esto, las otras dos pantallas
   * seguirían mostrando en caché los números de antes del ajuste.
   */
  function invalidarTrasAjuste() {
    queryClient.invalidateQueries({ queryKey: ["inventarios"] });
    queryClient.invalidateQueries({ queryKey: ["lotes"] });
    queryClient.invalidateQueries({ queryKey: ["articulos"] });
  }

  const procesar = useMutation({
    mutationFn: (inv: Inventario) => api.inventarios.procesar(inv.id, inv.idEmpresa),
    onSuccess: () => {
      invalidarTrasAjuste();
      toast.success("Inventario procesado: el stock del lote quedó ajustado");
      setAProcesar(null);
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo procesar el inventario")),
  });

  const anular = useMutation({
    mutationFn: (inv: Inventario) => api.inventarios.anular(inv.id, inv.idEmpresa),
    onSuccess: () => {
      // El anulado no toca el lote, pero se invalida igual: es una sola consulta
      // y evita tener que recordar cuál de las dos mutaciones ajustaba qué.
      invalidarTrasAjuste();
      toast.success("Inventario anulado");
      setAAnular(null);
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo anular el inventario")),
  });

  // Sin sucursal no hay dónde contar ni qué listar: la pantalla lo dice en vez
  // de mostrar una tabla vacía que parecería un depósito sin conteos.
  const sinSucursal = !cargandoSucursal && sucursal === null;
  const sinLotes = !cargandoLotes && (lotes?.items.length ?? 0) === 0;

  const opcionesEstado = [
    { valor: "ABIERTO", etiqueta: "Abierto" },
    { valor: "PROCESADO", etiqueta: "Procesado" },
    { valor: "ANULADO", etiqueta: "Anulado" },
  ];

  return (
    <AppLayout active="/inventarios" title="Inventarios">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Inventarios</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Conteos físicos de stock por lote
              {sucursal ? ` en ${sucursal.nombreSucursal}` : ""}.
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={sucursal === null || sinLotes}>
            <Plus className="size-4" />
            Nuevo conteo
          </Button>
        </div>

        {sinSucursal ? (
          <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
            La empresa no tiene sucursales activas. Cargá una sucursal antes de inventariar.
          </p>
        ) : sinLotes ? (
          // Un conteo sin lote no existe: el formulario no se podría completar.
          <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
            Esta sucursal no tiene lotes cargados. Un inventario cuenta lo que hay en una partida,
            así que primero hay que registrarla en Lotes.
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
                aria-label="Buscar inventarios"
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
                No se pudieron cargar los inventarios.
              </p>
            ) : resultado.length === 0 ? (
              <div className="surface-card px-3 py-16 text-center">
                <p className="text-sm text-muted-foreground">
                  {termino || filtroEstado !== SIN_FILTRO
                    ? "Ningún conteo coincide con la búsqueda."
                    : "Todavía no se inventarió nada en esta sucursal."}
                </p>
                {!termino && filtroEstado === SIN_FILTRO && (
                  <Button className="mt-4" onClick={() => setCreando(true)}>
                    Cargar el primero
                  </Button>
                )}
              </div>
            ) : (
              <>
                {/* Móvil: tarjetas. Una tabla de 7 columnas en 360px obliga a
                    scrollear de costado para leer una fila entera. */}
                <ul className="space-y-3 sm:hidden">
                  {mostrados.map((inv) => {
                    const estado = ESTILO_ESTADO[inv.estado];
                    const abierto = inventarioAbierto(inv.estado);
                    const diferencia = textoDiferencia(inv.diferencia);

                    return (
                      <li key={inv.id} className="surface-card p-4">
                        <div className="flex items-start justify-between gap-3">
                          <div className="min-w-0 flex-1">
                            <p className="truncate font-semibold text-foreground">
                              {inv.nombreArticulo}
                            </p>
                            <p className="mt-0.5 text-xs text-muted-foreground">
                              {inv.numeroLote === null
                                ? "Sin número de lote"
                                : `Lote ${inv.numeroLote}`}
                              {" · "}
                              {formatearFecha(inv.fechaInventario)}
                            </p>
                          </div>
                          <Badge variant={estado.variante} className="shrink-0">
                            {estado.texto}
                          </Badge>
                        </div>

                        <p className="mt-2 text-xs text-muted-foreground">
                          Sistema: {inv.cantidadSistema ?? "—"} · Contado:{" "}
                          {inv.cantidadFisica ?? "—"} · Diferencia:{" "}
                          <span className={diferencia.clase}>{diferencia.texto}</span>
                        </p>
                        {/* El nombre completo, con el login de respaldo: el
                            JOIN puede traer el usuario sin nombre cargado. */}
                        {(inv.nombreProcesa ?? inv.usuarioProcesa) && (
                          <p className="text-xs text-muted-foreground">
                            Procesado por {inv.nombreProcesa ?? inv.usuarioProcesa}
                          </p>
                        )}

                        {/* Sólo los abiertos tienen acciones. En los terminales
                            no se dibuja nada: botones deshabilitados invitan a
                            probar por qué no andan. */}
                        {abierto && (
                          <div className="mt-3 space-y-2 border-t border-border pt-3">
                            <Button
                              variant="outline"
                              size="sm"
                              className="w-full"
                              onClick={() => setEditando(inv)}
                            >
                              <Pencil className="size-4" />
                              Corregir
                            </Button>
                            <div className="flex gap-2">
                              <Button
                                size="sm"
                                className="flex-1"
                                onClick={() => setAProcesar(inv)}
                              >
                                <CheckCircle2 className="size-4" />
                                Procesar
                              </Button>
                              <Button
                                variant="outline"
                                size="sm"
                                className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                                onClick={() => setAAnular(inv)}
                              >
                                <Ban className="size-4" />
                                Anular
                              </Button>
                            </div>
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
                        <TableHeadOrdenable
                          direccion={orden?.campo === "nombreArticulo" ? orden.direccion : null}
                          onClick={() => alternarOrden("nombreArticulo")}
                        >
                          Artículo
                        </TableHeadOrdenable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "fechaInventario" ? orden.direccion : null}
                          onClick={() => alternarOrden("fechaInventario")}
                        >
                          Fecha
                        </TableHeadOrdenable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "cantidadSistema" ? orden.direccion : null}
                          onClick={() => alternarOrden("cantidadSistema")}
                        >
                          Sistema
                        </TableHeadOrdenable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "cantidadFisica" ? orden.direccion : null}
                          onClick={() => alternarOrden("cantidadFisica")}
                        >
                          Contado
                        </TableHeadOrdenable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "diferencia" ? orden.direccion : null}
                          onClick={() => alternarOrden("diferencia")}
                        >
                          Diferencia
                        </TableHeadOrdenable>
                        <TableHeadFiltrable
                          direccion={orden?.campo === "estado" ? orden.direccion : null}
                          onOrdenar={() => alternarOrden("estado")}
                          opciones={opcionesEstado}
                          valor={filtroEstado}
                          onFiltrar={setFiltroEstado}
                          buscarPlaceholder="Buscar estado…"
                        >
                          Estado
                        </TableHeadFiltrable>
                        <TableHead className="text-right">Acciones</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {mostrados.map((inv) => {
                        const estado = ESTILO_ESTADO[inv.estado];
                        const abierto = inventarioAbierto(inv.estado);
                        const diferencia = textoDiferencia(inv.diferencia);

                        return (
                          <TableRow key={inv.id}>
                            <TableCell className="font-medium text-foreground">
                              {inv.nombreArticulo}
                              <span className="block text-xs font-normal text-muted-foreground">
                                {inv.numeroLote === null
                                  ? "Sin número de lote"
                                  : `Lote ${inv.numeroLote}`}
                              </span>
                            </TableCell>
                            <TableCell className="text-muted-foreground">
                              {formatearFecha(inv.fechaInventario)}
                              {/* Quién procesó va debajo de la fecha y no en
                                  columna propia: sólo tiene valor en los
                                  procesados, y una columna vacía en dos tercios
                                  de las filas no paga su ancho. */}
                              {(inv.nombreProcesa ?? inv.usuarioProcesa) && (
                                <span className="block text-xs">
                                  {inv.nombreProcesa ?? inv.usuarioProcesa}
                                </span>
                              )}
                            </TableCell>
                            <TableCell className="tabular-nums text-muted-foreground">
                              {inv.cantidadSistema ?? "—"}
                            </TableCell>
                            <TableCell className="tabular-nums">
                              {inv.cantidadFisica ?? "—"}
                            </TableCell>
                            <TableCell className={`tabular-nums ${diferencia.clase}`}>
                              {diferencia.texto}
                            </TableCell>
                            <TableCell>
                              <Badge variant={estado.variante}>{estado.texto}</Badge>
                            </TableCell>
                            <TableCell className="text-right">
                              {abierto ? (
                                <div className="flex justify-end gap-1">
                                  <Button
                                    variant="ghost"
                                    size="icon"
                                    title="Corregir"
                                    aria-label={`Corregir el conteo de ${inv.nombreArticulo}`}
                                    onClick={() => setEditando(inv)}
                                  >
                                    <Pencil className="size-4" />
                                  </Button>
                                  <Button
                                    variant="ghost"
                                    size="icon"
                                    title="Procesar"
                                    aria-label={`Procesar el conteo de ${inv.nombreArticulo}`}
                                    onClick={() => setAProcesar(inv)}
                                  >
                                    <CheckCircle2 className="size-4 text-success" />
                                  </Button>
                                  <Button
                                    variant="ghost"
                                    size="icon"
                                    title="Anular"
                                    aria-label={`Anular el conteo de ${inv.nombreArticulo}`}
                                    onClick={() => setAAnular(inv)}
                                  >
                                    <Ban className="size-4 text-destructive" />
                                  </Button>
                                </div>
                              ) : (
                                // Un guión y no botones apagados: el conteo se
                                // cerró y no hay nada que intentar.
                                <span className="text-xs text-muted-foreground">—</span>
                              )}
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
                      Mostrar {Math.min(resultado.length - mostrados.length, POR_PAGINA)} más
                    </Button>
                  </div>
                )}

                <p className="text-center text-xs text-muted-foreground">
                  Mostrando {mostrados.length} de {resultado.length} conteo
                  {resultado.length === 1 ? "" : "s"}
                  {termino || filtroEstado !== SIN_FILTRO ? ` (${items.length} en total)` : ""}
                </p>
              </>
            )}
          </>
        )}

        {/* Sin empresa ni sucursal no se abre: el alta necesita los dos ids. */}
        {empresa !== null && sucursal !== null && (
          <InventarioFormDialog
            open={creando || editando !== null}
            inventario={editando}
            idEmpresa={empresa.id}
            lotes={lotes?.items ?? []}
            cargandoLotes={cargandoLotes}
            conteosAbiertos={items.filter((i) => inventarioAbierto(i.estado))}
            onClose={() => {
              setCreando(false);
              setEditando(null);
            }}
          />
        )}

        {/* PROCESAR ES IRREVERSIBLE y además mueve el stock: la confirmación
            dice exactamente en qué va a quedar el lote, que es la pregunta que
            alguien se hace antes de apretar. */}
        <AlertDialog open={aProcesar !== null} onOpenChange={(o) => !o && setAProcesar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>
                ¿Procesar el conteo de {aProcesar?.nombreArticulo}?
              </AlertDialogTitle>
              <AlertDialogDescription>
                El stock del lote pasa a {aProcesar?.cantidadFisica ?? 0}
                {aProcesar && aProcesar.diferencia !== 0
                  ? ` (${textoDiferencia(aProcesar.diferencia).texto} respecto de lo que decía el sistema)`
                  : ""}
                . No se puede deshacer.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancelar</AlertDialogCancel>
              <AlertDialogAction
                onClick={(e) => {
                  // Sin esto el AlertDialog se cierra antes de que la mutación
                  // termine y el error nunca se llega a mostrar.
                  e.preventDefault();
                  if (aProcesar) procesar.mutate(aProcesar);
                }}
                disabled={procesar.isPending}
              >
                {procesar.isPending && <Loader2 className="size-4 animate-spin" />}
                Procesar
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>

        <AlertDialog open={aAnular !== null} onOpenChange={(o) => !o && setAAnular(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Anular el conteo de {aAnular?.nombreArticulo}?</AlertDialogTitle>
              <AlertDialogDescription>
                El conteo queda registrado como anulado y el stock del lote no se toca. No se puede
                deshacer, pero podés cargar un conteo nuevo.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancelar</AlertDialogCancel>
              <AlertDialogAction
                onClick={(e) => {
                  e.preventDefault();
                  if (aAnular) anular.mutate(aAnular);
                }}
                disabled={anular.isPending}
                className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              >
                {anular.isPending && <Loader2 className="size-4 animate-spin" />}
                Anular
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </main>
    </AppLayout>
  );
}

/* -------------------------------------------------------------------------- */
/* Formulario                                                                  */
/* -------------------------------------------------------------------------- */

function InventarioFormDialog({
  open,
  inventario,
  idEmpresa,
  lotes,
  cargandoLotes,
  conteosAbiertos,
  onClose,
}: {
  open: boolean;
  inventario: Inventario | null;
  idEmpresa: number;
  lotes: Lote[];
  cargandoLotes: boolean;
  /** Para no ofrecer lotes que ya tienen un conteo abierto (daría 409). */
  conteosAbiertos: Inventario[];
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = inventario !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    values: {
      idLote: inventario ? String(inventario.idLote) : "",
      cantidadFisica: inventario?.cantidadFisica != null ? String(inventario.cantidadFisica) : "",
      // Un conteo nuevo se hizo hoy salvo que se diga otra cosa: es el caso
      // habitual, y obliga a menos tipeo que dejarlo vacío.
      fechaInventario: inventario?.fechaInventario
        ? inventario.fechaInventario.slice(0, 10)
        : hoyISO(),
      observaciones: inventario?.observaciones ?? "",
    },
  });

  // El lote elegido, para mostrar cuánto dice el sistema mientras se carga el
  // conteo. Es lo que convierte el formulario en algo verificable: sin esto hay
  // que memorizar el número de la otra pantalla.
  const idLoteElegido = form.watch("idLote");
  const loteElegido = lotes.find((l) => String(l.id) === idLoteElegido) ?? null;
  const cantidadFisica = form.watch("cantidadFisica");

  /**
   * La diferencia en vivo, mientras se escribe.
   *
   * En edición se compara contra `cantidadSistema` —la foto guardada— y no
   * contra el lote de hoy: la foto es lo que el backend va a usar, y mostrar
   * otra cosa haría que el número del formulario no coincidiera con el de la
   * tabla al guardar.
   */
  const sistemaComparado = esEdicion
    ? (inventario.cantidadSistema ?? 0)
    : (loteElegido?.cantidadDispon ?? null);
  const diferenciaViva =
    sistemaComparado !== null && cantidadFisica !== "" && !Number.isNaN(Number(cantidadFisica))
      ? Number(cantidadFisica) - sistemaComparado
      : null;

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const comunes = {
        cantidadFisica: Number(v.cantidadFisica),
        ...(v.fechaInventario ? { fechaInventario: v.fechaInventario } : {}),
        ...(v.observaciones ? { observaciones: v.observaciones } : {}),
      };

      // El lote NO viaja en la edición: cambiarlo convertiría el conteo en otro
      // conteo distinto, y el backend lo ignora. Por eso el combobox también se
      // bloquea abajo.
      return esEdicion
        ? api.inventarios.actualizar(inventario.id, { idEmpresa, ...comunes })
        : api.inventarios.crear({ idEmpresa, idLote: Number(v.idLote), ...comunes });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["inventarios"] });
      toast.success(esEdicion ? "Conteo actualizado" : "Conteo registrado");
      onClose();
    },
    onError: (e) =>
      toast.error(MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo registrar")),
  });

  /**
   * Los lotes que se pueden contar: todos menos los que ya tienen un conteo
   * abierto.
   *
   * Ofrecerlos igual daría un 409 después de completar el formulario entero, que
   * es la peor forma de enterarse. En edición no se filtra —el combobox está
   * bloqueado— pero el lote propio tiene que seguir en la lista o no se vería.
   */
  const lotesOpciones = lotes
    .filter((l) => {
      if (esEdicion) return l.id === inventario.idLote;
      return !conteosAbiertos.some((c) => c.idLote === l.id);
    })
    .map((l) => ({
      valor: String(l.id),
      etiqueta: l.nombreArticulo,
      descripcion:
        l.numeroLote === null
          ? `Sin número · ${l.cantidadDispon} en sistema`
          : `Lote ${l.numeroLote} · ${l.cantidadDispon} en sistema`,
    }));

  const sinLotesDisponibles = !esEdicion && !cargandoLotes && lotesOpciones.length === 0;

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="scrollbar-fino max-h-[92vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Corregir conteo" : "Nuevo conteo"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Sólo se puede corregir mientras el conteo esté abierto."
              : "Registrá cuánto hay realmente en el depósito. Se aplica al stock recién al procesarlo."}
          </DialogDescription>
        </DialogHeader>

        {sinLotesDisponibles ? (
          <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
            Todos los lotes de esta sucursal ya tienen un conteo abierto. Procesá o anulá alguno
            antes de cargar otro.
          </p>
        ) : (
          <Form {...form}>
            <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
              <FormField
                control={form.control}
                name="idLote"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Lote</FormLabel>
                    <FormControl>
                      <SelectorModal
                        opciones={lotesOpciones}
                        value={field.value}
                        onChange={field.onChange}
                        placeholder="Elegí el lote a contar"
                        titulo="Elegí el lote a contar"
                        buscarPlaceholder="Buscar lote…"
                        cargando={cargandoLotes}
                        // En edición el lote no se cambia: sería otro conteo.
                        // Si estaba mal, se anula y se carga uno nuevo.
                        disabled={esEdicion}
                      />
                    </FormControl>
                    <FormDescription>
                      {esEdicion
                        ? "El lote no se puede cambiar. Si está mal, anulá el conteo y cargá otro."
                        : "Sólo aparecen los lotes sin un conteo abierto."}
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <div className="grid gap-4 sm:grid-cols-2">
                <FormField
                  control={form.control}
                  name="cantidadFisica"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Cantidad contada</FormLabel>
                      <FormControl>
                        {/* inputMode decimal abre el teclado numérico en móvil
                            sin las flechas de un type="number". */}
                        <Input
                          {...field}
                          inputMode="decimal"
                          placeholder="0"
                          autoComplete="off"
                          className="tabular-nums"
                        />
                      </FormControl>
                      <FormDescription>
                        {sistemaComparado !== null
                          ? `El sistema dice ${sistemaComparado}.`
                          : "Elegí un lote para ver qué dice el sistema."}
                      </FormDescription>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <FormField
                  control={form.control}
                  name="fechaInventario"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Fecha del conteo</FormLabel>
                      <FormControl>
                        <Input {...field} type="date" />
                      </FormControl>
                      <FormDescription>Cuándo se contó físicamente.</FormDescription>
                      <FormMessage />
                    </FormItem>
                  )}
                />
              </div>

              {/* La diferencia en vivo: es el dato que dice si vale la pena
                  seguir. Se muestra sólo cuando hay algo que comparar. */}
              {diferenciaViva !== null && (
                <p
                  className={`rounded-lg border px-3 py-2 text-sm ${
                    diferenciaViva === 0
                      ? "border-border bg-muted text-muted-foreground"
                      : "border-destructive/30 bg-destructive/10 text-destructive"
                  }`}
                >
                  {diferenciaViva === 0
                    ? "Coincide con el sistema: no hay ajuste que aplicar."
                    : `Diferencia de ${textoDiferencia(diferenciaViva).texto} ${
                        diferenciaViva > 0 ? "(sobrante)" : "(faltante)"
                      } respecto del sistema.`}
                </p>
              )}

              <FormField
                control={form.control}
                name="observaciones"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Observaciones</FormLabel>
                    <FormControl>
                      <Textarea
                        {...field}
                        rows={3}
                        placeholder="Mercadería dañada, error de carga anterior…"
                        className="scrollbar-fino"
                      />
                    </FormControl>
                    <FormDescription>
                      Opcional, pero es lo que explica la diferencia cuando alguien la revise
                      después.
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <DialogFooter>
                <Button type="button" variant="outline" onClick={onClose}>
                  Cancelar
                </Button>
                <Button type="submit" disabled={guardar.isPending}>
                  {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                  {guardar.isPending
                    ? "Guardando…"
                    : esEdicion
                      ? "Guardar cambios"
                      : "Registrar conteo"}
                </Button>
              </DialogFooter>
            </form>
          </Form>
        )}
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/inventarios")({
  head: () => ({
    meta: [
      { title: tituloPagina("Inventarios") },
      {
        name: "description",
        content: "Conteos físicos de stock por lote, con ajuste al procesarlos.",
      },
    ],
  }),
  component: InventariosPage,
});
