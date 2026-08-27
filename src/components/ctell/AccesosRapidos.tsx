import { Link } from "@tanstack/react-router";

import { iconoDePagina } from "@/components/ctell/menu-iconos";
import { Skeleton } from "@/components/ui/skeleton";
import { useMenuUsuario, type MenuPagina } from "@/hooks/use-menu-usuario";
import { registrarUso, ordenarPorUso } from "@/lib/uso-paginas";

/**
 * Las páginas del usuario como botonera, ordenadas por lo que más usa.
 *
 * Reemplaza al `MenuDinamico` completo que estaba acá: un acordeón de módulos
 * en la home obligaba a dos clics —abrir el módulo, después la página— para
 * llegar a lo mismo que el sidebar ya ofrece. Como botonera se llega en uno.
 *
 * EL ORDEN LO DECIDE EL USO, no el `orden` del ABM. Quien factura todo el día
 * abre Punto de venta cincuenta veces y Departamentos nunca; que las dos estén
 * a la misma distancia es tratar por igual dos cosas que no lo son. El conteo
 * vive en `localStorage` y por lo tanto es **por navegador**: no viaja al
 * backend ni se comparte entre dispositivos, que para una preferencia de
 * atajo alcanza y evita una tabla más.
 */
export function AccesosRapidos() {
  const { modulos, isPending, isError } = useMenuUsuario();

  if (isPending) {
    return (
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
        {[0, 1, 2, 3, 4, 5].map((i) => (
          <Skeleton key={i} className="h-16" />
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

  // El menú viene agrupado por módulo y entrada; acá se aplana porque la
  // botonera no muestra esa jerarquía — sólo destinos.
  const paginas: MenuPagina[] = modulos.flatMap((modulo) => Object.values(modulo.entradas).flat());

  return (
    // TODAS las páginas, no un recorte: el orden por uso ya pone adelante lo que
    // importa, y cortar la lista escondería justamente las que todavía no se
    // usaron —que son las que cuesta encontrar—. El alto fijo con scroll es lo
    // que evita que la botonera empuje los KPIs fuera de la pantalla.
    <div className="scrollbar-fino max-h-64 overflow-y-auto pr-1">
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
        {ordenarPorUso(paginas).map((pagina) => {
          const Icono = iconoDePagina(pagina.nombre);
          return (
            <Link
              key={pagina.id}
              to={pagina.ruta}
              onClick={() => registrarUso(pagina.ruta)}
              className="surface-card flex items-center gap-3 p-3 transition-colors hover:bg-accent hover:text-accent-foreground"
            >
              <span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">
                <Icono className="size-4" />
              </span>
              <span className="min-w-0 truncate text-sm font-medium">{pagina.nombre}</span>
            </Link>
          );
        })}
      </div>
    </div>
  );
}
