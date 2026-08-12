/**
 * Convierte la salida del build SPA en algo servible.
 *
 * Vite deja el shell como `_shell.html`, que no es un nombre que GitHub Pages
 * busque solo. Este script lo copia a los nombres que sí se buscan:
 *
 *   index.html  el punto de entrada del sitio
 *   404.html    Pages lo devuelve ante cualquier URL que no exista como
 *               archivo, y así /home y /configuracion cargan la app en vez del
 *               404 de GitHub. El router del cliente resuelve la ruta.
 *   .nojekyll   sin esto Pages ignora los archivos que empiezan con "_", que
 *               es justamente donde viven los assets.
 *
 * Lo corre el workflow de deploy; en local sirve para reproducir el build de
 * producción tal como queda publicado.
 */
import { copyFile, writeFile, access } from "node:fs/promises";
import { join } from "node:path";

const DIR = "dist/client";
const SHELL = join(DIR, "_shell.html");

try {
  await access(SHELL);
} catch {
  console.error(`No existe ${SHELL}. ¿Corriste \`npm run build\` antes?`);
  process.exit(1);
}

await copyFile(SHELL, join(DIR, "index.html"));
await copyFile(SHELL, join(DIR, "404.html"));
await writeFile(join(DIR, ".nojekyll"), "");

console.log("Shell preparado: index.html, 404.html y .nojekyll");
