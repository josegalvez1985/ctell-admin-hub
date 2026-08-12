import { useMemo, useState } from "react";

/**
 * Búsqueda + orden client-side para un listado.
 *
 * Los listados de este proyecto son chicos (decenas o cientos de filas, no
 * miles): el backend siempre trae todo de una vez, así que no se justifica un
 * ida y vuelta al servidor por cada tecla o cada click en un header. Es el
 * mismo criterio que ya usaba la búsqueda de UsuariosDialog, generalizado para
 * que también ordene.
 *
 * `camposBusqueda` es una función y no una lista de keys porque algunas
 * columnas no salen de un campo plano — "activo" hay que traducirlo a
 * "Activo"/"Inactivo" antes de poder buscarlo por texto, y `pais` en
 * Departamentos ya viene del JOIN, pero otros casos futuros pueden necesitar
 * concatenar o formatear.
 */
export function useTablaListado<T>(
  items: T[],
  camposBusqueda: (item: T) => Array<string | number | null | undefined>,
) {
  const [busqueda, setBusqueda] = useState("");
  const [orden, setOrden] = useState<{ campo: keyof T; direccion: "asc" | "desc" } | null>(null);

  const termino = busqueda.trim().toLowerCase();

  const filtrados = useMemo(() => {
    if (termino === "") return items;
    return items.filter((item) =>
      camposBusqueda(item).some((valor) =>
        String(valor ?? "")
          .toLowerCase()
          .includes(termino),
      ),
    );
  }, [items, termino, camposBusqueda]);

  const ordenados = useMemo(() => {
    if (!orden) return filtrados;
    const { campo, direccion } = orden;
    const factor = direccion === "asc" ? 1 : -1;

    // toString() antes de comparar: cubre tanto columnas de texto como
    // numéricas (el id de País, por ejemplo) sin dos ramas de código.
    // localeCompare respeta acentos y mayúsculas como espera alguien
    // leyendo en español ("Á" ordena con "A", no después de "Z").
    return [...filtrados].sort(
      (a, b) => factor * String(a[campo] ?? "").localeCompare(String(b[campo] ?? ""), "es"),
    );
  }, [filtrados, orden]);

  function alternarOrden(campo: keyof T) {
    setOrden((actual) => {
      if (!actual || actual.campo !== campo) return { campo, direccion: "asc" };
      if (actual.direccion === "asc") return { campo, direccion: "desc" };
      return null; // Tercer click: vuelve al orden original del backend.
    });
  }

  return {
    busqueda,
    setBusqueda,
    orden,
    alternarOrden,
    resultado: ordenados,
    termino,
  };
}
