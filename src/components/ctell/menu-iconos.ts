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
  Settings,
  ShoppingCart,
  Sliders,
  Store,
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
  settings: Settings,
  shoppingcart: ShoppingCart,
  sliders: Sliders,
  store: Store,
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
  deposito: Warehouse,
  depositos: Warehouse,
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
