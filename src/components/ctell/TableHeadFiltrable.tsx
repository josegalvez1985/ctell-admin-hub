import { ArrowDown, ArrowUp, ArrowUpDown, ListFilter } from "lucide-react";
import { useState } from "react";

import { ListaEnModal } from "@/components/ctell/SelectorModal";
import { TableHead } from "@/components/ui/table";
import { cn } from "@/lib/utils";

/** Valor que representa "sin filtrar". No colisiona con ningún id ni nombre. */
export const SIN_FILTRO = "__todos__";

export type OpcionFiltro = {
  /** El valor que se compara contra la fila. `SIN_FILTRO` limpia el filtro. */
  valor: string;
  etiqueta: string;
};

/**
 * Header de tabla que ordena al hacer click y filtra desde un modal.
 *
 * Reemplaza al combobox de filtro suelto arriba de la tabla: el filtro vive en
 * la columna que filtra, que es donde se lo busca. El embudo se pinta lleno
 * cuando hay un filtro activo, para que no quede escondido — un filtro que no
 * se ve es un filtro que hace parecer que faltan datos.
 *
 * Ordenar y filtrar son dos acciones separadas en el mismo header: el texto
 * ordena, el embudo abre el filtro. Por eso son dos botones y no uno.
 *
 * LA LISTA ABRE EN MODAL, igual que el resto de las listas de valores del
 * proyecto (ver [SelectorModal](./SelectorModal.tsx)). Antes era un popover
 * anclado al embudo: se cambió para que elegir un valor se vea y se opere igual
 * en toda la aplicación, sin importar desde dónde se lo abra.
 *
 * Recibe la dirección y el valor ya resueltos, igual que TableHeadOrdenable:
 * no se acopla al estado de `useTablaListado`.
 */
export function TableHeadFiltrable({
  children,
  direccion,
  onOrdenar,
  opciones,
  valor,
  onFiltrar,
  buscarPlaceholder = "Buscar…",
  className,
}: {
  children: React.ReactNode;
  direccion: "asc" | "desc" | null;
  onOrdenar: () => void;
  /** Sin la opción `SIN_FILTRO`: la agrega el componente arriba de todo. */
  opciones: OpcionFiltro[];
  valor: string;
  onFiltrar: (valor: string) => void;
  buscarPlaceholder?: string;
  className?: string;
}) {
  const [abierto, setAbierto] = useState(false);
  const IconoOrden = direccion === "asc" ? ArrowUp : direccion === "desc" ? ArrowDown : ArrowUpDown;
  const filtrando = valor !== SIN_FILTRO;

  const todas: OpcionFiltro[] = [{ valor: SIN_FILTRO, etiqueta: "Todos" }, ...opciones];

  return (
    <TableHead className={className}>
      <div className="flex items-center gap-1">
        <button
          type="button"
          onClick={onOrdenar}
          className={cn(
            "flex items-center gap-1 text-left font-medium text-muted-foreground hover:text-foreground",
            direccion && "text-foreground",
          )}
        >
          {children}
          <IconoOrden className="size-3.5 shrink-0" />
        </button>

        <button
          type="button"
          onClick={() => setAbierto(true)}
          aria-label={filtrando ? "Cambiar filtro" : "Filtrar"}
          className={cn(
            "rounded p-0.5 text-muted-foreground hover:bg-accent hover:text-foreground",
            filtrando && "bg-primary/10 text-primary hover:text-primary",
          )}
        >
          <ListFilter className="size-3.5 shrink-0" />
        </button>

        <ListaEnModal
          abierto={abierto}
          onCerrar={() => setAbierto(false)}
          opciones={todas}
          value={valor}
          onElegir={(v) => {
            onFiltrar(v);
            setAbierto(false);
          }}
          titulo="Filtrar"
          buscarPlaceholder={buscarPlaceholder}
        />
      </div>
    </TableHead>
  );
}
