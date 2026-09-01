import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { SelectorModal } from "@/components/ctell/SelectorModal";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type Pagina, type Entrada } from "@/lib/api";
import { RUTAS_APP } from "@/lib/rutas-app";
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
  // Vacío en el alta = lo calcula el backend (último de ese módulo+entrada + 1).
  // Por eso es string y no number: un `z.coerce.number()` convierte "" en 0 y
  // la página nueva se iría al principio en vez de al final.
  orden: z
    .string()
    .trim()
    .refine((v) => v === "" || /^-?\d+$/.test(v), "Tiene que ser un número entero"),
  activo: z.boolean(),
});

type FormValues = z.infer<typeof schema>;

type Vista = { tipo: "lista" } | { tipo: "alta" } | { tipo: "edicion"; pagina: Pagina };

/**
 * Rutas asignables a una página, **derivadas del router** — ver
 * [rutas-app.ts](../../lib/rutas-app.ts).
 *
 * Antes era un array a mano acá mismo, y se desincronizaba con cada página
 * nueva: la ruta existía como archivo pero no aparecía en este desplegable, así
 * que la página quedaba sin ruta válida y su ítem de menú no navegaba. **Ya no
 * hay lista que mantener**: alcanza con crear `src/routes/_auth.<algo>.tsx`.
 */
const RUTAS_DISPONIBLES = RUTAS_APP;

/**
 * La descripción de una ruta en el desplegable: dónde está ya cargada.
 *
 * `PAGINAS_UK` es `(ID_MODULO, RUTA, ENTRADA)`, así que repetir una ruta en otro
 * módulo **es válido** — dos entradas de menú al mismo destino, para dos
 * perfiles que lo buscan en lugares distintos. Por eso esto avisa en vez de
 * bloquear: quitar la opción de la lista dejaría al usuario sin entender por qué
 * falta, y volvería a cargarla con otro nombre.
 */
