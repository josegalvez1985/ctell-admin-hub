import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, MapPin, Plus, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";

import { SelectorModal } from "@/components/ctell/SelectorModal";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { api, ApiError, type Articulo, type ArticuloUbicacion } from "@/lib/api";

function mensajeError(e: unknown, respaldo: string): string {
  return e instanceof ApiError ? e.message : respaldo;
}

/** "A1 · Estante 3 · Nivel 2" — la ubicación en una línea. */
function etiquetaUbicacion(zona: string, estante: number, nivel: number): string {
  return `${zona} · Estante ${estante} · Nivel ${nivel}`;
}

/**
 * Ubicaciones donde está un artículo.
 *
 * Va como diálogo sobre el ABM de artículos y no como página propia: siempre se
 * mira "dónde está ESTE artículo", así que una ruta aparte obligaría a elegir el
 * artículo de nuevo al entrar. Mismo criterio que `DetalleMonedasDialog`.
 *
 * **No hay edición, sólo asignar y quitar.** La fila de cruce no tiene datos
 * propios —desde que `CANTIDAD_UBICADA` salió del DDL— así que mover un artículo
 * de estante es quitar una asignación y crear otra.
 *
 * El listado de ubicaciones disponibles NO se filtra por la sucursal activa a
 * propósito: un artículo puede estar en depósitos de varias sucursales, y
 * limitarlo a la sucursal del momento impediría asignarle las otras.
 */
