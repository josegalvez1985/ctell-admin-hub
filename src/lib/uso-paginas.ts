/**
 * Cuántas veces abrió el usuario cada página, para ordenar los accesos rápidos.
 *
 * VIVE EN `localStorage`, no en el backend. Es una preferencia de atajo: se
 * pierde al cambiar de navegador y no se comparte entre dispositivos, y eso está
 * bien — no justifica una tabla, un endpoint y una escritura en la base por cada
 * clic de menú. Si algún día importa que siga al usuario, se mueve.
 *
 * Todo va envuelto en try/catch porque en modo privado `localStorage` puede
 * lanzar al leer o al escribir. Ante cualquier falla los accesos rápidos caen al
 * orden del ABM, que es un peor orden pero nunca una pantalla rota.
 */

const CLAVE = "ctell-uso-paginas";

type Conteo = Record<string, number>;

function leer(): Conteo {
  try {
    const crudo = localStorage.getItem(CLAVE);
    if (!crudo) return {};
    const dato: unknown = JSON.parse(crudo);
    // Se valida la forma en vez de confiar: el valor lo puede haber dejado una
    // versión anterior con otro formato, o el usuario editándolo a mano.
    if (typeof dato !== "object" || dato === null || Array.isArray(dato)) return {};
    const limpio: Conteo = {};
    for (const [ruta, veces] of Object.entries(dato)) {
      if (typeof veces === "number" && Number.isFinite(veces)) limpio[ruta] = veces;
    }
    return limpio;
  } catch {
    return {};
  }
}

/** Suma una visita a la ruta. Se llama al hacer clic, no al renderizar. */
export function registrarUso(ruta: string): void {
  try {
    const conteo = leer();
    conteo[ruta] = (conteo[ruta] ?? 0) + 1;
    localStorage.setItem(CLAVE, JSON.stringify(conteo));
  } catch {
    // Sin storage el orden queda fijo. No es motivo para romper la navegación.
  }
}

/**
 * Ordena por uso descendente, con el orden original como desempate.
 *
 * El desempate importa más de lo que parece: al principio **todas** las páginas
 * tienen cero usos, y sin él la botonera saldría en un orden arbitrario que
 * cambia entre renders. Con él, un usuario nuevo ve el orden del ABM y la lista
 * se va reacomodando sola a medida que trabaja.
 *
 * `sort` muta el array que recibe, así que se copia antes: el llamador suele
 * pasar algo derivado de una query de TanStack.
 */
export function ordenarPorUso<T extends { ruta: string }>(paginas: readonly T[]): T[] {
  const conteo = leer();
  return [...paginas]
    .map((pagina, indice) => ({ pagina, indice, usos: conteo[pagina.ruta] ?? 0 }))
    .sort((a, b) => b.usos - a.usos || a.indice - b.indice)
    .map((fila) => fila.pagina);
}