function describirRuta(ruta: string, paginas: Pagina[]): string {
  const usos = paginas.filter((p) => p.ruta === ruta);
  if (usos.length === 0) return ruta;
  const donde = usos.map((p) => `${p.modulo} › ${p.nombre}`).join(", ");
  return `${ruta} · Ya está en ${donde}`;
}

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

  /**
   * Los permisos de todos los usuarios, para saber qué páginas están en uso.
   *
   * Se pide entero y no por página: son pocas filas, es UNA consulta, y el
   * listado necesita el dato de todas a la vez para deshabilitar sus botones.
   * Misma queryKey que el diálogo de Permisos, así se comparte la respuesta.
   *
   * SIN FILTRAR POR EMPRESA: la página es una sola para todo el sistema y el
   * backend rechaza el borrado si está asignada en cualquiera. Filtrar acá
   * mostraría el botón habilitado para terminar en un 409.
   */
  const permisosQuery = useQuery({
    queryKey: ["usuario-paginas"],
    queryFn: () => api.usuarioPaginas.listar(),
  });

  /** Cuántos usuarios distintos tienen cada página. */
  const usuariosPorPagina = useMemo(() => {
    const cuenta = new Map<number, Set<number>>();
    for (const permiso of permisosQuery.data?.items ?? []) {
      const suyos = cuenta.get(permiso.idPagina) ?? new Set<number>();
      suyos.add(permiso.idUsuario);
      cuenta.set(permiso.idPagina, suyos);
    }
    return cuenta;
  }, [permisosQuery.data?.items]);

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

  // Búsqueda por cualquier campo visible. La lista ya viene ordenada por
  // módulo/orden desde el backend, que es lo que define el menú.
  const {
    busqueda,
    setBusqueda,
    resultado: paginas,
    termino,
  } = useTablaListado(data?.items ?? [], (p) => [
    p.nombre,
    p.modulo,
    p.ruta,
    esActivo(p.activo) ? "Activa" : "Inactiva",
  ]);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <div className="relative min-w-48 flex-1">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre, módulo o ruta…"
            className="pl-9"
          />
        </div>
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
          {termino ? `Sin resultados para "${busqueda.trim()}".` : "Todavía no hay páginas."}
        </p>
      )}

      {/* La lista scrollea DENTRO de su caja en vez de estirar el diálogo: así
          el buscador de arriba y el conteo de abajo quedan siempre visibles, y
          la rueda del mouse actúa sobre las filas y no sobre toda la pantalla.
          `scrollbar-fino` porque es un contenedor con scroll propio. */}
      {paginas.length > 0 && (
        <ul className="scrollbar-fino max-h-[45vh] divide-y divide-border overflow-y-auto rounded-lg border border-border">
          {paginas.map((pagina) => {
            const activo = esActivo(pagina.activo);
            // A cuántos usuarios se la habría que quitar antes de poder borrarla.
            const enUsoPor = usuariosPorPagina.get(pagina.id)?.size ?? 0;

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
                  {/* Deshabilitado mientras alguien la tenga asignada: el
                      backend lo rechaza con 409 igual, pero enterarse recién
                      después de confirmar un borrado es la peor forma. El
                      `title` dice a cuántos hay que quitársela primero.

                      Mientras la consulta de permisos está en vuelo el botón
                      queda habilitado —el 409 sigue cubriendo—, en vez de
                      bloquear todo el listado por un instante. */}
                  <Button
                    variant="ghost"
                    size="icon"
                    disabled={enUsoPor > 0}
                    title={
                      enUsoPor > 0
                        ? `Asignada a ${enUsoPor} ${enUsoPor === 1 ? "usuario" : "usuarios"}: quitásela en Permisos antes de borrarla`
                        : "Eliminar"
                    }
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
          {termino ? " (filtradas)" : ""}
        </p>
      )}

      <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar {aEliminar?.nombre}?</AlertDialogTitle>
            <AlertDialogDescription>
              Sólo se puede borrar una página que <strong>no</strong> tenga ningún usuario asignado.
              Esta acción no se puede deshacer.
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

  // Las páginas ya cargadas, para avisar cuándo una ruta se repite. Misma
  // queryKey que el listado de atrás: se comparte la respuesta, no se vuelve
  // a pedir.
  const { data: paginas } = useQuery({
    queryKey: ["paginas"],
    queryFn: () => api.paginas.listar(),
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
      // En el alta queda vacío a propósito: el backend le asigna el siguiente.
      orden: pagina ? String(pagina.orden) : "",
      activo: pagina ? esActivo(pagina.activo) : true,
    },
  });

  // La combinación que el UNIQUE de la base rechaza. Se mira en vivo sobre los
  // tres campos, no sólo la ruta: cambiar el módulo o la sección la resuelve.
  // En edición se excluye la propia página, que si no chocaría consigo misma.
  const idModulo = form.watch("idModulo");
  const rutaElegida = form.watch("ruta");
  const entradaElegida = form.watch("entrada");
  const duplicada = (paginas?.items ?? []).some(
    (p) =>
      p.id !== pagina?.id &&
      String(p.idModulo) === idModulo &&
      p.ruta === rutaElegida &&
      p.entrada === entradaElegida,
  );

  const guardar = useMutation({
    mutationFn: (v: FormValues) =>
      esEdicion
        ? api.paginas.actualizar(pagina.id, {
            idModulo: Number(v.idModulo),
            nombre: v.nombre,
            ruta: v.ruta,
            entrada: v.entrada as Entrada,
            orden: Number(v.orden),
            activo: v.activo ? "A" : "I",
          })
        : api.paginas.crear({
            idModulo: Number(v.idModulo),
            nombre: v.nombre,
            ruta: v.ruta,
            entrada: v.entrada as Entrada,
            // Sin orden, el backend le da el siguiente de ese módulo+entrada.
            // Mandar 0 lo mandaría al principio de la sección.
            ...(v.orden === "" ? {} : { orden: Number(v.orden) }),
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
        {/* Dos columnas: el diálogo ya es `max-w-3xl` y a una columna estos
            cinco campos empujaban el botón de guardar fuera de la pantalla. Ver
            "Un formulario entra en un pantallazo" en docs/GUIA-FRONTEND.md. */}
        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            control={form.control}
            name="idModulo"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Módulo</FormLabel>
                <FormControl>
                  <SelectorModal
                    opciones={(modulos?.items ?? []).map((m) => ({
                      valor: String(m.id),
                      etiqueta: m.nombre,
                    }))}
                    value={field.value}
                    onChange={field.onChange}
                    placeholder="Elegí un módulo"
                    titulo="Elegí un módulo"
                    buscarPlaceholder="Buscar módulo…"
                    cargando={cargandoModulos}
                  />
                </FormControl>
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
                <FormDescription>Como se lee en el menú.</FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          <FormField
            control={form.control}
            name="ruta"
            render={({ field }) => (
              <FormItem className="sm:col-span-2">
                <FormLabel>Ruta</FormLabel>
                {/* El MISMO combobox en alta y en edición.
                    Antes la edición usaba un <Input> de texto libre, y era justo
                    al revés de lo que conviene: editar es lo que se hace para
                    CORREGIR una ruta mal cargada, así que es donde más importa
                    elegir de una lista válida. Con el input, una página guardada
                    con la ruta vacía se abría mostrando un campo en blanco —sin
                    ninguna pista de qué rutas existen— y el desplegable sólo
                    aparecía al crear otra página desde cero. */}
                <FormControl>
                  <SelectorModal
                    opciones={RUTAS_DISPONIBLES.map((ruta) => ({
                      valor: ruta.valor,
                      etiqueta: ruta.label,
                      // Dónde está ya cargada, si lo está. Se MUESTRA en vez de
                      // esconderla: la misma ruta en otro módulo es válida —dos
                      // entradas al mismo destino para dos perfiles— y sacarla
                      // de la lista dejaría al usuario sin entender por qué
                      // falta. Con el dónde, decide él.
                      descripcion: describirRuta(ruta.valor, paginas?.items ?? []),
                    }))}
                    value={field.value}
                    onChange={field.onChange}
                    placeholder="Elegí una ruta disponible"
                    titulo="Elegí una ruta disponible"
                    buscarPlaceholder="Buscar ruta…"
                  />
                </FormControl>
                <FormDescription>
                  {/* Avisa cuando la ruta guardada no está entre las del router:
                      es exactamente el caso de una página que quedó apuntando a
                      una URL que no resuelve, y sin esto el combobox se ve vacío
                      sin explicar por qué. */}
                  {esEdicion &&
                  field.value &&
                  !RUTAS_DISPONIBLES.some((r) => r.valor === field.value)
                    ? `La ruta guardada ("${field.value}") no existe en el proyecto. Elegí una de la lista.`
                    : "Las rutas salen del router: si creaste la página .tsx, está acá."}
                </FormDescription>
                {/* La colisión EXACTA —mismo módulo, misma ruta, misma sección—
                    es la que el UNIQUE de la base rechaza. Se avisa mientras se
                    completa el formulario y no al guardar: descubrirlo después
                    de cargar nombre, orden y estado obliga a rehacer todo. */}
                {duplicada && (
                  <p className="text-xs font-medium text-destructive">
                    Ese módulo ya tiene esta ruta en la misma sección. Guardar va a fallar: cambiá
                    el módulo, la sección, o editá la página que ya existe.
                  </p>
                )}
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
                <FormDescription>Sección del menú.</FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          <FormField
            control={form.control}
            name="orden"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Orden {!esEdicion && "(opcional)"}</FormLabel>
                <FormControl>
                  <Input
                    {...field}
                    type="number"
                    placeholder={esEdicion ? undefined : "Automático"}
                  />
                </FormControl>
                <FormDescription>
                  {esEdicion ? "Posición en la sección." : "Vacío: se agrega al final."}
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
                <FormItem className="flex h-fit items-center justify-between gap-3 rounded-lg border border-border p-3 sm:col-span-2">
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
        </div>

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
