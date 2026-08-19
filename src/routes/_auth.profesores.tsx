import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { api, ApiError, type Profesor } from "@/lib/api";
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
  numeroCi: z.string().trim().min(1, "Obligatorio").max(20, "Máximo 20 caracteres"),
  nombre: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
  apellido: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
  usuarioSistema: z
    .string()
    .trim()
    .min(1, "Obligatorio")
    .max(50, "Máximo 50 caracteres")
    // Mismo criterio que el backend, que lo guarda en minúsculas y sin
    // espacios: avisar acá es más claro que dejar que el servidor lo
    // transforme sin que se note.
    .refine((v) => !/\s/.test(v), "No puede tener espacios"),
  direccion: z.string().trim().max(500, "Máximo 500 caracteres"),
  telefono: z.string().trim().max(20, "Máximo 20 caracteres"),
  // El vacío se acepta porque el campo es opcional; `z.string().email()` sobre
  // "" daría error y obligaría a cargar un correo que puede no existir.
  correo: z
    .string()
    .trim()
    .max(100, "Máximo 100 caracteres")
    .refine((v) => v === "" || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v), "Correo inválido"),
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

/** Lo que se espera entre teclas antes de mandar la búsqueda al servidor. */
const ESPERA_BUSQUEDA_MS = 350;

function ProfesoresPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Profesor | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Profesor | null>(null);

  // Dos estados para la búsqueda: `busqueda` es lo que se ve en el input
  // (inmediato, sin lag al tipear) y `busquedaEnvio` lo que entra en la
  // queryKey, para no disparar una consulta por tecla.
  const [busqueda, setBusqueda] = useState("");
  const [busquedaEnvio, setBusquedaEnvio] = useState("");

  useEffect(() => {
    const id = setTimeout(() => setBusquedaEnvio(busqueda), ESPERA_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  // Los profesores son POR EMPRESA: la que se eligió al iniciar sesión. No hay
  // filtro ni combobox de empresa en la pantalla.
  const { empresa } = useEmpresa();

  // La empresa y la búsqueda entran en la queryKey: al cambiar cualquiera,
  // TanStack Query trata el listado como otra consulta en vez de mostrar en
  // caché el de la anterior.
  //
  // `enabled` evita pedir sin empresa. En el primer render todavía es null
  // —el provider hidrata desde localStorage después de montar— y sin esto la
  // petición saldría con idEmpresa vacío, devolviendo los de TODAS las empresas.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["profesores", empresa?.id ?? null, busquedaEnvio.trim()],
    queryFn: () => api.profesores.listar({ idEmpresa: empresa!.id, busqueda: busquedaEnvio }),
    enabled: empresa !== null,
  });

  const eliminar = useMutation({
    mutationFn: (prof: Profesor) => api.profesores.eliminar(prof.id, prof.idEmpresa),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["profesores"] });
      toast.success("Profesor eliminado");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  const items = data?.items ?? [];

  /**
   * El orden por click en el header ordena en memoria lo que llegó. La búsqueda
   * sí va al servidor: filtrar en el cliente sólo miraría lo ya traído.
   */
  const [orden, setOrden] = useState<{
    campo: keyof Profesor;
    direccion: "asc" | "desc";
  } | null>(null);

  function alternarOrden(campo: keyof Profesor) {
    setOrden((actual) => {
      if (!actual || actual.campo !== campo) return { campo, direccion: "asc" };
      if (actual.direccion === "asc") return { campo, direccion: "desc" };
      return null; // Tercer click: vuelve al orden del backend (por apellido).
    });
  }

  const ordenados = orden
    ? [...items].sort(
        (a, b) =>
          (orden.direccion === "asc" ? 1 : -1) *
          String(a[orden.campo] ?? "").localeCompare(String(b[orden.campo] ?? ""), "es"),
      )
    : items;

  // El término que el servidor está respondiendo, no el que se está tipeando:
  // los mensajes de "sin resultados" tienen que nombrar lo que se buscó de
  // verdad, no lo que quedó a medio escribir.
  const termino = busquedaEnvio.trim();

  // Cuántas filas se están mostrando. Se resetea al cambiar la búsqueda:
  // seguir en "80 de 90" tras filtrar a 12 perdería el sentido.
  const [visibles, setVisibles] = useState(POR_PAGINA);
  const [terminoAnterior, setTerminoAnterior] = useState(termino);
  if (termino !== terminoAnterior) {
    // Ajuste de estado en render, no useEffect: React re-renderiza antes de
    // pintar, así que la lista nunca se ve con el valor viejo.
    setTerminoAnterior(termino);
    setVisibles(POR_PAGINA);
  }

  const mostrados = ordenados.slice(0, visibles);
  const quedan = ordenados.length - mostrados.length;

  return (
    <AppLayout active="/profesores" title="Profesores">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Profesores</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {empresa
                ? `Profesores de ${empresa.nombreEmpresa}.`
                : "Profesores de la empresa con la que iniciaste sesión."}
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null}>
            <Plus className="size-4" />
            Nuevo profesor
          </Button>
        </div>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre, apellido, cédula, usuario…"
            className="pl-9"
          />
        </div>

        {/* Sin empresa no hay nada que listar. Pasa si se entró con una sesión
            vieja, de antes de que el login pidiera elegirla. */}
        {empresa === null && !isPending && (
          <p className="rounded-lg border border-border px-3 py-6 text-center text-sm text-muted-foreground">
            No hay una empresa activa. Cerrá sesión y volvé a entrar eligiendo una.
          </p>
        )}

        {isPending && empresa !== null && (
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

        {!isPending && !isError && empresa !== null && ordenados.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {termino
                ? `Sin resultados para "${termino}".`
                : "Esta empresa todavía no tiene profesores cargados."}
            </p>
            {!termino && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                <Plus className="size-4" />
                Cargar el primero
              </Button>
            )}
          </div>
        )}

        {/* Móvil: tarjetas. Una tabla de 5 columnas en 360px obliga a scrollear
            de costado para leer una fila entera. */}
        {ordenados.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {mostrados.map((prof) => (
              <li key={prof.id} className="surface-card p-4">
                <p className="font-semibold leading-snug text-foreground">
                  {prof.apellido}, {prof.nombre}
                </p>
                <p className="mt-0.5 text-xs text-muted-foreground">
                  CI {prof.numeroCi} · {prof.usuarioSistema}
                </p>

                <dl className="mt-3 space-y-1 border-t border-border pt-3 text-xs">
                  {prof.telefono && (
                    <div>
                      <dt className="inline text-muted-foreground">Teléfono: </dt>
                      <dd className="inline tabular-nums text-foreground">{prof.telefono}</dd>
                    </div>
                  )}
                  {prof.correo && (
                    <div>
                      <dt className="inline text-muted-foreground">Correo: </dt>
                      <dd className="inline break-all text-foreground">{prof.correo}</dd>
                    </div>
                  )}
                  {prof.direccion && (
                    <div>
                      <dt className="inline text-muted-foreground">Dirección: </dt>
                      <dd className="inline text-foreground">{prof.direccion}</dd>
                    </div>
                  )}
                </dl>

                <div className="mt-3 flex gap-2 border-t border-border pt-3">
                  <Button
                    variant="outline"
                    size="sm"
                    className="flex-1"
                    onClick={() => setEditando(prof)}
                  >
                    <Pencil className="size-4" />
                    Editar
                  </Button>
                  <Button
                    variant="outline"
                    size="sm"
                    className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                    onClick={() => setAEliminar(prof)}
                  >
                    <Trash2 className="size-4" />
                    Eliminar
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}

        {ordenados.length > 0 && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "apellido" ? orden.direccion : null}
                    onClick={() => alternarOrden("apellido")}
                  >
                    Profesor
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "numeroCi" ? orden.direccion : null}
                    onClick={() => alternarOrden("numeroCi")}
                  >
                    Cédula
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "usuarioSistema" ? orden.direccion : null}
                    onClick={() => alternarOrden("usuarioSistema")}
                  >
                    Usuario
                  </TableHeadOrdenable>
                  <TableHead>Contacto</TableHead>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {mostrados.map((prof) => (
                  <TableRow key={prof.id}>
                    <TableCell className="font-medium text-foreground">
                      {prof.apellido}, {prof.nombre}
                      {prof.direccion && (
                        <span className="block text-xs font-normal text-muted-foreground">
                          {prof.direccion}
                        </span>
                      )}
                    </TableCell>
                    <TableCell className="tabular-nums text-muted-foreground">
                      {prof.numeroCi}
                    </TableCell>
                    <TableCell className="text-muted-foreground">{prof.usuarioSistema}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {prof.telefono ?? "—"}
                      {prof.correo && (
                        <span className="block break-all text-xs">{prof.correo}</span>
                      )}
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex justify-end gap-1">
                        <Button
                          variant="ghost"
                          size="icon"
                          title="Editar"
                          aria-label={`Editar ${prof.apellido}, ${prof.nombre}`}
                          onClick={() => setEditando(prof)}
                        >
                          <Pencil className="size-4" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="icon"
                          title="Eliminar"
                          aria-label={`Eliminar ${prof.apellido}, ${prof.nombre}`}
                          onClick={() => setAEliminar(prof)}
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

        {quedan > 0 && (
          <div className="flex justify-center">
            <Button variant="outline" onClick={() => setVisibles((v) => v + POR_PAGINA)}>
              Mostrar {Math.min(quedan, POR_PAGINA)} más
            </Button>
          </div>
        )}

        {data && ordenados.length > 0 && (
          <p className="text-center text-xs text-muted-foreground">
            Mostrando {mostrados.length} de {ordenados.length} profesor
            {ordenados.length === 1 ? "" : "es"}
          </p>
        )}

        {/* Sin empresa no se abre: el alta necesita su id. */}
        {empresa !== null && (
          <ProfesorFormDialog
            open={creando || editando !== null}
            profesor={editando}
            idEmpresa={empresa.id}
            onClose={() => {
              setCreando(false);
              setEditando(null);
            }}
          />
        )}

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>
                ¿Eliminar a {aEliminar?.nombre} {aEliminar?.apellido}?
              </AlertDialogTitle>
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

function ProfesorFormDialog({
  open,
  profesor,
  idEmpresa,
  onClose,
}: {
  open: boolean;
  profesor: Profesor | null;
  /** Empresa activa de la sesión. No es un campo del formulario. */
  idEmpresa: number;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = profesor !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    values: {
      numeroCi: profesor?.numeroCi ?? "",
      nombre: profesor?.nombre ?? "",
      apellido: profesor?.apellido ?? "",
      usuarioSistema: profesor?.usuarioSistema ?? "",
      direccion: profesor?.direccion ?? "",
      telefono: profesor?.telefono ?? "",
      correo: profesor?.correo ?? "",
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      // Los opcionales se mandan sólo si tienen algo: mandar "" en el alta
      // guardaría una cadena vacía en vez de NULL.
      const opcionales = {
        ...(v.direccion ? { direccion: v.direccion } : {}),
        ...(v.telefono ? { telefono: v.telefono } : {}),
        ...(v.correo ? { correo: v.correo } : {}),
      };

      return esEdicion
        ? api.profesores.actualizar(profesor.id, {
            idEmpresa: profesor.idEmpresa,
            numeroCi: v.numeroCi,
            nombre: v.nombre,
            apellido: v.apellido,
            usuarioSistema: v.usuarioSistema,
            ...opcionales,
          })
        : api.profesores.crear({
            idEmpresa,
            numeroCi: v.numeroCi,
            nombre: v.nombre,
            apellido: v.apellido,
            usuarioSistema: v.usuarioSistema,
            ...opcionales,
          });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["profesores"] });
      toast.success(esEdicion ? "Profesor actualizado" : "Profesor creado");
      onClose();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear el profesor"),
      ),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="scrollbar-fino max-h-[92vh] max-w-[95vw] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar profesor" : "Nuevo profesor"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos del profesor."
              : "Agregá un profesor a la empresa con la que iniciaste sesión."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="nombre"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Nombre</FormLabel>
                    <FormControl>
                      <Input {...field} placeholder="Juan" autoComplete="off" />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="apellido"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Apellido</FormLabel>
                    <FormControl>
                      <Input {...field} placeholder="Pérez" autoComplete="off" />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="numeroCi"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Cédula</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        inputMode="numeric"
                        placeholder="1234567"
                        autoComplete="off"
                        className="tabular-nums"
                      />
                    </FormControl>
                    {/* El UNIQUE es global, no por empresa: conviene avisarlo
                        antes de que el 409 lo explique. */}
                    <FormDescription>No puede repetirse en todo el sistema.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="usuarioSistema"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Usuario</FormLabel>
                    <FormControl>
                      <Input {...field} placeholder="jperez" autoComplete="off" />
                    </FormControl>
                    <FormDescription>
                      Identificador corto. Se guarda en minúsculas y tampoco puede repetirse.
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            <FormField
              control={form.control}
              name="direccion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Dirección</FormLabel>
                  <FormControl>
                    <Input
                      {...field}
                      placeholder="Avenida Mariscal López 1234"
                      autoComplete="off"
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="telefono"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Teléfono</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        inputMode="tel"
                        placeholder="021 123 456"
                        autoComplete="off"
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="correo"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Correo</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        type="email"
                        placeholder="profesor@empresa.com"
                        autoComplete="off"
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            <DialogFooter className="gap-2">
              <Button
                type="submit"
                disabled={guardar.isPending}
                className="h-11 w-full sm:h-10 sm:w-auto"
              >
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {guardar.isPending
                  ? "Guardando…"
                  : esEdicion
                    ? "Guardar cambios"
                    : "Crear profesor"}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={onClose}
                className="h-11 w-full sm:h-10 sm:w-auto"
              >
                Cancelar
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/profesores")({
  head: () => ({
    meta: [
      { title: tituloPagina("Profesores") },
      { name: "description", content: "Profesores por empresa." },
    ],
  }),
  component: ProfesoresPage,
});
