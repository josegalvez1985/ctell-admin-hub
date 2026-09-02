import { useInfiniteQuery } from "@tanstack/react-query";
import { Check, ChevronsUpDown, Loader2, Plus, Search } from "lucide-react";
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
import { api, type Articulo } from "@/lib/api";
import { cn } from "@/lib/utils";
import { DialogoAltaRapida, type AltaRapida } from "./SelectorModal";

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
  alta,
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
  /**
   * El tercer argumento es **el artículo entero**, y sólo llega cuando se lo
   * eligió de la lista: un alta rápida devuelve nada más el id y el nombre de lo
   * recién creado.
   *
   * Existe porque hay pantallas que necesitan algo más que el nombre —el conteo
   * de inventario mira `marca` para ofrecer cargarla si falta— y sin esto habría
   * que volver a pedir el artículo por id, que además es una consulta que
   * `/articulos/listar` no ofrece.
   *
   * Es opcional en la firma a propósito: los formularios que sólo guardan el id
   * siguen escribiendo `(valor, etiqueta) => …` sin enterarse.
   */
  onChange: (valor: string, etiqueta: string, articulo?: Articulo) => void;
  placeholder?: string;
  disabled?: boolean;
  className?: string;
  /**
   * Deja crear el artículo que falta sin salir de la pantalla. Mismo mecanismo
   * y mismo diálogo que `SelectorModal` — ver `AltaRapida`.
   */
  alta?: AltaRapida | undefined;
}) {
  const [abierto, setAbierto] = useState(false);
  const [creandoCon, setCreandoCon] = useState<string | null>(null);

  const boton = (
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
  );

  return (
    <>
      {alta ? (
        <div className="flex items-start gap-2">
          {boton}
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="min-h-9 shrink-0"
            disabled={disabled}
            onClick={() => setCreandoCon("")}
            title={alta.titulo}
            aria-label={alta.titulo}
          >
            <Plus className="size-4" />
          </Button>
        </div>
      ) : (
        boton
      )}

      {/* El contenido se monta sólo con el modal abierto: así la consulta no
          sale hasta que alguien va a elegir de verdad. Con varios selectores en
          un formulario, montarlos siempre dispararía una búsqueda por cada uno
          al abrir la pantalla. */}
      {abierto && (
        <DialogoArticulos
          idEmpresa={idEmpresa}
          value={value}
          onCerrar={() => setAbierto(false)}
          onElegir={(valor, etiqueta, articulo) => {
            onChange(valor, etiqueta, articulo);
            setAbierto(false);
          }}
          {...(alta ? { onCrear: (termino: string) => setCreandoCon(termino) } : {})}
          {...(alta ? { textoCrear: alta.titulo } : {})}
        />
      )}

      {alta && (
        <DialogoAltaRapida
          alta={alta}
          valorInicial={creandoCon}
          onCerrar={() => setCreandoCon(null)}
          onCreada={(opcion) => {
            onChange(opcion.valor, opcion.etiqueta);
            setCreandoCon(null);
            setAbierto(false);
          }}
        />
      )}
    </>
  );
}

/**
 * Cómo se lee el artículo YA ELEGIDO, en el botón del selector.
 *
 * Lleva la marca: dos artículos con el mismo nombre —"Filtro de aceite"— son
 * piezas distintas según de quién sean, y con sólo el nombre el campo cerrado
 * no deja distinguir cuál de los dos quedó. Es el dato que la lista muestra al
 * lado del código, así que no verlo después de elegir se lee como si se hubiera
 * perdido.
 *
 * **Es SÓLO presentación.** Ninguno de los formularios que usan este selector
 * manda esta etiqueta al backend —viajan `idArticulo` y nada más—, así que el
 * " · marca" no ensucia ningún dato guardado. Si alguna pantalla nueva llegara
 * a persistirla, tiene que guardar el nombre por su cuenta, no esto.
 *
 * Un artículo sin marca cargada devuelve el nombre pelado, sin el separador
 * colgando.
 */
function etiquetaDe(articulo: Articulo): string {
  return articulo.marca
    ? `${articulo.nombreArticulo} · ${articulo.marca}`
    : articulo.nombreArticulo;
}

function DialogoArticulos({
  idEmpresa,
  value,
  onCerrar,
  onElegir,
  onCrear,
  textoCrear = "Crear",
}: {
  idEmpresa: number;
  value: string;
  onCerrar: () => void;
  onElegir: (valor: string, etiqueta: string, articulo: Articulo) => void;
  /** Recibe lo que se estaba buscando, para arrancar el alta con ese texto. */
  onCrear?: ((termino: string) => void) | undefined;
  textoCrear?: string;
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
            La búsqueda recorre todo el catálogo y mira también la marca y los códigos equivalentes
            del artículo, no sólo su nombre.
          </DialogDescription>
        </DialogHeader>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            autoFocus
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Nombre, código OEM, marca o equivalencia…"
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
                onClick={() => onElegir(String(articulo.id), etiquetaDe(articulo), articulo)}
                className={cn(
                  "flex w-full items-center gap-2 rounded-md px-2 py-2 text-left text-sm transition-colors hover:bg-accent",
                  elegido && "bg-accent",
                )}
              >
                <Check className={cn("size-4 shrink-0", elegido ? "opacity-100" : "opacity-0")} />
                <span className="flex min-w-0 flex-1 flex-col">
                  <span className="break-words">{articulo.nombreArticulo}</span>
                  {/* SE MUESTRA TODO LO QUE LA BÚSQUEDA MIRA: código OEM, marca
                      y equivalencias. La lista contesta a un término que puede
                      no estar en el nombre, y sin ver por dónde coincidió el
                      resultado parece un error del sistema.

                      Segunda línea: OEM y marca, los dos datos cortos con los
                      que se identifica la pieza en la mano. */}
                  {(articulo.codigoArticulo || articulo.marca) && (
                    <span className="truncate text-xs text-muted-foreground">
                      {[articulo.codigoArticulo, articulo.marca].filter(Boolean).join(" · ")}
                    </span>
                  )}
                  {/* Tercera línea: las equivalencias, que son varias y largas.
                      Van aparte y con su rótulo —un código suelto al lado del
                      OEM no se distinguiría de él, y son cosas distintas: el
                      OEM es el del fabricante del vehículo, la equivalencia es
                      cómo llama a la misma pieza otra marca.

                      `line-clamp-2` y no `truncate`: entran dos renglones de
                      códigos, que es lo que hace falta para reconocer el que se
                      tecleó; el resto lo recorta el backend a 200 caracteres. */}
                  {articulo.codigosEquivalentes && (
                    <span className="line-clamp-2 break-words text-xs text-muted-foreground/80">
                      Equiv.: {articulo.codigosEquivalentes}
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

        {/* Fuera del área que scrollea: con el catálogo entero cargado, un botón
            al final de la lista no se ve nunca. El término va como arranque del
            alta — buscar algo y no encontrarlo es cuando hace falta crearlo. */}
        {onCrear && (
          <Button
            type="button"
            variant="outline"
            className="w-full"
            onClick={() => onCrear(busqueda.trim())}
          >
            <Plus className="size-4" />
            {articulos.length === 0 && busqueda.trim() !== ""
              ? `Crear "${busqueda.trim()}"`
              : textoCrear}
          </Button>
        )}
      </DialogContent>
    </Dialog>
  );
}
