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
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { api, ApiError, urlLogoEmpresa, type EstadoInventario, type Inventario } from "@/lib/api";
import { abrirPdf, descargarExcel, type ColumnaExport } from "@/lib/exportar";
import { tituloPagina } from "@/lib/marca";
import { formatearMoneda } from "@/lib/moneda";

export const Route = createFileRoute("/_auth/inventarios-reporte")({
  head: () => ({
    meta: [
      { title: tituloPagina("Reporte de inventarios") },
      {
        name: "description",
        content: "Conteos físicos por período, estado y diferencia, con exportación a Excel y PDF.",
      },
    ],
  }),
  component: InventariosReportePage,
});

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Cuántos conteos se piden por vuelta.
 *
 * NO es un número elegido al azar: `/inventarios/listar` tiene su
 * `C_TAMANIO_MAXIMO` en 50 y devuelve el JSON por un bind de ORDS tipado como
 * STRING, con techo de 4000 BYTES. Pedir más no trae más —el backend lo
 * recorta— y acercarse al techo hace fallar el bind DESPUÉS de que el PL/SQL
 * terminó bien, que es como el error llega al navegador como un 500 sin
 * diagnóstico que el `WHEN OTHERS` ni alcanza a registrar.
 *
 * Mismo criterio que `POR_PAGINA` en /existencias.
 */
const POR_PAGINA = 50;

/**
 * Tope de páginas a traer: 5.000 conteos.
 *
 * Existe para que un `total` mal calculado en el backend no deje al navegador
 * pidiendo páginas para siempre. Si un período real lo alcanza, la respuesta no
 * es subir el número: es acotar el rango de fechas, que para eso está el filtro.
 */
const MAX_PAGINAS = 100;

/**
 * Todos los conteos de la sucursal activa, en memoria.
 *
 * **Como en /existencias, acá no hay "Mostrar más".** Es un reporte que se
 * exporta: si la tabla mostrara 20 filas y el Excel saliera con 600, nadie
 * sabría cuál de los dos números creer. Trayendo todo, lo que se exporta es
 * exactamente lo que se ve.
 *
 * Las fechas y las diferencias se filtran en memoria sobre esto, no en el SQL:
 * la diferencia no es una columna sino una resta que cambia según el estado (ver
 * `sistemaDe`), y filtrarla en el backend obligaría a duplicar ese `CASE` en el
 * `COUNT` y en el `SELECT` del paquete — desincronizados, el total dice una cosa
 * y las filas otra.
 */
async function traerConteos(idEmpresa: number, idSucursal: number): Promise<Inventario[]> {
  const todos: Inventario[] = [];

  for (let pagina = 1; pagina <= MAX_PAGINAS; pagina++) {
    const respuesta = await api.inventarios.listar({
      idEmpresa,
      idSucursal,
      pagina,
      tamanio: POR_PAGINA,
    });
    todos.push(...respuesta.items);

    // Dos cortes: el total declarado por el backend y una página incompleta. El
    // segundo cubre el caso de que `total` venga mal — sin él, una página vacía
    // repetida daría vueltas hasta MAX_PAGINAS.
    if (todos.length >= respuesta.total || respuesta.items.length < POR_PAGINA) break;
  }

  return todos;
}

/**
 * Los tres estados que un conteo puede tener hoy.
 *
 * **`PROCESADO` no está**: ninguna transición lo produce y el backend no lo
 * acepta — es un valor legado de cuando el stock se manejaba por lotes.
 * Ofrecerlo como filtro sería ofrecer una búsqueda que se sabe vacía.
 *
 * Sigue existiendo en `EstadoInventario` y en `ETIQUETA_ESTADO` a propósito: si
 * quedó alguna fila vieja con ese valor, el reporte tiene que poder pintarla.
 * Se ve, no se filtra.
 */
const ESTADOS: { valor: EstadoInventario; etiqueta: string }[] = [
  { valor: "ABIERTO", etiqueta: "Abiertos" },
  { valor: "CERRADO", etiqueta: "Cerrados" },
  { valor: "ANULADO", etiqueta: "Anulados" },
];

