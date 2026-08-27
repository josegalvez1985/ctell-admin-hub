import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { ArrowDownRight, ArrowUpRight, Banknote, Building2 } from "lucide-react";
import { AppLayout } from "@/components/ctell/AppLayout";
import { LogoEmpresa } from "@/components/ctell/LogoEmpresa";
import { AccesosRapidos } from "@/components/ctell/AccesosRapidos";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import { primerNombre, useUsuarioActual } from "@/hooks/use-usuario-actual";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { api } from "@/lib/api";
import { tituloPagina } from "@/lib/marca";
import { formatearMoneda } from "@/lib/moneda";

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

/**
 * La variación contra el mes anterior, lista para mostrar.
 *
 * Devuelve `null` cuando el mes anterior fue 0: ahí la variación **no existe**
 * —no es 0% ni infinito— y mostrar cualquier número sería inventar una
 * comparación. Es el caso del primer mes de uso del sistema, que no es raro.
 */
function variacion(actual: number, anterior: number) {
  if (anterior === 0) return null;
  const porcentaje = ((actual - anterior) / anterior) * 100;
  return {
    texto: `${porcentaje >= 0 ? "+" : "−"}${formatearMoneda(Math.abs(porcentaje))}%`,
    up: porcentaje >= 0,
  };
}

const guaranies = (valor: number) => `₲ ${formatearMoneda(valor)}`;

/**
 * Sucursal en la que se está trabajando.
 *
 * Con una sola sucursal no es un selector sino un rótulo: no hay nada que
 * elegir, y un desplegable de una opción sugiere que sí. Con varias, cambiarla
 * afecta a toda la app (el valor vive en el provider), así que se muestra
 * siempre —no escondido en Configuración— para que quede claro sobre qué
 * sucursal se está operando.
 */
