/**
 * Formato y parseo de montos en es-PY, en un solo lugar.
 *
 * Antes cada pantalla transaccional traía su propia copia de estas dos
 * funciones y no todas coincidían: `punto-venta` y `cobros` parseaban formato
 * es-PY ("34.200") mientras `facturas-compras`, `inventarios` y `lotes` hacían
 * `Number()` crudo sobre el string. Mientras nadie escribiera un punto, las dos
 * versiones daban lo mismo; en cuanto el input empezó a separar miles,
 * `Number("34.200")` pasaba a devolver **34,2** y guardaba ese costo sin ningún
 * error a la vista. Por eso vive acá y no en cada archivo.
 */

/** El punto separa miles y la coma decimales, como se escribe en Paraguay. */
export const formatearMoneda = (valor: number) =>
  new Intl.NumberFormat("es-PY", { maximumFractionDigits: 2 }).format(valor);

/**
 * Texto escrito por una persona → número.
 *
 * Tolera las tres formas en que puede llegar, porque el mismo campo recibe lo
 * que tipea el cajero y lo que precarga el código:
 *
 *   "34.200"     → 34200   (formato es-PY ya separado)
 *   "34.200,50"  → 34200.5 (con decimales)
 *   "34200"      → 34200   (pegado o precargado sin formato)
 *
 * Devuelve `NaN` si no hay nada numérico: quien llama decide qué hacer con eso.
 */
export const numeroMoneda = (valor: string) => {
  const limpio = valor.trim().replace(/\s/g, "");
  if (limpio === "") return NaN;
  // Con coma, la coma es el decimal y los puntos son separadores de miles.
  if (limpio.includes(",")) return Number(limpio.replace(/\./g, "").replace(",", "."));
  // Sin coma, un punto sólo puede ser separador de miles si agrupa de a tres.
  // "1.234" es mil doscientos treinta y cuatro; "1.2" no es un monto válido.
  if (/^\d{1,3}(\.\d{3})+$/.test(limpio)) return Number(limpio.replace(/\./g, ""));
  return Number(limpio.replace(/[.,]/g, ""));
};

/** `true` si el texto representa un monto utilizable (numérico y no negativo). */
export const esMontoValido = (valor: string) => {
  const numero = numeroMoneda(valor);
  return Number.isFinite(numero) && numero >= 0;
};

/**
 * Deja sólo dígitos y **una** coma decimal, con dos decimales como techo.
 *
 * Es lo que permite escribir sin pelearse con el campo: cualquier basura que
 * entre (letras, puntos de más, una segunda coma) se descarta en el momento en
 * vez de rechazarse recién al guardar.
 */
const soloNumerico = (texto: string) => {
  const partes = texto.replace(/[^\d,]/g, "").split(",");
  const entero = partes[0] ?? "";
  if (partes.length === 1) return entero;
  // Todo lo que venga después de la primera coma es la parte decimal: si se
  // tipearon dos comas, la segunda se absorbe en vez de romper el número.
  return `${entero},${partes.slice(1).join("").slice(0, 2)}`;
};

/** Mete los puntos de miles en la parte entera, dejando la decimal intacta. */
export const separarMiles = (texto: string) => {
  const partes = soloNumerico(texto).split(",");
  const conPuntos = (partes[0] ?? "").replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  const decimal = partes[1];
  return decimal === undefined ? conPuntos : `${conPuntos},${decimal}`;
};

/**
 * Dónde cae el cursor tras reformatear.
 *
 * El truco para que el cursor no salte al final mientras se escribe: no se
 * guarda la posición en caracteres —los puntos se agregan y se corren— sino
 * **cuántos caracteres significativos** (dígitos y la coma) quedaban a la
 * izquierda. Esa cuenta no cambia al reformatear, así que alcanza para volver a
 * ubicarlo.
 */
export const posicionTrasFormatear = (formateado: string, significativos: number) => {
  if (significativos <= 0) return 0;
  let vistos = 0;
  for (let i = 0; i < formateado.length; i++) {
    if (/[\d,]/.test(formateado[i] ?? "")) {
      vistos += 1;
      if (vistos === significativos) return i + 1;
    }
  }
  return formateado.length;
};

/** Cuántos dígitos y comas hay en un texto (lo que sobrevive al formateo). */
export const contarSignificativos = (texto: string) => texto.replace(/[^\d,]/g, "").length;
