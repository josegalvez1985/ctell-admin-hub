import { useInfiniteQuery } from "@tanstack/react-query";
import { Check, ChevronsUpDown, Loader2, Search, X } from "lucide-react";
import { useEffect, useState } from "react";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { api, type Vehiculo } from "@/lib/api";
import { cn } from "@/lib/utils";

/** Mismo tamaño de página que la pantalla de Vehículos. */
const POR_PAGINA = 20;

/** Espera antes de mandar la búsqueda al servidor, igual que en Artículos. */
const ESPERA_BUSQUEDA_MS = 350;

/**
 * Selector de vehículo en MODAL PROPIO, que busca contra el servidor.
 *
 * Existe por lo mismo que `SelectorArticulo`: `/vehiculos/listar` está
 * paginado, así que un `SelectorModal` —que filtra en memoria sobre lo que
 * recibe— vería sólo los primeros 20 y el vehículo 300 no aparecería nunca.
 *
 * La etiqueta elegida se recibe por prop y no se busca por id: el vehículo ya
 * elegido puede no estar en la primera página.
 */
export function SelectorVehiculo({
  idEmpresa,
  value,
  etiquetaSeleccionada,
  onChange,
  placeholder = "Elegí un vehículo",
  disabled = false,
  className,
  quitable = false,
}: {
  idEmpresa: number;
  /** Id del vehículo elegido, como string (`""` = sin elegir). */
  value: string;
  etiquetaSeleccionada?: string | undefined;
  /** `("", "")` cuando se quita la selección (sólo con `quitable`). */
  onChange: (valor: string, etiqueta: string, vehiculo?: Vehiculo) => void;
  placeholder?: string;
  disabled?: boolean;
  className?: string;
  /**
   * Muestra una ✕ para volver a "sin elegir". Es para cuando el selector es un
   * FILTRO: ahí "todos los vehículos" es un valor válido y tiene que poder
   * recuperarse sin abrir el modal.
   */
  quitable?: boolean;
}) {
  const [abierto, setAbierto] = useState(false);

  return (
    <>
      <div className="flex items-start gap-2">
        <Button
          type="button"
          variant="outline"
          role="combobox"
          disabled={disabled}
          onClick={() => setAbierto(true)}
          className={cn(
            // `h-auto` + `whitespace-normal`: un nombre largo del Excel pasa a
            // una segunda línea en vez de desbordar lo que contiene al selector.
            "h-auto min-h-9 w-full justify-between whitespace-normal py-1.5 text-left font-normal",
            className,
          )}
          {...(etiquetaSeleccionada ? { title: etiquetaSeleccionada } : {})}
        >
          <span
            className={cn(
              "line-clamp-2 min-w-0 flex-1 break-words",
              !etiquetaSeleccionada && "text-muted-foreground",
            )}
          >
            {etiquetaSeleccionada || placeholder}
          </span>
          <ChevronsUpDown className="ml-2 size-4 shrink-0 self-center opacity-50" />
        </Button>
        {quitable && value !== "" && (
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="min-h-9 shrink-0"
            disabled={disabled}
            onClick={() => onChange("", "")}
            title="Quitar el filtro"
            aria-label="Quitar el filtro"
          >
            <X className="size-4" />
          </Button>
        )}
      </div>

      {/* Se monta sólo abierto: así la consulta no sale hasta que alguien va a
          elegir de verdad. */}
      {abierto && (
        <DialogoVehiculos
          idEmpresa={idEmpresa}
          value={value}
          onCerrar={() => setAbierto(false)}
          onElegir={(vehiculo) => {
            onChange(String(vehiculo.id), vehiculo.nombre, vehiculo);
            setAbierto(false);
          }}
        />
      )}
    </>
  );
}

function DialogoVehiculos({
  idEmpresa,
  value,
  onCerrar,
  onElegir,
}: {
  idEmpresa: number;
  value: string;
  onCerrar: () => void;
  onElegir: (vehiculo: Vehiculo) => void;
}) {
  const [busqueda, setBusqueda] = useState("");
  const [busquedaEnvio, setBusquedaEnvio] = useState("");

  useEffect(() => {
    const id = setTimeout(() => setBusquedaEnvio(busqueda), ESPERA_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  const { data, isPending, isError, fetchNextPage, hasNextPage, isFetchingNextPage } =
    useInfiniteQuery({
      // Clave propia: la de la pantalla de Vehículos lleva sus propios filtros,
      // y compartirla haría que una sirva la caché de la otra.
      queryKey: ["vehiculos-selector", idEmpresa, busquedaEnvio.trim()],
      queryFn: ({ pageParam }) =>
        api.vehiculos.listar({
          idEmpresa,
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

  const vehiculos = (data?.pages ?? []).flatMap((p) => p.items);
  const total = data?.pages[0]?.total ?? 0;

  return (
    <Dialog open onOpenChange={(a) => !a && onCerrar()}>
      {/* Mismas medidas que SelectorModal y SelectorArticulo: los tres son
          "elegir un valor de una lista" y tienen que verse iguales. */}
      <DialogContent className="flex max-h-[85dvh] max-w-[95vw] flex-col sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Elegí un vehículo</DialogTitle>
          <DialogDescription>
            La búsqueda mira el nombre y también los códigos de sus repuestos.
          </DialogDescription>
        </DialogHeader>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            autoFocus
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Nombre del vehículo o código de un repuesto…"
            className="pl-9"
          />
        </div>

        <div className="-mx-1 min-h-0 flex-1 overflow-y-auto px-1">
          {isPending && (
            <div className="space-y-2 py-2">
              {[0, 1, 2, 3, 4].map((i) => (
                <Skeleton key={i} className="h-10 w-full" />
              ))}
            </div>
          )}

          {isError && (
            <p className="py-8 text-center text-sm text-destructive">
              No se pudo cargar la lista de vehículos.
            </p>
          )}

          {!isPending && !isError && vehiculos.length === 0 && (
            <p className="py-8 text-center text-sm text-muted-foreground">
              {busquedaEnvio.trim()
                ? `Sin resultados para "${busquedaEnvio.trim()}".`
                : "Esta empresa todavía no tiene vehículos cargados."}
            </p>
          )}

          {vehiculos.map((vehiculo) => {
            const elegido = String(vehiculo.id) === value;
            return (
              <button
                key={vehiculo.id}
                type="button"
                onClick={() => onElegir(vehiculo)}
                className={cn(
                  "flex w-full items-center gap-2 rounded-md px-2 py-2 text-left text-sm transition-colors hover:bg-accent",
                  elegido && "bg-accent",
                )}
              >
                <Check className={cn("size-4 shrink-0", elegido ? "opacity-100" : "opacity-0")} />
                <span className="flex min-w-0 flex-1 flex-col">
                  <span className="break-words">{vehiculo.nombre}</span>
                  <span className="text-xs text-muted-foreground">
                    {vehiculo.cantidadPartes} repuesto{vehiculo.cantidadPartes === 1 ? "" : "s"}
                  </span>
                </span>
              </button>
            );
          })}

          {hasNextPage && (
            <div className="flex justify-center py-3">
              <Button
                type="button"
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
            </div>
          )}
        </div>

        {vehiculos.length > 0 && (
          <p className="text-center text-xs text-muted-foreground">
            Mostrando {vehiculos.length} de {total} vehículo{total === 1 ? "" : "s"}
          </p>
        )}
      </DialogContent>
    </Dialog>
  );
}
