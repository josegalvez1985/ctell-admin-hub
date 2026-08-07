import { createFileRoute, Link } from "@tanstack/react-router";
import {
  ArrowDownRight,
  ArrowUpRight,
  Banknote,
  Bell,
  Boxes,
  Home,
  LayoutGrid,
  LogOut,
  Search,
  Settings,
  ShoppingCart,
  Tags,
  Users,
  Wallet,
} from "lucide-react";

import { Logo } from "@/components/ctell/Logo";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Progress } from "@/components/ui/progress";

export const Route = createFileRoute("/home")({
  head: () => ({
    meta: [
      { title: "Panel general | CTELL" },
      {
        name: "description",
        content:
          "Panel general de CTELL: indicadores de compras, ventas, stock, tesorería y recursos humanos en tiempo real.",
      },
      { property: "og:title", content: "Panel general | CTELL" },
      {
        property: "og:description",
        content: "Indicadores de compras, ventas, stock, tesorería y RRHH en un solo panel.",
      },
    ],
  }),
  component: HomePage,
});

const modules = [
  { name: "Compras", icon: ShoppingCart, detail: "12 órdenes pendientes" },
  { name: "Ventas", icon: Tags, detail: "38 facturas hoy" },
  { name: "Stock", icon: Boxes, detail: "7 artículos críticos" },
  { name: "Tesorería", icon: Wallet, detail: "4 pagos programados" },
  { name: "RRHH", icon: Users, detail: "56 empleados activos" },
  { name: "Reportes", icon: LayoutGrid, detail: "Cierre de mes" },
];

const kpis = [
  { label: "Ventas del mes", value: "₲ 486.250.000", delta: "+12,4%", up: true },
  { label: "Compras del mes", value: "₲ 312.800.000", delta: "+4,1%", up: true },
  { label: "Saldo en tesorería", value: "₲ 98.140.000", delta: "-2,8%", up: false },
  { label: "Valor de stock", value: "₲ 214.500.000", delta: "+6,9%", up: true },
];

const movimientos = [
  { doc: "FAC-A 0012457", tipo: "Venta", parte: "Distribuidora Aurora", monto: "₲ 18.400.000", estado: "Cobrado" },
  { doc: "OC 004512", tipo: "Compra", parte: "Insumos del Este SRL", monto: "₲ 9.750.000", estado: "Pendiente" },
  { doc: "REC 008812", tipo: "Tesorería", parte: "Banco Continental", monto: "₲ 25.000.000", estado: "Conciliado" },
  { doc: "AJ-STK 1123", tipo: "Stock", parte: "Depósito Central", monto: "-142 un.", estado: "Aplicado" },
  { doc: "LIQ 07/2026", tipo: "RRHH", parte: "Nómina mensual", monto: "₲ 74.200.000", estado: "En proceso" },
];

const stockCritico = [
  { item: "Cable UTP Cat6 305m", nivel: 18 },
  { item: "Router empresarial X200", nivel: 34 },
  { item: "Fuente switching 48V", nivel: 52 },
  { item: "Conector RJ45 blindado", nivel: 9 },
];

