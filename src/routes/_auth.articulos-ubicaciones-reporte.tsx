import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { FileSpreadsheet, FileText, Loader2, Search } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHeader, TableRow } from "@/components/ui/table";
import {
  api,
  ApiError,
  esActivo,
  esGasto as esGastoArticulo,
  urlLogoEmpresa,
  type FilaReporteUbicaciones,
  type ReporteUbicaciones,
  type SituacionUbicacion,
} from "@/lib/api";
import { abrirPdf, descargarExcel, type ColumnaExport } from "@/lib/exportar";
import { tituloPagina } from "@/lib/marca";
import { formatearMoneda } from "@/lib/moneda";

export const Route = createFileRoute("/_auth/articulos-ubicaciones-reporte")({
  head: () => ({
    meta: [
      { title: tituloPagina("Reporte de ubicaciones") },
      {
        name: "description",
        content:
          "Los artículos de cada ubicación del depósito y los que no tienen ninguna, con exportación a Excel y PDF.",
      },
    ],
  }),
  component: ReporteUbicacionesPage,
});

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * De a 50, el techo del endpoint: el JSON vuelve por un bind de ORDS tipado
 * STRING, y una página más grande lo pasa y muere con un 500 mudo. Ver la nota
 * de `POR_PAGINA` en `/existencias`.
 */
const POR_PAGINA = 50;

/** Para que un `total` mal calculado no deje al navegador pidiendo páginas para siempre. */
const MAX_PAGINAS = 100;

const SIN_UBICACION = "Sin ubicación";

/**
 * La fila de la pantalla: la del backend más dos campos derivados.
 *
 * - `posicion` es el orden en que llegó, que es el **recorrido físico del
 *   depósito** (zona, estante, nivel; los sin ubicación al final). Ordenar la
 *   columna Ubicación por la etiqueta de texto pondría el estante 10 antes que
 *   el 2; por la posición, vuelve al orden en que se camina el depósito.
 * - `ubicacion` es la etiqueta, para buscar y mostrar.
 */
type Fila = FilaReporteUbicaciones & { posicion: number; ubicacion: string };

type Resumen = Omit<ReporteUbicaciones, "items" | "total" | "pagina" | "tamanio">;

/** "A1 · Estante 3 · Nivel 2", o "Sin ubicación". */
function etiquetaUbicacion(f: FilaReporteUbicaciones): string {
  if (f.idUbicacion === null) return SIN_UBICACION;
  return `${f.zona} · Estante ${f.estante} · Nivel ${f.nivel}`;
}

/**
 * El reporte entero de la sucursal, en memoria.
 *
 * Como en `/existencias`, **no hay "Mostrar más"**: es una consulta que se
 * exporta, y lo que sale en el archivo tiene que ser exactamente lo que se ve.
 *
 * La situación SÍ va al servidor —es el parámetro del reporte—, pero el resumen
 * vuelve igual con las dos mitades contadas, así que cambiarla no cambia los
 * números de arriba.
 */
async function traerReporte(
  idEmpresa: number,
  idSucursal: number,
  situacion: SituacionUbicacion | undefined,
): Promise<{ filas: Fila[]; resumen: Resumen }> {
  const filas: Fila[] = [];
  let resumen: Resumen | null = null;

  for (let pagina = 1; pagina <= MAX_PAGINAS; pagina++) {
    const r = await api.articulosUbicaciones.reporte({
      idEmpresa,
      idSucursal,
      situacion,
      pagina,
      tamanio: POR_PAGINA,
    });
    resumen ??= {
      asignaciones: r.asignaciones,
      ubicacionesOcupadas: r.ubicacionesOcupadas,
      articulosUbicados: r.articulosUbicados,
      sinUbicacion: r.sinUbicacion,
    };
    for (const item of r.items) {
      filas.push({ ...item, posicion: filas.length, ubicacion: etiquetaUbicacion(item) });
    }

    // Dos cortes: el total declarado y una página incompleta, por si el total
    // viniera mal.
    if (filas.length >= r.total || r.items.length < POR_PAGINA) break;
  }

  return {
    filas,
    resumen: resumen ?? {
      asignaciones: 0,
      ubicacionesOcupadas: 0,
      articulosUbicados: 0,
      sinUbicacion: 0,
    },
  };
}

