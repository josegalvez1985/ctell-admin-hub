/**
 * Cliente HTTP contra ORDS.
 *
 * El token de sesión se guarda en sessionStorage: se borra al cerrar la pestaña
 * y no viaja a otros orígenes. No es la opción más robusta —una cookie httpOnly
 * lo sería—, pero ORDS no puede fijar cookies para este dominio, así que el
 * token tiene que quedar en el cliente.
 */

/**
 * En desarrollo, ruta relativa contra el proxy de Vite (ver `server.proxy` en
 * vite.config.ts): la app pide a /ords/... —mismo origen que la página, así
 * que no hay chequeo de CORS— y es Vite quien reenvía a APEX servidor contra
 * servidor, donde la política de mismo origen no aplica.
 *
 * En producción se pega directo a oracleapex.com. Eso requiere que ORDS envíe
 * `Access-Control-Allow-Origin` para www.ctell.online: se habilita en APEX →
 * Administración del Workspace → RESTful Services → orígenes permitidos.
 * Sin ese origen habilitado, el navegador bloquea la respuesta igual que
 * bloquearía cualquier otra llamada cross-origin.
 */
const BASE_URL = import.meta.env.DEV ? "/ords/ctell" : "https://oracleapex.com/ords/ctell";
const TOKEN_KEY = "ctell-token";
const USUARIO_KEY = "ctell-usuario";
const USUARIO_RECORDADO_KEY = "ctell-usuario-recordado";
const EMPRESA_KEY = "ctell-empresa";

/**
 * Estado de un registro, tal como lo guarda la base: "A" activo, "I" inactivo.
 *
 * Es el mismo código en la columna, en el JSON y en el frontend. Antes la API
 * traducía a 1/0 en la respuesta y había que retraducir en cada filtro; ese
 * ida y vuelta era el origen de los ORA-01722 que rompían los listados.
 */
export type Estado = "A" | "I";

/** `true` si el registro está activo. Evita repetir la comparación literal. */
export function esActivo(estado: Estado | undefined): boolean {
  return estado === "A";
}

/**
 * Rol del usuario, con el mismo código que guarda la columna `ES_ADMIN`:
 * "S" administrador, "N" no.
 *
 * Sigue el criterio de `Estado`: el código viaja igual de punta a punta, sin
 * traducirse a booleano en la respuesta ni retraducirse en el frontend.
 */
export type Rol = "S" | "N";

/** `true` si el usuario es administrador. */
export function esAdmin(rol: Rol | undefined): boolean {
  return rol === "S";
}

export type Usuario = {
  id: number;
  usuario: string;
  nombreApellido: string;
  correo: string | null;
  /**
   * Estado de la cuenta, con el mismo código que guarda la base: "A" activo,
   * "I" inactivo. No es 1/0 — traducir a números en la respuesta obligaba a
   * retraducir en cada filtro y era una fuente constante de ORA-01722.
   */
  activo: Estado;
  esAdmin: Rol;
  fechaCreacion?: string;
  fechaActualizacion?: string;
};

export type LoginResponse = {
  token: string;
  expira: string;
  /**
   * `/auth/login` devuelve el rol pero no el estado: para haber llegado hasta
   * acá la cuenta tiene que estar activa, así que el dato no aportaría nada.
   */
  usuario: Pick<Usuario, "id" | "usuario" | "nombreApellido" | "correo" | "esAdmin">;
};

export type ListaUsuarios = {
  items: Usuario[];
  total: number;
};

export type Modulo = {
  id: number;
  nombre: string;
  icono: string | null;
  orden: number;
  /** Mismo criterio que Usuario.activo: código 'A'/'I' tal cual la columna. */
  activo: Estado;
};

export type ListaModulos = {
  items: Modulo[];
  total: number;
};

export type Pais = {
  id: number;
  nombrePais: string;
  codigoPais: string | null;
  activo: Estado;
};

export type ListaPaises = {
  items: Pais[];
  total: number;
};

export type Departamento = {
  id: number;
  idPais: number;
  /** Nombre del país al que pertenece: viene del JOIN, no de DEPARTAMENTOS. */
  pais: string;
  /** Código del país, del mismo JOIN. */
  codigoPais: string | null;
  nombreDepartamento: string;
  activo: Estado;
};

