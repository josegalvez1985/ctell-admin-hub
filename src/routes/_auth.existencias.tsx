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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { api, ApiError, esActivo, esGasto as esGastoArticulo, type Articulo } from "@/lib/api";
import { abrirPdf, descargarExcel, type ColumnaExport } from "@/lib/exportar";
import { tituloPagina } from "@/lib/marca";
import { formatearMoneda } from "@/lib/moneda";

export const Route = createFileRoute("/_auth/existencias")({
  head: () => ({
    meta: [
      { title: tituloPagina("Existencias") },
      {
        name: "description",
        content: "Consulta de existencia de artículos, con exportación a Excel y PDF.",
      },
    ],
  }),
  component: ExistenciasPage,
});

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Cuántos artículos se piden por vuelta.
 *
 * NO es el techo del endpoint (200), y bajarlo es deliberado: ORDS devuelve el
 * CLOB del listado por un parámetro tipado como STRING, que tope en 4000 BYTES.
 * Una página de 200 artículos —con DESCRIPCION de hasta 1000 caracteres cada
 * uno— pasa larguísimo ese límite y el bind falla DESPUÉS de que el PL/SQL
 * terminó bien: por eso el error llegaba como un 500 sin diagnóstico, que el
 * WHEN OTHERS del paquete ni siquiera alcanzaba a registrar.
 *
 * Con 50 la página entra holgada. El costo es una petición más cada 50
 * artículos, que en una pantalla que ya trae el catálogo completo no se nota.
 *
 * El arreglo de fondo es publicar el parámetro de salida como CLOB en vez de
 * STRING; hasta que eso se confirme contra esta instalación de ORDS, el tamaño
 * de página es lo que mantiene la respuesta por debajo del techo.
 */
const POR_PAGINA = 50;

/**
 * Tope de páginas a traer. 10.000 artículos es un catálogo enorme para este
 * sistema; el límite existe para que un `total` mal calculado en el backend no
 * deje al navegador pidiendo páginas para siempre.
 */
const MAX_PAGINAS = 50;

/**
 * Todo el catálogo de la empresa, en memoria.
 *
 * **A diferencia de la pantalla de Artículos, acá no hay "Mostrar más".** Es una
 * consulta que se exporta: si la tabla mostrara 20 filas y el Excel saliera con
 * 600, o al revés, nadie sabría cuál de los dos números creer. Trayendo todo,
 * **lo que se exporta es exactamente lo que se ve**, con los mismos filtros
 * aplicados.
 *
 * Se pagina de a `POR_PAGINA` y no de una sola vez: una respuesta grande hace
 * fallar a `/articulos/listar` con 500 por el techo de 4000 bytes del bind de
 * ORDS. Ver la nota de `POR_PAGINA`.
 */
async function traerCatalogo(idEmpresa: number, idSucursal: number): Promise<Articulo[]> {
  const todos: Articulo[] = [];

  for (let pagina = 1; pagina <= MAX_PAGINAS; pagina++) {
    // idSucursal ACOTA EL STOCK, no el catálogo: la lista de artículos es de la
    // empresa y no cambia según el depósito. Lo que cambia es `cantidadStock`,
    // que sin este parámetro suma TODAS las sucursales — y esta pantalla es
    // justamente la que se mira para saber si hay algo **acá**. Un total de 12
    // que en realidad son 8 en el otro local es peor que no mostrar nada.
    const respuesta = await api.articulos.listar({
      idEmpresa,
      idSucursal,
      pagina,
      tamanio: POR_PAGINA,
    });
    todos.push(...respuesta.items);

    // Dos cortes: el total declarado por el backend y una página incompleta.
    // El segundo cubre el caso de que `total` venga mal — sin él, una página
    // vacía repetida daría vueltas hasta MAX_PAGINAS.
    if (todos.length >= respuesta.total || respuesta.items.length < POR_PAGINA) break;
  }

  return todos;
}

/** Situaciones por las que se puede filtrar la columna Existencia. */
const SITUACIONES = [
  { valor: "bajo-minimo", etiqueta: "Bajo el mínimo" },
  { valor: "sin-existencia", etiqueta: "Sin existencia" },
  { valor: "con-existencia", etiqueta: "Con existencia" },
];

const ESTADOS = [
  { valor: "A", etiqueta: "Activo" },
  { valor: "I", etiqueta: "Inactivo" },
];

