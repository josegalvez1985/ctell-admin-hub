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
  Banknote,
  Boxes,
  Building,
  Building2,
  ClipboardList,
  Cog,
  Coins,
  CreditCard,
  Database,
  FileBarChart,
  FileText,
  Globe,
  Landmark,
  LayoutGrid,
  Map,
  MapPin,
  Package,
  Receipt,
  Ruler,
  Settings,
  ShoppingCart,
  Sliders,
  Store,
  Tags,
  Truck,
  UserCog,
  Users,
  Wallet,
  Warehouse,
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

/** Módulos conocidos del negocio. */
const ICONOS_MODULO: Record<string, LucideIcon> = {
  base: Database,
  compras: ShoppingCart,
  ventas: Store,
  stock: Warehouse,
  tesoreria: Wallet,
  rrhh: Users,
  "recursos humanos": Users,
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
  clientes: Users,
  usuarios: UserCog,
  articulos: Package,
  productos: Package,
  // Banknote y no Coins: Coins ya es "cobros", y con el mismo ícono no se
  // distinguiría la moneda —la divisa— del movimiento de caja.
  monedas: Banknote,
  moneda: Banknote,
  // La regla es lo que mide, sin confundirse con "artículos" (la caja).
  "unidades de medida": Ruler,
  "unidad de medida": Ruler,
  unidades: Ruler,
  // Las etiquetas agrupan artículos; Boxes o Package los representarían a
  // ellos, no a la agrupación.
  categorias: Tags,
  categoria: Tags,
  rubros: Tags,
  deposito: Warehouse,
  depositos: Warehouse,
  // Boxes (varias cajas) y no Package (una): un lote es una PARTIDA de
  // mercadería, no la unidad — que ya es "artículos".
  lotes: Boxes,
  lote: Boxes,
  // Warehouse y NO MapPin: la ubicación acá es la posición dentro del depósito
  // (zona/estante/nivel), y MapPin ya es "ciudades" — el ícono geográfico haría
  // pensar en una dirección.
  ubicaciones: Warehouse,
  ubicacion: Warehouse,
  ordenes: ClipboardList,
  "ordenes de compra": ClipboardList,
  facturas: Receipt,
  cobros: Coins,
  pagos: CreditCard,
  bancos: Landmark,
};

/** Ícono fijo por tipo de entrada: define la sección, no el contenido. */
const ICONOS_ENTRADA: Record<string, LucideIcon> = {
  D: Sliders,
  O: ClipboardList,
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

/** Ícono de la sección: Definiciones, Operaciones o Reportes. */
export function iconoDeEntrada(entrada: string): LucideIcon {
  return ICONOS_ENTRADA[entrada] ?? ClipboardList;
}