export type ListaDepartamentos = {
  items: Departamento[];
  total: number;
};

export type Ciudad = {
  id: number;
  idDepartamento: number;
  /**
   * Nombre del departamento al que pertenece: viene del JOIN, no de CIUDADES.
   *
   * No hay `pais` ni `idPais`: el listado hace un solo JOIN, contra
   * DEPARTAMENTOS. El país es información del departamento, no de la ciudad —
   * para verlo está la página de Departamentos.
   */
  departamento: string;
  nombreCiudad: string;
  activo: Estado;
};

export type ListaCiudades = {
  items: Ciudad[];
  total: number;
};

export type Empresa = {
  id: number;
  nombreEmpresa: string;
  ruc: string | null;
  correoEmpresa: string | null;
  telefono: string | null;
  direccion: string | null;
  /**
   * Ubicación. Los tres niveles se guardan aunque la ciudad ya implique
   * departamento y país: así lo pide el DDL, y el formulario los completa con
   * combobox en cascada. Las tres FK son nullables — una empresa puede no
   * tener dirección cargada todavía.
   */
  idCiudad: number | null;
  /** Nombre de la ciudad: viene del JOIN, no de EMPRESAS. */
  ciudad: string | null;
  idDepartamento: number | null;
  departamento: string | null;
  idPais: number | null;
  pais: string | null;
  /** Código ISO de 3 letras. 'PYG' por defecto. */
  monedaDefecto: string | null;
  representanteLegal: string | null;
  /**
   * Si tiene logo cargado. El binario no viaja en este JSON: se pide aparte
   * con `urlLogoEmpresa(id)` y se sube con `api.empresas.subirLogo`.
   */
  tieneLogo: boolean;
  activo: Estado;
};

export type ListaEmpresas = {
  items: Empresa[];
  total: number;
};

export type Sucursal = {
  id: number;
  idEmpresa: number;
  /** Nombre de la empresa a la que pertenece: viene del JOIN, no de SUCURSALES. */
  empresa: string;
  nombreSucursal: string;
  direccion: string | null;
  activo: Estado;
};

export type Moneda = {
  id: number;
  /**
   * Empresa dueña de la moneda. Sale de la empresa activa de la sesión, no de
   * un combobox: cada empresa tiene su propio juego de monedas.
   *
   * No hay campo `empresa` con el nombre: el listado siempre viene filtrado por
   * una sola empresa, así que sería la misma constante en todas las filas.
   */
  idEmpresa: number;
  nombreMoneda: string;
  simbolo: string | null;
  activo: Estado;
};

export type ListaMonedas = {
  items: Moneda[];
  total: number;
};

export type UnidadMedida = {
  id: number;
  /**
   * Empresa dueña de la unidad. Sale de la empresa activa de la sesión, no de
   * un combobox: cada empresa tiene su propio juego de unidades.
   *
   * No hay campo `empresa` con el nombre: el listado siempre viene filtrado por
   * una sola empresa, así que sería la misma constante en todas las filas.
   */
  idEmpresa: number;
  nombreUnidad: string;
  /**
   * Obligatoria, y es lo único que no puede repetirse dentro de una empresa —
   * el UNIQUE es (ID_EMPRESA, ABREVIATURA), no el nombre. Al revés que en
   * `Moneda`, donde el símbolo es opcional y lo único es el nombre.
   */
  abreviatura: string;
  activo: Estado;
};

export type ListaUnidadesMedida = {
  items: UnidadMedida[];
  total: number;
};

export type Categoria = {
  id: number;
  /**
   * Empresa dueña de la categoría. Sale de la empresa activa de la sesión, no
   * de un combobox: cada empresa tiene su propio juego de categorías.
   *
   * No hay campo `empresa` con el nombre: el listado siempre viene filtrado por
   * una sola empresa, así que sería la misma constante en todas las filas.
   */
  idEmpresa: number;
  /** Único dentro de la empresa — el UNIQUE es (ID_EMPRESA, NOMBRE_CATEGORIA). */
  nombreCategoria: string;
  descripcion: string | null;
  activo: Estado;
};

export type ListaCategorias = {
  items: Categoria[];
  total: number;
};

