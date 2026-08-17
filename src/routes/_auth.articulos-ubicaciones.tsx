import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, MapPin, Plus, Search, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";

import { AppLayout } from "@/components/ctell/AppLayout";
import { Combobox } from "@/components/ctell/Combobox";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, type ArticuloUbicacion } from "@/lib/api";
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
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
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

export const Route = createFileRoute("/_auth/articulos-ubicaciones")({
  head: () => ({
    meta: [
      { title: tituloPagina("Ubicaciones de artículos") },
      {
        name: "description",
        content: "En qué ubicación del depósito está cada artículo.",
      },
    ],
  }),
  component: ArticulosUbicacionesPage,
});

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

const POR_PAGINA = 20;

/** "A1 · Estante 3 · Nivel 2" */
function etiquetaUbicacion(zona: string, estante: number, nivel: number): string {
  return `${zona} · Estante ${estante} · Nivel ${nivel}`;
}

/**
 * Ubicaciones de artículos: el cruce completo, con su propia pantalla.
 *
 * La tabla no tiene datos propios —sólo une un artículo con una ubicación— así
 * que el ABM es **asignar y quitar**, sin edición: mover un artículo de estante
 * es quitar la asignación vieja y crear la nueva.
 *
 * El mismo cruce se puede ver también desde el ABM de Artículos, con el botón de
 * ubicación de cada fila. Esa vista responde "dónde está ESTE artículo"; esta
 * responde "qué hay asignado en todo el depósito", que es la que sirve para
 * revisar o cargar de corrido.
 */
