/**
 * Íconos del menú dinámico.
 *
 * El menú se arma con datos que carga una persona desde el ABM, así que el
 * ícono no puede venir hardcodeado por ruta: se resuelve por nombre. Hay tres
 * niveles, del más específico al más genérico:
 *
 *   1. `ICONOS_MODULO` / `ICONOS_PAGINA` — coincidencia por nombre.
 *   2. `MODULOS.ICONO` — lo que se haya cargado en el ABM de módulos.
 *   3. Un ícono por defecto, distinto según sea módulo, entrada o página.
 *
 * Se importan sólo los íconos usados en vez de todo lucide-react: el paquete
 * entero son miles de componentes y el bundle lo nota.
 */
import {
  Archive,
  BadgeDollarSign,
  Banknote,
  Boxes,
  Building,
  Building2,
  CalendarClock,
  CircleDot,
  ClipboardCheck,
  ClipboardList,
  Cog,
  Coins,
  Component,
  Contact,
  CreditCard,
  Database,
  FileBarChart,
  FileInput,
  FileOutput,
  FileText,
  Files,
  Globe,
  GraduationCap,
  Grid3x3,
  HandCoins,
  IdCard,
  KeyRound,
  Landmark,
  LayoutGrid,
  Map,
  MapPin,
  Package,
  PackageCheck,
  PackageSearch,
  PiggyBank,
  Percent,
  Receipt,
  Ruler,
  School,
  Settings,
  ShoppingCart,
  Sliders,
  Store,
  Tag,
  Tags,
  TicketCheck,
  TrendingUp,
  Truck,
  UserCog,
  Users,
  Wallet,
  Warehouse,
  Workflow,
  type LucideIcon,
} from "lucide-react";

/** Normaliza para comparar: sin acentos, sin mayúsculas, sin espacios de más. */
function clave(texto: string): string {
  return texto.trim().toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
}

/**
 * Todos los íconos que puede referenciar `MODULOS.ICONO`.
 *
 * Es un mapa explícito y no un lookup dinámico sobre lucide-react porque el
 * bundler necesita saber en tiempo de compilación qué se importa; además, un
 * nombre mal escrito en la base caería en el default en vez de romper.
 */
const POR_NOMBRE: Record<string, LucideIcon> = {
  banknote: Banknote,
  boxes: Boxes,
  building: Building,
  building2: Building2,
  calendarclock: CalendarClock,
  clipboardlist: ClipboardList,
  cog: Cog,
  coins: Coins,
  creditcard: CreditCard,
  database: Database,
  filebarchart: FileBarChart,
  filetext: FileText,
  globe: Globe,
  landmark: Landmark,
  layoutgrid: LayoutGrid,
  map: Map,
  mappin: MapPin,
  package: Package,
  percent: Percent,
  receipt: Receipt,
  ruler: Ruler,
  settings: Settings,
  shoppingcart: ShoppingCart,
  sliders: Sliders,
  store: Store,
  tags: Tags,
  truck: Truck,
  usercog: UserCog,
  users: Users,
  wallet: Wallet,
  warehouse: Warehouse,
};

/**
 * Módulos conocidos del negocio.
 *
 * NINGUNO REPITE EL ÍCONO DE UNA PÁGINA. El módulo es el encabezado que agrupa;
 * si usa el mismo ícono que una de sus páginas, el grupo se confunde con su
 * propio contenido — que es justo lo que pasaba con ventas/sucursales,
 * rrhh/personas y stock/ubicaciones.
 */
const ICONOS_MODULO: Record<string, LucideIcon> = {
  base: Database,
  compras: ShoppingCart,
  // TrendingUp y no Store: Store ya es "sucursales", una página que cuelga de
  // este mismo módulo. Lo que define a Ventas es el movimiento comercial, no el
  // local donde ocurre.
  ventas: TrendingUp,
  // Archive y no Warehouse: Warehouse ya es "depósito" y "ubicaciones". El
  // módulo agrupa todo el manejo de existencias, no el edificio.
  stock: Archive,
  tesoreria: Wallet,
  // Users queda para las páginas de personas; el módulo lleva UserCog… que ya
  // es "usuarios". Contact es la ficha del legajo, que es de lo que trata RRHH.
  rrhh: Contact,
  "recursos humanos": Contact,
  administracion: Cog,
  configuracion: Settings,
};