/**
 * Un artículo está bajo el mínimo cuando tiene menos de lo que la política del
 * negocio pide tener.
 *
 * El mínimo en 0 no cuenta: significa "no se definió", y sin esta guarda todo
 * artículo sin mínimo cargado y sin stock aparecería como faltante.
 */
function bajoMinimo(articulo: Articulo): boolean {
  return articulo.cantidadMinima > 0 && articulo.cantidadStock < articulo.cantidadMinima;
}

/** La unidad para mostrar al lado de la cantidad: "un.", "kg", "m". */
function unidad(articulo: Articulo): string {
  return articulo.abreviaturaUnidad ?? articulo.unidadMedida ?? "";
}

/**
 * Las columnas del reporte: valen para el Excel y para el PDF.
 *
 * Se declaran una sola vez a propósito — ver el encabezado de `lib/exportar.ts`.
 * Las cantidades van como número pelado (sin separador de miles) para que en
 * Excel entren como número y se puedan sumar; el formato bonito es cosa de la
 * pantalla, no del archivo.
 */
const COLUMNAS: ColumnaExport<Articulo>[] = [
  { titulo: "Código", valor: (a) => a.codigoArticulo, ancho: 16 },
  { titulo: "Artículo", valor: (a) => a.nombreArticulo, ancho: 42 },
  { titulo: "Categoría", valor: (a) => a.categoria, ancho: 22 },
  { titulo: "Marca", valor: (a) => a.marca, ancho: 20 },
  { titulo: "Unidad", valor: (a) => unidad(a) || null, ancho: 12 },
  { titulo: "Existencia", valor: (a) => a.cantidadStock, numerica: true, ancho: 13 },
  { titulo: "Mínimo", valor: (a) => a.cantidadMinima, numerica: true, ancho: 11 },
  {
    titulo: "Diferencia",
    // Negativa es lo que falta para llegar al mínimo. Se calcula acá y no en la
    // planilla para que el PDF —donde no hay fórmulas— diga lo mismo.
    valor: (a) => a.cantidadStock - a.cantidadMinima,
    numerica: true,
    ancho: 12,
  },
  { titulo: "Tipo", valor: (a) => (esGastoArticulo(a.esGasto) ? "Gasto" : "Stock"), ancho: 10 },
  { titulo: "Estado", valor: (a) => (esActivo(a.activo) ? "Activo" : "Inactivo"), ancho: 11 },
];

