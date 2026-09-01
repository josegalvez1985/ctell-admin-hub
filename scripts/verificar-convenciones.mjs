/**
 * Chequeos de convenciones que ya nos costaron horas.
 *
 * Se corre con `npm run verificar-convenciones`, y `npm run lint` lo incluye.
 * Falla (exit 1) para que el problema aparezca ANTES de ejecutar nada en APEX
 * o de abrir la pantalla en el navegador.
 *
 * QUÉ BUSCA Y POR QUÉ CADA UNO ESTÁ ACÁ:
 *
 *   1. `:body` con JSON_VALUE — el bind trae el payload CRUDO como BLOB, así
 *      que JSON_VALUE devuelve NULL en todos los campos y el endpoint responde
 *      400 "son obligatorios" con el body perfectamente puesto. El listado y el
 *      DELETE siguen andando porque no tocan el body: el síntoma es "el delete
 *      funciona, el update no".
 *
 *   2. Hijos de `ui/form` fuera de un `<FormItem>` — `useFormField()` LANZA sin
 *      su contexto, y eso tira abajo la página entera con "This page didn't
 *      load". No es un warning: es un crash.
 *
 * Son chequeos de TEXTO, no un parser: prefieren un falso positivo raro a
 * dejar pasar el caso real. Si alguno molesta, la salida dice qué línea es.
 *
 * LO QUE A PROPÓSITO NO SE CHEQUEA ACÁ: el `JSON_OBJECT` anidado dentro de un
 * `JSON_ARRAYAGG`. Rompe sólo cuando el resultado pasa los 4000 bytes, así que
 * depende del VOLUMEN y no del texto: una docena de listados chicos lo usan y
 * funcionan hace meses. Un chequeo que falla siempre no lo corre nadie. Está
 * explicado en docs/GUIA-IMPLEMENTACION.md, sección 3.7.
 */
import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const raiz = join(dirname(fileURLToPath(import.meta.url)), "..");

/**
 * Archivos versionados que matcheen el patrón, con rutas relativas a la raíz.
 *
 * El patrón va SIN comillas: en Windows execSync usa cmd.exe, que no las saca,
 * y git las recibe literales, no matchea nada y devuelve cero archivos. Un
 * chequeo que no lee nada pasa siempre — es peor que no tenerlo, y por eso
 * exigirArchivos() aborta cuando un patrón no matchea.
 */
function archivos(patron) {
  return execSync(`git ls-files ${patron}`, { cwd: raiz, encoding: "utf8" })
    .split("\n")
    .filter(Boolean);
}

/**
 * Si un patrón deja de matchear —un glob mal citado, un directorio movido— el
 * chequeo pasaría en silencio. Falla ruidoso en vez de dar un OK vacío.
 */
function exigirArchivos(patron) {
  const lista = archivos(patron);
  if (lista.length === 0) {
    console.error(`✗ El patrón "${patron}" no matcheó ningún archivo: el chequeo no se corrió.`);
    process.exit(1);
  }
  return lista;
}

const problemas = [];

function reportar(archivo, linea, texto, explicacion) {
  problemas.push({ archivo, linea, texto: texto.trim().slice(0, 90), explicacion });
}

/* -------------------------------------------------------------------------- */
/* 1. `:body` usado para leer un JSON                                          */
/* -------------------------------------------------------------------------- */

/**
 * `:body` es legítimo para subir archivos (imágenes, logos): ahí SÍ se quiere
 * el BLOB crudo. Lo que nunca es correcto es leerle campos con JSON_VALUE.
 *
 * Se detecta por el par: un handler que pasa `:body` a un procedimiento cuyo
 * cuerpo usa JSON_VALUE. Basta con que el archivo tenga las dos cosas, porque
 * un archivo de `db/` es una tabla con todos sus endpoints.
 */
