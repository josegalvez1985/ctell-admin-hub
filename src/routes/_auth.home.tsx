import { createFileRoute } from "@tanstack/react-router";
import { ArrowDownRight, ArrowUpRight, Banknote } from "lucide-react";
import { AppLayout } from "@/components/ctell/AppLayout";
import { LogoEmpresa } from "@/components/ctell/LogoEmpresa";
import { MenuDinamico } from "@/components/ctell/MenuDinamico";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { primerNombre, useUsuarioActual } from "@/hooks/use-usuario-actual";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import { Skeleton } from "@/components/ui/skeleton";
import { tituloPagina } from "@/lib/marca";

export const Route = createFileRoute("/_auth/home")({
  head: () => ({
    meta: [
      { title: tituloPagina("Dashboard") },
      {
        name: "description",
        content: "Dashboard con indicadores y menú personalizado según permisos.",
      },
      { property: "og:title", content: tituloPagina("Dashboard") },
      {
        property: "og:description",
        content: "Indicadores de compras, ventas, stock, tesorería y RRHH.",
      },
    ],
  }),
  component: HomePage,
});

const kpis = [
  { label: "Ventas del mes", value: "₲ 486.250.000", delta: "+12,4%", up: true },
  { label: "Compras del mes", value: "₲ 312.800.000", delta: "+4,1%", up: true },
  { label: "Saldo en tesorería", value: "₲ 98.140.000", delta: "-2,8%", up: false },
  { label: "Valor de stock", value: "₲ 214.500.000", delta: "+6,9%", up: true },
];

const movimientos = [
  {
    doc: "FAC-A 0012457",
    tipo: "Venta",
    parte: "Distribuidora Aurora",
    monto: "₲ 18.400.000",
    estado: "Cobrado",
  },
  {
    doc: "OC 004512",
    tipo: "Compra",
    parte: "Insumos del Este SRL",
    monto: "₲ 9.750.000",
    estado: "Pendiente",
  },
  {
    doc: "REC 008812",
    tipo: "Tesorería",
    parte: "Banco Continental",
    monto: "₲ 25.000.000",
    estado: "Conciliado",
  },
  {
    doc: "AJ-STK 1123",
    tipo: "Stock",
    parte: "Depósito Central",
    monto: "-142 un.",
    estado: "Aplicado",
  },
  {
    doc: "LIQ 07/2026",
    tipo: "RRHH",
    parte: "Nómina mensual",
    monto: "₲ 74.200.000",
    estado: "En proceso",
  },
];

const stockCritico = [
  { item: "Cable UTP Cat6 305m", nivel: 18 },
  { item: "Router empresarial X200", nivel: 34 },
  { item: "Fuente switching 48V", nivel: 52 },
  { item: "Conector RJ45 blindado", nivel: 9 },
];

function HomePage() {
  const { data: usuario } = useUsuarioActual();
  const { empresa } = useEmpresa();
  const nombre = primerNombre(usuario?.nombreApellido);
  const esperandoNombre = !usuario;

  return (
    <AppLayout active="Dashboard">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div className="flex items-center gap-3">
            {/* El provider hidrata desde localStorage DESPUÉS de montar, así que
                en el primer render `empresa` es null: sin el placeholder, el
                saludo saltaría de lugar al aparecer el logo. */}
            {empresa ? (
              <LogoEmpresa
                id={empresa.id}
                nombre={empresa.nombreEmpresa}
                tieneLogo={empresa.tieneLogo}
                className="size-14"
              />
            ) : (
              <Skeleton className="size-14 shrink-0 rounded-xl" />
            )}

            <div>
              {esperandoNombre ? (
                <Skeleton className="h-8 w-56 sm:h-9" />
              ) : (
                <h1 className="text-2xl font-bold text-foreground sm:text-3xl">
                  {nombre ? `Buen día, ${nombre}` : "Buen día"}
                </h1>
              )}
              <p className="mt-1 text-sm text-muted-foreground">
                {/* El nombre de la empresa activa en vez de "CTELL" fijo: con
                    varias empresas, saber en cuál se está parado importa. */}
                Resumen operativo de {empresa?.nombreEmpresa ?? "…"} · Agosto 2026
              </p>
            </div>
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

        <section>
          <h2 className="mb-4 text-sm font-semibold uppercase tracking-wider text-muted-foreground">
            Acceso rápido
          </h2>
          <div className="max-w-2xl">
            <MenuDinamico />
          </div>
        </section>
      </main>
    </AppLayout>
  );
}
