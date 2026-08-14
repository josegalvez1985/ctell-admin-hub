import { useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate } from "@tanstack/react-router";
import {
  Bell,
  Home,
  LogOut,
  Menu,
  PanelLeftClose,
  PanelLeftOpen,
  Search,
  Settings,
  X,
} from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";

import { Logo } from "@/components/ctell/Logo";
import { MenuDinamico } from "@/components/ctell/MenuDinamico";
import { ThemeToggle } from "@/components/ctell/ThemeToggle";
import { iniciales, useUsuarioActual } from "@/hooks/use-usuario-actual";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { api, getUsuarioSesion } from "@/lib/api";
import { cn } from "@/lib/utils";

const COLLAPSE_KEY = "ctell-sidebar-collapsed";

const mobileMenuItems = [
  { label: "Inicio", icon: Home, to: "/home" },
  { label: "Configuración", icon: Settings, to: "/configuracion" },
  { label: "Salir", icon: LogOut, to: undefined, action: "logout" },
];

/**
 * Layout persistente de la aplicación: sidebar colapsable + header + barra
 * inferior móvil. Las páginas sólo aportan su contenido, de modo que la
 * navegación se mantiene al cambiar de ruta.
 */
export function AppLayout({
  children,
  active,
  title,
  showSearch = true,
}: {
  children: ReactNode;
  /** Etiqueta del item de menú que debe marcarse como activo. */
  active?: string | undefined;
  /** Título mostrado en el header móvil. */
  title?: string | undefined;
  showSearch?: boolean;
}) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { data: usuarioRefresh } = useUsuarioActual();
  const usuarioSesion = getUsuarioSesion();
  const usuario = usuarioRefresh || usuarioSesion;
  const [collapsed, setCollapsed] = useState(false);
  const [saliendo, setSaliendo] = useState(false);
  const [menuAbierto, setMenuAbierto] = useState(false);

  // La preferencia se lee tras montar para no romper la hidratación SSR.
  useEffect(() => {
    setCollapsed(localStorage.getItem(COLLAPSE_KEY) === "1");
  }, []);

  function toggleCollapsed() {
    setCollapsed((prev) => {
      const next = !prev;
      localStorage.setItem(COLLAPSE_KEY, next ? "1" : "0");
      return next;
    });
  }

  // Navegar a "/" sin llamar a logout dejaba el token vigente en el servidor y
  // en sessionStorage: volver atrás reabría la sesión.
  async function handleLogout() {
    if (saliendo) return; // Evita revocar dos veces con doble clic.
    setSaliendo(true);

    try {
      // api.logout() borra el token local aunque el servidor falle, así que un
      // error acá no impide cerrar sesión: se sigue de largo. Sin el try, una
      // caída de red dejaría al usuario encerrado en la app.
      await api.logout();
    } finally {
      // La caché guarda datos del usuario que se va; sin limpiarla, quien
      // entre después los ve por un instante antes del refetch.
      queryClient.clear();
      navigate({ to: "/" });
    }
  }

  return (
    <div className="min-h-screen bg-background">
      <aside
        className={cn(
          "gradient-navy fixed inset-y-0 left-0 z-30 hidden flex-col py-6 transition-[width] duration-200 lg:flex",
          collapsed ? "w-20 px-2" : "w-64 px-4",
        )}
      >
        <div
          className={cn("flex items-center", collapsed ? "justify-center" : "justify-between px-2")}
        >
          {collapsed ? <Logo tone="dark" showWordmark={false} /> : <Logo tone="dark" />}
        </div>

        {/* scrollbar-fino: la barra nativa de Windows, gris y ancha, desentona
            contra el sidebar oscuro. Toma su color de currentColor, así que se
            adapta sola al tema. */}
        <nav className="scrollbar-fino mt-8 flex-1 space-y-1 overflow-y-auto">
          <SideItem
            icon={Home}
            label="Dashboard"
            to="/home"
            active={active === "Dashboard"}
            collapsed={collapsed}
          />
          {!collapsed && (
            <div className="pt-4">
              <MenuDinamico active={active} variant="dark" />
            </div>
          )}
        </nav>

        <div className="space-y-1 border-t border-sidebar-border pt-4">
          <SideItem
            icon={Settings}
            label="Configuración"
            to="/configuracion"
            active={active === "Configuración"}
            collapsed={collapsed}
          />
          <SideItem
            icon={LogOut}
            label={saliendo ? "Saliendo…" : "Salir"}
            onClick={handleLogout}
            disabled={saliendo}
            collapsed={collapsed}
          />
          <button
            onClick={toggleCollapsed}
            aria-label={collapsed ? "Expandir menú" : "Colapsar menú"}
            title={collapsed ? "Expandir menú" : "Colapsar menú"}
            className={cn(
              "mt-2 flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium text-sidebar-foreground/70 transition-colors hover:bg-sidebar-accent hover:text-sidebar-accent-foreground",
              collapsed && "justify-center px-0",
            )}
          >
            {collapsed ? (
              <PanelLeftOpen className="size-4 shrink-0" />
            ) : (
              <>
                <PanelLeftClose className="size-4 shrink-0" />
                Colapsar
              </>
            )}
          </button>
        </div>
      </aside>

      <div className={cn("transition-[padding] duration-200", collapsed ? "lg:pl-20" : "lg:pl-64")}>
        <header className="sticky top-0 z-20 border-b border-border bg-card/85 backdrop-blur-md">
          <div className="flex h-16 items-center gap-3 px-4 sm:px-6">
            <div className="lg:hidden">
              <Logo showWordmark={false} />
            </div>
            {title && (
              <span className="font-display text-lg font-bold text-foreground lg:hidden">
                {title}
              </span>
            )}
            {showSearch && (
              <div className="relative ml-auto hidden max-w-sm flex-1 lg:flex lg:items-center lg:gap-4">
                <div className="relative flex-1">
                  <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
                  <Input
                    placeholder="Buscar documentos, clientes, artículos…"
                    className="h-10 pl-9"
                  />
                </div>
                {usuario?.nombreApellido && (
                  <div className="flex items-center gap-3 border-l border-border pl-4">
                    <div className="text-right">
                      <p className="text-sm font-semibold text-foreground">
                        {usuario.nombreApellido}
                      </p>
                      <p className="text-xs text-muted-foreground">
                        {usuario.esAdmin === "S" ? "Administrador" : "Usuario"}
                      </p>
                    </div>
                  </div>
                )}
              </div>
            )}
            {!showSearch && <span className="ml-auto hidden lg:block" />}
            <Button
              variant="ghost"
              size="icon"
              aria-label="Notificaciones"
              className="relative ml-auto lg:ml-0"
            >
              <Bell className="size-5" />
              <span className="absolute right-2 top-2 size-2 rounded-full bg-primary" />
            </Button>
            <Link to="/home" className="lg:hidden">
              <Button variant="ghost" size="icon" aria-label="Ir a inicio" title="Ir a inicio">
                <Home className="size-5" />
              </Button>
            </Link>
            <ThemeToggle className="relative" />
            <Button
              variant="ghost"
              size="icon"
              onClick={handleLogout}
              disabled={saliendo}
              aria-label="Salir"
              title="Salir de la sesión"
              className="text-destructive hover:text-destructive hover:bg-destructive/10 disabled:opacity-60"
            >
              <LogOut className="size-5" />
            </Button>
            <Avatar className="size-9" title={usuario?.nombreApellido}>
              <AvatarFallback className="bg-accent text-sm font-semibold text-accent-foreground">
                {iniciales(usuario?.nombreApellido)}
              </AvatarFallback>
            </Avatar>
          </div>
        </header>

        {children}
      </div>

      <Button
        variant="ghost"
        size="icon"
        onClick={() => setMenuAbierto(!menuAbierto)}
        className="fixed bottom-6 right-6 z-30 size-14 rounded-full bg-primary text-primary-foreground shadow-lg hover:bg-primary/90 lg:hidden"
        aria-label="Abrir menú"
      >
        {menuAbierto ? <X className="size-6" /> : <Menu className="size-6" />}
      </Button>

      {menuAbierto && (
        <>
          <div
            className="fixed inset-0 z-20 bg-black/40 backdrop-blur-sm transition-opacity lg:hidden"
            onClick={() => setMenuAbierto(false)}
          />
          <div className="scrollbar-fino fixed inset-x-0 bottom-0 z-30 max-h-[85vh] overflow-y-auto rounded-t-3xl border-t border-border bg-card shadow-2xl lg:hidden">
            <div className="sticky top-0 flex items-center justify-between border-b border-border bg-card px-6 py-4">
              <h2 className="text-xl font-bold text-foreground">Menú</h2>
              <button
                onClick={() => setMenuAbierto(false)}
                className="text-muted-foreground transition-colors hover:text-foreground"
                aria-label="Cerrar menú"
              >
                <X className="size-5" />
              </button>
            </div>

            <nav className="p-4 space-y-2">
              {mobileMenuItems.map((item) => {
                const handleClick = () => {
                  if (item.action === "logout") {
                    handleLogout();
                  } else {
                    setMenuAbierto(false);
                  }
                };

                const isActive = active === item.label;
                const Icon = item.icon;

                if (item.action === "logout") {
                  return (
                    <button
                      key={item.label}
                      onClick={handleClick}
                      disabled={saliendo}
                      className={cn(
                        "w-full flex items-center gap-3 px-4 py-3 rounded-lg text-sm font-medium transition-all",
                        "text-destructive hover:bg-destructive/10 disabled:opacity-60 disabled:pointer-events-none",
                      )}
                    >
                      <Icon className="size-5 shrink-0" />
                      <span>{saliendo ? "Saliendo…" : item.label}</span>
                    </button>
                  );
                }

                return (
                  <Link
                    key={item.label}
                    to={item.to!}
                    onClick={() => setMenuAbierto(false)}
                    className={cn(
                      "flex items-center gap-3 px-4 py-3 rounded-lg text-sm font-medium transition-all",
                      isActive
                        ? "bg-primary text-primary-foreground"
                        : "text-muted-foreground hover:bg-accent hover:text-foreground",
                    )}
                  >
                    <Icon className="size-5 shrink-0" />
                    <span>{item.label}</span>
                  </Link>
                );
              })}
            </nav>

            <div className="border-t border-border p-4">
              <MenuDinamico active={active} />
            </div>

            <div className="border-t border-border p-4">
              <div className="flex items-center gap-3 px-2">
                <Avatar className="size-10">
                  <AvatarFallback className="bg-accent text-sm font-semibold text-accent-foreground">
                    {iniciales(usuario?.nombreApellido)}
                  </AvatarFallback>
                </Avatar>
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-semibold text-foreground truncate">
                    {usuario?.nombreApellido}
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {usuario?.esAdmin === "S" ? "Administrador" : "Usuario"}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </>
      )}
    </div>
  );
}

/** Item del menú lateral: enlaza con `to`, o ejecuta una acción con `onClick`. */
function SideItem({
  icon: Icon,
  label,
  active,
  to,
  onClick,
  disabled,
  collapsed,
}: {
  icon: typeof Home;
  label: string;
  active?: boolean;
  to?: string;
  onClick?: () => void;
  disabled?: boolean;
  collapsed?: boolean;
}) {
  const clases = cn(
    "flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors",
    collapsed && "justify-center px-0",
    active
      ? "bg-sidebar-primary text-sidebar-primary-foreground"
      : "text-sidebar-foreground/70 hover:bg-sidebar-accent hover:text-sidebar-accent-foreground",
  );

  const contenido = (
    <>
      <Icon className="size-4 shrink-0" />
      {!collapsed && label}
    </>
  );

  // Cerrar sesión no es una navegación: tiene que revocar el token primero.
  if (onClick) {
    return (
      <button
        onClick={onClick}
        disabled={disabled}
        title={collapsed ? label : undefined}
        className={cn(clases, disabled && "pointer-events-none opacity-60")}
      >
        {contenido}
      </button>
    );
  }

  return (
    <Link to={to!} title={collapsed ? label : undefined} className={clases}>
      {contenido}
    </Link>
  );
}