for (const archivo of exigirArchivos("db/*.sql")) {
  const contenido = readFileSync(join(raiz, archivo), "utf8");
  const lineas = contenido.split("\n");

  // Sólo el `:body` de un p_source; el de un comentario no cuenta.
  const usaBody = lineas.some((l) => /p_source\s*=>.*:body\b/.test(l));
  const usaJsonValue = /JSON_VALUE\s*\(\s*p_body/i.test(contenido);

  if (usaBody && usaJsonValue) {
    lineas.forEach((l, i) => {
      if (/p_source\s*=>.*:body\b/.test(l)) {
        reportar(
          archivo,
          i + 1,
          l,
          "`:body` trae el payload CRUDO (BLOB): JSON_VALUE sobre él devuelve NULL.\n" +
            "     Para un JSON, ORDS ya crea un bind por cada clave: pasá :idEmpresa, :fecha,\n" +
            "     etc. como VARCHAR2 sueltos, igual que db/categorias.sql.",
        );
      }
    });
  }
}

/* -------------------------------------------------------------------------- */
/* 2. Hijos de ui/form fuera de un <FormItem>                                 */
/* -------------------------------------------------------------------------- */

/** Los cuatro que llaman a useFormField() y lanzan sin su contexto. */
const HIJOS_FORM = /<(FormDescription|FormLabel|FormControl|FormMessage)\b/;

/**
 * Reemplaza los comentarios por espacios, conservando los saltos de línea.
 *
 * Sin esto, un comentario que NOMBRA a FormDescription para explicar por qué no
 * se usa queda reportado como si fuera el error. Los números de línea se
 * mantienen porque sólo se blanquean los caracteres.
 */
function sinComentarios(texto) {
  return texto.replace(/\{?\/\*[\s\S]*?\*\/\}?|\/\/[^\n]*/g, (m) => m.replace(/[^\n]/g, " "));
}

/**
 * Componentes del propio archivo que renderizan un `<FormItem>` y reciben
 * children: un `<Field>` propio, por ejemplo.
 *
 * Sus hijos SÍ tienen el contexto —React lo propaga por el árbol de render, no
 * por cómo esté escrito el JSX— así que cuentan como apertura igual que un
 * `<FormItem>` literal. Sin esto, cada wrapper propio da un falso positivo.
 */
function wrappersDe(texto) {
  const nombres = new Set();
  for (const definicion of texto.split(/\nfunction\s+/).slice(1)) {
    const nombre = definicion.match(/^(\w+)/)?.[1];
    if (nombre && /<FormItem[\s>]/.test(definicion)) nombres.add(nombre);
  }
  return [...nombres];
}

for (const archivo of exigirArchivos("src/**/*.tsx")) {
  // El propio ui/form.tsx los define; no tiene sentido chequearlo.
  if (archivo.endsWith("src/components/ui/form.tsx")) continue;

  const crudo = readFileSync(join(raiz, archivo), "utf8");
  const lineas = sinComentarios(crudo).split("\n");

  const aperturas = ["FormItem", ...wrappersDe(crudo)];
  const abre = new RegExp(`<(${aperturas.join("|")})[\\s>]`, "g");
  const cierra = new RegExp(`</(${aperturas.join("|")})>`, "g");

  let profundidad = 0;

  lineas.forEach((linea, i) => {
    if (HIJOS_FORM.test(linea) && profundidad === 0) {
      reportar(
        archivo,
        i + 1,
        linea,
        "Fuera de un <FormItem>: useFormField() LANZA y se lleva puesta la página\n" +
          "     entera. Si la nota es del formulario y no de un campo, usá un <p\n" +
          '     className="text-[0.8rem] text-muted-foreground">.',
      );
    }
    // Se cuenta DESPUÉS de evaluar: la apertura y su hijo pueden compartir línea.
    profundidad += (linea.match(abre) ?? []).length;
    profundidad -= (linea.match(cierra) ?? []).length;
  });
}

/* -------------------------------------------------------------------------- */

if (problemas.length === 0) {
  console.log("✓ Convenciones: sin problemas.");
  process.exit(0);
}

console.error(`\n✗ ${problemas.length} problema(s) de convención:\n`);
for (const p of problemas) {
  console.error(`  ${p.archivo}:${p.linea}`);
  console.error(`     ${p.texto}`);
  console.error(`     ${p.explicacion}\n`);
}
process.exit(1);