/** El parámetro del reporte. "Todos" es una opción más, no la ausencia de filtro. */
const SITUACIONES: { valor: SituacionUbicacion | undefined; etiqueta: string }[] = [
  { valor: undefined, etiqueta: "Todos" },
  { valor: "CON", etiqueta: "Con ubicación" },
  { valor: "SIN", etiqueta: "Sin ubicación" },
];

/**
 * Las columnas del Excel y del PDF, declaradas una sola vez (ver
 * `lib/exportar.ts`).
 *
 * Zona, estante y nivel van separados y no como la etiqueta de la pantalla: en
 * la planilla se ordena y se filtra por estante, y un "Estante 10" de texto
 * ordena antes que el 2.
 */
const COLUMNAS: ColumnaExport<Fila>[] = [
  { titulo: "Zona", valor: (f) => f.zona ?? SIN_UBICACION, ancho: 16 },
  { titulo: "Estante", valor: (f) => f.estante, numerica: true, ancho: 9 },
  { titulo: "Nivel", valor: (f) => f.nivel, numerica: true, ancho: 8 },
  { titulo: "Código", valor: (f) => f.codigoArticulo, ancho: 16 },
  { titulo: "Artículo", valor: (f) => f.nombreArticulo, ancho: 42 },
  { titulo: "Categoría", valor: (f) => f.categoria, ancho: 22 },
  { titulo: "Marca", valor: (f) => f.marca, ancho: 20 },
  { titulo: "Existencia", valor: (f) => f.cantidadStock, numerica: true, ancho: 12 },
  { titulo: "Estado", valor: (f) => (esActivo(f.activo) ? "Activo" : "Inactivo"), ancho: 11 },
];