/** Páginas frecuentes. La coincidencia es por nombre completo. */
const ICONOS_PAGINA: Record<string, LucideIcon> = {
  paises: Globe,
  pais: Globe,
  // La jerarquía geográfica usa tres íconos distintos: con el mismo MapPin
  // para los tres, el menú no deja distinguir un nivel de otro de un vistazo.
  departamentos: Map,
  departamento: Map,
  provincias: Map,
  ciudades: MapPin,
  ciudad: MapPin,
  barrios: Building,
  barrio: Building,
  empresas: Building2,
  empresa: Building2,
  // Distinto de empresas: la sucursal es un local, la empresa la organización.
  sucursales: Store,
  sucursal: Store,
  proveedores: Truck,
  // IdCard y no Users: Users es el padrón general de personas, y el cliente es
  // una relación comercial concreta —la cuenta a la que se le vende—, no
  // simplemente "varias personas". ShoppingCart tampoco sirve acá: ya es el
  // módulo Compras.
  clientes: IdCard,
  // School y NO Building/Building2/Landmark: Building ya es "barrios",
  // Building2 "empresas" y Landmark "bancos" — los tres edificios genéricos
  // están tomados, y con cualquiera de ellos la institución se confundiría con
  // la empresa dueña del sistema. School representa al colegio, que es el caso
  // típico de esta tabla, sin pisar a ninguno.
  instituciones: School,
  institucion: School,
  // GraduationCap y NO Users/IdCard/Contact: Users ya es "personas" (el padrón
  // general), IdCard "clientes" y Contact "recursos humanos" — con cualquiera
  // de ellos el profesor se vería igual que otro grupo de gente. El birrete es
  // lo que lo distingue, y hace juego con School (instituciones), que es la
  // tabla con la que se lo lee en el menú.
  profesores: GraduationCap,
  profesor: GraduationCap,
  docentes: GraduationCap,
  docente: GraduationCap,
  // Users (varias personas) y no UserCog: el padrón son las personas del
  // negocio; UserCog ya es "usuarios", que son las cuentas del sistema.
  personas: Users,
  persona: Users,
  usuarios: UserCog,
  articulos: Package,
  productos: Package,
  // La lupa sobre la caja: es la CONSULTA de cuánto hay, no el ABM del
  // artículo (Package) ni la asignación a una ubicación (PackageCheck). Los
  // tres son de la misma familia a propósito — hablan del mismo objeto— y se
  // distinguen por lo que se hace con él.
  existencias: PackageSearch,
  existencia: PackageSearch,
  "existencia de articulos": PackageSearch,
  "existencias de articulos": PackageSearch,
  "consulta de existencias": PackageSearch,
  // Banknote y no Coins: Coins ya es "cobros", y con el mismo ícono no se
  // distinguiría la moneda —la divisa— del movimiento de caja.
  monedas: Banknote,
  moneda: Banknote,
  // La regla es lo que mide, sin confundirse con "artículos" (la caja).
  "unidades de medida": Ruler,
  "unidad de medida": Ruler,
  unidades: Ruler,
  // Tag (UNA etiqueta, la de la oferta) y no Tags (VARIAS), que ya es
  // "categorías": lo que define a la lista es el descuento que le cuelga al
  // artículo, no la agrupación.
  //
  // NI Percent NI Banknote: Percent ya es "IVA" —la otra página del menú que
  // habla de porcentajes, y son justo las dos que más se confundirían— y
  // Banknote ya es "monedas". La lista no es la tasa ni la divisa: es la
  // etiqueta con la que sale el artículo.
  //
  // Se mapean las variantes del nombre porque el menú lo carga una persona
  // desde el ABM y no hay garantía de cómo lo escriba. Se dejan también las
  // de "precios": la tabla se llamó LISTAS_PRECIOS y el ítem puede haber
  // quedado cargado con ese nombre.
  "listas de descuentos": Tag,
  "lista de descuentos": Tag,
  "listas descuentos": Tag,
  descuentos: Tag,
  "listas de precios": Tag,
  "lista de precios": Tag,
  "listas precios": Tag,
  listas: Tag,
  precios: Tag,
  // Las etiquetas agrupan artículos; Boxes o Package los representarían a
  // ellos, no a la agrupación.
  categorias: Tags,
  categoria: Tags,
  rubros: Tags,
  // El depósito es el edificio; "ubicaciones" (abajo) es la posición DENTRO de
  // él, y por eso lleva otro ícono.
  deposito: Warehouse,
  depositos: Warehouse,
  // Boxes (varias cajas) y no Package (una): un lote es una PARTIDA de
  // mercadería, no la unidad — que ya es "artículos".
  lotes: Boxes,
  lote: Boxes,
  // NI MapPin NI Warehouse: MapPin ya es "ciudades" y haría pensar en una
  // dirección; Warehouse ya es "depósito", el edificio entero. La ubicación es
  // la posición dentro de él (zona/estante/nivel), que es lo que Grid3x3 —la
  // grilla de estantes— representa sin pisar a ninguno de los dos.
  ubicaciones: Grid3x3,
  ubicacion: Grid3x3,
  // PÁGINA DISTINTA de "ubicaciones": aquélla define los lugares del depósito,
  // ésta asigna QUÉ ARTÍCULO va en cada uno. Sin esta entrada caía en el
  // fallback FileText y quedaba igual a cualquier otra página sin mapear — dos
  // íconos repetidos en el menú de Stock.
  //
  // Se mapean las variantes del nombre porque el menú lo carga una persona desde
  // el ABM y no hay garantía de cómo lo escriba.
  "ubicaciones de articulos": PackageCheck,
  "ubicacion de articulos": PackageCheck,
  "articulos ubicaciones": PackageCheck,
  "articulos por ubicacion": PackageCheck,
  // La planilla del conteo, no la mercadería: un inventario es el ACTO de
  // contar, así que Boxes o Package (que ya son lotes y artículos) apuntarían a
  // lo contado en vez de a la tarea.
  //
  // ClipboardCheck (la planilla ya verificada) y no ClipboardList: así queda
  // libre para "órdenes", el pedido pendiente. Antes las dos compartían ícono.
  inventarios: ClipboardCheck,
  inventario: ClipboardCheck,
  ordenes: ClipboardList,
  "ordenes de compra": ClipboardList,
  // COMPRA Y VENTA NO COMPARTEN ÍCONO: son los dos comprobantes que más se
  // confunden en el menú, y con el mismo Receipt sólo los distinguía el texto.
  // FileInput es lo que entra (compra), FileOutput lo que sale (venta).
  facturas: Receipt,
  "facturas de compra": FileInput,
  "facturas compras": FileInput,
  "facturas de venta": FileOutput,
  // Percent y no Receipt: la tasa es el porcentaje, no el comprobante — con el
  // mismo ícono que "facturas" los dos ítems del menú se confundirían.
  iva: Percent,
  "tasas de iva": Percent,
  // CalendarClock y no CreditCard: lo que define una condición es el PLAZO
  // (cuántos días, cuántas cuotas), no el medio de pago. CreditCard ya es
  // "pagos" y haría pensar en tarjetas.
  "condiciones de pago": CalendarClock,
  "condicion de pago": CalendarClock,
  condiciones: CalendarClock,
  talonarios: TicketCheck,
  talonario: TicketCheck,
  "canales de pago": HandCoins,
  "canal de pago": HandCoins,
  "canales pagos": HandCoins,
  cobros: Coins,
  pagos: CreditCard,
  bancos: Landmark,
  "cuentas bancarias": PiggyBank,
  "punto de venta": BadgeDollarSign,
  // Las tres páginas de Administración. Sin ellas caían las tres en el fallback
  // FileText y el módulo entero se veía con el mismo ícono repetido.
  //
  // Component y NO LayoutGrid: LayoutGrid es el fallback de módulo, así que un
  // módulo nuevo sin mapear se vería idéntico a la página "Módulos".
  modulos: Component,
  modulo: Component,
  // Files (varios documentos) y NO FileText: FileText es el fallback de página,
  // así que "páginas" se vería igual que cualquier página futura sin mapear —
  // exactamente el problema que estas entradas vienen a cerrar.
  paginas: Files,
  pagina: Files,
  // UserCog ya es "usuarios"; el permiso es la llave, no la cuenta.
  permisos: KeyRound,
  permiso: KeyRound,
};