export type Articulo = {
  id: number;
  /** Empresa dueña del artículo. Sale de la empresa activa de la sesión. */
  idEmpresa: number;
  /**
   * Las tres relaciones son OPCIONALES: un artículo puede cargarse sin
   * categoría, sin moneda o sin unidad. Los nombres vienen del LEFT JOIN, así
   * que son null cuando el id lo es.
   */
  idCategoria: number | null;
  categoria: string | null;
  idMoneda: number | null;
  moneda: string | null;
  simboloMoneda: string | null;
  idUnidadMedida: number | null;
  unidadMedida: string | null;
  abreviaturaUnidad: string | null;
  codigoArticulo: string | null;
  nombreArticulo: string;
  descripcion: string | null;
  precioUltimaCompra: number | null;
  /** Obligatorio: la columna es NOT NULL. */
  precioVenta: number;
  cantidadStock: number;
  cantidadMinima: number;
  /**
   * Si tiene imagen cargada. El binario no viaja en el JSON: se pide aparte
   * con `urlImagenArticulo(id)`.
   */
  tieneImagen: boolean;
  activo: Estado;
};

export type ListaArticulos = {
  items: Articulo[];
  total: number;
};

export type ListaSucursales = {
  items: Sucursal[];
  total: number;
};

export type Entrada = "D" | "O" | "R";

export type Pagina = {
  id: number;
  idModulo: number;
  /** Nombre del módulo al que pertenece: viene del JOIN, no de PAGINAS. */
  modulo: string;
  nombre: string;
  /** Path del frontend para cargar la página ("/compras/ordenes", etc). */
  ruta: string;
  /** Sección: 'D' (Definiciones), 'O' (Operaciones), 'R' (Reportes). */
  entrada: Entrada;
  orden: number;
  activo: Estado;
};

export type ListaPaginas = {
  items: Pagina[];
  total: number;
};

/**
 * Permiso de un usuario sobre una página.
 *
 * No tiene `id` propio: la identidad es el par (idUsuario, idPagina), igual
 * que la PK compuesta de USUARIO_PAGINAS. Por eso para quitar un permiso hay
 * que mandar las dos claves.
 */
export type UsuarioPagina = {
  idUsuario: number;
  usuario: string;
  idPagina: number;
  /** Nombre de la página: viene del JOIN, no de USUARIO_PAGINAS. */
  pagina: string;
  /** Path del frontend, del JOIN con PAGINAS. Sin esto el menú no sabe adónde ir. */
  ruta: string;
  /** Sección donde se agrupa en el menú: 'D', 'O' o 'R'. También del JOIN. */
  entrada: Entrada;
  /** Posición dentro de su sección, del JOIN con PAGINAS. */
  orden: number;
  idModulo: number;
  /** Nombre del módulo al que pertenece la página. */
  modulo: string;
  /** Ícono del módulo (nombre de lucide-react), del JOIN con MODULOS. */
  moduloIcono: string | null;
  /**
   * Empresa desde la que se otorgó el permiso. Es AUDITORÍA, no alcance: el
   * permiso vale con cualquier empresa que el usuario elija al entrar, y el
   * menú no filtra por este campo.
   *
   * Es null en los permisos cargados antes de que existiera la columna. No se
   * puede usar para dar accesos distintos por empresa: la PK de la tabla sigue
   * siendo (ID_USUARIO, ID_PAGINA), así que una misma página no admite dos
   * filas para el mismo usuario. Ver el encabezado de db/usuario-paginas.sql.
   */
  idEmpresa: number | null;
  fechaAlta: string;
};

export type ListaUsuarioPaginas = {
  items: UsuarioPagina[];
  total: number;
};

/**
 * Aviso de que la sesión dejó de valer, para que la app lleve al login.
 *
 * Lo dispara cualquier 401, venga de donde venga: un token vencido, revocado
 * al cambiar la contraseña, de una cuenta que inactivaron, o simplemente
 * inválido. Este módulo no puede navegar por su cuenta —importar el router
 * desde acá crearía un ciclo, y `request()` no es un componente—, así que
 * avisa y quien sepa navegar reacciona. Ver `useCerrarSesionAlVencer`.
 *
 * Es un `Set` y no un solo callback porque el hook se monta una vez por
 * layout: si un día hay dos, los dos tienen que enterarse.
 */
type OyenteSesion = () => void;
const oyentesSesion = new Set<OyenteSesion>();

