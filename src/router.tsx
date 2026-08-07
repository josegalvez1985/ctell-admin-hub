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
    // En GitHub Pages la app vive en /ctell-admin-hub/, no en la raíz del
    // dominio. `base` de Vite sólo reescribe las URLs de los assets: sin este
    // basepath el router leería "/ctell-admin-hub/home" como ruta inexistente
    // y mostraría el 404. import.meta.env.BASE_URL es el mismo valor que
    // vite.config.ts calculó, así que en local sigue siendo "/".
    basepath: import.meta.env.BASE_URL,
  });

  return router;
};