/**
 * Cómo salió el conteo frente al sistema. "Todos" no está acá: lo pone el panel
 * de filtros, y `TableHeadFiltrable` lo agrega solo arriba de la lista del
 * embudo como `SIN_FILTRO`.
 *
 * **Un conteo sin cantidad cargada no entra en ninguna de las dos**: no
 * coincidió ni dejó de coincidir, sólo está esperando que alguien vaya al
 * depósito. Contarlo como "sin diferencia" haría que esa opción —la pregunta
 * "¿qué salió redondo?"— devolviera planillas vacías junto con los conteos que
 * de verdad dieron bien. Se lo sigue viendo con "Todos", donde su columna
 * Diferencia dice "Sin contar".
 */
const DIFERENCIAS = [
  { valor: "con", etiqueta: "Con diferencia" },
  { valor: "sin", etiqueta: "Sin diferencia" },
];

/**
 * Contra qué número se compara lo contado.
 *
 * **ESTA FUNCIÓN ESTÁ DUPLICADA a propósito** en `_auth.inventarios.tsx`, y su
 * criterio vive también en el `UNION ALL` de `PKG_DASHBOARD`. Son dos números
 * distintos según el estado, y confundirlos hace que la columna Diferencia
 * mienta:
 *
 * - Mientras está `ABIERTO`, contra `existenciaActual` — lo que el sistema dice
 *   ahora, que es lo que se está por corregir. `cantidadSistema` es `NULL` hasta
 *   el cierre, y restar 0 mostraría lo contado como si fuera todo diferencia.
 * - Ya `CERRADO`, contra `cantidadSistema` — lo que el sistema decía cuando se
 *   aplicó el ajuste, sellado por el trigger. Usar la existencia actual daría
 *   cero siempre, porque el propio cierre las igualó.
 *
 * **Si cambia acá, cambia en los otros dos lugares.**
 */
function sistemaDe(inventario: Inventario): number {
  return inventario.estado === "ABIERTO"
    ? inventario.existenciaActual
    : (inventario.cantidadSistema ?? 0);
}

/** `null` cuando todavía no se contó: no es cero, es que no hay dato. */
function diferenciaDe(inventario: Inventario): number | null {
  if (inventario.cantidadFisica === null) return null;
  return inventario.cantidadFisica - sistemaDe(inventario);
}

/**
 * El día del conteo en `YYYY-MM-DD`, para compararlo contra los
 * `<input type="date">` del filtro.
 *
 * Se recortan los 10 primeros caracteres del ISO y no se pasa por `Date`: el
 * backend manda la fecha sin zona y en hora local, así que convertirla de ida y
 * vuelta sólo agregaría una oportunidad de correrla de huso — y un conteo de las
 * 21:00 aparecería como del día siguiente, fuera del rango que sí lo incluye.
 */
function diaDe(inventario: Inventario): string {
  return inventario.fechaInventario ? inventario.fechaInventario.slice(0, 10) : "";
}

/**
 * Fecha y hora del conteo. **Va con hora, no sólo el día**: dos conteos del
 * mismo artículo el mismo día se ordenan entre sí por ella.
 *
 * Mismo formato que `/inventarios` — dos formatos distintos para el mismo dato
 * harían dudar de si son la misma fila.
 */
function formatearFecha(valor: string | null): string {
  if (!valor) return "—";
  const fecha = new Date(valor);
  if (Number.isNaN(fecha.getTime())) return valor;
  return new Intl.DateTimeFormat("es-PY", { dateStyle: "medium", timeStyle: "short" }).format(
    fecha,
  );
}

/** `YYYY-MM-DD` local. A mano y no con `toISOString()`, que devuelve UTC. */
function comoDia(fecha: Date): string {
  const dosDigitos = (n: number) => String(n).padStart(2, "0");
  return `${fecha.getFullYear()}-${dosDigitos(fecha.getMonth() + 1)}-${dosDigitos(fecha.getDate())}`;
}

/**
 * Los atajos de período.
 *
 * Existen porque escribir dos fechas a mano para la consulta que se hace todos
 * los meses es fricción pura, y porque el rango tecleado se equivoca fácil: un
 * "31" en un mes de 30 días devuelve vacío sin explicar por qué.
 */
