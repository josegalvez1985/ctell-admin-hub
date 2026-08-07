import { Link } from "@tanstack/react-router";
import {
  Bell,
  Boxes,
  Home,
  LayoutGrid,
  LogOut,
  PanelLeftClose,
  PanelLeftOpen,
  Search,
  Settings,
  ShoppingCart,
  Tags,
  Users,
  Wallet,
} from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";

import { Logo } from "@/components/ctell/Logo";
import { ThemeToggle } from "@/components/ctell/ThemeToggle";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

const COLLAPSE_KEY = "ctell-sidebar-collapsed";

export const navModules = [
  { name: "Compras", icon: ShoppingCart, to: "/home" },
  { name: "Ventas", icon: Tags, to: "/home" },
  { name: "Stock", icon: Boxes, to: "/home" },
  { name: "Tesorería", icon: Wallet, to: "/home" },
  { name: "RRHH", icon: Users, to: "/home" },
  { name: "Reportes", icon: LayoutGrid, to: "/home" },
];

const bottomNav = [
  { label: "Inicio", icon: Home, to: "/home" },
  { label: "Ventas", icon: Tags, to: "/home" },
  { label: "Stock", icon: Boxes, to: "/home" },
  { label: "Caja", icon: Wallet, to: "/home" },
  { label: "RRHH", icon: Users, to: "/home" },
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
  active?: string;
  /** Título mostrado en el header móvil. */
  title?: string;
  showSearch?: boolean;
}) {
  const [collapsed, setCollapsed] = useState(false);

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

        <nav className="mt-8 flex-1 space-y-1">
          <SideItem
            icon={Home}
            label="Panel general"
            to="/home"
            active={active === "Panel general"}
            collapsed={collapsed}
          />
          {navModules.map((module) => (
            <SideItem
              key={module.name}
              icon={module.icon}
              label={module.name}
              to={module.to}
              active={active === module.name}
              collapsed={collapsed}
            />
          ))}
        </nav>

        <div className="space-y-1 border-t border-sidebar-border pt-4">
          <SideItem
            icon={Settings}
            label="Configuración"
            to="/configuracion"
            active={active === "Configuración"}
            collapsed={collapsed}
          />
          <SideItem icon={LogOut} label="Salir" to="/" collapsed={collapsed} />
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
            {showSearch ? (
              <div className="relative ml-auto hidden max-w-sm flex-1 lg:block">
                <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
                <Input
                  placeholder="Buscar documentos, clientes, artículos…"
                  className="h-10 pl-9"
                />
              </div>
            ) : (
              <span className="ml-auto hidden lg:block" />
            )}
            <Button
              variant="ghost"
              size="icon"
              aria-label="Notificaciones"
              className="relative ml-auto lg:ml-0"
            >
              <Bell className="size-5" />
              <span className="absolute right-2 top-2 size-2 rounded-full bg-primary" />
            </Button>
            <ThemeToggle className="relative" />
            <Avatar className="size-9">
              <AvatarFallback className="bg-accent text-sm font-semibold text-accent-foreground">
                LM
              </AvatarFallback>
            </Avatar>
          </div>
        </header>

        {children}
      </div>

      <nav className="fixed inset-x-0 bottom-0 z-30 border-t border-border bg-card/95 pb-[env(safe-area-inset-bottom)] backdrop-blur-md lg:hidden">
        <ul className="grid grid-cols-5">
          {bottomNav.map((item) => (
            <li key={item.label}>
              <Link
                to={item.to}
                className={cn(
                  "flex w-full flex-col items-center gap-1 py-2.5 text-[11px] font-medium transition-colors",
                  active === item.label ? "text-primary" : "text-muted-foreground",
                )}
              >
                <item.icon className="size-5" />
                {item.label}
              </Link>
            </li>
          ))}
        </ul>
      </nav>
    </div>
  );
}

function SideItem({
  icon: Icon,
  label,
  active,
  to,
  collapsed,
}: {
  icon: typeof Home;
  label: string;
  active?: boolean;
  to: string;
  collapsed?: boolean;
}) {
  return (
    <Link
      to={to}
      title={collapsed ? label : undefined}
      className={cn(
        "flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors",
        collapsed && "justify-center px-0",
        active
          ? "bg-sidebar-primary text-sidebar-primary-foreground"
          : "text-sidebar-foreground/70 hover:bg-sidebar-accent hover:text-sidebar-accent-foreground",
      )}
    >
      <Icon className="size-4 shrink-0" />
      {!collapsed && label}
    </Link>
  );
}
