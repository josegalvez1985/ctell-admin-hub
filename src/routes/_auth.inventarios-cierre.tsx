import { createFileRoute, Link } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { AlertTriangle, Loader2, Search, Stamp } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
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
import { api, ApiError, type Inventario } from "@/lib/api";
import { tituloPagina } from "@/lib/marca";
import { formatearMoneda } from "@/lib/moneda";
import { invalidarStock } from "@/lib/stock";

export const Route = createFileRoute("/_auth/inventarios-cierre")({
  head: () => ({
    meta: [
      { title: tituloPagina("Cierre de inventarios") },
      {
        name: "description",
        content: "Aplica los conteos físicos abiertos a la existencia de la sucursal.",
      },
    ],
  }),
  component: InventariosCierrePage,
});

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Una tanda falló entera a mitad del cierre. Lleva cuántos se habían cerrado
 * antes, porque esos ya están aplicados y el usuario tiene que saberlo.
 */
class ErrorCierreParcial extends Error {
  readonly cerrados: number;

  constructor(cerrados: number, mensaje: string) {
    super(mensaje);
    this.name = "ErrorCierreParcial";
    this.cerrados = cerrados;
  }
}

/**
 * Cuántos conteos se piden por vuelta: el techo de `/inventarios/listar`. Ver
 * `POR_PAGINA` en /inventarios-reporte — el JSON viaja por un bind de ORDS con
 * límite de 4000 bytes.
 */
const POR_PAGINA = 50;

/** Tope de páginas, para que un `total` mal calculado no pida para siempre. */
const MAX_PAGINAS = 100;

/**
 * Cuántos conteos se mandan por llamada a `cerrarVarios`. Es el `C_MAX_CIERRE`
 * del paquete: más da 400. Si cambia allá, cambia acá.
 */
const TANDA_CIERRE = 50;

/**
 * Todos los conteos ABIERTOS de la sucursal, en memoria.
 *
 * Enteros y no paginados con "Mostrar más": lo que se elige para cerrar tiene
 * que poder elegirse entre todos, y el resumen de lo que va a entrar y salir no
 * puede ser el de las primeras 20 filas.
 */
async function traerAbiertos(idEmpresa: number, idSucursal: number): Promise<Inventario[]> {
  const todos: Inventario[] = [];

  for (let pagina = 1; pagina <= MAX_PAGINAS; pagina++) {
    const respuesta = await api.inventarios.listar({
      idEmpresa,
      idSucursal,
      estado: "ABIERTO",
      pagina,
      tamanio: POR_PAGINA,
    });
    todos.push(...respuesta.items);
    if (todos.length >= respuesta.total || respuesta.items.length < POR_PAGINA) break;
  }

  return todos;
}

/**
 * Contra qué número se compara lo contado.
 *
 * **COPIADA de `_auth.inventarios.tsx`** —y su criterio vive también en
 * `_auth.inventarios-reporte.tsx` y en el `UNION ALL` de `PKG_DASHBOARD`—. Si
 * cambia acá, cambia en todos.
 *
 * Contra `cantidadSistema`: lo que el sistema decía cuando se contó, sellado
 * por el trigger, y contra lo que el cierre va a ajustar. Un abierto sin sello
 * (viejo, o con un estante sin contar) va contra `existenciaActual`, que es lo
 * que se sellará al cerrar.
 */
function sistemaDe(inventario: Inventario): number {
  return (
    inventario.cantidadSistema ??
    (inventario.estado === "ABIERTO" ? inventario.existenciaActual : 0)
  );
}

/** `null` cuando todavía no se contó: no es cero, es que no hay dato. */
function diferenciaDe(inventario: Inventario): number | null {
  if (inventario.cantidadFisica === null) return null;
  return inventario.cantidadFisica - sistemaDe(inventario);
}

/**
 * Lo que va a decir la existencia después de cerrar: la de **ahora** más la
 * diferencia del conteo.
 *
 * No es lo contado, y la diferencia importa: si desde que se contó se vendieron
 * 3, el cierre las respeta. Mostrar "queda en lo contado" sería prometer algo
 * que el backend no hace.
 */
function quedaEn(inventario: Inventario): number | null {
  const diferencia = diferenciaDe(inventario);
  if (diferencia === null) return null;
  return inventario.existenciaActual + diferencia;
}

