import { useInfiniteQuery } from "@tanstack/react-query";
import { Check, ChevronsUpDown, Loader2, Search } from "lucide-react";
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
import { api } from "@/lib/api";
import { cn } from "@/lib/utils";

/**
 * Cuántos artículos trae cada página del selector. Es el mismo tamaño que usa
 * la pantalla de Artículos.
 */
const POR_PAGINA = 20;

/** Espera antes de mandar la búsqueda al servidor, igual que en Artículos. */
const ESPERA_BUSQUEDA_MS = 350;

/**
 * Selector de artículo en MODAL PROPIO, no en un popover pegado al campo.
 *
 * Existe porque `/articulos/listar` está paginado: devuelve 20 filas, no el
 * catálogo. Un Combobox común recibe esas 20 y filtra en memoria, así que el
 * artículo 300 no aparece nunca por más que se lo escriba — y el que ya estaba
 * guardado se ve vacío si no cayó en la primera página.
 *
 * Acá el buscador consulta AL SERVIDOR y el "Mostrar más" pide la página
 * siguiente, así que se llega a cualquier artículo del catálogo.
 *
 * El modal es independiente y no un popover anclado al input: la lista necesita
 * su propio espacio —búsqueda, filas de dos líneas, botón de paginar— y dentro
 * de un popover del ancho del campo eso queda apretado. Es el patrón a seguir
 * para las listas de valores del proyecto (ver docs/GUIA-FRONTEND.md).
 */
export function SelectorArticulo({
  idEmpresa,
  value,
  etiquetaSeleccionada,
  onChange,
  placeholder = "Elegí un artículo",
  disabled = false,
  className,
}: {
  idEmpresa: number;
  /** Id del artículo elegido, como string (""` = sin elegir). */
  value: string;
  /**
   * Nombre del artículo ya elegido, para mostrarlo en el botón.
   *
   * Se recibe de afuera y NO se busca por id: al editar, el artículo guardado
   * puede no estar en la primera página, y sin este dato el campo se vería
   * vacío como si no hubiera nada seleccionado.
   */
  etiquetaSeleccionada?: string | undefined;
  onChange: (valor: string, etiqueta: string) => void;
  placeholder?: string;
  disabled?: boolean;
  className?: string;
}) {
  const [abierto, setAbierto] = useState(false);

  return (
    <>
      <Button
        type="button"
        variant="outline"
        role="combobox"
        disabled={disabled}
        onClick={() => setAbierto(true)}
        className={cn(
          // Igual que en SelectorModal: `h-auto` + `whitespace-normal` para que
          // un nombre de artículo largo pase a una segunda línea en vez de
          // desbordar el diálogo que contiene al selector.
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
          {etiquetaSeleccionada ?? placeholder}
        </span>
        <ChevronsUpDown className="ml-2 size-4 shrink-0 self-center opacity-50" />
      </Button>

      {/* El contenido se monta sólo con el modal abierto: así la consulta no
          sale hasta que alguien va a elegir de verdad. Con varios selectores en
          un formulario, montarlos siempre dispararía una búsqueda por cada uno
          al abrir la pantalla. */}
      {abierto && (
        <DialogoArticulos
          idEmpresa={idEmpresa}
          value={value}
          onCerrar={() => setAbierto(false)}
          onElegir={(valor, etiqueta) => {
            onChange(valor, etiqueta);
            setAbierto(false);
          }}
        />
      )}
    </>
  );
}

function DialogoArticulos({
  idEmpresa,
  value,
  onCerrar,
  onElegir,
}: {
  idEmpresa: number;
  value: string;
  onCerrar: () => void;
  onElegir: (valor: string, etiqueta: string) => void;
}) {
  // `busqueda` es lo que se tipea (inmediato) y `busquedaEnvio` lo que viaja al
  // servidor: sin la espera, cada tecla dispararía un request.
  const [busqueda, setBusqueda] = useState("");
  const [busquedaEnvio, setBusquedaEnvio] = useState("");

  useEffect(() => {
    const id = setTimeout(() => setBusquedaEnvio(busqueda), ESPERA_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  const { data, isPending, isError, fetchNextPage, hasNextPage, isFetchingNextPage } =
    useInfiniteQuery({
      queryKey: ["articulos-selector", idEmpresa, busquedaEnvio.trim()],
      queryFn: ({ pageParam }) =>
        api.articulos.listar({
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

  const articulos = (data?.pages ?? []).flatMap((p) => p.items);
  const total = data?.pages[0]?.total ?? 0;

  return (
    <Dialog open onOpenChange={(a) => !a && onCerrar()}>
      {/* Mismas medidas que SelectorModal: los dos son "elegir un valor de una
          lista" y tienen que verse iguales aunque uno consulte paginado. */}
      <DialogContent className="flex max-h-[85vh] max-w-[95vw] flex-col sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Elegí un artículo</DialogTitle>
          <DialogDescription>
            La búsqueda recorre todo el catálogo, no sólo lo que se ve.
          </DialogDescription>
        </DialogHeader>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            autoFocus
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre, código o descripción…"
            className="pl-9"
          />
        </div>

        <div className="-mx-1 min-h-0 flex-1 overflow-y-auto px-1">
          {isPending && (
            <div className="space-y-2 py-2">
              {[0, 1, 2, 3, 4].map((i) => (
                <Skeleton key={i} className="h-12 w-full" />
              ))}
            </div>
          )}

          {isError && (
            <p className="py-8 text-center text-sm text-destructive">
              No se pudo cargar la lista de artículos.
            </p>
          )}

          {!isPending && !isError && articulos.length === 0 && (
            <p className="py-8 text-center text-sm text-muted-foreground">
              {busquedaEnvio.trim()
                ? `Sin resultados para "${busquedaEnvio.trim()}".`
                : "Esta empresa todavía no tiene artículos cargados."}
            </p>
          )}

          {articulos.map((articulo) => {
            const elegido = String(articulo.id) === value;
            return (
              <button
                key={articulo.id}
                type="button"
                onClick={() => onElegir(String(articulo.id), articulo.nombreArticulo)}
                className={cn(
                  "flex w-full items-center gap-2 rounded-md px-2 py-2 text-left text-sm transition-colors hover:bg-accent",
                  elegido && "bg-accent",
                )}
              >
                <Check className={cn("size-4 shrink-0", elegido ? "opacity-100" : "opacity-0")} />
                <span className="flex min-w-0 flex-1 flex-col">
                  <span className="break-words">{articulo.nombreArticulo}</span>
                  {articulo.codigoArticulo && (
                    <span className="truncate text-xs text-muted-foreground">
                      {articulo.codigoArticulo}
                    </span>
                  )}
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

        {articulos.length > 0 && (
          <p className="text-center text-xs text-muted-foreground">
            Mostrando {articulos.length} de {total} artículo{total === 1 ? "" : "s"}
          </p>
        )}
      </DialogContent>
    </Dialog>
  );
}
