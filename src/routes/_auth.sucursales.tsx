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
  idEmpresa: z.string().min(1, "Elegí una empresa"),
  nombreSucursal: z.string().trim().min(1, "Obligatorio").max(150, "Máximo 150 caracteres"),
  codigoSucursal: z.string().trim().min(1, "Obligatorio").max(20, "Máximo 20 caracteres"),
  direccion: z.string().trim().max(255, "Máximo 255 caracteres"),
  telefono: z.string().trim().max(20, "Máximo 20 caracteres"),
  activo: z.boolean(),
});

type FormValues = z.infer<typeof schema>;

/** Valor del filtro que significa "sin filtrar". El combobox no admite "". */
const TODOS = "todos";

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

function SucursalesPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Sucursal | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Sucursal | null>(null);
  const [filtroEmpresa, setFiltroEmpresa] = useState<string>(TODOS);

  // El filtro se aplica en el backend (?idEmpresa=): la query lleva la empresa
  // en la key para que cada selección tenga su propia entrada en la caché.
  const idEmpresaFiltro = filtroEmpresa === TODOS ? undefined : Number(filtroEmpresa);

  const { data, isPending, isError, error } = useQuery({
    queryKey: ["sucursales", idEmpresaFiltro ?? null],
    queryFn: () => api.sucursales.listar(idEmpresaFiltro ? { idEmpresa: idEmpresaFiltro } : {}),
  });

  // Las empresas alimentan el filtro y el formulario. Misma queryKey que usa
  // la página de Empresas al listar sin filtrar, así se comparte la caché.
  const { data: empresas } = useQuery({
    queryKey: ["empresas", null],
    queryFn: () => api.empresas.listar(),
  });

  const eliminar = useMutation({
    mutationFn: (sucursal: Sucursal) => api.sucursales.eliminar(sucursal.id),
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
  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    data?.items ?? [],
    (s) => [
      s.nombreSucursal,
      s.codigoSucursal,
      s.empresa,
      esActivo(s.activo) ? "Activo" : "Inactivo",
    ],
  );

  const empresasOpciones = (empresas?.items ?? []).map((e) => ({
    valor: String(e.id),
    etiqueta: e.nombreEmpresa,
    descripcion: e.ruc ?? undefined,
  }));

  return (
    <AppLayout active="/sucursales" title="Sucursales">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Sucursales</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Sucursales de cada empresa del sistema.
            </p>
          </div>
          <Button onClick={() => setCreando(true)}>
            <Plus className="size-4" />
            Nueva sucursal
          </Button>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-48 flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
              placeholder="Buscar por sucursal, código, empresa…"
              className="pl-9"
            />
          </div>
          <div className="flex items-center gap-2">
            <span className="shrink-0 text-sm text-muted-foreground">Empresa</span>
            <div className="w-full sm:w-64">
              <Combobox
                opciones={[{ valor: TODOS, etiqueta: "Todas las empresas" }, ...empresasOpciones]}
                value={filtroEmpresa}
                onChange={setFiltroEmpresa}
                placeholder="Todas las empresas"
                buscarPlaceholder="Buscar empresa…"
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
                : filtroEmpresa === TODOS
                  ? "Todavía no hay sucursales cargadas."
                  : "Esa empresa todavía no tiene sucursales cargadas."}
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
            {resultado.map((sucursal) => {
              const activo = esActivo(sucursal.activo);

              return (
                <li key={sucursal.id} className="surface-card p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">
                        {sucursal.nombreSucursal}
                      </p>
                      <p className="mt-0.5 text-xs text-muted-foreground">
                        {sucursal.codigoSucursal} · {sucursal.empresa}
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
                    direccion={orden?.campo === "codigoSucursal" ? orden.direccion : null}
                    onClick={() => alternarOrden("codigoSucursal")}
                  >
                    Código
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "empresa" ? orden.direccion : null}
                    onClick={() => alternarOrden("empresa")}
                  >
                    Empresa
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
                {resultado.map((sucursal) => {
                  const activo = esActivo(sucursal.activo);

                  return (
                    <TableRow key={sucursal.id}>
                      <TableCell className="font-medium text-foreground">
                        {sucursal.nombreSucursal}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {sucursal.codigoSucursal}
                      </TableCell>
                      <TableCell className="text-muted-foreground">{sucursal.empresa}</TableCell>
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

        {data && resultado.length > 0 && (
          <p className="text-xs text-muted-foreground">
            {resultado.length} de {data.items.length} sucursal
            {data.items.length === 1 ? "" : "es"}
          </p>
        )}

        <SucursalFormDialog
          open={creando || editando !== null}
          sucursal={editando}
          // Al crear con una empresa filtrada, esa empresa viene
          // preseleccionada: es la que la persona está mirando.
          idEmpresaPorDefecto={idEmpresaFiltro}
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
  idEmpresaPorDefecto,
  onClose,
}: {
  open: boolean;
  sucursal: Sucursal | null;
  idEmpresaPorDefecto: number | undefined;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = sucursal !== null;

  const { data: empresas, isPending: cargandoEmpresas } = useQuery({
    queryKey: ["empresas", null],
    queryFn: () => api.empresas.listar(),
  });

  const empresasOpciones = (empresas?.items ?? []).map((e) => ({
    valor: String(e.id),
    etiqueta: e.nombreEmpresa,
    descripcion: e.ruc ?? undefined,
  }));

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Sin defaults React avisa por inputs no controlados. Un alta nace activa:
    // cargar una sucursal para dejarla inactiva de entrada no tiene sentido.
    values: {
      idEmpresa: String(sucursal?.idEmpresa ?? idEmpresaPorDefecto ?? ""),
      nombreSucursal: sucursal?.nombreSucursal ?? "",
      codigoSucursal: sucursal?.codigoSucursal ?? "",
      direccion: sucursal?.direccion ?? "",
      telefono: sucursal?.telefono ?? "",
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
        ...(v.telefono ? { telefono: v.telefono } : {}),
      };

      return esEdicion
        ? api.sucursales.actualizar(sucursal.id, {
            idEmpresa: Number(v.idEmpresa),
            nombreSucursal: v.nombreSucursal,
            codigoSucursal: v.codigoSucursal,
            activo,
            ...opcionales,
          })
        : api.sucursales.crear({
            idEmpresa: Number(v.idEmpresa),
            nombreSucursal: v.nombreSucursal,
            codigoSucursal: v.codigoSucursal,
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
              : "Agregá una sucursal a una empresa."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="idEmpresa"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Empresa</FormLabel>
                  <FormControl>
                    <Combobox
                      opciones={empresasOpciones}
                      value={field.value}
                      onChange={field.onChange}
                      placeholder="Elegí una empresa"
                      buscarPlaceholder="Buscar empresa…"
                      cargando={cargandoEmpresas}
                    />
                  </FormControl>
                  <FormDescription>La sucursal pertenece a esta empresa.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="nombreSucursal"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre de la sucursal</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Casa Central" autoComplete="off" />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="codigoSucursal"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Código</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="CENTRAL" autoComplete="off" />
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

            <FormField
              control={form.control}
              name="telefono"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Teléfono (opcional)</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="021 123 456" autoComplete="off" />
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
      { title: "Sucursales | CTELL" },
      { name: "description", content: "Sucursales por empresa del sistema." },
    ],
  }),
  component: SucursalesPage,
});