const ATAJOS: { etiqueta: string; rango: () => { desde: string; hasta: string } }[] = [
  {
    etiqueta: "Este mes",
    rango: () => {
      const hoy = new Date();
      return {
        desde: comoDia(new Date(hoy.getFullYear(), hoy.getMonth(), 1)),
        hasta: comoDia(hoy),
      };
    },
  },
  {
    etiqueta: "Mes anterior",
    rango: () => {
      const hoy = new Date();
      return {
        desde: comoDia(new Date(hoy.getFullYear(), hoy.getMonth() - 1, 1)),
        // Día 0 del mes actual = último día del anterior. Así no hay que saber
        // si el mes tenía 28, 30 o 31.
        hasta: comoDia(new Date(hoy.getFullYear(), hoy.getMonth(), 0)),
      };
    },
  },
  {
    etiqueta: "Últimos 30 días",
    rango: () => {
      const hoy = new Date();
      const desde = new Date(hoy);
      desde.setDate(desde.getDate() - 29);
      return { desde: comoDia(desde), hasta: comoDia(hoy) };
    },
  },
  {
    etiqueta: "Este año",
    rango: () => {
      const hoy = new Date();
      return { desde: comoDia(new Date(hoy.getFullYear(), 0, 1)), hasta: comoDia(hoy) };
    },
  },
];

function EstadoBadge({ estado }: { estado: EstadoInventario }) {
  if (estado === "CERRADO") return <Badge>Cerrado</Badge>;
  if (estado === "ABIERTO") return <Badge variant="secondary">Abierto</Badge>;
  return (
    <Badge variant="outline" className="text-muted-foreground">
      {estado === "ANULADO" ? "Anulado" : "Procesado"}
    </Badge>
  );
}

/**
 * Un número de cantidad, con el signo cuando es una diferencia.
 *
 * El faltante va en `destructive` y el sobrante no: un sobrante también es un
 * error de registro, pero no es plata que se perdió.
 */
function Cantidad({ valor, conSigno = false }: { valor: number | null; conSigno?: boolean }) {
  if (valor === null) return <span className="text-muted-foreground">Sin contar</span>;
  const clase = conSigno && valor < 0 ? "text-destructive font-semibold" : "";
  const signo = conSigno && valor > 0 ? "+" : "";
  return (
    <span className={`tabular-nums ${clase}`}>
      {signo}
      {formatearMoneda(valor)}
    </span>
  );
}

const ETIQUETA_ESTADO: Record<EstadoInventario, string> = {
  ABIERTO: "Abierto",
  CERRADO: "Cerrado",
  ANULADO: "Anulado",
  PROCESADO: "Procesado",
};

/**
 * Las columnas del reporte: valen para el Excel y para el PDF.
 *
 * Se declaran una sola vez a propósito — ver el encabezado de `lib/exportar.ts`.
 * Las cantidades van como número pelado para que en Excel entren como número y
 * se puedan sumar; el formato bonito es cosa de la pantalla, no del archivo.
 *
 * `Sistema` y `Diferencia` salen de `sistemaDe`/`diferenciaDe`, las mismas que
 * pinta la tabla: si el archivo calculara la resta por su cuenta, tarde o
 * temprano diría algo distinto de lo que se vio en pantalla.
 */
const COLUMNAS: ColumnaExport<Inventario>[] = [
  { titulo: "Fecha", valor: (i) => formatearFecha(i.fechaInventario), ancho: 20 },
  { titulo: "Código", valor: (i) => i.codigoArticulo, ancho: 16 },
  { titulo: "Artículo", valor: (i) => i.nombreArticulo, ancho: 40 },
  { titulo: "Contado", valor: (i) => i.cantidadFisica, numerica: true, ancho: 12 },
  { titulo: "Sistema", valor: (i) => sistemaDe(i), numerica: true, ancho: 12 },
  { titulo: "Diferencia", valor: (i) => diferenciaDe(i), numerica: true, ancho: 12 },
  { titulo: "Estado", valor: (i) => ETIQUETA_ESTADO[i.estado], ancho: 12 },
  { titulo: "Contó", valor: (i) => i.usuario, ancho: 24 },
];

