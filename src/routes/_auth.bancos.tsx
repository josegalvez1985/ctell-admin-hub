import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Landmark, Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type Banco, type Estado } from "@/lib/api";
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
import { tituloPagina } from "@/lib/marca";

const schema = z.object({
  nombreBanco: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
  descripcion: z.string().trim().max(200, "Máximo 200 caracteres"),
  activo: z.boolean(),
});
type FormValues = z.infer<typeof schema>;
const mensajeError = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;
const opcionesEstado = [
  { valor: "A", etiqueta: "Activo" },
  { valor: "I", etiqueta: "Inactivo" },
];

function BancosPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Banco | null>(null);
  const [creando, setCreando] = useState(false);
  const [filtroEstado, setFiltroEstado] = useState(SIN_FILTRO);
  const [aEliminar, setAEliminar] = useState<Banco | null>(null);
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["bancos"],
    queryFn: () => api.bancos.listar(),
  });
  const filtrados = (data?.items ?? []).filter(
    (banco) => filtroEstado === SIN_FILTRO || banco.activo === filtroEstado,
  );
  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    filtrados,
    (banco) => [
      banco.nombreBanco,
      banco.descripcion,
      esActivo(banco.activo) ? "Activo" : "Inactivo",
    ],
  );
  const eliminar = useMutation({
    mutationFn: (banco: Banco) => api.bancos.eliminar(banco.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["bancos"] });
      toast.success("Banco eliminado");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(mensajeError(e, "No se pudo eliminar el banco"));
      setAEliminar(null);
    },
  });

  return (
    <AppLayout active="/bancos" title="Bancos">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Bancos</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Entidades bancarias disponibles para la operación.
            </p>
          </div>
          <Button onClick={() => setCreando(true)}>
            <Plus className="size-4" />
            Nuevo banco
          </Button>
        </div>
        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre o descripción..."
            className="pl-9"
          />
        </div>
        {isPending && (
          <div className="space-y-2">
            {[0, 1, 2, 3].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        )}
        {isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
            {mensajeError(error, "No se pudo cargar la lista")}
          </p>
        )}
        {!isPending && !isError && resultado.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {termino
                ? `Sin resultados para "${busqueda.trim()}".`
                : "Todavía no hay bancos cargados."}
            </p>
            {!termino && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                <Plus className="size-4" />
                Cargar el primero
              </Button>
            )}
          </div>
        )}
        {resultado.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {resultado.map((banco) => {
              const activo = esActivo(banco.activo);
              return (
                <li key={banco.id} className="surface-card p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">{banco.nombreBanco}</p>
                      <p className="mt-1 line-clamp-2 text-xs text-muted-foreground">
                        {banco.descripcion || "Sin descripción"}
                      </p>
                    </div>
                    <Badge variant={activo ? "secondary" : "outline"}>
                      {activo ? "Activo" : "Inactivo"}
                    </Badge>
                  </div>
                  <div className="mt-3 flex gap-2 border-t border-border pt-3">
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1"
                      onClick={() => setEditando(banco)}
                    >
                      <Pencil className="size-4" />
                      Editar
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                      onClick={() => setAEliminar(banco)}
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
                    direccion={orden?.campo === "nombreBanco" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreBanco")}
                  >
                    Banco
                  </TableHeadOrdenable>
                  <TableHead>Descripción</TableHead>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "activo" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("activo")}
                    opciones={opcionesEstado}
                    valor={filtroEstado}
                    onFiltrar={setFiltroEstado}
                    buscarPlaceholder="Buscar estado..."
                  >
                    Estado
                  </TableHeadFiltrable>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {resultado.map((banco) => {
                  const activo = esActivo(banco.activo);
                  return (
                    <TableRow key={banco.id}>
                      <TableCell className="font-medium text-foreground">
                        <span className="inline-flex items-center gap-2">
                          <Landmark className="size-4 text-muted-foreground" />
                          {banco.nombreBanco}
                        </span>
                      </TableCell>
                      <TableCell className="max-w-md text-muted-foreground">
                        {banco.descripcion || "—"}
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
                            aria-label={`Editar ${banco.nombreBanco}`}
                            onClick={() => setEditando(banco)}
                          >
                            <Pencil className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Eliminar"
                            aria-label={`Eliminar ${banco.nombreBanco}`}
                            onClick={() => setAEliminar(banco)}
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
            {resultado.length} de {data.items.length} banco{data.items.length === 1 ? "" : "s"}
          </p>
        )}
        <BancoFormDialog
          open={creando || editando !== null}
          banco={editando}
          onClose={() => {
            setCreando(false);
            setEditando(null);
          }}
        />
        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreBanco}?</AlertDialogTitle>
              <AlertDialogDescription>Esta acción no se puede deshacer.</AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancelar</AlertDialogCancel>
              <AlertDialogAction
                onClick={(e) => {
                  e.preventDefault();
                  if (aEliminar) eliminar.mutate(aEliminar);
                }}
                disabled={eliminar.isPending}
                className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              >
                {eliminar.isPending && <Loader2 className="size-4 animate-spin" />}Eliminar
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </main>
    </AppLayout>
  );
}

function BancoFormDialog({
  open,
  banco,
  onClose,
}: {
  open: boolean;
  banco: Banco | null;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = banco !== null;
  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    values: {
      nombreBanco: banco?.nombreBanco ?? "",
      descripcion: banco?.descripcion ?? "",
      activo: banco ? esActivo(banco.activo) : true,
    },
  });
  const guardar = useMutation({
    mutationFn: (v: FormValues) =>
      esEdicion
        ? api.bancos.actualizar(banco.id, {
            nombreBanco: v.nombreBanco,
            descripcion: v.descripcion,
            activo: (v.activo ? "A" : "I") as Estado,
          })
        : api.bancos.crear({ nombreBanco: v.nombreBanco, descripcion: v.descripcion }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["bancos"] });
      toast.success(esEdicion ? "Banco actualizado" : "Banco creado");
      onClose();
    },
    onError: (e) =>
      toast.error(
        mensajeError(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear el banco"),
      ),
  });
  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar banco" : "Nuevo banco"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos del banco."
              : "Agregá una entidad bancaria al catálogo."}
          </DialogDescription>
        </DialogHeader>
        <Form {...form}>
          <form
            id="banco-form"
            onSubmit={form.handleSubmit((v) => guardar.mutate(v))}
            className="space-y-4"
          >
            <FormField
              control={form.control}
              name="nombreBanco"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Banco Nacional" autoComplete="off" />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
            <FormField
              control={form.control}
              name="descripcion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Descripción</FormLabel>
                  <FormControl>
                    <Input
                      {...field}
                      placeholder="Entidad bancaria"
                      autoComplete="off"
                      maxLength={200}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
            {esEdicion && (
              <FormField
                control={form.control}
                name="activo"
                render={({ field }) => (
                  <FormItem className="flex items-center justify-between rounded-lg border border-border p-3">
                    <div className="space-y-0.5">
                      <FormLabel>Activo</FormLabel>
                      <p className="text-xs text-muted-foreground">
                        Un banco inactivo deja de ofrecerse al registrar operaciones.
                      </p>
                    </div>
                    <FormControl>
                      <Switch checked={field.value} onCheckedChange={field.onChange} />
                    </FormControl>
                  </FormItem>
                )}
              />
            )}
          </form>
        </Form>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>
            Cancelar
          </Button>
          <Button type="submit" form="banco-form" disabled={guardar.isPending}>
            {guardar.isPending && <Loader2 className="size-4 animate-spin" />}Guardar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/bancos")({
  head: () => ({
    meta: [
      { title: tituloPagina("Bancos") },
      { name: "description", content: "Catálogo de entidades bancarias." },
    ],
  }),
  component: BancosPage,
});
