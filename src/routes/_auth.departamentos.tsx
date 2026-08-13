import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { Combobox } from "@/components/ctell/Combobox";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type Departamento, type Estado } from "@/lib/api";
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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

const schema = z.object({
  // El combobox devuelve strings: el id se valida como texto no vacío y se
  // convierte a número recién al enviar.
  idPais: z.string().min(1, "Elegí un país"),
  nombreDepartamento: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
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

function DepartamentosPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Departamento | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Departamento | null>(null);
  const [filtroPais, setFiltroPais] = useState<string>(SIN_FILTRO);

  // El endpoint trae todos los departamentos y el filtro se aplica acá abajo,
  // sobre la columna País. Cambiar de país no dispara un viaje a la red.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["departamentos", null],
    queryFn: () => api.departamentos.listar(),
  });

  const departamentosFiltrados = (data?.items ?? []).filter(
    (d) => filtroPais === SIN_FILTRO || String(d.idPais) === filtroPais,
  );

  // Los países alimentan el filtro y el formulario. Se piden una vez acá y
  // TanStack Query los comparte con el dialog por la misma queryKey.
  const { data: paises } = useQuery({
    queryKey: ["paises"],
    queryFn: () => api.paises.listar(),
  });

  const eliminar = useMutation({
    mutationFn: (departamento: Departamento) => api.departamentos.eliminar(departamento.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["departamentos"] });
      toast.success("Departamento eliminado");
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
    departamentosFiltrados,
    (d) => [d.nombreDepartamento, d.pais, d.codigoPais, esActivo(d.activo) ? "Activo" : "Inactivo"],
  );

  const paisesOpciones = (paises?.items ?? []).map((p) => ({
    valor: String(p.id),
    etiqueta: p.nombrePais,
    descripcion: p.codigoPais ?? undefined,
  }));

  // Cuántas filas se están mostrando. Se resetea al cambiar el filtro o la
  // búsqueda: seguir en "80 de 90" tras filtrar a 12 perdería el sentido.
  const [visibles, setVisibles] = useState(POR_PAGINA);
  const claveVista = `${filtroPais}|${termino}`;
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
    <AppLayout active="/departamentos" title="Departamentos">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Departamentos</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Divisiones de cada país disponibles en el sistema.
            </p>
          </div>
          <Button onClick={() => setCreando(true)}>
            <Plus className="size-4" />
            Nuevo departamento
          </Button>
        </div>

        {/* El filtro por país vive en el header de su columna. */}
        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por departamento, país…"
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
                : filtroPais === SIN_FILTRO
                  ? "Todavía no hay departamentos cargados."
                  : "Ese país todavía no tiene departamentos cargados."}
            </p>
            {!termino && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                <Plus className="size-4" />
                Cargar el primero
              </Button>
            )}
          </div>
        )}

        {/* Móvil: tarjetas. Una tabla de 4 columnas en 360px obliga a scrollear
            de costado para leer una fila entera. */}
        {resultado.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {mostrados.map((departamento) => {
              const activo = esActivo(departamento.activo);

              return (
                <li key={departamento.id} className="surface-card p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">
                        {departamento.nombreDepartamento}
                      </p>
                      <p className="mt-0.5 text-xs text-muted-foreground">{departamento.pais}</p>
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
                      onClick={() => setEditando(departamento)}
                    >
                      <Pencil className="size-4" />
                      Editar
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                      onClick={() => setAEliminar(departamento)}
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
                    direccion={orden?.campo === "nombreDepartamento" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreDepartamento")}
                  >
                    Departamento
                  </TableHeadOrdenable>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "pais" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("pais")}
                    opciones={paisesOpciones.map((p) => ({
                      valor: p.valor,
                      etiqueta: p.etiqueta,
                    }))}
                    valor={filtroPais}
                    onFiltrar={setFiltroPais}
                    buscarPlaceholder="Buscar país…"
                  >
                    País
                  </TableHeadFiltrable>
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
                {mostrados.map((departamento) => {
                  const activo = esActivo(departamento.activo);

                  return (
                    <TableRow key={departamento.id}>
                      <TableCell className="font-medium text-foreground">
                        {departamento.nombreDepartamento}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {departamento.pais}
                        {departamento.codigoPais ? ` (${departamento.codigoPais})` : ""}
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
                            aria-label={`Editar ${departamento.nombreDepartamento}`}
                            onClick={() => setEditando(departamento)}
                          >
                            <Pencil className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Eliminar"
                            aria-label={`Eliminar ${departamento.nombreDepartamento}`}
                            onClick={() => setAEliminar(departamento)}
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
            Mostrando {mostrados.length} de {resultado.length} departamento
            {resultado.length === 1 ? "" : "s"}
            {termino || filtroPais !== SIN_FILTRO ? ` (${data.items.length} en total)` : ""}
          </p>
        )}

        <DepartamentoFormDialog
          open={creando || editando !== null}
          departamento={editando}
          // Al crear con un país filtrado, ese país viene preseleccionado: es
          // el que la persona está mirando.
          idPaisPorDefecto={filtroPais === SIN_FILTRO ? undefined : Number(filtroPais)}
          onClose={() => {
            setCreando(false);
            setEditando(null);
          }}
        />

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreDepartamento}?</AlertDialogTitle>
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

function DepartamentoFormDialog({
  open,
  departamento,
  idPaisPorDefecto,
  onClose,
}: {
  open: boolean;
  departamento: Departamento | null;
  idPaisPorDefecto: number | undefined;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = departamento !== null;

  const { data: paises, isPending: cargandoPaises } = useQuery({
    queryKey: ["paises"],
    queryFn: () => api.paises.listar(),
  });

  const paisesOpciones = (paises?.items ?? []).map((p) => ({
    valor: String(p.id),
    etiqueta: p.nombrePais,
    descripcion: p.codigoPais ?? undefined,
  }));

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Sin defaults React avisa por inputs no controlados. Un alta nace activa:
    // cargar un departamento para dejarlo inactivo de entrada no tiene sentido.
    values: {
      idPais: String(departamento?.idPais ?? idPaisPorDefecto ?? ""),
      nombreDepartamento: departamento?.nombreDepartamento ?? "",
      activo: departamento ? esActivo(departamento.activo) : true,
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const activo: Estado = v.activo ? "A" : "I";
      return esEdicion
        ? api.departamentos.actualizar(departamento.id, {
            idPais: Number(v.idPais),
            nombreDepartamento: v.nombreDepartamento,
            activo,
          })
        : api.departamentos.crear({
            idPais: Number(v.idPais),
            nombreDepartamento: v.nombreDepartamento,
          });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["departamentos"] });
      toast.success(esEdicion ? "Departamento actualizado" : "Departamento creado");
      onClose();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear el departamento"),
      ),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar departamento" : "Nuevo departamento"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos del departamento."
              : "Agregá un departamento a un país."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
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
            />

            <FormField
              control={form.control}
              name="nombreDepartamento"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre del departamento</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Central" autoComplete="off" />
                  </FormControl>
                  <FormDescription>No puede repetirse dentro del mismo país.</FormDescription>
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
                        Un departamento inactivo deja de ofrecerse en los formularios.
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
                    : "Crear departamento"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/departamentos")({
  head: () => ({
    meta: [
      { title: "Departamentos | CTELL" },
      { name: "description", content: "Departamentos por país del sistema." },
    ],
  }),
  component: DepartamentosPage,
});
