import { zodResolver } from "@hookform/resolvers/zod";
import { useInfiniteQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Car, Loader2, PackageSearch, Pencil, Plus, Search, Trash2, Wrench } from "lucide-react";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { SelectorVehiculo } from "@/components/ctell/SelectorVehiculo";
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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { api, ApiError, type VehiculoParte } from "@/lib/api";

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/** 20 por página, como el resto de los listados paginados. */
const POR_PAGINA = 20;
const ESPERA_BUSQUEDA_MS = 350;

/** Los largos de las columnas de `VEHICULO_PARTES`, para avisar antes de mandar. */
export const MAX_CODIGO = 100;
export const MAX_DESCRIPCION = 200;

/** El vehículo al que se acota el listado o se le cargan repuestos. */
export type VehiculoElegido = { id: number; nombre: string };

/**
 * Invalida todo lo que muestra repuestos o su cantidad. Son tres claves y se
 * olvida una: el síntoma es un vehículo que sigue diciendo "0 repuestos"
 * después de cargarle uno.
 */
function invalidarPartes(queryClient: ReturnType<typeof useQueryClient>) {
  queryClient.invalidateQueries({ queryKey: ["vehiculo-partes"] });
  queryClient.invalidateQueries({ queryKey: ["vehiculos"] });
  queryClient.invalidateQueries({ queryKey: ["vehiculos-selector"] });
}

/**
 * El listado de repuestos con su ABM. Lo usan dos lugares:
 *
 * - La página `/vehiculo-partes`, con los filtros de vehículo y de código.
 * - El diálogo de repuestos de `/vehiculos`, con el vehículo fijo.
 *
 * Es un solo componente y no dos copias porque las dos pantallas muestran lo
 * mismo con el mismo endpoint: dos versiones terminarían filtrando o avisando
 * distinto sobre los mismos datos.
 *
 * **Los dos sentidos de la relación** se recorren desde la fila: con
 * `onVerVehiculos`, cada código ofrece "a qué vehículos va"; con
 * `onVerRepuestos`, cada vehículo ofrece "qué lleva". Quien monta el listado
 * decide qué hace con eso —cambiar el filtro, abrir otra pantalla—: sin el
 * callback, el botón no aparece.
 */
