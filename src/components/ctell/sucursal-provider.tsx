import { useQuery } from "@tanstack/react-query";
import { createContext, useCallback, useContext, useEffect, useMemo, type ReactNode } from "react";

import { useEmpresa } from "@/components/ctell/empresa-provider";
import {
  api,
  getSucursalSeleccionada,
  setSucursalSeleccionada as guardarSucursal,
  esActivo,
  type Sucursal,
  type SucursalActiva,
} from "@/lib/api";

/**
 * Sucursal activa de la sesión, disponible en toda la app.
 *
 * Complementa a la empresa activa: la empresa se elige en el login y la
 * sucursal acá, porque depende de ella. Cualquier pantalla la lee con
 * `useSucursal()` y usa `sucursal.id` como `idSucursal` en sus consultas, igual
 * que hoy se usa `empresa.id`.
 *
 * **Se elige sola cuando no hay ambigüedad.** Si la empresa tiene una sola
 * sucursal, esa queda activa sin preguntar; si tiene varias y el usuario no
 * eligió todavía, se toma la primera. Obligar a elegir entre una sola opción es
 * un click sin información, y dejarla en null haría que las pantallas que
 * dependen de ella no cargaran nada.
 *
 * **Cambiar de empresa la invalida.** Una sucursal pertenece a una sola
 * empresa: al cambiar, la guardada deja de ser válida y se reemplaza por la de
 * la empresa nueva.
 */
type SucursalContextValue = {
  sucursal: SucursalActiva | null;
  /** Todas las de la empresa activa, para el selector. */
  sucursales: Sucursal[];
  /** Sigue cargando la lista: las pantallas pueden esperar antes de consultar. */
  cargando: boolean;
  setSucursal: (sucursal: SucursalActiva | null) => void;
};

const SucursalContext = createContext<SucursalContextValue | null>(null);

/** Descarta los campos que no se persisten. */
function aActiva(sucursal: Sucursal): SucursalActiva {
  return {
    id: sucursal.id,
    idEmpresa: sucursal.idEmpresa,
    nombreSucursal: sucursal.nombreSucursal,
  };
}

export function SucursalProvider({ children }: { children: ReactNode }) {
  const { empresa } = useEmpresa();

  // Las sucursales son POR EMPRESA, así que la empresa entra en la queryKey: al
  // cambiarla, TanStack Query trata el listado como otra consulta en vez de
  // devolver en caché las de la anterior.
  const { data, isPending } = useQuery({
    queryKey: ["sucursales", empresa?.id ?? null],
    queryFn: () => api.sucursales.listar({ idEmpresa: empresa!.id }),
    // El provider de empresa hidrata después de montar: sin esto la primera
    // petición saldría sin idEmpresa y traería las de todas las empresas.
    enabled: empresa !== null,
  });

  // Sólo las activas son elegibles: una sucursal inactiva no debería poder
  // quedar como contexto de trabajo.
  const sucursales = useMemo(
    () => (data?.items ?? []).filter((s) => esActivo(s.activo)),
    [data?.items],
  );

  const setSucursal = useCallback((siguiente: SucursalActiva | null) => {
    guardarSucursal(siguiente);
  }, []);

  /**
   * Qué sucursal está activa, resuelto en cada render en vez de en un estado.
   *
   * Se deriva de lo guardado y de la lista: mantener una copia en `useState`
   * abría la puerta a que quedara apuntando a una sucursal de otra empresa
   * mientras la lista nueva ya había llegado.
   */
  const sucursal = useMemo<SucursalActiva | null>(() => {
    if (empresa === null || sucursales.length === 0) return null;

    const guardada = getSucursalSeleccionada();

    // Vale sólo si es de la empresa activa Y sigue existiendo entre las
    // activas: una sucursal borrada o inactivada no puede seguir siendo el
    // contexto de trabajo.
    if (guardada && guardada.idEmpresa === empresa.id) {
      const vigente = sucursales.find((s) => s.id === guardada.id);
      if (vigente) return aActiva(vigente);
    }

    // Sin elección válida: la única si hay una, la primera si hay varias.
    return aActiva(sucursales[0]!);
  }, [empresa, sucursales]);

  // La elección automática se persiste, para que sea la misma tras un F5 aunque
  // el orden del listado cambie. Va en un efecto porque escribir en
  // localStorage durante el render es un efecto secundario.
  useEffect(() => {
    if (sucursal === null) return;
    const guardada = getSucursalSeleccionada();
    if (guardada?.id === sucursal.id && guardada.idEmpresa === sucursal.idEmpresa) return;
    guardarSucursal(sucursal);
  }, [sucursal]);

  return (
    <SucursalContext.Provider
      value={{ sucursal, sucursales, cargando: empresa !== null && isPending, setSucursal }}
    >
      {children}
    </SucursalContext.Provider>
  );
}

/**
 * Sucursal activa y cómo cambiarla.
 *
 * `sucursal` puede ser null mientras carga la lista, o si la empresa no tiene
 * ninguna sucursal activa. Las pantallas que la necesiten deberían usar
 * `enabled: sucursal !== null` en sus consultas, igual que con la empresa.
 */
export function useSucursal() {
  const ctx = useContext(SucursalContext);
  if (!ctx) throw new Error("useSucursal debe usarse dentro de <SucursalProvider>");
  return ctx;
}