function ExistenciasPage() {
  const { empresa } = useEmpresa();
  // La existencia es de UN depósito: la sucursal activa es parte de la pregunta
  // que responde esta pantalla, igual que en el resto del sistema.
  const { sucursal } = useSucursal();
  const [filtroCategoria, setFiltroCategoria] = useState<string>(SIN_FILTRO);
  const [filtroMarca, setFiltroMarca] = useState<string>(SIN_FILTRO);
  const [filtroSituacion, setFiltroSituacion] = useState<string>(SIN_FILTRO);
  const [filtroEstado, setFiltroEstado] = useState<string>(SIN_FILTRO);
  const [exportando, setExportando] = useState<"excel" | "pdf" | null>(null);

  // queryKey propia y no la de ["articulos"]: aquélla guarda páginas sueltas de
  // 20 filas con búsqueda del servidor, y ésta el catálogo entero. Compartirla
  // haría que una pantalla sirviera la caché de la otra.
  // LA SUCURSAL VA EN LA queryKey. Sin ella, cambiar de depósito serviría el
  // catálogo cacheado del anterior —con sus cantidades— y nada avisaría de que
  // los números son de otro lado.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["existencias", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => traerCatalogo(empresa!.id, sucursal!.id),
    enabled: empresa !== null && sucursal !== null,
  });

  const { data: categorias } = useQuery({
    queryKey: ["categorias", empresa?.id ?? null],
    queryFn: () => api.categorias.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  // Con la empresa en la clave: MARCAS cuelga de EMPRESAS. Comparte caché con
  // /marcas y con la pantalla de Artículos.
  const { data: marcas } = useQuery({
    queryKey: ["marcas", empresa?.id ?? null],
    queryFn: () => api.marcas.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  const catalogo = data ?? [];

  // Búsqueda y orden en memoria: acá el catálogo está entero en el cliente, así
  // que ordenar por existencia ordena TODO y no sólo lo que se alcanzó a traer
  // —que es la diferencia con la pantalla de Artículos, donde el listado viene
  // paginado del servidor.
  const { busqueda, setBusqueda, orden, alternarOrden, resultado } = useTablaListado<Articulo>(
    catalogo,
    (a) => [a.codigoArticulo, a.nombreArticulo, a.categoria, a.marca, a.unidadMedida],
  );

  // Los tres filtros de columna se aplican DESPUÉS de la búsqueda y el orden,
  // sobre el mismo array que después se exporta.
  const filas = resultado.filter((a) => {
    if (filtroCategoria !== SIN_FILTRO && String(a.idCategoria) !== filtroCategoria) return false;
    if (filtroMarca !== SIN_FILTRO && String(a.idMarca) !== filtroMarca) return false;
    if (filtroEstado !== SIN_FILTRO && a.activo !== filtroEstado) return false;
    if (filtroSituacion === "bajo-minimo" && !bajoMinimo(a)) return false;
    if (filtroSituacion === "sin-existencia" && a.cantidadStock > 0) return false;
    if (filtroSituacion === "con-existencia" && a.cantidadStock <= 0) return false;
    return true;
  });

  const categoriasOpciones = (categorias?.items ?? []).map((c) => ({
    valor: String(c.id),
    etiqueta: c.nombreCategoria,
  }));

  const marcasOpciones = (marcas?.items ?? []).map((m) => ({
    valor: String(m.id),
    etiqueta: m.descripcion,
  }));

  // Los totales se cuentan sobre lo filtrado, no sobre el catálogo: son el
  // resumen de lo que se está mirando y de lo que va a salir en el archivo.
  const totalFaltantes = filas.filter(bajoMinimo).length;
  const totalSinExistencia = filas.filter((a) => a.cantidadStock <= 0).length;

  /** Los filtros activos, en texto, para que el reporte diga qué se consultó. */
  function descripcionFiltros(): string[] {
    const partes: string[] = [];
    if (busqueda.trim()) partes.push(`Búsqueda: "${busqueda.trim()}"`);
    if (filtroCategoria !== SIN_FILTRO) {
      const categoria = categoriasOpciones.find((c) => c.valor === filtroCategoria);
      partes.push(`Categoría: ${categoria?.etiqueta ?? filtroCategoria}`);
    }
    if (filtroMarca !== SIN_FILTRO) {
      const marca = marcasOpciones.find((m) => m.valor === filtroMarca);
      partes.push(`Marca: ${marca?.etiqueta ?? filtroMarca}`);
    }
    if (filtroSituacion !== SIN_FILTRO) {
      partes.push(
        `Situación: ${SITUACIONES.find((s) => s.valor === filtroSituacion)?.etiqueta ?? ""}`,
      );
    }
    if (filtroEstado !== SIN_FILTRO) {
      partes.push(`Estado: ${filtroEstado === "A" ? "Activos" : "Inactivos"}`);
    }
    return partes;
  }

  async function exportarAExcel() {
    setExportando("excel");
    try {
      await descargarExcel({
        nombreArchivo: "existencias",
        hoja: "Existencias",
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
   * NO es `async`, y no se hace ningún `await` antes de llamar a `abrirPdf`.
   *
   * `abrirPdf` abre la pestaña en su primera línea, que tiene que correr dentro
   * del click para que el bloqueador de ventanas emergentes la deje pasar. Con
   * un `await` en el medio —cargar la librería, por ejemplo— el navegador ya no
   * lo asocia al gesto del usuario y la bloquea sin decir nada.
   */
  function exportarAPdf() {
    setExportando("pdf");
    abrirPdf({
      nombreArchivo: "existencias",
      titulo: "Existencia de artículos",
      subtitulos: [
        empresa?.nombreEmpresa ?? "",
        ...descripcionFiltros(),
        `${filas.length} artículo${filas.length === 1 ? "" : "s"}` +
          (totalFaltantes > 0 ? ` · ${totalFaltantes} bajo el mínimo` : ""),
      ].filter(Boolean),
      columnas: COLUMNAS,
      filas,
      // Apaisado: son nueve columnas y en vertical el nombre del artículo queda
      // partido en tres renglones.
      orientacion: "landscape",
    })
      .catch((e: unknown) => toast.error(MENSAJE_ERROR(e, "No se pudo generar el PDF")))
      .finally(() => setExportando(null));
  }

  const sinDatos = filas.length === 0;

  return (
    // La RUTA y no el nombre: `MenuDinamico` acepta cualquiera de los dos, pero
    // el nombre lo escribe una persona en el ABM de páginas y si lo carga como
    // "Consulta de existencias" el ítem no se marcaría como activo.
    <AppLayout active="/existencias" title="Existencias">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div className="min-w-0">
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">
              Existencia de artículos
            </h1>
            {/* DICE DE QUÉ SUCURSAL SON LOS NÚMEROS. Sin eso, la misma tabla
                con las mismas columnas muestra cantidades distintas según el
                depósito activo y no hay nada en pantalla que lo explique. */}
            <p className="mt-1 text-sm text-muted-foreground">
              {sucursal
                ? `Stock disponible en ${sucursal.nombreSucursal}.`
                : "Stock disponible de la sucursal activa."}
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

        {/* El resumen va arriba porque es la respuesta a la pregunta que trae a
            alguien a esta pantalla: cuánto falta reponer. La tabla es el
            detalle de eso. */}
        {!isPending && !isError && empresa !== null && (
          <section className="grid grid-cols-3 gap-3 sm:gap-4">
            <article className="surface-card min-w-0 p-4">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">Artículos</p>
              <p className="mt-2 font-display text-lg font-bold text-foreground sm:text-2xl">
                {formatearMoneda(filas.length)}
              </p>
            </article>
            <article className="surface-card min-w-0 p-4">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">Bajo el mínimo</p>
              <p
                className={`mt-2 font-display text-lg font-bold sm:text-2xl ${
                  totalFaltantes > 0 ? "text-destructive" : "text-foreground"
                }`}
              >
                {formatearMoneda(totalFaltantes)}
              </p>
            </article>
            <article className="surface-card min-w-0 p-4">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">Sin existencia</p>
              <p
                className={`mt-2 font-display text-lg font-bold sm:text-2xl ${
                  totalSinExistencia > 0 ? "text-destructive" : "text-foreground"
                }`}
              >
                {formatearMoneda(totalSinExistencia)}
              </p>
            </article>
          </section>
        )}

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre, código, categoría o marca…"
            className="pl-9"
          />
        </div>

        {empresa === null && !isPending && (
          <p className="rounded-lg border border-border px-3 py-6 text-center text-sm text-muted-foreground">
            No hay una empresa activa. Cerrá sesión y volvé a entrar eligiendo una.
          </p>
        )}

        {isPending && empresa !== null && (
          <div className="space-y-2">
            {[0, 1, 2, 3, 4].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        )}

        {isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
            {MENSAJE_ERROR(error, "No se pudo cargar la existencia")}
          </p>
        )}

        {!isPending && !isError && empresa !== null && sinDatos && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {catalogo.length === 0
                ? "Esta empresa todavía no tiene artículos cargados."
                : "Ningún artículo coincide con la búsqueda o los filtros."}
            </p>
          </div>
        )}

        {/* Móvil: tarjetas. Nueve columnas en 360px obligan a scrollear de
            costado para leer una fila entera. */}
        {!sinDatos && (
          <ul className="space-y-3 sm:hidden">
            {filas.map((articulo) => {
              const falta = bajoMinimo(articulo);
              const activo = esActivo(articulo.activo);

              return (
                <li key={articulo.id} className="surface-card min-w-0 p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">
                        {articulo.nombreArticulo}
                      </p>
                      <p className="mt-0.5 truncate text-xs text-muted-foreground">
                        {articulo.codigoArticulo ? `${articulo.codigoArticulo} · ` : ""}
                        {articulo.categoria ?? "Sin categoría"}
                        {articulo.marca ? ` · ${articulo.marca}` : ""}
                        {esGastoArticulo(articulo.esGasto) ? " · Gasto" : ""}
                      </p>
                    </div>
                    {!activo && (
                      <Badge variant="outline" className="shrink-0">
                        Inactivo
                      </Badge>
                    )}
                  </div>

                  <div className="mt-3 flex items-end justify-between gap-3 border-t border-border pt-3">
                    <div className="min-w-0">
                      <p className="text-xs text-muted-foreground">Existencia</p>
                      <p
                        className={`font-display text-xl font-bold tabular-nums ${
                          falta ? "text-destructive" : "text-foreground"
                        }`}
                      >
                        {formatearMoneda(articulo.cantidadStock)}
                        {unidad(articulo) ? (
                          <span className="ml-1 text-sm font-normal text-muted-foreground">
                            {unidad(articulo)}
                          </span>
                        ) : null}
                      </p>
                    </div>
                    <p className="shrink-0 text-right text-xs text-muted-foreground">
                      {articulo.cantidadMinima > 0
                        ? `Mínimo ${formatearMoneda(articulo.cantidadMinima)}`
                        : "Sin mínimo"}
                      {falta && (
                        <span className="block font-semibold text-destructive">
                          Faltan {formatearMoneda(articulo.cantidadMinima - articulo.cantidadStock)}
                        </span>
                      )}
                    </p>
                  </div>
                </li>
              );
            })}
          </ul>
        )}

        {!sinDatos && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
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
                  {/* El filtro de situación vive en la columna Existencia
                      porque es sobre ese número que se pregunta "mostrame sólo
                      los que faltan". */}
                  <TableHeadFiltrable
                    direccion={orden?.campo === "cantidadStock" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("cantidadStock")}
                    opciones={SITUACIONES}
                    valor={filtroSituacion}
                    onFiltrar={setFiltroSituacion}
                    buscarPlaceholder="Buscar situación…"
                    className="text-right"
                  >
                    Existencia
                  </TableHeadFiltrable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "cantidadMinima" ? orden.direccion : null}
                    onClick={() => alternarOrden("cantidadMinima")}
                    className="text-right"
                  >
                    Mínimo
                  </TableHeadOrdenable>
                  <TableHead className="text-right">Diferencia</TableHead>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "activo" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("activo")}
                    opciones={ESTADOS}
                    valor={filtroEstado}
                    onFiltrar={setFiltroEstado}
                    buscarPlaceholder="Buscar estado…"
                  >
                    Estado
                  </TableHeadFiltrable>
                </TableRow>
              </TableHeader>
              <TableBody>
                {filas.map((articulo) => {
                  const falta = bajoMinimo(articulo);
                  const activo = esActivo(articulo.activo);
                  const diferencia = articulo.cantidadStock - articulo.cantidadMinima;

                  return (
                    <TableRow key={articulo.id}>
                      <TableCell className="text-muted-foreground">
                        {articulo.codigoArticulo ?? "—"}
                      </TableCell>
                      <TableCell className="font-medium text-foreground">
                        <span className="flex items-center gap-2">
                          {articulo.nombreArticulo}
                          {/* Sólo se marca el gasto, que es la excepción: un
                              gasto no lleva depósito y su existencia no dice
                              nada. Igual se lista, para que nadie crea que
                              falta un artículo del catálogo. */}
                          {esGastoArticulo(articulo.esGasto) && (
                            <Badge variant="outline" className="shrink-0 font-normal">
                              Gasto
                            </Badge>
                          )}
                        </span>
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {articulo.categoria ?? "—"}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {articulo.marca ?? "—"}
                      </TableCell>
                      <TableCell className="text-right">
                        <span
                          className={`tabular-nums ${falta ? "font-semibold text-destructive" : "text-foreground"}`}
                        >
                          {formatearMoneda(articulo.cantidadStock)}
                        </span>
                        {unidad(articulo) && (
                          <span className="ml-1 text-xs text-muted-foreground">
                            {unidad(articulo)}
                          </span>
                        )}
                      </TableCell>
                      <TableCell className="text-right tabular-nums text-muted-foreground">
                        {articulo.cantidadMinima > 0
                          ? formatearMoneda(articulo.cantidadMinima)
                          : "—"}
                      </TableCell>
                      <TableCell className="text-right">
                        {/* La diferencia sólo se muestra cuando hay un mínimo
                            contra el cual medirla: sin mínimo, "restar" da el
                            stock otra vez y parece otro dato. */}
                        {articulo.cantidadMinima > 0 ? (
                          <span
                            className={`tabular-nums ${diferencia < 0 ? "font-semibold text-destructive" : "text-muted-foreground"}`}
                          >
                            {diferencia > 0 ? "+" : ""}
                            {formatearMoneda(diferencia)}
                          </span>
                        ) : (
                          <span className="text-muted-foreground">—</span>
                        )}
                      </TableCell>
                      <TableCell>
                        <Badge variant={activo ? "secondary" : "outline"}>
                          {activo ? "Activo" : "Inactivo"}
                        </Badge>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>
        )}

        {!sinDatos && (
          <p className="text-center text-xs text-muted-foreground">
            {filas.length === catalogo.length
              ? `${formatearMoneda(catalogo.length)} artículos`
              : `${formatearMoneda(filas.length)} de ${formatearMoneda(catalogo.length)} artículos`}
            {" · "}
            Excel y PDF salen con estas mismas filas.
          </p>
        )}
      </main>
    </AppLayout>
  );
}