/** Suscribe un callback al cierre de sesión. Devuelve cómo desuscribirse. */
export function alCerrarseSesion(oyente: OyenteSesion): () => void {
  oyentesSesion.add(oyente);
  return () => oyentesSesion.delete(oyente);
}

function notificarSesionCerrada() {
  for (const oyente of oyentesSesion) oyente();
}

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

/**
 * Empresa mínima que devuelve el endpoint público del login.
 *
 * Solo id y nombre: es lo único que `/empresas/publicas` expone sin token. Para
 * los datos completos está el tipo `Empresa`, que requiere sesión.
 */
export type EmpresaPublica = {
  id: number;
  nombreEmpresa: string;
  /**
   * Si tiene un logo cargado. El binario no viaja en el JSON: se pide aparte
   * con `urlLogoEmpresa(id)`. Con `false` el frontend dibuja las iniciales sin
   * intentar la petición.
   */
  tieneLogo: boolean;
};

export type ListaEmpresasPublicas = {
  items: EmpresaPublica[];
  total: number;
};

/**
 * URL de la imagen del logo, para usar directo en `<img src>`.
 *
 * No pasa por `request()` a propósito: quien descarga la imagen es el navegador
 * con su propia petición, y ahí no hay forma de mandar el header Authorization.
 * Por eso el endpoint es público, igual que `/empresas/publicas`.
 *
 * Devuelve 404 si la empresa no tiene logo cargado. Quien la use debería
 * manejar el `onError` del `<img>` para caer a las iniciales.
 */
export function urlLogoEmpresa(id: number): string {
  return `${BASE_URL}/empresas/logo/${id}`;
}

/**
 * URL de la imagen de un artículo, para usar directo en `<img src>`.
 *
 * Mismo criterio que `urlLogoEmpresa`: el navegador descarga la imagen con su
 * propia petición y ahí no hay forma de mandar el header Authorization, así que
 * el endpoint es público. Devuelve 404 si el artículo no tiene imagen.
 */
export function urlImagenArticulo(id: number): string {
  return `${BASE_URL}/articulos/imagen/${id}`;
}

/**
 * Empresa a la que el usuario eligió conectarse en el login.
 *
 * Vive en localStorage —no en sessionStorage— para que el login la deje
 * preseleccionada la próxima vez, como ya hace "Recordarme" con el usuario.
 * Pero se borra en el logout (ver `api.logout`) y ante un 401: elegir empresa
 * es parte de iniciar sesión, así que no debe sobrevivir a cerrarla.
 *
 * Se guarda el objeto entero y no solo el id porque el nombre se muestra en el
 * layout: con el id suelto haría falta pedir la lista de nuevo solo para
 * escribir un título.
 */
export function getEmpresaSeleccionada(): EmpresaPublica | null {
  if (typeof window === "undefined") return null;

  const crudo = localStorage.getItem(EMPRESA_KEY);
  if (!crudo) return null;

  try {
    const datos = JSON.parse(crudo) as Partial<EmpresaPublica>;
    // Sin id no sirve para nada: se descarta en vez de devolver a medias.
    if (typeof datos.id !== "number") return null;
    return {
      id: datos.id,
      nombreEmpresa: datos.nombreEmpresa ?? "",
      tieneLogo: datos.tieneLogo === true,
    };
  } catch {
    localStorage.removeItem(EMPRESA_KEY);
    return null;
  }
}

