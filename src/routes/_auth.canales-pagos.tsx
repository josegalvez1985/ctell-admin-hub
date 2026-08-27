import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type CanalPago, type Estado } from "@/lib/api";
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
  nombreCanal: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
  descripcion: z.string().trim().max(200, "Máximo 200 caracteres"),
  indBanco: z.boolean(),
  activo: z.boolean(),
});

type FormValues = z.infer<typeof schema>;
const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;
const OPCIONES_ESTADO = [
  { valor: "A", etiqueta: "Activo" },
  { valor: "I", etiqueta: "Inactivo" },
];

function CanalesPagosPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<CanalPago | null>(null);
  const [creando, setCreando] = useState(false);
  const [filtroEstado, setFiltroEstado] = useState(SIN_FILTRO);
  const [aEliminar, setAEliminar] = useState<CanalPago | null>(null);

  const { data, isPending, isError, error } = useQuery({
    queryKey: ["canales-pagos"],
    queryFn: () => api.canalesPagos.listar(),
  });

  const filtrados = (data?.items ?? []).filter(
    (canal) => filtroEstado === SIN_FILTRO || canal.activo === filtroEstado,
  );
  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    filtrados,
    (canal) => [
      canal.nombreCanal,
      canal.descripcion,
      esActivo(canal.activo) ? "Activo" : "Inactivo",
    ],
  );

  const eliminar = useMutation({
    mutationFn: (canal: CanalPago) => api.canalesPagos.eliminar(canal.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["canales-pagos"] });
      toast.success("Canal de pago eliminado");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar el canal de pago"));
      setAEliminar(null);
    },
  });

  return (
    <AppLayout active="/canales-pagos" title="Canales de pago">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Canales de pago</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Medios disponibles para registrar pagos y cobros.
            </p>
          </div>
          <Button onClick={() => setCreando(true)}>
            <Plus className="size-4" />
            Nuevo canal
          </Button>
        </div>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre o descripción…"
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
            {MENSAJE_ERROR(error, "No se pudo cargar la lista")}
          </p>
        )}
        {!isPending && !isError && resultado.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {termino
                ? `Sin resultados para "${busqueda.trim()}".`
                : "Todavía no hay canales cargados."}
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
            {resultado.map((canal) => {
              const activo = esActivo(canal.activo);
              return (
                <li key={canal.id} className="surface-card p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">{canal.nombreCanal}</p>
                      <p className="mt-1 line-clamp-2 text-xs text-muted-foreground">
                        {canal.descripcion || "Sin descripción"}
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
                      onClick={() => setEditando(canal)}
                    >
                      <Pencil className="size-4" />
                      Editar
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                      onClick={() => setAEliminar(canal)}
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
                    direccion={orden?.campo === "nombreCanal" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreCanal")}
                  >
                    Canal
                  </TableHeadOrdenable>
                  <TableHead>Descripción</TableHead>
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
                {resultado.map((canal) => {
                  const activo = esActivo(canal.activo);
                  return (
                    <TableRow key={canal.id}>
                      <TableCell className="font-medium text-foreground">
                        {canal.nombreCanal}
                      </TableCell>
                      <TableCell className="max-w-md text-muted-foreground">
                        {canal.descripcion || "—"}
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
                            aria-label={`Editar ${canal.nombreCanal}`}
                            onClick={() => setEditando(canal)}
                          >
                            <Pencil className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Eliminar"
                            aria-label={`Eliminar ${canal.nombreCanal}`}
                            onClick={() => setAEliminar(canal)}
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
            {resultado.length} de {data.items.length} canal{data.items.length === 1 ? "" : "es"}
          </p>
        )}

        <CanalPagoFormDialog
          open={creando || editando !== null}
          canal={editando}
          onClose={() => {
            setCreando(false);
            setEditando(null);
          }}
        />
        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreCanal}?</AlertDialogTitle>
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

function CanalPagoFormDialog({
  open,
  canal,
  onClose,
}: {
  open: boolean;
  canal: CanalPago | null;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = canal !== null;
  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    values: {
      nombreCanal: canal?.nombreCanal ?? "",
      descripcion: canal?.descripcion ?? "",
      indBanco: canal?.indBanco === "S",
      activo: canal ? esActivo(canal.activo) : true,
    },
  });
  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const activo: Estado = v.activo ? "A" : "I";
      const indBanco: "S" | "N" = v.indBanco ? "S" : "N";
      return esEdicion
        ? api.canalesPagos.actualizar(canal.id, {
            nombreCanal: v.nombreCanal,
            descripcion: v.descripcion,
            indBanco,
            activo,
          })
        : api.canalesPagos.crear({
            nombreCanal: v.nombreCanal,
            descripcion: v.descripcion,
            indBanco,
          });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["canales-pagos"] });
      toast.success(esEdicion ? "Canal actualizado" : "Canal creado");
      onClose();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear el canal"),
      ),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar canal de pago" : "Nuevo canal de pago"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos del canal."
              : "Agregá un medio para registrar pagos y cobros."}
          </DialogDescription>
        </DialogHeader>
        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="nombreCanal"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Transferencia bancaria" autoComplete="off" />
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
                      placeholder="Pago mediante transferencia"
                      autoComplete="off"
                      maxLength={200}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
            <FormField
              control={form.control}
              name="indBanco"
              render={({ field }) => (
                <FormItem className="flex items-center justify-between rounded-lg border border-border p-3">
                  <div className="space-y-0.5">
                    <FormLabel>Requiere cuenta bancaria</FormLabel>
                    <p className="text-xs text-muted-foreground">
                      Al cobrar por este canal se pide a qué cuenta entró la plata. Dejalo apagado
                      para el efectivo.
                    </p>
                  </div>
                  <FormControl>
                    <Switch checked={field.value} onCheckedChange={field.onChange} />
                  </FormControl>
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
                        Un canal inactivo deja de ofrecerse al registrar operaciones.
                      </p>
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
                {guardar.isPending ? "Guardando…" : esEdicion ? "Guardar cambios" : "Crear canal"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/canales-pagos")({
  head: () => ({
    meta: [
      { title: tituloPagina("Canales de pago") },
      { name: "description", content: "Catálogo de canales de pago y cobro." },
    ],
  }),
  component: CanalesPagosPage,
});
