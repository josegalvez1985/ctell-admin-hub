import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type Modulo } from "@/lib/api";
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

const schema = z.object({
  nombre: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
  icono: z.string().trim().max(50, "Máximo 50 caracteres").optional().or(z.literal("")),
  orden: z.coerce.number().int(),
  activo: z.boolean(),
});

type FormValues = z.infer<typeof schema>;

type Vista = { tipo: "lista" } | { tipo: "alta" } | { tipo: "edicion"; modulo: Modulo };

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

export function ModulosDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const [vista, setVista] = useState<Vista>({ tipo: "lista" });

  // Cada apertura empieza en la lista: reabrir y caer en el formulario que
  // quedó a medias la vez anterior sería desconcertante.
  useEffect(() => {
    if (open) setVista({ tipo: "lista" });
  }, [open]);

  const titulos: Record<Vista["tipo"], { titulo: string; descripcion: string }> = {
    lista: {
      titulo: "Módulos",
      descripcion: "Altas, modificaciones y bajas de los módulos del sistema.",
    },
    alta: { titulo: "Nuevo módulo", descripcion: "Creá un módulo para el menú del sistema." },
    edicion: { titulo: "Editar módulo", descripcion: "Modificá los datos del módulo." },
  };

  const { titulo, descripcion } = titulos[vista.tipo];

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85vh] max-w-3xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{titulo}</DialogTitle>
          <DialogDescription>{descripcion}</DialogDescription>
        </DialogHeader>

        {vista.tipo === "lista" && <PanelLista onCambiarVista={setVista} />}
        {vista.tipo === "alta" && <PanelForm onVolver={() => setVista({ tipo: "lista" })} />}
        {vista.tipo === "edicion" && (
          <PanelForm modulo={vista.modulo} onVolver={() => setVista({ tipo: "lista" })} />
        )}
      </DialogContent>
    </Dialog>
  );
}

/* -------------------------------------------------------------------------- */
/* Lista                                                                       */
/* -------------------------------------------------------------------------- */

