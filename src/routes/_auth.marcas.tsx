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
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, type Marca } from "@/lib/api";
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
import { tituloPagina } from "@/lib/marca";

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

const schema = z.object({
  descripcion: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
});

type FormValues = z.infer<typeof schema>;

export const Route = createFileRoute("/_auth/marcas")({
  head: () => ({
    meta: [
      { title: tituloPagina("Marcas") },
      { name: "description", content: "Catálogo de marcas de artículos." },
    ],
  }),
  component: MarcasPage,
});

function MarcasPage() {
  const queryClient = useQueryClient();
  const { empresa } = useEmpresa();
  const [editando, setEditando] = useState<Marca | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Marca | null>(null);

  // La empresa VA en la queryKey: MARCAS dejó de ser un catálogo global, así
  // que cada empresa ve su propia lista —más las heredadas— y al cambiar de
  // empresa hay que volver a consultar.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["marcas", empresa?.id ?? null],
    queryFn: () => api.marcas.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  const eliminar = useMutation({
    mutationFn: (marca: Marca) => api.marcas.eliminar(marca.id, empresa!.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["marcas"] });
      toast.success("Marca eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      // El 409 de "hay artículos que usan esta marca" llega con su mensaje del
      // backend, que es más preciso que cualquier texto de acá.
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  // Búsqueda + orden client-side: el catálogo viene entero y es acotado.
  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    data?.items ?? [],
    (m) => [m.descripcion],
  );

  return (
    <AppLayout active="/marcas" title="Marcas">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Marcas</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Marcas de artículos de esta empresa. Las que no tienen empresa asignada las ven todas.
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null}>
            <Plus className="size-4" />
            Nueva marca
          </Button>
        </div>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por descripción…"
            className="pl-9"
          />
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

        {/* El vacío distingue "sin datos" de "sin resultados": ofrecer "cargá la
            primera" cuando lo que pasa es que la búsqueda no encontró nada
            confunde. */}
        {!isPending && !isError && resultado.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {termino
                ? `Sin resultados para "${busqueda.trim()}".`
                : "Todavía no hay marcas cargadas."}
            </p>
            {!termino && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                <Plus className="size-4" />
                Cargar la primera
              </Button>
            )}
          </div>
        )}

        {/* Móvil: tarjetas. Una tabla obliga a scrollear de costado en 360px. */}
        {resultado.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {resultado.map((marca) => (
              <li key={marca.id} className="surface-card p-4">
                <p className="truncate font-semibold text-foreground">{marca.descripcion}</p>

                <div className="mt-3 flex gap-2 border-t border-border pt-3">
                  <Button
                    variant="outline"
                    size="sm"
                    className="flex-1"
                    onClick={() => setEditando(marca)}
                  >
                    <Pencil className="size-4" />
                    Editar
                  </Button>
                  <Button
                    variant="outline"
                    size="sm"
                    className="flex-1 text-destructive hover:text-destructive"
                    onClick={() => setAEliminar(marca)}
                  >
                    <Trash2 className="size-4" />
                    Eliminar
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
                    direccion={orden?.campo === "descripcion" ? orden.direccion : null}
                    onClick={() => alternarOrden("descripcion")}
                  >
                    Descripción
                  </TableHeadOrdenable>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {resultado.map((marca) => (
                  <TableRow key={marca.id}>
                    <TableCell className="font-medium text-foreground">
                      {marca.descripcion}
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex justify-end gap-1">
                        <Button
                          variant="ghost"
                          size="icon"
                          onClick={() => setEditando(marca)}
                          title="Editar"
                        >
                          <Pencil className="size-4" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="icon"
                          onClick={() => setAEliminar(marca)}
                          title="Eliminar"
                          className="text-destructive hover:text-destructive"
                        >
                          <Trash2 className="size-4" />
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}

        {empresa !== null && (
          <MarcaDialog
            abierto={creando || editando !== null}
            onCerrar={() => {
              setCreando(false);
              setEditando(null);
            }}
            marca={editando}
            idEmpresa={empresa.id}
          />
        )}

        <AlertDialog open={aEliminar !== null} onOpenChange={(v) => !v && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar la marca?</AlertDialogTitle>
              <AlertDialogDescription>
                {aEliminar
                  ? `"${aEliminar.descripcion}" se elimina definitivamente. Si algún artículo la usa, la operación se rechaza.`
                  : ""}
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancelar</AlertDialogCancel>
              <AlertDialogAction
                onClick={() => aEliminar && eliminar.mutate(aEliminar)}
                disabled={eliminar.isPending}
              >
                Eliminar
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </main>
    </AppLayout>
  );
}

/**
 * Alta y edición. `marca` en `null` es un alta.
 *
 * Un solo diálogo para las dos cosas: el formulario tiene un único campo, así
 * que separarlos duplicaría el schema y la mutación sin ganar nada.
 */
function MarcaDialog({
  abierto,
  onCerrar,
  marca,
  idEmpresa,
}: {
  abierto: boolean;
  onCerrar: () => void;
  marca: Marca | null;
  idEmpresa: number;
}) {
  const queryClient = useQueryClient();
  const editando = marca !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { descripcion: "" },
  });

  // Se rellena al abrir: el diálogo se monta una vez y se reusa, así que sin
  // esto la segunda marca que se editara mostraría los datos de la primera.
  useEffect(() => {
    if (!abierto) return;
    form.reset({ descripcion: marca?.descripcion ?? "" });
  }, [abierto, marca, form]);

  const guardar = useMutation({
    mutationFn: (valores: FormValues) =>
      marca
        ? api.marcas.actualizar(marca.id, { idEmpresa, descripcion: valores.descripcion })
        : api.marcas.crear({ idEmpresa, descripcion: valores.descripcion }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["marcas"] });
      toast.success(editando ? "Marca actualizada" : "Marca creada");
      onCerrar();
    },
    onError: (e) => {
      // El 409 de duplicado llega con su mensaje del backend.
      toast.error(MENSAJE_ERROR(e, "No se pudo guardar"));
    },
  });

  return (
    <Dialog open={abierto} onOpenChange={(v) => !v && onCerrar()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{editando ? "Editar marca" : "Nueva marca"}</DialogTitle>
          <DialogDescription>
            El nombre del fabricante del artículo. Ej: Sakura, VIC, filter.
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form
            onSubmit={form.handleSubmit((v) => guardar.mutate(v))}
            className="space-y-4"
            noValidate
          >
            <FormField
              control={form.control}
              name="descripcion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Descripción</FormLabel>
                  <FormControl>
                    <Input autoFocus placeholder="Filter" {...field} />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onCerrar}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {editando ? "Guardar" : "Crear"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}
