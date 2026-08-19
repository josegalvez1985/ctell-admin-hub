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
import { api, ApiError, esActivo, type Estado, type UnidadMedida } from "@/lib/api";
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
import { Switch } from "@/components/ui/switch";
import { tituloPagina } from "@/lib/marca";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

const schema = z.object({
  nombreUnidad: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
  // Obligatoria, a diferencia del símbolo de Moneda: la columna es NOT NULL y
  // además es la que no puede repetirse dentro de la empresa.
  abreviatura: z.string().trim().min(1, "Obligatoria").max(10, "Máximo 10 caracteres"),
  activo: z.boolean(),
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
 * Las dos opciones del filtro de Estado. Los valores son los códigos que viajan
 * en el JSON —"A"/"I"—, así el filtro compara contra la columna sin traducir.
 */
const OPCIONES_ESTADO = [
  { valor: "A", etiqueta: "Activo" },
  { valor: "I", etiqueta: "Inactivo" },
];

function UnidadesMedidaPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<UnidadMedida | null>(null);
  const [creando, setCreando] = useState(false);
  // Filtro de la columna Estado. Va acá y no en el endpoint: el listado ya vino
  // entero, así que alternar entre activos e inactivos es instantáneo.
  const [filtroEstado, setFiltroEstado] = useState<string>(SIN_FILTRO);
  const [aEliminar, setAEliminar] = useState<UnidadMedida | null>(null);

  // Las unidades son POR EMPRESA: la que se eligió al iniciar sesión. No hay
  // filtro ni combobox de empresa en la pantalla — se trabaja sobre la empresa
  // activa, y para ver las de otra hay que cambiarla en el login.
  const { empresa } = useEmpresa();

  // La empresa entra en la queryKey: al cambiarla, TanStack Query trata el
  // listado como otra consulta en vez de mostrar en caché las de la anterior.
  //
  // `enabled` evita pedir sin empresa. En el primer render todavía es null
  // —el provider hidrata desde localStorage después de montar— y sin esto la
  // petición saldría con idEmpresa vacío, devolviendo las unidades de TODAS las
  // empresas por un instante.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["unidades-medida", empresa?.id ?? null],
    queryFn: () => api.unidadesMedida.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  const eliminar = useMutation({
    mutationFn: (unidad: UnidadMedida) => api.unidadesMedida.eliminar(unidad.id, unidad.idEmpresa),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["unidades-medida"] });
      toast.success("Unidad eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  // Búsqueda por cualquier campo visible + orden por click en el header.
  // Ver el criterio general en la guía de frontend, sección "Listados".
  // El filtro de estado se aplica ANTES de la búsqueda: buscar dentro de lo
  // filtrado es lo que espera quien acotó primero la columna.
  const filtrados = (data?.items ?? []).filter(
    (x) => filtroEstado === SIN_FILTRO || x.activo === filtroEstado,
  );

  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    filtrados,
    (u) => [u.nombreUnidad, u.abreviatura, esActivo(u.activo) ? "Activo" : "Inactivo"],
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
    <AppLayout active="/unidades-medida" title="Unidades de medida">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Unidades de medida</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {empresa
                ? `Unidades de ${empresa.nombreEmpresa}.`
                : "Unidades de la empresa con la que iniciaste sesión."}
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null}>
            <Plus className="size-4" />
            Nueva unidad
          </Button>
        </div>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre, abreviatura…"
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
                : "Esta empresa todavía no tiene unidades cargadas."}
            </p>
            {!termino && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                <Plus className="size-4" />
                Cargar la primera
              </Button>
            )}
          </div>
        )}

        {/* Móvil: tarjetas. Una tabla de 4 columnas en 360px obliga a scrollear
            de costado para leer una fila entera. */}
        {resultado.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {mostrados.map((unidad) => {
              const activo = esActivo(unidad.activo);

              return (
                <li key={unidad.id} className="surface-card p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">
                        {unidad.nombreUnidad}
                      </p>
                      <p className="mt-0.5 text-xs text-muted-foreground">{unidad.abreviatura}</p>
                    </div>
                    <Badge variant={activo ? "secondary" : "outline"} className="shrink-0">
                      {activo ? "Activo" : "Inactivo"}
                    </Badge>
                  </div>

                  <div className="mt-3 flex gap-2 border-t border-border pt-3">
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1"
                      onClick={() => setEditando(unidad)}
                    >
                      <Pencil className="size-4" />
                      Editar
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                      onClick={() => setAEliminar(unidad)}
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
                    direccion={orden?.campo === "nombreUnidad" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreUnidad")}
                  >
                    Unidad
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "abreviatura" ? orden.direccion : null}
                    onClick={() => alternarOrden("abreviatura")}
                  >
                    Abreviatura
                  </TableHeadOrdenable>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "activo" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("activo")}
                    opciones={OPCIONES_ESTADO}
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
                {mostrados.map((unidad) => {
                  const activo = esActivo(unidad.activo);

                  return (
                    <TableRow key={unidad.id}>
                      <TableCell className="font-medium text-foreground">
                        {unidad.nombreUnidad}
                      </TableCell>
                      <TableCell className="text-muted-foreground">{unidad.abreviatura}</TableCell>
                      <TableCell>
                        <Badge variant={activo ? "secondary" : "outline"}>
                          {activo ? "Activo" : "Inactivo"}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-right">
                        <div className="flex justify-end gap-1">
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Editar"
                            aria-label={`Editar ${unidad.nombreUnidad}`}
                            onClick={() => setEditando(unidad)}
                          >
                            <Pencil className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Eliminar"
                            aria-label={`Eliminar ${unidad.nombreUnidad}`}
                            onClick={() => setAEliminar(unidad)}
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
            Mostrando {mostrados.length} de {resultado.length} unidad
            {resultado.length === 1 ? "" : "es"}
            {termino ? ` (${data.items.length} en total)` : ""}
          </p>
        )}

        {/* Sin empresa no se abre: el alta necesita su id. */}
        {empresa !== null && (
          <UnidadFormDialog
            open={creando || editando !== null}
            unidad={editando}
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
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreUnidad}?</AlertDialogTitle>
              <AlertDialogDescription>Esta acción no se puede deshacer.</AlertDialogDescription>
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

function UnidadFormDialog({
  open,
  unidad,
  idEmpresa,
  onClose,
}: {
  open: boolean;
  unidad: UnidadMedida | null;
  /** Empresa activa de la sesión. No es un campo del formulario. */
  idEmpresa: number;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = unidad !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Sin defaults React avisa por inputs no controlados. Un alta nace activa:
    // cargar una unidad para dejarla inactiva de entrada no tiene sentido.
    values: {
      nombreUnidad: unidad?.nombreUnidad ?? "",
      abreviatura: unidad?.abreviatura ?? "",
      activo: unidad ? esActivo(unidad.activo) : true,
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const activo: Estado = v.activo ? "A" : "I";
      // Los dos campos son obligatorios (zod ya los validó), así que van
      // siempre — no hay que omitirlos condicionalmente como el símbolo de
      // Moneda.
      return esEdicion
        ? api.unidadesMedida.actualizar(unidad.id, {
            nombreUnidad: v.nombreUnidad,
            abreviatura: v.abreviatura,
            activo,
          })
        : api.unidadesMedida.crear({
            idEmpresa,
            nombreUnidad: v.nombreUnidad,
            abreviatura: v.abreviatura,
          });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["unidades-medida"] });
      toast.success(esEdicion ? "Unidad actualizada" : "Unidad creada");
      onClose();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear la unidad"),
      ),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar unidad" : "Nueva unidad de medida"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos de la unidad."
              : "Agregá una unidad a la empresa con la que iniciaste sesión."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="nombreUnidad"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre de la unidad</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Kilogramo" autoComplete="off" />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="abreviatura"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Abreviatura</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="kg" autoComplete="off" />
                  </FormControl>
                  <FormDescription>No puede repetirse dentro de la misma empresa.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            {/* Solo en edición: el alta siempre nace activa. */}
            {esEdicion && (
              <FormField
                control={form.control}
                name="activo"
                render={({ field }) => (
                  <FormItem className="flex items-center justify-between rounded-lg border border-border p-3">
                    <div className="space-y-0.5">
                      <FormLabel>Activo</FormLabel>
                      <FormDescription>
                        Una unidad inactiva deja de ofrecerse en los formularios.
                      </FormDescription>
                    </div>
                    <FormControl>
                      <Switch checked={field.value} onCheckedChange={field.onChange} />
                    </FormControl>
                  </FormItem>
                )}
              />
            )}

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onClose}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {guardar.isPending ? "Guardando…" : esEdicion ? "Guardar cambios" : "Crear unidad"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/unidades-medida")({
  head: () => ({
    meta: [
      { title: tituloPagina("Unidades de medida") },
      { name: "description", content: "Unidades de medida por empresa del sistema." },
    ],
  }),
  component: UnidadesMedidaPage,
});