function PanelLista({ onCambiarVista }: { onCambiarVista: (v: Vista) => void }) {
  const queryClient = useQueryClient();
  const [aEliminar, setAEliminar] = useState<Modulo | null>(null);

  const { data, isPending, isError, error } = useQuery({
    queryKey: ["modulos"],
    queryFn: () => api.modulos.listar(),
  });

  const invalidar = () => queryClient.invalidateQueries({ queryKey: ["modulos"] });

  const eliminar = useMutation({
    mutationFn: (modulo: Modulo) => api.modulos.eliminar(modulo.id),
    onSuccess: () => {
      invalidar();
      toast.success("Módulo eliminado");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  // Búsqueda por cualquier campo visible. La lista de módulos ya viene
  // ordenada por ORDEN desde el backend, que es lo que define el menú: acá no
  // hay headers de columna que reordenar.
  const {
    busqueda,
    setBusqueda,
    resultado: modulos,
    termino,
  } = useTablaListado(data?.items ?? [], (m) => [
    m.nombre,
    m.icono,
    esActivo(m.activo) ? "Activo" : "Inactivo",
  ]);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <div className="relative min-w-48 flex-1">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre…"
            className="pl-9"
          />
        </div>
        <Button onClick={() => onCambiarVista({ tipo: "alta" })}>
          <Plus className="size-4" />
          Nuevo
        </Button>
      </div>

      {isPending && (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <Skeleton key={i} className="h-16 w-full" />
          ))}
        </div>
      )}

      {isError && (
        <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
          {MENSAJE_ERROR(error, "No se pudo cargar la lista")}
        </p>
      )}

      {!isPending && !isError && modulos.length === 0 && (
        <p className="px-3 py-10 text-center text-sm text-muted-foreground">
          {termino ? `Sin resultados para "${busqueda.trim()}".` : "Todavía no hay módulos."}
        </p>
      )}

      {modulos.length > 0 && (
        <ul className="divide-y divide-border rounded-lg border border-border">
          {modulos.map((modulo) => {
            const activo = esActivo(modulo.activo);

            return (
              <li
                key={modulo.id}
                className="flex flex-wrap items-center justify-between gap-3 px-3 py-3"
              >
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-semibold text-foreground">{modulo.nombre}</p>
                  <p className="truncate text-xs text-muted-foreground">
                    {modulo.icono ? `${modulo.icono} · ` : ""}orden {modulo.orden}
                  </p>
                </div>

                <Badge variant={activo ? "secondary" : "outline"} className="shrink-0">
                  {activo ? "Activo" : "Inactivo"}
                </Badge>

                <div className="flex shrink-0 gap-1">
                  <Button
                    variant="ghost"
                    size="icon"
                    title="Editar"
                    aria-label={`Editar ${modulo.nombre}`}
                    onClick={() => onCambiarVista({ tipo: "edicion", modulo })}
                  >
                    <Pencil className="size-4" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    title="Eliminar"
                    aria-label={`Eliminar ${modulo.nombre}`}
                    onClick={() => setAEliminar(modulo)}
                  >
                    <Trash2 className="size-4 text-destructive" />
                  </Button>
                </div>
              </li>
            );
          })}
        </ul>
      )}

      {data && modulos.length > 0 && (
        <p className="text-xs text-muted-foreground">
          {modulos.length} de {data.total} módulo{data.total === 1 ? "" : "s"}
          {termino ? " (filtrados)" : ""}
        </p>
      )}

      <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar {aEliminar?.nombre}?</AlertDialogTitle>
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
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Alta / Edición                                                              */
/* -------------------------------------------------------------------------- */

function PanelForm({ modulo, onVolver }: { modulo?: Modulo; onVolver: () => void }) {
  const queryClient = useQueryClient();
  const esEdicion = modulo !== undefined;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Sin defaults React avisa por inputs no controlados. Un alta nace activa:
    // crear un módulo para dejarlo inactivo de entrada no tiene sentido.
    defaultValues: {
      nombre: modulo?.nombre ?? "",
      icono: modulo?.icono ?? "",
      orden: modulo?.orden ?? 0,
      activo: modulo ? esActivo(modulo.activo) : true,
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) =>
      esEdicion
        ? api.modulos.actualizar(modulo.id, {
            nombre: v.nombre,
            orden: v.orden,
            activo: v.activo ? "A" : "I",
            ...(v.icono ? { icono: v.icono } : {}),
          })
        : api.modulos.crear({
            nombre: v.nombre,
            orden: v.orden,
            ...(v.icono ? { icono: v.icono } : {}),
          }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["modulos"] });
      toast.success(esEdicion ? "Módulo actualizado" : "Módulo creado");
      onVolver();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear el módulo"),
      ),
  });

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
        <FormField
          control={form.control}
          name="nombre"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Nombre</FormLabel>
              <FormControl>
                <Input {...field} placeholder="Compras" autoComplete="off" />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="icono"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Ícono (opcional)</FormLabel>
              <FormControl>
                <Input {...field} placeholder="ShoppingCart" autoComplete="off" />
              </FormControl>
              <FormDescription>Nombre del ícono de lucide-react.</FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="orden"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Orden</FormLabel>
              <FormControl>
                <Input {...field} type="number" />
              </FormControl>
              <FormDescription>Define la posición en el menú.</FormDescription>
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
                    Un módulo inactivo y sus páginas desaparecen del menú.
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
          <Button type="button" variant="outline" onClick={onVolver}>
            Cancelar
          </Button>
          <Button type="submit" disabled={guardar.isPending}>
            {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
            {guardar.isPending ? "Guardando…" : esEdicion ? "Guardar cambios" : "Crear módulo"}
          </Button>
        </DialogFooter>
      </form>
    </Form>
  );
}
