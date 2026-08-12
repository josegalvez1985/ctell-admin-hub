import { useQuery } from "@tanstack/react-query";

import { api, ApiError, getToken, getUsuarioSesion } from "@/lib/api";

/**
 * Usuario de la sesión actual.
 *
 * El login ya devuelve los datos del usuario, así que se usan como valor
 * inicial: el nombre aparece apenas carga el panel, sin esperar la red.
 * `GET /auth/me` corre igual en segundo plano para refrescarlos —si alguien
 * cambió el nombre desde otra sesión, se actualiza solo.
 */
export function useUsuarioActual() {
  return useQuery({
    queryKey: ["usuario-actual"],
    queryFn: () => api.me(),
    // Sin token no hay nada que pedir: en el login la petición daría 401.
    enabled: getToken() !== null,
    // Lo que trajo el login. Al ser un subconjunto de Usuario, las páginas que
    // solo muestran el nombre ya tienen todo lo que necesitan.
    placeholderData: () => {
      const sesion = getUsuarioSesion();
      // "A": si hay sesión, la cuenta está activa — el login rechaza a los
      // inactivos, así que un token válido implica una cuenta habilitada.
      return sesion
        ? ({ ...sesion, activo: "A" } as Awaited<ReturnType<typeof api.me>>)
        : undefined;
    },
    // El token dura 8 h y los datos del usuario no cambian entre pantallas.
    staleTime: 5 * 60 * 1000,
    // Un 401 significa sesión vencida, no un fallo temporal: reintentar solo
    // repite el mismo error.
    retry: (fallos, error) => !(error instanceof ApiError && error.status === 401) && fallos < 2,
  });
}

/** Iniciales para el avatar: "Jose Galvez" -> "JG". */
export function iniciales(nombreApellido: string | undefined): string {
  if (!nombreApellido) return "";

  return nombreApellido
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .map((parte) => parte[0]?.toUpperCase() ?? "")
    .join("");
}

/** Primer nombre, para saludar sin sonar formal: "Jose Galvez" -> "Jose". */
export function primerNombre(nombreApellido: string | undefined): string {
  if (!nombreApellido) return "";
  return nombreApellido.trim().split(/\s+/)[0] ?? "";
}