function HomePage() {
  return (
    <div className="min-h-screen bg-background">
      <aside className="fixed inset-y-0 left-0 z-30 hidden w-64 flex-col gradient-navy px-4 py-6 lg:flex">
        <Logo tone="dark" className="px-2" />
        <nav className="mt-8 flex-1 space-y-1">
          <SideItem icon={Home} label="Panel general" active />
          {modules.map((module) => (
            <SideItem key={module.name} icon={module.icon} label={module.name} />
          ))}
        </nav>
        <div className="space-y-1 border-t border-sidebar-border pt-4">
          <SideItem icon={Settings} label="Configuración" />
          <Link
            to="/"
            className="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium text-sidebar-foreground/70 transition-colors hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
          >
            <LogOut className="size-4" /> Salir
          </Link>
        </div>
      </aside>

      <div className="lg:pl-64">
        <header className="sticky top-0 z-20 border-b border-border bg-card/85 backdrop-blur-md">
          <div className="flex h-16 items-center gap-3 px-4 sm:px-6">
            <div className="lg:hidden">
              <Logo />
            </div>
            <div className="relative ml-auto hidden max-w-sm flex-1 lg:block">
              <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input placeholder="Buscar documentos, clientes, artículos…" className="h-10 pl-9" />
            </div>
            <Button variant="ghost" size="icon" aria-label="Notificaciones" className="relative ml-auto lg:ml-0">
              <Bell className="size-5" />
              <span className="absolute right-2 top-2 size-2 rounded-full bg-primary" />
            </Button>
            <Avatar className="size-9">
              <AvatarFallback className="bg-accent text-sm font-semibold text-accent-foreground">
                LM
              </AvatarFallback>
            </Avatar>
          </div>
        </header>

        <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
          <div className="flex flex-wrap items-end justify-between gap-3">
            <div>
              <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Buen día, Lucía</h1>
              <p className="mt-1 text-sm text-muted-foreground">
                Resumen operativo de CTELL · Agosto 2026
              </p>
            </div>
            <Button className="hidden sm:inline-flex">Nueva operación</Button>
          </div>

          <section className="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-4">
            {kpis.map((kpi) => (
              <article key={kpi.label} className="surface-card p-4 sm:p-5">
                <p className="text-xs font-medium text-muted-foreground sm:text-sm">{kpi.label}</p>
                <p className="mt-2 font-display text-lg font-bold text-foreground sm:text-2xl">
                  {kpi.value}
                </p>
                <p
                  className={`mt-2 flex items-center gap-1 text-xs font-semibold ${
                    kpi.up ? "text-success" : "text-destructive"
                  }`}
                >
                  {kpi.up ? (
                    <ArrowUpRight className="size-3.5" />
                  ) : (
                    <ArrowDownRight className="size-3.5" />
                  )}
                  {kpi.delta}
                </p>
              </article>
            ))}
          </section>

          <section>
            <h2 className="text-sm font-semibold uppercase tracking-wider text-muted-foreground">
              Módulos
            </h2>
            <div className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-3 sm:gap-4 xl:grid-cols-6">
              {modules.map((module) => (
                <button
                  key={module.name}
                  className="surface-card group flex flex-col items-start gap-3 p-4 text-left transition-all hover:-translate-y-0.5 hover:shadow-elevated"
                >
                  <span className="gradient-primary flex size-10 items-center justify-center rounded-xl text-primary-foreground">
                    <module.icon className="size-5" />
                  </span>
                  <span>
                    <span className="block text-sm font-semibold text-foreground">{module.name}</span>
                    <span className="mt-0.5 block text-xs text-muted-foreground">{module.detail}</span>
                  </span>
                </button>
              ))}
            </div>
          </section>

          <div className="grid gap-4 xl:grid-cols-3">
            <section className="surface-card xl:col-span-2">
              <div className="flex items-center justify-between border-b border-border px-4 py-4 sm:px-5">
                <h2 className="text-base font-semibold text-foreground">Últimos movimientos</h2>
                <Button variant="ghost" size="sm">
                  Ver todo
                </Button>
              </div>
              <ul className="divide-y divide-border">
                {movimientos.map((mov) => (
                  <li
                    key={mov.doc}
                    className="flex items-center justify-between gap-3 px-4 py-3.5 sm:px-5"
                  >
                    <div className="min-w-0">
                      <p className="truncate text-sm font-semibold text-foreground">{mov.parte}</p>
                      <p className="mt-0.5 truncate text-xs text-muted-foreground">
                        {mov.tipo} · {mov.doc}
                      </p>
                    </div>
                    <div className="flex shrink-0 flex-col items-end gap-1">
                      <span className="text-sm font-semibold text-foreground">{mov.monto}</span>
                      <Badge variant="secondary" className="text-[10px] font-medium">
                        {mov.estado}
                      </Badge>
                    </div>
                  </li>
                ))}
              </ul>
            </section>

            <section className="surface-card p-4 sm:p-5">
              <h2 className="text-base font-semibold text-foreground">Stock crítico</h2>
              <p className="mt-1 text-xs text-muted-foreground">
                Nivel de cobertura respecto al mínimo definido.
              </p>
              <ul className="mt-5 space-y-4">
                {stockCritico.map((row) => (
                  <li key={row.item}>
                    <div className="flex items-center justify-between text-sm">
                      <span className="truncate pr-3 text-foreground">{row.item}</span>
                      <span className="font-semibold text-muted-foreground">{row.nivel}%</span>
                    </div>
                    <Progress value={row.nivel} className="mt-2 h-1.5" />
                  </li>
                ))}
              </ul>
              <div className="mt-6 flex items-center gap-3 rounded-xl bg-accent p-3">
                <Banknote className="size-5 shrink-0 text-accent-foreground" />
                <p className="text-xs text-accent-foreground">
                  4 pagos a proveedores vencen esta semana.
                </p>
              </div>
            </section>
          </div>
        </main>
      </div>

      <nav className="fixed inset-x-0 bottom-0 z-30 border-t border-border bg-card/95 pb-[env(safe-area-inset-bottom)] backdrop-blur-md lg:hidden">
        <ul className="grid grid-cols-5">
          {[
            { label: "Inicio", icon: Home, active: true },
            { label: "Ventas", icon: Tags },
            { label: "Stock", icon: Boxes },
            { label: "Caja", icon: Wallet },
            { label: "RRHH", icon: Users },
          ].map((item) => (
            <li key={item.label}>
              <button
                className={`flex w-full flex-col items-center gap-1 py-2.5 text-[11px] font-medium transition-colors ${
                  item.active ? "text-primary" : "text-muted-foreground"
                }`}
              >
                <item.icon className="size-5" />
                {item.label}
              </button>
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
}: {
  icon: typeof Home;
  label: string;
  active?: boolean;
}) {
  return (
    <button
      className={`flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors ${
        active
          ? "bg-sidebar-primary text-sidebar-primary-foreground"
          : "text-sidebar-foreground/70 hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
      }`}
    >
      <Icon className="size-4" />
      {label}
    </button>
  );
}