function SelectorSucursal() {
  const { sucursal, sucursales, cargando, setSucursal } = useSucursal();

  if (cargando) return <Skeleton className="h-9 w-40" />;

  // La empresa no tiene sucursales activas: se avisa en vez de no mostrar nada,
  // porque sin sucursal las pantallas que dependen de ella no van a funcionar.
  if (sucursales.length === 0) {
    return (
      <span className="rounded-lg border border-border bg-muted px-3 py-2 text-xs text-muted-foreground">
        Sin sucursales
      </span>
    );
  }

  if (sucursales.length === 1) {
    return (
      <span
        className="flex items-center gap-1.5 rounded-lg border border-border bg-muted px-3 py-2 text-sm text-muted-foreground"
        title="Única sucursal de la empresa"
      >
        <Building2 className="size-4 shrink-0" />
        <span className="max-w-40 truncate">{sucursal?.nombreSucursal}</span>
      </span>
    );
  }

  return (
    <Select
      // Spread condicional y no `value={... : undefined}`: con
      // exactOptionalPropertyTypes, pasar undefined explícito no compila.
      {...(sucursal ? { value: String(sucursal.id) } : {})}
      onValueChange={(valor) => {
        const elegida = sucursales.find((s) => s.id === Number(valor));
        if (elegida) {
          setSucursal({
            id: elegida.id,
            idEmpresa: elegida.idEmpresa,
            nombreSucursal: elegida.nombreSucursal,
          });
        }
      }}
    >
      <SelectTrigger className="w-44" aria-label="Sucursal activa">
        <Building2 className="size-4 shrink-0 text-muted-foreground" />
        <SelectValue placeholder="Sucursal" />
      </SelectTrigger>
      <SelectContent>
        {sucursales.map((s) => (
          <SelectItem key={s.id} value={String(s.id)}>
            {s.nombreSucursal}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

function HomePage() {
  const { data: usuario } = useUsuarioActual();
  const { empresa } = useEmpresa();
  const { sucursal } = useSucursal();
  const nombre = primerNombre(usuario?.nombreApellido);
  const esperandoNombre = !usuario;

  const resumen = useQuery({
    queryKey: ["dashboard", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => api.dashboard.resumen({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
    enabled: empresa !== null && sucursal !== null,
  });

  const datos = resumen.data;
  const kpis = [
    {
      label: "Ventas del mes",
      valor: datos ? guaranies(datos.ventasMes) : null,
      variacion: datos ? variacion(datos.ventasMes, datos.ventasMesAnterior) : null,
    },
    {
      label: "Compras del mes",
      valor: datos ? guaranies(datos.comprasMes) : null,
      variacion: datos ? variacion(datos.comprasMes, datos.comprasMesAnterior) : null,
    },
    {
      label: "Valor de stock",
      valor: datos ? guaranies(datos.valorStock) : null,
      // El stock no se compara contra el mes pasado: es una foto de HOY, no un
      // acumulado del período. Se muestra en cuántas unidades está repartido.
      pie: datos ? `${formatearMoneda(datos.unidadesStock)} unidades` : null,
    },
    {
      label: "Artículos bajo mínimo",
      valor: datos ? formatearMoneda(datos.articulosBajoMinimo) : null,
      pie: datos
        ? datos.articulosBajoMinimo === 0
          ? "Todo por encima del mínimo"
          : "Necesitan reposición"
        : null,
      alerta: (datos?.articulosBajoMinimo ?? 0) > 0,
    },
  ];

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
          <div className="flex items-center gap-2">
            <SelectorSucursal />
            <Button className="hidden sm:inline-flex">Nueva operación</Button>
          </div>
        </div>

        {/* Arriba de los KPIs y no al final: es lo que la gente viene a usar.
            Los indicadores se miran de paso, el menú es el punto de partida de
            cualquier tarea — tenerlo abajo obligaba a scrollear la home entera
            para llegar a lo único accionable de la pantalla. */}
        <section>
          <h2 className="mb-4 text-sm font-semibold uppercase tracking-wider text-muted-foreground">
            Acceso rápido
          </h2>
          <AccesosRapidos />
        </section>

        <section className="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-4">
          {kpis.map((kpi) => (
            <article key={kpi.label} className="surface-card p-4 sm:p-5">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">{kpi.label}</p>
              {kpi.valor === null ? (
                <Skeleton className="mt-2 h-7 w-32 sm:h-8" />
              ) : (
                <p
                  className={`mt-2 font-display text-lg font-bold sm:text-2xl ${
                    kpi.alerta ? "text-destructive" : "text-foreground"
                  }`}
                >
                  {kpi.valor}
                </p>
              )}
              {/* La variación sólo cuando existe: con el mes anterior en 0 no hay
                  con qué comparar, y ahí va el pie o nada antes que un número
                  inventado. */}
              {kpi.variacion ? (
                <p
                  className={`mt-2 flex items-center gap-1 text-xs font-semibold ${
                    kpi.variacion.up ? "text-success" : "text-destructive"
                  }`}
                >
                  {kpi.variacion.up ? (
                    <ArrowUpRight className="size-3.5" />
                  ) : (
                    <ArrowDownRight className="size-3.5" />
                  )}
                  {kpi.variacion.texto}
                </p>
              ) : (
                <p className="mt-2 text-xs text-muted-foreground">
                  {kpi.pie ?? (kpi.valor === null ? "" : "Sin mes anterior para comparar")}
                </p>
              )}
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
              {resumen.isPending &&
                [0, 1, 2, 3].map((i) => (
                  <li key={i} className="px-4 py-3.5 sm:px-5">
                    <Skeleton className="h-9 w-full" />
                  </li>
                ))}
              {datos?.movimientos.length === 0 && (
                <li className="px-4 py-10 text-center text-sm text-muted-foreground">
                  Todavía no hay movimientos
                </li>
              )}
              {(datos?.movimientos ?? []).map((mov) => (
                <li
                  key={`${mov.tipo}-${mov.documento}`}
                  className="flex items-center justify-between gap-3 px-4 py-3.5 sm:px-5"
                >
                  <div className="min-w-0">
                    <p className="truncate text-sm font-semibold text-foreground">{mov.parte}</p>
                    <p className="mt-0.5 truncate text-xs text-muted-foreground">
                      {mov.tipo} · {mov.documento} · {mov.fecha}
                    </p>
                  </div>
                  <div className="flex shrink-0 flex-col items-end gap-1">
                    {/* Los inventarios traen unidades, no plata: sin el signo
                        explícito un +3 y un −3 se leen igual de un vistazo. */}
                    <span className="text-sm font-semibold text-foreground">
                      {mov.enUnidades === "S"
                        ? `${mov.monto > 0 ? "+" : ""}${formatearMoneda(mov.monto)} un.`
                        : guaranies(mov.monto)}
                    </span>
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
              Artículos con menos de {datos?.umbralCritico ?? 5} unidades disponibles.
            </p>
            <ul className="mt-5 space-y-3">
              {resumen.isPending &&
                [0, 1, 2].map((i) => <Skeleton key={i} className="h-8 w-full" />)}
              {datos?.stockCritico.length === 0 && (
                <li className="py-6 text-center text-sm text-muted-foreground">
                  Ningún artículo por debajo de {datos.umbralCritico} unidades
                </li>
              )}
              {(datos?.stockCritico ?? []).map((row) => (
                <li key={row.idArticulo} className="flex items-center justify-between gap-3">
                  <div className="min-w-0">
                    <p className="truncate text-sm text-foreground">{row.articulo}</p>
                    {row.cantidadMinima !== null && row.cantidadMinima > 0 && (
                      <p className="text-xs text-muted-foreground">
                        Mínimo {formatearMoneda(row.cantidadMinima)}
                      </p>
                    )}
                  </div>
                  {/* Unidades y no un porcentaje: "quedan 2" dice qué hacer,
                      "18%" obliga a calcular sobre qué. */}
                  <span
                    className={`shrink-0 text-sm font-semibold ${
                      row.disponible <= 0 ? "text-destructive" : "text-foreground"
                    }`}
                  >
                    {formatearMoneda(row.disponible)} un.
                  </span>
                </li>
              ))}
            </ul>
            {(datos?.cuotasPorVencer ?? 0) > 0 && datos && (
              <div className="mt-6 flex items-center gap-3 rounded-xl bg-accent p-3">
                <Banknote className="size-5 shrink-0 text-accent-foreground" />
                <p className="text-xs text-accent-foreground">
                  {datos.cuotasPorVencer}{" "}
                  {datos.cuotasPorVencer === 1 ? "pago vence" : "pagos vencen"} en los próximos{" "}
                  {datos.diasPorVencer} días, por {guaranies(datos.montoPorVencer)}.
                </p>
              </div>
            )}
          </section>
        </div>
      </main>
    </AppLayout>
  );
}