/**
 * Lo que se vendió y compró desde que se contó. Cero si no hay sello: sin él
 * no hay contra qué medirlo.
 */
function movidoDesdeElConteo(inventario: Inventario): number {
  if (inventario.cantidadSistema === null) return 0;
  return inventario.existenciaActual - inventario.cantidadSistema;
}

/**
 * Por qué un conteo todavía no se puede cerrar, o `null` si se puede.
 *
 * Son las dos reglas que el backend chequea antes de aplicar (400). Repetirlas
 * acá no es duplicar la regla sino anticiparla: no ofrecer el tilde de algo que
 * se sabe que va a ser rechazado.
 */
function motivoNoListo(inventario: Inventario): string | null {
  if (inventario.cantidadUbicaciones === 0) return "Falta la ubicación";
  if (inventario.cantidadFisica === null) return "Estantes sin contar";
  return null;
}

/** Fecha y hora del conteo, con el mismo formato que /inventarios. */
function formatearFecha(valor: string | null): string {
  if (!valor) return "—";
  const fecha = new Date(valor);
  if (Number.isNaN(fecha.getTime())) return valor;
  return new Intl.DateTimeFormat("es-PY", { dateStyle: "medium", timeStyle: "short" }).format(
    fecha,
  );
}

type Situacion = "listos" | "diferencia" | "incompletos" | "todos";

/**
 * "Listos" por defecto: es lo que se viene a hacer acá. Los incompletos se ven
 * aparte, para saber qué falta completar en /inventarios.
 */
const SITUACIONES: { valor: Situacion; etiqueta: string }[] = [
  { valor: "listos", etiqueta: "Listos" },
  { valor: "diferencia", etiqueta: "Listos con diferencia" },
  { valor: "incompletos", etiqueta: "Incompletos" },
  { valor: "todos", etiqueta: "Todos" },
];

/** Un número de cantidad, con el signo cuando es una diferencia. */
function Cantidad({ valor, conSigno = false }: { valor: number | null; conSigno?: boolean }) {
  if (valor === null) return <span className="text-muted-foreground">—</span>;
  const clase = conSigno && valor < 0 ? "text-destructive font-semibold" : "";
  const signo = conSigno && valor > 0 ? "+" : "";
  return (
    <span className={`tabular-nums ${clase}`}>
      {signo}
      {formatearMoneda(valor)}
    </span>
  );
}

/**
 * La nota de "hubo movimientos desde que se contó", debajo de la existencia que
 * va a quedar. Explica por qué ese número no es igual a lo contado.
 */
function NotaMovimientos({ inventario }: { inventario: Inventario }) {
  const movido = movidoDesdeElConteo(inventario);
  if (movido === 0) return null;
  return (
    <span className="mt-0.5 block text-xs text-muted-foreground">
      {movido > 0 ? "+" : ""}
      {formatearMoneda(movido)} desde el conteo
    </span>
  );
}

type Progreso = { hechos: number; total: number };

