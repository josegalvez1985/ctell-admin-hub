import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, MapPin, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, type Ubicacion } from "@/lib/api";
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

export const Route = createFileRoute("/_auth/ubicaciones")({
  head: () => ({
    meta: [
      { title: tituloPagina("Ubicaciones") },
      {
        name: "description",
        content: "Ubicaciones físicas del depósito: zona, estante y nivel.",
      },
    ],
  }),
  component: UbicacionesPage,
});

const schema = z.object({
  // ZONA se guarda en mayúsculas. El regex evita que entren separadores que
  // después harían ver dos ubicaciones distintas donde hay una sola.
  zona: z
    .string()
    .trim()
    .min(1, "Obligatorio")
    .max(10, "Máximo 10 caracteres")
    .regex(/^[A-Za-z0-9-]+$/, "Sólo letras, números y guiones"),
  // coerce: los <input> devuelven string y la columna es NUMBER.
  estante: z.coerce
    .number({ message: "Tiene que ser un número" })
    .int("Sin decimales")
    .positive("Mayor a cero"),
  nivel: z.coerce
    .number({ message: "Tiene que ser un número" })
    .int("Sin decimales")
    .positive("Mayor a cero"),
  descripcion: z.string().trim().max(200, "Máximo 200 caracteres"),
});

type FormValues = z.infer<typeof schema>;

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/** Cuántas filas se muestran de entrada, y cuántas suma cada "Mostrar más". */
const POR_PAGINA = 20;

/** Etiqueta compacta de la ubicación: "A1 · Estante 3 · Nivel 2". */
function etiqueta(u: Ubicacion): string {
  return `${u.zona} · Estante ${u.estante} · Nivel ${u.nivel}`;
}

function UbicacionesPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Ubicacion | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Ubicacion | null>(null);
  const [filtroZona, setFiltroZona] = useState<string>(SIN_FILTRO);
  const [visibles, setVisibles] = useState(POR_PAGINA);

  // Las ubicaciones cuelgan de la empresa Y de la sucursal: las dos salen de los
  // providers globales. No hay combobox de ninguna en la pantalla — se trabaja
  // sobre el contexto activo, y para ver otra sucursal se cambia en el home.
  const { empresa } = useEmpresa();
  const { sucursal, cargando: cargandoSucursal } = useSucursal();

  // Las dos entran en la queryKey: al cambiar cualquiera, TanStack Query trata
  // el listado como otra consulta en vez de mostrar en caché el de la anterior.
  const { data, isPending, isError } = useQuery({
    queryKey: ["ubicaciones", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => api.ubicaciones.listar({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
    // Los providers hidratan después de montar: sin esto la primera petición
    // saldría sin filtros y traería las ubicaciones de todas las sucursales.
    enabled: empresa !== null && sucursal !== null,
  });

  const items = data?.items ?? [];

  // Las zonas salen del PROPIO listado y no de una tabla aparte: son los
  // valores que existen en esta sucursal, y ofrecer otros daría opciones que
  // siempre devuelven cero filas.
  const zonasOpciones = Array.from(new Set(items.map((u) => u.zona)))
    .sort((a, b) => a.localeCompare(b, "es"))
    .map((z) => ({ valor: z, etiqueta: z }));

  const filtrados = items.filter((u) => filtroZona === SIN_FILTRO || u.zona === filtroZona);

  const { busqueda, setBusqueda, orden, alternarOrden, resultado } = useTablaListado(
    filtrados,
    (u) => [u.zona, u.estante, u.nivel, u.descripcion],
  );

  /**
   * El orden de `useTablaListado` compara con `localeCompare` sobre strings, y
   * ESTANTE y NIVEL son numéricos: como texto, el estante 10 iría antes que el
   * 2. Cuando se ordena por una de esas dos columnas se reordena numéricamente
   * acá; para `zona` y `descripcion` el orden del hook ya es correcto.
   */
  const mostrados = useMemo(() => {
    const lista =
      orden && (orden.campo === "estante" || orden.campo === "nivel")
        ? [...resultado].sort((a, b) => {
            const factor = orden.direccion === "asc" ? 1 : -1;
            return factor * (Number(a[orden.campo]) - Number(b[orden.campo]));
          })
        : resultado;
    return lista.slice(0, visibles);
  }, [resultado, orden, visibles]);

  const eliminar = useMutation({
    mutationFn: (u: Ubicacion) => api.ubicaciones.eliminar(u.id, u.idEmpresa),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["ubicaciones"] });
      toast.success("Ubicación eliminada");
      setAEliminar(null);
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo eliminar la ubicación")),
  });

  // Sin sucursal no hay dónde crear ni qué listar: la pantalla lo dice en vez de
  // mostrar una tabla vacía que parecería un depósito sin ubicaciones.
  const sinSucursal = !cargandoSucursal && sucursal === null;

  return (
    <AppLayout active="/ubicaciones" title="Ubicaciones">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Ubicaciones</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Zona, estante y nivel del depósito
              {sucursal ? ` de ${sucursal.nombreSucursal}` : ""}.
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={sucursal === null}>
            <Plus className="size-4" />
            Nueva ubicación
          </Button>
        </div>

        {sinSucursal ? (
          <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
            La empresa no tiene sucursales activas. Cargá una sucursal antes de definir ubicaciones.
          </p>
        ) : (
          <>
            <div className="relative max-w-sm">
              <Search className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={busqueda}
                onChange={(e) => setBusqueda(e.target.value)}
                placeholder="Buscar zona o descripción…"
                className="pl-9"
                aria-label="Buscar ubicaciones"
              />
            </div>

            {isPending || cargandoSucursal ? (
              <div className="space-y-2">
                {[0, 1, 2, 3].map((i) => (
                  <Skeleton key={i} className="h-14 w-full" />
                ))}
              </div>
            ) : isError ? (
              <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
                No se pudieron cargar las ubicaciones.
              </p>
            ) : resultado.length === 0 ? (
              <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
                {items.length === 0
                  ? "Todavía no hay ubicaciones cargadas en esta sucursal."
                  : "Ninguna ubicación coincide con la búsqueda."}
              </p>
            ) : (
              <>
                {/* Móvil: tarjetas. Una tabla de 4 columnas en 360px obliga a
                    scrollear de costado para leer una fila entera. */}
                <ul className="space-y-3 sm:hidden">
                  {mostrados.map((u) => (
                    <li key={u.id} className="surface-card p-4">
                      <div className="flex items-start gap-3">
                        <MapPin className="mt-0.5 size-5 shrink-0 text-primary" />
                        <div className="min-w-0 flex-1">
                          <p className="truncate font-semibold tabular-nums text-foreground">
                            {etiqueta(u)}
                          </p>
                          {u.descripcion && (
                            <p className="mt-0.5 truncate text-xs text-muted-foreground">
                              {u.descripcion}
                            </p>
                          )}
                        </div>
                      </div>

                      <div className="mt-3 flex gap-2 border-t border-border pt-3">
                        <Button
                          variant="outline"
                          size="sm"
                          className="flex-1"
                          onClick={() => setEditando(u)}
                        >
                          <Pencil className="size-4" />
                          Editar
                        </Button>
                        <Button
                          variant="outline"
                          size="sm"
                          className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                          onClick={() => setAEliminar(u)}
                        >
                          <Trash2 className="size-4" />
                          Eliminar
                        </Button>
                      </div>
                    </li>
                  ))}
                </ul>

                <div className="surface-card hidden overflow-x-auto sm:block">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHeadFiltrable
                          direccion={orden?.campo === "zona" ? orden.direccion : null}
                          onOrdenar={() => alternarOrden("zona")}
                          opciones={zonasOpciones}
                          valor={filtroZona}
                          onFiltrar={setFiltroZona}
                          buscarPlaceholder="Buscar zona…"
                        >
                          Zona
                        </TableHeadFiltrable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "estante" ? orden.direccion : null}
                          onClick={() => alternarOrden("estante")}
                        >
                          Estante
                        </TableHeadOrdenable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "nivel" ? orden.direccion : null}
                          onClick={() => alternarOrden("nivel")}
                        >
                          Nivel
                        </TableHeadOrdenable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "descripcion" ? orden.direccion : null}
                          onClick={() => alternarOrden("descripcion")}
                        >
                          Descripción
                        </TableHeadOrdenable>
                        <TableHead className="text-right">Acciones</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {mostrados.map((u) => (
                        <TableRow key={u.id}>
                          <TableCell className="font-medium text-foreground">{u.zona}</TableCell>
                          <TableCell className="tabular-nums text-muted-foreground">
                            {u.estante}
                          </TableCell>
                          <TableCell className="tabular-nums text-muted-foreground">
                            {u.nivel}
                          </TableCell>
                          <TableCell className="text-muted-foreground">
                            {u.descripcion ?? "—"}
                          </TableCell>
                          <TableCell className="text-right">
                            <div className="flex justify-end gap-1">
                              <Button
                                variant="ghost"
                                size="icon"
                                title="Editar"
                                aria-label={`Editar ${etiqueta(u)}`}
                                onClick={() => setEditando(u)}
                              >
                                <Pencil className="size-4" />
                              </Button>
                              <Button
                                variant="ghost"
                                size="icon"
                                title="Eliminar"
                                aria-label={`Eliminar ${etiqueta(u)}`}
                                onClick={() => setAEliminar(u)}
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

                {resultado.length > mostrados.length && (
                  <div className="flex justify-center">
                    <Button variant="outline" onClick={() => setVisibles((v) => v + POR_PAGINA)}>
                      Mostrar más ({resultado.length - mostrados.length} restantes)
                    </Button>
                  </div>
                )}
              </>
            )}
          </>
        )}

        {/* Sin empresa Y sucursal no se abre: el alta necesita los dos ids. */}
        {empresa !== null && sucursal !== null && (
          <UbicacionFormDialog
            open={creando || editando !== null}
            ubicacion={editando}
            idEmpresa={empresa.id}
            idSucursal={sucursal.id}
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
                ¿Eliminar {aEliminar ? etiqueta(aEliminar) : "la ubicación"}?
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

/** Alta y edición. Los ids de empresa y sucursal vienen del contexto activo. */
function UbicacionFormDialog({
  open,
  ubicacion,
  idEmpresa,
  idSucursal,
  onClose,
}: {
  open: boolean;
  /** `null` en el alta. */
  ubicacion: Ubicacion | null;
  idEmpresa: number;
  idSucursal: number;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = ubicacion !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      zona: ubicacion?.zona ?? "",
      // El alta arranca en 1 y no en 0: el schema exige positivo, y un 0 de
      // arranque mostraría un error de validación que el usuario no causó.
      estante: ubicacion?.estante ?? 1,
      nivel: ubicacion?.nivel ?? 1,
      descripcion: ubicacion?.descripcion ?? "",
    },
    // Vuelve a sembrar el formulario cuando cambia la fila editada: sin esto,
    // abrir otra ubicación mostraría los valores de la anterior.
    values: {
      zona: ubicacion?.zona ?? "",
      estante: ubicacion?.estante ?? 1,
      nivel: ubicacion?.nivel ?? 1,
      descripcion: ubicacion?.descripcion ?? "",
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const datos = {
        zona: v.zona.toUpperCase(),
        estante: v.estante,
        nivel: v.nivel,
        // Vacío se manda como undefined: el backend usa NVL, así que "" pisaría
        // la descripción con una cadena vacía en vez de dejarla como estaba.
        ...(v.descripcion ? { descripcion: v.descripcion } : {}),
      };
      return esEdicion
        ? // idEmpresa es OBLIGATORIO en el update aunque no sea un campo del
          // formulario: el backend lo usa en el WHERE para acotar a cuál fila
          // se aplica el cambio. Sin él responde 400.
          api.ubicaciones.actualizar(ubicacion.id, {
            idEmpresa: ubicacion.idEmpresa,
            ...datos,
          })
        : api.ubicaciones.crear({ idEmpresa, idSucursal, ...datos });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["ubicaciones"] });
      toast.success(esEdicion ? "Ubicación actualizada" : "Ubicación creada");
      onClose();
    },
    onError: (e) =>
      form.setError("root", { message: MENSAJE_ERROR(e, "No se pudo guardar la ubicación") }),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar ubicación" : "Nueva ubicación"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos de la ubicación."
              : "Zona, estante y nivel donde se guarda la mercadería."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="zona"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Zona</FormLabel>
                  <FormControl>
                    <Input
                      {...field}
                      // Se fuerza mayúscula al tipear porque así se guarda: ver
                      // el resultado distinto de lo escrito confunde más que
                      // ayudar.
                      onChange={(e) => field.onChange(e.target.value.toUpperCase())}
                      placeholder="A1"
                      autoComplete="off"
                      autoFocus
                    />
                  </FormControl>
                  <FormDescription>Se guarda en mayúsculas.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <div className="grid grid-cols-2 gap-3">
              <FormField
                control={form.control}
                name="estante"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Estante</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        type="number"
                        min={1}
                        step={1}
                        inputMode="numeric"
                        className="tabular-nums"
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="nivel"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Nivel</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        type="number"
                        min={1}
                        step={1}
                        inputMode="numeric"
                        className="tabular-nums"
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            <FormField
              control={form.control}
              name="descripcion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Descripción</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Opcional" autoComplete="off" />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            {form.formState.errors.root && (
              <p
                role="alert"
                className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive"
              >
                {form.formState.errors.root.message}
              </p>
            )}

            <DialogFooter className="gap-2 sm:gap-2">
              <Button type="button" variant="outline" onClick={onClose}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                Guardar
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}
