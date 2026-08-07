import { defineNitroConfig } from "nitro/config";

/**
 * Config de nitro para el despliegue.
 *
 * El preset `cloudflare-module` genera `.output/server/wrangler.json` en cada
 * build; fijamos el nombre del worker acá para que no dependa del nombre del
 * repositorio ni del usuario que corre el build.
 */
export default defineNitroConfig({
  preset: "cloudflare-module",
  cloudflare: {
    wrangler: {
      name: "ctell-admin-hub",
    },
  },
});
