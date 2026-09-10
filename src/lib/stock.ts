import type { QueryClient } from "@tanstack/react-query";

/**
 * Las `queryKey` de todo lo que muestra una cantidad de stock.
 *
 * Están juntas acá y no repetidas en cada pantalla porque **son cuatro y se
 * olvida una**. El síntoma de olvidarla no es un error: es una pantalla que
 * sigue diciendo 12 disponibles después de vender los 12, y nadie la relaciona
 * con la venta que la dejó vieja.
 *
 * - `articulos` — el catálogo, con `cantidadStock` por fila.
 * - `pos-articulos` — la grilla de la caja. Es la más urgente: sin invalidarla,
 *   la venta siguiente se decide contra el stock de antes.
 * - `existencias` — la consulta abierta por sucursal.
 * - `dashboard` — unidades en depósito, artículos bajo mínimo y stock crítico.
 */
const CLAVES_STOCK = ["articulos", "pos-articulos", "existencias", "dashboard"] as const;

/**
 * Invalida todo lo que muestra stock. Se llama después de **cualquier**
 * operación que lo mueva: vender, comprar, borrar una de las dos, o cerrar un
 * conteo físico.
 *
 * No espera a que terminen las consultas —`invalidateQueries` no se aguarda— y
 * eso es deliberado: el toast de "venta registrada" no tiene por qué demorarse
 * hasta que se refresquen cuatro listados, de los cuales el usuario está
 * mirando uno.
 */
export function invalidarStock(queryClient: QueryClient) {
  for (const clave of CLAVES_STOCK) {
    queryClient.invalidateQueries({ queryKey: [clave] });
  }
}
