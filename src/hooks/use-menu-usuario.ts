import { useQuery } from "@tanstack/react-query";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { api, type UsuarioPagina } from "@/lib/api";
import { useUsuarioActual } from "./use-usuario-actual";

export type MenuModulo = {
  id: number;
  nombre: string;
  /** Nombre del ícono cargado en el ABM de módulos; null si no se cargó. */
  icono: string | null;
  orden: number;
  entradas: Record<string, MenuPagina[]>;
};

export type MenuPagina = {
  id: number;
  nombre: string;
  ruta: string;
  entrada: "D" | "O" | "R";
  orden: number;
};

const ENTRADA_LABELS: Record<string, string> = {
  D: "Definiciones",
  O: "Operaciones",
  R: "Reportes",
};

const ENTRADA_ORDER: Record<string, number> = {
  D: 1,
  O: 2,
  R: 3,
};

export function useMenuUsuario() {
  const { data: usuario } = useUsuarioActual();
  const { empresa } = useEmpresa();

  const { data, isPending, isError, error } = useQuery({
    queryKey: ["menu-usuario", usuario?.id],
    queryFn: () => (usuario?.id ? api.usuarioPaginas.listar({ idUsuario: usuario.id }) : null),
    enabled: !!usuario?.id,
  });

  /**
   * Permisos que aplican a la empresa activa.
   *
   * El endpoint devuelve TODOS los permisos del usuario, de todas las empresas;
   * el recorte se hace acá para no repetir la consulta al cambiar de empresa.
   *
   * Un permiso vale en esta empresa si su `idEmpresa` coincide. Los que tienen
   * `idEmpresa` en null NO se muestran: son de antes de que existiera la
   * columna, y tratarlos como "válidos en todas" haría que el menú siguiera
   * mostrando páginas que nadie habilitó para esta empresa — justo lo contrario
   * de lo que el filtro busca. Para recuperarlos hay que reasignarlos desde el
   * ABM de permisos, que ahora registra la empresa.
   *
   * Sin empresa activa no se muestra nada: no hay contra qué comparar, y un
   * menú completo sería más engañoso que uno vacío.
   */
  const permisos = (data?.items ?? []).filter(
    (p) => empresa !== null && p.idEmpresa === empresa.id,
  );

  // Agrupar páginas por módulo y luego por entrada
  const modulos: MenuModulo[] = [];

  if (permisos.length > 0) {
    const modulosMap = new Map<number, MenuModulo>();

    for (const permiso of permisos) {
      if (!modulosMap.has(permiso.idModulo)) {
        modulosMap.set(permiso.idModulo, {
          id: permiso.idModulo,
          nombre: permiso.modulo,
          icono: permiso.moduloIcono ?? null,
          orden: 0, // Se actualiza si hay otra página del mismo módulo
          entradas: {},
        });
      }

      const modulo = modulosMap.get(permiso.idModulo)!;

      // Se normaliza acá además de en el SQL: esta letra es la CLAVE con la que
      // se agrupa el menú, y si no matchea con ENTRADA_LABELS el grupo entero
      // —"Operaciones", por ejemplo— no se dibuja aunque el permiso exista. Una
      // 'o' minúscula o con espacios cargada a mano en PAGINAS.ENTRADA alcanzaba
      // para que la página fuera invisible sin ningún error.
      //
      // Cualquier valor que no sea D/O/R cae en 'O': es mejor mostrar la página
      // en Operaciones que ocultarla.
      const cruda = (permiso.entrada ?? "").trim().toUpperCase();
      const entrada = cruda === "D" || cruda === "R" ? cruda : "O";

      if (!modulo.entradas[entrada]) {
        modulo.entradas[entrada] = [];
      }

      modulo.entradas[entrada].push({
        id: permiso.idPagina,
        nombre: permiso.pagina,
        ruta: permiso.ruta ?? "",
        entrada: entrada as "D" | "O" | "R",
        orden: permiso.orden ?? 0,
      });
    }

    // Convertir Map a array y ordenar
    const modulosOrdenados = [...modulosMap.values()]
      .sort((a, b) => a.nombre.localeCompare(b.nombre))
      .map((m) => ({
        ...m,
        entradas: Object.fromEntries(
          Object.entries(m.entradas)
            .sort(([a], [b]) => (ENTRADA_ORDER[a] || 999) - (ENTRADA_ORDER[b] || 999))
            .map(([entrada, paginas]) => [
              entrada,
              paginas.sort((a, b) => a.orden - b.orden || a.nombre.localeCompare(b.nombre)),
            ]),
        ),
      }));

    modulos.push(...modulosOrdenados);
  }

  return {
    modulos,
    isPending,
    isError,
    error,
    getEntradaLabel: (entrada: string) => ENTRADA_LABELS[entrada] || entrada,
  };
}
