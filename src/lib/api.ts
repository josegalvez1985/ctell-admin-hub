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
};

export type ListaUbicaciones = {
  items: Ubicacion[];
  total: number;
};

/**
 * Partida de mercadería que entró al depósito.
 *
 * Cuelga de empresa **y** sucursal (las activas de la sesión) y además de un
 * artículo, que sí se elige en el formulario. El listado trae el nombre y el
 * código del artículo por JOIN: cada lote es de un artículo distinto, así que
 * no son una constante repetida como sí lo serían la empresa y la sucursal.
 *
 * **Sin `activo`:** el DDL no trae la columna, la baja es física.
 */
export type Lote = {
  id: number;
  idEmpresa: number;
  idSucursal: number;
  idArticulo: number;
  /** Del artículo (JOIN). */
  nombreArticulo: string;
  codigoArticulo: string | null;
  /**
   * Identificador de la partida. **Nullable**: entra mercadería sin lote
   * identificado, y Oracle no considera que dos NULL choquen entre sí, así que
   * el UNIQUE no impide varios lotes sin número para el mismo artículo.
   */
  numeroLote: number | null;
  /**
   * Cuánto **entró** en la partida. Es histórico: no cambia al consumirse la
   * mercadería, sólo si se corrige un error de carga.
   */
  cantidad: number;
  /**
   * Cuánto **queda** sin consumir hoy. Arranca igual a `cantidad` y baja con el
   * uso; la resta entre las dos es lo consumido.
   *
   * **El stock de un artículo suma este campo, no `cantidad`.** Nunca llega
   * null: el backend lo iguala a `cantidad` en las filas viejas.
   */
  cantidadDispon: number;
  costo: number | null;
  /**
   * Fechas en ISO **sólo día** ("2026-04-03"), sin hora: un vencimiento es un
   * día del calendario. `fechaVencimiento` es null cuando la mercadería no
   * vence.
   */
  fechaVencimiento: string | null;
  fechaEntrada: string | null;
  observaciones: string | null;
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
 * Estado de un conteo físico. **No** usa el `'A'`/`'I'` del resto del proyecto:
 * acá no son dos estados sino tres, y la columna guarda la palabra entera.
 *
 * - `ABIERTO` — editable, todavía no aplicado. Todo conteo nace así.
 * - `PROCESADO` — aplicado al lote. Terminal.
 * - `ANULADO` — descartado sin aplicar. Terminal.
 *
 * Las únicas transiciones posibles son `ABIERTO → PROCESADO` y
 * `ABIERTO → ANULADO`, y las impone un trigger de la base: desde un estado
 * terminal no se sale.
 */
export type EstadoInventario = "ABIERTO" | "PROCESADO" | "ANULADO";

/** `true` si el conteo todavía se puede editar, procesar o anular. */
export function inventarioAbierto(estado: EstadoInventario | undefined): boolean {
  return estado === "ABIERTO";
}

/**
 * Conteo físico de un lote: cuánto decía el sistema y cuánto se contó de verdad.
 *
 * **Una fila por lote contado**, no una cabecera con líneas. Por eso la relación
 * con `LOTES` es obligatoria y de ahí salen la sucursal y el artículo.
 */
export type Inventario = {
  id: number;
  idEmpresa: number;
  idSucursal: number;
  idLote: number;
  idArticulo: number;
  /** Del JOIN contra ARTICULOS, LOTES y SUCURSALES. */
  nombreArticulo: string;
  codigoArticulo: string | null;
  numeroLote: number | null;
  nombreSucursal: string;
  /**
   * Lo que el sistema creía que había **al momento de contar**. Es una foto: se
   * copia del lote al crear el conteo y no se recalcula, para que la diferencia
   * no se mueva sola entre que se cuenta y se procesa.
   */
  cantidadSistema: number | null;
  /** Lo que se contó con las manos. El único dato que aporta la persona. */
  cantidadFisica: number | null;
  /**
   * `cantidadFisica - cantidadSistema`. La calcula el backend en cada listado y
   * **no se guarda**: tres columnas derivables entre sí son tres columnas que
   * pueden contradecirse.
   */
  diferencia: number;
  /**
   * Lo que queda en el lote **hoy**. Si difiere de `cantidadSistema`, el lote se
   * movió después del conteo y la diferencia ya no es sólo el ajuste.
   */
  cantidadLoteHoy: number;
  estado: EstadoInventario;
  /**
   * Quién **procesó** el conteo. Los tres son null mientras esté abierto y
   * también en los anulados: ahí nadie aplicó nada.
   *
   * El nombre y el login vienen del JOIN contra `USUARIOS`, no de una copia
   * guardada en la fila: si alguien corrige su nombre, el histórico lo refleja.
   */
  idUsuario: number | null;
  /** Login (`USUARIOS.USUARIO`), corto y estable. */
  usuarioProcesa: string | null;
  /** Nombre completo, para mostrar. */
  nombreProcesa: string | null;
  /** ISO ("2026-08-18T14:30:00"). Cuándo se hizo el conteo físico. */
  fechaInventario: string | null;
  observaciones: string | null;
};

export type ListaInventarios = {
  items: Inventario[];
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
   * `'S'` si algo de esta factura **ya se vendió**.
   *
   * La compra creó un lote por línea; editar o borrar la factura rehace o
   * elimina esos lotes, y eso no se puede una vez que salió mercadería. El
   * backend lo rechaza con 409 — esto permite avisarlo antes.
   */
  tieneSalidas: "S" | "N";
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
   * El lote del que salió la línea. **Uno solo**: `VENTAS_DETALLES` tiene una
   * columna `ID_LOTE` y un `UNIQUE (ID_VENTA, ID_ARTICULO)`, así que una línea
   * no se reparte entre lotes — las 10 unidades salen todas del mismo.
   *
   * `null` en los artículos `ES_GASTO`: un servicio no tiene stock.
   */
  idLote: number | null;
  numeroLote: number | null;
  loteVence: string | null;
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

export type ListaLotes = {
  items: Lote[];
  /** Las filas que pasan el filtro, **no** las de esta página. */
  total: number;
  pagina: number;
  /** El que el backend aplicó, que pudo recortarse al techo de 200. */
  tamanio: number;
};

/**
 * Un artículo que tiene al menos un lote, para el desplegable del filtro de la
 * columna Artículo.
 *
 * Sólo id y nombre: es lo único que el filtro necesita. Viene de
 * `/lotes/articulos` y no de `/articulos/listar` porque ese ofrecería artículos
 * sin ningún lote —elegirlos daría una lista vacía— y además viene paginado.
 */
export type ArticuloConLotes = {
  id: number;
  nombreArticulo: string;
};

export type ListaArticulosConLotes = {
  items: ArticuloConLotes[];
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
  codigoArticulo: string | null;
  nombreArticulo: string;
  descripcion: string | null;
  /**
   * Stock actual: la **suma de las cantidades de sus lotes**, calculada por el
   * backend en cada listado. Ya no es una columna de ARTICULOS.
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
    listar: (params: { idEmpresa?: number; idSucursal?: number } = {}) => {
      const q = new URLSearchParams();
      if (params.idEmpresa) q.set("idEmpresa", String(params.idEmpresa));
      if (params.idSucursal) q.set("idSucursal", String(params.idSucursal));
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
   * Lotes de mercadería (partidas con vencimiento y costo).
   *
   * Filtran por empresa **y** sucursal —las activas, igual que ubicaciones— y
   * opcionalmente por artículo, para ver las partidas de uno solo.
   *
   * Las fechas van y vuelven como ISO de sólo día ("2026-04-03"). El backend
   * las convierte con formato explícito: mandar otro formato da 400.
   */
  lotes: {
    /**
     * Lotes de una empresa y sucursal. Las dos salen de los providers globales
     * (`useEmpresa()` / `useSucursal()`), no de filtros de la pantalla.
     *
     * PAGINADO EN EL SERVIDOR, 20 por página. `busqueda` e `idArticulo` van al
     * backend y filtran en SQL: filtrando en el cliente sólo se miraría lo ya
     * traído, y un lote de la página 5 no aparecería al buscarlo.
     *
     * `URLSearchParams` escapa los valores solo — hace falta porque un código de
     * artículo puede llevar barras.
     */
    listar: (
      // `| undefined` explícito y no sólo `?`: con exactOptionalPropertyTypes
      // pasar `idArticulo: undefined` —que es como la pantalla expresa "sin
      // filtro"— no compilaría contra una propiedad meramente opcional.
      params: {
        idEmpresa?: number | undefined;
        idSucursal?: number | undefined;
        idArticulo?: number | undefined;
        busqueda?: string | undefined;
        pagina?: number | undefined;
        tamanio?: number | undefined;
      } = {},
    ) => {
      const q = new URLSearchParams();
      if (params.idEmpresa) q.set("idEmpresa", String(params.idEmpresa));
      if (params.idSucursal) q.set("idSucursal", String(params.idSucursal));
      if (params.idArticulo) q.set("idArticulo", String(params.idArticulo));
      if (params.busqueda?.trim()) q.set("busqueda", params.busqueda.trim());
      if (params.pagina) q.set("pagina", String(params.pagina));
      if (params.tamanio) q.set("tamanio", String(params.tamanio));
      const query = q.toString();
      return request<ListaLotes>(`/lotes/listar${query ? `?${query}` : ""}`);
    },

    /**
     * Los artículos que tienen al menos un lote, para el desplegable del filtro
     * de la columna. Sin paginar: son los artículos con stock en UNA sucursal.
     */
    articulos: (params: { idEmpresa?: number; idSucursal?: number } = {}) => {
      const q = new URLSearchParams();
      if (params.idEmpresa) q.set("idEmpresa", String(params.idEmpresa));
      if (params.idSucursal) q.set("idSucursal", String(params.idSucursal));
      const query = q.toString();
      return request<ListaArticulosConLotes>(`/lotes/articulos${query ? `?${query}` : ""}`);
    },

    crear: (datos: {
      idEmpresa: number;
      idSucursal: number;
      idArticulo: number;
      numeroLote?: number;
      cantidad?: number;
      cantidadDispon?: number;
      costo?: number;
      /** ISO de sólo día: "2026-04-03". */
      fechaVencimiento?: string;
      fechaEntrada?: string;
      observaciones?: string;
    }) =>
      request<{ id: number; ok: boolean }>("/lotes/crear", {
        method: "POST",
        body: JSON.stringify(datos),
      }),

    /**
     * Los campos ausentes no se modifican.
     *
     * Ojo: mandar `fechaVencimiento` vacía significa "no cambiar", **no** quitar
     * el vencimiento. No hay forma de borrarlo desde este endpoint.
     */
    actualizar: (
      id: number,
      datos: {
        /** OBLIGATORIO: acota a cuál fila se aplica el cambio, no es un dato a guardar. Sin él, 400. */
        idEmpresa: number;
        idSucursal?: number;
        idArticulo?: number;
        numeroLote?: number;
        cantidad?: number;
        cantidadDispon?: number;
        costo?: number;
        fechaVencimiento?: string;
        fechaEntrada?: string;
        observaciones?: string;
      },
    ) =>
      request<{ ok: boolean }>(`/lotes/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/lotes/eliminar/${id}/${idEmpresa}`, { method: "DELETE" }),
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
     * Los dos filtros se combinan:
     * - `idArticulo` → dónde está ese artículo (lo que usa el ABM de artículos).
     * - `idUbicacion` → qué hay en ese estante.
     */
    listar: (params: { idArticulo?: number; idUbicacion?: number } = {}) => {
      const q = new URLSearchParams();
      if (params.idArticulo) q.set("idArticulo", String(params.idArticulo));
      if (params.idUbicacion) q.set("idUbicacion", String(params.idUbicacion));
      const query = q.toString();
      return request<ListaArticulosUbicaciones>(
        `/articulos-ubicaciones/listar${query ? `?${query}` : ""}`,
      );
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
     * Sin `idEmpresa` devuelve las de todas las empresas — no se usa desde la
     * app, pero el endpoint lo permite para poder inspeccionarlo.
     */
    listar: (params: { idEmpresa?: number } = {}) => {
      const q = params.idEmpresa ? `?idEmpresa=${params.idEmpresa}` : "";
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
    listar: (params: { idMoneda?: number } = {}) => {
      const q = params.idMoneda ? `?idMoneda=${params.idMoneda}` : "";
      return request<ListaDetalleMonedas>(`/detalle-monedas/listar${q}`);
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
      if (params.pagina) partes.push(`pagina=${params.pagina}`);
      if (params.tamanio) partes.push(`tamanio=${params.tamanio}`);
      const q = partes.length > 0 ? `?${partes.join("&")}` : "";
      return request<ListaArticulos>(`/articulos/listar${q}`);
    },

    /**
     * Sólo `idEmpresa` y `nombreArticulo` son obligatorios; el resto no. Las
     * cuatro relaciones (categoría, marca, moneda, unidad) pueden omitirse.
     *
     * **No hay precios ni stock**: se eliminaron de la tabla. El costo vive en
     * cada lote (`api.lotes`) y el stock es la suma de sus cantidades.
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
   * Conteos físicos de stock.
   *
   * Es el único módulo **sin `eliminar`**: un trigger de la base prohíbe el
   * DELETE, porque un conteo es evidencia de que alguien fue al depósito y
   * contó. `anular` ocupa su lugar y deja el registro asentado.
   */
  inventarios: {
    /**
     * Los cuatro filtros se combinan. En la app siempre viajan `idEmpresa` e
     * `idSucursal`, que salen de los providers de la sesión.
     */
    listar: (
      params: {
        idEmpresa?: number;
        idSucursal?: number;
        idArticulo?: number;
        estado?: EstadoInventario;
      } = {},
    ) => {
      const q = new URLSearchParams();
      if (params.idEmpresa) q.set("idEmpresa", String(params.idEmpresa));
      if (params.idSucursal) q.set("idSucursal", String(params.idSucursal));
      if (params.idArticulo) q.set("idArticulo", String(params.idArticulo));
      if (params.estado) q.set("estado", params.estado);
      const query = q.toString();
      return request<ListaInventarios>(`/inventarios/listar${query ? `?${query}` : ""}`);
    },

    /**
     * Abre un conteo sobre un lote. Nace siempre `ABIERTO`.
     *
     * **No recibe `idSucursal`, `idArticulo` ni `cantidadSistema`**: los tres
     * salen del lote, que ya los tiene resueltos. Pedirlos abriría la puerta a
     * que lleguen inconsistentes entre sí.
     *
     * Devuelve la foto del sistema y la diferencia, para poder mostrarlas sin
     * volver a pedir el listado. Da 409 si ese lote ya tiene un conteo abierto.
     */
    crear: (datos: {
      idEmpresa: number;
      idLote: number;
      /** Obligatoria. Un 0 es un dato válido: el lote se agotó. */
      cantidadFisica: number;
      /** ISO, día o día y hora. Ausente = ahora. */
      fechaInventario?: string;
      observaciones?: string;
    }) =>
      request<{ id: number; cantidadSistema: number; diferencia: number; ok: boolean }>(
        "/inventarios/crear",
        { method: "POST", body: JSON.stringify(datos) },
      ),

    /**
     * Corrige un conteo **todavía abierto**; los campos ausentes no se
     * modifican. Da 409 si ya fue procesado o anulado.
     *
     * Los ids no se pueden cambiar: mover un conteo a otro lote lo convertiría
     * en un conteo distinto. Si el lote estaba mal, se anula y se carga otro.
     */
    actualizar: (
      id: number,
      datos: {
        idEmpresa: number;
        cantidadFisica?: number;
        fechaInventario?: string;
        observaciones?: string;
      },
    ) =>
      request<{ ok: boolean }>(`/inventarios/actualizar/${id}`, {
        method: "PUT",
        body: JSON.stringify(datos),
      }),

    /**
     * `ABIERTO → PROCESADO`: aplica lo contado al lote y sella quién lo hizo.
     *
     * **Es irreversible** — no hay vuelta a abierto. El ajuste lo hace un
     * trigger sobre `LOTES.CANTIDAD_DISPON`, que es lo que suma el stock del
     * artículo.
     */
    procesar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/inventarios/procesar/${id}/${idEmpresa}`, { method: "POST" }),

    /**
     * `ABIERTO → ANULADO`: descarta el conteo **sin tocar el lote**. También
     * irreversible.
     */
    anular: (id: number, idEmpresa: number) =>
      request<{ ok: boolean }>(`/inventarios/anular/${id}/${idEmpresa}`, { method: "POST" }),
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
        /**
         * De qué lote sale la línea. **Obligatorio** salvo en artículos
         * `ES_GASTO`: el backend rechaza la venta sin él, y valida que el lote
         * sea de esta sucursal, del artículo, y que tenga existencia suficiente.
         */
        idLote?: number;
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
     * Borra la venta y **devuelve el stock** a los lotes de los que salió.
     *
     * `unidadesRepuestas` en 0 significa que la venta es anterior a
     * `VENTAS_DETALLES_LOTES`: no hay reparto guardado, así que no hay dónde
     * reponer. Se corrige con un inventario, no hay forma de deducirlo.
     */
    eliminar: (id: number, idEmpresa: number) =>
      request<{ ok: boolean; unidadesRepuestas: number }>(`/ventas/eliminar/${id}/${idEmpresa}`, {
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
