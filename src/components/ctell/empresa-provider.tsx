import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";

import {
  getEmpresaSeleccionada,
  setEmpresaSeleccionada as guardarEmpresa,
  type EmpresaPublica,
} from "@/lib/api";

/**
 * Empresa activa de la sesión, disponible en toda la app.
 *
 * Se elige en el login (es obligatorio para entrar) y desde ahí cualquier
 * pantalla puede leerla con `useEmpresa()`. Hoy es solo estado del frontend:
 * ningún endpoint la recibe todavía. Cuando los paquetes PL/SQL empiecen a
 * filtrar por empresa, el id sale de acá.
 *
 * Persiste en localStorage para que el login la deje preseleccionada la próxima
 * vez, pero se borra al cerrar sesión y ante un 401 — ver `api.logout` y el
 * manejo del 401 en `request`, que llaman a `setEmpresaSeleccionada(null)`.
 * Por eso el provider revalida contra localStorage cada vez que monta: si la
 * sesión se cerró, el estado en memoria ya no tiene con qué repoblarse.
 */
type EmpresaContextValue = {
  empresa: EmpresaPublica | null;
  setEmpresa: (empresa: EmpresaPublica | null) => void;
};

const EmpresaContext = createContext<EmpresaContextValue | null>(null);

export function EmpresaProvider({ children }: { children: ReactNode }) {
  // Arranca en null y se hidrata al montar: localStorage no existe durante el
  // prerender del build, y leerlo en el render inicial rompe la hidratación.
  const [empresa, setEmpresaState] = useState<EmpresaPublica | null>(null);

  useEffect(() => {
    setEmpresaState(getEmpresaSeleccionada());
  }, []);

  const setEmpresa = useCallback((siguiente: EmpresaPublica | null) => {
    // El estado y el localStorage se escriben juntos: si solo se actualizara
    // el estado, un F5 volvería a la empresa anterior.
    guardarEmpresa(siguiente);
    setEmpresaState(siguiente);
  }, []);

  return (
    <EmpresaContext.Provider value={{ empresa, setEmpresa }}>{children}</EmpresaContext.Provider>
  );
}

/**
 * Empresa activa y cómo cambiarla.
 *
 * `empresa` puede ser null en el primer render (antes de hidratar desde
 * localStorage) aunque el login la exija, así que hay que contemplarlo.
 */
export function useEmpresa() {
  const ctx = useContext(EmpresaContext);
  if (!ctx) throw new Error("useEmpresa debe usarse dentro de <EmpresaProvider>");
  return ctx;
}
