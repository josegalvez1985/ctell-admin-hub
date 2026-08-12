import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { api, ApiError, esActivo, type Pagina, type Entrada } from "@/lib/api";
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";

const schema = z.object({
  idModulo: z.string().min(1, "Elegí un módulo"),
  nombre: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
  ruta: z.string().min(1, "Obligatorio").max(200, "Máximo 200 caracteres"),
  entrada: z.enum(["D", "O", "R"], { message: "Elegí una entrada válida" }),
  orden: z.coerce.number().int(),
  activo: z.boolean(),
});

type FormValues = z.infer<typeof schema>;

type Vista = { tipo: "lista" } | { tipo: "alta" } | { tipo: "edicion"; pagina: Pagina };

// Rutas disponibles en el proyecto (deben coincidir con src/routes/_auth*.tsx)
const RUTAS_DISPONIBLES = [
  { valor: "/home", label: "Dashboard" },
  { valor: "/configuracion", label: "Configuración" },
  { valor: "/menu", label: "Menú" },
  { valor: "/administracion", label: "Administración" },
  { valor: "/paises", label: "Países" },
];

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

export function PaginasDialog({
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
      titulo: "Páginas",
      descripcion: "Altas, modificaciones y bajas de las páginas de cada módulo.",
    },
    alta: { titulo: "Nueva página", descripcion: "Creá una página dentro de un módulo." },
    edicion: { titulo: "Editar página", descripcion: "Modificá los datos de la página." },
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
          <PanelForm pagina={vista.pagina} onVolver={() => setVista({ tipo: "lista" })} />
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
  const [aEliminar, setAEliminar] = useState<Pagina | null>(null);

  const { data, isPending, isError, error } = useQuery({
    queryKey: ["paginas"],
    queryFn: () => api.paginas.listar(),
  });

  const eliminar = useMutation({
    mutationFn: (pagina: Pagina) => api.paginas.eliminar(pagina.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["paginas"] });
      toast.success("Página eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  const paginas = data?.items ?? [];

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-end">
        <Button onClick={() => onCambiarVista({ tipo: "alta" })}>
          <Plus className="size-4" />
          Nueva
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

      {!isPending && !isError && paginas.length === 0 && (
        <p className="px-3 py-10 text-center text-sm text-muted-foreground">
          Todavía no hay páginas.
        </p>
      )}

      {paginas.length > 0 && (
        <ul className="divide-y divide-border rounded-lg border border-border">
          {paginas.map((pagina) => {
            const activo = esActivo(pagina.activo);

            return (
              <li
                key={pagina.id}
                className="flex flex-wrap items-center justify-between gap-3 px-3 py-3"
              >
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-semibold text-foreground">{pagina.nombre}</p>
                  <p className="truncate text-xs text-muted-foreground">
                    {pagina.modulo} · orden {pagina.orden}
                  </p>
                </div>

                <Badge variant={activo ? "secondary" : "outline"} className="shrink-0">
                  {activo ? "Activa" : "Inactiva"}
                </Badge>

                <div className="flex shrink-0 gap-1">
                  <Button
                    variant="ghost"
                    size="icon"
                    title="Editar"
                    aria-label={`Editar ${pagina.nombre}`}
                    onClick={() => onCambiarVista({ tipo: "edicion", pagina })}
                  >
                    <Pencil className="size-4" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    title="Eliminar"
                    aria-label={`Eliminar ${pagina.nombre}`}
                    onClick={() => setAEliminar(pagina)}
                  >
                    <Trash2 className="size-4 text-destructive" />
                  </Button>
                </div>
              </li>
            );
          })}
        </ul>
      )}

      {data && paginas.length > 0 && (
        <p className="text-xs text-muted-foreground">
          {paginas.length} de {data.total} página{data.total === 1 ? "" : "s"}
        </p>
      )}

      <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar {aEliminar?.nombre}?</AlertDialogTitle>
            <AlertDialogDescription>
              Se pierden también los permisos que los usuarios tuvieran sobre esta página. Esta
              acción no se puede deshacer.
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
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Alta / Edición                                                              */
/* -------------------------------------------------------------------------- */

function PanelForm({ pagina, onVolver }: { pagina?: Pagina; onVolver: () => void }) {
  const queryClient = useQueryClient();
  const esEdicion = pagina !== undefined;

  // Se necesitan los módulos para el selector: una página siempre pertenece a
  // uno, y el backend rechaza un idModulo inexistente con 400.
  const { data: modulos, isPending: cargandoModulos } = useQuery({
    queryKey: ["modulos"],
    queryFn: () => api.modulos.listar(),
  });

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Sin defaults React avisa por inputs no controlados.
    // Un alta nace activa: crear una página para dejarla inactiva de entrada
    // no tiene sentido.
    defaultValues: {
      idModulo: pagina ? String(pagina.idModulo) : "",
      nombre: pagina?.nombre ?? "",
      ruta: pagina?.ruta ?? "",
      entrada: pagina?.entrada ?? "O",
      orden: pagina?.orden ?? 0,
      activo: pagina ? esActivo(pagina.activo) : true,
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) =>
      esEdicion
        ? api.paginas.actualizar(pagina.id, {
            idModulo: Number(v.idModulo),
            nombre: v.nombre,
            ruta: v.ruta,
            entrada: v.entrada as Entrada,
            orden: v.orden,
            activo: v.activo ? "A" : "I",
          })
        : api.paginas.crear({
            idModulo: Number(v.idModulo),
            nombre: v.nombre,
            ruta: v.ruta,
            entrada: v.entrada as Entrada,
            orden: v.orden,
          }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["paginas"] });
      toast.success(esEdicion ? "Página actualizada" : "Página creada");
      onVolver();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear la página"),
      ),
  });

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
        <FormField
          control={form.control}
          name="idModulo"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Módulo</FormLabel>
              <Select value={field.value} onValueChange={field.onChange} disabled={cargandoModulos}>
                <FormControl>
                  <SelectTrigger>
                    <SelectValue placeholder={cargandoModulos ? "Cargando…" : "Elegí un módulo"} />
                  </SelectTrigger>
                </FormControl>
                <SelectContent>
                  {(modulos?.items ?? []).map((m) => (
                    <SelectItem key={m.id} value={String(m.id)}>
                      {m.nombre}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FormDescription>La página se muestra dentro de este módulo.</FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="nombre"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Nombre</FormLabel>
              <FormControl>
                <Input {...field} placeholder="Órdenes de compra" autoComplete="off" />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="ruta"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Ruta</FormLabel>
              {esEdicion ? (
                <FormControl>
                  <Input
                    {...field}
                    placeholder="/compras/ordenes"
                    autoComplete="off"
                  />
                </FormControl>
              ) : (
                <Select value={field.value} onValueChange={field.onChange}>
                  <FormControl>
                    <SelectTrigger>
                      <SelectValue placeholder="Elegí una ruta disponible" />
                    </SelectTrigger>
                  </FormControl>
                  <SelectContent>
                    {RUTAS_DISPONIBLES.map((ruta) => (
                      <SelectItem key={ruta.valor} value={ruta.valor}>
                        {ruta.label} ({ruta.valor})
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
              <FormDescription>
                {esEdicion
                  ? "Ruta del archivo .tsx en el proyecto."
                  : "Selecciona una ruta disponible del proyecto."}
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="entrada"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Entrada</FormLabel>
              <Select value={field.value} onValueChange={field.onChange}>
                <FormControl>
                  <SelectTrigger>
                    <SelectValue placeholder="Elegí una entrada" />
                  </SelectTrigger>
                </FormControl>
                <SelectContent>
                  <SelectItem value="D">Definiciones</SelectItem>
                  <SelectItem value="O">Operaciones</SelectItem>
                  <SelectItem value="R">Reportes</SelectItem>
                </SelectContent>
              </Select>
              <FormDescription>Sección donde aparece la página en el menú.</FormDescription>
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
              <FormDescription>Define la posición dentro del módulo.</FormDescription>
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
                  <FormLabel>Activa</FormLabel>
                  <FormDescription>
                    Una página inactiva desaparece del menú de todos los usuarios.
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
            {guardar.isPending ? "Guardando…" : esEdicion ? "Guardar cambios" : "Crear página"}
          </Button>
        </DialogFooter>
      </form>
    </Form>
  );
}
