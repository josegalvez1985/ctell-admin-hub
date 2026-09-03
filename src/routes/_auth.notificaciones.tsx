import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, Eye, Loader2, Pencil, Plus, Search, Trash2, Users } from "lucide-react";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type Notificacion } from "@/lib/api";
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
import { Checkbox } from "@/components/ui/checkbox";
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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Textarea } from "@/components/ui/textarea";
import { tituloPagina } from "@/lib/marca";

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Los máximos salen del DDL: `TITULO VARCHAR2(100)` y
 * `DESCRIPCION VARCHAR2(1000)`.
 *
 * Validarlos acá evita un 500 sin diagnóstico: pasarse del largo de la columna
 * da `ORA-12899` en el INSERT, que llega al navegador como "Error al crear la
 * notificación" sin decir cuál campo.
 */
const schema = z.object({
  titulo: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
  descripcion: z.string().trim().min(1, "Obligatorio").max(1000, "Máximo 1000 caracteres"),
});

type FormValues = z.infer<typeof schema>;

export const Route = createFileRoute("/_auth/notificaciones")({
  head: () => ({
    meta: [
      { title: tituloPagina("Notificaciones") },
      {
        name: "description",
        content: "Avisos enviados a profesores, con su estado de lectura.",
      },
    ],
  }),
  component: NotificacionesPage,
});

/** Fecha y hora legibles. Con hora porque dos avisos del mismo día se ordenan por ella. */
function formatearFecha(valor: string | null): string {
  if (!valor) return "—";
  const fecha = new Date(valor);
  if (Number.isNaN(fecha.getTime())) return valor;
  return new Intl.DateTimeFormat("es-PY", { dateStyle: "medium", timeStyle: "short" }).format(
    fecha,
  );
}

