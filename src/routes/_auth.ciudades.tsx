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
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type Ciudad, type Estado } from "@/lib/api";
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
  idDepartamento: z.string().min(1, "Elegí un departamento"),
  nombreCiudad: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
  activo: z.boolean(),
});

type FormValues = z.infer<typeof schema>;

/** Valor del filtro que significa "sin filtrar". El combobox no admite "". */
const TODOS = "todos";

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

function CiudadesPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Ciudad | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Ciudad | null>(null);
  const [filtroDepartamento, setFiltroDepartamento] = useState<string>(TODOS);

  // El filtro se aplica en el backend (?idDepartamento=): la query lleva el
  // departamento en la key para que cada selección tenga su propia entrada en
  // la caché.
  const idDepartamentoFiltro =
    filtroDepartamento === TODOS ? undefined : Number(filtroDepartamento);

  const { data, isPending, isError, error } = useQuery({
    queryKey: ["ciudades", idDepartamentoFiltro ?? null],
    queryFn: () =>
      api.ciudades.listar(idDepartamentoFiltro ? { idDepartamento: idDepartamentoFiltro } : {}),
  });

  // Los departamentos alimentan el filtro y el formulario. Se piden una vez acá
  // y TanStack Query los comparte con el dialog por la misma queryKey — la
  // misma que usa la página de Departamentos cuando lista sin filtrar.
  const { data: departamentos } = useQuery({
    queryKey: ["departamentos", null],
    queryFn: () => api.departamentos.listar(),
  });

  const eliminar = useMutation({
    mutationFn: (ciudad: Ciudad) => api.ciudades.eliminar(ciudad.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["ciudades"] });
      toast.success("Ciudad eliminada");
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
    (c) => [c.nombreCiudad, c.departamento, c.pais, esActivo(c.activo) ? "Activo" : "Inactivo"],
  );

  const departamentosOpciones = (departamentos?.items ?? []).map((d) => ({
    valor: String(d.id),
    etiqueta: d.nombreDepartamento,
    descripcion: d.pais,
  }));

  return (
    <AppLayout active="/ciudades" title="Ciudades">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Ciudades</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Ciudades de cada departamento disponibles en el sistema.
            </p>
          </div>
          <Button onClick={() => setCreando(true)}>
            <Plus className="size-4" />
            Nueva ciudad
          </Button>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-48 flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
              placeholder="Buscar por ciudad, departamento…"
              className="pl-9"
            />
          </div>
          <div className="flex items-center gap-2">
            <span className="shrink-0 text-sm text-muted-foreground">Departamento</span>
            <div className="w-full sm:w-64">
              <Combobox
                opciones={[
                  { valor: TODOS, etiqueta: "Todos los departamentos" },
                  ...departamentosOpciones,
                ]}
                value={filtroDepartamento}
                onChange={setFiltroDepartamento}
                placeholder="Todos los departamentos"
                buscarPlaceholder="Buscar departamento…"
              />
            </div>
          </div>
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
                : filtroDepartamento === TODOS
                  ? "Todavía no hay ciudades cargadas."
                  : "Ese departamento todavía no tiene ciudades cargadas."}
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
            {resultado.map((ciudad) => {
              const activo = esActivo(ciudad.activo);

              return (
                <li key={ciudad.id} className="surface-card p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">
                        {ciudad.nombreCiudad}
                      </p>
                      <p className="mt-0.5 text-xs text-muted-foreground">{ciudad.departamento}</p>
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
                      onClick={() => setEditando(ciudad)}
                    >
                      <Pencil className="size-4" />
                      Editar
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                      onClick={() => setAEliminar(ciudad)}
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
                    direccion={orden?.campo === "nombreCiudad" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreCiudad")}
                  >
                    Ciudad
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "departamento" ? orden.direccion : null}
                    onClick={() => alternarOrden("departamento")}
                  >
                    Departamento
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
                {resultado.map((ciudad) => {
                  const activo = esActivo(ciudad.activo);

                  return (
                    <TableRow key={ciudad.id}>
                      <TableCell className="font-medium text-foreground">
                        {ciudad.nombreCiudad}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {ciudad.departamento}
                        {ciudad.pais ? ` (${ciudad.pais})` : ""}
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
                            aria-label={`Editar ${ciudad.nombreCiudad}`}
                            onClick={() => setEditando(ciudad)}
                          >
                            <Pencil className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Eliminar"
                            aria-label={`Eliminar ${ciudad.nombreCiudad}`}
                            onClick={() => setAEliminar(ciudad)}
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

        {data && resultado.length > 0 && (
          <p className="text-xs text-muted-foreground">
            {resultado.length} de {data.items.length} ciudad
            {data.items.length === 1 ? "" : "es"}
          </p>
        )}

        <CiudadFormDialog
          open={creando || editando !== null}
          ciudad={editando}
          // Al crear con un departamento filtrado, ese departamento viene
          // preseleccionado: es el que la persona está mirando.
          idDepartamentoPorDefecto={idDepartamentoFiltro}
          onClose={() => {
            setCreando(false);
            setEditando(null);
          }}
        />

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreCiudad}?</AlertDialogTitle>
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

function CiudadFormDialog({
  open,
  ciudad,
  idDepartamentoPorDefecto,
  onClose,
}: {
  open: boolean;
  ciudad: Ciudad | null;
  idDepartamentoPorDefecto: number | undefined;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = ciudad !== null;

  const { data: departamentos, isPending: cargandoDepartamentos } = useQuery({
    queryKey: ["departamentos", null],
    queryFn: () => api.departamentos.listar(),
  });

  const departamentosOpciones = (departamentos?.items ?? []).map((d) => ({
    valor: String(d.id),
    etiqueta: d.nombreDepartamento,
    descripcion: d.pais,
  }));

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Sin defaults React avisa por inputs no controlados. Un alta nace activa:
    // cargar una ciudad para dejarla inactiva de entrada no tiene sentido.
    values: {
      idDepartamento: String(ciudad?.idDepartamento ?? idDepartamentoPorDefecto ?? ""),
      nombreCiudad: ciudad?.nombreCiudad ?? "",
      activo: ciudad ? esActivo(ciudad.activo) : true,
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const activo: Estado = v.activo ? "A" : "I";
      return esEdicion
        ? api.ciudades.actualizar(ciudad.id, {
            idDepartamento: Number(v.idDepartamento),
            nombreCiudad: v.nombreCiudad,
            activo,
          })
        : api.ciudades.crear({
            idDepartamento: Number(v.idDepartamento),
            nombreCiudad: v.nombreCiudad,
          });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["ciudades"] });
      toast.success(esEdicion ? "Ciudad actualizada" : "Ciudad creada");
      onClose();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear la ciudad"),
      ),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar ciudad" : "Nueva ciudad"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos de la ciudad."
              : "Agregá una ciudad a un departamento."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="idDepartamento"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Departamento</FormLabel>
                  <FormControl>
                    <Combobox
                      opciones={departamentosOpciones}
                      value={field.value}
                      onChange={field.onChange}
                      placeholder="Elegí un departamento"
                      buscarPlaceholder="Buscar departamento…"
                      cargando={cargandoDepartamentos}
                    />
                  </FormControl>
                  <FormDescription>La ciudad pertenece a este departamento.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="nombreCiudad"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre de la ciudad</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Asunción" autoComplete="off" />
                  </FormControl>
                  <FormDescription>
                    No puede repetirse dentro del mismo departamento.
                  </FormDescription>
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
                        Una ciudad inactiva deja de ofrecerse en los formularios.
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
                {guardar.isPending ? "Guardando…" : esEdicion ? "Guardar cambios" : "Crear ciudad"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/ciudades")({
  head: () => ({
    meta: [
      { title: "Ciudades | CTELL" },
      { name: "description", content: "Ciudades por departamento del sistema." },
    ],
  }),
  component: CiudadesPage,
});
