import { ArrowDown, ArrowUp, ArrowUpDown, Check, ListFilter } from "lucide-react";
import { useState } from "react";

import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
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
 * Header de tabla que ordena al hacer click y filtra desde un desplegable.
 *
 * Reemplaza al combobox de filtro suelto arriba de la tabla: el filtro vive en
 * la columna que filtra, que es donde se lo busca. El embudo se pinta lleno
 * cuando hay un filtro activo, para que no quede escondido — un filtro que no
 * se ve es un filtro que hace parecer que faltan datos.
 *
 * Ordenar y filtrar son dos acciones separadas en el mismo header: el texto
 * ordena, el embudo abre el filtro. Por eso son dos botones y no uno.
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

        <Popover open={abierto} onOpenChange={setAbierto}>
          <PopoverTrigger asChild>
            <button
              type="button"
              aria-label={filtrando ? "Cambiar filtro" : "Filtrar"}
              className={cn(
                "rounded p-0.5 text-muted-foreground hover:bg-accent hover:text-foreground",
                filtrando && "bg-primary/10 text-primary hover:text-primary",
              )}
            >
              <ListFilter className="size-3.5 shrink-0" />
            </button>
          </PopoverTrigger>
          <PopoverContent className="w-56 p-0" align="start">
            <Command
              filter={(itemValue, search) => {
                // cmdk normaliza el value del CommandItem (minúsculas y sin
                // espacios en los extremos), así que la comparación contra el
                // valor original normaliza de los dos lados. Se busca contra la
                // etiqueta visible: el value suele ser un id, y "12" no
                // matchearía nunca con "Central".
                const buscado = itemValue.trim().toLowerCase();
                const opcion = todas.find((o) => o.valor.trim().toLowerCase() === buscado);
                return (opcion?.etiqueta ?? "").toLowerCase().includes(search.toLowerCase())
                  ? 1
                  : 0;
              }}
            >
              <CommandInput placeholder={buscarPlaceholder} />
              <CommandList>
                <CommandEmpty>Sin resultados.</CommandEmpty>
                <CommandGroup>
                  {todas.map((opcion) => (
                    <CommandItem
                      key={opcion.valor}
                      value={opcion.valor}
                      onSelect={(elegido) => {
                        // cmdk devuelve el value normalizado: hay que mapearlo
                        // de vuelta o el consumidor recibe algo que no existe
                        // en su lista y el filtro no cambia nada.
                        const buscado = elegido.trim().toLowerCase();
                        const real = todas.find((o) => o.valor.trim().toLowerCase() === buscado);
                        onFiltrar(real?.valor ?? elegido);
                        setAbierto(false);
                      }}
                    >
                      <Check
                        className={cn(
                          "size-4",
                          valor === opcion.valor ? "opacity-100" : "opacity-0",
                        )}
                      />
                      <span className="truncate">{opcion.etiqueta}</span>
                    </CommandItem>
                  ))}
                </CommandGroup>
              </CommandList>
            </Command>
          </PopoverContent>
        </Popover>
      </div>
    </TableHead>
  );
}
