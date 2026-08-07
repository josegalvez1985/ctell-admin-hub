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
  },
});
