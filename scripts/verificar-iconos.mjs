/**
 * Verifica que no haya íconos repetidos en el menú.
 *
 * Se corre con `npm run verificar-iconos`. Falla (exit 1) si dos entradas
 * DISTINTAS comparten ícono, para que el problema aparezca antes de llegar al
 * menú y no cuando alguien lo nota en pantalla.
 *
 * QUÉ CUENTA COMO REPETICIÓN:
 *
 *   - Dos entidades distintas con el mismo ícono → ERROR.
 *   - Un ícono que también es fallback → ERROR: cualquier página nueva sin
 *     mapear se vería igual a esa entrada. Es el caso más difícil de ver a ojo,
 *     porque los dos mapas por separado parecen correctos.
 *   - Sinónimos de la MISMA entidad (singular/plural, "categorías"/"rubros") →
 *     está bien que compartan: son la misma página escrita distinto. Se declaran
 *     en SINONIMOS de abajo.
 *
 * Es un chequeo de texto sobre el archivo, no un import: el módulo trae JSX y
 * habría que compilarlo para leerlo desde Node.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const raiz = join(dirname(fileURLToPath(import.meta.url)), "..");
const ARCHIVO = join(raiz, "src/components/ctell/menu-iconos.ts");

/**
 * Grupos de claves que son la misma entidad y por eso comparten ícono a
 * propósito. Cada grupo se colapsa en un solo "dueño" antes de buscar choques.
 */
const SINONIMOS = [
  ["modulos", "modulo"],
  ["paginas", "pagina"],
  ["permisos", "permiso"],
  ["paises", "pais"],
  ["departamentos", "departamento", "provincias"],
  ["ciudades", "ciudad"],
  ["barrios", "barrio"],
  ["empresas", "empresa"],
  ["sucursales", "sucursal"],
  ["personas", "persona"],
  ["articulos", "productos"],
  ["monedas", "moneda"],
  ["unidades de medida", "unidad de medida", "unidades"],
  ["categorias", "categoria", "rubros"],
  ["deposito", "depositos"],
  ["lotes", "lote"],
  ["ubicaciones", "ubicacion"],
  [
    "ubicaciones de articulos",
    "ubicacion de articulos",
    "articulos ubicaciones",
    "articulos por ubicacion",
  ],
  ["inventarios", "inventario"],
  ["ordenes", "ordenes de compra"],
  ["facturas de compra", "facturas compras"],
  ["iva", "tasas de iva"],
  ["condiciones de pago", "condicion de pago", "condiciones"],
  ["talonarios", "talonario"],
  ["canales de pago", "canal de pago", "canales pagos"],
  ["rrhh", "recursos humanos"],
  // La tabla se llamó LISTAS_PRECIOS y se renombró a LISTAS_DESCUENTOS: las
  // variantes de los dos nombres se mapean al mismo ícono porque el ítem del
  // menú puede haber quedado cargado con el nombre viejo.
  [
    "listas de descuentos",
    "lista de descuentos",
    "listas descuentos",
    "descuentos",
    "listas de precios",
    "lista de precios",
    "listas precios",
    "listas",
    "precios",
  ],
  ["instituciones", "institucion"],
  ["profesores", "profesor", "docentes", "docente"],
];

/** Clave → representante del grupo. */
const duenio = new Map();
for (const grupo of SINONIMOS) {
  for (const clave of grupo) duenio.set(clave, grupo[0]);
}

const fuente = readFileSync(ARCHIVO, "utf8");

/** Extrae los pares `clave: Icono` de un objeto del archivo. */
function leerMapa(nombre, etiqueta) {
  const bloque = fuente.match(new RegExp(`const ${nombre}[^=]*= \\{([\\s\\S]*?)\\n\\};`));
  if (!bloque) throw new Error(`No se encontró ${nombre} en menu-iconos.ts`);

  const entradas = [];
  for (const linea of bloque[1].split("\n")) {
    // Las líneas de comentario se saltean: pueden mencionar nombres de íconos.
    if (linea.trim().startsWith("//")) continue;
    const m = linea.match(/^\s+"?([^":]+)"?:\s*([A-Z][A-Za-z0-9]*)\s*,/);
    if (m) entradas.push({ clave: m[1].trim(), icono: m[2], etiqueta });
  }
  return entradas;
}

const entradas = [
  ...leerMapa("ICONOS_MODULO", "módulo"),
  ...leerMapa("ICONOS_PAGINA", "página"),
  ...leerMapa("ICONOS_ENTRADA", "entrada"),
];

// Los fallbacks entran como una entrada más: si un ícono es fallback Y está
// mapeado, cualquier entrada sin mapear se vería igual que la mapeada.
for (const m of fuente.matchAll(/\?\?\s*([A-Z][A-Za-z0-9]*);/g)) {
  entradas.push({ clave: `(fallback)`, icono: m[1], etiqueta: "fallback" });
}

/** icono → conjunto de entidades distintas que lo usan. */
const porIcono = new Map();
for (const { clave, icono, etiqueta } of entradas) {
  const entidad = `${etiqueta}:${duenio.get(clave) ?? clave}`;
  if (!porIcono.has(icono)) porIcono.set(icono, new Set());
  porIcono.get(icono).add(entidad);
}

const choques = [...porIcono.entries()]
  .filter(([, entidades]) => entidades.size > 1)
  .map(([icono, entidades]) => `  ${icono}: ${[...entidades].join(", ")}`);

if (choques.length > 0) {
  console.error("Íconos repetidos en el menú:\n");
  console.error(choques.join("\n"));
  console.error(
    "\nCada página, módulo y entrada necesita un ícono propio, distinto también" +
      "\nde los fallbacks. Si dos claves son la MISMA entidad escrita de otra" +
      "\nforma, agregalas a SINONIMOS en este script.",
  );
  process.exit(1);
}

console.log(`Íconos del menú: sin repeticiones (${entradas.length} entradas).`);
