import { ArrowDown, ArrowUp, ArrowUpDown } from "lucide-react";

import { TableHead } from "@/components/ui/table";
import { cn } from "@/lib/utils";

/**
 * Header de tabla clicable para ordenar. El ícono cambia según el estado:
 * flechita doble gris cuando la columna no ordena, arriba/abajo cuando sí.
 *
 * Recibe la dirección ya resuelta (no el campo) para no acoplarse al tipo de
 * `useTablaListado` — cualquier pantalla que arme su propio estado de orden
 * puede usarlo igual.
 */
export function TableHeadOrdenable({
  children,
  direccion,
  onClick,
  className,
}: {
  children: React.ReactNode;
  direccion: "asc" | "desc" | null;
  onClick: () => void;
  className?: string;
}) {
  const Icono = direccion === "asc" ? ArrowUp : direccion === "desc" ? ArrowDown : ArrowUpDown;

  return (
    <TableHead className={className}>
      <button
        type="button"
        onClick={onClick}
        className={cn(
          "flex items-center gap-1 text-left font-medium text-muted-foreground hover:text-foreground",
          direccion && "text-foreground",
        )}
      >
        {children}
        <Icono className="size-3.5 shrink-0" />
      </button>
    </TableHead>
  );
}
