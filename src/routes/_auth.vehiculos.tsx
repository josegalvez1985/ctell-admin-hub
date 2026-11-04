import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useInfiniteQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2, Wrench, X } from "lucide-react";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { MAX_CODIGO, MAX_DESCRIPCION, PartesListado } from "@/components/ctell/VehiculoPartes";
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
import { api, ApiError, type ParteNueva, type Vehiculo } from "@/lib/api";
import { tituloPagina } from "@/lib/marca";

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

const POR_PAGINA = 20;
const ESPERA_BUSQUEDA_MS = 350;

/** El techo del backend por alta (`C_MAX_LINEAS` en db/vehiculo-partes.sql). */
const MAX_LINEAS_ALTA = 200;

const schema = z.object({
  nombre: z.string().trim().min(1, "Obligatorio").max(200, "Máximo 200 caracteres"),
});

type FormValues = z.infer<typeof schema>;

/**
 * Una línea del alta. Va en un `useState` y no en react-hook-form, como en
 * facturas: el schema de zod cubre sólo la cabecera.
 */
type Linea = {
  /** Sólo para el `key` de React: no viaja. No es el índice, que se corre al borrar. */
  clave: number;
  codigoEquivalente: string;
  descripcion: string;
};

export const Route = createFileRoute("/_auth/vehiculos")({
  head: () => ({
    meta: [
      { title: tituloPagina("Vehículos") },
      { name: "description", content: "Vehículos y los repuestos que lleva cada uno." },
    ],
  }),
  component: VehiculosPage,
});

