import { Check, ChevronsUpDown, Search } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

export type OpcionSelector = {
  valor: string;
  etiqueta: string;
  /**
   * Texto secundario, chico y gris — el código de país, el RUC de una persona.
   * `| undefined` explícito porque `exactOptionalPropertyTypes` distingue "la
   * propiedad no está" de "está en undefined", y los llamadores la arman con
   * `x.campo ?? undefined` desde un campo nullable de la API.
   */
  descripcion?: string | undefined;
};

/**
 * Selector de un valor de otra tabla, en MODAL PROPIO.
 *
 * Es el componente estándar del proyecto para toda lista de valores: FK de un
 * formulario, filtro de columna, cualquier "elegí uno de estos". Reemplazó al
 * `Combobox` de popover en todas las pantallas.
 *
 * **El modal se usa siempre, aunque la lista traiga un solo ítem.** Es una
 * decisión de consistencia, no de tamaño: si el control cambiara de forma según
 * cuántas filas haya, la misma acción se vería distinta en cada pantalla y
 * habría que aprender dos interacciones para lo mismo. Un popover angosto y
 * pegado al campo tampoco deja lugar para la búsqueda y las dos líneas por fila.
 *
 * No pide datos: recibe `opciones` ya armadas, igual que el Combobox. Para una
 * tabla cuyo listado viene PAGINADO no sirve —vería sólo la primera página— y
 * hay que usar un selector que consulte al servidor, como
 * [SelectorArticulo](./SelectorArticulo.tsx).
 */
export function SelectorModal({
  opciones,
  value,
  onChange,
  placeholder = "Elegí una opción",
  buscarPlaceholder = "Buscar…",
  vacioTexto = "Sin resultados.",
  titulo = "Elegí una opción",
  descripcion,
  cargando = false,
  disabled = false,
  className,
}: {
  opciones: OpcionSelector[];
  value: string;
  onChange: (valor: string) => void;
  placeholder?: string;
  buscarPlaceholder?: string;
  vacioTexto?: string;
  /** Título del modal. Por defecto genérico; conviene nombrar la entidad. */
  titulo?: string;
  /** Línea de ayuda bajo el título. Se omite si no se pasa. */
  descripcion?: string | undefined;
  cargando?: boolean;
  disabled?: boolean;
  /** Clases del botón que abre el modal — el login lo necesita en h-12. */
  className?: string;
}) {
  const [abierto, setAbierto] = useState(false);
  const seleccionada = opciones.find((o) => o.valor === value);

  return (
    <>
      <Button
        type="button"
        variant="outline"
        role="combobox"
        aria-expanded={abierto}
        disabled={disabled || cargando}
        onClick={() => setAbierto(true)}
        className={cn("w-full justify-between font-normal", className)}
        // El disparador es de una sola línea, así que la etiqueta sigue
        // truncada acá. El `title` deja leer el nombre completo al pasar el
        // mouse sin tener que abrir el modal.
        {...(seleccionada ? { title: seleccionada.etiqueta } : {})}
      >
        <span className={cn("truncate", !seleccionada && "text-muted-foreground")}>
          {cargando ? "Cargando…" : (seleccionada?.etiqueta ?? placeholder)}
        </span>
        <ChevronsUpDown className="ml-2 size-4 shrink-0 opacity-50" />
      </Button>

      <ListaEnModal
        abierto={abierto}
        onCerrar={() => setAbierto(false)}
        opciones={opciones}
        value={value}
        onElegir={(v) => {
          onChange(v);
          setAbierto(false);
        }}
        titulo={titulo}
        {...(descripcion !== undefined ? { descripcion } : {})}
        buscarPlaceholder={buscarPlaceholder}
        vacioTexto={vacioTexto}
      />
    </>
  );
}

/**
 * El modal con el buscador y la lista. Se exporta porque el filtro de columna
 * (`TableHeadFiltrable`) lo abre desde su propio botón —el embudo del
 * encabezado— en vez del botón de arriba.
 *
 * La búsqueda filtra por etiqueta Y descripción, no por `valor`: el valor suele
 * ser un id, y tipear "Central" no encontraría nada si se comparara contra "12".
 */
export function ListaEnModal({
  abierto,
  onCerrar,
  opciones,
  value,
  onElegir,
  titulo,
  descripcion,
  buscarPlaceholder = "Buscar…",
  vacioTexto = "Sin resultados.",
}: {
  abierto: boolean;
  onCerrar: () => void;
  opciones: OpcionSelector[];
  value: string;
  onElegir: (valor: string) => void;
  titulo: string;
  descripcion?: string | undefined;
  buscarPlaceholder?: string;
  vacioTexto?: string;
}) {
  const [busqueda, setBusqueda] = useState("");

  // El término se limpia al cerrar: reabrir con el filtro anterior puesto haría
  // creer que faltan opciones.
  useEffect(() => {
    if (!abierto) setBusqueda("");
  }, [abierto]);

  const termino = busqueda.trim().toLowerCase();
  const filtradas = useMemo(() => {
    if (termino === "") return opciones;
    return opciones.filter((o) =>
      `${o.etiqueta} ${o.descripcion ?? ""}`.toLowerCase().includes(termino),
    );
  }, [opciones, termino]);

  return (
    <Dialog open={abierto} onOpenChange={(a) => !a && onCerrar()}>
      {/* `max-w-lg` y no `max-w-md`: las opciones suelen ser nombres de
          artículo, que con 28rem se cortaban a mitad de palabra. `max-w-[95vw]`
          lo mantiene dentro de la pantalla en móvil. */}
      <DialogContent className="flex max-h-[85vh] max-w-[95vw] flex-col sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{titulo}</DialogTitle>
          {descripcion && <DialogDescription>{descripcion}</DialogDescription>}
        </DialogHeader>

        {/* El buscador se muestra desde unas pocas opciones: con tres o cuatro
            ocupa más de lo que ayuda, y la lista entra entera en pantalla. */}
        {opciones.length > 6 && (
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              autoFocus
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
              placeholder={buscarPlaceholder}
              className="pl-9"
            />
          </div>
        )}

        <div className="-mx-1 min-h-0 flex-1 overflow-y-auto px-1">
          {filtradas.length === 0 ? (
            <p className="py-8 text-center text-sm text-muted-foreground">{vacioTexto}</p>
          ) : (
            filtradas.map((opcion) => {
              const elegida = opcion.valor === value;
              return (
                <button
                  key={opcion.valor}
                  type="button"
                  onClick={() => onElegir(opcion.valor)}
                  className={cn(
                    "flex w-full items-center gap-2 rounded-md px-2 py-2 text-left text-sm transition-colors hover:bg-accent",
                    elegida && "bg-accent",
                  )}
                >
                  <Check className={cn("size-4 shrink-0", elegida ? "opacity-100" : "opacity-0")} />
                  {/* La etiqueta se PARTE en varias líneas en vez de truncarse:
                      acá es donde hay que poder leer el nombre entero para
                      elegir, y dos artículos con el mismo prefijo largo se
                      veían idénticos cortados. La descripción sí sigue en una
                      línea: es corta y de apoyo. */}
                  <span className="flex min-w-0 flex-1 flex-col">
                    <span className="break-words">{opcion.etiqueta}</span>
                    {opcion.descripcion && (
                      <span className="truncate text-xs text-muted-foreground">
                        {opcion.descripcion}
                      </span>
                    )}
                  </span>
                </button>
              );
            })
          )}
        </div>
      </DialogContent>
    </Dialog>
  );
}