function InventariosReportePage() {
  const { empresa } = useEmpresa();
  // EL CONTEO ES DE UN DEPÓSITO. La sucursal activa no es un filtro más: es
  // parte de la identidad de la fila, igual que en /inventarios y /existencias.
  const { sucursal } = useSucursal();

  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");
  const [filtroEstado, setFiltroEstado] = useState<string>(SIN_FILTRO);
  const [filtroDiferencia, setFiltroDiferencia] = useState<string>(SIN_FILTRO);
  const [exportando, setExportando] = useState<"excel" | "pdf" | null>(null);

  // queryKey propia y no la de ["inventarios"]: aquélla guarda páginas sueltas
  // de 20 filas con los filtros de la pantalla de carga, y ésta el historial
  // entero. Compartirla haría que una pantalla sirviera la caché de la otra.
  //
  // LA SUCURSAL VA EN LA CLAVE. Sin ella, cambiar de depósito serviría los
  // conteos cacheados del anterior y nada avisaría de que son de otro lado.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["inventarios-reporte", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => traerConteos(empresa!.id, sucursal!.id),
    enabled: empresa !== null && sucursal !== null,
  });

  const conteos = data ?? [];

  // Búsqueda y orden en memoria: acá el historial está entero en el cliente, así
  // que ordenar por lo contado ordena TODO y no sólo lo que se alcanzó a traer.
  // SE SIGUE BUSCANDO POR MARCA Y CATEGORÍA aunque ya no tengan columna: el
  // backend las devuelve igual, y son la forma natural de acorralar una pieza
  // ("filtro" a secas devuelve demasiado). Quitarlas de la búsqueda porque se
  // fueron de la tabla haría que teclear una marca no encontrara nada, sin
  // ninguna pista de por qué.
  const { busqueda, setBusqueda, orden, alternarOrden, resultado } = useTablaListado<Inventario>(
    conteos,
    (i) => [i.codigoArticulo, i.nombreArticulo, i.marca, i.categoria, i.usuario],
  );

  // Los filtros se aplican DESPUÉS de la búsqueda y el orden, sobre el mismo
  // array que después se exporta.
  const filas = resultado.filter((i) => {
    const dia = diaDe(i);
    // Un conteo sin fecha queda fuera de cualquier rango: no se puede afirmar
    // que caiga dentro. Sin filtro de fechas se lista como el resto.
    if (desde && (dia === "" || dia < desde)) return false;
    if (hasta && (dia === "" || dia > hasta)) return false;
    if (filtroEstado !== SIN_FILTRO && i.estado !== filtroEstado) return false;

    if (filtroDiferencia !== SIN_FILTRO) {
      const diferencia = diferenciaDe(i);
      // `null` es "no se contó", y LAS DOS OPCIONES LO DESCARTAN. Sin el chequeo
      // explícito en "con", una comparación suelta lo dejaría pasar —`null !== 0`
      // es verdadero— y las planillas vacías aparecerían como si tuvieran
      // diferencia; en "sin", `diferencia !== 0` ya lo excluye por el mismo
      // motivo, que acá es lo correcto.
      if (filtroDiferencia === "con" && (diferencia === null || diferencia === 0)) return false;
      if (filtroDiferencia === "sin" && diferencia !== 0) return false;
    }

    return true;
  });

  // Los totales se cuentan sobre lo filtrado, no sobre el historial: son el
  // resumen de lo que se está mirando y de lo que va a salir en el archivo.
  const diferencias = filas.map(diferenciaDe);
  const totalConDiferencia = diferencias.filter((d) => d !== null && d !== 0).length;
  const totalSinContar = diferencias.filter((d) => d === null).length;
  // La suma NETA, no la de los valores absolutos: sobrantes y faltantes se
  // compensan, que es exactamente el número que se busca al cuadrar un depósito.
  const netoUnidades = diferencias.reduce<number>((acumulado, d) => acumulado + (d ?? 0), 0);

  function aplicarAtajo(rango: { desde: string; hasta: string }) {
    setDesde(rango.desde);
    setHasta(rango.hasta);
  }

  /** Los filtros activos, en texto, para que el reporte diga qué se consultó. */
  function descripcionFiltros(): string[] {
    const partes: string[] = [];
    if (desde && hasta) partes.push(`Período: ${desde} a ${hasta}`);
    else if (desde) partes.push(`Desde: ${desde}`);
    else if (hasta) partes.push(`Hasta: ${hasta}`);
    if (busqueda.trim()) partes.push(`Búsqueda: "${busqueda.trim()}"`);
    if (filtroEstado !== SIN_FILTRO) {
      partes.push(`Estado: ${ESTADOS.find((e) => e.valor === filtroEstado)?.etiqueta ?? ""}`);
    }
    if (filtroDiferencia !== SIN_FILTRO) {
      partes.push(
        `Diferencia: ${DIFERENCIAS.find((d) => d.valor === filtroDiferencia)?.etiqueta ?? ""}`,
      );
    }
    return partes;
  }

  async function exportarAExcel() {
    setExportando("excel");
    try {
      await descargarExcel({
        nombreArchivo: "inventarios",
        hoja: "Inventarios",
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
   * un `await` en el medio el navegador ya no lo asocia al gesto del usuario y
   * la bloquea sin decir nada.
   */
  function exportarAPdf() {
    setExportando("pdf");
    abrirPdf({
      nombreArchivo: "inventarios",
      titulo: "Reporte de inventarios",
      subtitulos: [
        empresa?.nombreEmpresa ?? "",
        sucursal ? `Sucursal: ${sucursal.nombreSucursal}` : "",
        ...descripcionFiltros(),
        `${filas.length} conteo${filas.length === 1 ? "" : "s"}` +
          (totalConDiferencia > 0 ? ` · ${totalConDiferencia} con diferencia` : ""),
      ].filter(Boolean),
      columnas: COLUMNAS,
      filas,
      // Vertical: sin marca ni categoría quedan ocho columnas, que entran en el
      // ancho de una A4 de pie. Apaisado desperdiciaría media hoja y obligaría a
      // girar el papel para leer una planilla que se archiva con el resto.
      orientacion: "portrait",
      // Sólo si la empresa tiene uno cargado: sin esa guarda se pediría una
      // imagen que ya se sabe que da 404.
      ...(empresa?.tieneLogo ? { urlLogo: urlLogoEmpresa(empresa.id) } : {}),
    })
      .catch((e: unknown) => toast.error(MENSAJE_ERROR(e, "No se pudo generar el PDF")))
      .finally(() => setExportando(null));
  }

  const sinDatos = filas.length === 0;

  return (
    // La RUTA y no el nombre: `MenuDinamico` acepta cualquiera de los dos, pero
    // el nombre lo escribe una persona en el ABM de páginas y si lo carga como
    // "Reporte de conteos" el ítem no se marcaría como activo.
    <AppLayout active="/inventarios-reporte" title="Reporte de inventarios">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div className="min-w-0">
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">
              Reporte de inventarios
            </h1>
            {/* DICE DE QUÉ SUCURSAL SON LOS NÚMEROS. Sin eso, la misma tabla con
                las mismas columnas muestra conteos distintos según el depósito
                activo y no hay nada en pantalla que lo explique. */}
            <p className="mt-1 text-sm text-muted-foreground">
              {sucursal
                ? `Conteos físicos de ${sucursal.nombreSucursal}.`
                : "Conteos físicos de la sucursal activa."}
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

        {/* El período va arriba de todo porque es la primera pregunta del
            reporte: de cuándo a cuándo. Los atajos cubren los rangos que se
            piden siempre; las dos fechas quedan para el caso puntual. */}
        <section className="surface-card space-y-3 p-4">
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <div className="space-y-1.5">
              <Label htmlFor="desde">Desde</Label>
              {/* `max`/`min` cruzados: el navegador no deja elegir un rango dado
                  vuelta, que devolvería cero filas sin decir por qué. */}
              <Input
                id="desde"
                type="date"
                value={desde}
                max={hasta || undefined}
                onChange={(e) => setDesde(e.target.value)}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="hasta">Hasta</Label>
              <Input
                id="hasta"
                type="date"
                value={hasta}
                min={desde || undefined}
                onChange={(e) => setHasta(e.target.value)}
              />
            </div>
          </div>

          <div className="flex flex-wrap items-center gap-2">
            {ATAJOS.map((atajo) => (
              <Button
                key={atajo.etiqueta}
                type="button"
                variant="outline"
                size="sm"
                onClick={() => aplicarAtajo(atajo.rango())}
              >
                {atajo.etiqueta}
              </Button>
            ))}
            {(desde || hasta) && (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={() => {
                  setDesde("");
                  setHasta("");
                }}
              >
                Todo el historial
              </Button>
            )}
          </div>

          {/* ESTADO Y DIFERENCIA VAN A LA VISTA, no sólo en el embudo del header
              de su columna.

              El embudo alcanza en un ABM, donde filtrar es ocasional. Acá son la
              pregunta del reporte —"mostrame los cerrados que no cuadran"— y un
              filtro que hay que descubrir pasando el mouse por un ícono es un
              filtro que no se usa. Siguen estando en la columna: quien ya los
              conoce los tiene donde espera, y los dos controles comparten estado,
              así que tocar uno mueve el otro.

              Botones y no ToggleGroup: es el mismo patrón de los atajos de fecha
              de acá arriba, y el componente ya está en el proyecto sin que
              ninguna pantalla lo use. */}
          <div className="space-y-2 border-t border-border pt-3">
            <div className="flex flex-wrap items-center gap-2">
              <span className="text-xs font-medium text-muted-foreground">Estado</span>
              {/* "Todos" es una opción más y no la ausencia de filtro: sin el
                  botón, volver atrás obliga a adivinar que se destilda haciendo
                  click de nuevo en el que está activo. */}
              <Button
                type="button"
                variant={filtroEstado === SIN_FILTRO ? "default" : "outline"}
                size="sm"
                onClick={() => setFiltroEstado(SIN_FILTRO)}
              >
                Todos
              </Button>
              {ESTADOS.map((e) => (
                <Button
                  key={e.valor}
                  type="button"
                  variant={filtroEstado === e.valor ? "default" : "outline"}
                  size="sm"
                  onClick={() => setFiltroEstado(e.valor)}
                >
                  {e.etiqueta}
                </Button>
              ))}
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <span className="text-xs font-medium text-muted-foreground">Conteo</span>
              <Button
                type="button"
                variant={filtroDiferencia === SIN_FILTRO ? "default" : "outline"}
                size="sm"
                onClick={() => setFiltroDiferencia(SIN_FILTRO)}
              >
                Todos
              </Button>
              {DIFERENCIAS.map((d) => (
                <Button
                  key={d.valor}
                  type="button"
                  variant={filtroDiferencia === d.valor ? "default" : "outline"}
                  size="sm"
                  onClick={() => setFiltroDiferencia(d.valor)}
                >
                  {d.etiqueta}
                </Button>
              ))}
            </div>
          </div>
        </section>

        {/* El resumen es la respuesta a la pregunta que trae a alguien acá:
            cuánto se desvió el depósito. La tabla es el detalle de eso. */}
        {!isPending && !isError && empresa !== null && (
          <section className="grid grid-cols-2 gap-3 sm:grid-cols-4 sm:gap-4">
            <article className="surface-card min-w-0 p-4">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">Conteos</p>
              <p className="mt-2 font-display text-lg font-bold text-foreground sm:text-2xl">
                {formatearMoneda(filas.length)}
              </p>
            </article>
            <article className="surface-card min-w-0 p-4">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">Con diferencia</p>
              <p
                className={`mt-2 font-display text-lg font-bold sm:text-2xl ${
                  totalConDiferencia > 0 ? "text-destructive" : "text-foreground"
                }`}
              >
                {formatearMoneda(totalConDiferencia)}
              </p>
            </article>
            <article className="surface-card min-w-0 p-4">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">Sin contar</p>
              <p className="mt-2 font-display text-lg font-bold text-foreground sm:text-2xl">
                {formatearMoneda(totalSinContar)}
              </p>
            </article>
            <article className="surface-card min-w-0 p-4">
              {/* EN UNIDADES, no en guaraníes: `EXISTENCIAS` guarda la cantidad
                  pero no a cuánto entró, así que valorizar el desvío todavía no
                  se puede. Decirlo en el rótulo evita que alguien lea el número
                  como plata — es el mismo cuidado que el `enUnidades: 'S'` de
                  los movimientos del dashboard. */}
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">
                Neto (unidades)
              </p>
              <p
                className={`mt-2 font-display text-lg font-bold tabular-nums sm:text-2xl ${
                  netoUnidades < 0 ? "text-destructive" : "text-foreground"
                }`}
              >
                {netoUnidades > 0 ? "+" : ""}
                {formatearMoneda(netoUnidades)}
              </p>
            </article>
          </section>
        )}

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por artículo, código, marca, categoría o quién contó…"
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
            {MENSAJE_ERROR(error, "No se pudieron cargar los conteos")}
          </p>
        )}

        {!isPending && !isError && empresa !== null && sinDatos && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {conteos.length === 0
                ? "Esta sucursal todavía no tiene conteos cargados."
                : "Ningún conteo coincide con el período, la búsqueda o los filtros."}
            </p>
          </div>
        )}

        {/* Móvil: tarjetas. Diez columnas en 360px obligan a scrollear de
            costado para leer una fila entera. */}
        {!sinDatos && (
          <ul className="space-y-3 sm:hidden">
            {filas.map((inv) => (
              <li key={inv.id} className="surface-card min-w-0 p-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-semibold text-foreground">{inv.nombreArticulo}</p>
                    <p className="mt-0.5 truncate text-xs text-muted-foreground">
                      {inv.codigoArticulo ?? "Sin código"}
                    </p>
                  </div>
                  <EstadoBadge estado={inv.estado} />
                </div>

                <div className="mt-3 flex items-end justify-between gap-3 border-t border-border pt-3">
                  <div className="min-w-0">
                    <p className="text-xs text-muted-foreground">Diferencia</p>
                    <p className="font-display text-xl font-bold">
                      <Cantidad valor={diferenciaDe(inv)} conSigno />
                    </p>
                  </div>
                  <p className="shrink-0 text-right text-xs text-muted-foreground">
                    Contado <Cantidad valor={inv.cantidadFisica} /> · Sistema{" "}
                    <Cantidad valor={sistemaDe(inv)} />
                    <span className="mt-0.5 block">{formatearFecha(inv.fechaInventario)}</span>
                  </p>
                </div>
              </li>
            ))}
          </ul>
        )}

        {!sinDatos && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "fechaInventario" ? orden.direccion : null}
                    onClick={() => alternarOrden("fechaInventario")}
                  >
                    Fecha
                  </TableHeadOrdenable>
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
                  <TableHeadOrdenable
                    direccion={orden?.campo === "cantidadFisica" ? orden.direccion : null}
                    onClick={() => alternarOrden("cantidadFisica")}
                    className="text-right"
                  >
                    Contado
                  </TableHeadOrdenable>
                  <TableHead className="text-right">Sistema</TableHead>
                  {/* El filtro de diferencias vive en la columna Diferencia, que
                      es donde se lo busca. NO es ordenable: la diferencia no es
                      un campo de la fila sino una resta, y `useTablaListado`
                      ordena por `keyof T`. */}
                  <TableHeadFiltrable
                    direccion={null}
                    onOrdenar={() => {}}
                    opciones={DIFERENCIAS}
                    valor={filtroDiferencia}
                    onFiltrar={setFiltroDiferencia}
                    buscarPlaceholder="Buscar situación…"
                    className="text-right"
                  >
                    Diferencia
                  </TableHeadFiltrable>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "estado" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("estado")}
                    opciones={ESTADOS}
                    valor={filtroEstado}
                    onFiltrar={setFiltroEstado}
                    buscarPlaceholder="Buscar estado…"
                  >
                    Estado
                  </TableHeadFiltrable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "usuario" ? orden.direccion : null}
                    onClick={() => alternarOrden("usuario")}
                  >
                    Contó
                  </TableHeadOrdenable>
                </TableRow>
              </TableHeader>
              <TableBody>
                {filas.map((inv) => (
                  <TableRow key={inv.id}>
                    <TableCell className="whitespace-nowrap text-muted-foreground">
                      {formatearFecha(inv.fechaInventario)}
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {inv.codigoArticulo ?? "—"}
                    </TableCell>
                    <TableCell className="font-medium text-foreground">
                      {inv.nombreArticulo}
                    </TableCell>
                    <TableCell className="text-right">
                      <Cantidad valor={inv.cantidadFisica} />
                    </TableCell>
                    <TableCell className="text-right">
                      <Cantidad valor={sistemaDe(inv)} />
                    </TableCell>
                    <TableCell className="text-right">
                      <Cantidad valor={diferenciaDe(inv)} conSigno />
                    </TableCell>
                    <TableCell>
                      <EstadoBadge estado={inv.estado} />
                    </TableCell>
                    <TableCell className="text-muted-foreground">{inv.usuario ?? "—"}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}

        {!sinDatos && (
          <p className="text-center text-xs text-muted-foreground">
            {filas.length === conteos.length
              ? `${formatearMoneda(conteos.length)} conteos`
              : `${formatearMoneda(filas.length)} de ${formatearMoneda(conteos.length)} conteos`}
            {" · "}
            Excel y PDF salen con estas mismas filas.
          </p>
        )}
      </main>
    </AppLayout>
  );
}
