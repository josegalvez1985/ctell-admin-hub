import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";

import { InstalarPwaDialog } from "@/components/ctell/InstalarPwaDialog";
import { useCerrarSesionAlVencer } from "@/hooks/use-cerrar-sesion-al-vencer";
import { getToken } from "@/lib/api";

/**
 * Layout de las páginas que exigen sesión.
 *
 * El guion bajo lo marca como ruta "pathless": no agrega nada a la URL, sólo
 * envuelve a sus hijas. `_auth.home.tsx` sigue siendo `/home`.
 *
 * Antes de esto ninguna página verificaba el token. Entrar a /home sin sesión
 * —un marcador, un F5, una pestaña nueva— cargaba el panel igual: `/auth/me`
 * devolvía 401, `api.ts` limpiaba el token, y nadie miraba ese error. El
 * saludo quedaba con el skeleton girando indefinidamente sobre un panel de
 * KPIs que se veían porque son datos de ejemplo. No había redirección al login
 * porque no existía ninguna.
 */
export const Route = createFileRoute("/_auth")({
  beforeLoad: () => {
    // En el servidor no hay sessionStorage y getToken() devuelve null siempre.
    // Sin esta guarda, el SSR redirigiría al login a todo el mundo, incluso con
    // la sesión abierta. La verificación real corre en el cliente, que es donde
    // el token existe.
    if (typeof window === "undefined") return;

    if (getToken() === null) {
      throw redirect({ to: "/" });
    }
  },
  component: LayoutProtegido,
});

function LayoutProtegido() {
  // Un 401 en cualquier petición de las páginas de adentro devuelve al login.
  useCerrarSesionAlVencer();

  return (
    <>
      <Outlet />
      {/* Acá y no en __root: instalar se le sugiere a quien ya inició sesión,
          no a quien está parado en el login. Se descarta solo en escritorio. */}
      <InstalarPwaDialog />
    </>
  );
}
