import { useRouter } from "@tanstack/react-router";
import { ChevronDown } from "lucide-react";
import { useSyncExternalStore } from "react";
import { iconoDeEntrada, iconoDeModulo, iconoDePagina } from "@/components/ctell/menu-iconos";
import { useMenuUsuario, type MenuModulo } from "@/hooks/use-menu-usuario";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";

/**
 * Qué está desplegado en el menú, fuera de React.
 *
 * `AppLayout` lo monta cada página, así que al navegar el componente se
 * desmonta y se vuelve a montar: un `useState` volvería al valor inicial y
 * cerraría todo lo que el usuario había abierto, justo al hacer click en una
 * página. El estado tiene que vivir más que el componente.
 *
 * Se respalda en sessionStorage para que tampoco se pierda al recargar. Muere
 * al cerrar la pestaña, igual que el token: es preferencia de navegación de
 * esta sesión, no algo que valga la pena recordar para siempre.
 */
const CLAVE_ABIERTOS = "ctell-menu-abiertos";

/**
 * Snapshot cacheado. `useSyncExternalStore` compara por identidad, así que hay
 * que devolver siempre el MISMO objeto mientras nada cambie: reconstruir el
 * Set en cada lectura daría una referencia nueva cada vez y React entraría en
 * un bucle de renders.
 */
let abiertosActuales: ReadonlySet<string> = leerDeStorage();

function leerDeStorage(): ReadonlySet<string> {
  if (typeof window === "undefined") return new Set();
  try {
    const crudo = sessionStorage.getItem(CLAVE_ABIERTOS);
    return new Set(crudo ? (JSON.parse(crudo) as string[]) : []);
  } catch {
    return new Set();
  }
}

const oyentes = new Set<() => void>();

function suscribir(oyente: () => void): () => void {
  oyentes.add(oyente);
  return () => oyentes.delete(oyente);
}

/** Despliega o pliega una clave (`m:<id>` para módulo, `e:<id>:<entrada>`). */
function alternarClave(clave: string) {
  const next = new Set(abiertosActuales);
  if (next.has(clave)) {
    next.delete(clave);
  } else {
    next.add(clave);
  }
  abiertosActuales = next;

  try {
    sessionStorage.setItem(CLAVE_ABIERTOS, JSON.stringify([...next]));
  } catch {
    // Modo privado o storage lleno: el menú sigue andando, sólo se olvida.
  }

  for (const oyente of oyentes) oyente();
}

/**
 * Lo desplegado, compartido por todas las instancias del menú.
 *
 * En el prerender de build no hay `window`; el server snapshot es un Set vacío
 * constante (no una llamada que cree uno nuevo cada vez).
 */
const VACIO: ReadonlySet<string> = new Set();

function useAbiertos(): ReadonlySet<string> {
  return useSyncExternalStore(
    suscribir,
    () => abiertosActuales,
    () => VACIO,
  );
}

export function MenuDinamico({
  active,
  variant = "light",
}: {
  active?: string | undefined;
  /** "dark" para el sidebar con fondo oscuro; "light" para paneles claros (menú móvil). */
  variant?: "light" | "dark";
}) {
  const { modulos, isPending, isError } = useMenuUsuario();

  // Todo arranca cerrado y lo que el usuario despliega queda desplegado: el
  // estado vive fuera de React, así que navegar (que remonta este componente)
  // no lo pierde.
  const abiertos = useAbiertos();

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
          abiertos={abiertos}
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
  abiertos,
  variant,
}: {
  modulo: MenuModulo;
  active?: string | undefined;
  abiertos: ReadonlySet<string>;
  variant: "light" | "dark";
}) {
  const esDark = variant === "dark";
  const router = useRouter();
  const IconoModulo = iconoDeModulo(modulo.nombre, modulo.icono);
  const abierto = abiertos.has(`m:${modulo.id}`);

  return (
    <div>
      <button
        type="button"
        onClick={() => alternarClave(`m:${modulo.id}`)}
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
          {/* pl-3 + borde: la sangría marca que todo esto cuelga del módulo,
              y la línea vertical la hace visible aunque el bloque sea largo. */}
          <div
            className={cn(
              "ml-4 space-y-1 border-l pb-2 pl-1",
              esDark ? "border-sidebar-foreground/15" : "border-border",
            )}
          >
            {Object.entries(modulo.entradas).map(([entrada, paginas]) => (
              <EntradaAccordion
                key={entrada}
                clave={`e:${modulo.id}:${entrada}`}
                entrada={entrada}
                paginas={paginas}
                active={active}
                desplegada={abiertos.has(`e:${modulo.id}:${entrada}`)}
                esDark={esDark}
                router={router}
              />
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

/**
 * Segundo nivel del menú: Definiciones / Operaciones / Reportes.
 *
 * Es desplegable igual que el módulo. Antes era un rótulo fijo, y con varias
 * entradas por módulo la lista de páginas crecía sin forma de plegarla.
 *
 * Arranca abierta: colapsar todo por defecto obligaría a dos clicks para
 * llegar a cualquier página, cuando el módulo ya se abrió a propósito.
 */
function EntradaAccordion({
  clave,
  entrada,
  paginas,
  active,
  desplegada,
  esDark,
  router,
}: {
  clave: string;
  entrada: string;
  paginas: MenuModulo["entradas"][string];
  active?: string | undefined;
  desplegada: boolean;
  esDark: boolean;
  router: ReturnType<typeof useRouter>;
}) {
  const entradaLabel =
    entrada === "D" ? "Definiciones" : entrada === "R" ? "Reportes" : "Operaciones";
  const IconoEntrada = iconoDeEntrada(entrada);

  return (
    <div>
      <button
        type="button"
        onClick={() => alternarClave(clave)}
        aria-expanded={desplegada}
        className={cn(
          "mb-1.5 flex w-full items-center gap-1.5 rounded-md px-2 py-1.5 text-xs font-medium transition-colors",
          esDark
            ? "text-sidebar-foreground/50 hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
            : "text-muted-foreground/70 hover:text-foreground",
        )}
      >
        <IconoEntrada className="size-3.5 shrink-0" />
        <span className="flex-1 text-left">{entradaLabel}</span>
        <ChevronDown
          className={cn(
            "size-3.5 shrink-0 transition-transform duration-200",
            desplegada && "rotate-180",
          )}
        />
      </button>

      <div
        className={cn(
          "grid overflow-hidden transition-[grid-template-rows] duration-200 ease-in-out",
          desplegada ? "grid-rows-[1fr]" : "grid-rows-[0fr]",
        )}
      >
        <div className="min-h-0">
          {/* Tercer nivel: una sangría más que la entrada que lo contiene. */}
          <ul className="space-y-0.5 pl-3">
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
      </div>
    </div>
  );
}