/**
 * Ícono fijo por tipo de entrada: define la sección, no el contenido.
 *
 * Los tres tienen que ser distintos ENTRE SÍ y distintos del fallback: la
 * entrada es el encabezado que agrupa páginas, así que repetir el ícono de una
 * de ellas hace que el grupo se confunda con su propio contenido.
 *
 * Operaciones usa Workflow y no ClipboardList: la planilla ya es "inventarios"
 * y "órdenes de compra", dos páginas que cuelgan justo de esta entrada. Lo que
 * define a la sección es el proceso, no el comprobante que produce.
 */
const ICONOS_ENTRADA: Record<string, LucideIcon> = {
  D: Sliders,
  O: Workflow,
  R: FileBarChart,
};

/**
 * Ícono de un módulo. Primero por nombre conocido, después lo cargado en el
 * ABM, y si nada coincide una grilla genérica.
 */
export function iconoDeModulo(nombre: string, icono: string | null): LucideIcon {
  return (
    ICONOS_MODULO[clave(nombre)] ?? (icono ? POR_NOMBRE[clave(icono)] : undefined) ?? LayoutGrid
  );
}

/** Ícono de una página, por nombre. Cae en un documento genérico. */
export function iconoDePagina(nombre: string): LucideIcon {
  return ICONOS_PAGINA[clave(nombre)] ?? FileText;
}

/**
 * Ícono de la sección: Definiciones, Operaciones o Reportes.
 *
 * CircleDot como default y no ClipboardList: el fallback sólo se alcanza con un
 * código de entrada que no sea ninguno de los tres, y con ClipboardList esa
 * entrada desconocida se dibujaba idéntica a Operaciones. Un marcador neutro no
 * afirma nada sobre un contenido que no se conoce.
 */
export function iconoDeEntrada(entrada: string): LucideIcon {
  return ICONOS_ENTRADA[entrada] ?? CircleDot;
}
