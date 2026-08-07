// El preset de configuración ya incluye TanStack devtools, tanstackStart, viteReact,
// tailwindcss, tsConfigPaths, nitro, inyección de env VITE_*, el alias @ y el dedupe de
// React/TanStack — no los agregues manualmente o la app romperá por plugins duplicados.
// Config adicional vía defineConfig({ vite: { ... } }).
import { defineConfig } from "@lovable.dev/vite-tanstack-config";

export default defineConfig({
  tanstackStart: {
    // Redirect TanStack Start's bundled server entry to src/server.ts (our SSR error wrapper).
    // nitro/vite builds from this
    server: { entry: "server" },
  },
});