function ReporteUbicacionesPage() {
  const { empresa } = useEmpresa();
  // Las ubicaciones son de UNA sucursal, y "sin ubicación" también: el mismo
  // artículo puede estar ubicado en la casa central y sin ubicar en el local.
  const { sucursal } = useSucursal();
  const [situacion, setSituacion] = useState<SituacionUbicacion | undefined>(undefined);
  const [filtroZona, setFiltroZona] = useState<string>(SIN_FILTRO);
  const [filtroCategoria, setFiltroCategoria] = useState<string>(SIN_FILTRO);
  const [filtroMarca, setFiltroMarca] = useState<string>(SIN_FILTRO);
  const [exportando, setExportando] = useState<"excel" | "pdf" | null>(null);

  // Bajo el prefijo ["articulos-ubicaciones"] a propósito: es el que invalidan
  // el ABM del cruce y el diálogo de ubicaciones de un artículo al asignar o
  // quitar, así que el reporte se refresca solo sin que nadie se acuerde de él.
  const { data, isPending, isError, error } = useQuery({
    queryKey: [
      "articulos-ubicaciones",
      "reporte",
      empresa?.id ?? null,
      sucursal?.id ?? null,
      situacion ?? null,
    ],
    queryFn: () => traerReporte(empresa!.id, sucursal!.id, situacion),
    enabled: empresa !== null && sucursal !== null,
  });

  const todas = data?.filas ?? [];
  const resumen = data?.resumen;

  const { busqueda, setBusqueda, orden, alternarOrden, resultado } = useTablaListado<Fila>(
    todas,
    (f) => [f.codigoArticulo, f.nombreArticulo, f.categoria, f.marca, f.ubicacion],
  );

  // Los filtros de columna van en memoria y sobre el mismo array que se
  // exporta. La situación no: ésa ya vino filtrada del servidor.
  const filas = resultado.filter((f) => {
    if (filtroZona !== SIN_FILTRO && (f.zona ?? SIN_UBICACION) !== filtroZona) return false;
    if (filtroCategoria !== SIN_FILTRO && String(f.idCategoria) !== filtroCategoria) return false;
    if (filtroMarca !== SIN_FILTRO && String(f.idMarca) !== filtroMarca) return false;
    return true;
  });

  // Las opciones salen de las filas traídas y no del catálogo: ofrecer una zona
  // o una marca que no figura en el reporte es ofrecer un filtro que ya se sabe
  // que deja la tabla vacía.
  const zonasOpciones = opcionesUnicas(todas, (f) => {
    const zona = f.zona ?? SIN_UBICACION;
    return [zona, zona];
  });
  const categoriasOpciones = opcionesUnicas(todas, (f) =>
    f.idCategoria !== null && f.categoria ? [String(f.idCategoria), f.categoria] : null,
  );
  const marcasOpciones = opcionesUnicas(todas, (f) =>
    f.idMarca !== null && f.marca ? [String(f.idMarca), f.marca] : null,
  );

  const etiquetaSituacion = SITUACIONES.find((s) => s.valor === situacion)?.etiqueta ?? "Todos";

  /** Los filtros activos, en texto, para que el PDF diga qué se consultó. */
  function descripcionFiltros(): string[] {
    const partes: string[] = [`Situación: ${etiquetaSituacion}`];
    if (busqueda.trim()) partes.push(`Búsqueda: "${busqueda.trim()}"`);
    if (filtroZona !== SIN_FILTRO) partes.push(`Zona: ${filtroZona}`);
    if (filtroCategoria !== SIN_FILTRO) {
      const c = categoriasOpciones.find((o) => o.valor === filtroCategoria);
      partes.push(`Categoría: ${c?.etiqueta ?? filtroCategoria}`);
    }
    if (filtroMarca !== SIN_FILTRO) {
      const m = marcasOpciones.find((o) => o.valor === filtroMarca);
      partes.push(`Marca: ${m?.etiqueta ?? filtroMarca}`);
    }
    return partes;
  }

  async function exportarAExcel() {
    setExportando("excel");
    try {
      await descargarExcel({
        nombreArchivo: "articulos-por-ubicacion",
        hoja: "Ubicaciones",
        columnas: COLUMNAS,
        filas,
      });
    } catch (e) {
      toast.error(MENSAJE_ERROR(e, "No se pudo generar el Excel"));
    } finally {
      setExportando(null);
    }
  }

  /**
   * NO es `async`: `abrirPdf` abre la pestaña en su primera línea y tiene que
   * correr dentro del click, o el bloqueador de ventanas emergentes la frena.
   */
  function exportarAPdf() {
    setExportando("pdf");
    abrirPdf({
      nombreArchivo: "articulos-por-ubicacion",
      titulo: "Artículos por ubicación",
      subtitulos: [
        empresa?.nombreEmpresa ?? "",
        sucursal ? `Sucursal: ${sucursal.nombreSucursal}` : "",
        ...descripcionFiltros(),
        `${filas.length} fila${filas.length === 1 ? "" : "s"}`,
      ].filter(Boolean),
      columnas: COLUMNAS,
      filas,
      orientacion: "landscape",
      ...(empresa?.tieneLogo ? { urlLogo: urlLogoEmpresa(empresa.id) } : {}),
    })
      .catch((e: unknown) => toast.error(MENSAJE_ERROR(e, "No se pudo generar el PDF")))
      .finally(() => setExportando(null));
  }

  const sinDatos = filas.length === 0;

  return (
    <AppLayout active="/articulos-ubicaciones-reporte" title="Reporte de ubicaciones">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div className="min-w-0">
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">
              Artículos por ubicación
            </h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {sucursal
                ? `Los estantes de ${sucursal.nombreSucursal} y lo que todavía no tiene lugar.`
                : "Los estantes de la sucursal activa y lo que todavía no tiene lugar."}
            </p>
          </div>

          <div className="flex flex-wrap items-center gap-2">
            <Button
              variant="outline"
              onClick={exportarAExcel}
              disabled={sinDatos || exportando !== null}
            >
              {exportando === "excel" ? (
                <Loader2 className="size-4 animate-spin" />
              ) : (
                <FileSpreadsheet className="size-4" />
              )}
              Excel
            </Button>
            <Button onClick={exportarAPdf} disabled={sinDatos || exportando !== null}>
              {exportando === "pdf" ? (
                <Loader2 className="size-4 animate-spin" />
              ) : (
                <FileText className="size-4" />
              )}
              PDF
            </Button>
          </div>
        </div>

        {/* LA SITUACIÓN VA A LA VISTA, no en el embudo de una columna: es la
            pregunta del reporte —"¿qué falta ubicar?"— y un filtro que hay que
            descubrir es un filtro que no se usa. Mismo patrón de botones que
            /inventarios-reporte. */}
        <section className="surface-card flex flex-wrap items-center gap-2 p-4">
          <span className="text-xs font-medium text-muted-foreground">Mostrar</span>
          {SITUACIONES.map((s) => (
            <Button
              key={s.etiqueta}
              type="button"
              variant={situacion === s.valor ? "default" : "outline"}
              size="sm"
              onClick={() => setSituacion(s.valor)}
            >
              {s.etiqueta}
            </Button>
          ))}
        </section>

        {/* El resumen es de la sucursal entera, no de lo filtrado: con
            "Con ubicación" elegido, saber que faltan 37 por ubicar sigue
            siendo la respuesta que trae a alguien acá. */}
        {resumen && (
          <section className="grid grid-cols-3 gap-3 sm:gap-4">
            <article className="surface-card min-w-0 p-4">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">
                Ubicaciones ocupadas
              </p>
              <p className="mt-2 font-display text-lg font-bold text-foreground sm:text-2xl">
                {formatearMoneda(resumen.ubicacionesOcupadas)}
              </p>
            </article>
            <article className="surface-card min-w-0 p-4">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">
                Artículos ubicados
              </p>
              <p className="mt-2 font-display text-lg font-bold text-foreground sm:text-2xl">
                {formatearMoneda(resumen.articulosUbicados)}
              </p>
            </article>
            {/* Se puede tocar: informar cuántos faltan sin ofrecer verlos es
                media ayuda. */}
            <button
              type="button"
              onClick={() => setSituacion("SIN")}
              className="surface-card min-w-0 p-4 text-left transition-colors hover:bg-muted/50"
            >
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">Sin ubicación</p>
              <p
                className={`mt-2 font-display text-lg font-bold sm:text-2xl ${
                  resumen.sinUbicacion > 0 ? "text-destructive" : "text-foreground"
                }`}
              >
                {formatearMoneda(resumen.sinUbicacion)}
              </p>
            </button>
          </section>
        )}

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por artículo, código, categoría, marca o ubicación…"
            className="pl-9"
          />
        </div>

        {(empresa === null || sucursal === null) && (
          <p className="rounded-lg border border-border px-3 py-6 text-center text-sm text-muted-foreground">
            No hay una empresa o una sucursal activa. Elegila en la barra de arriba.
          </p>
        )}

        {isPending && empresa !== null && sucursal !== null && (
          <div className="space-y-2">
            {[0, 1, 2, 3, 4].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        )}

        {isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
            {MENSAJE_ERROR(error, "No se pudo cargar el reporte")}
          </p>
        )}

        {!isPending && !isError && sinDatos && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {todas.length > 0
                ? "Ninguna fila coincide con la búsqueda o los filtros."
                : situacion === "SIN"
                  ? "Todos los artículos activos tienen ubicación en esta sucursal."
                  : situacion === "CON"
                    ? "Ningún artículo tiene ubicación en esta sucursal todavía."
                    : "Esta empresa todavía no tiene artículos cargados."}
            </p>
          </div>
        )}

        {/* Móvil: tarjetas, con la ubicación arriba porque es por donde se
            recorre el reporte. */}
        {!sinDatos && (
          <ul className="space-y-3 sm:hidden">
            {filas.map((f) => (
              <li key={`${f.idArticulo}-${f.idUbicacion ?? "sin"}`} className="surface-card p-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0 flex-1">
                    <EtiquetaUbicacion fila={f} />
                    <p className="mt-1 truncate font-semibold text-foreground">
                      {f.nombreArticulo}
                    </p>
                    <p className="mt-0.5 truncate text-xs text-muted-foreground">
                      {f.codigoArticulo ? `${f.codigoArticulo} · ` : ""}
                      {f.categoria ?? "Sin categoría"}
                      {f.marca ? ` · ${f.marca}` : ""}
                    </p>
                  </div>
                  <div className="shrink-0 text-right">
                    <p className="text-xs text-muted-foreground">Existencia</p>
                    <p className="font-display text-lg font-bold tabular-nums text-foreground">
                      {formatearMoneda(f.cantidadStock)}
                    </p>
                  </div>
                </div>
                <Marcas fila={f} />
              </li>
            ))}
          </ul>
        )}

        {!sinDatos && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "posicion" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("posicion")}
                    opciones={zonasOpciones}
                    valor={filtroZona}
                    onFiltrar={setFiltroZona}
                    buscarPlaceholder="Buscar zona…"
                  >
                    Ubicación
                  </TableHeadFiltrable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "codigoArticulo" ? orden.direccion : null}
                    onClick={() => alternarOrden("codigoArticulo")}
                  >
                    Código
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "nombreArticulo" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreArticulo")}
                  >
                    Artículo
                  </TableHeadOrdenable>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "categoria" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("categoria")}
                    opciones={categoriasOpciones}
                    valor={filtroCategoria}
                    onFiltrar={setFiltroCategoria}
                    buscarPlaceholder="Buscar categoría…"
                  >
                    Categoría
                  </TableHeadFiltrable>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "marca" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("marca")}
                    opciones={marcasOpciones}
                    valor={filtroMarca}
                    onFiltrar={setFiltroMarca}
                    buscarPlaceholder="Buscar marca…"
                  >
                    Marca
                  </TableHeadFiltrable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "cantidadStock" ? orden.direccion : null}
                    onClick={() => alternarOrden("cantidadStock")}
                    className="text-right"
                  >
                    Existencia
                  </TableHeadOrdenable>
                </TableRow>
              </TableHeader>
              <TableBody>
                {filas.map((f) => (
                  <TableRow key={`${f.idArticulo}-${f.idUbicacion ?? "sin"}`}>
                    <TableCell>
                      <EtiquetaUbicacion fila={f} />
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {f.codigoArticulo ?? "—"}
                    </TableCell>
                    <TableCell className="font-medium text-foreground">
                      <span className="flex flex-wrap items-center gap-2">
                        {f.nombreArticulo}
                        <Marcas fila={f} />
                      </span>
                    </TableCell>
                    <TableCell className="text-muted-foreground">{f.categoria ?? "—"}</TableCell>
                    <TableCell className="text-muted-foreground">{f.marca ?? "—"}</TableCell>
                    <TableCell className="text-right tabular-nums text-foreground">
                      {formatearMoneda(f.cantidadStock)}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}

        {!sinDatos && (
          <p className="text-center text-xs text-muted-foreground">
            {filas.length === todas.length
              ? `${formatearMoneda(todas.length)} filas`
              : `${formatearMoneda(filas.length)} de ${formatearMoneda(todas.length)} filas`}
            {" · "}
            Un artículo en varios estantes sale una vez por cada uno. Excel y PDF salen con estas
            mismas filas.
          </p>
        )}
      </main>
    </AppLayout>
  );
}