function InventariosCierrePage() {
  const queryClient = useQueryClient();
  const { empresa } = useEmpresa();
  // EL CIERRE ES DE UN DEPÓSITO. Se cierran los conteos de la sucursal activa
  // y de ninguna otra, igual que se cargan en /inventarios.
  const { sucursal } = useSucursal();

  const [situacion, setSituacion] = useState<Situacion>("listos");
  const [seleccion, setSeleccion] = useState<Set<number>>(() => new Set());
  const [confirmando, setConfirmando] = useState(false);
  const [progreso, setProgreso] = useState<Progreso | null>(null);

  // Cuelga de ["inventarios"]: editar, anular o eliminar un conteo en
  // /inventarios invalida esa clave, y esta lista se refresca sola. La
  // sucursal va en la clave por lo mismo que en todas las pantallas de stock.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["inventarios", "cierre", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => traerAbiertos(empresa!.id, sucursal!.id),
    enabled: empresa !== null && sucursal !== null,
  });

  const abiertos = data ?? [];

  const { busqueda, setBusqueda, orden, alternarOrden, resultado } = useTablaListado<Inventario>(
    abiertos,
    (i) => [i.codigoArticulo, i.nombreArticulo, i.marca, i.categoria, i.usuario],
  );

  const filas = resultado.filter((i) => {
    const listo = motivoNoListo(i) === null;
    if (situacion === "listos") return listo;
    if (situacion === "diferencia") return listo && diferenciaDe(i) !== 0;
    if (situacion === "incompletos") return !listo;
    return true;
  });

  const listos = abiertos.filter((i) => motivoNoListo(i) === null);
  const totalIncompletos = abiertos.length - listos.length;

  // LA SELECCIÓN SE CRUZA CONTRA LO QUE HAY AHORA. Un conteo tildado que otro
  // usuario anuló, o que dejó de estar completo, desaparece de los listos al
  // refrescar: si siguiera en el Set, se mandaría a cerrar algo que ya no se
  // ve en pantalla.
  const seleccionados = listos.filter((i) => seleccion.has(i.id));
  const visiblesListos = filas.filter((i) => motivoNoListo(i) === null);
  const visiblesTildados = visiblesListos.filter((i) => seleccion.has(i.id)).length;

  const diferenciasSeleccion = seleccionados.map((i) => diferenciaDe(i) ?? 0);
  const entran = diferenciasSeleccion.filter((d) => d > 0).reduce((a, d) => a + d, 0);
  const salen = diferenciasSeleccion.filter((d) => d < 0).reduce((a, d) => a - d, 0);
  const conMovimientos = seleccionados.filter((i) => movidoDesdeElConteo(i) !== 0).length;

  function alternar(id: number, marcado: boolean) {
    setSeleccion((actual) => {
      const nueva = new Set(actual);
      if (marcado) nueva.add(id);
      else nueva.delete(id);
      return nueva;
    });
  }

  /** El tilde del encabezado: gobierna sólo lo visible y cerrable. */
  function alternarVisibles(marcado: boolean) {
    setSeleccion((actual) => {
      const nueva = new Set(actual);
      for (const i of visiblesListos) {
        if (marcado) nueva.add(i.id);
        else nueva.delete(i.id);
      }
      return nueva;
    });
  }

  const tildeEncabezado: boolean | "indeterminate" =
    visiblesListos.length > 0 && visiblesTildados === visiblesListos.length
      ? true
      : visiblesTildados > 0
        ? "indeterminate"
        : false;

  /**
   * De a tandas de 50, UNA DETRÁS DE OTRA y no en paralelo: el backend bloquea
   * la fila de existencia de cada artículo mientras lo cierra, y varias tandas
   * a la vez sólo competirían entre sí por las mismas filas de la caja.
   *
   * Si una tanda falla entera (se cortó la red), las anteriores ya quedaron
   * cerradas —cada conteo es su propia transacción—: se informa y se refresca,
   * y lo que quedó abierto se vuelve a ver en la lista.
   */
  const cerrar = useMutation({
    mutationFn: async (ids: number[]) => {
      let cerrados = 0;
      const rechazados: number[] = [];
      let primerError: string | null = null;

      setProgreso({ hechos: 0, total: ids.length });

      for (let desde = 0; desde < ids.length; desde += TANDA_CIERRE) {
        const tanda = ids.slice(desde, desde + TANDA_CIERRE);
        try {
          const respuesta = await api.inventarios.cerrarVarios(tanda, empresa!.id);
          cerrados += respuesta.cerrados;
          rechazados.push(...respuesta.rechazados);
          primerError ??= respuesta.primerError;
        } catch (e) {
          throw new ErrorCierreParcial(cerrados, MENSAJE_ERROR(e, "Se cortó el cierre"));
        }
        setProgreso({ hechos: Math.min(desde + tanda.length, ids.length), total: ids.length });
      }

      return { cerrados, rechazados, primerError };
    },
    onSuccess: ({ cerrados, rechazados, primerError }) => {
      if (rechazados.length === 0) {
        toast.success(
          cerrados === 1
            ? "Conteo cerrado. La existencia quedó ajustada"
            : `${formatearMoneda(cerrados)} conteos cerrados. La existencia quedó ajustada`,
        );
      } else {
        // Los rechazados siguen abiertos y se ven al refrescar. El motivo de
        // cada uno no viene —no entra en la respuesta—, el del primero sí.
        toast.warning(
          `Se cerraron ${formatearMoneda(cerrados)}; ${formatearMoneda(rechazados.length)} no se pudieron cerrar` +
            (primerError ? `: ${primerError}` : ""),
        );
      }
    },
    onError: (e) => {
      if (e instanceof ErrorCierreParcial) {
        toast.error(
          e.cerrados > 0
            ? `Se cerraron ${formatearMoneda(e.cerrados)} antes de que fallara: ${e.message}. Revisá lo que quedó abierto.`
            : e.message,
        );
      } else {
        toast.error(MENSAJE_ERROR(e, "No se pudieron cerrar los conteos"));
      }
    },
    onSettled: () => {
      // TODO LO QUE MUESTRA STOCK, no sólo esta lista: el cierre acaba de
      // escribir EXISTENCIAS. Se invalida también si falló a la mitad, porque
      // las tandas anteriores sí se aplicaron.
      invalidarStock(queryClient);
      queryClient.invalidateQueries({ queryKey: ["inventarios"] });
      queryClient.invalidateQueries({ queryKey: ["inventarios-reporte"] });
      setSeleccion(new Set());
      setProgreso(null);
      setConfirmando(false);
    },
  });

  const sinDatos = filas.length === 0;

  return (
    <AppLayout active="/inventarios-cierre" title="Cierre de inventarios">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div className="min-w-0">
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">
              Cierre de inventarios
            </h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {sucursal
                ? `Aplica los conteos abiertos de ${sucursal.nombreSucursal} a su existencia.`
                : "Aplica los conteos abiertos de la sucursal activa a su existencia."}
            </p>
          </div>

          {/* El botón dice CUÁNTOS: "Cerrar" a secas no deja ver, antes de
              confirmar, si se está por aplicar uno o doscientos. */}
          <Button
            onClick={() => setConfirmando(true)}
            disabled={seleccionados.length === 0 || cerrar.isPending}
          >
            <Stamp className="size-4" />
            {seleccionados.length === 0
              ? "Cerrar seleccionados"
              : `Cerrar ${formatearMoneda(seleccionados.length)} conteo${seleccionados.length === 1 ? "" : "s"}`}
          </Button>
        </div>

        {!isPending && !isError && empresa !== null && (
          <section className="grid grid-cols-2 gap-3 sm:grid-cols-4 sm:gap-4">
            <article className="surface-card min-w-0 p-4">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">Listos</p>
              <p className="mt-2 font-display text-lg font-bold text-foreground sm:text-2xl">
                {formatearMoneda(listos.length)}
              </p>
            </article>
            <article className="surface-card min-w-0 p-4">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">Seleccionados</p>
              <p className="mt-2 font-display text-lg font-bold text-foreground sm:text-2xl">
                {formatearMoneda(seleccionados.length)}
              </p>
            </article>
            {/* EN UNIDADES, no en guaraníes: EXISTENCIAS no guarda costo. Y
                separados, no el neto: diez de más en un artículo y diez de
                menos en otro dan cero neto y son dos errores. */}
            <article className="surface-card min-w-0 p-4">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">
                Entran (unidades)
              </p>
              <p className="mt-2 font-display text-lg font-bold tabular-nums text-foreground sm:text-2xl">
                {entran > 0 ? "+" : ""}
                {formatearMoneda(entran)}
              </p>
            </article>
            <article className="surface-card min-w-0 p-4">
              <p className="text-xs font-medium text-muted-foreground sm:text-sm">
                Salen (unidades)
              </p>
              <p
                className={`mt-2 font-display text-lg font-bold tabular-nums sm:text-2xl ${
                  salen > 0 ? "text-destructive" : "text-foreground"
                }`}
              >
                {salen > 0 ? "−" : ""}
                {formatearMoneda(salen)}
              </p>
            </article>
          </section>
        )}

        {/* Los incompletos no se pueden tildar, y sin este aviso el usuario ve
            filas grises sin saber qué hacer con ellas. El aviso dice dónde se
            arreglan. */}
        {!isPending && totalIncompletos > 0 && (
          <div className="flex items-start gap-2 rounded-lg border border-warning/40 bg-warning/10 px-3 py-2 text-sm text-foreground">
            <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" />
            <p>
              {totalIncompletos === 1
                ? "1 conteo todavía no se puede cerrar"
                : `${formatearMoneda(totalIncompletos)} conteos todavía no se pueden cerrar`}
              : les falta la ubicación o tienen un estante sin contar. Completalos en{" "}
              <Link to="/inventarios" className="font-medium underline underline-offset-2">
                Inventarios
              </Link>
              .
            </p>
          </div>
        )}

        <div className="flex flex-wrap items-center gap-2">
          {SITUACIONES.map((s) => (
            <Button
              key={s.valor}
              type="button"
              variant={situacion === s.valor ? "default" : "outline"}
              size="sm"
              onClick={() => setSituacion(s.valor)}
            >
              {s.etiqueta}
            </Button>
          ))}
        </div>

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
            {MENSAJE_ERROR(error, "No se pudieron cargar los conteos abiertos")}
          </p>
        )}

        {!isPending && !isError && empresa !== null && sinDatos && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {abiertos.length === 0 ? (
                <>
                  No hay conteos abiertos en esta sucursal. Se cargan en{" "}
                  <Link to="/inventarios" className="font-medium underline underline-offset-2">
                    Inventarios
                  </Link>
                  .
                </>
              ) : (
                "Ningún conteo coincide con la búsqueda o el filtro."
              )}
            </p>
          </div>
        )}

        {/* Móvil: tarjetas. El tilde va a la izquierda, del lado del pulgar
            que no sostiene el teléfono en la mayoría de los casos, y la
            tarjeta entera no es clickeable: tildar de paso al scrollear es
            justo lo que no tiene que pasar acá. */}
        {!sinDatos && (
          <ul className="space-y-3 sm:hidden">
            {filas.map((inv) => {
              const motivo = motivoNoListo(inv);
              return (
                <li key={inv.id} className="surface-card min-w-0 p-4">
                  <div className="flex items-start gap-3">
                    <Checkbox
                      className="mt-1"
                      checked={seleccion.has(inv.id) && motivo === null}
                      disabled={motivo !== null || cerrar.isPending}
                      onCheckedChange={(v) => alternar(inv.id, v === true)}
                      aria-label={`Seleccionar ${inv.nombreArticulo}`}
                    />
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">{inv.nombreArticulo}</p>
                      <p className="mt-0.5 truncate text-xs text-muted-foreground">
                        {[inv.codigoArticulo, inv.marca].filter(Boolean).join(" · ") ||
                          "Sin código"}
                      </p>
                    </div>
                  </div>

                  {motivo !== null ? (
                    <p className="mt-3 border-t border-border pt-3 text-sm text-warning">
                      {motivo}
                    </p>
                  ) : (
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
                        <span className="mt-0.5 block">
                          Queda en <Cantidad valor={quedaEn(inv)} />
                        </span>
                        <NotaMovimientos inventario={inv} />
                      </p>
                    </div>
                  )}
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
                  <TableHead className="w-10">
                    <Checkbox
                      checked={tildeEncabezado}
                      disabled={visiblesListos.length === 0 || cerrar.isPending}
                      onCheckedChange={(v) => alternarVisibles(v === true)}
                      aria-label="Seleccionar todos los conteos listos que se ven"
                    />
                  </TableHead>
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
                  {/* "al contar" en el rótulo: no es la existencia de ahora, y
                      sin decirlo la fila parece no cerrar contra /existencias. */}
                  <TableHead className="text-right">Sistema al contar</TableHead>
                  <TableHead className="text-right">Diferencia</TableHead>
                  <TableHead className="text-right">Queda en</TableHead>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "fechaInventario" ? orden.direccion : null}
                    onClick={() => alternarOrden("fechaInventario")}
                  >
                    Contado el
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "usuario" ? orden.direccion : null}
                    onClick={() => alternarOrden("usuario")}
                  >
                    Contó
                  </TableHeadOrdenable>
                </TableRow>
              </TableHeader>
              <TableBody>
                {filas.map((inv) => {
                  const motivo = motivoNoListo(inv);
                  return (
                    <TableRow
                      key={inv.id}
                      data-state={seleccion.has(inv.id) && motivo === null ? "selected" : undefined}
                    >
                      <TableCell>
                        <Checkbox
                          checked={seleccion.has(inv.id) && motivo === null}
                          disabled={motivo !== null || cerrar.isPending}
                          onCheckedChange={(v) => alternar(inv.id, v === true)}
                          aria-label={`Seleccionar ${inv.nombreArticulo}`}
                        />
                      </TableCell>
                      <TableCell className="max-w-[18rem]">
                        <p className="truncate font-medium text-foreground">{inv.nombreArticulo}</p>
                        <p className="truncate text-xs text-muted-foreground">
                          {[inv.codigoArticulo, inv.marca].filter(Boolean).join(" · ") || "—"}
                        </p>
                      </TableCell>
                      <TableCell className="text-right">
                        <Cantidad valor={inv.cantidadFisica} />
                      </TableCell>
                      <TableCell className="text-right">
                        {motivo === null ? <Cantidad valor={sistemaDe(inv)} /> : "—"}
                      </TableCell>
                      <TableCell className="text-right">
                        {motivo === null ? (
                          <Cantidad valor={diferenciaDe(inv)} conSigno />
                        ) : (
                          <span className="whitespace-nowrap text-sm text-warning">{motivo}</span>
                        )}
                      </TableCell>
                      <TableCell className="text-right">
                        <Cantidad valor={quedaEn(inv)} />
                        <NotaMovimientos inventario={inv} />
                      </TableCell>
                      <TableCell className="whitespace-nowrap text-sm text-muted-foreground">
                        {formatearFecha(inv.fechaInventario)}
                      </TableCell>
                      <TableCell className="max-w-[12rem] truncate text-sm text-muted-foreground">
                        {inv.usuario ?? "—"}
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
            {filas.length === abiertos.length
              ? `${formatearMoneda(abiertos.length)} conteos abiertos`
              : `${formatearMoneda(filas.length)} de ${formatearMoneda(abiertos.length)} conteos abiertos`}
          </p>
        )}

        <AlertDialog
          open={confirmando}
          // No se cierra mientras trabaja: cerrarlo a mitad de camino no frena
          // las tandas, sólo esconde el progreso.
          onOpenChange={(v) => !v && !cerrar.isPending && setConfirmando(false)}
        >
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>
                {seleccionados.length === 1
                  ? "¿Cerrar 1 conteo?"
                  : `¿Cerrar ${formatearMoneda(seleccionados.length)} conteos?`}
              </AlertDialogTitle>
              <AlertDialogDescription asChild>
                <div className="space-y-2">
                  <p>
                    Se aplican a la existencia de {sucursal?.nombreSucursal ?? "la sucursal activa"}
                    : entran <strong>{formatearMoneda(entran)}</strong> unidades y salen{" "}
                    <strong>{formatearMoneda(salen)}</strong>.
                  </p>
                  {conMovimientos > 0 && (
                    <p>
                      En {formatearMoneda(conMovimientos)} artículo{conMovimientos === 1 ? "" : "s"}{" "}
                      hubo ventas o compras desde que se contó: el ajuste las respeta, por eso
                      &quot;Queda en&quot; no es igual a lo contado.
                    </p>
                  )}
                  <p className="font-medium text-foreground">
                    No se puede deshacer. Para corregir un conteo cerrado hay que cargar otro.
                  </p>
                </div>
              </AlertDialogDescription>
            </AlertDialogHeader>

            {progreso && (
              <p className="flex items-center gap-2 text-sm text-muted-foreground">
                <Loader2 className="size-4 animate-spin" />
                Cerrando {formatearMoneda(progreso.hechos)} de {formatearMoneda(progreso.total)}…
              </p>
            )}

            <AlertDialogFooter>
              <AlertDialogCancel disabled={cerrar.isPending}>Cancelar</AlertDialogCancel>
              {/* Button y no AlertDialogAction: aquél cierra el diálogo al
                  hacer click, y acá tiene que quedar abierto mostrando el
                  progreso hasta que terminen las tandas. */}
              <Button
                onClick={() => cerrar.mutate(seleccionados.map((i) => i.id))}
                disabled={cerrar.isPending || seleccionados.length === 0}
              >
                {cerrar.isPending ? (
                  <Loader2 className="size-4 animate-spin" />
                ) : (
                  <Stamp className="size-4" />
                )}
                Cerrar y aplicar
              </Button>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </main>
    </AppLayout>
  );
}