export function PartesListado({
  idEmpresa,
  vehiculo,
  codigo = "",
  onVerVehiculos,
  onVerRepuestos,
}: {
  idEmpresa: number;
  vehiculo: VehiculoElegido | null;
  /** Código exacto: deja sólo los vehículos que llevan ese repuesto. */
  codigo?: string;
  onVerVehiculos?: ((codigo: string) => void) | undefined;
  onVerRepuestos?: ((vehiculo: VehiculoElegido) => void) | undefined;
}) {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<VehiculoParte | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<VehiculoParte | null>(null);

  // `busqueda` es lo que se tipea (inmediato) y `busquedaEnvio` lo que viaja al
  // servidor: sin la espera, cada tecla dispararía un request.
  const [busqueda, setBusqueda] = useState("");
  const [busquedaEnvio, setBusquedaEnvio] = useState("");

  useEffect(() => {
    const id = setTimeout(() => setBusquedaEnvio(busqueda), ESPERA_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  const codigoFiltro = codigo.trim();

  // La empresa, los dos filtros y la búsqueda van en la clave: cambiar
  // cualquiera es otra consulta, y TanStack descarta las páginas traídas con el
  // filtro anterior en vez de mezclarlas.
  //
  // useInfiniteQuery: "Mostrar más" ACUMULA páginas. Los filtros van todos al
  // servidor —con el listado paginado, filtrar en memoria miraría sólo lo ya
  // traído—, y por lo mismo no hay orden por columna.
  const { data, isPending, isError, error, fetchNextPage, hasNextPage, isFetchingNextPage } =
    useInfiniteQuery({
      queryKey: [
        "vehiculo-partes",
        idEmpresa,
        vehiculo?.id ?? null,
        codigoFiltro,
        busquedaEnvio.trim(),
      ],
      queryFn: ({ pageParam }) =>
        api.vehiculoPartes.listar({
          idEmpresa,
          idVehiculo: vehiculo?.id,
          codigo: codigoFiltro,
          busqueda: busquedaEnvio,
          pagina: pageParam,
          tamanio: POR_PAGINA,
        }),
      initialPageParam: 1,
      getNextPageParam: (ultima, paginas) => {
        const traidos = paginas.reduce((suma, p) => suma + p.items.length, 0);
        return traidos < ultima.total ? paginas.length + 1 : undefined;
      },
    });

  const partes = (data?.pages ?? []).flatMap((p) => p.items);
  const total = data?.pages[0]?.total ?? 0;
  const termino = busquedaEnvio.trim();
  const filtrado = termino !== "" || codigoFiltro !== "";

  // "A qué vehículos va" no tiene sentido si el listado ya está acotado a ese
  // código; "qué lleva", si ya está acotado a un vehículo.
  const ofrecerVehiculos = onVerVehiculos !== undefined && codigoFiltro === "";
  const ofrecerRepuestos = onVerRepuestos !== undefined && vehiculo === null;

  const eliminar = useMutation({
    mutationFn: (parte: VehiculoParte) => api.vehiculoPartes.eliminar(parte.id, idEmpresa),
    onSuccess: () => {
      invalidarPartes(queryClient);
      toast.success("Repuesto eliminado");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
        <div className="relative flex-1">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder={
              vehiculo ? "Buscar por código o descripción…" : "Código, descripción o vehículo…"
            }
            className="pl-9"
          />
        </div>
        <Button onClick={() => setCreando(true)}>
          <Plus className="size-4" />
          Nuevo repuesto
        </Button>
      </div>

      {isPending && (
        <div className="space-y-2">
          {[0, 1, 2, 3, 4].map((i) => (
            <Skeleton key={i} className="h-12 w-full" />
          ))}
        </div>
      )}

      {isError && (
        <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
          {MENSAJE_ERROR(error, "No se pudo cargar la lista")}
        </p>
      )}

      {/* El vacío distingue "sin datos" de "sin resultados": ofrecer "cargá el
          primero" cuando lo que pasa es que el filtro no encontró nada confunde. */}
      {!isPending && !isError && partes.length === 0 && (
        <div className="surface-card px-3 py-12 text-center">
          <p className="text-sm text-muted-foreground">
            {codigoFiltro && !termino
              ? `Ningún vehículo${vehiculo ? " de este filtro" : ""} lleva el código "${codigoFiltro}".`
              : termino
                ? `Sin resultados para "${termino}".`
                : vehiculo
                  ? "Este vehículo todavía no tiene repuestos."
                  : "Todavía no hay repuestos cargados."}
          </p>
          {!filtrado && (
            <Button className="mt-4" onClick={() => setCreando(true)}>
              <Plus className="size-4" />
              Cargar el primero
            </Button>
          )}
        </div>
      )}

      {/* Móvil: tarjetas. Una tabla obliga a scrollear de costado en 360px. */}
      {partes.length > 0 && (
        <ul className="space-y-3 sm:hidden">
          {partes.map((parte) => (
            <li key={parte.id} className="surface-card p-4">
              <p className="break-all font-mono font-semibold text-foreground">
                {parte.codigoEquivalente}
              </p>
              {parte.descripcion && (
                <p className="mt-0.5 break-words text-sm text-muted-foreground">
                  {parte.descripcion}
                </p>
              )}
              {!vehiculo && (
                <p className="mt-1 break-words text-xs text-muted-foreground">{parte.vehiculo}</p>
              )}
              <div className="mt-2">
                <CoincidenciaArticulo parte={parte} />
              </div>

              <div className="mt-3 flex flex-wrap gap-2 border-t border-border pt-3">
                {ofrecerVehiculos && (
                  <Button
                    variant="outline"
                    size="sm"
                    className="flex-1"
                    onClick={() => onVerVehiculos(parte.codigoEquivalente)}
                  >
                    <Car className="size-4" />
                    Vehículos
                  </Button>
                )}
                {ofrecerRepuestos && (
                  <Button
                    variant="outline"
                    size="sm"
                    className="flex-1"
                    onClick={() => onVerRepuestos({ id: parte.idVehiculo, nombre: parte.vehiculo })}
                  >
                    <Wrench className="size-4" />
                    Qué lleva
                  </Button>
                )}
                <Button
                  variant="outline"
                  size="icon"
                  className="size-8"
                  onClick={() => setEditando(parte)}
                  title="Editar"
                >
                  <Pencil className="size-4" />
                </Button>
                <Button
                  variant="outline"
                  size="icon"
                  className="size-8 text-destructive hover:text-destructive"
                  onClick={() => setAEliminar(parte)}
                  title="Eliminar"
                >
                  <Trash2 className="size-4" />
                </Button>
              </div>
            </li>
          ))}
        </ul>
      )}

      {partes.length > 0 && (
        <div className="surface-card hidden overflow-x-auto sm:block">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Código</TableHead>
                <TableHead>Descripción</TableHead>
                {/* Con un vehículo elegido, la columna repetiría su nombre en
                    cada fila. */}
                {!vehiculo && <TableHead>Vehículo</TableHead>}
                <TableHead>En el catálogo</TableHead>
                <TableHead className="text-right">Acciones</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {partes.map((parte) => (
                <TableRow key={parte.id}>
                  <TableCell className="font-mono font-medium text-foreground">
                    {parte.codigoEquivalente}
                  </TableCell>
                  <TableCell className="max-w-xs whitespace-normal break-words text-muted-foreground">
                    {parte.descripcion || "—"}
                  </TableCell>
                  {!vehiculo && (
                    <TableCell className="max-w-[14rem] whitespace-normal break-words">
                      {parte.vehiculo}
                    </TableCell>
                  )}
                  <TableCell>
                    <CoincidenciaArticulo parte={parte} />
                  </TableCell>
                  <TableCell className="text-right">
                    <div className="flex justify-end gap-1">
                      {ofrecerVehiculos && (
                        <Button
                          variant="ghost"
                          size="icon"
                          onClick={() => onVerVehiculos(parte.codigoEquivalente)}
                          title="Vehículos que llevan este código"
                        >
                          <Car className="size-4" />
                        </Button>
                      )}
                      {ofrecerRepuestos && (
                        <Button
                          variant="ghost"
                          size="icon"
                          onClick={() =>
                            onVerRepuestos({ id: parte.idVehiculo, nombre: parte.vehiculo })
                          }
                          title="Repuestos de este vehículo"
                        >
                          <Wrench className="size-4" />
                        </Button>
                      )}
                      <Button
                        variant="ghost"
                        size="icon"
                        onClick={() => setEditando(parte)}
                        title="Editar"
                      >
                        <Pencil className="size-4" />
                      </Button>
                      <Button
                        variant="ghost"
                        size="icon"
                        onClick={() => setAEliminar(parte)}
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

      {partes.length > 0 && (
        <div className="flex flex-col items-center gap-2">
          <p className="text-xs text-muted-foreground">
            Mostrando {partes.length} de {total} repuesto{total === 1 ? "" : "s"}
          </p>
          {hasNextPage && (
            <Button
              variant="outline"
              size="sm"
              onClick={() => fetchNextPage()}
              disabled={isFetchingNextPage}
            >
              {isFetchingNextPage ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  Cargando…
                </>
              ) : (
                "Mostrar más"
              )}
            </Button>
          )}
        </div>
      )}

      <ParteDialog
        abierto={creando || editando !== null}
        onCerrar={() => {
          setCreando(false);
          setEditando(null);
        }}
        parte={editando}
        vehiculo={vehiculo}
        idEmpresa={idEmpresa}
      />

      <AlertDialog open={aEliminar !== null} onOpenChange={(v) => !v && setAEliminar(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar el repuesto?</AlertDialogTitle>
            <AlertDialogDescription>
              {aEliminar
                ? `"${aEliminar.codigoEquivalente}" se quita de ${aEliminar.vehiculo}. No toca el artículo del catálogo.`
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
    </div>
  );
}

/**
 * Con cuántos artículos del catálogo coincide el código.
 *
 * Es lo que vuelve útil el catálogo en el mostrador: "de lo que lleva este
 * auto, qué tenemos". El cero no es un error —es un repuesto que la empresa no
 * vende, o que todavía no tiene cargada la equivalencia—, pero se marca, porque
 * es justo lo que hay que mirar.
 */
function CoincidenciaArticulo({ parte }: { parte: VehiculoParte }) {
  if (parte.articulos === 0) {
    return (
      <Badge variant="outline" className="text-muted-foreground">
        Sin artículo
      </Badge>
    );
  }
  if (parte.articulos === 1 && parte.articulo) {
    return (
      <span className="inline-flex min-w-0 items-center gap-1.5 text-sm">
        <PackageSearch className="size-4 shrink-0 text-primary" />
        <span className="break-words">{parte.articulo}</span>
      </span>
    );
  }
  // Dos o más: el mismo código puede estar en dos artículos a propósito (ver
  // db/codigos-equivalentes.sql), y elegir cuál es del vendedor.
  return <Badge variant="secondary">{parte.articulos} artículos</Badge>;
}

const schemaParte = z.object({
  codigoEquivalente: z
    .string()
    .trim()
    .min(1, "Obligatorio")
    .max(MAX_CODIGO, `Máximo ${MAX_CODIGO} caracteres`),
  descripcion: z.string().trim().max(MAX_DESCRIPCION, `Máximo ${MAX_DESCRIPCION} caracteres`),
});

type ValoresParte = z.infer<typeof schemaParte>;

/**
 * Alta y edición de un repuesto. `parte` en `null` es un alta.
 *
 * En el alta, el vehículo es el del listado si hay uno elegido; si no, se elige
 * acá. En la edición **no se cambia**: mover un repuesto de vehículo es borrarlo
 * y crearlo, como el artículo de un código equivalente.
 */
function ParteDialog({
  abierto,
  onCerrar,
  parte,
  vehiculo,
  idEmpresa,
}: {
  abierto: boolean;
  onCerrar: () => void;
  parte: VehiculoParte | null;
  vehiculo: VehiculoElegido | null;
  idEmpresa: number;
}) {
  const queryClient = useQueryClient();
  const editando = parte !== null;
  const [destino, setDestino] = useState<VehiculoElegido | null>(vehiculo);

  const form = useForm<ValoresParte>({
    resolver: zodResolver(schemaParte),
    defaultValues: { codigoEquivalente: "", descripcion: "" },
  });

  // Se rellena al abrir: el diálogo se monta una vez y se reusa, así que sin
  // esto el segundo repuesto que se editara mostraría los datos del primero.
  useEffect(() => {
    if (!abierto) return;
    form.reset({
      codigoEquivalente: parte?.codigoEquivalente ?? "",
      descripcion: parte?.descripcion ?? "",
    });
    setDestino(vehiculo);
  }, [abierto, parte, vehiculo, form]);

  const guardar = useMutation({
    // Las dos claves van siempre, aunque la descripción sea "": una clave
    // omitida deja el bind de ORDS sin definir.
    mutationFn: (valores: ValoresParte) =>
      parte
        ? api.vehiculoPartes.actualizar(parte.id, { idEmpresa, ...valores })
        : api.vehiculoPartes.crear({ idEmpresa, idVehiculo: destino!.id, ...valores }),
    onSuccess: () => {
      invalidarPartes(queryClient);
      toast.success(editando ? "Repuesto actualizado" : "Repuesto agregado");
      onCerrar();
    },
    // El 409 de "ese código ya está en este vehículo" llega con su mensaje.
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo guardar")),
  });

  const sinVehiculo = !editando && destino === null;

  return (
    <Dialog open={abierto} onOpenChange={(v) => !v && onCerrar()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{editando ? "Editar repuesto" : "Nuevo repuesto"}</DialogTitle>
          <DialogDescription>
            {editando
              ? `De ${parte.vehiculo}.`
              : "El código se guarda en mayúsculas: es el que se cruza contra los artículos."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form
            onSubmit={form.handleSubmit((v) => guardar.mutate(v))}
            className="space-y-4"
            noValidate
          >
            {/* El vehículo no es un campo del schema: en la edición no existe, y
                en el alta a veces ya viene dado por el listado. */}
            {!editando && !vehiculo && (
              <div className="space-y-2">
                <p className="text-sm font-medium">Vehículo</p>
                <SelectorVehiculo
                  idEmpresa={idEmpresa}
                  value={destino ? String(destino.id) : ""}
                  etiquetaSeleccionada={destino?.nombre}
                  onChange={(valor, etiqueta) =>
                    setDestino(valor ? { id: Number(valor), nombre: etiqueta } : null)
                  }
                />
              </div>
            )}
            {!editando && vehiculo && (
              <p className="text-[0.8rem] text-muted-foreground">
                Se agrega a <span className="font-medium text-foreground">{vehiculo.nombre}</span>.
              </p>
            )}

            <FormField
              control={form.control}
              name="codigoEquivalente"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Código</FormLabel>
                  <FormControl>
                    <Input autoFocus placeholder="W-712" className="font-mono" {...field} />
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
                    <Input placeholder="Filtro de aceite" {...field} />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onCerrar}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending || sinVehiculo}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {editando ? "Guardar" : "Agregar"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}
