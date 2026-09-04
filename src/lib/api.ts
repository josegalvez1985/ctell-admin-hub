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
const SUCURSAL_KEY = "ctell-sucursal";

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

/**
 * `true` si el artículo es un gasto y no un bien de stock.
 *
 * Reusa el tipo `Rol` porque la columna `ARTICULOS.ES_GASTO` es el mismo
 * `VARCHAR2(1)` con `'S'`/`'N'` que `USUARIOS.ES_ADMIN`. El helper existe
 * aparte para que la pregunta se lea en el idioma de quien la hace —
 * `esGasto(a.esGasto)` y no `esAdmin(a.esGasto)`, que confundiría a cualquiera
 * leyendo la pantalla de artículos.
 */
export function esGasto(marca: Rol | undefined): boolean {
  return marca === "S";
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

/**
 * Marca de un artículo (Sony, LG, Nike).
 *
 * **No tiene `activo`**: es la única tabla del proyecto sin columna de estado,
 * así que no hay baja lógica — se elimina o no existe.
 */
export type Marca = {
  id: number;
  descripcion: string;
  /**
   * Empresa dueña, o `null` si es **heredada**.
   *
   * `MARCAS.ID_EMPRESA` se agregó después de que la tabla estuviera en uso: las
   * filas anteriores la tienen vacía y el backend se las ofrece a **todas** las
   * empresas, para que no desaparezcan del combo ni dejen huérfanos a los
   * artículos que ya las usan.
   */
  idEmpresa: number | null;
};

export type ListaMarcas = {
  items: Marca[];
  total: number;
};

/**
 * Código alternativo de un artículo: el del fabricante, el del proveedor, el
 * del catálogo del vehículo.
 *
 * Un repuesto casi nunca se pide por el código interno, así que un artículo
 * tiene varios de estos y se lo puede encontrar por cualquiera.
 *
 * **El código se guarda normalizado** (mayúsculas, sin espacios de sobra): el
 * `UNIQUE` del DDL es sobre el texto crudo, y sin normalizar `abc` y `ABC`
 * entrarían como dos códigos distintos del mismo artículo.
 */
export type CodigoEquivalente = {
  id: number;
  idEmpresa: number;
  idArticulo: number;
  /** Nombre del artículo: viene del JOIN, para la búsqueda por código. */
  articulo: string;
  codigoArticulo: string | null;
  codigoEquivalente: string;
  descripcion: string | null;
};

export type ListaCodigosEquivalentes = {
  items: CodigoEquivalente[];
  total: number;
};

export type CanalPago = {
  id: number;
  nombreCanal: string;
  descripcion: string | null;
  /**
   * `'S'` si el canal mueve dinero por un banco y hay que pedir la cuenta
   * receptora al cobrar; `'N'` si es efectivo. Es un dato de la tabla, no una
   * suposición sobre el nombre.
   */
  indBanco: "S" | "N";
  activo: Estado;
};

export type ListaCanalesPagos = {
  items: CanalPago[];
  total: number;
};

/**
 * Si al cobrar por este canal hay que pedir la cuenta bancaria receptora.
 *
 * Lee `IND_BANCO` de la tabla. Antes esto era un `idCanalPago !== "1"` escrito a
 * mano en las dos pantallas de cobro, y después una heurística sobre el nombre
 * (`/efectivo|caja/`) que se rompía con un renombre. Ahora es un dato.
 *
 * Un canal sin el indicador cargado se trata como efectivo: pedir una cuenta que
 * no corresponde bloquea un cobro válido, mientras que no pedirla sólo deja el
 * dato vacío en un cobro que igual queda registrado.
 */
export function requiereCuentaBancaria(canal: CanalPago | undefined): boolean {
  return canal?.indBanco === "S";
}

export type Banco = {
  id: number;
  nombreBanco: string;
  descripcion: string | null;
  activo: Estado;
};

export type ListaBancos = {
  items: Banco[];
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

/**
 * Institución de una empresa: un colegio, un hospital, una municipalidad.
 *
 * Tiene estado activo/inactivo. La baja física queda reservada para cargas
 * equivocadas; la operación normal es inactivar.
 *
 * LA GEOGRAFÍA VIENE DESNORMALIZADA: guarda país, departamento y ciudad aunque
 * el país se deduzca del departamento. El backend valida que la cadena sea
 * coherente (`PAISES ← DEPARTAMENTOS ← CIUDADES`) antes de escribir, porque las
 * FK sólo garantizan que cada fila exista, no que tengan que ver entre sí.
 */
export type Institucion = {
  id: number;
  /**
   * Empresa dueña de la institución. Sale de la empresa activa de la sesión, no
   * de un combobox.
   *
   * No hay campo `empresa` con el nombre: el listado siempre viene filtrado por
   * una sola empresa, así que sería la misma constante en todas las filas.
   */
  idEmpresa: number;
  /** Opcional. El nombre viene del LEFT JOIN contra PAISES. */
  idPais: number | null;
  pais: string | null;
  /** Opcional. El nombre viene del LEFT JOIN contra DEPARTAMENTOS. */
  idDepartamento: number | null;
  departamento: string | null;
  /**
   * **Opcional**: el DDL la deja nullable. Una institución rural puede no tener
   * ciudad asignada. Por eso el JOIN contra CIUDADES es LEFT y `ciudad` llega
   * null cuando no hay.
   */
  idCiudad: number | null;
  ciudad: string | null;
  nombreInstitucion: string;
  direccion: string | null;
  director: string | null;
  contacto: string | null;
  correo: string | null;
  /**
   * Ubicación geográfica en **texto libre** — coordenadas, un link de mapa, una
   * referencia. No tiene relación con la tabla `UBICACIONES`, que son
   * posiciones dentro de un depósito.
   */
  ubicacion: string | null;
  activo: Estado;
};

export type ListaInstituciones = {
  items: Institucion[];
  total: number;
};

/**
 * Profesor de una empresa.
 *
 * Tiene estado activo/inactivo y puede vincularse opcionalmente con una cuenta
 * de USUARIOS.
 *
 * `numeroCi` es único en todo el sistema. `idUsuario` también se usa una sola
 * vez, aunque esa regla se valida en el paquete PL/SQL.
 */
export type Profesor = {
  id: number;
  /**
   * Empresa dueña del profesor. Sale de la empresa activa de la sesión, no de
   * un combobox.
   *
   * No hay campo `empresa` con el nombre: el listado siempre viene filtrado por
   * una sola empresa, así que sería la misma constante en todas las filas.
   */
  idEmpresa: number;
  /** Cédula. **Única en todo el sistema**, no sólo dentro de la empresa. */
  numeroCi: string;
  nombre: string;
  apellido: string;
  idUsuario: number | null;
  usuario: string | null;
  activo: Estado;
  tieneFoto: boolean;
  direccion: string | null;
  telefono: string | null;
  correo: string | null;
};

export type ListaProfesores = {
  items: Profesor[];
  total: number;
};

/**
 * Una marcación de asistencia: **una fila por entrada/salida, no por día.**
 *
 * El UNIQUE de la tabla es sobre las claves de entrada y salida, no sobre
 * (profesor, fecha): un profesor puede marcar varias veces el mismo día. La
 * pantalla las agrupa por fecha para armar la grilla.
 */
export type AsistenciaProfesor = {
  id: number;
  idProfesor: number;
  profesor: string;
  numeroCi: string;
  idInstitucion: number;
  /** `null` si la institución fue borrada. */
  institucion: string | null;
  /** ISO `YYYY-MM-DD`. */
  fecha: string;
  /** `HH:MM`, o `null` si todavía no marcó. */
  horaEntrada: string | null;
  horaSalida: string | null;
  /**
   * Minutos entre entrada y salida.
   *
   * **`null` significa incompleto**, no cero: falta una de las dos marcas. Un 0
   * sería una jornada de duración nula, que es un caso distinto y hay que poder
   * distinguirlo para marcarlo en el reporte.
   *
   * Vienen en minutos y no en horas porque la conversión depende de la duración
   * de la hora cátedra, que se carga en la pantalla.
   */
  minutos: number | null;
  /** `'S'` si se marcó sin conexión: la hora es la del teléfono, no la del servidor. */
  entradaOffline: "S" | "N";
  salidaOffline: "S" | "N";
  marcadoEnEntrada: string | null;
  marcadoEnSalida: string | null;
  latitud: string | null;
  longitud: string | null;
  latitudSalida: string | null;
  longitudSalida: string | null;
};

export type ListaAsistenciasProfesores = {
  items: AsistenciaProfesor[];
  total: number;
};

/**
 * Los tres tipos que acepta `REPORTES_MULTIMEDIA.TIPO_ARCHIVO`.
 *
 * **La misma lista está en `TIPO_VALIDO` de `db/reportes-multimedia.sql`**: el
 * DDL no tiene `CHECK` —sólo un `COMMENT`, que no es una restricción—, así que
 * si se agrega un tipo, van los dos.
 */
export const TIPOS_MULTIMEDIA = ["foto", "video", "documento"] as const;
export type TipoMultimedia = (typeof TIPOS_MULTIMEDIA)[number];

/** Máximos que acepta el backend. No son de negocio: son el techo del bind de
 * ORDS. Ver la cabecera de `db/reportes-actividades.sql`. */
export const MAX_DESCRIPCION_REPORTE = 2000;
export const MAX_PIE_MULTIMEDIA = 200;

export type ReporteMultimedia = {
  id: number;
  idReporte: number;
  tipoArchivo: TipoMultimedia;
  /** Pie de foto. Viaja entero: el backend lo limita a 200 al guardarlo. */
  descripcionTexto: string | null;
  /** URL en Cloudinary. El backend exige `https://`. */
  urlArchivo: string;
  nombreArchivo: string | null;
  tamanioBytes: number | null;
  fechaCreacion: string;
};

export type ListaReportesMultimedia = {
  items: ReporteMultimedia[];
  total: number;
  pagina: number;
  tamanio: number;
};

export type ReporteActividad = {
  id: number;
  idEmpresa: number;
  idProfesor: number;
  profesor: string;
  idInstitucion: number;
  /** `null` si la institución fue borrada. */
  institucion: string | null;
  /**
   * ISO `YYYY-MM-DD`. **No es editable**: es la fecha de la marcación de la que
   * cuelga el reporte. Ver `db/reportes-actividades.sql`.
   */
  fecha: string;
  idAsistencia: number;
  /** De la marcación, para ubicar el reporte en el día. `HH:MM` o `null`. */
  horaEntrada: string | null;
  horaSalida: string | null;
  /**
   * **En el listado viene recortada a 200 caracteres** y `truncada` vale `'S'`.
   * El formulario de edición tiene que cargarla con `obtener()`: guardar el
   * resumen escribiría 200 caracteres encima de los 2000.
   */
  descripcion: string | null;
  truncada: "S" | "N";
  cantidadMultimedia: number;
  fechaCreacion: string;
  fechaActualizacion: string;
};

export type ListaReportesActividades = {
  items: ReporteActividad[];
  total: number;
  pagina: number;
  tamanio: number;
};

/**
 * Los cuatro estados de una justificación de ausencia.
 *
 * **La columna `ESTADO_SOLICITUD` no tiene `CHECK`**: los valores viven en un
 * `COMMENT`, y un `COMMENT` no es una restricción. Esta lista es el espejo de
 * `ESTADO_VALIDO` en `db/justificaciones-ausencia.sql` — **si se agrega un
 * estado, van los dos**. Es la misma trampa que `GRADOS` en manuales.
 */
export const ESTADOS_JUSTIFICACION = ["PENDIENTE", "EN REVISION", "APROBADA", "RECHAZADA"] as const;

export type EstadoJustificacion = (typeof ESTADOS_JUSTIFICACION)[number];

/**
 * Una justificación de ausencia que mandó un profesor.
 *
 * **La escriben dos programas.** La solicitud la crea la app del profesor (otro
 * proyecto); el hub sólo la resuelve: estado, suplente y observaciones. Por eso
 * acá no hay `crear` ni `eliminar`, y el resto de los campos son de lectura.
 */
export type JustificacionAusencia = {
  id: number;
  /**
   * **La empresa del PROFESOR**, no la columna `ID_EMPRESA` de la fila: la app
   * la fija siempre en 1, así que el backend la ignora y filtra contra
   * `PROFESORES`. Es el mismo criterio que las marcaciones.
   */
  idEmpresa: number;
  idProfesor: number;
  profesor: string;
  idInstitucion: number;
  /** `null` sólo si la institución fue borrada. */
  institucion: string | null;
  materia: string | null;
  /** ISO `YYYY-MM-DD`. */
  fechaInicio: string;
  /** `null` significa **un solo día**, no "sin definir". */
  fechaFin: string | null;
  /**
   * Días que cubre la ausencia, **derivado de las fechas** — que es lo único
   * verificable. Puede no coincidir con `cantidadDeclarada`, y mostrar los dos
   * es justamente el punto.
   */
  dias: number;
  /** Texto libre que escribió el profesor: "2 días", "4 horas". */
  cantidadDeclarada: string | null;
  turno: string | null;
  cursos: string | null;
  /**
   * **En el listado viene recortado a 200 caracteres** y `motivoTruncado` vale
   * `'S'`. El diálogo de gestión carga con `obtener()`.
   */
  motivo: string | null;
  motivoTruncado: "S" | "N";
  /**
   * El respaldo en Cloudinary, **sólo si empieza con `https://`**. Lo escribió
   * otro programa y termina en un `<a href>`: un `javascript:` ahí sería un
   * enlace que ejecuta script, así que el backend no lo devuelve.
   */
  urlArchivo: string | null;
  /**
   * `'S'` si la columna tiene algo, aunque `urlArchivo` sea `null`. Con los dos
   * la pantalla distingue "no adjuntó nada" de "adjuntó algo que no se puede
   * abrir" — que es el caso que hay que ver, no esconder.
   */
  tieneArchivo: "S" | "N";
  /**
   * Normalizado y con `NVL` a `PENDIENTE`: la columna acepta NULL y una
   * solicitud sin estado es una pendiente.
   *
   * **Puede llegar un valor fuera de la unión.** No hay `CHECK` y la escribe
   * otro programa, así que quien lo pinte necesita un caso por defecto — se
   * muestra, aunque no se pueda filtrar.
   */
  estado: EstadoJustificacion;
  /** Lo sella el backend con el usuario del token la primera vez que se
   * gestiona. No se manda ni se edita. */
  recibidoPor: string | null;
  /** ISO `YYYY-MM-DD`. Sellada junto con `recibidoPor`, y nunca pisada después. */
  fechaRecepcion: string | null;
  suplente: string | null;
  /** **Recortadas a 200 en el listado.** Son editables: guardar la fila del
   * listado escribiría el resumen encima de los 1000 caracteres. */
  observaciones: string | null;
  observacionesTruncadas: "S" | "N";
  /**
   * Cuándo la mandó el profesor, **en su hora local**. `fechaCreacion` es el
   * UTC del servidor: no son el mismo reloj y no se comparan entre sí.
   */
  fechaEnvio: string | null;
  fechaCreacion: string | null;
  fechaActualizacion: string | null;
};

export type ListaJustificacionesAusencia = {
  items: JustificacionAusencia[];
  total: number;
  pagina: number;
  tamanio: number;
};

/**
 * Una marcación que todavía no tiene reporte.
 *
 * Sale de `/reportes-actividades/pendientes`, que es la resta entre las
 * marcaciones del período y los reportes ya cargados. No se deduce del listado:
 * habría que traerse las dos tablas enteras y restarlas en el navegador.
 */
export type AsistenciaSinReporte = {
  idAsistencia: number;
  idProfesor: number;
  profesor: string;
  idInstitucion: number;
  institucion: string | null;
  fecha: string;
  horaEntrada: string | null;
  horaSalida: string | null;
};

/**
 * Un par (profesor, institución) que tiene marcaciones.
 *
 * Es la relación que ninguna tabla guarda: la escribe el historial de
 * asistencias. Con ella, elegir un profesor deja el combo de institución sólo
 * con las que le corresponden.
 */
export type VinculoProfesorInstitucion = {
  idProfesor: number;
  idInstitucion: number;
};

export type ListaAsistenciasSinReporte = {
  items: AsistenciaSinReporte[];
  total: number;
  pagina: number;
  tamanio: number;
};

/**
 * Un mes que tiene marcaciones, con cuántas.
 *
 * Alimenta los combos del reporte. Viene de su propio endpoint y no se deduce
 * del listado: para saber qué meses del año tienen datos habría que pedir el
 * año entero —miles de marcaciones— y contarlas acá.
 */
export type PeriodoAsistencias = {
  anio: number;
  /** 1 a 12. */
  mes: number;
  cantidad: number;
};

/**
 * Los doce grados que admite `MANUALES.GRADO`.
 *
 * **La misma lista está en `GRADO_VALIDO` de `db/manuales.sql`**: acá para que
 * el selector los ofrezca, allá para que el endpoint los acepte. Si se agrega
 * un grado, van los dos.
 *
 * El DDL no tiene `CHECK`, sólo un `COMMENT` que los enumera — y un `COMMENT`
 * no es una restricción. Sin la validación del backend, `'1ro'` sin punto entra
 * como un grado distinto que el `UNIQUE (ID_INSTITUCION, GRADO)` deja pasar, y
 * la institución termina con dos manuales de primero.
 *
 * La capitalización es parte del valor y es irregular a propósito (`'1ro.'`
 * pero `'1ME.'`): no normalizar a mayúsculas ni a minúsculas.
 */
export const GRADOS = [
  "1ro.",
  "2do.",
  "3er.",
  "4to.",
  "5to.",
  "6to.",
  "7mo.",
  "8vo.",
  "9no.",
  "1ME.",
  "2ME.",
  "3ME.",
] as const;

export type Grado = (typeof GRADOS)[number];

/**
 * Un manual en PDF, de una institución y un grado.
 *
 * **La tabla no tiene `ID_EMPRESA`**: cuelga de `INSTITUCIONES`, que sí la
 * tiene, y el backend aísla por empresa con un JOIN contra el padre. Por eso
 * `idEmpresa` viaja en todas las llamadas aunque no sea una columna del manual
 * — incluido el `listar`, donde es **obligatorio**: sin él la consulta no se
 * acota sola y devolvería los manuales de todas las empresas.
 *
 * Tampoco tiene `ACTIVO`: la baja es física. Un manual que ya no corre se
 * reemplaza por el del mismo grado (el `UNIQUE` lo garantiza) o se borra.
 */
export type Manual = {
  id: number;
  idInstitucion: number;
  /** Nombre de la institución, del JOIN. */
  institucion: string;
  grado: Grado;
  /**
   * `false` mientras no se haya subido el PDF — el alta crea la fila y el
   * archivo va después, así que es un estado normal y transitorio.
   *
   * Se calcula con `GETLENGTH > 0` y no con `IS NOT NULL`: un BLOB vacío no
   * sirve como archivo y haría fallar la descarga.
   */
  tieneArchivo: boolean;
  /** Peso del PDF. `0` si todavía no se subió. */
  bytesArchivo: number;
  /**
   * Cuándo entró el PDF, no cuándo se tocó la fila: la mueve el alta y cada
   * subida del archivo, pero **no** una corrección del grado.
   */
  fechaCarga: string | null;
  /** Cualquier cambio de la fila, incluido corregir el grado. */
  fechaActualizacion: string | null;
};

export type ListaManuales = {
  items: Manual[];
  total: number;
};

/**
 * Si el profesor leyó la notificación.
 *
 * **`'S'`/`'N'`, no `'A'`/`'I'`**: rompe la convención del proyecto a propósito,
 * porque no es el estado de la fila —una lectura no se da de baja— sino la
 * respuesta a "¿la leyó?". Mismo criterio que `IND_BANCO` en `CANALES_PAGOS` y
 * que `entradaOffline` acá al lado. **`esActivo()` no aplica**: se compara
 * contra `'S'` directo.
 */
export type Leido = "S" | "N";

/** Un profesor al que se le mandó una notificación, con su estado de lectura. */
export type DestinatarioNotificacion = {
  idProfesor: number;
  /** "Nombre Apellido", del JOIN. `null` sólo si el profesor se borró. */
  profesor: string | null;
  numeroCi: string | null;
  leido: Leido;
  /** ISO con hora. `null` mientras no la haya abierto. */
  fechaLectura: string | null;
};

/**
 * Un aviso enviado a profesores desde administración.
 *
 * Es **cabecera y detalle**, como una factura: la notificación y sus
 * destinatarios se guardan en una sola transacción. Una notificación sin
 * destinatarios no le llegó a nadie, así que el backend la rechaza.
 */
export type Notificacion = {
  id: number;
  idEmpresa: number;
  titulo: string;
  /**
   * Los primeros 150 caracteres nada más — el listado la recorta por el techo
   * de 4000 bytes del bind de ORDS.
   *
   * **No la mandes de vuelta en un PUT**: escribiría el resumen encima del
   * mensaje completo. Para editar, `obtener()`.
   */
  descripcionResumen: string | null;
  /** ISO con hora: cuándo se envió. */
  fechaNotificacion: string | null;
  fechaCreacion: string | null;
  /**
   * Cuántos la recibieron y cuántos la leyeron. **Se derivan** contando el
   * detalle en cada consulta, no se guardan: una columna con el total quedaría
   * desincronizada el día que alguien toque el detalle. Mismo criterio que los
   * totales de una factura.
   */
  destinatarios: number;
  leidos: number;
};

export type ListaNotificaciones = {
  items: Notificacion[];
  /** Las filas que pasan el filtro, **no** las de esta página. */
  total: number;
  pagina: number;
  /** El que el backend aplicó, que pudo recortarse al techo de 50. */
  tamanio: number;
};

/**
 * Una notificación con su `descripcion` COMPLETA y la lista de destinatarios.
 *
 * Es lo que devuelve `obtener()`, y lo que tiene que cargar el formulario de
 * edición: guardar el resumen del listado perdería el resto del mensaje sin
 * ningún error a la vista.
 */
export type NotificacionDetalle = Omit<Notificacion, "descripcionResumen" | "destinatarios"> & {
  descripcion: string | null;
  destinatarios: DestinatarioNotificacion[];
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

export type Talonario = {
  id: number;
  idEmpresa: number;
  idSucursal: number;
  tipoComprobante: "FCO" | "FCR" | "NCR";
  nroTimbrado: string;
  establecimiento: string;
  puntoExpedicion: string;
  nroInicial: number;
  nroFinal: number;
  nroActual: number;
  fechaInicio: string | null;
  fechaVencimiento: string | null;
  activo: Estado;
};

export type ListaTalonarios = {
  items: Talonario[];
  total: number;
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

export type CuentaBancaria = {
  id: number;
  idEmpresa: number;
  idBanco: number;
  banco: string;
  numeroCuenta: string;
  tipoCuenta: string | null;
  titular: string | null;
  saldoInicial: number | null;
  idMoneda: number | null;
  moneda: string | null;
  activo: Estado;
};

export type ListaCuentasBancarias = {
  items: CuentaBancaria[];
  total: number;
};

/**
 * Denominación de una moneda: el billete de 50.000, la moneda de 500.
 *
 * MONEDAS es la cabecera y esto el detalle. Sirve para los cierres de caja,
 * donde se cuenta por denominación y la foto ayuda a identificarla.
 *
 * A diferencia del resto de las tablas **no tiene estado `activo`**: el DDL no
 * trae la columna, así que la baja es física. Una denominación existe o no.
 */
export type DetalleMoneda = {
  id: number;
  /** Moneda a la que pertenece. Sale de la cabecera, no de un combobox. */
  idMoneda: number;
  denominacion: string;
  /**
   * Si tiene foto cargada. El binario no viaja en este JSON: se pide aparte con
   * `urlFotoDetalleMoneda(id)` y se sube con `api.detalleMonedas.subirFoto`.
   */
  tieneFoto: boolean;
};

export type ListaDetalleMonedas = {
  items: DetalleMoneda[];
  total: number;
};

/**
 * Ubicación física del depósito: zona, estante y nivel.
 *
 * Cuelga de la empresa **y** de la sucursal: los dos ids salen de los providers
 * globales (`useEmpresa()` y `useSucursal()`), no de combobox del formulario.
 *
 * No tiene estado `activo` —el DDL no trae la columna— así que la baja es
 * física, igual que en `DetalleMoneda`.
 */
export type Ubicacion = {
  id: number;
  idEmpresa: number;
  idSucursal: number;
  /** Se guarda en mayúsculas: "a1" y "A1" son la misma ubicación física. */
  zona: string;
  estante: number;
  nivel: number;
  descripcion: string | null;
  /**
   * Cuántos artículos hay asignados a este estante.
   *
   * Viene siempre, se haya filtrado o no. Un 0 es un dato útil: dice que la
   * ubicación se puede borrar sin romper nada.
   */
  cantidadArticulos: number;
};

export type ListaUbicaciones = {
  items: Ubicacion[];
  total: number;
};

/**
 * Lista de descuentos de una empresa: "Lista Mayorista", "Lista Verano 2024".
 *
 * **No tiene columna `activo`**, y eso cambia cómo se la da de baja: acá la
 * vigencia la determinan las FECHAS. Una lista no se inactiva, se le pone
 * `fechaVigenciaHasta`. El borrado, como en `DetalleMoneda`, es físico.
 */
export type ListaDescuentos = {
  id: number;
  /**
   * Empresa dueña de la lista. Sale de la empresa activa de la sesión, no de un
   * combobox: cada empresa tiene su propio juego de listas.
   *
   * No hay campo `empresa` con el nombre: el listado siempre viene filtrado por
   * una sola empresa, así que sería la misma constante en todas las filas.
   */
  idEmpresa: number;
  /** Único dentro de la empresa. Dos empresas sí pueden repetirlo. */
  nombreLista: string;
  /**
   * Descuento general de la lista, en **porcentaje**: `10` es 10%, no 0.10.
   * Nunca llega null — el backend lo resuelve a 0, que es lo que "sin
   * descuento" significa.
   */
  porcentajeDescuento: number;
  /**
   * Fechas en ISO **sólo día** ("2026-04-03"), sin hora: una vigencia es un día
   * del calendario. `fechaVigenciaHasta` es null cuando la lista rige
   * indefinidamente.
   */
  fechaVigenciaDesde: string;
  fechaVigenciaHasta: string | null;
  /**
   * Si la lista rige **hoy**, resuelto por el backend contra las dos fechas
   * (ambos extremos inclusive).
   *
   * **Calculado, no guardado:** no existe como columna. Viene con el mismo
   * código `'A'`/`'I'` del resto del proyecto para poder tratarlo igual que
   * cualquier otro estado —`esActivo(x.vigente)`— aunque no salga de un
   * `ACTIVO`. No se manda al crear ni al actualizar: cambiarlo significa mover
   * las fechas.
   */
  vigente: Estado;
};

export type ListaListasDescuentos = {
  items: ListaDescuentos[];
  total: number;
};

/**
 * Tipo de persona, con el mismo código de una letra que guarda la columna:
 * `"F"` física, `"J"` jurídica. Sigue el criterio de `Estado` y `Rol` — el
 * código viaja igual de punta a punta, sin traducirse.
 */
export type TipoPersona = "F" | "J";

/** `true` si es una persona jurídica (empresa). */
export function esJuridica(tipo: TipoPersona | undefined): boolean {
  return tipo === "J";
}

/**
 * Una persona del padrón: física o jurídica.
 *
 * **Es un catálogo global**, sin `idEmpresa`: el padrón es uno solo y lo
 * comparten todas las empresas, igual que países o ciudades. La misma persona
 * puede ser cliente de una y proveedor de otra sin cargarse dos veces.
 *
 * **No tiene `activo`**: la tabla no lleva esa columna, así que la única baja es
 * física. Cuando existan compras o ventas apuntando acá, borrar a alguien con
 * movimientos va a dar 409.
 */
export type Persona = {
  id: number;
  tipoPersona: TipoPersona;
  /**
   * En una física, el nombre de pila. En una jurídica llega **una copia de la
   * razón social**: la columna es NOT NULL en la base y una empresa no tiene
   * nombre de pila. Para mostrar, usá `nombreCompleto`.
   */
  nombre: string;
  /** Null en las jurídicas: el backend filtra el relleno que guarda la base. */
  apellido: string | null;
  /** Sólo en las jurídicas. Null en las físicas. */
  razonSocial: string | null;
  /**
   * El nombre que se muestra, ya resuelto por el backend: razón social si es
   * jurídica, "Nombre Apellido" si es física.
   *
   * **Usá este y no armes la concatenación en la pantalla** — la regla de qué
   * campo corresponde según el tipo vive en un solo lugar.
   */
  nombreCompleto: string;
  /** Únicos si están cargados, pero los dos pueden ser null. */
  numeroCi: string | null;
  ruc: string | null;
  email: string | null;
  telefono: string | null;
  direccion: string | null;
};

export type ListaPersonas = {
  items: Persona[];
  total: number;
};

/**
 * Una tasa de IVA.
 *
 * **Editar una tasa en uso cambia facturas ya emitidas**: el impuesto de cada
 * línea no se guarda, se calcula como `subtotal / ivaDivision` en cada consulta.
 * Cambiar el porcentaje o el divisor altera el desglose de todo lo que ya la
 * usaba, incluidos períodos ya declarados. Por eso `usos` viaja en el listado.
 */
export type Iva = {
  id: number;
  /** La tasa nominal: 10, 5, 0. Es lo que se muestra. */
  porcentaje: number;
  /**
   * El **divisor** para desglosar el impuesto de un precio que ya lo incluye:
   * 11 para el 10%, 21 para el 5%, y **0 en la exenta**.
   *
   * Los precios de este sistema incluyen IVA, así que el impuesto de un monto
   * es `subtotal / ivaDivision` — **no** `subtotal * porcentaje / 100`, que
   * cobraría impuesto sobre impuesto.
   *
   * Cuidado al dividir: en la exenta vale 0.
   */
  ivaDivision: number;
  /**
   * El divisor de la **base imponible**: 1,1 para el 10%, 1,05 para el 5%, y
   * **1 en la exenta** (el monto entero es gravado).
   *
   * Es `1 + porcentaje/100`, el complemento de `ivaDivision`. Cuando está
   * cargado, el desglose se hace `gravado = subtotal / gravadaDivision` y el IVA
   * sale por resta — así `gravado + iva` da el total exacto, sin diferencias de
   * redondeo.
   *
   * **`null` en las tasas cargadas antes de que existiera la columna**: ahí el
   * backend cae al método anterior. Ojo con el criterio opuesto de la exenta
   * frente a `ivaDivision`, que en ese caso vale 0.
   */
  gravadaDivision: number | null;
  descripcion: string;
  /**
   * Cuántas líneas de factura la usan.
   *
   * Con `usos > 0`, editarla cambia esas facturas y borrarla da 409. La pantalla
   * lo muestra antes de dejar editar, para que la decisión sea informada.
   */
  usos: number;
};

export type ListaIva = {
  items: Iva[];
  total: number;
};

/**
 * Una condición de pago: contado, 30 días, 3 cuotas.
 *
 * **Catálogo global**, sin `idEmpresa`: las condiciones son las mismas para
 * todas las empresas.
 */
export type CondicionPago = {
  id: number;
  nombreCondicion: string;
  /** Días para pagar desde la fecha de la factura. **0 es contado.** */
  diasPago: number;
  /** En cuántas veces se paga. **1 es pago único.** */
  cantidadCuotas: number;
  /**
   * Cuántas facturas la usan. Con `usos > 0` no se puede borrar: lo impide la
   * FK, y el backend devuelve 409 con la cantidad en el mensaje.
   */
  usos: number;
};

export type ListaCondicionesPago = {
  items: CondicionPago[];
  total: number;
};

/** Una línea del detalle de una factura de compra. */
export type FacturaCompraDetalle = {
  id: number;
  idArticulo: number;
  /** Del JOIN contra ARTICULOS. */
  nombreArticulo: string;
  codigoArticulo: string | null;
  cantidad: number;
  /** **Incluye IVA**: es el precio final de la línea. */
  precioUnitario: number;
  /**
   * `cantidad * precioUnitario`. Es una **columna virtual** en la base: la
   * calcula Oracle y no se puede escribir, así que nunca queda desincronizada.
   */
  subtotal: number;
  idIva: number | null;
  porcentajeIva: number | null;
  descripcionIva: string | null;
  /** El impuesto **contenido** en el subtotal, ya calculado por el backend. */
  montoIva: number;
  /** El subtotal menos su impuesto. */
  montoGravado: number;
};

/**
 * La cabecera de una factura de compra, como la devuelve el listado.
 *
 * **No trae el detalle**: cien facturas con todas sus líneas serían un JSON
 * enorme para dibujar una tabla que sólo muestra encabezados. Para las líneas
 * está `api.facturasCompras.obtener()`.
 */
export type FacturaCompra = {
  id: number;
  idEmpresa: number;
  idSucursal: number;
  nombreSucursal: string;
  idProveedor: number;
  /** Ya resuelto según el tipo de persona, igual que `Persona.nombreCompleto`. */
  proveedor: string;
  rucProveedor: string | null;
  numeroFactura: string;
  /** ISO de sólo día ("2026-08-19"). */
  fechaFactura: string;
  idMoneda: number;
  moneda: string;
  simboloMoneda: string | null;
  tipoCambio: number;
  /**
   * Cómo se paga. **Opcional**: una factura sin condición cargada es válida, y
   * lo son todas las anteriores a que existiera la columna. Los tres campos
   * siguientes son null cuando no hay condición.
   */
  idCondicion: number | null;
  condicionPago: string | null;
  diasPago: number | null;
  /**
   * `fechaFactura + diasPago`, en ISO. **Lo calcula el backend**: guardarlo
   * dejaría un dato que queda desfasado si se corrige la fecha o la condición.
   *
   * `null` sin condición — "no se sabe cuándo vence" no es lo mismo que "vence
   * el mismo día".
   */
  fechaVencimiento: string | null;
  observacion: string | null;
  /**
   * La suma del detalle, **calculada por el backend en cada consulta**. No es
   * una columna: guardarla permitiría que la cabecera diga un número y sus
   * líneas sumen otro.
   *
   * Los precios ya incluyen IVA, así que este es el total a pagar — no hay que
   * sumarle el impuesto aparte.
   */
  total: number;
  /** Cuántas líneas tiene, para mostrarlo sin traer el detalle. */
  lineas: number;
  /** Suma de los pagos registrados. Derivado, no es una columna. */
  montoPagado: number;
  /** `total - montoPagado`. En 0 la factura está saldada. */
  saldoPendiente: number;
  /**
   * **Sin `tieneSalidas`**: salía de comparar el disponible de los lotes que
   * creaba la compra, y la compra ya no crea lotes ni mueve stock. Lo único que
   * congela una factura son sus pagos.
   */
};

/** Una cuota del plan de pago de una factura de compra. */
export type CuotaCompra = {
  id: number;
  nroCuota: number;
  fechaVencimiento: string;
  montoCuota: number;
  montoPagado: number;
  saldoPendiente: number;
  /** Los valores del CHECK del DDL. Ojo: `PAGADA`, no `PAGADO` como en ventas. */
  estado: "PENDIENTE" | "PARCIAL" | "PAGADA" | "VENCIDA";
};

export type PagoCompra = {
  id: number;
  idFactura: number;
  idCuota: number | null;
  nroCuota: number | null;
  idCanalPago: number;
  /** De LEFT JOIN: `null` si el canal, la cuenta o el banco se borraron después. */
  canalPago: string | null;
  idMoneda: number;
  idCuentaBancaria: number | null;
  banco: string | null;
  numeroCuenta: string | null;
  monto: number;
  fechaPago: string;
  referencia: string | null;
  observacion: string | null;
};

export type ListaPagosCompras = { items: PagoCompra[] };

/**
 * Los indicadores de la home. El mes es el **calendario en curso**, no 30 días
 * móviles: se compara contra el cierre del mes pasado, no contra una ventana
 * que se corre sola.
 */
export type ResumenDashboard = {
  ventasMes: number;
  ventasMesAnterior: number;
  comprasMes: number;
  comprasMesAnterior: number;
  /** Lo que queda en los lotes por lo que costó, no por lo que se vende. */
  valorStock: number;
  unidadesStock: number;
  /** Artículos con stock por debajo de su mínimo. El único que pide una acción. */
  articulosBajoMinimo: number;
  /**
   * Cuotas de compra con saldo que vencen dentro de `diasPorVencer` — incluidas
   * las ya vencidas. Se cuentan cuotas y no facturas: lo que hay que pagar el
   * viernes es una cuota, no la factura entera.
   */
  cuotasPorVencer: number;
  montoPorVencer: number;
  diasPorVencer: number;
  /** Debajo de cuántas unidades un artículo entra en stock crítico. */
  umbralCritico: number;
  /**
   * Ventas, compras e inventarios en una sola lista por fecha. Se unen en el
   * backend porque cada origen está paginado por su lado: mezclar tres primeras
   * páginas no da los últimos movimientos, da los últimos de cada uno.
   */
  movimientos: Array<{
    tipo: "Venta" | "Compra" | "Inventario";
    documento: string;
    parte: string;
    monto: number;
    /** `'S'` en los inventarios: el monto son unidades, no plata. */
    enUnidades: "S" | "N";
    fecha: string;
    estado: string;
  }>;
  stockCritico: Array<{
    idArticulo: number;
    articulo: string;
    codigo: string | null;
    disponible: number;
    cantidadMinima: number | null;
  }>;
};

/** La factura completa: cabecera, totales desglosados y sus líneas. */
export type FacturaCompraCompleta = Omit<FacturaCompra, "lineas"> & {
  /** Sólo en el detalle: el listado no lo trae. Null sin condición. */
  cantidadCuotas: number | null;
  /** El IVA contenido en el total. Para el libro de compras. */
  totalIva: number;
  /** El total menos el IVA. */
  totalGravado: number;
  detalle: FacturaCompraDetalle[];
  /** El plan de pago que generó la condición. Vacío en una factura al contado. */
  cuotas: CuotaCompra[];
};

export type ListaFacturasCompras = {
  items: FacturaCompra[];
  total: number;
};

export type VentaDetalle = {
  id: number;
  idArticulo: number;
  idIva: number | null;
  cantidad: number;
  precioUnitario: number;
  subtotal: number;
  porcentajeDescuento: number;
  montoDescuento: number;
  /** La base imponible: el neto menos el IVA que ya venía dentro del precio. */
  montoGravado: number;
  montoIva: number;
  total: number;
  articulo: string | null;
  /**
   * **Sin lote.** La línea ya no guarda de qué partida salió: el stock por lotes
   * se discontinuó y `VENTAS_DETALLES.ID_LOTE` no existe más en el DDL.
   */
};

export type Venta = {
  id: number;
  idEmpresa: number;
  idSucursal: number;
  idCliente: number | null;
  cliente: string | null;
  numeroVenta: string;
  fechaVenta: string;
  tipoComprobante: "FCO" | "FCR" | "NCR";
  idTalonario: number;
  nroTimbrado: string;
  establecimiento: string;
  puntoExpedicion: string;
  nroComprobante: number;
  idMoneda: number;
  /**
   * Los montos **no son columnas de la cabecera**: el backend los deriva
   * sumando el detalle en cada consulta. Guardarlos además dejaría que la
   * cabecera diga 500.000 mientras sus líneas suman 480.000.
   */
  montoSubtotal: number;
  montoDescuento: number;
  /** Base imponible: el total menos el IVA que ya venía dentro del precio. */
  montoGravado: number;
  /**
   * El IVA **contenido** en `montoTotal`, no un importe a sumarle: los precios
   * ya lo incluyen, igual que en compras. `montoGravado + montoIva` da
   * `montoTotal` exacto.
   */
  montoIva: number;
  montoTotal: number;
  observacion: string | null;
  lineas: number;
  /** Suma de los cobros registrados. Lo deriva el backend, no es una columna. */
  montoCobrado: number;
  /**
   * `montoTotal - montoCobrado`. En 0 la venta está saldada y el backend
   * rechaza cobrarla de nuevo — la UI no debería ofrecer el botón.
   */
  saldoPendiente: number;
};

export type VentaCompleta = {
  cabecera: Omit<Venta, "cliente" | "lineas"> & {
    /** `null` en las ventas hechas sin lista, a precio de etiqueta. */
    idListaDescuentos: number | null;
    idCondicionPago: number;
  };
  detalle: VentaDetalle[];
  cuotas: Array<{
    id: number;
    nroCuota: number;
    fechaVencimiento: string;
    montoCuota: number;
    montoPagado: number;
    saldoPendiente: number;
    estado: string;
  }>;
};

export type ListaVentas = { items: Venta[]; total: number };

export type VentaCobro = {
  id: number;
  idVenta: number;
  idCuota: number | null;
  /** Número de la cuota imputada. `null` si el cobro fue contra la venta entera. */
  nroCuota: number | null;
  idCanalPago: number;
  /**
   * Los nombres vienen de LEFT JOIN y son `null` si el canal, la cuenta o el
   * banco se borraron después. El cobro sigue en el historial igual: pasó.
   */
  canalPago: string | null;
  idMoneda: number;
  idCuentaBancaria: number | null;
  banco: string | null;
  numeroCuenta: string | null;
  monto: number;
  fechaCobro: string;
  referencia: string | null;
  observacion: string | null;
};

export type ListaVentasCobros = { items: VentaCobro[] };

/**
 * Cuánto hay de un artículo en una sucursal.
 *
 * **Una fila por (empresa, sucursal, artículo)** — es el `UNIQUE` de la tabla, y
 * lo que reemplazó al stock repartido en lotes: en el estante las unidades son
 * idénticas y nadie sabe de qué compra vino cada una.
 *
 * La fila **puede no existir**: un artículo que nunca tuvo movimiento en esa
 * sucursal no tiene ninguna, que no es lo mismo que tener 0 aunque se muestre
 * igual. Por eso el listado de artículos usa `cantidadStock` con `NVL` en vez de
 * cruzar contra esto.
 */
export type Existencia = {
  id: number;
  idEmpresa: number;
  idSucursal: number;
  /** Del JOIN. `null` sólo si la sucursal se borró. */
  sucursal: string | null;
  idArticulo: number;
  nombreArticulo: string;
  codigoArticulo: string | null;
  /** Nunca `null`: el backend ya aplica `NVL(..., 0)`. */
  cantidadDisponible: number;
  /** Del artículo, para poder marcar lo que está por debajo. */
  cantidadMinima: number | null;
  /**
   * ISO con hora. Lo único que distingue una existencia viva de una que quedó
   * quieta hace meses. `null` mientras nada la haya movido.
   */
  fechaUltimoMovimiento: string | null;
};

export type ListaExistencias = {
  items: Existencia[];
  /** Las filas que pasan el filtro, **no** las de esta página. */
  total: number;
  pagina: number;
  /** El que el backend aplicó, que pudo recortarse al techo de 50. */
  tamanio: number;
};

/**
 * Estado de un conteo físico.
 *
 * `PROCESADO` es **legado**: describe el efecto que el conteo tenía cuando el
 * stock vivía en lotes, y ninguna transición lo produce hoy. Está en el tipo
 * porque las filas históricas pueden traerlo y la pantalla tiene que poder
 * mostrarlas.
 */
export type EstadoInventario = "ABIERTO" | "CERRADO" | "ANULADO" | "PROCESADO";

/**
 * Un conteo físico: cuánto hay REALMENTE de un artículo en una sucursal.
 *
 * Es la única corrección de `EXISTENCIAS` que existe hoy. Al cerrarse,
 * `CANTIDAD_DISPONIBLE` pasa a valer `cantidadFisica` — lo escribe un trigger,
 * no el paquete.
 *
 * **Sin lotes.** Un conteo es por artículo y depósito, no por partida: en el
 * estante las unidades son idénticas y nadie sabe de qué compra vino cada una,
 * que es justamente lo que hacía imposible contar con el modelo viejo.
 */
export type Inventario = {
  id: number;
  idEmpresa: number;
  idSucursal: number;
  /** Del JOIN. `null` sólo si la sucursal se borró. */
  sucursal: string | null;
  idArticulo: number;
  nombreArticulo: string;
  codigoArticulo: string | null;
  /**
   * Del JOIN contra `MARCAS`. `null` si el artículo no tiene una asignada.
   *
   * Va porque **la marca identifica la pieza**: dos artículos llamados "Filtro
   * de aceite" son cosas distintas según de quién sean, y en un conteo lo que
   * se tiene en la mano es la pieza. Es también el dato con el que se lo eligió
   * en la lista de valores.
   */
  marca: string | null;
  /**
   * Del JOIN contra `CATEGORIAS`. `null` si el artículo no tiene una asignada.
   *
   * Mismo criterio que `marca`: el diálogo de conteo ofrece completarla ahí
   * mismo si falta.
   */
  categoria: string | null;
  /**
   * Lo contado en el estante. `null` mientras la planilla esté abierta y nadie
   * haya ido al depósito todavía — por eso no se puede cerrar así.
   */
  cantidadFisica: number | null;
  /**
   * Lo que el sistema decía **al cerrar**, sellado por el trigger. `null` en
   * los abiertos: todavía no hay ajuste que explicar.
   *
   * Es contra esto que se mide la diferencia de un conteo cerrado. Contra
   * `existenciaActual` daría cero siempre, porque el cierre las igualó.
   */
  cantidadSistema: number | null;
  /**
   * Lo que `EXISTENCIAS` dice **ahora**, leído en vivo. Nunca `null`: el
   * backend ya aplica `NVL(..., 0)`.
   *
   * Es el número contra el que se compara **mientras se cuenta**.
   */
  existenciaActual: number;
  estado: EstadoInventario;
  /** ISO con hora: cuándo se contó. */
  fechaInventario: string | null;
  /** ISO con hora. En un conteo cerrado, cuándo se aplicó. */
  fechaActualizacion: string | null;
  idUsuario: number | null;
  /** Quién contó, del JOIN. Un ajuste de stock sin firma no se le puede preguntar a nadie. */
  usuario: string | null;
  /**
   * Los primeros 150 caracteres nada más — el listado la recorta.
   *
   * **No la mandes de vuelta en un PUT**: escribiría el resumen encima del
   * texto completo. Para editar, `obtener()`, que trae `observaciones` entera.
   */
  observacionesResumen: string | null;
};

export type ListaInventarios = {
  items: Inventario[];
  /** Las filas que pasan el filtro, **no** las de esta página. */
  total: number;
  pagina: number;
  /** El que el backend aplicó, que pudo recortarse al techo de 50. */
  tamanio: number;
};

/**
 * Un conteo con su observación completa. Es lo que devuelve `obtener()`, y lo
 * que tiene que cargar el formulario de edición.
 */
export type InventarioDetalle = Omit<Inventario, "observacionesResumen"> & {
  observaciones: string | null;
};

/** Lo que devuelve cerrar un conteo: cuánto se corrigió, sin volver a consultar. */
export type CierreInventario = {
  ok: boolean;
  /** Lo que el sistema decía antes del ajuste. */
  cantidadSistema: number | null;
  cantidadFisica: number;
  /** `cantidadFisica - cantidadSistema`. Negativa es faltante. */
  diferencia: number;
};

/**
 * Asignación de un artículo a una ubicación del depósito.
 *
 * Tabla de cruce pura: la fila **no tiene datos propios**, sólo une los dos ids.
 * Por eso no hay "actualizar" — reasignar es quitar y volver a asignar.
 *
 * A diferencia de las tablas por empresa, el listado SÍ trae los nombres del
 * artículo y de la ubicación: cada fila cruza dos entidades distintas, así que no
 * son una constante repetida.
 */
export type ArticuloUbicacion = {
  /** Id de la ASIGNACIÓN, no del artículo ni de la ubicación. */
  id: number;
  idArticulo: number;
  idUbicacion: number;
  /** Del artículo (JOIN). */
  codigoArticulo: string | null;
  nombreArticulo: string;
  /** De la ubicación (JOIN). */
  zona: string;
  estante: number;
  nivel: number;
  descripcion: string | null;
  /** Sucursal de la ubicación: un artículo puede estar en varias. */
  idSucursal: number;
  sucursal: string;
};

export type ListaArticulosUbicaciones = {
  items: ArticuloUbicacion[];
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
   * Las cuatro relaciones son OPCIONALES: un artículo puede cargarse sin
   * categoría, sin marca, sin moneda o sin unidad. Los nombres vienen del LEFT
   * JOIN, así que son null cuando el id lo es.
   */
  idCategoria: number | null;
  categoria: string | null;
  /**
   * Marca del artículo. `MARCAS` cuelga de la empresa, así que sólo se puede
   * asignar una de la empresa activa (o una heredada, sin empresa): el backend
   * rechaza el resto con 400.
   *
   * Null en todos los artículos cargados antes de que existiera la columna.
   */
  idMarca: number | null;
  marca: string | null;
  idMoneda: number | null;
  moneda: string | null;
  simboloMoneda: string | null;
  idUnidadMedida: number | null;
  unidadMedida: string | null;
  abreviaturaUnidad: string | null;
  /**
   * El código propio del artículo, que en repuestos es el **OEM**: el del
   * fabricante del vehículo. Es por el que se pide una pieza.
   */
  codigoArticulo: string | null;
  nombreArticulo: string;
  descripcion: string | null;
  /**
   * Los códigos con los que otros fabricantes llaman a la misma pieza, ya
   * concatenados y separados por comas: el backend los arma con `LISTAGG`, no
   * llega un array. Para gestionarlos uno por uno está `api.codigosEquivalentes`.
   *
   * La búsqueda del listado **sí** los mira, así que mostrarlos es lo que
   * explica por qué apareció un artículo cuyo nombre no se parece a lo escrito.
   */
  codigosEquivalentes: string | null;
  /**
   * Stock actual, sumado de `EXISTENCIAS` — una fila por artículo y sucursal.
   *
   * **Es el total de la empresa** salvo que se pida `idSucursal`, y ahí es el de
   * ese depósito. Un artículo sin ninguna fila de existencia llega en 0, no en
   * null: nunca tuvo movimiento, que para quien mira es lo mismo que no tener.
   *
   * Ojo: **nada lo mueve todavía**. Comprar y vender no tocan existencias
   * mientras no exista `PKG_STOCK`, así que el número es el que se haya cargado
   * en la tabla.
   *
   * Es de sólo lectura y no aparece en `crear` ni en `actualizar`: se mueve
   * cargando o consumiendo lotes, no editando la ficha del artículo.
   */
  cantidadStock: number;
  /**
   * A partir de cuánto avisar que falta. **Sí** se edita: es una política del
   * negocio, no una medición — por eso sobrevivió a la eliminación de
   * `cantidadStock` de la tabla.
   */
  cantidadMinima: number;
  /**
   * Si tiene imagen cargada. El binario no viaja en el JSON: se pide aparte
   * con `urlImagenArticulo(id)`.
   */
  tieneImagen: boolean;
  /**
   * Cuándo se contó físicamente el artículo por última vez. ISO
   * ("2026-08-17T10:30:00") o `null` si nunca se inventarió.
   *
   * **Sólo lectura.** No aparece en `crear` ni en `actualizar` a propósito: la
   * va a estampar el proceso de inventario cuando exista, contra un conteo
   * real. Hoy llega null en todas las filas.
   */
  fechaUltimoInventario: string | null;
  /**
   * `"S"` si es un gasto (servicios, alquiler, honorarios: se compran y se
   * consumen, no se depositan); `"N"` si es un artículo que lleva stock.
   *
   * Mismo código de una letra que `esAdmin`, y llega normalizado: el backend
   * traduce a `"N"` tanto el null de las filas anteriores a la columna como
   * cualquier valor inesperado, así que acá nunca hay un tercer estado.
   *
   * **Es descriptivo, no restrictivo**: hoy un gasto acepta lotes y suma stock
   * igual que cualquier otro artículo. Preguntá con `esGasto(a.esGasto)`.
   */
  esGasto: Rol;
  activo: Estado;
};

/**
 * A diferencia del resto de los listados, éste viene PAGINADO del servidor: el
 * catálogo puede tener cientos de artículos y traerlo entero hacía fallar al
 * endpoint.
 *
 * `total` son las filas que pasan el filtro, no las de esta página: es lo que
 * permite saber si queda algo por traer.
 */
export type ListaArticulos = {
  items: Articulo[];
  total: number;
  pagina: number;
  tamanio: number;
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
   * **Es el alcance del permiso, no auditoría.** La PK de la tabla es
   * `(ID_EMPRESA, ID_USUARIO, ID_PAGINA)`, así que el mismo usuario puede tener
   * accesos distintos según con qué empresa entre: vendedor en una y sólo
   * consulta en otra. El menú muestra únicamente las páginas cuya empresa
   * coincide con la de la sesión.
   *
   * `null` en los permisos cargados antes de que existiera la columna: esos no
   * aparecen en ninguna empresa. Ver el encabezado de db/usuario-paginas.sql.
   */
  idEmpresa: number | null;
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
 * URL de la foto de una denominación, para usar directo en `<img src>`.
 *
 * Mismo criterio que `urlLogoEmpresa`: el navegador descarga la imagen con su
 * propia petición y ahí no hay forma de mandar el header Authorization, así que
 * el endpoint es público. Devuelve 404 si la denominación no tiene foto.
 */
export function urlFotoDetalleMoneda(id: number): string {
  return `${BASE_URL}/detalle-monedas/foto/${id}`;
}

/** URL pública de la foto de un profesor. */
export function urlFotoProfesor(id: number): string {
  return `${BASE_URL}/profesores/foto/${id}`;
}

/**
 * URL pública del PDF de un manual, para abrirlo en una pestaña nueva o
 * descargarlo.
 *
 * Es pública por el mismo motivo que las imágenes: quien descarga el archivo es
 * el navegador con su propia petición, y ahí no hay forma de mandar el header
 * Authorization. Con el endpoint detrás de token habría que bajarlo con `fetch`
 * y armar un object URL, perdiendo el link compartible y la posibilidad de
 * imprimir desde el visor del navegador.
 *
 * Devuelve **404 si el manual todavía no tiene el PDF cargado** (el alta crea
 * la fila y el archivo va después), así que conviene mirar `tieneArchivo` antes
 * de ofrecer el link en vez de mandar a alguien a una pestaña con un error.
 */
export function urlArchivoManual(id: number): string {
  return `${BASE_URL}/manuales/archivo/${id}`;
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

/**
 * Sucursal activa de la sesión: lo mínimo para identificarla.
 *
 * No se guarda la `Sucursal` completa porque su `idEmpresa` y `empresa` ya los
 * da la empresa activa, y guardar dos veces el mismo dato deja lugar a que
 * queden desincronizados.
 */
export type SucursalActiva = {
  id: number;
  idEmpresa: number;
  nombreSucursal: string;
};

/**
 * Sucursal en la que está trabajando el usuario.
 *
 * Mismo ciclo de vida que la empresa —localStorage, y se borra en el logout y
 * ante un 401— con una diferencia: **cambiar de empresa la invalida**. Una
 * sucursal pertenece a una sola empresa, así que la de la empresa anterior no
 * sirve. Por eso se guarda junto al `idEmpresa`: al leerla se compara contra la
 * empresa activa y se descarta si no coincide.
 */
export function getSucursalSeleccionada(): SucursalActiva | null {
  if (typeof window === "undefined") return null;

  const crudo = localStorage.getItem(SUCURSAL_KEY);
  if (!crudo) return null;

  try {
    const datos = JSON.parse(crudo) as Partial<SucursalActiva>;
    if (typeof datos.id !== "number" || typeof datos.idEmpresa !== "number") return null;
    return {
      id: datos.id,
      idEmpresa: datos.idEmpresa,
      nombreSucursal: datos.nombreSucursal ?? "",
    };
  } catch {
    localStorage.removeItem(SUCURSAL_KEY);
    return null;
  }
}

export function setSucursalSeleccionada(sucursal: SucursalActiva | null) {
  if (typeof window === "undefined") return;
  if (sucursal) {
    localStorage.setItem(SUCURSAL_KEY, JSON.stringify(sucursal));
  } else {
    localStorage.removeItem(SUCURSAL_KEY);
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
      // La sucursal pertenece a una empresa: sin empresa no tiene sentido.
      setSucursalSeleccionada(null);
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
      // La sucursal pertenece a una empresa: sin empresa no tiene sentido.
      setSucursalSeleccionada(null);
    }
  },

  /**
   * "Olvidé mi contraseña": manda una clave provisoria al correo del usuario.
   *
   * No lleva token —quien la usa es justamente alguien que no puede entrar— y
   * **siempre responde 200**, coincidan o no los datos. El backend no distingue
   * "ese usuario no existe" de "ese no es su correo" a propósito: hacerlo
   * permitiría averiguar qué cuentas existen. La UI muestra el mismo mensaje
   * en los dos casos.
   */
  recuperarPassword: (datos: { usuario: string; correo: string }) =>
    request<{ ok: boolean; mensaje: string }>("/auth/recuperar", {
      method: "POST",
      auth: false,
      body: JSON.stringify(datos),
    }),

  /**
   * Cambia la contraseña del usuario logueado.
   *
   * Exige la actual: sin eso, una pantalla desatendida alcanzaría para quedarse
   * con la cuenta. **Un 200 revoca todas las sesiones, incluida la propia**, así
   * que después de esto hay que volver al login — por eso limpia el estado
   * local igual que `logout`.
   */
  async cambiarPassword(datos: {
    passwordActual: string;
    passwordNueva: string;
  }): Promise<{ ok: boolean }> {
    const data = await request<{ ok: boolean }>("/auth/cambiar-password", {
      method: "POST",
      body: JSON.stringify(datos),
    });

    // El token que se usó para llamar acá ya está revocado en el servidor:
    // conservarlo daría 401 en la siguiente petición, que es peor que salir
    // limpio. Mismo criterio que logout.
    setToken(null);
    setUsuarioSesion(null);
    setEmpresaSeleccionada(null);
    setSucursalSeleccionada(null);

    return data;
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

    /**
     * Alta de usuario. La contraseña inicial viaja por correo, no por pantalla.
     *
     * `correo` es **obligatorio**: es el único canal por el que sale la clave.
     *
     * No se manda contraseña: la genera siempre el backend. Quien da el alta no
     * la elige ni la ve, así la credencial inicial la conoce sólo el dueño de
     * la cuenta.
     */
    crear: (datos: {
      usuario: string;
      nombreApellido: string;
      correo: string;
      /** Omitido equivale a "N": el default seguro es no ser administrador. */
      esAdmin?: Rol;
    }) =>
      // Responde 201, no 200. `request` solo mira `res.ok`, así que da igual.
      request<{
        id: number;
        ok: boolean;
        /** `false` si APEX no pudo mandar el mail: el usuario igual se creó. */
        correoEnviado: boolean;
        /**
         * Sólo viene cuando `correoEnviado` es `false`. Es el único respaldo
         * —nadie más conoce la clave—; la UI la muestra una vez para copiarla.
         */
        passwordInicial?: string;
      }>("/usuarios/crear", {
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

    /**
     * Borra la página. **409 si algún usuario la tiene asignada** — en
     * cualquier empresa, no sólo en la activa: la página es una sola para todo
     * el sistema y el permiso es por empresa.
     *
     * El error trae `usuarios`, la cantidad de personas a las que habría que
     * quitársela primero desde Permisos.
     */
    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/paginas/eliminar/${id}`, { method: "DELETE" }),
  },

  usuarioPaginas: {
    /**
     * Sin `idUsuario` devuelve los permisos de todos los usuarios.
     *
     * **JUNTA TODAS LAS PÁGINAS** y devuelve la lista completa, que es lo que
     * necesitan sus dos consumidores: el menú —que dibuja mal si le falta una
     * entrada— y el ABM de Permisos, que cuenta cuántas tiene cada usuario.
     *
     * El endpoint pagina de a 15 y no acepta más: cada fila lleva el nombre de
     * la página, el del módulo, la ruta y el ícono, y ORDS devuelve el JSON por
     * un bind con techo de 4000 bytes. Pedir todo de una vez lo pasaba y salía
     * un **500 mudo** —el `WHEN OTHERS` no lo registra, porque el PL/SQL ya
     * terminó bien—, que es exactamente lo que rompió esta pantalla.
     *
     * El tope de vueltas es la red contra un `total` mal calculado: sin él, una
     * página vacía repetida daría vueltas para siempre.
     */
    listar: async (params: { idUsuario?: number } = {}): Promise<ListaUsuarioPaginas> => {
      const POR_PAGINA = 15;
      const MAX_PAGINAS = 60;
      const items: UsuarioPagina[] = [];
      let total = 0;

      for (let pagina = 1; pagina <= MAX_PAGINAS; pagina++) {
        const partes = [`pagina=${pagina}`, `tamanio=${POR_PAGINA}`];
        if (params.idUsuario) partes.unshift(`idUsuario=${params.idUsuario}`);

        const respuesta = await request<ListaUsuarioPaginas>(
          `/usuario-paginas/listar?${partes.join("&")}`,
        );
        items.push(...respuesta.items);
        total = respuesta.total;

        // Dos cortes: el total declarado por el backend y una página incompleta.
        // El segundo cubre que `total` venga mal.
        if (items.length >= total || respuesta.items.length < POR_PAGINA) break;
      }

      return { items, total };
    },

    /**
     * Responde 409 si el usuario ya tenía acceso a esa página **en esa
     * empresa**. La PK es (idEmpresa, idUsuario, idPagina), así que la misma
     * página sí se puede asignar en varias empresas: son filas distintas.
     *
     * Los tres ids son obligatorios — la empresa integra la PK.
     */
    asignar: (idUsuario: number, idPagina: number, idEmpresa: number) =>
      request<{ ok: boolean }>("/usuario-paginas/asignar", {
        method: "POST",
        body: JSON.stringify({ idUsuario, idPagina, idEmpresa }),
      }),

    /**
     * Quita el permiso **en una empresa**. Las tres claves van en la URL porque
     * la PK las incluye a las tres.
     *
     * `idEmpresa` no es opcional y no debe serlo: sin ella el backend borraría
     * la fila en todas las empresas, revocando accesos que nadie pidió tocar.
     */
    quitar: (idUsuario: number, idPagina: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/usuario-paginas/quitar/${idUsuario}/${idPagina}/${idEmpresa}`, {
        method: "DELETE",
      }),
  },

  /**
   * Existencias: cuánto hay de cada artículo en cada sucursal.
   *
   * **Sólo lectura.** No hay crear, actualizar ni eliminar, y es a propósito: el
   * stock se mueve con las transacciones —comprar suma, vender resta, un conteo
   * ajusta—, no editándolo a mano. Un endpoint de escritura lo convertiría en un
   * campo editable y no habría forma de explicar por qué dice lo que dice.
   *
   * Para el stock de un artículo suelto suele alcanzar con `cantidadStock` del
   * listado de artículos; esto sirve cuando hace falta verlo **abierto por
   * sucursal**.
   */
  existencias: {
    /**
     * `idEmpresa` es obligatorio; el resto de los filtros se combinan.
     *
     * Sin `idSucursal` devuelve **una fila por sucursal**, no la suma: sumarlas
     * escondería que las 12 unidades están en el otro depósito, que es
     * justamente lo que hay que ver antes de prometer una venta.
     *
     * Paginado en el servidor, 20 por página y **50 como techo**: el JSON viaja
     * por un bind de ORDS con límite de 4000 bytes.
     */
    listar: (params: {
      idEmpresa: number;
      idSucursal?: number | undefined;
      idArticulo?: number | undefined;
      busqueda?: string | undefined;
      pagina?: number | undefined;
      tamanio?: number | undefined;
    }) => {
      const partes: string[] = [`idEmpresa=${params.idEmpresa}`];
      if (params.idSucursal) partes.push(`idSucursal=${params.idSucursal}`);
      if (params.idArticulo) partes.push(`idArticulo=${params.idArticulo}`);
      if (params.busqueda?.trim())
        partes.push(`busqueda=${encodeURIComponent(params.busqueda.trim())}`);
      if (params.pagina) partes.push(`pagina=${params.pagina}`);
      if (params.tamanio) partes.push(`tamanio=${params.tamanio}`);

      return request<ListaExistencias>(`/existencias/listar?${partes.join("&")}`);
    },
  },

  /**
   * Inventarios: los conteos físicos, y la única cosa que hoy corrige
   * `EXISTENCIAS`.
   *
   * **`cerrar` mueve el stock y no se deshace.** Por eso es su propio endpoint y
   * no un campo de `actualizar`: contar y aplicar son dos actos distintos. Un
   * conteo cerrado no se edita ni se borra — para corregirlo, se carga otro.
   *
   * **`anular` y `eliminar` no son lo mismo**: eliminar es para el borrador
   * cargado por error, que no significa nada; anular es para el conteo que se
   * hizo y se decide no aplicar, y deja constancia de que alguien fue a contar.
   */
  inventarios: {
    /**
     * `idEmpresa` es obligatorio; el resto de los filtros se combinan.
     *
     * `busqueda` mira **todo lo que identifica la pieza**: nombre, código del
     * fabricante, marca y códigos equivalentes. Mismo criterio que la lista de
     * valores de artículos, y tiene que serlo: si el conteo se cargó eligiendo
     * el artículo por una equivalencia, buscarlo después con esa misma
     * equivalencia no puede fallar.
     *
     * Paginado en el servidor, 20 por página y **50 como techo**: el JSON viaja
     * por un bind de ORDS con límite de 4000 bytes.
     *
     * **`observaciones` viene recortada** a 150 caracteres, como
     * `observacionesResumen`, por ese mismo límite. Para el texto entero,
     * `obtener()`.
     */
    listar: (params: {
      idEmpresa: number;
      idSucursal?: number | undefined;
      idArticulo?: number | undefined;
      estado?: EstadoInventario | undefined;
      busqueda?: string | undefined;
      pagina?: number | undefined;
      tamanio?: number | undefined;
    }) => {
      const q = new URLSearchParams({ idEmpresa: String(params.idEmpresa) });
      if (params.idSucursal) q.set("idSucursal", String(params.idSucursal));
      if (params.idArticulo) q.set("idArticulo", String(params.idArticulo));
      if (params.estado) q.set("estado", params.estado);
      if (params.busqueda?.trim()) q.set("busqueda", params.busqueda.trim());
      if (params.pagina) q.set("pagina", String(params.pagina));
      if (params.tamanio) q.set("tamanio", String(params.tamanio));
      return request<ListaInventarios>(`/inventarios/listar?${q}`);
    },

    /**
     * Un conteo con su `observaciones` COMPLETA.
     *
     * **El formulario de edición tiene que usar esto**, no la fila del listado:
     * guardar el resumen de 150 caracteres escribiría encima de los 1000 y se
     * perdería el resto sin ningún error a la vista.
     */
    obtener: (id: number, idEmpresa: number) =>
      request<InventarioDetalle>(`/inventarios/obtener/${id}/${idEmpresa}`),

    /**
     * Nace `ABIERTO` y firmado por el usuario del token — `idUsuario` no se
     * manda: dejaría firmar un conteo a nombre de otro.
     *
     * `cantidadFisica` es opcional: se abre la planilla y se cuenta después.
     * Sin ella no se puede cerrar, que es donde el número importa.
     *
     * Da **409** si ya hay un conteo abierto de ese artículo en esa sucursal:
     * dos planillas del mismo estante terminan en que la última que se cierre
     * pisa a la otra sin dejar rastro.
     *
     * Las claves van todas aunque estén vacías: una clave omitida deja el bind
     * de ORDS sin definir, no en `NULL`.
     */
    crear: (datos: {
      idEmpresa: number;
      idSucursal: number;
      idArticulo: number;
      /**
       * `YYYY-MM-DDTHH:mm:ss` local, **con hora**. Vacío = el momento de la
       * carga (lo pone el trigger con `SYSTIMESTAMP`).
       *
       * El backend también acepta `YYYY-MM-DDTHH:mm` —un
       * `<input type="datetime-local">` omite los segundos cuando están en
       * cero— y `YYYY-MM-DD` a secas, que vale medianoche.
       *
       * La hora importa: dos conteos del mismo artículo el mismo día se ordenan
       * entre sí por ella.
       */
      fechaInventario?: string | undefined;
      cantidadFisica?: number | undefined;
      observaciones?: string | undefined;
    }) =>
      request<{ id: number; ok: boolean }>("/inventarios/crear", {
        method: "POST",
        body: JSON.stringify({
          idEmpresa: datos.idEmpresa,
          idSucursal: datos.idSucursal,
          idArticulo: datos.idArticulo,
          fechaInventario: datos.fechaInventario ?? "",
          cantidadFisica: datos.cantidadFisica ?? "",
          observaciones: datos.observaciones ?? "",
        }),
      }),

    /**
     * Corrige un conteo **abierto**. Empresa, sucursal y artículo no se
     * modifican: contar otra cosa es cargar otro inventario.
     *
     * **ACÁ UN CAMPO VACÍO BORRA, no conserva** — al revés que el resto del
     * proyecto. Es deliberado: la cantidad puede volver a quedar sin cargar, y
     * con la regla habitual quien escribió 12 por error se quedaría con ese 12
     * para siempre… y cerrar lo aplicaría al stock. Mandá siempre los tres
     * campos con lo que tenga el formulario.
     *
     * `fechaInventario` es la excepción: vacía conserva la que ya tenía. Un
     * conteo sin fecha no significa nada.
     */
    actualizar: (
      id: number,
      datos: {
        idEmpresa: number;
        fechaInventario?: string | undefined;
        cantidadFisica?: number | undefined;
        observaciones?: string | undefined;
      },
    ) =>
      request<{ ok: boolean }>(`/inventarios/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify({
          idEmpresa: datos.idEmpresa,
          fechaInventario: datos.fechaInventario ?? "",
          cantidadFisica: datos.cantidadFisica ?? "",
          observaciones: datos.observaciones ?? "",
        }),
      }),

    /**
     * Aplica el conteo: `EXISTENCIAS.CANTIDAD_DISPONIBLE` pasa a valer
     * `cantidadFisica`, y la fila queda congelada.
     *
     * **No se deshace.** Da 400 si el conteo no tiene cantidad cargada, y 409
     * si ya estaba cerrado o anulado.
     *
     * Invalidá también `["existencias"]` y `["articulos"]` al volver: los
     * números que muestran acaban de cambiar.
     */
    cerrar: (id: number, idEmpresa: number) =>
      request<CierreInventario>(`/inventarios/cerrar/${id}`, {
        method: "POST",
        body: JSON.stringify({ idEmpresa }),
      }),

    /** Descarta el conteo sin tocar el stock. Sólo desde `ABIERTO`. */
    anular: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/inventarios/anular/${id}`, {
        method: "POST",
        body: JSON.stringify({ idEmpresa }),
      }),

    /**
     * Baja física, **sólo mientras está abierto** (409 si no). Un conteo cerrado
     * ya movió el stock: borrarlo dejaría la existencia sin la explicación de
     * por qué dice lo que dice.
     */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/inventarios/eliminar/${id}/${idEmpresa}`, { method: "DELETE" }),
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

  /**
   * Marcas de artículos, **por empresa**.
   *
   * `MARCAS.ID_EMPRESA` se agregó después de que la tabla estuviera en uso: las
   * filas anteriores la tienen en null y el backend se las ofrece a todas las
   * empresas —"heredadas"—, para que no desaparezcan del combo ni dejen
   * huérfanos a los artículos que ya las usan.
   */
  marcas: {
    /**
     * Las marcas de la empresa **más las heredadas** (`idEmpresa` en null).
     *
     * `idEmpresa` es obligatorio: `MARCAS` dejó de ser un catálogo global. Sin
     * `busqueda` devuelve el catálogo entero, que es acotado.
     */
    listar: (params: { idEmpresa: number; busqueda?: string | undefined }) => {
      const q = new URLSearchParams({ idEmpresa: String(params.idEmpresa) });
      if (params.busqueda) q.set("busqueda", params.busqueda);
      return request<ListaMarcas>(`/marcas/listar?${q}`);
    },

    crear: (datos: { idEmpresa: number; descripcion: string }) =>
      request<{ id: number; ok: boolean }>("/marcas/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /**
     * `idEmpresa` es **obligatorio**: no es un dato más a guardar, acota a cuál
     * fila se aplica el cambio. Una marca de otra empresa devuelve 404.
     */
    actualizar: (id: number, datos: { idEmpresa: number; descripcion: string }) =>
      request<{ ok: boolean }>(`/marcas/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    /** Baja física: la tabla no tiene estado. Da 409 si algún artículo la usa. */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/marcas/eliminar/${id}/${idEmpresa}`, { method: "DELETE" }),
  },

  /**
   * Códigos equivalentes de un artículo: los alias con los que se lo pide.
   *
   * Se gestionan desde la ficha del artículo y no en una pantalla propia:
   * siempre se mira "los códigos de ESTE artículo".
   */
  codigosEquivalentes: {
    /**
     * Con `idArticulo`, los de ese artículo — que es lo que muestra la ficha.
     *
     * Sin él y con `busqueda`, los que coinciden en toda la empresa: sirve para
     * responder "¿qué artículo es este código de fabricante?". Devuelve una
     * **lista** porque el mismo código puede estar en dos artículos: el
     * `UNIQUE` incluye el artículo a propósito.
     */
    listar: (params: {
      idEmpresa: number;
      idArticulo?: number | undefined;
      busqueda?: string | undefined;
    }) => {
      const q = new URLSearchParams({ idEmpresa: String(params.idEmpresa) });
      if (params.idArticulo) q.set("idArticulo", String(params.idArticulo));
      if (params.busqueda?.trim()) q.set("busqueda", params.busqueda.trim());
      return request<ListaCodigosEquivalentes>(`/codigos-equivalentes/listar?${q}`);
    },

    /** El backend sube el código a mayúsculas y recorta los espacios. */
    crear: (datos: {
      idEmpresa: number;
      idArticulo: number;
      codigoEquivalente: string;
      descripcion?: string;
    }) =>
      request<{ id: number; ok: boolean }>("/codigos-equivalentes/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /**
     * El artículo NO se puede cambiar: mover un código de un artículo a otro es
     * borrarlo y crearlo, y así el `UNIQUE` se evalúa contra el correcto.
     *
     * `idEmpresa` es **obligatorio**: acota a cuál fila se aplica el cambio.
     */
    actualizar: (
      id: number,
      datos: { idEmpresa: number; codigoEquivalente: string; descripcion?: string },
    ) =>
      request<{ ok: boolean }>(`/codigos-equivalentes/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    /** Baja física: nada cuelga de un código, no hay qué revertir. */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/codigos-equivalentes/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),
  },

  canalesPagos: {
    listar: () => request<ListaCanalesPagos>("/canales-pagos/listar"),

    crear: (datos: { nombreCanal: string; descripcion?: string; indBanco?: "S" | "N" }) =>
      request<{ id: number; ok: boolean }>("/canales-pagos/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: { nombreCanal?: string; descripcion?: string; indBanco?: "S" | "N"; activo?: Estado },
    ) =>
      request<{ ok: boolean }>(`/canales-pagos/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/canales-pagos/eliminar/${id}`, { method: "DELETE" }),
  },

  bancos: {
    listar: () => request<ListaBancos>("/bancos/listar"),

    crear: (datos: { nombreBanco: string; descripcion?: string }) =>
      request<{ id: number; ok: boolean }>("/bancos/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    actualizar: (
      id: number,
      datos: { nombreBanco?: string; descripcion?: string; activo?: Estado },
    ) =>
      request<{ ok: boolean }>(`/bancos/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/bancos/eliminar/${id}`, { method: "DELETE" }),
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

  /**
   * Instituciones por empresa, con su ubicación geográfica.
   *
   * El estado se modifica mediante `actualizar`; `eliminar` sigue siendo baja
   * física para cargas equivocadas.
   */
  instituciones: {
    /**
     * Instituciones de una empresa. `idEmpresa` sale de la empresa activa de la
     * sesión (`useEmpresa()`), no de un filtro de la pantalla.
     *
     * Los filtros geográficos son opcionales y se acumulan.
     */
    listar: (
      // `| undefined` explícito y no sólo `?`: con exactOptionalPropertyTypes
      // pasar `idCiudad: undefined` —que es como la pantalla expresa "sin
      // filtro"— no compilaría contra una propiedad meramente opcional.
      params: {
        idEmpresa?: number | undefined;
        idPais?: number | undefined;
        idDepartamento?: number | undefined;
        idCiudad?: number | undefined;
        activo?: Estado | undefined;
      } = {},
    ) => {
      const q = new URLSearchParams();
      if (params.idEmpresa) q.set("idEmpresa", String(params.idEmpresa));
      if (params.idPais) q.set("idPais", String(params.idPais));
      if (params.idDepartamento) q.set("idDepartamento", String(params.idDepartamento));
      if (params.idCiudad) q.set("idCiudad", String(params.idCiudad));
      if (params.activo) q.set("activo", params.activo);
      const query = q.toString();
      return request<ListaInstituciones>(`/instituciones/listar${query ? `?${query}` : ""}`);
    },

    crear: (datos: {
      idEmpresa: number;
      idPais?: number;
      idDepartamento?: number;
      /** Opcional: el DDL la deja nullable. */
      idCiudad?: number;
      nombreInstitucion: string;
      direccion?: string;
      director?: string;
      contacto?: string;
      correo?: string;
      ubicacion?: string;
      activo?: Estado;
    }) =>
      request<{ id: number; ok: boolean }>("/instituciones/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        /** OBLIGATORIO: acota a cuál fila se aplica el cambio, no es un dato a guardar. Sin él, 400. */
        idEmpresa: number;
        idPais?: number | "null";
        idDepartamento?: number | "null";
        /**
         * Ausente significa **no cambiar**, no "quitarle la ciudad". Para dejar
         * la institución sin ciudad se manda el literal `"null"` — sin ese valor
         * distinto no habría forma de borrarla.
         */
        idCiudad?: number | "null";
        nombreInstitucion?: string;
        direccion?: string;
        director?: string;
        contacto?: string;
        correo?: string;
        ubicacion?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/instituciones/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    /** Baja física para cargas equivocadas; normalmente se usa `activo: "I"`. */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/instituciones/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),
  },

  /**
   * Profesores por empresa.
   *
   * El estado se modifica mediante `actualizar`; `eliminar` queda como baja
   * física para cargas equivocadas.
   */
  profesores: {
    /**
     * Profesores de una empresa. `idEmpresa` sale de la empresa activa de la
     * sesión (`useEmpresa()`), no de un filtro de la pantalla.
     *
     * `busqueda` va al backend y filtra en SQL sobre nombre, apellido, cédula,
     * usuario y correo.
     */
    listar: (
      // `| undefined` explícito y no sólo `?`: con exactOptionalPropertyTypes
      // pasar `busqueda: undefined` no compilaría contra una propiedad
      // meramente opcional.
      params: {
        idEmpresa?: number | undefined;
        busqueda?: string | undefined;
        activo?: Estado | undefined;
      } = {},
    ) => {
      const q = new URLSearchParams();
      if (params.idEmpresa) q.set("idEmpresa", String(params.idEmpresa));
      if (params.busqueda?.trim()) q.set("busqueda", params.busqueda.trim());
      if (params.activo) q.set("activo", params.activo);
      const query = q.toString();
      return request<ListaProfesores>(`/profesores/listar${query ? `?${query}` : ""}`);
    },

    /**
     * `numeroCi` e `idUsuario` se validan contra **todo el sistema**, no sólo
     * contra la empresa activa.
     */
    crear: (datos: {
      idEmpresa: number;
      numeroCi: string;
      nombre: string;
      apellido: string;
      idUsuario?: number;
      direccion?: string;
      telefono?: string;
      correo?: string;
    }) =>
      request<{ id: number; ok: boolean }>("/profesores/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        /** OBLIGATORIO: acota a cuál fila se aplica el cambio, no es un dato a guardar. Sin él, 400. */
        idEmpresa: number;
        numeroCi?: string;
        nombre?: string;
        apellido?: string;
        idUsuario?: number;
        direccion?: string;
        telefono?: string;
        correo?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/profesores/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    /** Baja física para una carga equivocada. */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/profesores/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),

    subirFoto: (id: number, archivo: File) =>
      request<{ ok: boolean }>(`/profesores/foto/${id}`, {
        method: "PUT",
        headers: { "Content-Type": archivo.type },
        body: archivo,
      }),
  },

  /**
   * Manuales en PDF, por institución y grado.
   *
   * **`MANUALES` no tiene `ID_EMPRESA`**: cuelga de `INSTITUCIONES`. El backend
   * aísla por empresa con un JOIN contra el padre, así que `idEmpresa` viaja en
   * todas las llamadas —incluido el `listar`, donde es obligatorio— aunque no
   * sea una columna del manual.
   *
   * El PDF **no viaja en el JSON**: se sube con `subirArchivo()` y se lee por
   * la URL pública de `urlArchivoManual()`, igual que la foto de un profesor.
   */
  manuales: {
    /**
     * `idEmpresa` es **obligatorio**, a diferencia del resto de los listados
     * donde vacío significa "todas las empresas": acá la empresa no es una
     * columna sino el JOIN con `INSTITUCIONES`, así que sin ella la consulta no
     * se acota sola y el backend responde 400 en vez de devolver los manuales
     * de todo el sistema.
     *
     * `busqueda` va al backend y filtra en SQL sobre el nombre de la
     * institución y el grado.
     *
     * Vienen ordenados por institución y **por grado real** (1ro. … 3ME.), no
     * alfabéticamente: con un orden de texto, `1ME.` cae entre `1ro.` y `2do.`
     * y la media queda intercalada con la escolar básica.
     */
    listar: (params: {
      idEmpresa: number;
      idInstitucion?: number | undefined;
      grado?: Grado | undefined;
      busqueda?: string | undefined;
    }) => {
      const q = new URLSearchParams({ idEmpresa: String(params.idEmpresa) });
      if (params.idInstitucion) q.set("idInstitucion", String(params.idInstitucion));
      if (params.grado) q.set("grado", params.grado);
      if (params.busqueda?.trim()) q.set("busqueda", params.busqueda.trim());
      return request<ListaManuales>(`/manuales/listar?${q}`);
    },

    /**
     * Crea la fila **sin el PDF**: el archivo se sube después con
     * `subirArchivo()`, cuando ya hay un id al que asociarlo. Es el mismo flujo
     * que la foto de un profesor, y la pantalla lo encadena para que el usuario
     * vea una sola operación.
     *
     * La institución tiene que ser de la empresa: mandar una ajena da 400,
     * porque la FK sola no lo impide —valida que exista, no de quién es—.
     *
     * Una institución no puede tener dos manuales del mismo grado (409).
     */
    crear: (datos: { idEmpresa: number; idInstitucion: number; grado: Grado }) =>
      request<{ id: number; ok: boolean }>("/manuales/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /**
     * Los campos ausentes no se modifican.
     *
     * **No toca `fechaCarga`**: corregir un grado mal tipeado no cambia la fecha
     * del PDF. Esa la mueve `subirArchivo()`.
     */
    actualizar: (
      id: number,
      datos: {
        /** OBLIGATORIO: acota a cuál fila se aplica el cambio. Sin él, 400. */
        idEmpresa: number;
        /** La institución de destino también se valida contra la empresa. */
        idInstitucion?: number | undefined;
        grado?: Grado | undefined;
      },
    ) =>
      request<{ ok: boolean }>(`/manuales/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    /** Baja física — la tabla no tiene `ACTIVO`. Se lleva el PDF con ella. */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/manuales/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),

    /**
     * Sube o **reemplaza** el PDF del manual. Reemplazar es la operación
     * normal: como sólo hay un manual por grado, un manual nuevo se carga sobre
     * la misma fila.
     *
     * Sólo `application/pdf`, y hasta 20 MB (413 si se pasa) — el techo es alto
     * porque un manual escaneado pesa lo que pesa y no hay nada que lo
     * recomprima del lado del cliente.
     *
     * Mueve `fechaCarga`: la fecha de carga es la del archivo, no la de la
     * fila.
     */
    subirArchivo: (id: number, archivo: File) =>
      request<{ ok: boolean; bytes: number }>(`/manuales/archivo/${id}`, {
        method: "PUT",
        // El Content-Type del File, no uno fijo: es de donde el backend saca el
        // formato que guarda. Un PDF elegido del disco siempre trae
        // "application/pdf", que es lo único que el endpoint acepta.
        headers: { "Content-Type": archivo.type },
        body: archivo,
      }),
  },

  /**
   * Asistencias de profesores. **Sólo lectura**: la marcación la hace la app del
   * profesor, así que no hay alta, edición ni baja.
   *
   * Los importes no vienen de acá — el precio por hora y la duración de la hora
   * cátedra se cargan en la pantalla del reporte.
   */
  asistenciasProfesores: {
    listar: (params: {
      idEmpresa: number;
      anio?: number | undefined;
      mes?: number | undefined;
      idProfesor?: number | undefined;
      idInstitucion?: number | undefined;
    }) => {
      const q = new URLSearchParams({ idEmpresa: String(params.idEmpresa) });
      if (params.anio) q.set("anio", String(params.anio));
      if (params.mes) q.set("mes", String(params.mes));
      if (params.idProfesor) q.set("idProfesor", String(params.idProfesor));
      if (params.idInstitucion) q.set("idInstitucion", String(params.idInstitucion));
      return request<ListaAsistenciasProfesores>(`/asistencias-profesores/listar?${q}`);
    },

    /**
     * Carga manual de una marcación, para corregir lo que la app no registró.
     *
     * Las horas van como `HH:MM` y no como timestamp: el backend las compone
     * con la fecha del día. Mandar un ISO completo desde acá haría que una
     * diferencia de zona horaria corriera el día.
     *
     * `horaSalida` va vacía —no omitida— cuando el profesor entró y todavía no
     * salió: ORDS crea un bind por cada clave del JSON, y una clave que no
     * viene deja el bind sin definir. El backend trata la cadena vacía como
     * NULL.
     */
    crear: (datos: {
      idEmpresa: number;
      idProfesor: number;
      idInstitucion: number;
      /** ISO `YYYY-MM-DD`. */
      fecha: string;
      /** `HH:MM` en 24 horas. */
      horaEntrada?: string | undefined;
      horaSalida?: string | undefined;
    }) =>
      request<{ id: number; ok: boolean }>("/asistencias-profesores/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /**
     * `idEmpresa` es **obligatorio**: no es un dato más a guardar, acota a cuál
     * fila se aplica el cambio. Sin él la respuesta es 400.
     */
    actualizar: (
      id: number,
      datos: {
        idEmpresa: number;
        idProfesor: number;
        idInstitucion: number;
        fecha: string;
        horaEntrada?: string | undefined;
        horaSalida?: string | undefined;
      },
    ) =>
      request<{ ok: boolean }>(`/asistencias-profesores/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    /** Baja física: la tabla no tiene estado — o la marcación pasó o no pasó. */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/asistencias-profesores/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),

    /**
     * Los años y meses que tienen marcaciones, con cuántas cada uno.
     *
     * Una fila por mes, sin paginar: el resultado es chico por naturaleza
     * —cuántos meses puede haber— y se pide una sola vez por empresa.
     */
    periodos: (idEmpresa: number) =>
      request<{ items: PeriodoAsistencias[] }>(
        `/asistencias-profesores/periodos?idEmpresa=${idEmpresa}`,
      ),
  },

  /**
   * Reportes de actividades: qué se hizo en la clase de un día que el profesor
   * ya marcó.
   *
   * **Un reporte cuelga de una marcación** (`UNIQUE (ID_ASISTENCIA)`), y de ahí
   * sale la forma de este cliente: al crear se manda `idAsistencia` y nada más
   * —profesor, institución y fecha los deriva el backend de la marcación—, y al
   * editar se manda sólo la descripción. Ver `db/reportes-actividades.sql`.
   */
  reportesActividades: {
    /** `descripcion` viene recortada a 200 caracteres; la entera, en `obtener`. */
    listar: (params: {
      idEmpresa: number;
      desde?: string | undefined;
      hasta?: string | undefined;
      idProfesor?: number | undefined;
      idInstitucion?: number | undefined;
      busqueda?: string | undefined;
      pagina?: number | undefined;
      /**
       * De a 20 por defecto, y **50 como techo**: cada fila lleva texto libre y
       * una página grande vuelve a chocar contra el bind de ORDS.
       */
      tamanio?: number | undefined;
    }) => {
      const q = new URLSearchParams({ idEmpresa: String(params.idEmpresa) });
      if (params.desde) q.set("desde", params.desde);
      if (params.hasta) q.set("hasta", params.hasta);
      if (params.idProfesor) q.set("idProfesor", String(params.idProfesor));
      if (params.idInstitucion) q.set("idInstitucion", String(params.idInstitucion));
      if (params.busqueda) q.set("busqueda", params.busqueda);
      if (params.pagina) q.set("pagina", String(params.pagina));
      if (params.tamanio) q.set("tamanio", String(params.tamanio));
      return request<ListaReportesActividades>(`/reportes-actividades/listar?${q}`);
    },

    /** Marcaciones del período que todavía no tienen reporte. Es lo que ofrece
     * el alta y el número de "pendientes" del encabezado. */
    pendientes: (params: {
      idEmpresa: number;
      desde?: string | undefined;
      hasta?: string | undefined;
      idProfesor?: number | undefined;
      idInstitucion?: number | undefined;
      pagina?: number | undefined;
      tamanio?: number | undefined;
    }) => {
      const q = new URLSearchParams({ idEmpresa: String(params.idEmpresa) });
      if (params.desde) q.set("desde", params.desde);
      if (params.hasta) q.set("hasta", params.hasta);
      if (params.idProfesor) q.set("idProfesor", String(params.idProfesor));
      if (params.idInstitucion) q.set("idInstitucion", String(params.idInstitucion));
      if (params.pagina) q.set("pagina", String(params.pagina));
      if (params.tamanio) q.set("tamanio", String(params.tamanio));
      return request<ListaAsistenciasSinReporte>(`/reportes-actividades/pendientes?${q}`);
    },

    /**
     * Qué profesor estuvo en qué institución, según las marcaciones del período.
     *
     * Alimenta el combo dependiente: elegido un profesor, Institución ofrece
     * sólo donde ese profesor marcó. **No hay tabla de relación** —`PROFESORES`
     * no tiene institución— así que el vínculo sale del historial de
     * asistencias.
     */
    vinculos: (params: {
      idEmpresa: number;
      desde?: string | undefined;
      hasta?: string | undefined;
    }) => {
      const q = new URLSearchParams({ idEmpresa: String(params.idEmpresa) });
      if (params.desde) q.set("desde", params.desde);
      if (params.hasta) q.set("hasta", params.hasta);
      return request<{ items: VinculoProfesorInstitucion[] }>(
        `/reportes-actividades/vinculos?${q}`,
      );
    },

    /** La ficha con la descripción entera. **La edición carga de acá**, nunca
     * de la fila del listado. */
    obtener: (id: number, idEmpresa: number) =>
      request<ReporteActividad>(`/reportes-actividades/obtener/${id}/${idEmpresa}`),

    /**
     * `idAsistencia` identifica todo lo demás. `descripcion` va siempre, con
     * `""` cuando está vacía: una clave omitida deja el bind sin definir en vez
     * de en NULL, y el backend responde 400.
     */
    crear: (datos: { idEmpresa: number; idAsistencia: number; descripcion: string }) =>
      request<{ ok: boolean; id: number }>("/reportes-actividades/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Sólo la descripción — y vacía la borra. La fecha es de la marcación. */
    actualizar: (id: number, datos: { idEmpresa: number; descripcion: string }) =>
      request<{ ok: boolean }>(`/reportes-actividades/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    /** Se lleva las filas de multimedia. Los archivos siguen en Cloudinary:
     * `archivosEliminados` dice cuántas referencias se borraron. */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean; archivosEliminados: number }>(
        `/reportes-actividades/eliminar/${id}/${idEmpresa}`,
        { method: "DELETE" },
      ),
  },

  /**
   * Evidencias de un reporte. **Acá viaja la URL, no el binario**: el archivo lo
   * sube el navegador directo a Cloudinary y esto guarda su dirección. Por eso
   * borrar una fila no borra el archivo.
   */
  reportesMultimedia: {
    listar: (params: {
      idReporte: number;
      idEmpresa: number;
      pagina?: number | undefined;
      tamanio?: number | undefined;
    }) => {
      const q = new URLSearchParams({
        idReporte: String(params.idReporte),
        idEmpresa: String(params.idEmpresa),
      });
      if (params.pagina) q.set("pagina", String(params.pagina));
      if (params.tamanio) q.set("tamanio", String(params.tamanio));
      return request<ListaReportesMultimedia>(`/reportes-multimedia/listar?${q}`);
    },

    /** Todas las claves van siempre, con `""` o `0` cuando no hay dato. */
    crear: (datos: {
      idReporte: number;
      idEmpresa: number;
      tipoArchivo: TipoMultimedia;
      descripcionTexto: string;
      urlArchivo: string;
      nombreArchivo: string;
      tamanioBytes: number;
    }) =>
      request<{ ok: boolean; id: number }>("/reportes-multimedia/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Sólo el pie de foto: cambiar la URL sería otro archivo, y eso es borrar
     * y volver a agregar. */
    actualizar: (id: number, datos: { idEmpresa: number; descripcionTexto: string }) =>
      request<{ ok: boolean }>(`/reportes-multimedia/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/reportes-multimedia/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),
  },

  /**
   * Justificaciones de ausencia de profesores.
   *
   * **No tiene `crear` ni `eliminar`, y no es un olvido.** La solicitud la carga
   * el profesor desde su app; el hub la resuelve. Un ABM completo dejaría que
   * administración cargue una ausencia a nombre de alguien que nunca la pidió, y
   * que borre la única constancia de una que sí pidió.
   */
  justificacionesAusencia: {
    /**
     * La bandeja. `idEmpresa` es obligatorio y acota por la empresa **del
     * profesor**, no por la columna de la fila.
     *
     * `desde`/`hasta` filtran por **solapamiento**: una licencia del 29 de marzo
     * al 4 de abril sale en los dos meses, que es cuando hay que resolverla.
     *
     * **`motivo` y `observaciones` vienen recortados a 200 caracteres.** De a 20
     * por página y **50 como techo**: cada fila lleva dos textos libres y una
     * página grande choca contra el bind de 4000 bytes de ORDS.
     */
    listar: (params: {
      idEmpresa: number;
      desde?: string | undefined;
      hasta?: string | undefined;
      idProfesor?: number | undefined;
      idInstitucion?: number | undefined;
      estado?: EstadoJustificacion | undefined;
      busqueda?: string | undefined;
      pagina?: number | undefined;
      tamanio?: number | undefined;
    }) => {
      const q = new URLSearchParams({ idEmpresa: String(params.idEmpresa) });
      if (params.desde) q.set("desde", params.desde);
      if (params.hasta) q.set("hasta", params.hasta);
      if (params.idProfesor) q.set("idProfesor", String(params.idProfesor));
      if (params.idInstitucion) q.set("idInstitucion", String(params.idInstitucion));
      if (params.estado) q.set("estado", params.estado);
      if (params.busqueda) q.set("busqueda", params.busqueda);
      if (params.pagina) q.set("pagina", String(params.pagina));
      if (params.tamanio) q.set("tamanio", String(params.tamanio));
      return request<ListaJustificacionesAusencia>(`/justificaciones-ausencia/listar?${q}`);
    },

    /** La ficha con el motivo y las observaciones enteros. **El diálogo de
     * gestión carga de acá**, nunca de la fila del listado. */
    obtener: (id: number, idEmpresa: number) =>
      request<JustificacionAusencia>(`/justificaciones-ausencia/obtener/${id}/${idEmpresa}`),

    /**
     * Resuelve la solicitud, y nada más: los campos que cargó el profesor no se
     * tocan. `recibidoPor` y `fechaRecepcion` **no van acá** — los sella el
     * backend con el usuario del token la primera vez.
     *
     * Las tres claves van siempre, con `""` cuando están vacías: una clave
     * omitida deja el bind sin definir en vez de en NULL. Y **`""` borra**: es
     * la única forma de sacar un suplente cargado por error.
     */
    actualizar: (
      id: number,
      datos: {
        idEmpresa: number;
        estado: EstadoJustificacion;
        suplenteAsignado: string;
        observaciones: string;
      },
    ) =>
      request<{ ok: boolean }>(`/justificaciones-ausencia/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),
  },

  /**
   * Notificaciones a profesores. **Cabecera y detalle en un solo request**: los
   * destinatarios viajan con la notificación y se guardan en la misma
   * transacción, como el detalle de una factura.
   *
   * Hoy nadie marca una notificación como leída: `leido` se muestra pero el
   * endpoint que lo escribe —el de la app del profesor— todavía no existe.
   */
  notificaciones: {
    /**
     * `idEmpresa` es obligatorio. `busqueda` mira título y descripción.
     *
     * Paginado en el servidor, 20 por página y **50 como techo**: el JSON viaja
     * por un bind de ORDS con límite de 4000 bytes.
     *
     * **`descripcion` viene recortada** a 150 caracteres, como
     * `descripcionResumen`. Para el texto entero, `obtener()`.
     */
    listar: (params: {
      idEmpresa: number;
      busqueda?: string | undefined;
      pagina?: number | undefined;
      tamanio?: number | undefined;
    }) => {
      const q = new URLSearchParams({ idEmpresa: String(params.idEmpresa) });
      if (params.busqueda?.trim()) q.set("busqueda", params.busqueda.trim());
      if (params.pagina) q.set("pagina", String(params.pagina));
      if (params.tamanio) q.set("tamanio", String(params.tamanio));
      return request<ListaNotificaciones>(`/notificaciones/listar?${q}`);
    },

    /**
     * La notificación con su `descripcion` COMPLETA y sus destinatarios.
     *
     * **El formulario de edición tiene que usar esto**, no la fila del listado:
     * guardar el resumen de 150 caracteres escribiría encima del mensaje entero
     * y se perdería el resto sin ningún error a la vista.
     */
    obtener: (id: number, idEmpresa: number) =>
      request<NotificacionDetalle>(`/notificaciones/obtener/${id}/${idEmpresa}`),

    /**
     * `destinatarios` es un array de ids de profesor y **no puede ir vacío**:
     * una notificación que no le llega a nadie no es un aviso a medio cargar,
     * es un registro inútil. El backend responde 400.
     *
     * Los profesores tienen que ser de la empresa: mandar un id ajeno da 400,
     * porque la FK sola no lo impide —valida que el profesor exista, no de
     * quién es.
     *
     * `fechaNotificacion` vacía = ahora, que es el caso normal. Se manda
     * explícita para registrar un aviso ya comunicado por otro medio.
     *
     * Las claves van todas aunque estén vacías: una clave omitida deja el bind
     * de ORDS sin definir en vez de en `NULL`.
     */
    crear: (datos: {
      idEmpresa: number;
      titulo: string;
      descripcion: string;
      /** `YYYY-MM-DDTHH:mm:ss` local. También acepta sin segundos y sólo la fecha. */
      fechaNotificacion?: string | undefined;
      destinatarios: number[];
    }) =>
      request<{ id: number; destinatarios: number; ok: boolean }>("/notificaciones/crear", {
        method: "POST",
        body: JSON.stringify({
          idEmpresa: datos.idEmpresa,
          titulo: datos.titulo,
          descripcion: datos.descripcion,
          fechaNotificacion: datos.fechaNotificacion ?? "",
          // Como texto: ORDS crea un bind por clave de primer nivel, y el
          // paquete lo lee con JSON_TABLE.
          destinatarios: JSON.stringify(datos.destinatarios),
        }),
      }),

    /**
     * Un campo ausente **conserva** su valor, como en el resto del proyecto.
     *
     * **`destinatarios` omitido deja la lista intacta, con sus lecturas** — así
     * corregir un typo del título no reinicia lo que ya se leyó. Cuando sí va,
     * la lista se reemplaza entera, pero el backend **preserva la marca de
     * lectura de quien siga estando**: agregar un destinatario a un aviso que
     * diez personas ya leyeron no reinicia a esas diez.
     */
    actualizar: (
      id: number,
      datos: {
        idEmpresa: number;
        titulo?: string | undefined;
        descripcion?: string | undefined;
        fechaNotificacion?: string | undefined;
        destinatarios?: number[] | undefined;
      },
    ) =>
      request<{ ok: boolean }>(`/notificaciones/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify({
          idEmpresa: datos.idEmpresa,
          titulo: datos.titulo ?? "",
          descripcion: datos.descripcion ?? "",
          fechaNotificacion: datos.fechaNotificacion ?? "",
          // "" y no "[]": el paquete distingue "no vino" de "vino vacío", y un
          // array vacío sería un intento de dejarla sin destinatarios (400).
          destinatarios: datos.destinatarios ? JSON.stringify(datos.destinatarios) : "",
        }),
      }),

    /** Baja física. Los destinatarios se borran primero, en la misma transacción. */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/notificaciones/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),
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
    /** **`idEmpresa` es obligatorio.** Sin él devolvía las de todas las empresas. */
    listar: (params: { idEmpresa: number }) => {
      const q = `?idEmpresa=${params.idEmpresa}`;
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
        /** OBLIGATORIO: acota a cuál fila se aplica el cambio, no es un dato a guardar. Sin él, 400. */
        idEmpresa: number;
        nombreSucursal?: string;
        direccion?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/sucursales/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/sucursales/eliminar/${id}/${idEmpresa}`, { method: "DELETE" }),
  },

  /**
   * Ubicaciones del depósito (zona / estante / nivel).
   *
   * Filtran por empresa **y** sucursal: los dos ids salen de los providers
   * globales, no de la pantalla. Es la primera tabla del proyecto que usa la
   * sucursal activa además de la empresa.
   */
  ubicaciones: {
    /**
     * Con `conArticulos`, devuelve **sólo los estantes que tienen algo**.
     *
     * Es lo que hace usable un filtro "qué hay acá": en un depósito con la
     * grilla entera cargada, la mayoría de las ubicaciones están vacías, y
     * ofrecerlas es ofrecer búsquedas que ya se sabe que no devuelven nada.
     *
     * **El ABM de ubicaciones no debe usarlo**: ahí hay que ver las vacías, que
     * son justamente las que se pueden editar o borrar sin romper nada.
     */
    listar: (params: { idEmpresa?: number; idSucursal?: number; conArticulos?: boolean } = {}) => {
      const q = new URLSearchParams();
      if (params.idEmpresa) q.set("idEmpresa", String(params.idEmpresa));
      if (params.idSucursal) q.set("idSucursal", String(params.idSucursal));
      if (params.conArticulos) q.set("conArticulos", "S");
      const query = q.toString();
      return request<ListaUbicaciones>(`/ubicaciones/listar${query ? `?${query}` : ""}`);
    },

    crear: (datos: {
      idEmpresa: number;
      idSucursal: number;
      zona: string;
      estante: number;
      nivel: number;
      descripcion?: string;
    }) =>
      request<{ id: number; ok: boolean }>("/ubicaciones/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        /** OBLIGATORIO: acota a cuál fila se aplica el cambio, no es un dato a guardar. Sin él, 400. */
        idEmpresa: number;
        idSucursal?: number;
        zona?: string;
        estante?: number;
        nivel?: number;
        descripcion?: string;
      },
    ) =>
      request<{ ok: boolean }>(`/ubicaciones/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/ubicaciones/eliminar/${id}/${idEmpresa}`, { method: "DELETE" }),
  },

  talonarios: {
    listar: (params: { idEmpresa?: number; idSucursal?: number } = {}) => {
      const q = new URLSearchParams();
      if (params.idEmpresa) q.set("idEmpresa", String(params.idEmpresa));
      if (params.idSucursal) q.set("idSucursal", String(params.idSucursal));
      const query = q.toString();
      return request<ListaTalonarios>(`/talonarios/listar${query ? `?${query}` : ""}`);
    },

    crear: (datos: {
      idEmpresa: number;
      idSucursal: number;
      tipoComprobante: Talonario["tipoComprobante"];
      nroTimbrado: string;
      establecimiento: string;
      puntoExpedicion: string;
      nroInicial: number;
      nroFinal: number;
      nroActual?: number;
      fechaInicio?: string;
      fechaVencimiento?: string;
    }) =>
      request<{ id: number; ok: boolean }>("/talonarios/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    actualizar: (
      id: number,
      datos: {
        idEmpresa: number;
        tipoComprobante?: Talonario["tipoComprobante"];
        nroTimbrado?: string;
        establecimiento?: string;
        puntoExpedicion?: string;
        nroInicial?: number;
        nroFinal?: number;
        nroActual?: number;
        fechaInicio?: string;
        fechaVencimiento?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/talonarios/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/talonarios/eliminar/${id}/${idEmpresa}`, { method: "DELETE" }),
  },

  /**
   * En qué ubicaciones está cada artículo.
   *
   * Tabla de cruce: sólo asignar y quitar. **No hay `actualizar`** — la fila no
   * tiene datos propios, así que mover un artículo de estante es quitar la
   * asignación vieja y crear la nueva.
   */
  articulosUbicaciones: {
    /**
     * **`idEmpresa` es obligatorio.** `ARTICULOS_UBICACIONES` es una tabla de
     * cruce y no tiene columna de empresa: sin este parámetro la consulta no se
     * acota sola y devolvía el cruce de **todas** las empresas. El backend ahora
     * responde 400 si falta, pero el tipo lo pide antes de compilar.
     *
     * Los otros dos filtros se combinan:
     * - `idArticulo` → dónde está ese artículo (lo que usa el ABM de artículos).
     * - `idUbicacion` → qué hay en ese estante.
     */
    listar: (params: { idEmpresa: number; idArticulo?: number; idUbicacion?: number }) => {
      const q = new URLSearchParams({ idEmpresa: String(params.idEmpresa) });
      if (params.idArticulo) q.set("idArticulo", String(params.idArticulo));
      if (params.idUbicacion) q.set("idUbicacion", String(params.idUbicacion));
      return request<ListaArticulosUbicaciones>(`/articulos-ubicaciones/listar?${q}`);
    },

    /**
     * Asigna un artículo a una ubicación.
     *
     * 409 si ya estaba asignado, y **400 si el artículo y la ubicación son de
     * empresas distintas**: el DDL lo permite (las dos FK no miran la empresa) y
     * sólo el paquete lo evita.
     */
    asignar: (datos: { idArticulo: number; idUbicacion: number }) =>
      request<{ id: number; ok: boolean }>("/articulos-ubicaciones/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /**
     * El id es el de la ASIGNACIÓN (`ArticuloUbicacion.id`).
     *
     * `idEmpresa` acota el borrado a las asignaciones de artículos de esa
     * empresa. La tabla no tiene esa columna —es un cruce— así que el backend
     * lo verifica contra el artículo padre.
     */
    quitar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/articulos-ubicaciones/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),
  },

  monedas: {
    /**
     * Monedas de una empresa. `idEmpresa` sale de la empresa activa de la
     * sesión (`useEmpresa()`), no de un filtro de la pantalla.
     *
     * **Es obligatorio.** Antes, sin `idEmpresa`, el endpoint devolvía las de
     * todas las empresas: un olvido en el cliente no fallaba, mezclaba.
     */
    listar: (params: { idEmpresa: number }) => {
      const q = `?idEmpresa=${params.idEmpresa}`;
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
        /** OBLIGATORIO: acota a cuál fila se aplica el cambio, no es un dato a guardar. Sin él, 400. */
        idEmpresa: number;
        nombreMoneda?: string;
        simbolo?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/monedas/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/monedas/eliminar/${id}/${idEmpresa}`, { method: "DELETE" }),
  },

  cuentasBancarias: {
    listar: (idEmpresa: number) =>
      request<ListaCuentasBancarias>(`/cuentas-bancarias/listar?idEmpresa=${idEmpresa}`),
    crear: (datos: {
      idEmpresa: number;
      idBanco: number;
      numeroCuenta: string;
      tipoCuenta?: string;
      titular?: string;
      saldoInicial?: number;
      idMoneda?: number;
    }) =>
      request<{ id: number; ok: boolean }>("/cuentas-bancarias/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),
    actualizar: (
      id: number,
      datos: {
        idEmpresa: number;
        idBanco?: number;
        numeroCuenta?: string;
        tipoCuenta?: string;
        titular?: string;
        saldoInicial?: number;
        idMoneda?: number;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/cuentas-bancarias/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/cuentas-bancarias/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),
  },

  /**
   * Listas de descuentos por empresa, con vigencia por fechas.
   *
   * **No hay `inactivar`/`activar`**: la tabla no tiene columna de estado. Para
   * retirar una lista se le pone `fechaVigenciaHasta`; para borrarla de verdad,
   * `eliminar` (baja física).
   */
  listasDescuentos: {
    /**
     * Listas de una empresa. `idEmpresa` sale de la empresa activa de la sesión
     * (`useEmpresa()`), no de un filtro de la pantalla.
     *
     * Vienen ordenadas por vigencia descendente: lo que rige hoy primero.
     *
     * **Es obligatorio.** Antes, sin `idEmpresa`, el endpoint devolvía las de
     * todas las empresas: un olvido en el cliente no fallaba, mezclaba.
     */
    listar: (params: { idEmpresa: number }) => {
      const q = `?idEmpresa=${params.idEmpresa}`;
      return request<ListaListasDescuentos>(`/listas-descuentos/listar${q}`);
    },

    crear: (datos: {
      idEmpresa: number;
      nombreLista: string;
      /** Porcentaje: 10 es 10%. Entre 0 y 100. Omitido = 0. */
      porcentajeDescuento?: number;
      /** ISO sólo día ("2026-04-03"). Obligatoria. */
      fechaVigenciaDesde: string;
      /** ISO sólo día. Omitida = la lista rige indefinidamente. */
      fechaVigenciaHasta?: string;
    }) =>
      request<{ id: number; ok: boolean }>("/listas-descuentos/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: {
        /** OBLIGATORIO: acota a cuál fila se aplica el cambio, no es un dato a guardar. Sin él, 400. */
        idEmpresa: number;
        nombreLista?: string;
        porcentajeDescuento?: number;
        fechaVigenciaDesde?: string;
        /**
         * Ausente significa **no cambiar**, no "quitarle el vencimiento". Para
         * volver a dejar la lista sin fin de vigencia se manda el literal
         * `"null"` — sin ese valor distinto no habría forma de borrarla.
         */
        fechaVigenciaHasta?: string | "null";
      },
    ) =>
      request<{ ok: boolean }>(`/listas-descuentos/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    /** Baja **física**: no hay estado que apagar. */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/listas-descuentos/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),
  },

  /**
   * Denominaciones de una moneda (el detalle de la cabecera MONEDAS).
   *
   * Cuelga de la moneda, no de la empresa: el filtro es `idMoneda`, que sale de
   * la moneda que se está viendo. La empresa se deduce por la moneda padre.
   */
  detalleMonedas: {
    /**
     * **`idEmpresa` es obligatorio.** `DETALLE_MONEDAS` cuelga de `MONEDAS` y no
     * tiene columna de empresa: el backend la valida contra el padre. Sin ella
     * alcanzaba con conocer un `idMoneda` ajeno para leer denominaciones de otra
     * empresa.
     */
    listar: (params: { idEmpresa: number; idMoneda?: number }) => {
      const q = new URLSearchParams({ idEmpresa: String(params.idEmpresa) });
      if (params.idMoneda) q.set("idMoneda", String(params.idMoneda));
      return request<ListaDetalleMonedas>(`/detalle-monedas/listar?${q}`);
    },

    /**
     * Crea la denominación SIN la foto: el `PUT` de la imagen necesita el id,
     * que recién existe después de esta llamada. Mismo flujo que el logo de una
     * empresa.
     */
    crear: (datos: { idMoneda: number; denominacion: string }) =>
      request<{ id: number; ok: boolean }>("/detalle-monedas/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. La foto tiene su propio endpoint. */
    /**
     * `idEmpresa` es OBLIGATORIO aunque no sea un campo del formulario: el
     * backend lo usa para verificar que la denominación pertenezca a la
     * empresa antes de tocarla. Sin él responde 400.
     */
    actualizar: (
      id: number,
      datos: { idEmpresa: number; idMoneda?: number; denominacion?: string },
    ) =>
      request<{ ok: boolean }>(`/detalle-monedas/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/detalle-monedas/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),

    /**
     * Sube la foto de una denominación. Igual que `empresas.subirLogo`: el
     * archivo va como cuerpo crudo del PUT y su tipo en el Content-Type.
     */
    subirFoto: (id: number, archivo: File) =>
      request<{ ok: boolean }>(`/detalle-monedas/foto/${id}`, {
        method: "PUT",
        headers: { "Content-Type": archivo.type },
        body: archivo,
      }),
  },

  unidadesMedida: {
    /**
     * Unidades de una empresa. `idEmpresa` sale de la empresa activa de la
     * sesión (`useEmpresa()`), no de un filtro de la pantalla.
     *
     * **Es obligatorio.** Antes, sin `idEmpresa`, el endpoint devolvía las de
     * todas las empresas: un olvido en el cliente no fallaba, mezclaba.
     */
    listar: (params: { idEmpresa: number }) => {
      const q = `?idEmpresa=${params.idEmpresa}`;
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
        /** OBLIGATORIO: acota a cuál fila se aplica el cambio, no es un dato a guardar. Sin él, 400. */
        idEmpresa: number;
        nombreUnidad?: string;
        abreviatura?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/unidades-medida/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/unidades-medida/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),
  },

  categorias: {
    /**
     * Categorías de una empresa. `idEmpresa` sale de la empresa activa de la
     * sesión (`useEmpresa()`), no de un filtro de la pantalla.
     *
     * **Es obligatorio.** Antes, sin `idEmpresa`, el endpoint devolvía las de
     * todas las empresas: un olvido en el cliente no fallaba, mezclaba.
     */
    listar: (params: { idEmpresa: number }) => {
      const q = `?idEmpresa=${params.idEmpresa}`;
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
        /** OBLIGATORIO: acota a cuál fila se aplica el cambio, no es un dato a guardar. Sin él, 400. */
        idEmpresa: number;
        nombreCategoria?: string;
        descripcion?: string;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/categorias/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/categorias/eliminar/${id}/${idEmpresa}`, { method: "DELETE" }),
  },

  articulos: {
    /**
     * Artículos de una empresa. `idEmpresa` sale de la empresa activa de la
     * sesión (`useEmpresa()`), no de un filtro de la pantalla.
     *
     * PAGINADO EN EL SERVIDOR, 20 por página. `busqueda`, `idCategoria` e
     * `idMarca` van al backend y filtran en SQL: filtrando en el cliente sólo se miraría lo ya
     * traído, y un artículo de la página 5 no aparecería al buscarlo.
     *
     * `encodeURIComponent` en la búsqueda: un código como "LYP/GLD-6085" lleva
     * barras, y sin escapar romperían el query string.
     */
    listar: (
      // `| undefined` explícito y no sólo `?`: con exactOptionalPropertyTypes
      // pasar `idCategoria: undefined` —que es como la pantalla expresa "sin
      // filtro"— no compilaría contra una propiedad meramente opcional.
      params: {
        idEmpresa?: number | undefined;
        busqueda?: string | undefined;
        idCategoria?: number | undefined;
        idMarca?: number | undefined;
        /**
         * Deja **sólo los artículos guardados en ese estante**. Responde "qué
         * hay acá", que es la pregunta con la que alguien se para delante de la
         * ubicación.
         *
         * Es el único filtro que no es una columna de `ARTICULOS`: sale de la
         * tabla de cruce, así que un artículo puede aparecer bajo varias
         * ubicaciones — el backend usa `EXISTS` para que eso no lo duplique en
         * el listado ni infle el total del paginador.
         */
        idUbicacion?: number | undefined;
        /**
         * **Acota el stock, no la lista.** El catálogo es de la empresa y no
         * cambia según el depósito; lo que cambia es `cantidadStock`, que sin
         * esto suma todas las sucursales de la empresa y con esto devuelve el de
         * una sola.
         *
         * Ojo con la diferencia: `idUbicacion` sí filtra qué artículos vuelven.
         */
        idSucursal?: number | undefined;
        pagina?: number | undefined;
        tamanio?: number | undefined;
      } = {},
    ) => {
      const partes: string[] = [];
      if (params.idEmpresa) partes.push(`idEmpresa=${params.idEmpresa}`);
      if (params.busqueda?.trim())
        partes.push(`busqueda=${encodeURIComponent(params.busqueda.trim())}`);
      if (params.idCategoria) partes.push(`idCategoria=${params.idCategoria}`);
      if (params.idMarca) partes.push(`idMarca=${params.idMarca}`);
      if (params.idUbicacion) partes.push(`idUbicacion=${params.idUbicacion}`);
      if (params.idSucursal) partes.push(`idSucursal=${params.idSucursal}`);
      if (params.pagina) partes.push(`pagina=${params.pagina}`);
      if (params.tamanio) partes.push(`tamanio=${params.tamanio}`);
      const q = partes.length > 0 ? `?${partes.join("&")}` : "";
      return request<ListaArticulos>(`/articulos/listar${q}`);
    },

    /**
     * Sólo `idEmpresa` y `nombreArticulo` son obligatorios; el resto no. Las
     * cuatro relaciones (categoría, marca, moneda, unidad) pueden omitirse.
     *
     * **No hay precios ni stock**: se eliminaron de la tabla. El costo de cada
     * compra vive en `FACTURAS_COMPRAS_DET.PRECIO_UNITARIO`, y el stock va a
     * vivir en `EXISTENCIAS` — hasta entonces el listado devuelve 0.
     */
    crear: (datos: {
      idEmpresa: number;
      nombreArticulo: string;
      idCategoria?: number;
      idMarca?: number;
      idMoneda?: number;
      idUnidadMedida?: number;
      codigoArticulo?: string;
      descripcion?: string;
      cantidadMinima?: number;
      /** Omitirlo crea un artículo de stock: el backend lo entra como `"N"`. */
      esGasto?: Rol;
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
        /** OBLIGATORIO: acota a cuál fila se aplica el cambio, no es un dato a guardar. Sin él, 400. */
        idEmpresa: number;
        idCategoria?: number;
        idMarca?: number;
        idMoneda?: number;
        idUnidadMedida?: number;
        codigoArticulo?: string;
        nombreArticulo?: string;
        descripcion?: string;
        cantidadMinima?: number;
        /**
         * Acá el ausente **conserva** la marca actual, al revés que en `crear`,
         * donde cae en `"N"`. Sin esa diferencia, un PUT que sólo cambiara el
         * nombre convertiría un gasto en artículo de stock.
         */
        esGasto?: Rol;
        activo?: Estado;
      },
    ) =>
      request<{ ok: boolean }>(`/articulos/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/articulos/eliminar/${id}/${idEmpresa}`, { method: "DELETE" }),

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

  /**
   * Padrón de personas, físicas y jurídicas.
   *
   * **Catálogo global**: ninguna operación lleva `idEmpresa`, y el borrado es
   * `/eliminar/:id` a secas — no el `/:id/:idEmpresa` de las tablas por empresa.
   */
  personas: {
    /**
     * `busqueda` filtra por nombre, apellido, razón social, CI o RUC; `tipo`
     * acota a físicas o jurídicas. Los dos son opcionales y se combinan.
     */
    listar: (params: { busqueda?: string; tipo?: TipoPersona } = {}) => {
      const q = new URLSearchParams();
      if (params.busqueda) q.set("busqueda", params.busqueda);
      if (params.tipo) q.set("tipo", params.tipo);
      const query = q.toString();
      return request<ListaPersonas>(`/personas/listar${query ? `?${query}` : ""}`);
    },

    /**
     * **Qué es obligatorio depende del tipo**, y el backend lo rechaza con 400
     * si falta:
     * - `"F"` → `nombre` y `apellido`.
     * - `"J"` → `razonSocial` (el backend completa `nombre` por su cuenta).
     *
     * `numeroCi` y `ruc` dan 409 si ya están usados por otra persona.
     */
    crear: (datos: {
      tipoPersona: TipoPersona;
      nombre?: string;
      apellido?: string;
      razonSocial?: string;
      numeroCi?: string;
      ruc?: string;
      email?: string;
      telefono?: string;
      direccion?: string;
    }) =>
      request<{ id: number; ok: boolean }>("/personas/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /**
     * Los campos ausentes no se modifican.
     *
     * `tipoPersona` **sí** se puede cambiar, pero el backend valida cómo va a
     * quedar la fila: pasar a jurídica sin razón social —ni cargada de antes ni
     * en esta llamada— da 400 en vez de dejar el registro a medio armar.
     */
    actualizar: (
      id: number,
      datos: {
        tipoPersona?: TipoPersona;
        nombre?: string;
        apellido?: string;
        razonSocial?: string;
        numeroCi?: string;
        ruc?: string;
        email?: string;
        telefono?: string;
        direccion?: string;
      },
    ) =>
      request<{ ok: boolean }>(`/personas/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    /** Baja **física**: la tabla no tiene estado. 409 si tiene dependencias. */
    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/personas/eliminar/${id}`, { method: "DELETE" }),
  },

  /** Tasas de IVA. Catálogo global: ninguna operación lleva `idEmpresa`. */
  iva: {
    listar: () => request<ListaIva>("/iva/listar"),

    /**
     * Agrega una tasa. **Los dos divisores son opcionales**: si no se mandan, el
     * backend los calcula (`100/p + 1` el del IVA, `1 + p/100` el del gravado).
     * Mandarlos mal se rechaza con 400 en vez de guardarse.
     *
     * 409 si ya existe una tasa con ese porcentaje: la columna es única.
     */
    crear: (datos: {
      porcentaje: number;
      ivaDivision?: number;
      gravadaDivision?: number;
      descripcion?: string;
    }) =>
      request<{ id: number; ivaDivision: number; gravadaDivision: number; ok: boolean }>(
        "/iva/crear",
        { method: "POST", body: JSON.stringify(datos) },
      ),

    /**
     * Los campos ausentes no se modifican, **con una excepción importante**:
     * cambiar `porcentaje` sin mandar los divisores los **recalcula solos**.
     *
     * Sin eso, pasar una tasa de 10% a 5% dejaría el divisor en 11 —el del 10%—
     * y todas sus facturas desglosarían mal sin ningún error visible.
     *
     * Guardar una tasa con `gravadaDivision` en null también la completa, así
     * que editar las tasas viejas las migra al método nuevo sin trabajo extra.
     *
     * Devuelve los divisores con los que quedó.
     */
    actualizar: (
      id: number,
      datos: {
        porcentaje?: number;
        ivaDivision?: number;
        gravadaDivision?: number;
        descripcion?: string;
      },
    ) =>
      request<{ ivaDivision: number; gravadaDivision: number; ok: boolean }>(
        `/iva/actualizar/${id}`,
        { method: "PUT", body: JSON.stringify(datos) },
      ),

    /** 409 si alguna línea de factura la usa, con la cantidad en el mensaje. */
    eliminar: (id: number) => request<{ ok: boolean }>(`/iva/eliminar/${id}`, { method: "DELETE" }),
  },

  /**
   * Condiciones de pago. **Catálogo global**: ninguna operación lleva
   * `idEmpresa`, y el borrado es `/eliminar/:id` a secas.
   */
  condicionesPago: {
    listar: () => request<ListaCondicionesPago>("/condiciones-pago/listar"),

    /**
     * Sólo el nombre es obligatorio. Sin `diasPago` ni `cantidadCuotas`, entra
     * como contado (0 días) y pago único (1 cuota).
     *
     * 400 si los valores no son coherentes — contado no admite varias cuotas —
     * y 409 si el nombre ya existe (ignorando mayúsculas).
     */
    crear: (datos: { nombreCondicion: string; diasPago?: number; cantidadCuotas?: number }) =>
      request<{ id: number; ok: boolean }>("/condiciones-pago/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /** Los campos ausentes no se modifican. */
    actualizar: (
      id: number,
      datos: { nombreCondicion?: string; diasPago?: number; cantidadCuotas?: number },
    ) =>
      request<{ ok: boolean }>(`/condiciones-pago/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    /** 409 si alguna factura la usa, con la cantidad en el mensaje. */
    eliminar: (id: number) =>
      request<{ ok: boolean }>(`/condiciones-pago/eliminar/${id}`, { method: "DELETE" }),
  },

  /**
   * Facturas de compra: cabecera y detalle.
   *
   * Es la primera **transacción** del proyecto — la cabecera y sus líneas viajan
   * en el mismo request y entran juntas o no entra ninguna. Guardar una factura
   * **no mueve stock**: es el documento, y el ingreso al depósito se carga
   * aparte en Lotes.
   */
  facturasCompras: {
    /**
     * Devuelve las **cabeceras** con su total calculado, sin el detalle. Los
     * filtros se combinan; `desde`/`hasta` van en ISO e incluyen ambos extremos.
     */
    listar: (
      params: {
        idEmpresa?: number;
        idSucursal?: number;
        idProveedor?: number;
        desde?: string;
        hasta?: string;
      } = {},
    ) => {
      const q = new URLSearchParams();
      if (params.idEmpresa) q.set("idEmpresa", String(params.idEmpresa));
      if (params.idSucursal) q.set("idSucursal", String(params.idSucursal));
      if (params.idProveedor) q.set("idProveedor", String(params.idProveedor));
      if (params.desde) q.set("desde", params.desde);
      if (params.hasta) q.set("hasta", params.hasta);
      const query = q.toString();
      return request<ListaFacturasCompras>(`/facturas-compras/listar${query ? `?${query}` : ""}`);
    },

    /** Una factura **con** su detalle y sus totales desglosados. */
    obtener: (id: number, idEmpresa: number) =>
      request<FacturaCompraCompleta>(`/facturas-compras/obtener/${id}/${idEmpresa}`),

    /**
     * Crea la cabecera y su detalle en una sola transacción.
     *
     * `detalle` no puede venir vacío: una factura sin líneas se rechaza con 400.
     * Y el mismo artículo no puede repetirse (409) — para comprar dos veces lo
     * mismo, se suma la cantidad en una línea.
     */
    crear: (datos: {
      idEmpresa: number;
      idSucursal: number;
      idProveedor: number;
      numeroFactura: string;
      /** ISO de sólo día. */
      fechaFactura: string;
      idMoneda: number;
      /** Ausente = 1, que es lo correcto en moneda local. */
      tipoCambio?: number;
      /** Opcional: sin ella la factura queda sin plazo ni vencimiento. */
      idCondicion?: number;
      observacion?: string;
      detalle: Array<{
        idArticulo: number;
        cantidad: number;
        /** **Con IVA incluido.** */
        precioUnitario: number;
        idIva?: number;
      }>;
    }) =>
      request<{ id: number; lineas: number; ok: boolean }>("/facturas-compras/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /**
     * Los campos ausentes de la cabecera no se modifican.
     *
     * **`detalle` presente REEMPLAZA las líneas por completo**; ausente las deja
     * como estaban. No hay forma de editar una sola línea: se manda el detalle
     * entero como quedó.
     */
    actualizar: (
      id: number,
      datos: {
        idEmpresa: number;
        idSucursal?: number;
        idProveedor?: number;
        numeroFactura?: string;
        fechaFactura?: string;
        idMoneda?: number;
        tipoCambio?: number;
        idCondicion?: number;
        observacion?: string;
        detalle?: Array<{
          idArticulo: number;
          cantidad: number;
          precioUnitario: number;
          idIva?: number;
        }>;
      },
    ) =>
      request<{ ok: boolean }>(`/facturas-compras/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    /** Borra la factura **y su detalle**. Baja física: no hay estado. */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/facturas-compras/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),
  },

  dashboard: {
    /**
     * Los indicadores de la home, en una consulta.
     *
     * Cada monto viene con el del **mes anterior** en vez de un porcentaje ya
     * calculado: con los dos números la pantalla puede distinguir "no cambió"
     * de "el mes pasado no hubo nada", que con un porcentaje solo se confunden.
     */
    resumen: (params: { idEmpresa: number; idSucursal: number }) =>
      request<ResumenDashboard>(
        `/dashboard/resumen?idEmpresa=${params.idEmpresa}&idSucursal=${params.idSucursal}`,
      ),
  },

  /**
   * Pagos a proveedores. Espejo de `ventasCobros`: mismo contrato, dinero
   * saliendo en vez de entrando.
   */
  comprasPagos: {
    listar: (idFactura: number, idEmpresa: number) =>
      request<ListaPagosCompras>(`/compras-pagos/listar/${idFactura}/${idEmpresa}`),
    crear: (datos: {
      idFactura: number;
      idCuota?: number;
      idEmpresa: number;
      idCanalPago: number;
      idMoneda: number;
      idCuentaBancaria?: number;
      monto: number;
      fechaPago: string;
      referencia?: string;
      observacion?: string;
    }) =>
      request<{ id: number; ok: boolean }>("/compras-pagos/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),
    /** Borra el pago y devuelve el saldo a la factura, reabriendo su cuota. */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean; idFactura: number }>(`/compras-pagos/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),
  },

  ventas: {
    listar: (params: { idEmpresa: number; idSucursal: number }) =>
      request<ListaVentas>(
        `/ventas/listar?idEmpresa=${params.idEmpresa}&idSucursal=${params.idSucursal}`,
      ),
    obtener: (id: number, idEmpresa: number) =>
      request<VentaCompleta>(`/ventas/obtener/${id}/${idEmpresa}`),
    crear: (datos: {
      idEmpresa: number;
      idSucursal: number;
      idUsuario: number;
      idCliente?: number;
      /**
       * Opcional: sin lista, la venta va a precio de etiqueta y el backend
       * aplica 0% de descuento. Mandar una que no exista o que no esté vigente
       * para `fechaVenta` se rechaza con 400.
       */
      idListaDescuentos?: number;
      idCondicionPago: number;
      idMoneda: number;
      fechaVenta: string;
      idTalonario: number;
      observacion?: string;
      detalle: Array<{
        idArticulo: number;
        cantidad: number;
        precioUnitario: number;
        idIva?: number;
      }>;
    }) =>
      request<{
        id: number;
        /** El número de comprobante (`001-001-0000042`), no el id interno. */
        numeroVenta: string;
        lineas: number;
        total: number;
        ok: boolean;
      }>("/ventas/crear", {
        method: "POST",
        body: JSON.stringify({ ...datos, detalle: JSON.stringify(datos.detalle) }),
      }),
    /**
     * Borra la venta con sus cuotas y su detalle.
     *
     * **No repone stock**, porque vender tampoco lo descuenta mientras dure la
     * migración a existencias por artículo. Una venta con cobros se rechaza con
     * 409: hay que anularlos primero.
     */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/ventas/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),
  },

  ventasCobros: {
    listar: (idVenta: number, idEmpresa: number) =>
      request<ListaVentasCobros>(`/ventas-cobros/listar/${idVenta}/${idEmpresa}`),
    crear: (datos: {
      idVenta: number;
      idCuota?: number;
      idEmpresa: number;
      idCanalPago: number;
      idMoneda: number;
      idCuentaBancaria?: number;
      monto: number;
      fechaCobro: string;
      referencia?: string;
      observacion?: string;
    }) =>
      request<{ id: number; ok: boolean }>("/ventas-cobros/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),
    /**
     * Borra el cobro y **devuelve el saldo a la venta**: el saldo se deriva de
     * la suma de cobros, y el backend además le resta el monto a la cuota
     * imputada y la reabre si deja de estar cubierta.
     */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean; idVenta: number }>(`/ventas-cobros/eliminar/${id}/${idEmpresa}`, {
        method: "DELETE",
      }),
  },
};
