import { useNavigate } from "@tanstack/react-router";
import { useEffect } from "react";
import { toast } from "sonner";

import { alCerrarseSesion } from "@/lib/api";

/**
 * Lleva al login cuando la sesión deja de valer.
 *
 * Escucha el aviso que `api.ts` emite ante cualquier 401, sin importar qué
 * petición lo provocó: el token venció (dura 8 h), se revocó al cambiarse la
 * contraseña, la cuenta se inactivó, o el valor guardado quedó inservible.
 *
 * Cubre el hueco que dejaban las otras dos defensas. El `beforeLoad` de
 * `_auth` sólo mira si el token existe, y `useUsuarioActual` sólo se entera de
 * los 401 de `/auth/me`: si la sesión se caía mientras alguien guardaba un
 * usuario, el token se limpiaba pero la persona se quedaba en la pantalla
 * viendo un error que no explicaba nada.
 *
 * Se monta una sola vez, en el layout `_auth`.
 */
export function useCerrarSesionAlVencer() {
  const navigate = useNavigate();

  useEffect(() => {
    return alCerrarseSesion(() => {
      // Sin el aviso, volver al login de golpe parece un cierre de sesión
      // espontáneo. Decir por qué evita que se lea como una falla del sistema.
      toast.info("Tu sesión expiró. Iniciá sesión de nuevo.");
      navigate({ to: "/" });
    });
  }, [navigate]);
}