export function setEmpresaSeleccionada(empresa: EmpresaPublica | null) {
  if (typeof window === "undefined") return;
  if (empresa) {
    localStorage.setItem(EMPRESA_KEY, JSON.stringify(empresa));
  } else {
    localStorage.removeItem(EMPRESA_KEY);
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

/**
 * Traduce un código HTTP a un mensaje que le sirva a quien usa el sistema.
 *
 * Es el último recurso: solo se usa cuando el backend no mandó su propio
 * mensaje, que siempre es más preciso. Pasa cuando la respuesta no es JSON —un
 * error de ORDS anterior al handler llega como HTML— y ahí lo único que se
 * sabe es el número.
 *
 * Los mensajes dicen qué hacer, no qué falló: a quien está frente a la
 * pantalla "Error 502" no le sirve de nada, "el servidor no responde,
 * probá de nuevo en unos minutos" sí.
 */
function mensajeSegunEstado(status: number): string {
  switch (status) {
    case 400:
      return "Los datos enviados no son válidos. Revisá el formulario e intentá de nuevo.";
    case 401:
      // Genérico a propósito: acá no se sabe si el 401 vino del login o de un
      // token vencido en cualquier otra pantalla. El login lo reemplaza por
      // uno específico, que en ese contexto sí es correcto.
      return "Tu sesión no es válida o expiró. Iniciá sesión de nuevo.";
    case 403:
      return "No tenés permisos para hacer esto. Consultá con un administrador.";
    case 404:
      return "No se encontró lo que buscabas. Puede que se haya eliminado.";
    case 409:
      return "Ese registro ya existe.";
    case 500:
      return "Hubo un problema en el servidor. Si sigue pasando, avisá al administrador.";
    case 502:
    case 503:
    case 504:
      return "El servidor no está respondiendo. Probá de nuevo en unos minutos.";
    default:
      // Un código que no esperábamos: se informa sin tecnicismos, pero el
      // número queda en ApiError.status para poder diagnosticarlo.
      return "No se pudo completar la operación. Intentá de nuevo.";
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
  let data: { error?: string; resultado?: string } | null = null;
  try {
    data = texto ? JSON.parse(texto) : null;
  } catch {
    data = null;
  }

  if (!res.ok) {
    // Un 401 sólo significa "la sesión se cayó" en una petición autenticada.
    // En el login (`auth: false`) significa "credenciales incorrectas": ahí no
    // hay ninguna sesión que perder, y tratarlo igual rompía el acceso — el
    // aviso de sesión vencida se disparaba con cada intento fallido y expulsaba
    // de la pantalla a quien estaba tratando de entrar.
    if (res.status === 401 && auth) {
      // Se limpia el token local, o el usuario queda en un limbo enviando
      // credenciales que ya no sirven.
      setToken(null);
      setUsuarioSesion(null);
      // La empresa se elige al iniciar sesión: si la sesión se cayó, la
      // elección caducó con ella y hay que volver a hacerla en el login.
      setEmpresaSeleccionada(null);
      // …y hay que sacarlo de la pantalla protegida donde quedó. Limpiar el
      // token no alcanza: sin esto seguiría viendo el panel, con un toast de
      // error y sin entender que lo que pasó fue que se le venció la sesión.
      notificarSesionCerrada();
    }
    // El mensaje del backend es siempre el mejor: explica el caso concreto
    // ("El usuario ya existe"). Solo cuando no llega —porque la respuesta no
    // era JSON— se traduce el código a algo legible: "Error 401" no le dice
    // nada a quien está usando el sistema.
    throw new ApiError(data?.error ?? mensajeSegunEstado(res.status), res.status);
  }

  // Si la respuesta viene empaquetada en { resultado: "..." }, desempaquetarla
  if (
    data &&
    typeof data === "object" &&
    "resultado" in data &&
    typeof data.resultado === "string"
  ) {
    try {
      return JSON.parse(data.resultado) as T;
    } catch {
      // Si falla el parseo, devolver como estaba
      return data as T;
    }
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
      // La empresa muere con la sesión: aunque viva en localStorage para que el
      // login la deje preseleccionada, dejarla activa tras cerrar sesión haría
      // que el siguiente que entre en esta PC arranque conectado a la empresa
      // del anterior.
      setEmpresaSeleccionada(null);
    }
  },

  async me(): Promise<Usuario> {
    const raw = await request<{ resultado?: string } | Usuario>("/auth/me");
    if (!raw) return raw as Usuario;

    // Si tiene 'resultado' como string (empaquetado), desempaquetarlo
    if ("resultado" in raw && typeof raw.resultado === "string") {
      return JSON.parse(raw.resultado) as Usuario;
    }

    // Si ya es Usuario (sin 'resultado'), devolverlo tal cual
    if ("id" in raw && "usuario" in raw) {
      return raw as Usuario;
    }

    return raw as Usuario;
  },

  usuarios: {
    listar: () => request<ListaUsuarios>("/usuarios/listar"),

    crear: (datos: {
      usuario: string;
      nombreApellido: string;
      correo?: string;
      password: string;
      /** Omitido equivale a "N": el default seguro es no ser administrador. */
      esAdmin?: Rol;
    }) =>
      // Responde 201, no 200. `request` solo mira `res.ok`, así que da igual.
      request<{ id: number; ok: boolean }>("/usuarios/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /**
     * Los campos ausentes no se modifican. `usuario` no se puede cambiar: es la
     * identidad con la que se inicia sesión, y el backend ignora el campo.
     *
     * Para activar o inactivar una cuenta se manda `activo: "A" | "I"` acá — no
     * hay endpoints separados. El backend revoca las sesiones abiertas cuando
     * la deja inactiva.
     */
    actualizar: (
      id: number,
      datos: {
        nombreApellido?: string;
        correo?: string;
        activo?: Estado;
        esAdmin?: Rol;
      },
    ) =>
      request<{ ok: boolean }>(`/usuarios/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/usuarios/eliminar/${id}`, { method: "DELETE" }),
  },

  modulos: {
    listar: () => request<ListaModulos>("/modulos/listar"),

    crear: (datos: { nombre: string; icono?: string; orden?: number }) =>
      request<{ id: number; ok: boolean }>("/modulos/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        nombre?: string;
        icono?: string;
        orden?: number;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/modulos/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/modulos/eliminar/${id}`, { method: "DELETE" }),
  },

  paginas: {
    /** Sin `idModulo` devuelve todas las páginas de todos los módulos. */
    listar: (params: { idModulo?: number } = {}) => {
      const q = params.idModulo ? `?idModulo=${params.idModulo}` : "";
      return request<ListaPaginas>(`/paginas/listar${q}`);
    },

    crear: (datos: {
      idModulo: number;
      nombre: string;
      ruta: string;
      entrada: Entrada;
      orden?: number;
    }) =>
      request<{ id: number; ok: boolean }>("/paginas/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        idModulo?: number;
        nombre?: string;
        ruta?: string;
        entrada?: Entrada;
        orden?: number;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/paginas/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/paginas/eliminar/${id}`, { method: "DELETE" }),
  },

  usuarioPaginas: {
    /** Sin `idUsuario` devuelve los permisos de todos los usuarios. */
    listar: (params: { idUsuario?: number } = {}) => {
      const q = params.idUsuario ? `?idUsuario=${params.idUsuario}` : "";
      return request<ListaUsuarioPaginas>(`/usuario-paginas/listar${q}`);
    },

    /**
     * Responde 409 si el usuario ya tenía acceso a esa página — incluso con
     * otro `idEmpresa`: la PK es (idUsuario, idPagina) y la empresa no la
     * integra, así que una página se asigna a UNA sola empresa por usuario.
     *
     * `idEmpresa` es obligatorio acá aunque la columna sea nullable: define en
     * qué empresa vale el permiso, y el menú solo muestra las páginas de la
     * empresa activa. Un permiso sin empresa no aparecería en ningún lado.
     */
    asignar: (idUsuario: number, idPagina: number, idEmpresa: number) =>
      request<{ ok: boolean }>("/usuario-paginas/asignar", {
        method: "POST",
        body: JSON.stringify({ idUsuario, idPagina, idEmpresa }),
      }),

    /** Las dos claves van en la URL: la PK de la tabla es compuesta. */
    quitar: (idUsuario: number, idPagina: number) =>
      request<{ ok: boolean }>(`/usuario-paginas/quitar/${idUsuario}/${idPagina}`, {
        method: "DELETE",
      }),
  },

  paises: {
    listar: () => request<ListaPaises>("/paises/listar"),

    crear: (datos: { nombrePais: string; codigoPais?: string }) =>
      request<{ id: number; ok: boolean }>("/paises/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        nombrePais?: string;
        codigoPais?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/paises/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/paises/eliminar/${id}`, { method: "DELETE" }),
  },

  departamentos: {
    /** Sin `idPais` devuelve los departamentos de todos los países. */
    listar: (params: { idPais?: number } = {}) => {
      const q = params.idPais ? `?idPais=${params.idPais}` : "";
      return request<ListaDepartamentos>(`/departamentos/listar${q}`);
    },

    crear: (datos: { idPais: number; nombreDepartamento: string }) =>
      request<{ id: number; ok: boolean }>("/departamentos/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        idPais?: number;
        nombreDepartamento?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/departamentos/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/departamentos/eliminar/${id}`, { method: "DELETE" }),
  },

  ciudades: {
    /** Sin `idDepartamento` devuelve las ciudades de todos los departamentos. */
    listar: (params: { idDepartamento?: number } = {}) => {
      const q = params.idDepartamento ? `?idDepartamento=${params.idDepartamento}` : "";
      return request<ListaCiudades>(`/ciudades/listar${q}`);
    },

    crear: (datos: { idDepartamento: number; nombreCiudad: string }) =>
      request<{ id: number; ok: boolean }>("/ciudades/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        idDepartamento?: number;
        nombreCiudad?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/ciudades/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/ciudades/eliminar/${id}`, { method: "DELETE" }),
  },

  empresas: {
    /** Sin `idCiudad` devuelve las empresas de todas las ciudades. */
    listar: (params: { idCiudad?: number } = {}) => {
      const q = params.idCiudad ? `?idCiudad=${params.idCiudad}` : "";
      return request<ListaEmpresas>(`/empresas/listar${q}`);
    },

    /**
     * Empresas activas para el selector del login. `auth: false` porque en esa
     * pantalla todavía no hay token — es el único endpoint del proyecto que no
     * lo pide.
     *
     * Devuelve solo id y nombre: el backend no expone nada más acá, que es
     * justamente lo que hace aceptable dejarlo abierto.
     */
    publicas: () => request<ListaEmpresasPublicas>("/empresas/publicas", { auth: false }),

    /**
     * Sube el logo de una empresa. El archivo va como cuerpo crudo del PUT y su
     * tipo en el Content-Type — no es multipart: el endpoint recibe una sola
     * imagen, y envolverla en un form-data solo agregaría parseo de más.
     *
     * El Content-Type se pisa con el del archivo; `request` respeta el header
     * que ya venga puesto en vez de forzar application/json.
     */
    subirLogo: (id: number, archivo: File) =>
      request<{ ok: boolean }>(`/empresas/logo/${id}`, {
        method: "PUT",
        headers: { "Content-Type": archivo.type },
        body: archivo,
      }),

    crear: (datos: {
      nombreEmpresa: string;
      ruc?: string;
      correoEmpresa?: string;
      telefono?: string;
      direccion?: string;
      idCiudad?: number;
      idDepartamento?: number;
      idPais?: number;
      /** Omitida equivale a "PYG". */
      monedaDefecto?: string;
      representanteLegal?: string;
    }) =>
      request<{ id: number; ok: boolean }>("/empresas/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        nombreEmpresa?: string;
        ruc?: string;
        correoEmpresa?: string;
        telefono?: string;
        direccion?: string;
        idCiudad?: number;
        idDepartamento?: number;
        idPais?: number;
        monedaDefecto?: string;
        representanteLegal?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/empresas/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/empresas/eliminar/${id}`, { method: "DELETE" }),
  },

  sucursales: {
    /** Sin `idEmpresa` devuelve las sucursales de todas las empresas. */
    listar: (params: { idEmpresa?: number } = {}) => {
      const q = params.idEmpresa ? `?idEmpresa=${params.idEmpresa}` : "";
      return request<ListaSucursales>(`/sucursales/listar${q}`);
    },

    crear: (datos: { idEmpresa: number; nombreSucursal: string; direccion?: string }) =>
      request<{ id: number; ok: boolean }>("/sucursales/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        idEmpresa?: number;
        nombreSucursal?: string;
        direccion?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/sucursales/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/sucursales/eliminar/${id}`, { method: "DELETE" }),
  },

  monedas: {
    /**
     * Monedas de una empresa. `idEmpresa` sale de la empresa activa de la
     * sesión (`useEmpresa()`), no de un filtro de la pantalla.
     *
     * Sin `idEmpresa` devuelve las de todas las empresas — no se usa desde la
     * app, pero el endpoint lo permite para poder inspeccionarlo.
     */
    listar: (params: { idEmpresa?: number } = {}) => {
      const q = params.idEmpresa ? `?idEmpresa=${params.idEmpresa}` : "";
      return request<ListaMonedas>(`/monedas/listar${q}`);
    },

    crear: (datos: { idEmpresa: number; nombreMoneda: string; simbolo?: string }) =>
      request<{ id: number; ok: boolean }>("/monedas/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        idEmpresa?: number;
        nombreMoneda?: string;
        simbolo?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/monedas/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/monedas/eliminar/${id}`, { method: "DELETE" }),
  },

  unidadesMedida: {
    /**
     * Unidades de una empresa. `idEmpresa` sale de la empresa activa de la
     * sesión (`useEmpresa()`), no de un filtro de la pantalla.
     *
     * Sin `idEmpresa` devuelve las de todas las empresas — no se usa desde la
     * app, pero el endpoint lo permite para poder inspeccionarlo.
     */
    listar: (params: { idEmpresa?: number } = {}) => {
      const q = params.idEmpresa ? `?idEmpresa=${params.idEmpresa}` : "";
      return request<ListaUnidadesMedida>(`/unidades-medida/listar${q}`);
    },

    /** `abreviatura` es obligatoria: la columna es NOT NULL. */
    crear: (datos: { idEmpresa: number; nombreUnidad: string; abreviatura: string }) =>
      request<{ id: number; ok: boolean }>("/unidades-medida/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        idEmpresa?: number;
        nombreUnidad?: string;
        abreviatura?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/unidades-medida/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/unidades-medida/eliminar/${id}`, { method: "DELETE" }),
  },

  categorias: {
    /**
     * Categorías de una empresa. `idEmpresa` sale de la empresa activa de la
     * sesión (`useEmpresa()`), no de un filtro de la pantalla.
     *
     * Sin `idEmpresa` devuelve las de todas las empresas — no se usa desde la
     * app, pero el endpoint lo permite para poder inspeccionarlo.
     */
    listar: (params: { idEmpresa?: number } = {}) => {
      const q = params.idEmpresa ? `?idEmpresa=${params.idEmpresa}` : "";
      return request<ListaCategorias>(`/categorias/listar${q}`);
    },

    crear: (datos: { idEmpresa: number; nombreCategoria: string; descripcion?: string }) =>
      request<{ id: number; ok: boolean }>("/categorias/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        idEmpresa?: number;
        nombreCategoria?: string;
        descripcion?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/categorias/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/categorias/eliminar/${id}`, { method: "DELETE" }),
  },

  articulos: {
    /**
     * Artículos de una empresa. `idEmpresa` sale de la empresa activa de la
     * sesión (`useEmpresa()`), no de un filtro de la pantalla.
     */
    listar: (params: { idEmpresa?: number } = {}) => {
      const q = params.idEmpresa ? `?idEmpresa=${params.idEmpresa}` : "";
      return request<ListaArticulos>(`/articulos/listar${q}`);
    },

    /**
     * `nombreArticulo` y `precioVenta` son obligatorios; el resto no. Las tres
     * relaciones (categoría, moneda, unidad) pueden omitirse.
     */
    crear: (datos: {
      idEmpresa: number;
      nombreArticulo: string;
      precioVenta: number;
      idCategoria?: number;
      idMoneda?: number;
      idUnidadMedida?: number;
      codigoArticulo?: string;
      descripcion?: string;
      precioUltimaCompra?: number;
      cantidadStock?: number;
      cantidadMinima?: number;
    }) =>
      request<{ id: number; ok: boolean }>("/articulos/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /**
     * Los campos ausentes no se modifican. Ojo: mandar una relación vacía
     * significa "no cambiar", no "desvincular" — el backend usa NVL.
     */
    actualizar: (
      id: number,
      datos: {
        idEmpresa?: number;
        idCategoria?: number;
        idMoneda?: number;
        idUnidadMedida?: number;
        codigoArticulo?: string;
        nombreArticulo?: string;
        descripcion?: string;
        precioUltimaCompra?: number;
        precioVenta?: number;
        cantidadStock?: number;
        cantidadMinima?: number;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/articulos/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/articulos/eliminar/${id}`, { method: "DELETE" }),

    /**
     * Sube la imagen del artículo. El archivo va como cuerpo crudo del PUT y su
     * tipo en el Content-Type — no es multipart. Mismo mecanismo que
     * `empresas.subirLogo`.
     */
    subirImagen: (id: number, archivo: File) =>
      request<{ ok: boolean }>(`/articulos/imagen/${id}`, {
        method: "PUT",
        headers: { "Content-Type": archivo.type },
        body: archivo,
      }),
  },
};