function ArticulosUbicacionesPage() {
  const queryClient = useQueryClient();
  const { empresa } = useEmpresa();
  const [creando, setCreando] = useState(false);
  const [aQuitar, setAQuitar] = useState<ArticuloUbicacion | null>(null);
  const [visibles, setVisibles] = useState(POR_PAGINA);

  // Sin filtros: el cruce completo. El backend acepta ?idArticulo= y
  // ?idUbicacion=, pero acá se lista todo y se filtra en el cliente con el
  // buscador — son pocas filas y así se busca por artículo Y por zona a la vez.
  const { data, isPending, isError } = useQuery({
    queryKey: ["articulos-ubicaciones", "todos"],
    queryFn: () => api.articulosUbicaciones.listar(),
    enabled: empresa !== null,
  });

  const items = data?.items ?? [];

  const { busqueda, setBusqueda, orden, alternarOrden, resultado } = useTablaListado(items, (i) => [
    i.nombreArticulo,
    i.codigoArticulo,
    i.zona,
    i.estante,
    i.nivel,
    i.sucursal,
    i.descripcion,
  ]);

  // `estante` y `nivel` son numéricos y useTablaListado ordena con
  // localeCompare: como texto, el estante 10 iría antes que el 2.
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

  const quitar = useMutation({
    mutationFn: (item: ArticuloUbicacion) => api.articulosUbicaciones.quitar(item.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["articulos-ubicaciones"] });
      toast.success("Asignación quitada");
      setAQuitar(null);
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo quitar la asignación")),
  });

  return (
    <AppLayout active="/articulos-ubicaciones" title="Ubicaciones de artículos">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">
              Ubicaciones de artículos
            </h1>
            <p className="mt-1 text-sm text-muted-foreground">
              En qué lugar del depósito se guarda cada artículo.
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null}>
            <Plus className="size-4" />
            Asignar ubicación
          </Button>
        </div>

        <div className="relative max-w-sm">
          <Search className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar artículo, zona o sucursal…"
            className="pl-9"
            aria-label="Buscar asignaciones"
          />
        </div>

        {isPending ? (
          <div className="space-y-2">
            {[0, 1, 2, 3].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        ) : isError ? (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
            No se pudieron cargar las asignaciones.
          </p>
        ) : resultado.length === 0 ? (
          <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
            {items.length === 0
              ? "Todavía no hay artículos asignados a ubicaciones."
              : "Ninguna asignación coincide con la búsqueda."}
          </p>
        ) : (
          <>
            {/* Móvil: tarjetas. Una tabla de 4 columnas en 360px obliga a
                scrollear de costado para leer una fila entera. */}
            <ul className="space-y-3 sm:hidden">
              {mostrados.map((item) => (
                <li key={item.id} className="surface-card p-4">
                  <p className="truncate font-semibold text-foreground">{item.nombreArticulo}</p>
                  {item.codigoArticulo && (
                    <p className="mt-0.5 text-xs text-muted-foreground">{item.codigoArticulo}</p>
                  )}
                  <div className="mt-2 flex items-start gap-2">
                    <MapPin className="mt-0.5 size-4 shrink-0 text-primary" />
                    <div className="min-w-0">
                      <p className="truncate text-sm tabular-nums text-foreground">
                        {etiquetaUbicacion(item.zona, item.estante, item.nivel)}
                      </p>
                      <p className="truncate text-xs text-muted-foreground">{item.sucursal}</p>
                    </div>
                  </div>

                  <div className="mt-3 border-t border-border pt-3">
                    <Button
                      variant="outline"
                      size="sm"
                      className="w-full text-destructive hover:bg-destructive/10 hover:text-destructive"
                      onClick={() => setAQuitar(item)}
                    >
                      <Trash2 className="size-4" />
                      Quitar
                    </Button>
                  </div>
                </li>
              ))}
            </ul>

            <div className="surface-card hidden overflow-x-auto sm:block">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHeadOrdenable
                      direccion={orden?.campo === "nombreArticulo" ? orden.direccion : null}
                      onClick={() => alternarOrden("nombreArticulo")}
                    >
                      Artículo
                    </TableHeadOrdenable>
                    <TableHeadOrdenable
                      direccion={orden?.campo === "sucursal" ? orden.direccion : null}
                      onClick={() => alternarOrden("sucursal")}
                    >
                      Sucursal
                    </TableHeadOrdenable>
                    <TableHeadOrdenable
                      direccion={orden?.campo === "zona" ? orden.direccion : null}
                      onClick={() => alternarOrden("zona")}
                    >
                      Zona
                    </TableHeadOrdenable>
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
                    <TableHead className="text-right">Acciones</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {mostrados.map((item) => (
                    <TableRow key={item.id}>
                      <TableCell className="font-medium text-foreground">
                        {item.nombreArticulo}
                        {item.codigoArticulo && (
                          <span className="block text-xs font-normal text-muted-foreground">
                            {item.codigoArticulo}
                          </span>
                        )}
                      </TableCell>
                      <TableCell className="text-muted-foreground">{item.sucursal}</TableCell>
                      <TableCell className="font-medium text-foreground">{item.zona}</TableCell>
                      <TableCell className="tabular-nums text-muted-foreground">
                        {item.estante}
                      </TableCell>
                      <TableCell className="tabular-nums text-muted-foreground">
                        {item.nivel}
                      </TableCell>
                      <TableCell className="text-right">
                        <Button
                          variant="ghost"
                          size="icon"
                          title="Quitar"
                          aria-label={`Quitar ${item.nombreArticulo} de ${etiquetaUbicacion(item.zona, item.estante, item.nivel)}`}
                          onClick={() => setAQuitar(item)}
                        >
                          <Trash2 className="size-4 text-destructive" />
                        </Button>
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

        {empresa !== null && (
          <AsignarDialog
            open={creando}
            idEmpresa={empresa.id}
            yaAsignadas={items}
            onClose={() => setCreando(false)}
          />
        )}

        <AlertDialog open={aQuitar !== null} onOpenChange={(o) => !o && setAQuitar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Quitar la asignación?</AlertDialogTitle>
              <AlertDialogDescription>
                {aQuitar?.nombreArticulo} deja de estar asignado a{" "}
                {aQuitar ? etiquetaUbicacion(aQuitar.zona, aQuitar.estante, aQuitar.nivel) : ""}. Ni
                el artículo ni la ubicación se borran.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancelar</AlertDialogCancel>
              <AlertDialogAction
                onClick={(e) => {
                  // Sin esto el AlertDialog se cierra antes de que la mutación
                  // termine y el error nunca se llega a mostrar.
                  e.preventDefault();
                  if (aQuitar) quitar.mutate(aQuitar);
                }}
                disabled={quitar.isPending}
              >
                {quitar.isPending && <Loader2 className="size-4 animate-spin" />}
                Quitar
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </main>
    </AppLayout>
  );
}

/**
 * Alta: elegir un artículo y una ubicación.
 *
 * Los dos son combobox con buscador (no `<Select>`): las listas pueden tener
 * cientos de artículos, y sin buscador encontrar uno es imposible.
 */
function AsignarDialog({
  open,
  idEmpresa,
  yaAsignadas,
  onClose,
}: {
  open: boolean;
  idEmpresa: number;
  /** Para no ofrecer un par que ya existe: daría 409. */
  yaAsignadas: ArticuloUbicacion[];
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const [idArticulo, setIdArticulo] = useState("");
  const [idUbicacion, setIdUbicacion] = useState("");

  const articulos = useQuery({
    queryKey: ["articulos", idEmpresa],
    queryFn: () => api.articulos.listar({ idEmpresa }),
    enabled: open,
  });

  // La queryKey lleva "todas": la clave ["ubicaciones", idEmpresa, …] la usa la
  // página de Ubicaciones con filtro por sucursal, y compartirla haría que este
  // selector recibiera en caché una lista recortada.
  const ubicaciones = useQuery({
    queryKey: ["ubicaciones", "todas", idEmpresa],
    queryFn: () => api.ubicaciones.listar({ idEmpresa }),
    enabled: open,
  });

  const opcionesArticulos = useMemo(
    () =>
      (articulos.data?.items ?? []).map((a) => ({
        valor: String(a.id),
        etiqueta: a.nombreArticulo,
        descripcion: a.codigoArticulo ?? undefined,
      })),
    [articulos.data?.items],
  );

  /** Las ubicaciones que ese artículo todavía no tiene asignadas. */
  const opcionesUbicaciones = useMemo(() => {
    const tomadas = new Set(
      yaAsignadas.filter((i) => String(i.idArticulo) === idArticulo).map((i) => i.idUbicacion),
    );
    return (ubicaciones.data?.items ?? [])
      .filter((u) => !tomadas.has(u.id))
      .map((u) => ({
        valor: String(u.id),
        etiqueta: etiquetaUbicacion(u.zona, u.estante, u.nivel),
        descripcion: u.descripcion ?? undefined,
      }));
  }, [ubicaciones.data?.items, yaAsignadas, idArticulo]);

  const asignar = useMutation({
    mutationFn: () =>
      api.articulosUbicaciones.asignar({
        idArticulo: Number(idArticulo),
        idUbicacion: Number(idUbicacion),
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["articulos-ubicaciones"] });
      toast.success("Ubicación asignada");
      // Se limpia sólo la ubicación: lo habitual es cargar varias ubicaciones
      // del mismo artículo de corrido.
      setIdUbicacion("");
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo asignar la ubicación")),
  });

  function cerrar() {
    setIdArticulo("");
    setIdUbicacion("");
    onClose();
  }

  return (
    <Dialog open={open} onOpenChange={(o) => !o && cerrar()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Asignar ubicación</DialogTitle>
          <DialogDescription>
            Elegí el artículo y dónde se guarda. Un artículo puede estar en varias ubicaciones.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
          <div className="space-y-2">
            <Label>Artículo</Label>
            <Combobox
              opciones={opcionesArticulos}
              value={idArticulo}
              onChange={(v) => {
                setIdArticulo(v);
                // La ubicación elegida puede estar ya asignada al artículo
                // nuevo: se limpia para no mandar un par que daría 409.
                setIdUbicacion("");
              }}
              placeholder={articulos.isPending ? "Cargando…" : "Elegí un artículo"}
              buscarPlaceholder="Buscar artículo…"
              disabled={articulos.isPending}
            />
          </div>

          <div className="space-y-2">
            <Label>Ubicación</Label>
            <Combobox
              opciones={opcionesUbicaciones}
              value={idUbicacion}
              onChange={setIdUbicacion}
              placeholder={
                ubicaciones.isPending
                  ? "Cargando…"
                  : !idArticulo
                    ? "Elegí primero el artículo"
                    : opcionesUbicaciones.length === 0
                      ? "Sin ubicaciones libres para este artículo"
                      : "Elegí una ubicación"
              }
              buscarPlaceholder="Buscar zona…"
              disabled={ubicaciones.isPending || !idArticulo || opcionesUbicaciones.length === 0}
            />
            {ubicaciones.data?.items.length === 0 && !ubicaciones.isPending && (
              <p className="text-xs text-muted-foreground">
                La empresa no tiene ubicaciones cargadas. Creá una en Ubicaciones.
              </p>
            )}
          </div>
        </div>

        <DialogFooter className="gap-2 sm:gap-2">
          <Button variant="outline" onClick={cerrar}>
            Cerrar
          </Button>
          <Button
            onClick={() => asignar.mutate()}
            disabled={!idArticulo || !idUbicacion || asignar.isPending}
          >
            {asignar.isPending && <Loader2 className="size-4 animate-spin" />}
            Asignar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
