/**
 * Cliente HTTP contra ORDS.
 *
 * El token de sesión se guarda en sessionStorage: se borra al cerrar la pestaña
 * y no viaja a otros orígenes. No es la opción más robusta —una cookie httpOnly
 * lo sería—, pero ORDS no puede fijar cookies para este dominio, así que el
 * token tiene que quedar en el cliente.
 */

const BASE_URL = "https://oracleapex.com/ords/ctell";
const TOKEN_KEY = "ctell-token";

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

async function request<T>(
  path: string,
  options: RequestInit & { auth?: boolean } = {},
): Promise<T> {
  const { auth = true, headers, ...rest } = options;

  const finalHeaders: Record<string, string> = {
    "Content-Type": "application/json",
    ...((headers as Record<string, string>) ?? {}),
  };

  if (auth) {
    const token = getToken();
    if (token) finalHeaders["Authorization"] = `Bearer ${token}`;
  }

  const res = await fetch(`${BASE_URL}${path}`, { ...rest, headers: finalHeaders });

  // 204 y respuestas sin cuerpo no traen JSON.
  const texto = await res.text();
  const data = texto ? JSON.parse(texto) : null;

  if (!res.ok) {
    // Una sesión vencida debe limpiar el token local, o el usuario queda
    // en un limbo enviando credenciales que ya no sirven.
    if (res.status === 401) setToken(null);
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
    return data;
  },

  async logout(): Promise<void> {
    try {
      await request("/auth/logout", { method: "POST" });
    } finally {
      // El token local se borra aunque el servidor falle: la sesión del
      // navegador debe cerrarse igual.
      setToken(null);
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
