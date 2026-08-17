import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Coins, Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { DetalleMonedasDialog } from "@/components/ctell/DetalleMonedasDialog";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type Estado, type Moneda } from "@/lib/api";
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
  nombreMoneda: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
  simbolo: z.string().trim().max(10, "Máximo 10 caracteres"),
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

function MonedasPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Moneda | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Moneda | null>(null);
  // Moneda cuyas denominaciones se están viendo. El detalle va en un diálogo y
  // no en una ruta propia: sólo tiene sentido dentro de su cabecera.
  const [verDetalle, setVerDetalle] = useState<Moneda | null>(null);

  // Las monedas son POR EMPRESA: la que se eligió al iniciar sesión. No hay
  // filtro ni combobox de empresa en la pantalla — se trabaja sobre la empresa
  // activa, y para ver las de otra hay que cambiarla en el login.
  const { empresa } = useEmpresa();

  // La empresa entra en la queryKey: al cambiarla, TanStack Query trata el
  // listado como otra consulta en vez de mostrar en caché las de la anterior.
  //
  // `enabled` evita pedir sin empresa. En el primer render todavía es null
  // —el provider hidrata desde localStorage después de montar— y sin esto la
  // petición saldría con idEmpresa vacío, devolviendo las monedas de TODAS las
  // empresas por un instante.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["monedas", empresa?.id ?? null],
    queryFn: () => api.monedas.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  const eliminar = useMutation({
    mutationFn: (moneda: Moneda) => api.monedas.eliminar(moneda.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["monedas"] });
      toast.success("Moneda eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  // Búsqueda por cualquier campo visible + orden por click en el header.
  // Ver el criterio general en la guía de frontend, sección "Listados".
  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    data?.items ?? [],
    (m) => [m.nombreMoneda, m.simbolo, esActivo(m.activo) ? "Activo" : "Inactivo"],
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
    <AppLayout active="/monedas" title="Monedas">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Monedas</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {empresa
                ? `Monedas de ${empresa.nombreEmpresa}.`
                : "Monedas de la empresa con la que iniciaste sesión."}
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null}>
            <Plus className="size-4" />
            Nueva moneda
          </Button>
        </div>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre, símbolo…"
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
                : "Esta empresa todavía no tiene monedas cargadas."}
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
            {mostrados.map((moneda) => {
              const activo = esActivo(moneda.activo);

              return (
                <li key={moneda.id} className="surface-card p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">
                        {moneda.nombreMoneda}
                      </p>
                      {moneda.simbolo && (
                        <p className="mt-0.5 text-xs text-muted-foreground">{moneda.simbolo}</p>
                      )}
                    </div>
                    <Badge variant={activo ? "secondary" : "outline"} className="shrink-0">
                      {activo ? "Activo" : "Inactivo"}
                    </Badge>
                  </div>

                  <div className="mt-3 space-y-2 border-t border-border pt-3">
                    <Button
                      variant="outline"
                      size="sm"
                      className="w-full"
                      onClick={() => setVerDetalle(moneda)}
                    >
                      <Coins className="size-4" />
                      Denominaciones
                    </Button>
                    <div className="flex gap-2">
                      <Button
                        variant="outline"
                        size="sm"
                        className="flex-1"
                        onClick={() => setEditando(moneda)}
                      >
                        <Pencil className="size-4" />
                        Editar
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                        onClick={() => setAEliminar(moneda)}
                      >
                        <Trash2 className="size-4" />
                        Eliminar
                      </Button>
                    </div>
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
                    direccion={orden?.campo === "nombreMoneda" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreMoneda")}
                  >
                    Moneda
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "simbolo" ? orden.direccion : null}
                    onClick={() => alternarOrden("simbolo")}
                  >
                    Símbolo
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "activo" ? orden.direccion : null}
                    onClick={() => alternarOrden("activo")}
                  >
                    Estado
                  </TableHeadOrdenable>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {mostrados.map((moneda) => {
                  const activo = esActivo(moneda.activo);

                  return (
                    <TableRow key={moneda.id}>
                      <TableCell className="font-medium text-foreground">
                        {moneda.nombreMoneda}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {moneda.simbolo ?? "—"}
                      </TableCell>
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
                            title="Denominaciones"
                            aria-label={`Denominaciones de ${moneda.nombreMoneda}`}
                            onClick={() => setVerDetalle(moneda)}
                          >
                            <Coins className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Editar"
                            aria-label={`Editar ${moneda.nombreMoneda}`}
                            onClick={() => setEditando(moneda)}
                          >
                            <Pencil className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Eliminar"
                            aria-label={`Eliminar ${moneda.nombreMoneda}`}
                            onClick={() => setAEliminar(moneda)}
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
            Mostrando {mostrados.length} de {resultado.length} moneda
            {resultado.length === 1 ? "" : "s"}
            {termino ? ` (${data.items.length} en total)` : ""}
          </p>
        )}

        {/* Sin empresa no se abre: el alta necesita su id. */}
        {empresa !== null && (
          <MonedaFormDialog
            open={creando || editando !== null}
            moneda={editando}
            idEmpresa={empresa.id}
            onClose={() => {
              setCreando(false);
              setEditando(null);
            }}
          />
        )}

        {/* Denominaciones de la moneda: billetes y monedas para el cierre de
            caja, cada una con su foto. */}
        <DetalleMonedasDialog
          moneda={verDetalle}
          onOpenChange={(abierto) => !abierto && setVerDetalle(null)}
        />

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreMoneda}?</AlertDialogTitle>
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

function MonedaFormDialog({
  open,
  moneda,
  idEmpresa,
  onClose,
}: {
  open: boolean;
  moneda: Moneda | null;
  /** Empresa activa de la sesión. No es un campo del formulario. */
  idEmpresa: number;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = moneda !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Sin defaults React avisa por inputs no controlados. Un alta nace activa:
    // cargar una moneda para dejarla inactiva de entrada no tiene sentido.
    values: {
      nombreMoneda: moneda?.nombreMoneda ?? "",
      simbolo: moneda?.simbolo ?? "",
      activo: moneda ? esActivo(moneda.activo) : true,
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const activo: Estado = v.activo ? "A" : "I";
      // El símbolo es opcional: se manda solo si se escribió algo. Mandar ""
      // en la edición no borraría nada (el backend trata vacío como "no
      // cambiar"), pero en el alta guardaría una cadena vacía en vez de NULL.
      const simbolo = v.simbolo.trim();

      return esEdicion
        ? api.monedas.actualizar(moneda.id, {
            nombreMoneda: v.nombreMoneda,
            ...(simbolo ? { simbolo } : {}),
            activo,
          })
        : api.monedas.crear({
            idEmpresa,
            nombreMoneda: v.nombreMoneda,
            ...(simbolo ? { simbolo } : {}),
          });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["monedas"] });
      toast.success(esEdicion ? "Moneda actualizada" : "Moneda creada");
      onClose();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear la moneda"),
      ),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar moneda" : "Nueva moneda"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos de la moneda."
              : "Agregá una moneda a la empresa con la que iniciaste sesión."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="nombreMoneda"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre de la moneda</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Guaraní" autoComplete="off" />
                  </FormControl>
                  <FormDescription>No puede repetirse dentro de la misma empresa.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="simbolo"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Símbolo</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="₲" autoComplete="off" />
                  </FormControl>
                  <FormDescription>Opcional. Se muestra junto a los importes.</FormDescription>
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
                        Una moneda inactiva deja de ofrecerse en los formularios.
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
                {guardar.isPending ? "Guardando…" : esEdicion ? "Guardar cambios" : "Crear moneda"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/monedas")({
  head: () => ({
    meta: [
      { title: tituloPagina("Monedas") },
      { name: "description", content: "Monedas por empresa del sistema." },
    ],
  }),
  component: MonedasPage,
});