/** La ubicación de la fila, o el aviso de que no tiene. */
function EtiquetaUbicacion({ fila }: { fila: Fila }) {
  if (fila.idUbicacion === null) {
    return (
      <Badge variant="outline" className="border-destructive/40 font-normal text-destructive">
        {SIN_UBICACION}
      </Badge>
    );
  }
  return (
    <span className="block min-w-0">
      <span className="font-medium text-foreground">{fila.ubicacion}</span>
      {fila.descripcionUbicacion && (
        <span className="block truncate text-xs text-muted-foreground">
          {fila.descripcionUbicacion}
        </span>
      )}
    </span>
  );
}

/**
 * Sólo las excepciones: inactivo y gasto. Pueden aparecer únicamente en las
 * filas CON ubicación —el backend no los cuenta como "sin ubicación"—, y ahí
 * son justo lo que hay que ver: algo dado de baja que sigue ocupando un estante.
 */
function Marcas({ fila }: { fila: Fila }) {
  const inactivo = !esActivo(fila.activo);
  const gasto = esGastoArticulo(fila.esGasto);
  if (!inactivo && !gasto) return null;
  return (
    <span className="mt-2 flex gap-1.5 sm:mt-0">
      {inactivo && (
        <Badge variant="outline" className="font-normal">
          Inactivo
        </Badge>
      )}
      {gasto && (
        <Badge variant="outline" className="font-normal">
          Gasto
        </Badge>
      )}
    </span>
  );
}

/** Opciones de filtro sin repetir, ordenadas por etiqueta. */
function opcionesUnicas(
  filas: Fila[],
  par: (f: Fila) => [string, string] | null,
): { valor: string; etiqueta: string }[] {
  const mapa = new Map<string, string>();
  for (const f of filas) {
    const p = par(f);
    if (p && !mapa.has(p[0])) mapa.set(p[0], p[1]);
  }
  return [...mapa]
    .map(([valor, etiqueta]) => ({ valor, etiqueta }))
    .sort((a, b) => a.etiqueta.localeCompare(b.etiqueta, "es"));
}
