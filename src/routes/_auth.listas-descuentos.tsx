import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type ListaDescuentos } from "@/lib/api";
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
import { tituloPagina } from "@/lib/marca";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

/**
 * Campo de fecha: ISO de sólo día, que es lo que el backend espera y devuelve.
 *
 * `z.string()` y no `z.date()` porque el `<input type="date">` entrega el string
 * ya en ese formato — convertirlo a Date y de vuelta sólo agregaría zonas
 * horarias que acá no significan nada (una vigencia es un día del calendario).
 */
const FECHA_ISO = /^\d{4}-\d{2}-\d{2}$/;

const schema = z
  .object({
    nombreLista: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
    /**
     * El descuento se valida como texto y se convierte al enviar, igual que en
     * Lotes: un `z.coerce.number()` sobre "" da 0, y acá eso es un valor
     * legítimo ("sin descuento") — no habría forma de distinguir el campo vacío
     * del cero escrito a mano.
     */
    porcentajeDescuento: z
      .string()
      .trim()
      .refine((v) => v === "" || !Number.isNaN(Number(v)), "El descuento tiene que ser un número")
      .refine((v) => v === "" || Number(v) >= 0, "El descuento no puede ser negativo")
      .refine((v) => v === "" || Number(v) < 100, "El descuento tiene que ser menor a 100"),
    fechaVigenciaDesde: z.string().trim().regex(FECHA_ISO, "Fecha inválida"),
    // Opcional de verdad: una lista sin fin de vigencia rige indefinidamente.
    fechaVigenciaHasta: z
      .string()
      .trim()
      .regex(FECHA_ISO, "Fecha inválida")
      .optional()
      .or(z.literal("")),
  })
  // Mismo control que hace el backend. Acá se valida además para no gastar un
  // viaje a la red en un error que se ve en el formulario.
  .refine((v) => !v.fechaVigenciaHasta || v.fechaVigenciaHasta >= v.fechaVigenciaDesde, {
    message: "No puede terminar antes de empezar",
    path: ["fechaVigenciaHasta"],
  });

type FormValues = z.infer<typeof schema>;

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Cuántas filas se muestran de entrada, y cuántas suma cada "Mostrar más".
 *
 * El endpoint devuelve todo de una vez —poco para la red, mucho para el DOM—,
 * así que la tabla corta acá.
 */
const POR_PAGINA = 20;

/**
 * Las dos opciones del filtro de Vigencia. Los valores son los códigos que
 * viajan en el JSON —"A"/"I"—, así el filtro compara contra el campo sin
 * traducir.
 */
const OPCIONES_VIGENCIA = [
  { valor: "A", etiqueta: "Vigente" },
  { valor: "I", etiqueta: "No vigente" },
];

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

/**
 * El rango de vigencia en una línea. Sin fecha de fin la lista rige
 * indefinidamente, y decirlo con palabras es más claro que un guión suelto.
 */
function formatearVigencia(lista: ListaDescuentos): string {
  const desde = formatearFecha(lista.fechaVigenciaDesde);
  return lista.fechaVigenciaHasta
    ? `${desde} → ${formatearFecha(lista.fechaVigenciaHasta)}`
    : `Desde ${desde}`;
}

/** "10" → "10%". El 0 se muestra igual: es "sin descuento", no un dato faltante. */
function formatearDescuento(porcentaje: number): string {
  return `${porcentaje}%`;
}

function ListasDescuentosPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<ListaDescuentos | null>(null);
  const [creando, setCreando] = useState(false);
  // Filtro de la columna Vigencia. Va acá y no en el endpoint: el listado ya
  // vino entero, así que alternar entre vigentes y vencidas es instantáneo.
  const [filtroVigencia, setFiltroVigencia] = useState<string>(SIN_FILTRO);
  const [aEliminar, setAEliminar] = useState<ListaDescuentos | null>(null);

  // Las listas son POR EMPRESA: la que se eligió al iniciar sesión. No hay
  // filtro ni combobox de empresa en la pantalla — se trabaja sobre la empresa
  // activa, y para ver las de otra hay que cambiarla en el login.
  const { empresa } = useEmpresa();

  // La empresa entra en la queryKey: al cambiarla, TanStack Query trata el
  // listado como otra consulta en vez de mostrar en caché las de la anterior.
  //
  // `enabled` evita pedir sin empresa. En el primer render todavía es null
  // —el provider hidrata desde localStorage después de montar— y sin esto la
  // petición saldría con idEmpresa vacío, devolviendo las listas de TODAS las
  // empresas por un instante.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["listas-descuentos", empresa?.id ?? null],
    queryFn: () => api.listasDescuentos.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  const eliminar = useMutation({
    mutationFn: (lista: ListaDescuentos) =>
      api.listasDescuentos.eliminar(lista.id, lista.idEmpresa),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["listas-descuentos"] });
      toast.success("Lista eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  // Búsqueda por cualquier campo visible + orden por click en el header.
  // El filtro de vigencia se aplica ANTES de la búsqueda: buscar dentro de lo
  // filtrado es lo que espera quien acotó primero la columna.
  const filtrados = (data?.items ?? []).filter(
    (x) => filtroVigencia === SIN_FILTRO || x.vigente === filtroVigencia,
  );

  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    filtrados,
    (l) => [
      l.nombreLista,
      formatearDescuento(l.porcentajeDescuento),
      formatearFecha(l.fechaVigenciaDesde),
      formatearFecha(l.fechaVigenciaHasta),
      esActivo(l.vigente) ? "Vigente" : "No vigente",
    ],
  );

  // Cuántas filas se están mostrando. Se resetea al cambiar la búsqueda:
  // seguir en "80 de 90" tras filtrar a 12 perdería el sentido.
  const [visibles, setVisibles] = useState(POR_PAGINA);
  const [terminoAnterior, setTerminoAnterior] = useState(termino);
  if (termino !== terminoAnterior) {
    // Ajuste de estado en render, no useEffect: React re-renderiza antes de
    // pintar, así que la lista nunca se ve con el valor viejo.
    setTerminoAnterior(termino);
    setVisibles(POR_PAGINA);
  }

  const mostrados = resultado.slice(0, visibles);
  const quedan = resultado.length - mostrados.length;

  return (
    <AppLayout active="/listas-descuentos" title="Listas de descuentos">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Listas de descuentos</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {empresa
                ? `Listas de ${empresa.nombreEmpresa}.`
                : "Listas de la empresa con la que iniciaste sesión."}
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null}>
            <Plus className="size-4" />
            Nueva lista
          </Button>
        </div>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre, descuento, fecha…"
            className="pl-9"
          />
        </div>

        {/* Sin empresa no hay nada que listar. Pasa si se entró con una sesión
            vieja, de antes de que el login pidiera elegirla. */}
        {empresa === null && !isPending && (
          <p className="rounded-lg border border-border px-3 py-6 text-center text-sm text-muted-foreground">
            No hay una empresa activa. Cerrá sesión y volvé a entrar eligiendo una.
          </p>
        )}

        {isPending && empresa !== null && (
          <div className="space-y-2">
            {[0, 1, 2, 3, 4].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        )}

        {isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
            {MENSAJE_ERROR(error, "No se pudo cargar la lista")}
          </p>
        )}

        {!isPending && !isError && empresa !== null && resultado.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {termino
                ? `Sin resultados para "${busqueda.trim()}".`
                : "Esta empresa todavía no tiene listas de descuentos cargadas."}
            </p>
            {!termino && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                <Plus className="size-4" />
                Cargar la primera
              </Button>
            )}
          </div>
        )}

        {/* Móvil: tarjetas. Una tabla de 5 columnas en 360px obliga a scrollear
            de costado para leer una fila entera. */}
        {resultado.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {mostrados.map((lista) => {
              const vigente = esActivo(lista.vigente);

              return (
                <li key={lista.id} className="surface-card p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">{lista.nombreLista}</p>
                      <p className="mt-0.5 text-xs text-muted-foreground">
                        {formatearVigencia(lista)}
                      </p>
                    </div>
                    <Badge variant={vigente ? "secondary" : "outline"} className="shrink-0">
                      {vigente ? "Vigente" : "No vigente"}
                    </Badge>
                  </div>

                  <p className="mt-2 text-sm text-foreground">
                    Descuento{" "}
                    <span className="font-medium tabular-nums">
                      {formatearDescuento(lista.porcentajeDescuento)}
                    </span>
                  </p>

                  <div className="mt-3 flex gap-2 border-t border-border pt-3">
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1"
                      onClick={() => setEditando(lista)}
                    >
                      <Pencil className="size-4" />
                      Editar
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                      onClick={() => setAEliminar(lista)}
                    >
                      <Trash2 className="size-4" />
                      Eliminar
                    </Button>
                  </div>
                </li>
              );
            })}
          </ul>
        )}

        {resultado.length > 0 && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "nombreLista" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreLista")}
                  >
                    Lista
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "porcentajeDescuento" ? orden.direccion : null}
                    onClick={() => alternarOrden("porcentajeDescuento")}
                  >
                    Descuento
                  </TableHeadOrdenable>
                  {/* Las fechas en ISO ordenan bien como texto, así que el orden
                      del hook alcanza sin comparador propio. */}
                  <TableHeadOrdenable
                    direccion={orden?.campo === "fechaVigenciaDesde" ? orden.direccion : null}
                    onClick={() => alternarOrden("fechaVigenciaDesde")}
                  >
                    Desde
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "fechaVigenciaHasta" ? orden.direccion : null}
                    onClick={() => alternarOrden("fechaVigenciaHasta")}
                  >
                    Hasta
                  </TableHeadOrdenable>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "vigente" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("vigente")}
                    opciones={OPCIONES_VIGENCIA}
                    valor={filtroVigencia}
                    onFiltrar={setFiltroVigencia}
                    buscarPlaceholder="Buscar vigencia…"
                  >
                    Vigencia
                  </TableHeadFiltrable>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {mostrados.map((lista) => {
                  const vigente = esActivo(lista.vigente);

                  return (
                    <TableRow key={lista.id}>
                      <TableCell className="font-medium text-foreground">
                        {lista.nombreLista}
                      </TableCell>
                      <TableCell className="tabular-nums text-muted-foreground">
                        {formatearDescuento(lista.porcentajeDescuento)}
                      </TableCell>
                      <TableCell className="tabular-nums text-muted-foreground">
                        {formatearFecha(lista.fechaVigenciaDesde)}
                      </TableCell>
                      <TableCell className="tabular-nums text-muted-foreground">
                        {formatearFecha(lista.fechaVigenciaHasta)}
                      </TableCell>
                      <TableCell>
                        <Badge variant={vigente ? "secondary" : "outline"}>
                          {vigente ? "Vigente" : "No vigente"}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-right">
                        <div className="flex justify-end gap-1">
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Editar"
                            aria-label={`Editar ${lista.nombreLista}`}
                            onClick={() => setEditando(lista)}
                          >
                            <Pencil className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Eliminar"
                            aria-label={`Eliminar ${lista.nombreLista}`}
                            onClick={() => setAEliminar(lista)}
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
        )}

        {quedan > 0 && (
          <div className="flex justify-center">
            <Button variant="outline" onClick={() => setVisibles((v) => v + POR_PAGINA)}>
              Mostrar {Math.min(quedan, POR_PAGINA)} más
            </Button>
          </div>
        )}

        {data && resultado.length > 0 && (
          <p className="text-center text-xs text-muted-foreground">
            Mostrando {mostrados.length} de {resultado.length} lista
            {resultado.length === 1 ? "" : "s"}
            {termino ? ` (${data.items.length} en total)` : ""}
          </p>
        )}

        {/* Sin empresa no se abre: el alta necesita su id. */}
        {empresa !== null && (
          <ListaDescuentosFormDialog
            open={creando || editando !== null}
            lista={editando}
            idEmpresa={empresa.id}
            onClose={() => {
              setCreando(false);
              setEditando(null);
            }}
          />
        )}

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreLista}?</AlertDialogTitle>
              <AlertDialogDescription>
                Esta acción no se puede deshacer. Si sólo querés dejar de usarla, poné una fecha de
                fin de vigencia en vez de eliminarla.
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
/* Alta / Edición                                                              */
/* -------------------------------------------------------------------------- */

function ListaDescuentosFormDialog({
  open,
  lista,
  idEmpresa,
  onClose,
}: {
  open: boolean;
  lista: ListaDescuentos | null;
  /** Empresa activa de la sesión. No es un campo del formulario. */
  idEmpresa: number;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = lista !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Sin defaults React avisa por inputs no controlados. El alta arranca
    // rigiendo desde hoy: lo habitual es cargar la lista el día que empieza.
    values: {
      nombreLista: lista?.nombreLista ?? "",
      porcentajeDescuento: lista ? String(lista.porcentajeDescuento) : "",
      fechaVigenciaDesde: lista?.fechaVigenciaDesde ?? hoyISO(),
      fechaVigenciaHasta: lista?.fechaVigenciaHasta ?? "",
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const descuento = v.porcentajeDescuento.trim();
      const hasta = v.fechaVigenciaHasta?.trim() ?? "";

      if (esEdicion) {
        return api.listasDescuentos.actualizar(lista.id, {
          idEmpresa: lista.idEmpresa,
          nombreLista: v.nombreLista,
          ...(descuento ? { porcentajeDescuento: Number(descuento) } : {}),
          fechaVigenciaDesde: v.fechaVigenciaDesde,
          // Vaciar el campo en la edición SÍ tiene que borrar el vencimiento,
          // pero para el backend "ausente" significa "no cambiar". El literal
          // "null" es lo que distingue las dos intenciones.
          fechaVigenciaHasta: hasta || "null",
        });
      }

      return api.listasDescuentos.crear({
        idEmpresa,
        nombreLista: v.nombreLista,
        ...(descuento ? { porcentajeDescuento: Number(descuento) } : {}),
        fechaVigenciaDesde: v.fechaVigenciaDesde,
        // En el alta se omite y listo: no hay valor previo que conservar.
        ...(hasta ? { fechaVigenciaHasta: hasta } : {}),
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["listas-descuentos"] });
      toast.success(esEdicion ? "Lista actualizada" : "Lista creada");
      onClose();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear la lista"),
      ),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {esEdicion ? "Editar lista de descuentos" : "Nueva lista de descuentos"}
          </DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos de la lista."
              : "Agregá una lista a la empresa con la que iniciaste sesión."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="nombreLista"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre de la lista</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Lista Mayorista" autoComplete="off" />
                  </FormControl>
                  <FormDescription>No puede repetirse dentro de la misma empresa.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="porcentajeDescuento"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Descuento (%)</FormLabel>
                  <FormControl>
                    {/* inputMode decimal y no type="number": el spinner del
                        navegador cambia el valor con la rueda del mouse sobre el
                        campo enfocado, que acá sería un error silencioso. */}
                    <Input
                      {...field}
                      inputMode="decimal"
                      placeholder="0"
                      autoComplete="off"
                      className="tabular-nums"
                    />
                  </FormControl>
                  <FormDescription>
                    Porcentaje general de la lista: 10 es 10%. Vacío equivale a 0.
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            {/* Las dos fechas en una fila: son un rango, y separadas costaba ver
                que se leen juntas. */}
            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="fechaVigenciaDesde"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Vigente desde</FormLabel>
                    <FormControl>
                      {/* type="date" y no un campo de texto: el selector nativo
                          garantiza el formato ISO que el backend espera. */}
                      <Input {...field} type="date" className="tabular-nums" />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="fechaVigenciaHasta"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Vigente hasta</FormLabel>
                    <FormControl>
                      <Input {...field} type="date" className="tabular-nums" />
                    </FormControl>
                    <FormDescription>Opcional. Vacío: rige indefinidamente.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onClose}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {guardar.isPending ? "Guardando…" : esEdicion ? "Guardar cambios" : "Crear lista"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

/** Hoy en ISO de sólo día, para el valor inicial de la fecha de inicio. */
function hoyISO(): string {
  const hoy = new Date();
  const mes = String(hoy.getMonth() + 1).padStart(2, "0");
  const dia = String(hoy.getDate()).padStart(2, "0");
  return `${hoy.getFullYear()}-${mes}-${dia}`;
}

export const Route = createFileRoute("/_auth/listas-descuentos")({
  head: () => ({
    meta: [
      { title: tituloPagina("Listas de descuentos") },
      {
        name: "description",
        content: "Listas de descuentos por empresa, con vigencia por fechas.",
      },
    ],
  }),
  component: ListasDescuentosPage,
});
