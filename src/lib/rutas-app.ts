import { routeTree } from "@/routeTree.gen";

/**
 * Rutas asignables a una página del menú, **derivadas del router**.
 *
 * Antes esto era un array escrito a mano en `PaginasDialog.tsx`, y se
 * desincronizaba con cada página nueva: la ruta existía como archivo pero no
 * aparecía en el desplegable del alta, así que la página quedaba registrada sin
 * ruta válida y su ítem de menú no navegaba a ningún lado. Pasó con
 * `/ubicaciones` y habría vuelto a pasar con cada tabla.
 *
 * Ahora sale de `routeTree.gen.ts`, que **lo regenera el build** a partir de los
 * archivos de `src/routes/`: agregar `_auth.<algo>.tsx` alcanza para que la ruta
 * aparezca sola en el alta. No hay lista que mantener.
 *
 * Se listan sólo las rutas bajo `_auth` —las páginas de la app— y se excluyen
 * las que no son navegables desde el menú (ver `EXCLUIDAS`).
 */

/**
 * Rutas que existen pero no se ofrecen en el alta de páginas.
 *
 * Hoy sólo la del login, que no es una página del menú. `/home`,
 * `/configuracion`, `/menu` y `/administracion` **sí** se ofrecen: ya estaban en
 * la lista manual que este módulo reemplaza, y sacarlas cambiaría el
 * comportamiento del ABM en vez de sólo dejar de mantenerlo a mano.
 *
 * La regla es que **todo lo que sea navegable aparezca**. Agregar algo acá es
 * volver al problema que este archivo resuelve, así que sólo va lo que
 * demostrablemente no es una página.
 */
const EXCLUIDAS = new Set<string>([]);

/** Etiqueta legible a partir del segmento de la URL: "/unidades-medida" → "Unidades medida". */
function etiquetaDesdeRuta(ruta: string): string {
  const palabras = ruta.replace(/^\//, "").split("-");
  const texto = palabras.join(" ");
  return texto.charAt(0).toUpperCase() + texto.slice(1);
}

/**
 * Nombres que no salen bien de `etiquetaDesdeRuta`.
 *
 * Sólo hacen falta cuando la ruta pierde un acento o una palabra que el usuario
 * espera ver escrita de otra forma. Una ruta que no esté acá igual aparece, con
 * su nombre derivado — lo importante es que **nunca falte**.
 */
const ETIQUETAS: Record<string, string> = {
  "/home": "Dashboard",
  "/configuracion": "Configuración",
  "/menu": "Menú",
  "/administracion": "Administración",
  "/paises": "Países",
  "/categorias": "Categorías",
  "/articulos": "Artículos",
  "/unidades-medida": "Unidades de medida",
  "/articulos-ubicaciones": "Ubicaciones de artículos",
};

export type RutaApp = { valor: string; label: string };

/**
 * Todas las rutas asignables, ordenadas alfabéticamente por su etiqueta.
 *
 * Se calcula una sola vez al cargar el módulo: el árbol de rutas es estático
 * dentro de un build.
 */
export const RUTAS_APP: RutaApp[] = (() => {
  /**
   * Nodo del árbol tal como se ve ANTES de que el router lo inicialice.
   *
   * Dos detalles que no son obvios y que hay que respetar:
   * - El id y el path viven en `options`, no en el nodo: `nodo.id` es
   *   `undefined` hasta que el router corre.
   * - `children` es un objeto indexado por posición (`{0: …, 1: …}`), no un
   *   array, así que se recorre con `Object.values`.
   */
  type Nodo = {
    options?: { id?: string; path?: string };
    children?: Record<string, Nodo>;
  };

  const raiz = routeTree as unknown as Nodo;

  // El layout `_auth` agrupa las páginas con sesión: sus hijos son las rutas
  // navegables. Se busca por su id porque el orden de los hijos de la raíz
  // (`/` y `_auth`) no está garantizado.
  const authRoute = Object.values(raiz.children ?? {}).find((r) => r.options?.id === "/_auth");

  return (
    Object.values(authRoute?.children ?? {})
      .map((r) => r.options?.path)
      .filter((ruta): ruta is string => typeof ruta === "string" && ruta !== "")
      // Normaliza la barra final que TanStack agrega en algunas rutas.
      .map((ruta) => (ruta.length > 1 && ruta.endsWith("/") ? ruta.slice(0, -1) : ruta))
      .filter((ruta) => !EXCLUIDAS.has(ruta))
      .map((ruta) => ({ valor: ruta, label: ETIQUETAS[ruta] ?? etiquetaDesdeRuta(ruta) }))
      .sort((a, b) => a.label.localeCompare(b.label, "es"))
  );
})();
