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
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type Estado, type Sucursal } from "@/lib/api";
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
  nombreSucursal: z.string().trim().min(1, "Obligatorio").max(200, "Máximo 200 caracteres"),
  direccion: z.string().trim().max(500, "Máximo 500 caracteres"),
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

function SucursalesPage() {
  const { empresa } = useEmpresa();
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Sucursal | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Sucursal | null>(null);

  // Sólo las sucursales de la empresa activa, y el recorte lo hace el backend
  // —no la pantalla—: traer las de todas para esconder casi todas manda por la
  // red datos de empresas que nadie está mirando.
  //
  // Es la MISMA queryKey que usa `sucursal-provider`, así que las dos comparten
  // la caché y un alta acá refresca también el selector de sucursal del header.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["sucursales", empresa?.id ?? null],
    queryFn: () => api.sucursales.listar({ idEmpresa: empresa!.id }),
    // El provider de empresa hidrata después de montar: sin esto la primera
    // petición saldría sin idEmpresa y traería las de todas las empresas.
    enabled: empresa !== null,
  });

  const eliminar = useMutation({
    mutationFn: (sucursal: Sucursal) => api.sucursales.eliminar(sucursal.id, sucursal.idEmpresa),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["sucursales"] });
      toast.success("Sucursal eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  // Búsqueda por cualquier campo visible + orden por click en el header.
  // Ver el criterio general en la guía de frontend, sección "Listados".
  // Buscar por empresa ya no tiene sentido —todas las filas son de la misma—;
  // la dirección sí distingue una sucursal de otra.
  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    data?.items ?? [],
    (s) => [s.nombreSucursal, s.direccion, esActivo(s.activo) ? "Activo" : "Inactivo"],
  );

  // Cuántas filas se están mostrando. Se resetea al cambiar la búsqueda:
  // seguir en "80 de 90" tras filtrar a 12 perdería el sentido.
  const [visibles, setVisibles] = useState(POR_PAGINA);
  const claveVista = termino;
  const [claveAnterior, setClaveAnterior] = useState(claveVista);
  if (claveVista !== claveAnterior) {
    // Ajuste de estado en render, no useEffect: React re-renderiza antes de
    // pintar, así que la lista nunca se ve con el valor viejo.
    setClaveAnterior(claveVista);
    setVisibles(POR_PAGINA);
  }

  const mostrados = resultado.slice(0, visibles);
  const quedan = resultado.length - mostrados.length;

  return (
    <AppLayout active="/sucursales" title="Sucursales">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Sucursales</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Sucursales de {empresa?.nombreEmpresa ?? "la empresa activa"}.
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null}>
            <Plus className="size-4" />
            Nueva sucursal
          </Button>
        </div>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por sucursal o dirección…"
            className="pl-9"
          />
        </div>

        {isPending && (
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

        {!isPending && !isError && resultado.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {termino
                ? `Sin resultados para "${busqueda.trim()}".`
                : "Esta empresa todavía no tiene sucursales cargadas."}
            </p>
            {!termino && (
              <Button className="mt-4" onClick={() => setCreando(true)} disabled={empresa === null}>
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
            {mostrados.map((sucursal) => {
              const activo = esActivo(sucursal.activo);

              return (
                <li key={sucursal.id} className="surface-card p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">
                        {sucursal.nombreSucursal}
                      </p>
                      <p className="mt-0.5 text-xs text-muted-foreground">
                        {sucursal.direccion ?? "Sin dirección"}
                      </p>
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
                      onClick={() => setEditando(sucursal)}
                    >
                      <Pencil className="size-4" />
                      Editar
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                      onClick={() => setAEliminar(sucursal)}
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
                    direccion={orden?.campo === "nombreSucursal" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreSucursal")}
                  >
                    Sucursal
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "direccion" ? orden.direccion : null}
                    onClick={() => alternarOrden("direccion")}
                  >
                    Dirección
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
                {mostrados.map((sucursal) => {
                  const activo = esActivo(sucursal.activo);

                  return (
                    <TableRow key={sucursal.id}>
                      <TableCell className="font-medium text-foreground">
                        {sucursal.nombreSucursal}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {sucursal.direccion ?? "—"}
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
                            title="Editar"
                            aria-label={`Editar ${sucursal.nombreSucursal}`}
                            onClick={() => setEditando(sucursal)}
                          >
                            <Pencil className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Eliminar"
                            aria-label={`Eliminar ${sucursal.nombreSucursal}`}
                            onClick={() => setAEliminar(sucursal)}
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
            Mostrando {mostrados.length} de {resultado.length} sucursal
            {resultado.length === 1 ? "" : "es"}
            {termino ? ` (${data.items.length} en total)` : ""}
          </p>
        )}

        <SucursalFormDialog
          open={creando || editando !== null}
          sucursal={editando}
          onClose={() => {
            setCreando(false);
            setEditando(null);
          }}
        />

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreSucursal}?</AlertDialogTitle>
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

function SucursalFormDialog({
  open,
  sucursal,
  onClose,
}: {
  open: boolean;
  sucursal: Sucursal | null;
  onClose: () => void;
}) {
  const { empresa } = useEmpresa();
  const queryClient = useQueryClient();
  const esEdicion = sucursal !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Sin defaults React avisa por inputs no controlados. Un alta nace activa:
    // cargar una sucursal para dejarla inactiva de entrada no tiene sentido.
    values: {
      nombreSucursal: sucursal?.nombreSucursal ?? "",
      direccion: sucursal?.direccion ?? "",
      activo: sucursal ? esActivo(sucursal.activo) : true,
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const activo: Estado = v.activo ? "A" : "I";
      // Los opcionales vacíos no se mandan: en el UPDATE un campo ausente
      // significa "no cambiar", que es justo lo que corresponde.
      const opcionales = {
        ...(v.direccion ? { direccion: v.direccion } : {}),
      };

      // La empresa no se elige: la sucursal es siempre de la empresa activa.
      // En edición sale de la propia fila —que ya vino acotada a esa empresa—
      // y no del provider, para que la sucursal no se mude de empresa si
      // alguien cambia de empresa con el diálogo abierto.
      return esEdicion
        ? api.sucursales.actualizar(sucursal.id, {
            idEmpresa: sucursal.idEmpresa,
            nombreSucursal: v.nombreSucursal,
            activo,
            ...opcionales,
          })
        : api.sucursales.crear({
            idEmpresa: empresa!.id,
            nombreSucursal: v.nombreSucursal,
            ...opcionales,
          });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["sucursales"] });
      toast.success(esEdicion ? "Sucursal actualizada" : "Sucursal creada");
      onClose();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear la sucursal"),
      ),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar sucursal" : "Nueva sucursal"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos de la sucursal."
              : `Agregá una sucursal a ${empresa?.nombreEmpresa ?? "la empresa activa"}.`}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="nombreSucursal"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre de la sucursal</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Casa Central" autoComplete="off" />
                  </FormControl>
                  <FormDescription>No puede repetirse dentro de la misma empresa.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="direccion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Dirección (opcional)</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Avda. España 123" autoComplete="off" />
                  </FormControl>
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
                        Una sucursal inactiva deja de ofrecerse en los formularios.
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
                {guardar.isPending
                  ? "Guardando…"
                  : esEdicion
                    ? "Guardar cambios"
                    : "Crear sucursal"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/sucursales")({
  head: () => ({
    meta: [
      { title: tituloPagina("Sucursales") },
      { name: "description", content: "Sucursales de la empresa activa." },
    ],
  }),
  component: SucursalesPage,
});