function VehiculosPage() {
  const queryClient = useQueryClient();
  const { empresa } = useEmpresa();
  const [editando, setEditando] = useState<Vehiculo | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Vehiculo | null>(null);
  // Vehículo cuyos repuestos se están viendo. Diálogo y no sólo la página
  // /vehiculo-partes: desde acá siempre se mira "los repuestos de ESTE".
  const [verPartes, setVerPartes] = useState<Vehiculo | null>(null);

  const [busqueda, setBusqueda] = useState("");
  const [busquedaEnvio, setBusquedaEnvio] = useState("");

  /**
   * El otro sentido de la relación: sólo los vehículos que llevan ESTE código.
   *
   * Es un filtro aparte de la búsqueda, y exacto: la búsqueda es texto parcial
   * —"W-71" también trae los del W-712—, y "a qué vehículos va este repuesto"
   * necesita la respuesta justa. Se escribe a mano o llega desde la llave de un
   * repuesto en el diálogo.
   */
  const [codigo, setCodigo] = useState("");
  const [codigoEnvio, setCodigoEnvio] = useState("");

  useEffect(() => {
    const id = setTimeout(() => setBusquedaEnvio(busqueda), ESPERA_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  useEffect(() => {
    const id = setTimeout(() => setCodigoEnvio(codigo), ESPERA_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [codigo]);

  // La empresa y los filtros van en la queryKey: cambiar cualquiera es otra
  // consulta. `enabled` evita pedir sin empresa (el provider hidrata después
  // de montar). Los filtros van al servidor porque el listado está paginado, y
  // por lo mismo no hay orden por columna: ordenaría sólo lo ya traído.
  const { data, isPending, isError, error, fetchNextPage, hasNextPage, isFetchingNextPage } =
    useInfiniteQuery({
      queryKey: ["vehiculos", empresa?.id ?? null, codigoEnvio.trim(), busquedaEnvio.trim()],
      queryFn: ({ pageParam }) =>
        api.vehiculos.listar({
          idEmpresa: empresa!.id,
          codigo: codigoEnvio,
          busqueda: busquedaEnvio,
          pagina: pageParam,
          tamanio: POR_PAGINA,
        }),
      enabled: empresa !== null,
      initialPageParam: 1,
      getNextPageParam: (ultima, paginas) => {
        const traidos = paginas.reduce((suma, p) => suma + p.items.length, 0);
        return traidos < ultima.total ? paginas.length + 1 : undefined;
      },
    });

  const vehiculos = (data?.pages ?? []).flatMap((p) => p.items);
  const total = data?.pages[0]?.total ?? 0;
  const termino = busquedaEnvio.trim();
  const codigoFiltro = codigoEnvio.trim();

  const eliminar = useMutation({
    mutationFn: (vehiculo: Vehiculo) => api.vehiculos.eliminar(vehiculo.id, empresa!.id),
    onSuccess: (r) => {
      queryClient.invalidateQueries({ queryKey: ["vehiculos"] });
      queryClient.invalidateQueries({ queryKey: ["vehiculos-selector"] });
      queryClient.invalidateQueries({ queryKey: ["vehiculo-partes"] });
      toast.success(
        r.partesEliminadas > 0
          ? `Vehículo eliminado con sus ${r.partesEliminadas} repuestos`
          : "Vehículo eliminado",
      );
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  return (
    <AppLayout active="/vehiculos" title="Vehículos">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Vehículos</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Cada vehículo con los repuestos que lleva.
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null}>
            <Plus className="size-4" />
            Nuevo vehículo
          </Button>
        </div>

        <div className="grid gap-2 sm:grid-cols-[2fr_1fr]">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
              placeholder="Nombre del vehículo o parte de un código…"
              className="pl-9"
            />
          </div>
          <div className="relative">
            <Wrench className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={codigo}
              onChange={(e) => setCodigo(e.target.value)}
              placeholder="Lleva el repuesto (código exacto)"
              className="pl-9 pr-9 font-mono"
              aria-label="Filtrar por el código exacto de un repuesto"
            />
            {codigo !== "" && (
              <button
                type="button"
                onClick={() => setCodigo("")}
                className="absolute right-2 top-1/2 -translate-y-1/2 rounded p-1 text-muted-foreground hover:text-foreground"
                title="Quitar el filtro"
                aria-label="Quitar el filtro"
              >
                <X className="size-4" />
              </button>
            )}
          </div>
        </div>

        {empresa === null && !isPending && (
          <p className="text-sm text-muted-foreground">
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

        {/* El vacío distingue "sin datos" de "sin resultados", y dice qué filtro
            no encontró nada. */}
        {!isPending && !isError && vehiculos.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {codigoFiltro && !termino
                ? `Ningún vehículo lleva el repuesto "${codigoFiltro.toUpperCase()}".`
                : termino || codigoFiltro
                  ? "Ningún vehículo coincide con los filtros."
                  : "Todavía no hay vehículos cargados."}
            </p>
            {!termino && !codigoFiltro && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                <Plus className="size-4" />
                Cargar el primero
              </Button>
            )}
          </div>
        )}

        {codigoFiltro && vehiculos.length > 0 && (
          <p className="text-sm text-muted-foreground">
            {total} vehículo{total === 1 ? "" : "s"} lleva{total === 1 ? "" : "n"} el repuesto{" "}
            <span className="font-mono font-medium text-foreground">
              {codigoFiltro.toUpperCase()}
            </span>
            .
          </p>
        )}

        {/* Móvil: tarjetas. */}
        {vehiculos.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {vehiculos.map((vehiculo) => (
              <li key={vehiculo.id} className="surface-card p-4">
                <div className="flex items-start justify-between gap-3">
                  <p className="min-w-0 flex-1 break-words font-semibold text-foreground">
                    {vehiculo.nombre}
                  </p>
                  <CantidadPartes cantidad={vehiculo.cantidadPartes} />
                </div>

                <div className="mt-3 flex gap-2 border-t border-border pt-3">
                  <Button
                    variant="outline"
                    size="sm"
                    className="flex-1"
                    onClick={() => setVerPartes(vehiculo)}
                  >
                    <Wrench className="size-4" />
                    Repuestos
                  </Button>
                  <Button
                    variant="outline"
                    size="icon"
                    className="size-8"
                    onClick={() => setEditando(vehiculo)}
                    title="Editar"
                  >
                    <Pencil className="size-4" />
                  </Button>
                  <Button
                    variant="outline"
                    size="icon"
                    className="size-8 text-destructive hover:text-destructive"
                    onClick={() => setAEliminar(vehiculo)}
                    title="Eliminar"
                  >
                    <Trash2 className="size-4" />
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}

        {vehiculos.length > 0 && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Vehículo</TableHead>
                  <TableHead>Repuestos</TableHead>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {vehiculos.map((vehiculo) => (
                  <TableRow key={vehiculo.id}>
                    <TableCell className="whitespace-normal break-words font-medium text-foreground">
                      {vehiculo.nombre}
                    </TableCell>
                    <TableCell>
                      <CantidadPartes cantidad={vehiculo.cantidadPartes} />
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex justify-end gap-1">
                        <Button
                          variant="ghost"
                          size="icon"
                          onClick={() => setVerPartes(vehiculo)}
                          title="Repuestos"
                        >
                          <Wrench className="size-4" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="icon"
                          onClick={() => setEditando(vehiculo)}
                          title="Editar"
                        >
                          <Pencil className="size-4" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="icon"
                          onClick={() => setAEliminar(vehiculo)}
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

        {vehiculos.length > 0 && (
          <div className="flex flex-col items-center gap-2">
            <p className="text-xs text-muted-foreground">
              Mostrando {vehiculos.length} de {total} vehículo{total === 1 ? "" : "s"}
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

        {empresa !== null && (
          <VehiculoDialog
            abierto={creando || editando !== null}
            onCerrar={() => {
              setCreando(false);
              setEditando(null);
            }}
            vehiculo={editando}
            idEmpresa={empresa.id}
            onCreado={(v) => setVerPartes(v)}
          />
        )}

        {empresa !== null && (
          <Dialog open={verPartes !== null} onOpenChange={(v) => !v && setVerPartes(null)}>
            <DialogContent className="flex max-h-[90dvh] max-w-[95vw] flex-col sm:max-w-4xl">
              <DialogHeader>
                <DialogTitle className="break-words">{verPartes?.nombre}</DialogTitle>
                <DialogDescription>
                  Los repuestos de este vehículo, y con qué artículo del catálogo coincide cada
                  código. El auto de cada fila muestra qué otros vehículos llevan ese repuesto.
                </DialogDescription>
              </DialogHeader>
              <div className="-mx-1 min-h-0 flex-1 overflow-y-auto px-1">
                {verPartes && (
                  <PartesListado
                    idEmpresa={empresa.id}
                    vehiculo={{ id: verPartes.id, nombre: verPartes.nombre }}
                    // Vehículo → repuesto → vehículos: se cierra el diálogo y
                    // el código queda como filtro del listado de atrás, que es
                    // justamente la lista de vehículos.
                    onVerVehiculos={(c) => {
                      setVerPartes(null);
                      setBusqueda("");
                      setCodigo(c);
                    }}
                  />
                )}
              </div>
            </DialogContent>
          </Dialog>
        )}

        <AlertDialog open={aEliminar !== null} onOpenChange={(v) => !v && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar el vehículo?</AlertDialogTitle>
              <AlertDialogDescription>
                {aEliminar
                  ? aEliminar.cantidadPartes > 0
                    ? `"${aEliminar.nombre}" se elimina definitivamente junto con sus ${aEliminar.cantidadPartes} repuestos. Los artículos del catálogo no se tocan.`
                    : `"${aEliminar.nombre}" se elimina definitivamente.`
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
 * Un vehículo sin repuestos no es un error —se crea el nombre y las líneas se
 * cargan después—, pero se marca: uno que quedó así es una carga olvidada.
 */
function CantidadPartes({ cantidad }: { cantidad: number }) {
  return cantidad === 0 ? (
    <Badge variant="outline" className="shrink-0 text-warning">
      Sin repuestos
    </Badge>
  ) : (
    <Badge variant="secondary" className="shrink-0">
      {cantidad} repuesto{cantidad === 1 ? "" : "s"}
    </Badge>
  );
}

/** El primer problema de las líneas, o `null`. El backend lo rechazaría igual. */
function errorDeLineas(partes: ParteNueva[]): string | null {
  if (partes.length > MAX_LINEAS_ALTA) {
    return `Se pueden cargar hasta ${MAX_LINEAS_ALTA} repuestos en el alta; el resto, después.`;
  }
  const vistos = new Map<string, number>();
  for (const [i, p] of partes.entries()) {
    if (p.codigoEquivalente.length > MAX_CODIGO) {
      return `El código de la línea ${i + 1} pasa de ${MAX_CODIGO} caracteres.`;
    }
    if (p.descripcion.length > MAX_DESCRIPCION) {
      return `La descripción de la línea ${i + 1} pasa de ${MAX_DESCRIPCION} caracteres.`;
    }
    // Comparado como lo guarda el backend: en mayúsculas. Sin esto, `w-712` y
    // `W-712` pasarían acá y el alta entera volvería con un 400.
    const normalizado = p.codigoEquivalente.toUpperCase();
    const anterior = vistos.get(normalizado);
    if (anterior !== undefined) {
      return `El código ${normalizado} está en las líneas ${anterior + 1} y ${i + 1}.`;
    }
    vistos.set(normalizado, i);
  }
  return null;
}

/**
 * Alta y edición. `vehiculo` en `null` es un alta.
 *
 * **El alta lleva los repuestos**, en la misma transacción que la cabecera; la
 * edición cambia **sólo el nombre**. Con cientos de líneas, reemplazar el
 * detalle entero en cada guardado obligaría a traérselo completo; los repuestos
 * se corrigen de a uno desde el botón de repuestos.
 */
function VehiculoDialog({
  abierto,
  onCerrar,
  vehiculo,
  idEmpresa,
  onCreado,
}: {
  abierto: boolean;
  onCerrar: () => void;
  vehiculo: Vehiculo | null;
  idEmpresa: number;
  /** Con el vehículo recién creado, para abrir sus repuestos y revisar la carga. */
  onCreado: (vehiculo: Vehiculo) => void;
}) {
  const queryClient = useQueryClient();
  const editando = vehiculo !== null;
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [proximaClave, setProximaClave] = useState(1);

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { nombre: "" },
  });

  // Se rellena al abrir: el diálogo se monta una vez y se reusa.
  useEffect(() => {
    if (!abierto) return;
    form.reset({ nombre: vehiculo?.nombre ?? "" });
    setLineas([]);
  }, [abierto, vehiculo, form]);

  const agregarLinea = () => {
    setLineas((ls) => [...ls, { clave: proximaClave, codigoEquivalente: "", descripcion: "" }]);
    setProximaClave((c) => c + 1);
  };

  const cambiarLinea = (clave: number, cambio: Partial<Omit<Linea, "clave">>) =>
    setLineas((ls) => ls.map((l) => (l.clave === clave ? { ...l, ...cambio } : l)));

  // Las líneas sin código se descartan en vez de mandarse: la última suele
  // quedar vacía porque se agregó y no se completó, y mandarla daría un 400 por
  // algo que el usuario no considera parte del alta.
  const partes: ParteNueva[] = lineas
    .map((l) => ({
      codigoEquivalente: l.codigoEquivalente.trim(),
      descripcion: l.descripcion.trim(),
    }))
    .filter((p) => p.codigoEquivalente !== "");
  const errorLineas = errorDeLineas(partes);

  const guardar = useMutation({
    mutationFn: (valores: FormValues) =>
      vehiculo
        ? api.vehiculos
            .actualizar(vehiculo.id, { idEmpresa, nombre: valores.nombre })
            .then(() => null)
        : // `partes` va siempre, aunque sea []: una clave omitida deja el bind
          // de ORDS sin definir.
          api.vehiculos.crear({ idEmpresa, nombre: valores.nombre, partes }),
    onSuccess: (r, valores) => {
      queryClient.invalidateQueries({ queryKey: ["vehiculos"] });
      queryClient.invalidateQueries({ queryKey: ["vehiculos-selector"] });
      queryClient.invalidateQueries({ queryKey: ["vehiculo-partes"] });
      if (r === null) {
        toast.success("Vehículo actualizado");
        onCerrar();
        return;
      }
      toast.success(
        r.partes > 0
          ? `Vehículo creado con ${r.partes} repuesto${r.partes === 1 ? "" : "s"}`
          : "Vehículo creado",
      );
      onCerrar();
      // Se abren sus repuestos: el paso siguiente es revisar con qué artículos
      // coincidió cada código, o seguir cargando.
      onCreado({ id: r.id, idEmpresa, nombre: valores.nombre.trim(), cantidadPartes: r.partes });
    },
    // El 409 de nombre repetido y el 400 de una línea llegan con su mensaje.
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo guardar")),
  });

  return (
    <Dialog open={abierto} onOpenChange={(v) => !v && onCerrar()}>
      <DialogContent className="flex max-h-[90dvh] max-w-[95vw] flex-col sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{editando ? "Editar vehículo" : "Nuevo vehículo"}</DialogTitle>
          <DialogDescription>
            {editando
              ? "Sólo el nombre. Los repuestos se corrigen desde el botón de repuestos de la fila."
              : "El nombre y, si querés, sus repuestos. También se pueden cargar después."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form
            onSubmit={form.handleSubmit((v) => guardar.mutate(v))}
            className="flex min-h-0 flex-1 flex-col gap-4"
            noValidate
          >
            <div className="-mx-1 min-h-0 flex-1 space-y-4 overflow-y-auto px-1">
              <FormField
                control={form.control}
                name="nombre"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Nombre</FormLabel>
                    <FormControl>
                      <Input autoFocus placeholder="Toyota Hilux 2.8 2016" {...field} />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />

              {!editando && (
                <div className="space-y-2">
                  <div className="flex items-center justify-between gap-2">
                    <p className="text-sm font-medium">Repuestos</p>
                    <Button type="button" variant="outline" size="sm" onClick={agregarLinea}>
                      <Plus className="size-4" />
                      Agregar línea
                    </Button>
                  </div>

                  {lineas.length === 0 ? (
                    <p className="text-[0.8rem] text-muted-foreground">
                      Sin repuestos todavía. Se pueden agregar ahora o después, desde el botón de
                      repuestos del vehículo.
                    </p>
                  ) : (
                    <>
                      {/* Las etiquetas una sola vez como encabezado, no en cada
                          línea. En móvil las líneas se apilan y cada campo lleva
                          su placeholder. */}
                      <div className="hidden gap-2 px-1 sm:grid sm:grid-cols-[1fr_2fr_auto]">
                        <span className="text-xs text-muted-foreground">Código</span>
                        <span className="text-xs text-muted-foreground">Descripción</span>
                        <span className="w-9" />
                      </div>
                      <ul className="space-y-2">
                        {lineas.map((l) => (
                          <li
                            key={l.clave}
                            className="grid gap-2 sm:grid-cols-[1fr_2fr_auto] sm:items-center"
                          >
                            <Input
                              value={l.codigoEquivalente}
                              onChange={(e) =>
                                cambiarLinea(l.clave, { codigoEquivalente: e.target.value })
                              }
                              placeholder="Código"
                              className="font-mono"
                              aria-label="Código"
                            />
                            <div className="flex gap-2">
                              <Input
                                value={l.descripcion}
                                onChange={(e) =>
                                  cambiarLinea(l.clave, { descripcion: e.target.value })
                                }
                                placeholder="Descripción"
                                aria-label="Descripción"
                                className="flex-1"
                              />
                              <Button
                                type="button"
                                variant="ghost"
                                size="icon"
                                className="shrink-0 text-destructive hover:text-destructive"
                                onClick={() =>
                                  setLineas((ls) => ls.filter((x) => x.clave !== l.clave))
                                }
                                title="Quitar la línea"
                                aria-label="Quitar la línea"
                              >
                                <X className="size-4" />
                              </Button>
                            </div>
                          </li>
                        ))}
                      </ul>
                    </>
                  )}

                  {errorLineas && <p className="text-xs text-destructive">{errorLineas}</p>}
                </div>
              )}
            </div>

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onCerrar}>
                Cancelar
              </Button>
              <Button
                type="submit"
                disabled={guardar.isPending || (!editando && errorLineas !== null)}
              >
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {editando
                  ? "Guardar"
                  : partes.length > 0
                    ? `Crear con ${partes.length} repuesto${partes.length === 1 ? "" : "s"}`
                    : "Crear"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}
