import { QueryClient } from "@tanstack/react-query";
import { createRouter } from "@tanstack/react-router";
import { routeTree } from "./routeTree.gen";

export const getRouter = () => {
  const queryClient = new QueryClient();

  const router = createRouter({
    routeTree,
    context: { queryClient },
    scrollRestoration: true,
    defaultPreloadStaleTime: 0,
    // Hoy es "/" —el sitio vive en la raíz de www.ctell.online—, pero se deja
    // atado a BASE_URL y no clavado: `base` de Vite sólo reescribe las URLs de
    // los assets, así que si el sitio volviera a servirse desde un
    // subdirectorio, sin este basepath el router leería "/<subdir>/home" como
    // ruta inexistente y mostraría el 404.
    basepath: import.meta.env.BASE_URL,
  });

  return router;
};
