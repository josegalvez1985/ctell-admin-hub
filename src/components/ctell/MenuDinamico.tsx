import { useRouter } from "@tanstack/react-router";
import { ChevronDown } from "lucide-react";
import { useState } from "react";
import { iconoDeEntrada, iconoDeModulo, iconoDePagina } from "@/components/ctell/menu-iconos";
import { useMenuUsuario, type MenuModulo } from "@/hooks/use-menu-usuario";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";

export function MenuDinamico({
  active,
  variant = "light",
}: {
  active?: string | undefined;
  /** "dark" para el sidebar con fondo oscuro; "light" para paneles claros (menú móvil). */
  variant?: "light" | "dark";
}) {
  const { modulos, isPending, isError } = useMenuUsuario();

  // El módulo del item activo arranca desplegado: si active vive adentro,
  // colapsado por defecto lo escondería justo cuando más hace falta verlo.
  const [abiertos, setAbiertos] = useState<Set<number>>(() => {
    const conActivo = modulos.find((m) =>
      Object.values(m.entradas).some((paginas) => paginas.some((p) => p.ruta === active)),
    );
    return new Set(conActivo ? [conActivo.id] : []);
  });

  function toggle(idModulo: number) {
    setAbiertos((prev) => {
      const next = new Set(prev);
      if (next.has(idModulo)) {
        next.delete(idModulo);
      } else {
        next.add(idModulo);
      }
      return next;
    });
  }

  if (isPending) {
    return (
      <div className="space-y-3">
        {[0, 1, 2].map((i) => (
          <Skeleton key={i} className="h-12 w-full" />
        ))}
      </div>
    );
  }

  if (isError || modulos.length === 0) {
    return (
      <p className="rounded-lg border border-border bg-muted px-4 py-3 text-center text-sm text-muted-foreground">
        Sin acceso a páginas
      </p>
    );
  }

  return (
    <div className="space-y-1">
      {modulos.map((modulo) => (
        <ModuloAccordion
          key={modulo.id}
          modulo={modulo}
          active={active}
          abierto={abiertos.has(modulo.id)}
          onToggle={() => toggle(modulo.id)}
          variant={variant}
        />
      ))}
    </div>
  );
}

/**
 * Normaliza la ruta que viene de la base antes de navegar.
 *
 * El dato lo carga una persona desde el ABM de páginas, así que puede llegar
 * con espacios o sin la barra inicial. `navigate` no perdona ninguna de las
 * dos: un `to` que no matchea el árbol de rutas no navega ni avisa.
 */
function normalizarRuta(ruta: string): string {
  const limpia = ruta.trim();
  if (!limpia || limpia === "#") return "";
  return limpia.startsWith("/") ? limpia : `/${limpia}`;
}

function ModuloAccordion({
  modulo,
  active,
  abierto,
  onToggle,
  variant,
}: {
  modulo: MenuModulo;
  active?: string | undefined;
  abierto: boolean;
  onToggle: () => void;
  variant: "light" | "dark";
}) {
  const esDark = variant === "dark";
  const router = useRouter();
  const IconoModulo = iconoDeModulo(modulo.nombre, modulo.icono);

  return (
    <div>
      <button
        type="button"
        onClick={onToggle}
        aria-expanded={abierto}
        className={cn(
          "flex w-full items-center gap-2 rounded-md px-2 py-2 text-xs font-semibold uppercase tracking-wider transition-colors",
          esDark
            ? "text-sidebar-foreground/70 hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
            : "text-muted-foreground hover:text-foreground",
        )}
      >
        <IconoModulo className="size-4 shrink-0" />
        <span className="flex-1 text-left">{modulo.nombre}</span>
        <ChevronDown
          className={cn(
            "size-4 shrink-0 transition-transform duration-200",
            abierto && "rotate-180",
          )}
        />
      </button>

      <div
        className={cn(
          "grid overflow-hidden transition-[grid-template-rows] duration-200 ease-in-out",
          abierto ? "grid-rows-[1fr]" : "grid-rows-[0fr]",
        )}
      >
        <div className="min-h-0">
          <div className="space-y-1 pb-2">
            {Object.entries(modulo.entradas).map(([entrada, paginas]) => {
              const entradaLabel =
                entrada === "D" ? "Definiciones" : entrada === "R" ? "Reportes" : "Operaciones";
              const IconoEntrada = iconoDeEntrada(entrada);

              return (
                <div key={entrada}>
                  <p
                    className={cn(
                      "mb-1.5 flex items-center gap-1.5 pl-2 text-xs font-medium",
                      esDark ? "text-sidebar-foreground/50" : "text-muted-foreground/70",
                    )}
                  >
                    <IconoEntrada className="size-3.5 shrink-0" />
                    {entradaLabel}
                  </p>

                  <ul className="space-y-0.5">
                    {paginas.map((pagina) => {
                      const destino = normalizarRuta(pagina.ruta);
                      const isActive = active === pagina.nombre || active === destino;
                      const IconoPagina = iconoDePagina(pagina.nombre);

                      return (
                        <li key={pagina.id}>
                          {/* <a> con navegación imperativa en vez de <Link>: `to`
                              exige un literal del árbol de rutas, y esta ruta
                              sale de la base como string cualquiera. */}
                          <a
                            href={destino || "#"}
                            onClick={(e) => {
                              e.preventDefault();
                              if (destino) router.navigate({ to: destino });
                            }}
                            className={cn(
                              "flex cursor-pointer items-center gap-2 rounded-md px-3 py-2 text-sm font-medium transition-colors",
                              isActive
                                ? esDark
                                  ? "bg-sidebar-primary text-sidebar-primary-foreground"
                                  : "bg-primary text-primary-foreground"
                                : esDark
                                  ? "text-sidebar-foreground/70 hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
                                  : "text-muted-foreground hover:bg-accent hover:text-foreground",
                            )}
                          >
                            <IconoPagina className="size-4 shrink-0" />
                            {pagina.nombre}
                          </a>
                        </li>
                      );
                    })}
                  </ul>
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}