function NotificacionesPage() {
  const queryClient = useQueryClient();
  const { empresa } = useEmpresa();

  const [dialogoAbierto, setDialogoAbierto] = useState(false);
  const [editando, setEditando] = useState<Notificacion | null>(null);
  const [aEliminar, setAEliminar] = useState<Notificacion | null>(null);
  /** La notificación cuyo detalle de lectura se está mirando. */
  const [viendo, setViendo] = useState<Notificacion | null>(null);
  /** Los profesores elegidos en el formulario, por id. */
  const [destinatarios, setDestinatarios] = useState<number[]>([]);

  const notificaciones = useQuery({
    queryKey: ["notificaciones", empresa?.id ?? null],
    queryFn: () => api.notificaciones.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  // Los profesores para elegir destinatarios. Comparte caché con /profesores.
  const profesores = useQuery({
    queryKey: ["profesores", empresa?.id ?? null],
    queryFn: () => api.profesores.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  /**
   * El detalle de la que se está editando o mirando.
   *
   * **Hace falta sí o sí para editar**: el listado trae la descripción recortada
   * a 150 caracteres, y guardar eso escribiría el resumen encima del mensaje
   * completo. También trae los destinatarios, que el listado sólo cuenta.
   */
  const detalle = useQuery({
    queryKey: ["notificaciones", "detalle", (editando ?? viendo)?.id ?? null, empresa?.id ?? null],
    queryFn: () => api.notificaciones.obtener((editando ?? viendo)!.id, empresa!.id),
    enabled: (editando !== null || viendo !== null) && empresa !== null,
  });

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { titulo: "", descripcion: "" },
  });

  // Al abrir una edición, el formulario se llena con el DETALLE —no con la fila
  // del listado— apenas llega. Mientras carga, los campos quedan vacíos y el
  // botón de guardar deshabilitado: guardar a mitad de camino escribiría el
  // resumen encima del mensaje entero.
  useEffect(() => {
    if (editando === null) return;
    if (!detalle.data) return;
    form.reset({
      titulo: detalle.data.titulo,
      descripcion: detalle.data.descripcion ?? "",
    });
    setDestinatarios(detalle.data.destinatarios.map((d) => d.idProfesor));
  }, [editando, detalle.data, form]);

  const guardar = useMutation({
    mutationFn: async (valores: FormValues) => {
      if (editando) {
        return api.notificaciones.actualizar(editando.id, {
          idEmpresa: empresa!.id,
          titulo: valores.titulo,
          descripcion: valores.descripcion,
          destinatarios,
        });
      }
      return api.notificaciones.crear({
        idEmpresa: empresa!.id,
        titulo: valores.titulo,
        descripcion: valores.descripcion,
        destinatarios,
      });
    },
    onSuccess: () => {
      toast.success(editando ? "Notificación actualizada" : "Notificación enviada");
      queryClient.invalidateQueries({ queryKey: ["notificaciones"] });
      cerrarDialogo();
    },
    onError: (error) => toast.error(MENSAJE_ERROR(error, "No se pudo guardar la notificación")),
  });

  const eliminar = useMutation({
    mutationFn: (n: Notificacion) => api.notificaciones.eliminar(n.id, empresa!.id),
    onSuccess: () => {
      toast.success("Notificación eliminada");
      queryClient.invalidateQueries({ queryKey: ["notificaciones"] });
      setAEliminar(null);
    },
    onError: (error) => toast.error(MENSAJE_ERROR(error, "No se pudo eliminar la notificación")),
  });

  function abrirAlta() {
    setEditando(null);
    setDestinatarios([]);
    form.reset({ titulo: "", descripcion: "" });
    setDialogoAbierto(true);
  }

  function abrirEdicion(n: Notificacion) {
    setEditando(n);
    // Los campos los llena el efecto de arriba cuando llega el detalle.
    form.reset({ titulo: "", descripcion: "" });
    setDestinatarios([]);
    setDialogoAbierto(true);
  }

  function cerrarDialogo() {
    setDialogoAbierto(false);
    setEditando(null);
    setDestinatarios([]);
  }

  const items = notificaciones.data?.items ?? [];

  const { busqueda, setBusqueda, orden, alternarOrden, resultado } = useTablaListado<Notificacion>(
    items,
    (n) => [n.titulo, n.descripcionResumen],
  );

  // Sólo los activos: mandarle un aviso a alguien dado de baja no le llega a
  // nadie, y ensucia la lista de quien tiene que elegir.
  const profesoresActivos = (profesores.data?.items ?? []).filter((p) => esActivo(p.activo));

  const todosElegidos =
    profesoresActivos.length > 0 && destinatarios.length === profesoresActivos.length;

  function alternarTodos() {
    setDestinatarios(todosElegidos ? [] : profesoresActivos.map((p) => p.id));
  }

  function alternarProfesor(id: number) {
    setDestinatarios((previo) =>
      previo.includes(id) ? previo.filter((x) => x !== id) : [...previo, id],
    );
  }

  // El detalle que está cargando bloquea el guardado de una edición: ver el
  // efecto de arriba.
  const esperandoDetalle = editando !== null && detalle.isPending;

  return (
    <AppLayout active="/notificaciones" title="Notificaciones">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div className="min-w-0">
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Notificaciones</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Avisos enviados a los profesores, con su estado de lectura.
            </p>
          </div>
          <Button onClick={abrirAlta} disabled={empresa === null}>
            <Plus className="size-4" />
            Nueva notificación
          </Button>
        </div>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por título o mensaje…"
            className="pl-9"
          />
        </div>

        {empresa === null && (
          <p className="rounded-lg border border-border px-3 py-6 text-center text-sm text-muted-foreground">
            No hay una empresa activa. Cerrá sesión y volvé a entrar eligiendo una.
          </p>
        )}

        {notificaciones.isPending && empresa !== null && (
          <div className="space-y-2">
            {[0, 1, 2, 3].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        )}

        {notificaciones.isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
            {MENSAJE_ERROR(notificaciones.error, "No se pudieron cargar las notificaciones")}
          </p>
        )}

        {!notificaciones.isPending && !notificaciones.isError && resultado.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {items.length === 0
                ? "Todavía no se envió ninguna notificación."
                : "Ninguna notificación coincide con la búsqueda."}
            </p>
          </div>
        )}

        {/* Móvil: tarjetas. Seis columnas en 360px obligan a scrollear de costado. */}
        {resultado.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {resultado.map((n) => (
              <li key={n.id} className="surface-card min-w-0 p-4">
                <p className="truncate font-semibold text-foreground">{n.titulo}</p>
                <p className="mt-0.5 line-clamp-2 text-xs text-muted-foreground">
                  {n.descripcionResumen ?? "—"}
                </p>
                <div className="mt-3 flex items-center justify-between gap-3 border-t border-border pt-3">
                  <span className="text-xs text-muted-foreground">
                    {formatearFecha(n.fechaNotificacion)}
                  </span>
                  <LecturaBadge leidos={n.leidos} destinatarios={n.destinatarios} />
                </div>
                <div className="mt-2 flex justify-end gap-1">
                  <Button variant="ghost" size="icon" onClick={() => setViendo(n)} title="Ver">
                    <Eye className="size-4" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    onClick={() => abrirEdicion(n)}
                    title="Editar"
                  >
                    <Pencil className="size-4" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    onClick={() => setAEliminar(n)}
                    title="Eliminar"
                  >
                    <Trash2 className="size-4 text-destructive" />
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}

        {resultado.length > 0 && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "fechaNotificacion" ? orden.direccion : null}
                    onClick={() => alternarOrden("fechaNotificacion")}
                  >
                    Fecha
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "titulo" ? orden.direccion : null}
                    onClick={() => alternarOrden("titulo")}
                  >
                    Título
                  </TableHeadOrdenable>
                  <TableHead>Mensaje</TableHead>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "destinatarios" ? orden.direccion : null}
                    onClick={() => alternarOrden("destinatarios")}
                    className="text-right"
                  >
                    Enviada a
                  </TableHeadOrdenable>
                  <TableHead className="text-center">Lecturas</TableHead>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {resultado.map((n) => (
                  <TableRow key={n.id}>
                    <TableCell className="whitespace-nowrap text-muted-foreground">
                      {formatearFecha(n.fechaNotificacion)}
                    </TableCell>
                    <TableCell className="font-medium text-foreground">{n.titulo}</TableCell>
                    {/* max-w + truncate: el resumen son 150 caracteres y sin
                        techo estira la tabla hasta obligar a scrollear. */}
                    <TableCell className="max-w-sm truncate text-muted-foreground">
                      {n.descripcionResumen ?? "—"}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">{n.destinatarios}</TableCell>
                    <TableCell className="text-center">
                      <LecturaBadge leidos={n.leidos} destinatarios={n.destinatarios} />
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex justify-end gap-1">
                        <Button
                          variant="ghost"
                          size="icon"
                          onClick={() => setViendo(n)}
                          title="Ver quién la leyó"
                        >
                          <Eye className="size-4" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="icon"
                          onClick={() => abrirEdicion(n)}
                          title="Editar la notificación"
                        >
                          <Pencil className="size-4" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="icon"
                          onClick={() => setAEliminar(n)}
                          title="Eliminar la notificación"
                        >
                          <Trash2 className="size-4 text-destructive" />
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </main>

      {/* ---------------------------------------------------------------- */}
      {/* Alta y edición                                                    */}
      {/* ---------------------------------------------------------------- */}
      <Dialog open={dialogoAbierto} onOpenChange={(v) => !v && cerrarDialogo()}>
        <DialogContent className="sm:max-w-2xl">
          <DialogHeader>
            <DialogTitle>{editando ? "Editar notificación" : "Nueva notificación"}</DialogTitle>
            <DialogDescription>
              {editando
                ? "Los destinatarios que sigan en la lista conservan su marca de leído."
                : "El aviso se envía a los profesores que elijas."}
            </DialogDescription>
          </DialogHeader>

          {esperandoDetalle ? (
            <div className="space-y-3">
              <Skeleton className="h-9 w-full" />
              <Skeleton className="h-24 w-full" />
              <Skeleton className="h-40 w-full" />
            </div>
          ) : (
            <Form {...form}>
              <form
                id="form-notificacion"
                onSubmit={form.handleSubmit((v) => guardar.mutate(v))}
                className="space-y-4"
              >
                <FormField
                  control={form.control}
                  name="titulo"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Título</FormLabel>
                      <FormControl>
                        <Input {...field} maxLength={100} placeholder="Reunión de personal" />
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
                      <FormLabel>Mensaje</FormLabel>
                      <FormControl>
                        <Textarea
                          {...field}
                          maxLength={1000}
                          rows={4}
                          placeholder="El viernes a las 18:00 en la sala de profesores."
                        />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                {/* FUERA DE UN FormItem NO PUEDE IR NINGÚN HIJO DE ui/form:
                    FormLabel y compañía llaman a useFormField(), que lanza sin
                    su contexto y tira abajo la página entera. Los
                    destinatarios no son un campo del schema —viven en su propio
                    estado— así que van con etiquetas planas. */}
                <div className="space-y-2">
                  <div className="flex items-center justify-between gap-3">
                    <p className="text-sm font-medium">
                      Destinatarios
                      {destinatarios.length > 0 && (
                        <span className="ml-1.5 font-normal text-muted-foreground">
                          ({destinatarios.length})
                        </span>
                      )}
                    </p>
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={alternarTodos}
                      disabled={profesoresActivos.length === 0}
                    >
                      <Users className="size-4" />
                      {todosElegidos ? "Ninguno" : "Todos"}
                    </Button>
                  </div>

                  {profesores.isPending && <Skeleton className="h-40 w-full" />}

                  {!profesores.isPending && profesoresActivos.length === 0 && (
                    <p className="rounded-lg border border-dashed border-border px-3 py-6 text-center text-sm text-muted-foreground">
                      No hay profesores activos en esta empresa.
                    </p>
                  )}

                  {profesoresActivos.length > 0 && (
                    // Alto acotado y scroll propio: con treinta profesores la
                    // lista empujaría el botón de guardar fuera de la pantalla.
                    <ul className="scrollbar-fino max-h-56 space-y-1 overflow-y-auto rounded-lg border border-border p-2">
                      {profesoresActivos.map((p) => (
                        <li key={p.id}>
                          <label className="flex cursor-pointer items-center gap-2 rounded px-2 py-1.5 hover:bg-accent/60">
                            <Checkbox
                              checked={destinatarios.includes(p.id)}
                              onCheckedChange={() => alternarProfesor(p.id)}
                            />
                            <span className="min-w-0 flex-1 truncate text-sm">
                              {p.nombre} {p.apellido}
                              <span className="ml-1.5 text-xs text-muted-foreground">
                                {p.numeroCi}
                              </span>
                            </span>
                          </label>
                        </li>
                      ))}
                    </ul>
                  )}

                  {/* El backend rechaza una notificación sin destinatarios con
                      un 400; avisarlo acá evita mandar un request que se sabe
                      que va a fallar. */}
                  {destinatarios.length === 0 && (
                    <p className="text-[0.8rem] text-muted-foreground">
                      Elegí al menos un profesor.
                    </p>
                  )}
                </div>
              </form>
            </Form>
          )}

          <DialogFooter>
            <Button type="button" variant="outline" onClick={cerrarDialogo}>
              Cancelar
            </Button>
            <Button
              type="submit"
              form="form-notificacion"
              disabled={guardar.isPending || destinatarios.length === 0 || esperandoDetalle}
            >
              {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
              {editando ? "Guardar" : "Enviar"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* ---------------------------------------------------------------- */}
      {/* Quién la leyó                                                     */}
      {/* ---------------------------------------------------------------- */}
      <Dialog open={viendo !== null} onOpenChange={(v) => !v && setViendo(null)}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>{viendo?.titulo}</DialogTitle>
            <DialogDescription>
              {viendo && `${viendo.leidos} de ${viendo.destinatarios} la leyeron`}
            </DialogDescription>
          </DialogHeader>

          {detalle.isPending && <Skeleton className="h-40 w-full" />}

          {detalle.data && (
            <>
              <p className="whitespace-pre-wrap rounded-lg border border-border p-3 text-sm">
                {detalle.data.descripcion}
              </p>

              <ul className="scrollbar-fino max-h-64 space-y-1 overflow-y-auto">
                {detalle.data.destinatarios.map((d) => (
                  <li
                    key={d.idProfesor}
                    className="flex items-center justify-between gap-3 rounded border border-border px-3 py-2 text-sm"
                  >
                    <span className="min-w-0 flex-1 truncate">{d.profesor ?? "—"}</span>
                    {d.leido === "S" ? (
                      <span className="flex shrink-0 items-center gap-1 text-xs text-success">
                        <Check className="size-3.5" />
                        {formatearFecha(d.fechaLectura)}
                      </span>
                    ) : (
                      <span className="shrink-0 text-xs text-muted-foreground">Sin leer</span>
                    )}
                  </li>
                ))}
              </ul>
            </>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => setViendo(null)}>
              Cerrar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <AlertDialog open={aEliminar !== null} onOpenChange={(v) => !v && setAEliminar(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar la notificación?</AlertDialogTitle>
            <AlertDialogDescription>
              Se borra «{aEliminar?.titulo}» y el registro de quién la leyó. No se puede deshacer.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => aEliminar && eliminar.mutate(aEliminar)}
              disabled={eliminar.isPending}
            >
              {eliminar.isPending && <Loader2 className="size-4 animate-spin" />}
              Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </AppLayout>
  );
}

/**
 * Cuántos leyeron, sobre cuántos la recibieron.
 *
 * Se pinta como logro cumplido sólo cuando la leyeron **todos**: un "3/10" en
 * verde daría la sensación de que el aviso llegó, cuando siete personas todavía
 * no lo vieron.
 */
function LecturaBadge({ leidos, destinatarios }: { leidos: number; destinatarios: number }) {
  if (destinatarios === 0) return <span className="text-muted-foreground">—</span>;
  const todas = leidos === destinatarios;
  return (
    <Badge variant={todas ? "default" : "secondary"} className="tabular-nums">
      {leidos}/{destinatarios}
    </Badge>
  );
}
