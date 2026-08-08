/**
 * Cliente HTTP contra ORDS.
 *
 * El token de sesión se guarda en sessionStorage: se borra al cerrar la pestaña
 * y no viaja a otros orígenes. No es la opción más robusta —una cookie httpOnly
 * lo sería—, pero ORDS no puede fijar cookies para este dominio, así que el
 * token tiene que quedar en el cliente.
 */

/**
 * En desarrollo se usa una ruta relativa para que las peticiones pasen por el
 * proxy de Vite (ver `server.proxy` en vite.config.ts): al salir del mismo
 * origen que la página, el navegador no aplica CORS y no hace falta tocar la
 * configuración de ORDS.
 *
 * En el build no hay proxy —GitHub Pages sirve archivos estáticos, sin
 * servidor que reenvíe nada—, así que ahí se pega directo a APEX.
 */
const BASE_URL = import.meta.env.DEV ? "/ords/ctell" : "https://oracleapex.com/ords/ctell";
const TOKEN_KEY = "ctell-token";
const USUARIO_KEY = "ctell-usuario";
const USUARIO_RECORDADO_KEY = "ctell-usuario-recordado";

export type Usuario = {
  id: number;
  usuario: string;
  nombreApellido: string;
  correo: string | null;
  activo: number;
  fechaCreacion?: string;
  fechaActualizacion?: string;
};

export type LoginResponse = {
  token: string;
  expira: string;
  usuario: Pick<Usuario, "id" | "usuario" | "nombreApellido" | "correo">;
};

export type ListaUsuarios = {
  items: Usuario[];
  total: number;
  pagina: number;
  tamanio: number;
};

/** Error con el status HTTP, para distinguir 401 de un fallo real. */
export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export function getToken(): string | null {
  if (typeof window === "undefined") return null;
  return sessionStorage.getItem(TOKEN_KEY);
}

export function setToken(token: string | null) {
  if (typeof window === "undefined") return;
  if (token) {
    sessionStorage.setItem(TOKEN_KEY, token);
  } else {
    sessionStorage.removeItem(TOKEN_KEY);
  }
}

/** Datos del usuario que `POST /auth/login` ya devuelve junto al token. */
export type UsuarioSesion = LoginResponse["usuario"];

/**
 * Usuario de la sesión, cacheado en sessionStorage.
 *
 * El login ya devuelve nombreApellido, así que guardarlo evita un GET /auth/me
 * extra en cada carga: el saludo del panel aparece de inmediato en vez de
 * esperar un viaje a la red. Vive junto al token y muere con él.
 */
export function getUsuarioSesion(): UsuarioSesion | null {
  if (typeof window === "undefined") return null;

  const crudo = sessionStorage.getItem(USUARIO_KEY);
  if (!crudo) return null;

  try {
    return JSON.parse(crudo) as UsuarioSesion;
  } catch {
    // Si el JSON quedó corrupto se descarta: /auth/me lo repone.
    sessionStorage.removeItem(USUARIO_KEY);
    return null;
  }
}

export function setUsuarioSesion(usuario: UsuarioSesion | null) {
  if (typeof window === "undefined") return;
  if (usuario) {
    sessionStorage.setItem(USUARIO_KEY, JSON.stringify(usuario));
  } else {
    sessionStorage.removeItem(USUARIO_KEY);
  }
}

/** Credenciales que "Recordarme" deja precargadas en el login. */
export type CredencialesRecordadas = {
  usuario: string;
  password: string;
};

/**
 * "Recordarme": usuario y contraseña para precargar el formulario de login.
 *
 * ATENCIÓN — esto guarda la contraseña EN TEXTO PLANO en localStorage. Queda
 * en disco, la lee cualquiera que abra F12 → Application → Local Storage, y a
 * diferencia del token (8 h) no vence nunca. En una PC compartida, quien se
 * siente después tiene la clave de quien la usó antes.
 *
 * Es una decisión explícita del proyecto, no un descuido. La alternativa sin
 * ese riesgo es dejar que el gestor de contraseñas del navegador la guarde
 * cifrada por el sistema operativo.
 *
 * El token de sesión sigue en sessionStorage y muere al cerrar la pestaña:
 * esto solo precarga el formulario, no deja la sesión abierta.
 */
export function getCredencialesRecordadas(): CredencialesRecordadas | null {
  if (typeof window === "undefined") return null;

  const crudo = localStorage.getItem(USUARIO_RECORDADO_KEY);
  if (!crudo) return null;

  try {
    const datos = JSON.parse(crudo) as Partial<CredencialesRecordadas>;
    // Sin usuario no hay nada que precargar; la contraseña puede faltar si
    // vienen datos del formato anterior, que solo guardaba el usuario.
    if (!datos.usuario) return null;
    return { usuario: datos.usuario, password: datos.password ?? "" };
  } catch {
    // Formato viejo (texto plano con el usuario) o JSON corrupto: se descarta.
    localStorage.removeItem(USUARIO_RECORDADO_KEY);
    return null;
  }
}

