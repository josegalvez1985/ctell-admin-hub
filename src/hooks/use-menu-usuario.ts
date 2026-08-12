import { useQuery } from "@tanstack/react-query";
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

  const { data, isPending, isError, error } = useQuery({
    queryKey: ["menu-usuario", usuario?.id],
    queryFn: () =>
      usuario?.id ? api.usuarioPaginas.listar({ idUsuario: usuario.id }) : null,
    enabled: !!usuario?.id,
  });

  // Agrupar páginas por módulo y luego por entrada
  const modulos: MenuModulo[] = [];

  if (data?.items) {
    const modulosMap = new Map<number, MenuModulo>();

    for (const permiso of data.items) {
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
      const entrada = permiso.entrada || "O"; // default a Operaciones

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
            .sort(
              ([a], [b]) => (ENTRADA_ORDER[a] || 999) - (ENTRADA_ORDER[b] || 999)
            )
            .map(([entrada, paginas]) => [
              entrada,
              paginas.sort((a, b) => a.orden - b.orden || a.nombre.localeCompare(b.nombre)),
            ])
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
