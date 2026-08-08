// El preset de configuración ya incluye TanStack devtools, tanstackStart, viteReact,
// tailwindcss, tsConfigPaths, nitro, inyección de env VITE_*, el alias @ y el dedupe de
// React/TanStack — no los agregues manualmente o la app romperá por plugins duplicados.
// Config adicional vía defineConfig({ vite: { ... } }).
import { defineConfig } from "@lovable.dev/vite-tanstack-config";

// GitHub Pages sirve el sitio bajo /<repo>/, no bajo la raíz del dominio. El
// workflow define GITHUB_PAGES=true; en local queda "/" para que `npm run dev`
// siga funcionando sin prefijo.
const enPages = process.env["GITHUB_PAGES"] === "true";

export default defineConfig({
  // Pages sólo sirve archivos estáticos: no puede ejecutar el servidor SSR que
  // genera nitro. El build pasa a SPA (`.output/public/_shell.html`) y el
  // ruteo lo resuelve el cliente. El backend es ORDS, así que no se pierde
  // nada: el SSR no aportaba datos, sólo el primer render.
  nitro: false,
  tanstackStart: {
    // Redirect TanStack Start's bundled server entry to src/server.ts (our SSR error wrapper).
    server: { entry: "server" },
    spa: { enabled: true },
  },
  vite: {
    base: enPages ? "/ctell-admin-hub/" : "/",

    server: {
      // El navegador bloquea las llamadas del frontend a oracleapex.com por
      // ser de otro origen, y ORDS no envía Access-Control-Allow-Origin. En
      // desarrollo se evita con un proxy: la app pide a /ords/... (mismo
      // origen que la página, así que no hay chequeo de CORS) y es Vite quien
      // reenvía la petición a APEX. Servidor contra servidor no aplica la
      // política de mismo origen, que es cosa del navegador.
      //
      // Esto solo corre con `npm run dev`. El build de producción no lleva
      // proxy: ahí la app pega directo a oracleapex.com — ver BASE_URL en
      // src/lib/api.ts.
      proxy: {
        "/ords": {
          target: "https://oracleapex.com",
          changeOrigin: true,
          secure: true,
        },
      },
    },
  },
});