export function setCredencialesRecordadas(credenciales: CredencialesRecordadas | null) {
  if (typeof window === "undefined") return;
  if (credenciales) {
    localStorage.setItem(USUARIO_RECORDADO_KEY, JSON.stringify(credenciales));
  } else {
    localStorage.removeItem(USUARIO_RECORDADO_KEY);
  }
}

async function request<T>(
  path: string,
  options: RequestInit & { auth?: boolean } = {},
): Promise<T> {
  const { auth = true, headers, ...rest } = options;

  const finalHeaders: Record<string, string> = {
    ...((headers as Record<string, string>) ?? {}),
  };

  // Content-Type solo cuando hay cuerpo que describir. Declararlo en un POST
  // vacío (logout, activar, inactivar) hace que ORDS intente parsear un JSON
  // inexistente y responda 400 sin llegar a ejecutar el handler.
  if (rest.body !== undefined && finalHeaders["Content-Type"] === undefined) {
    finalHeaders["Content-Type"] = "application/json";
  }

  if (auth) {
    const token = getToken();
    if (token) finalHeaders["Authorization"] = `Bearer ${token}`;
  }

  const res = await fetch(`${BASE_URL}${path}`, { ...rest, headers: finalHeaders });

  // 204 y respuestas sin cuerpo no traen JSON. Los errores de ORDS previos al
  // handler tampoco: llegan como HTML, y un JSON.parse a secas fallaría con
  // "Unexpected token <", ocultando el status que sí explica el problema.
  const texto = await res.text();
  let data: { error?: string } | null = null;
  try {
    data = texto ? JSON.parse(texto) : null;
  } catch {
    data = null;
  }

  if (!res.ok) {
    // Una sesión vencida debe limpiar el token local, o el usuario queda
    // en un limbo enviando credenciales que ya no sirven.
    if (res.status === 401) {
      setToken(null);
      setUsuarioSesion(null);
    }
    throw new ApiError(data?.error ?? `Error ${res.status}`, res.status);
  }

  return data as T;
}

export const api = {
  async login(usuario: string, password: string): Promise<LoginResponse> {
    const data = await request<LoginResponse>("/auth/login", {
      method: "POST",
      auth: false,
      body: JSON.stringify({ usuario, password }),
    });
    setToken(data.token);
    // El login ya trae nombreApellido: se guarda para que el panel lo muestre
    // sin tener que pedirlo de nuevo con /auth/me.
    setUsuarioSesion(data.usuario);
    return data;
  },

  /**
   * Cierra la sesión. Nunca lanza: revocar el token en el servidor es un
   * intento "mejor esfuerzo", pero la sesión del navegador se cierra siempre.
   *
   * Un `finally` solo no alcanza —limpia el estado pero deja la promesa
   * rechazada, y el error llega a la consola como "Uncaught (in promise)"—,
   * así que el fallo se captura de verdad. Si el servidor no pudo revocarlo,
   * el token igual vence a las 8 h.
   */
  async logout(): Promise<void> {
    try {
      await request("/auth/logout", { method: "POST" });
    } catch {
      // Sin re-lanzar: el usuario pidió salir y va a salir.
    } finally {
      // El usuario se limpia junto al token, o el siguiente que entre vería
      // el nombre del anterior.
      setToken(null);
      setUsuarioSesion(null);
    }
  },

  me: () => request<Usuario>("/auth/me"),

  usuarios: {
    listar: (
      params: {
        busqueda?: string;
        activo?: number;
        pagina?: number;
        tamanio?: number;
      } = {},
    ) => {
      const qs = new URLSearchParams();
      if (params.busqueda) qs.set("busqueda", params.busqueda);
      if (params.activo !== undefined) qs.set("activo", String(params.activo));
      if (params.pagina) qs.set("pagina", String(params.pagina));
      if (params.tamanio) qs.set("tamanio", String(params.tamanio));
      const q = qs.toString();
      return request<ListaUsuarios>(`/usuarios/${q ? `?${q}` : ""}`);
    },

    obtener: (id: number) => request<Usuario>(`/usuarios/${id}`),

    crear: (datos: {
      usuario: string;
      nombreApellido: string;
      correo?: string;
      password: string;
    }) =>
      request<{ id: number; ok: string }>("/usuarios/", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    actualizar: (
      id: number,
      datos: { nombreApellido?: string; correo?: string; activo?: number },
    ) =>
      request<{ ok: string }>(`/usuarios/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) => request<{ ok: string }>(`/usuarios/${id}`, { method: "DELETE" }),

    inactivar: (id: number) =>
      request<{ ok: string }>(`/usuarios/${id}/inactivar`, { method: "POST" }),

    activar: (id: number) => request<{ ok: string }>(`/usuarios/${id}/activar`, { method: "POST" }),

    cambiarPassword: (id: number, password: string) =>
      request<{ ok: string }>(`/usuarios/${id}/password`, {
        method: "POST",
        body: JSON.stringify({ password }),
      }),
  },
};