export function ArticuloUbicacionesDialog({
  articulo,
  onOpenChange,
}: {
  /** Artículo cuyas ubicaciones se están viendo. `null` cierra el diálogo. */
  articulo: Articulo | null;
  onOpenChange: (abierto: boolean) => void;
}) {
  const queryClient = useQueryClient();
  const { empresa } = useEmpresa();
  const [aQuitar, setAQuitar] = useState<ArticuloUbicacion | null>(null);
  const [aAsignar, setAAsignar] = useState("");

  const idArticulo = articulo?.id ?? null;

  const asignadas = useQuery({
    queryKey: ["articulos-ubicaciones", idArticulo],
    queryFn: () => api.articulosUbicaciones.listar({ idArticulo: idArticulo! }),
    enabled: idArticulo !== null,
  });

  // Todas las ubicaciones de la empresa, para el selector. Sin filtrar por
  // sucursal: ver la nota del encabezado.
  //
  // La queryKey lleva el sufijo "todas" y NO es ["ubicaciones", idEmpresa, null]:
  // esa clave la usa la página de Ubicaciones mientras la sucursal no hidrató, y
  // su consulta SÍ filtra por sucursal. Con la misma clave, TanStack Query las
  // trata como una sola query y este selector recibía en caché una lista
  // filtrada por sucursal —o vacía—, dejando afuera las ubicaciones que se
  // querían asignar.
  const disponibles = useQuery({
    queryKey: ["ubicaciones", "todas", empresa?.id ?? null],
    queryFn: () => api.ubicaciones.listar({ idEmpresa: empresa!.id }),
    enabled: idArticulo !== null && empresa !== null,
  });

  const items = asignadas.data?.items ?? [];

  /** Las que todavía no están asignadas: ofrecer una asignada daría 409. */
  const opciones = useMemo(() => {
    const yaAsignadas = new Set(items.map((i) => i.idUbicacion));
    return (disponibles.data?.items ?? [])
      .filter((u) => !yaAsignadas.has(u.id))
      .map((u) => ({
        valor: String(u.id),
        etiqueta: etiquetaUbicacion(u.zona, u.estante, u.nivel),
        descripcion: u.descripcion ?? undefined,
      }));
  }, [disponibles.data?.items, items]);

  function invalidar() {
    queryClient.invalidateQueries({ queryKey: ["articulos-ubicaciones", idArticulo] });
  }

  const asignar = useMutation({
    mutationFn: (idUbicacion: number) =>
      api.articulosUbicaciones.asignar({ idArticulo: idArticulo!, idUbicacion }),
    onSuccess: () => {
      toast.success("Ubicación asignada");
      setAAsignar("");
      invalidar();
    },
    onError: (e) => toast.error(mensajeError(e, "No se pudo asignar la ubicación")),
  });

  const quitar = useMutation({
    mutationFn: (id: number) => api.articulosUbicaciones.quitar(id, empresa!.id),
    onSuccess: () => {
      toast.success("Ubicación quitada");
      setAQuitar(null);
      invalidar();
    },
    onError: (e) => toast.error(mensajeError(e, "No se pudo quitar la ubicación")),
  });

  return (
    <>
      <Dialog open={articulo !== null} onOpenChange={onOpenChange}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>Ubicaciones de {articulo?.nombreArticulo}</DialogTitle>
            <DialogDescription>
              Dónde se guarda este artículo en el depósito. Puede estar en varias ubicaciones,
              incluso de distintas sucursales.
            </DialogDescription>
          </DialogHeader>

          {/* Asignar: combobox + botón. Va arriba porque es la acción principal
              cuando la lista está vacía, que es el caso inicial. */}
          <div className="flex items-end gap-2">
            <div className="min-w-0 flex-1">
              <SelectorModal
                opciones={opciones}
                value={aAsignar}
                onChange={setAAsignar}
                placeholder={
                  disponibles.isPending
                    ? "Cargando ubicaciones…"
                    : opciones.length === 0
                      ? "No hay ubicaciones para asignar"
                      : "Elegí una ubicación"
                }
                buscarPlaceholder="Buscar zona…"
                disabled={disponibles.isPending || opciones.length === 0}
              />
            </div>
            <Button
              onClick={() => aAsignar && asignar.mutate(Number(aAsignar))}
              disabled={!aAsignar || asignar.isPending}
            >
              {asignar.isPending ? (
                <Loader2 className="size-4 animate-spin" />
              ) : (
                <Plus className="size-4" />
              )}
              Asignar
            </Button>
          </div>

          {asignadas.isPending ? (
            <div className="space-y-2">
              {[0, 1].map((i) => (
                <Skeleton key={i} className="h-14 w-full" />
              ))}
            </div>
          ) : asignadas.isError ? (
            <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">
              No se pudieron cargar las ubicaciones del artículo.
            </p>
          ) : items.length === 0 ? (
            <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
              {/* El estado vacío distingue las dos causas: sin ubicaciones
                  cargadas no hay nada que asignar, y eso se arregla en otra
                  pantalla. */}
              {disponibles.data?.items.length === 0
                ? "La empresa no tiene ubicaciones cargadas. Creá una en Ubicaciones."
                : "Este artículo todavía no tiene ubicaciones asignadas."}
            </p>
          ) : (
            // <ul> y no <Table>: dentro de un diálogo el ancho es acotado y una
            // tabla obligaría a scrollear de costado.
            <ul className="scrollbar-fino max-h-72 space-y-2 overflow-y-auto">
              {items.map((item) => (
                <li
                  key={item.id}
                  className="flex items-center gap-3 rounded-lg border border-border p-3"
                >
                  <MapPin className="size-5 shrink-0 text-primary" />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium tabular-nums text-foreground">
                      {etiquetaUbicacion(item.zona, item.estante, item.nivel)}
                    </p>
                    <p className="mt-0.5 truncate text-xs text-muted-foreground">
                      {item.sucursal}
                      {item.descripcion ? ` · ${item.descripcion}` : ""}
                    </p>
                  </div>
                  <Button
                    variant="ghost"
                    size="icon"
                    title="Quitar"
                    aria-label={`Quitar ${etiquetaUbicacion(item.zona, item.estante, item.nivel)}`}
                    onClick={() => setAQuitar(item)}
                  >
                    <Trash2 className="size-4 text-destructive" />
                  </Button>
                </li>
              ))}
            </ul>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => onOpenChange(false)}>
              Cerrar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={aQuitar !== null} onOpenChange={(a) => !a && setAQuitar(null)}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Quitar ubicación</DialogTitle>
            <DialogDescription>
              El artículo deja de estar asignado a{" "}
              {aQuitar ? etiquetaUbicacion(aQuitar.zona, aQuitar.estante, aQuitar.nivel) : ""}. La
              ubicación no se borra.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2 sm:gap-2">
            <Button variant="outline" onClick={() => setAQuitar(null)}>
              Cancelar
            </Button>
            <Button
              variant="destructive"
              disabled={quitar.isPending}
              onClick={() => aQuitar && quitar.mutate(aQuitar.id)}
            >
              {quitar.isPending && <Loader2 className="size-4 animate-spin" />}
              Quitar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
