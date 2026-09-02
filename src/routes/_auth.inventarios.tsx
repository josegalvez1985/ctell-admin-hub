import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { AlertTriangle, Ban, Eye, Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { SelectorArticulo } from "@/components/ctell/SelectorArticulo";
import { SelectorModal, type AltaRapida } from "@/components/ctell/SelectorModal";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Textarea } from "@/components/ui/textarea";
import { api, ApiError, type Articulo, type EstadoInventario, type Inventario } from "@/lib/api";
import { tituloPagina } from "@/lib/marca";
import { formatearMoneda } from "@/lib/moneda";

export const Route = createFileRoute("/_auth/inventarios")({
  head: () => ({
    meta: [
      { title: tituloPagina("Inventarios") },
      {
        name: "description",
        content: "Conteo físico de artículos: al cerrarlo, ajusta la existencia.",
      },
    ],
  }),
  component: InventariosPage,
});

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Cuántas filas trae cada página, y cuántas suma cada "Mostrar más".
 *
 * Es el tamaño que se le PIDE AL SERVIDOR: el endpoint pagina de verdad, con un
 * techo de 50 porque el JSON viaja por un bind de ORDS limitado a 4000 bytes.
 */
const POR_PAGINA = 20;

/** Espera antes de mandar la búsqueda al servidor, igual que en Artículos. */
const ESPERA_BUSQUEDA_MS = 350;

/** El valor del combo de estado que significa "todos". Un `""` no lo acepta Radix. */
const TODOS = "todos";

/**
 * La opción "sin filtrar por estante" del selector de ubicación.
 *
 * No es `""`: `SelectorModal` trata la cadena vacía como "nada elegido" y no la
 * marcaría como seleccionada. Con un centinela propio, la fila se ve tildada
 * como cualquier otra.
 */
const TODAS_UBICACIONES = "todas";

const ESTADOS: { valor: EstadoInventario; etiqueta: string }[] = [
  { valor: "ABIERTO", etiqueta: "Abiertos" },
  { valor: "CERRADO", etiqueta: "Cerrados" },
  { valor: "ANULADO", etiqueta: "Anulados" },
  // Legado: ninguna transición lo produce, pero las filas viejas lo tienen y sin
  // esta opción no habría forma de encontrarlas.
  { valor: "PROCESADO", etiqueta: "Procesados (legado)" },
];

/**
 * Contra qué número se compara lo contado.
 *
 * **Son dos números distintos según el estado**, y confundirlos hace que la
 * columna Diferencia mienta:
 *
 * - Mientras está `ABIERTO`, contra `existenciaActual` — lo que el sistema dice
 *   ahora, que es lo que se está por corregir.
 * - Ya `CERRADO`, contra `cantidadSistema` — lo que el sistema decía cuando se
 *   aplicó el ajuste, sellado por el trigger. Usar la existencia actual daría
 *   cero siempre, porque el propio cierre las igualó.
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
 * Fecha y hora del conteo.
 *
 * **Va con hora, no sólo el día.** Dos conteos del mismo artículo el mismo día
 * se ordenan entre sí por la hora, y el que se cierra después es el que manda:
 * sin ella los dos empatan a medianoche y el orden lo termina decidiendo el id,
 * que es el momento de CARGA y no el del conteo.
 *
 * Los segundos se muestran sólo donde se está mirando UNA fila
 * (`conSegundos`). En la tabla son ruido: nadie escanea una columna por el
 * segundo en que se contó.
 *
 * El backend la manda en ISO sin zona ("2026-08-17T10:30:00"), que `new Date()`
 * interpreta como hora local — correcto acá, porque el conteo se hizo en la
 * misma zona que lo mira.
 */
function formatearFecha(valor: string | null, conSegundos = false): string {
  if (!valor) return "—";
  const fecha = new Date(valor);
  if (Number.isNaN(fecha.getTime())) return valor;
  return new Intl.DateTimeFormat("es-PY", {
    dateStyle: "medium",
    timeStyle: conSegundos ? "medium" : "short",
  }).format(fecha);
}

/**
 * Cómo se nombra un estante: "A · Estante 3 · Nivel 2".
 *
 * Mismo formato que usa `/articulos-ubicaciones`, y a propósito: es la misma
 * cosa vista desde otra pantalla, y dos formatos distintos para el mismo lugar
 * harían dudar de si son el mismo.
 */
function etiquetaUbicacion(zona: string, estante: number, nivel: number): string {
  return `${zona} · Estante ${estante} · Nivel ${nivel}`;
}

/**
 * ISO del backend → `YYYY-MM-DDTHH:mm:ss`, que es lo que espera un
 * `<input type="datetime-local" step="1">`.
 *
 * Se recortan los 19 primeros caracteres y no se pasa por `Date`: el valor ya
 * viene sin zona y en hora local, así que convertirlo de ida y vuelta sólo
 * agregaría una oportunidad de correrlo de huso.
 */
function paraInput(valor: string | null): string {
  return valor ? valor.slice(0, 19) : "";
}

/**
 * Ahora, en `YYYY-MM-DDTHH:mm:ss` local.
 *
 * A mano y no con `toISOString()`: ése devuelve UTC, que en Paraguay adelanta
 * hasta cuatro horas — y pasadas las 20:00 adelanta también el día.
 */
function ahora(): string {
  const f = new Date();
  const dosDigitos = (n: number) => String(n).padStart(2, "0");
  return (
    `${f.getFullYear()}-${dosDigitos(f.getMonth() + 1)}-${dosDigitos(f.getDate())}` +
    `T${dosDigitos(f.getHours())}:${dosDigitos(f.getMinutes())}:${dosDigitos(f.getSeconds())}`
  );
}

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
  if (valor === null) {
    return <span className="text-muted-foreground">Sin contar</span>;
  }
  const clase = conSigno && valor < 0 ? "text-destructive font-semibold" : "";
  const signo = conSigno && valor > 0 ? "+" : "";
  return (
    <span className={`tabular-nums ${clase}`}>
      {signo}
      {formatearMoneda(valor)}
    </span>
  );
}

function InventariosPage() {
  const queryClient = useQueryClient();
  const { empresa } = useEmpresa();
  // EL CONTEO ES DE UN DEPÓSITO. La sucursal activa no es un filtro más: es
  // parte de la identidad de la fila, igual que en /existencias. Contar "en
  // general" no significa nada — las unidades están en un estante concreto.
  const { sucursal } = useSucursal();

  const [creando, setCreando] = useState(false);
  const [editando, setEditando] = useState<Inventario | null>(null);
  const [viendo, setViendo] = useState<Inventario | null>(null);
  const [aAnular, setAAnular] = useState<Inventario | null>(null);
  const [aEliminar, setAEliminar] = useState<Inventario | null>(null);
  const [filtroEstado, setFiltroEstado] = useState<string>(TODOS);

  // `busqueda` es lo que se ve en el input (inmediato) y `busquedaEnvio` lo que
  // entra en la queryKey: sin el retraso, cada tecla dispara un request.
  const [busqueda, setBusqueda] = useState("");
  const [busquedaEnvio, setBusquedaEnvio] = useState("");

  useEffect(() => {
    const id = setTimeout(() => setBusquedaEnvio(busqueda), ESPERA_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  // LA SUCURSAL VA EN LA queryKey. Sin ella, cambiar de depósito serviría la
  // lista cacheada del anterior y nada avisaría de que esos conteos son de otro
  // lado.
  const { data, isPending, isError, error, fetchNextPage, hasNextPage, isFetchingNextPage } =
    useInfiniteQuery({
      queryKey: [
        "inventarios",
        empresa?.id ?? null,
        sucursal?.id ?? null,
        filtroEstado,
        busquedaEnvio.trim(),
      ],
      queryFn: ({ pageParam }) =>
        api.inventarios.listar({
          idEmpresa: empresa!.id,
          idSucursal: sucursal!.id,
          estado: filtroEstado === TODOS ? undefined : (filtroEstado as EstadoInventario),
          busqueda: busquedaEnvio,
          pagina: pageParam,
          tamanio: POR_PAGINA,
        }),
      enabled: empresa !== null && sucursal !== null,
      initialPageParam: 1,
      getNextPageParam: (ultima, paginas) => {
        const traidos = paginas.reduce((suma, p) => suma + p.items.length, 0);
        return traidos < ultima.total ? paginas.length + 1 : undefined;
      },
    });

  const filas = data?.pages.flatMap((p) => p.items) ?? [];
  const total = data?.pages[0]?.total ?? 0;

  /**
   * NOTA PARA QUIEN IMPLEMENTE EL CIERRE, en la pantalla que corresponda:
   * aplicar un conteo escribe `EXISTENCIAS`, así que hay que invalidar TODO lo
   * que muestra stock —`["existencias"]`, `["articulos"]` y `["dashboard"]`—, no
   * sólo `["inventarios"]`. Si no, los tres siguen mostrando el número viejo.
   *
   * Acá no hace falta: ninguna acción de esta pantalla mueve stock. Anular no
   * toca la existencia y eliminar sólo borra un borrador.
   */

  const anular = useMutation({
    mutationFn: (inventario: Inventario) =>
      api.inventarios.anular(inventario.id, inventario.idEmpresa),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["inventarios"] });
      toast.success("Conteo anulado. La existencia quedó como estaba");
      setAAnular(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo anular"));
      setAAnular(null);
    },
  });

  const eliminar = useMutation({
    mutationFn: (inventario: Inventario) =>
      api.inventarios.eliminar(inventario.id, inventario.idEmpresa),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["inventarios"] });
      toast.success("Conteo eliminado");
      setAEliminar(null);
    },
    onError: (e) => {
      // El 409 de "ya no está abierto" llega con su mensaje del backend, que es
      // más preciso que cualquier texto de acá.
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  const filtrando = filtroEstado !== TODOS || busquedaEnvio.trim() !== "";
  const sinDatos = !isPending && !isError && filas.length === 0;

  return (
    <AppLayout active="/inventarios" title="Inventarios">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div className="min-w-0">
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Conteo físico</h1>
            {/* DICE DE QUÉ SUCURSAL SON LOS CONTEOS. Sin eso, la misma tabla
                muestra filas distintas según el depósito activo y no hay nada en
                pantalla que lo explique. */}
            <p className="mt-1 text-sm text-muted-foreground">
              {sucursal
                ? `Lo que hay realmente en ${sucursal.nombreSucursal}. Al cerrar un conteo, su cantidad pasa a ser la existencia.`
                : "Lo que hay realmente en la sucursal activa."}
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null || sucursal === null}>
            <Plus className="size-4" />
            Nuevo conteo
          </Button>
        </div>

        <div className="flex flex-wrap items-center gap-3">
          <div className="relative min-w-0 flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
              placeholder="Nombre, código, marca o equivalencia…"
              className="pl-9"
            />
          </div>
          <Select value={filtroEstado} onValueChange={setFiltroEstado}>
            <SelectTrigger className="w-full sm:w-56">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={TODOS}>Todos los estados</SelectItem>
              {ESTADOS.map((e) => (
                <SelectItem key={e.valor} value={e.valor}>
                  {e.etiqueta}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        {empresa === null && !isPending && (
          <p className="rounded-lg border border-border px-3 py-6 text-center text-sm text-muted-foreground">
            No hay una empresa activa. Cerrá sesión y volvé a entrar eligiendo una.
          </p>
        )}

        {empresa !== null && sucursal === null && (
          <p className="rounded-lg border border-border px-3 py-6 text-center text-sm text-muted-foreground">
            Esta empresa no tiene ninguna sucursal activa. Un conteo es de un depósito concreto, así
            que hay que crear una antes.
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
            {MENSAJE_ERROR(error, "No se pudo cargar la lista")}
          </p>
        )}

        {/* El vacío distingue "sin datos" de "sin resultados": ofrecer "cargá el
            primero" cuando lo que pasa es que el filtro no encontró nada
            confunde. */}
        {sinDatos && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {filtrando
                ? "Ningún conteo coincide con el filtro."
                : "Todavía no se contó nada en esta sucursal."}
            </p>
            {!filtrando && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                <Plus className="size-4" />
                Cargar el primero
              </Button>
            )}
          </div>
        )}

        {/* Móvil: tarjetas. La tabla tiene siete columnas y en 360px obligaría a
            scrollear de costado para leer una fila. */}
        {filas.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {filas.map((inv) => (
              <li key={inv.id} className="surface-card p-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="truncate font-semibold text-foreground">{inv.nombreArticulo}</p>
                    <p className="truncate text-xs text-muted-foreground">
                      {[inv.codigoArticulo ?? "Sin código", inv.marca].filter(Boolean).join(" · ")}{" "}
                      · {formatearFecha(inv.fechaInventario)}
                    </p>
                  </div>
                  <EstadoBadge estado={inv.estado} />
                </div>

                <dl className="mt-3 grid grid-cols-3 gap-2 text-sm">
                  <div>
                    <dt className="text-xs text-muted-foreground">Sistema</dt>
                    <dd>
                      <Cantidad valor={sistemaDe(inv)} />
                    </dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">Contado</dt>
                    <dd>
                      <Cantidad valor={inv.cantidadFisica} />
                    </dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">Diferencia</dt>
                    <dd>
                      <Cantidad valor={diferenciaDe(inv)} conSigno />
                    </dd>
                  </div>
                </dl>

                <div className="mt-3 flex flex-wrap gap-2 border-t border-border pt-3">
                  {inv.estado === "ABIERTO" ? (
                    <>
                      <Button
                        variant="outline"
                        size="sm"
                        className="flex-1"
                        onClick={() => setEditando(inv)}
                      >
                        <Pencil className="size-4" />
                        Editar
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        className="flex-1"
                        onClick={() => setAAnular(inv)}
                      >
                        <Ban className="size-4" />
                        Anular
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        className="flex-1 text-destructive hover:text-destructive"
                        onClick={() => setAEliminar(inv)}
                      >
                        <Trash2 className="size-4" />
                        Eliminar
                      </Button>
                    </>
                  ) : (
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1"
                      onClick={() => setViendo(inv)}
                    >
                      <Eye className="size-4" />
                      Ver
                    </Button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}

        {filas.length > 0 && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Artículo</TableHead>
                  {/* El título dice contra qué se compara, porque cambia con el
                      estado: en un abierto es lo que hay hoy, en un cerrado lo
                      que había cuando se aplicó. */}
                  <TableHead className="text-right" title="Lo que dice el sistema">
                    Sistema
                  </TableHead>
                  <TableHead className="text-right">Contado</TableHead>
                  <TableHead className="text-right">Diferencia</TableHead>
                  <TableHead>Estado</TableHead>
                  <TableHead>Fecha</TableHead>
                  <TableHead>Cargado por</TableHead>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {filas.map((inv) => (
                  <TableRow key={inv.id}>
                    <TableCell className="max-w-[22rem]">
                      <p className="truncate font-medium text-foreground">{inv.nombreArticulo}</p>
                      {/* Código y MARCA: es con lo que se reconoce la pieza en
                          la mano, y es lo mismo que muestra la lista de valores
                          al elegirla. */}
                      <p className="truncate text-xs text-muted-foreground">
                        {[inv.codigoArticulo ?? "Sin código", inv.marca, inv.observacionesResumen]
                          .filter(Boolean)
                          .join(" · ")}
                      </p>
                    </TableCell>
                    <TableCell className="text-right">
                      <Cantidad valor={sistemaDe(inv)} />
                    </TableCell>
                    <TableCell className="text-right">
                      <Cantidad valor={inv.cantidadFisica} />
                    </TableCell>
                    <TableCell className="text-right">
                      <Cantidad valor={diferenciaDe(inv)} conSigno />
                    </TableCell>
                    <TableCell>
                      <EstadoBadge estado={inv.estado} />
                    </TableCell>
                    <TableCell className="whitespace-nowrap text-sm text-muted-foreground">
                      {formatearFecha(inv.fechaInventario)}
                    </TableCell>
                    <TableCell className="max-w-[12rem] truncate text-sm text-muted-foreground">
                      {inv.usuario ?? "—"}
                    </TableCell>
                    <TableCell className="text-right">
                      {/* NO HAY "CERRAR" ACÁ, Y NO ES UN OLVIDO. Cerrar aplica el
                          conteo al stock y no se deshace: no va como un ícono
                          más de una fila de listado, al lado de editar y borrar,
                          donde se toca de paso. Anular sí, porque no mueve nada.
                          El endpoint existe (`POST /inventarios/cerrar/:id`) y lo
                          va a usar la pantalla que se haga para eso. */}
                      <div className="flex justify-end gap-1">
                        {inv.estado === "ABIERTO" ? (
                          <>
                            <Button
                              variant="ghost"
                              size="icon"
                              onClick={() => setEditando(inv)}
                              title="Editar el conteo"
                            >
                              <Pencil className="size-4" />
                            </Button>
                            <Button
                              variant="ghost"
                              size="icon"
                              onClick={() => setAAnular(inv)}
                              title="Anular: descarta el conteo sin tocar el stock"
                            >
                              <Ban className="size-4" />
                            </Button>
                            <Button
                              variant="ghost"
                              size="icon"
                              onClick={() => setAEliminar(inv)}
                              title="Eliminar"
                              className="text-destructive hover:text-destructive"
                            >
                              <Trash2 className="size-4" />
                            </Button>
                          </>
                        ) : (
                          <Button
                            variant="ghost"
                            size="icon"
                            onClick={() => setViendo(inv)}
                            title="Ver el detalle"
                          >
                            <Eye className="size-4" />
                          </Button>
                        )}
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}

        {filas.length > 0 && (
          <p className="text-center text-xs text-muted-foreground">
            {filas.length} de {total} conteo{total === 1 ? "" : "s"}
          </p>
        )}

        {hasNextPage && (
          <div className="flex justify-center">
            <Button variant="outline" onClick={() => fetchNextPage()} disabled={isFetchingNextPage}>
              {isFetchingNextPage ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  Cargando…
                </>
              ) : (
                "Mostrar más"
              )}
            </Button>
          </div>
        )}

        {empresa !== null && sucursal !== null && (
          <InventarioDialog
            abierto={creando || editando !== null || viendo !== null}
            onCerrar={() => {
              setCreando(false);
              setEditando(null);
              setViendo(null);
            }}
            inventario={editando ?? viendo}
            soloLectura={viendo !== null}
            idEmpresa={empresa.id}
            idSucursal={sucursal.id}
            nombreSucursal={sucursal.nombreSucursal}
          />
        )}

        <AlertDialog open={aAnular !== null} onOpenChange={(v) => !v && setAAnular(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Anular el conteo?</AlertDialogTitle>
              <AlertDialogDescription>
                {aAnular
                  ? `El conteo de "${aAnular.nombreArticulo}" se descarta y la existencia queda como está. La fila se conserva: es la constancia de que alguien fue a contar.`
                  : ""}
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancelar</AlertDialogCancel>
              <AlertDialogAction
                onClick={() => aAnular && anular.mutate(aAnular)}
                disabled={anular.isPending}
              >
                Anular
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>

        <AlertDialog open={aEliminar !== null} onOpenChange={(v) => !v && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar el conteo?</AlertDialogTitle>
              <AlertDialogDescription>
                {aEliminar
                  ? `El conteo de "${aEliminar.nombreArticulo}" se borra sin dejar rastro. Si ya se fue a contar y sólo se decide no aplicarlo, anulalo en vez de borrarlo.`
                  : ""}
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancelar</AlertDialogCancel>
              <AlertDialogAction
                onClick={() => aEliminar && eliminar.mutate(aEliminar)}
                disabled={eliminar.isPending}
              >
                Eliminar
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </main>
    </AppLayout>
  );
}

/**
 * La cantidad se carga como TEXTO y se convierte al enviar.
 *
 * Un `z.number()` sobre un `<input>` obliga a `valueAsNumber`, que devuelve NaN
 * mientras el campo está vacío y hace saltar el error antes de que la persona
 * termine de escribir. Vacío es un estado legítimo acá: es la planilla abierta
 * a la que todavía no se le cargó lo contado.
 *
 * `Number()` crudo y no `numeroMoneda()`: esto son unidades, no guaraníes. El
 * campo no separa miles —igual que la cantidad mínima de un artículo— así que
 * no existe el `Number("34.200") === 34.2` que obliga a `InputMoneda` en los
 * campos de plata.
 */
const cantidad = z
  .string()
  .trim()
  .refine((v) => v === "" || (!Number.isNaN(Number(v)) && Number(v) >= 0), {
    message: "La cantidad contada debe ser un número mayor o igual a 0",
  });

const schema = z.object({
  idArticulo: z.string().min(1, "Elegí el artículo que se contó"),
  fechaInventario: z.string().min(1, "Obligatorio"),
  cantidadFisica: cantidad,
  observaciones: z.string().trim().max(1000, "Máximo 1000 caracteres"),
});

type FormValues = z.infer<typeof schema>;

/**
 * Alta, edición y vista del conteo. `inventario` en `null` es un alta.
 *
 * **Un conteo cerrado o anulado sólo se mira** (`soloLectura`): el backend lo
 * rechazaría igual, y presentar un formulario editable que después falla es
 * peor que no ofrecerlo.
 */
function InventarioDialog({
  abierto,
  onCerrar,
  inventario,
  soloLectura,
  idEmpresa,
  idSucursal,
  nombreSucursal,
}: {
  abierto: boolean;
  onCerrar: () => void;
  inventario: Inventario | null;
  soloLectura: boolean;
  idEmpresa: number;
  idSucursal: number;
  nombreSucursal: string;
}) {
  const queryClient = useQueryClient();
  const editando = inventario !== null;
  const [nombreArticulo, setNombreArticulo] = useState("");
  /**
   * El artículo tal como vino de la lista de valores, sólo si se lo acaba de
   * elegir. Es lo único que dice si tiene marca cargada: al reabrir un conteo
   * ese dato sale de `detalle`, no de acá.
   */
  const [articuloElegido, setArticuloElegido] = useState<Articulo | null>(null);
  /** La marca que se está por asignar desde acá, mientras no se confirme. */
  const [idMarcaAAsignar, setIdMarcaAAsignar] = useState("");
  /**
   * La marca recién asignada desde este diálogo, que pisa a las dos fuentes.
   *
   * Existe porque el dato original vive en dos lados —el artículo elegido, o el
   * detalle traído del servidor— y sólo uno de los dos se puede corregir en
   * memoria. Sin este override, asignar una marca mientras se EDITA un conteo
   * dejaba el aviso en pantalla hasta que volviera a llegar el detalle.
   */
  const [marcaAsignada, setMarcaAsignada] = useState<string | null>(null);
  /**
   * Ya se asignó una marca desde este diálogo.
   *
   * Es un flag aparte de `marcaAsignada` y no un `!== null`: el nombre se
   * resuelve buscando el id en el catálogo cargado, y si esa búsqueda fallara
   * —una marca creada acá mismo cuyo refetch todavía no llegó— el aviso seguiría
   * en pantalla sobre un artículo que YA tiene marca. La asignación se confirma
   * con el 200 del backend, no con haberle encontrado el nombre.
   */
  const [marcaYaAsignada, setMarcaYaAsignada] = useState(false);

  /** Misma idea que `idMarcaAAsignar`, para la categoría. */
  const [idCategoriaAAsignar, setIdCategoriaAAsignar] = useState("");
  /** Misma idea que `marcaAsignada`, para la categoría. */
  const [categoriaAsignada, setCategoriaAsignada] = useState<string | null>(null);
  /** Misma idea que `marcaYaAsignada`, para la categoría. */
  const [categoriaYaAsignada, setCategoriaYaAsignada] = useState(false);

  /**
   * La ubicación que se está por asignar. Misma idea que las otras dos, pero la
   * relación NO es la misma — ver `faltaUbicacion`.
   */
  const [idUbicacionAAsignar, setIdUbicacionAAsignar] = useState("");

  /**
   * Estante por el que se está filtrando la lista de artículos.
   *
   * NO ES UN CAMPO DEL CONTEO: no viaja al backend ni se guarda. El conteo ya
   * queda ubicado por su artículo — esto sólo acorta la lista para el que está
   * parado delante del estante contando lo que hay.
   */
  const [filtroUbicacion, setFiltroUbicacion] = useState(TODAS_UBICACIONES);

  /** El id que se le pasa al selector de artículo, o nada si es "todo el depósito". */
  const ubicacionFiltrada =
    filtroUbicacion === TODAS_UBICACIONES ? undefined : Number(filtroUbicacion);

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      idArticulo: "",
      fechaInventario: ahora(),
      cantidadFisica: "",
      observaciones: "",
    },
  });

  /**
   * EL DETALLE SE PIDE APARTE, y no se usa la fila del listado.
   *
   * El listado manda `observacionesResumen`: los primeros 150 caracteres. Si el
   * formulario cargara eso y lo guardara, el PUT escribiría el resumen encima
   * del texto completo y se perderían los otros 850 sin ningún error a la vista.
   */
  const { data: detalle } = useQuery({
    queryKey: ["inventario", inventario?.id ?? null, idEmpresa],
    queryFn: () => api.inventarios.obtener(inventario!.id, idEmpresa),
    enabled: abierto && inventario !== null,
  });

  /**
   * En una edición, mientras el detalle no llegó.
   *
   * NO se usa `isPending` de la consulta: una query deshabilitada queda en
   * `pending` para siempre, así que en un alta —donde no hay detalle que pedir—
   * habría dejado el formulario bloqueado sin que nada lo destrabe.
   */
  const esperandoDetalle = editando && detalle === undefined;

  const idArticuloElegido = Number(form.watch("idArticulo"));

  /**
   * Los estantes que ofrece el filtro de arriba: SÓLO los que tienen algo, y de
   * esta sucursal.
   *
   * `conArticulos` es lo que lo hace usable: en un depósito con la grilla entera
   * cargada la mayoría está vacía, y ofrecer un estante vacío acá es ofrecer una
   * lista de artículos que ya se sabe que va a salir en blanco.
   *
   * queryKey con `con-articulos`, la misma que usa el filtro de /articulos: es
   * el mismo recorte y conviene que compartan respuesta. NO es la del aviso de
   * "sin ubicación" de más abajo, que trae también las vacías porque ahí hacen
   * falta para poder asignar una.
   */
  const { data: ubicacionesFiltro, isPending: cargandoUbicacionesFiltro } = useQuery({
    queryKey: ["ubicaciones", "con-articulos", idEmpresa, idSucursal],
    queryFn: () => api.ubicaciones.listar({ idEmpresa, idSucursal, conArticulos: true }),
    enabled: abierto && !soloLectura && !editando,
  });

  /**
   * "Todo el depósito" va como una OPCIÓN MÁS, la primera.
   *
   * `SelectorModal` no ofrece un "ninguna" propio: una vez adentro del modal
   * sólo se puede elegir algo de la lista, así que sin esta fila no hay forma de
   * deshacer el filtro desde donde se lo puso. La ✕ de al lado no alcanza —
   * aparece recién con algo elegido, y para verla hay que cerrar el modal.
   *
   * El centinela es `TODAS` y no `""`: el selector usa la cadena vacía para "sin
   * elegir", y una opción con ese valor se vería como no seleccionada aunque
   * fuera justamente lo elegido.
   */
  const ubicacionesFiltroOpciones = [
    { valor: TODAS_UBICACIONES, etiqueta: "Todo el depósito" },
    ...(ubicacionesFiltro?.items ?? []).map((u) => ({
      valor: String(u.id),
      etiqueta: etiquetaUbicacion(u.zona, u.estante, u.nivel),
      descripcion: `${u.cantidadArticulos} artículo${u.cantidadArticulos === 1 ? "" : "s"}`,
    })),
  ];

  /**
   * Lo que el sistema dice para el artículo elegido, EN ESTA SUCURSAL.
   *
   * Se consulta en vivo en vez de leerlo del detalle: en un alta todavía no hay
   * fila que consultar, y en una edición el número pudo cambiar desde que se
   * abrió la planilla — que es exactamente el dato que hay que ver antes de
   * decidir si el conteo corrige algo.
   *
   * Comparte prefijo de clave con /existencias, así invalidar `["existencias"]`
   * después de un cierre también refresca esto.
   */
  const { data: existencia } = useQuery({
    queryKey: ["existencias", "articulo", idEmpresa, idSucursal, idArticuloElegido],
    queryFn: () =>
      api.existencias.listar({ idEmpresa, idSucursal, idArticulo: idArticuloElegido, tamanio: 1 }),
    enabled: abierto && Number.isFinite(idArticuloElegido) && idArticuloElegido > 0,
  });

  // Un artículo sin fila de existencia en este depósito no tiene 0 guardado: no
  // tiene fila. Para quien cuenta es lo mismo, y se muestra como 0.
  const sistema = existencia?.items[0]?.cantidadDisponible ?? 0;

  const contadoTexto = form.watch("cantidadFisica");
  const contado = contadoTexto.trim() === "" ? null : Number(contadoTexto);
  const diferencia = contado === null || Number.isNaN(contado) ? null : contado - sistema;

  /**
   * La marca del artículo elegido, y si se sabe cuál es.
   *
   * Vienen de dos lados según cómo se llegó: recién elegido, del propio artículo
   * que devolvió la lista de valores; reabriendo un conteo, de `detalle`. Se
   * distingue "no tiene marca" de "todavía no sé": sin `conoceMarca`, el aviso
   * de abajo parpadearía en cada apertura antes de que llegue el dato.
   */
  const conoceMarca = articuloElegido !== null || detalle !== undefined;
  const marcaActual =
    marcaAsignada ?? (articuloElegido ? articuloElegido.marca : (detalle?.marca ?? null));

  /**
   * El momento de cargar la marca que falta es ÉSTE.
   *
   * Quien cuenta tiene la pieza en la mano y ve de quién es; el que después abra
   * la ficha del artículo, no. Mandarlo a `/articulos` a completarla significa
   * perder el conteo a medio cargar, así que en la práctica no se hace nunca y
   * el catálogo se queda sin marcas para siempre.
   *
   * En sólo lectura no se ofrece: el diálogo de un conteo cerrado no edita nada,
   * y aunque esto toque el ARTÍCULO y no el conteo, mezclar las dos cosas ahí
   * haría dudar de si se está por mover algo del conteo.
   */
  const faltaMarca =
    !soloLectura &&
    idArticuloElegido > 0 &&
    conoceMarca &&
    marcaActual === null &&
    !marcaYaAsignada;

  // Mismo razonamiento que `conoceMarca`/`faltaMarca`, para la categoría: es
  // otro dato del artículo, independiente de la marca, que puede faltar solo.
  const conoceCategoria = articuloElegido !== null || detalle !== undefined;
  const categoriaActual =
    categoriaAsignada ??
    (articuloElegido ? articuloElegido.categoria : (detalle?.categoria ?? null));
  const faltaCategoria =
    !soloLectura &&
    idArticuloElegido > 0 &&
    conoceCategoria &&
    categoriaActual === null &&
    !categoriaYaAsignada;

  /**
   * Dónde está guardado el artículo elegido.
   *
   * **NO SALE DEL ARTÍCULO, y no puede salir.** A diferencia de la marca y la
   * categoría —que son una columna de `ARTICULOS`— la ubicación es una tabla de
   * CRUCE: un artículo puede estar en varios estantes a la vez. Por eso hay que
   * consultarla, y por eso asignar una no reemplaza a las que ya tenga.
   *
   * No se pide junto con el listado de conteos: sería una consulta N:M por fila
   * para un dato que sólo importa cuando se está mirando un artículo concreto.
   */
  const { data: ubicacionesDelArticulo, isPending: cargandoAsignaciones } = useQuery({
    queryKey: ["articulos-ubicaciones", idArticuloElegido],
    queryFn: () => api.articulosUbicaciones.listar({ idArticulo: idArticuloElegido }),
    enabled: abierto && !soloLectura && idArticuloElegido > 0,
  });

  /**
   * Las de ESTA sucursal, que son las únicas que le sirven a quien está
   * contando.
   *
   * El endpoint devuelve las asignaciones de todas las sucursales —un artículo
   * puede estar en un estante de Central y en otro del local— así que el recorte
   * va acá. Sin él, un artículo ubicado sólo en el otro depósito se vería como
   * "ya tiene ubicación" y nadie cargaría la de acá, que es la que hace falta
   * para encontrarlo la próxima vez.
   */
  const ubicacionesAca = (ubicacionesDelArticulo?.items ?? []).filter(
    (u) => u.idSucursal === idSucursal,
  );

  /**
   * El artículo no está ubicado en este depósito.
   *
   * Se espera a que la consulta responda (`cargandoAsignaciones`): sin eso el
   * aviso aparecería un instante en CADA artículo elegido, incluso en los que sí
   * tienen estante, porque una lista vacía y una lista que todavía no llegó se
   * ven igual.
   */
  const faltaUbicacion =
    !soloLectura && idArticuloElegido > 0 && !cargandoAsignaciones && ubicacionesAca.length === 0;

  // El catálogo entero: MARCAS no está paginado y es acotado. Misma queryKey que
  // /marcas y que la pantalla de Artículos, así se comparte la respuesta.
  const { data: marcas, isPending: cargandoMarcas } = useQuery({
    queryKey: ["marcas", idEmpresa],
    queryFn: () => api.marcas.listar({ idEmpresa }),
    enabled: abierto && faltaMarca,
  });

  const marcasOpciones = (marcas?.items ?? []).map((m) => ({
    valor: String(m.id),
    etiqueta: m.descripcion,
  }));

  /**
   * Crear la marca que falta sin salir del conteo.
   *
   * El id llega en la respuesta del POST, así que la opción se arma acá mismo:
   * esperar al refetch del catálogo dejaría un hueco en el que el selector
   * todavía no conoce el valor que acaba de recibir. Mismo mecanismo que usa el
   * formulario de artículos.
   */
  const altaMarca: AltaRapida = {
    titulo: "Nueva marca",
    descripcion: "Se crea para esta empresa y queda disponible en todo el catálogo.",
    campos: [{ nombre: "descripcion", etiqueta: "Descripción", placeholder: "Sakura" }],
    crear: async (v) => {
      const descripcion = v["descripcion"] ?? "";
      const { id } = await api.marcas.crear({ idEmpresa, descripcion });
      await queryClient.invalidateQueries({ queryKey: ["marcas"] });
      return { valor: String(id), etiqueta: descripcion };
    },
  };

  /**
   * ESTO MODIFICA EL ARTÍCULO, no el conteo — y por eso es un botón aparte y no
   * un campo más que se guarde con "Cargar conteo".
   *
   * Se manda sólo `idMarca`: el backend usa `NVL` en cada columna, así que lo
   * ausente conserva su valor y no hay riesgo de pisar el resto de la ficha.
   */
  const asignarMarca = useMutation({
    mutationFn: (idMarca: number) =>
      api.articulos.actualizar(idArticuloElegido, { idEmpresa, idMarca }),
    onSuccess: (_resultado, idMarca) => {
      const marca = marcasOpciones.find((m) => m.valor === String(idMarca))?.etiqueta ?? null;

      // El estado local se corrige a mano además de invalidar: el aviso tiene
      // que desaparecer YA, y el dato del artículo no vive en ninguna caché que
      // este diálogo pueda refrescar sola.
      setMarcaAsignada(marca);
      setMarcaYaAsignada(true);
      setIdMarcaAAsignar("");

      // La etiqueta del selector gana la marca, igual que si se acabara de
      // elegir el artículo. Se parte por " · " y se toma la primera mitad para
      // no encadenar dos marcas si esto se hiciera dos veces.
      if (marca) {
        const soloNombre = articuloElegido?.nombreArticulo ?? nombreArticulo.split(" · ")[0] ?? "";
        setNombreArticulo(`${soloNombre} · ${marca}`);
      }

      // Los listados que muestran la marca del artículo quedaron con el dato
      // viejo, incluido el de conteos.
      queryClient.invalidateQueries({ queryKey: ["articulos"] });
      queryClient.invalidateQueries({ queryKey: ["articulos-selector"] });
      queryClient.invalidateQueries({ queryKey: ["inventarios"] });
      queryClient.invalidateQueries({ queryKey: ["inventario"] });
      toast.success(marca ? `Marca "${marca}" asignada al artículo` : "Marca asignada");
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo asignar la marca")),
  });

  // Igual que MARCAS: CATEGORIAS no está paginado y es acotado. Misma queryKey
  // que /categorias y que la pantalla de Artículos, para compartir la respuesta.
  const { data: categorias, isPending: cargandoCategorias } = useQuery({
    queryKey: ["categorias", idEmpresa],
    queryFn: () => api.categorias.listar({ idEmpresa }),
    enabled: abierto && faltaCategoria,
  });

  const categoriasOpciones = (categorias?.items ?? []).map((c) => ({
    valor: String(c.id),
    etiqueta: c.nombreCategoria,
  }));

  /** Crear la categoría que falta sin salir del conteo. Mismo mecanismo que `altaMarca`. */
  const altaCategoria: AltaRapida = {
    titulo: "Nueva categoría",
    descripcion: "Se crea para esta empresa y queda disponible en todo el catálogo.",
    campos: [{ nombre: "nombreCategoria", etiqueta: "Nombre", placeholder: "Filtros" }],
    crear: async (v) => {
      const nombreCategoria = v["nombreCategoria"] ?? "";
      const { id } = await api.categorias.crear({ idEmpresa, nombreCategoria });
      await queryClient.invalidateQueries({ queryKey: ["categorias"] });
      return { valor: String(id), etiqueta: nombreCategoria };
    },
  };

  /**
   * ESTO MODIFICA EL ARTÍCULO, no el conteo — mismo criterio que `asignarMarca`.
   * La categoría no forma parte de la etiqueta del selector —sólo la marca lo
   * hace—, así que acá no hay `nombreArticulo` que recomponer.
   */
  const asignarCategoria = useMutation({
    mutationFn: (idCategoria: number) =>
      api.articulos.actualizar(idArticuloElegido, { idEmpresa, idCategoria }),
    onSuccess: (_resultado, idCategoria) => {
      const categoria =
        categoriasOpciones.find((c) => c.valor === String(idCategoria))?.etiqueta ?? null;

      setCategoriaAsignada(categoria);
      setCategoriaYaAsignada(true);
      setIdCategoriaAAsignar("");

      queryClient.invalidateQueries({ queryKey: ["articulos"] });
      queryClient.invalidateQueries({ queryKey: ["articulos-selector"] });
      queryClient.invalidateQueries({ queryKey: ["inventarios"] });
      queryClient.invalidateQueries({ queryKey: ["inventario"] });
      toast.success(
        categoria ? `Categoría "${categoria}" asignada al artículo` : "Categoría asignada",
      );
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo asignar la categoría")),
  });

  /**
   * Las ubicaciones DE ESTA SUCURSAL, para elegir una.
   *
   * `idSucursal` no es opcional acá: el catálogo de ubicaciones es de toda la
   * empresa, y ofrecer un estante del otro depósito sería dejar asignar el
   * artículo a un lugar donde no está. El backend no lo impide —sólo rechaza el
   * cruce entre empresas— así que el recorte tiene que hacerlo la pantalla.
   */
  const { data: ubicaciones, isPending: cargandoUbicaciones } = useQuery({
    queryKey: ["ubicaciones", idEmpresa, idSucursal],
    queryFn: () => api.ubicaciones.listar({ idEmpresa, idSucursal }),
    enabled: abierto && faltaUbicacion,
  });

  const ubicacionesOpciones = (ubicaciones?.items ?? []).map((u) => ({
    valor: String(u.id),
    etiqueta: etiquetaUbicacion(u.zona, u.estante, u.nivel),
    ...(u.descripcion ? { descripcion: u.descripcion } : {}),
  }));

  /**
   * Crear el estante que falta sin salir del conteo.
   *
   * Tres campos y no uno, porque una ubicación es zona + estante + nivel. La
   * sucursal NO es un campo: es la del conteo, y se dice en la descripción para
   * que no parezca una decisión pendiente.
   */
  const altaUbicacion: AltaRapida = {
    titulo: "Nueva ubicación",
    descripcion: `Se crea en ${nombreSucursal} y queda elegida.`,
    campos: [
      { nombre: "zona", etiqueta: "Zona", placeholder: "A" },
      { nombre: "estante", etiqueta: "Estante", tipo: "numero", placeholder: "3" },
      { nombre: "nivel", etiqueta: "Nivel", tipo: "numero", placeholder: "2" },
    ],
    crear: async (v) => {
      const zona = v["zona"] ?? "";
      const estante = Number(v["estante"]);
      const nivel = Number(v["nivel"]);
      const { id } = await api.ubicaciones.crear({
        idEmpresa,
        idSucursal,
        zona,
        estante,
        nivel,
      });
      await queryClient.invalidateQueries({ queryKey: ["ubicaciones"] });
      return { valor: String(id), etiqueta: etiquetaUbicacion(zona, estante, nivel) };
    },
  };

  /**
   * ASIGNA, no reemplaza. La tabla es un cruce: el artículo queda en el estante
   * nuevo *además* de donde ya estuviera. Mover uno de lugar es quitar la
   * asignación vieja desde `/articulos-ubicaciones`, que es la pantalla que
   * tiene esa operación.
   *
   * Acá no hace falta el flag "ya asigné" que sí tienen la marca y la categoría:
   * el aviso se apaga solo, porque `faltaUbicacion` sale de una CONSULTA que se
   * invalida al terminar. Es la ventaja de que el dato no viva en el artículo.
   */
  const asignarUbicacion = useMutation({
    mutationFn: (idUbicacion: number) =>
      api.articulosUbicaciones.asignar({ idArticulo: idArticuloElegido, idUbicacion }),
    onSuccess: (_resultado, idUbicacion) => {
      const donde = ubicacionesOpciones.find((u) => u.valor === String(idUbicacion))?.etiqueta;
      setIdUbicacionAAsignar("");
      queryClient.invalidateQueries({ queryKey: ["articulos-ubicaciones"] });
      toast.success(donde ? `Artículo ubicado en ${donde}` : "Ubicación asignada");
    },
    // El 409 de "ya estaba asignado" llega con su mensaje del backend.
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo asignar la ubicación")),
  });

  // Se rellena al abrir: el diálogo se monta una vez y se reusa, así que sin
  // esto el segundo conteo que se abriera mostraría los datos del primero.
  useEffect(() => {
    if (!abierto) return;

    // Lo de la marca y la categoría se limpia SIEMPRE, en los dos caminos: son
    // datos del artículo anterior y arrastrarlos haría que el aviso hable de
    // una pieza que ya no es la que está en pantalla.
    setArticuloElegido(null);
    setMarcaAsignada(null);
    setMarcaYaAsignada(false);
    setIdMarcaAAsignar("");
    setCategoriaAsignada(null);
    setCategoriaYaAsignada(false);
    setIdCategoriaAAsignar("");
    // La ubicación no tiene "asignada"/"ya asignada": su aviso sale de una
    // consulta, no de estado local. Sólo hay que limpiar lo elegido a medias.
    setIdUbicacionAAsignar("");
    // El filtro de arriba también: es de la sesión de carga anterior, y dejarlo
    // haría que el próximo conteo arranque con la lista acotada a un estante que
    // nadie eligió esta vez.
    setFiltroUbicacion(TODAS_UBICACIONES);

    if (inventario === null) {
      form.reset({
        idArticulo: "",
        fechaInventario: ahora(),
        cantidadFisica: "",
        observaciones: "",
      });
      setNombreArticulo("");
      return;
    }

    // SE ESPERA AL DETALLE Y SE RESETEA UNA SOLA VEZ. Precargar primero la fila
    // del listado y volver a resetear cuando llega el detalle se lleva puesto lo
    // que se haya tipeado en el medio — son unos cientos de milisegundos, pero
    // alcanzan para que el campo se vacíe solo mientras alguien escribe. Los
    // campos van deshabilitados hasta entonces (`esperandoDetalle`).
    if (!detalle) return;

    // Con la marca, igual que la etiqueta que arma el selector al elegir. Si acá
    // fuera el nombre pelado, el mismo campo se leería distinto según se hubiera
    // acabado de elegir el artículo o se estuviera reabriendo el conteo.
    setNombreArticulo(
      detalle.marca ? `${detalle.nombreArticulo} · ${detalle.marca}` : detalle.nombreArticulo,
    );
    form.reset({
      idArticulo: String(detalle.idArticulo),
      fechaInventario: paraInput(detalle.fechaInventario) || ahora(),
      cantidadFisica: detalle.cantidadFisica === null ? "" : String(detalle.cantidadFisica),
      observaciones: detalle.observaciones ?? "",
    });
  }, [abierto, inventario, detalle, form]);

  const guardar = useMutation({
    mutationFn: (valores: FormValues) => {
      // El campo vacío se manda como `undefined`, que el cliente traduce a "" y
      // el backend interpreta como BORRAR. Es deliberado: sin eso, quien cargó
      // 12 por error no podría volver a dejar la planilla sin contar, y cerrar
      // aplicaría ese 12 al stock.
      const cantidadFisica =
        valores.cantidadFisica.trim() === "" ? undefined : Number(valores.cantidadFisica);

      return inventario
        ? api.inventarios.actualizar(inventario.id, {
            idEmpresa,
            fechaInventario: valores.fechaInventario,
            cantidadFisica,
            observaciones: valores.observaciones,
          })
        : api.inventarios.crear({
            idEmpresa,
            idSucursal,
            idArticulo: Number(valores.idArticulo),
            fechaInventario: valores.fechaInventario,
            cantidadFisica,
            observaciones: valores.observaciones,
          });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["inventarios"] });
      queryClient.invalidateQueries({ queryKey: ["inventario"] });
      toast.success(editando ? "Conteo actualizado" : "Conteo cargado");
      onCerrar();
    },
    onError: (e) => {
      // El 409 de "ya hay un conteo abierto de este artículo" llega con su
      // mensaje del backend, que explica qué hacer.
      toast.error(MENSAJE_ERROR(e, "No se pudo guardar"));
    },
  });

  const titulo = soloLectura ? "Detalle del conteo" : editando ? "Editar conteo" : "Nuevo conteo";

  return (
    <Dialog open={abierto} onOpenChange={(v) => !v && onCerrar()}>
      {/* max-h + overflow-y-auto: con los dos avisos de "falta marca/categoría"
          sumados a los campos, el contenido pasa la altura de la pantalla y sin
          esto el diálogo se corta contra el borde de la ventana sin forma de
          bajar hasta "Guardar". */}
      <DialogContent className="scrollbar-fino max-h-[92vh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{titulo}</DialogTitle>
          <DialogDescription>
            {soloLectura
              ? "Un conteo que ya no está abierto no se modifica: es la evidencia de lo que se contó ese día."
              : `Cuántas unidades hay realmente en ${nombreSucursal}. El número se aplica al stock recién cuando se cierra el conteo.`}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form
            onSubmit={form.handleSubmit((v) => guardar.mutate(v))}
            className="space-y-4"
            noValidate
          >
            {/* ARRIBA DEL ARTÍCULO, y no es sólo orden visual: así se cuenta de
                verdad. Alguien se para delante de un estante y cuenta lo que
                hay ahí, uno por uno — elegir primero la ubicación deja el
                selector de artículo con esa lista corta en vez del catálogo
                entero, que obliga a teclear cada nombre de memoria.

                NO ES UN CAMPO DEL CONTEO: no se guarda. El conteo se ubica solo,
                por el artículo. Por eso va fuera del <FormField> y sin hijos de
                ui/form, que lanzarían sin su <FormItem>.

                En sólo lectura no se muestra: filtrar una lista que no se puede
                usar no sirve de nada. */}
            {!soloLectura && !editando && (
              <div className="space-y-2">
                <Label>Ubicación (opcional)</Label>
                {/* Sin botón de limpiar al lado: "Todo el depósito" es la
                    primera opción DENTRO del modal, así que se deshace el
                    filtro desde el mismo lugar donde se lo puso. Una ✕ afuera
                    obligaba a cerrar el modal para encontrarla. */}
                <SelectorModal
                  opciones={ubicacionesFiltroOpciones}
                  value={filtroUbicacion}
                  onChange={(valor) => {
                    setFiltroUbicacion(valor);
                    // El artículo elegido puede no estar en el estante nuevo:
                    // dejarlo seleccionado mostraría un nombre que ya no figura
                    // en la lista de abajo.
                    form.setValue("idArticulo", "");
                    setNombreArticulo("");
                    setArticuloElegido(null);
                  }}
                  titulo={`Ubicaciones de ${nombreSucursal}`}
                  descripcion="Sólo los estantes que tienen algo guardado."
                  buscarPlaceholder="Buscar zona, estante o nivel…"
                  vacioTexto="Ningún estante de esta sucursal tiene artículos asignados."
                  cargando={cargandoUbicacionesFiltro}
                  className="w-full"
                />
                <p className="text-[0.8rem] text-muted-foreground">
                  Acota la lista de abajo a lo guardado en ese estante. No se guarda en el conteo.
                </p>
              </div>
            )}

            <FormField
              control={form.control}
              name="idArticulo"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Artículo</FormLabel>
                  <FormControl>
                    <SelectorArticulo
                      idEmpresa={idEmpresa}
                      {...(ubicacionFiltrada ? { idUbicacion: ubicacionFiltrada } : {})}
                      value={field.value}
                      etiquetaSeleccionada={nombreArticulo || undefined}
                      onChange={(valor, etiqueta, articulo) => {
                        field.onChange(valor);
                        setNombreArticulo(etiqueta);
                        // Se guarda el artículo entero para saber si tiene
                        // marca. `undefined` sólo llega desde un alta rápida,
                        // que no existe en esta pantalla.
                        setArticuloElegido(articulo ?? null);
                        setMarcaAsignada(null);
                        setMarcaYaAsignada(false);
                        setIdMarcaAAsignar("");
                        setCategoriaAsignada(null);
                        setCategoriaYaAsignada(false);
                        setIdCategoriaAAsignar("");
                        setIdUbicacionAAsignar("");
                      }}
                      // NO SE CAMBIA AL EDITAR: mover el conteo a otro artículo
                      // lo aplicaría sobre una existencia que nadie contó. El
                      // trigger lo rechaza; acá directamente no se ofrece.
                      disabled={editando}
                    />
                  </FormControl>
                  {editando && !soloLectura && (
                    <FormDescription>
                      No se cambia: contar otro artículo es cargar otro conteo.
                    </FormDescription>
                  )}
                  <FormMessage />
                </FormItem>
              )}
            />

            {/* SIN MARCA: se ofrece cargarla acá mismo.

                Va FUERA de cualquier <FormItem> y sin hijos de ui/form: no es un
                campo del conteo —modifica el ARTÍCULO— y `useFormField()` lanza
                sin su contexto, llevándose la página entera. */}
            {faltaMarca && (
              <div className="space-y-3 rounded-lg border border-warning/40 bg-warning/10 p-3">
                <div className="flex items-start gap-2">
                  <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" />
                  <p className="text-sm text-foreground">
                    Este artículo no tiene marca cargada.{" "}
                    <span className="text-muted-foreground">
                      Ahora la tenés en la mano: elegila o creala y queda en su ficha.
                    </span>
                  </p>
                </div>

                <div className="flex flex-wrap items-center gap-2">
                  <SelectorModal
                    opciones={marcasOpciones}
                    value={idMarcaAAsignar}
                    onChange={setIdMarcaAAsignar}
                    placeholder="Elegí la marca"
                    titulo="Marca del artículo"
                    buscarPlaceholder="Buscar marca…"
                    cargando={cargandoMarcas}
                    className="min-w-0 flex-1"
                    alta={altaMarca}
                  />
                  <Button
                    type="button"
                    // type="button" NO es decorativo: adentro de un <form>, un
                    // botón sin type dispara el submit y guardaría el conteo a
                    // medio cargar en vez de asignar la marca.
                    onClick={() => asignarMarca.mutate(Number(idMarcaAAsignar))}
                    disabled={idMarcaAAsignar === "" || asignarMarca.isPending}
                  >
                    {asignarMarca.isPending && <Loader2 className="size-4 animate-spin" />}
                    Asignar
                  </Button>
                </div>

                <p className="text-xs text-muted-foreground">
                  Cambia la ficha del artículo, no este conteo — y se aplica al tocar "Asignar", sin
                  esperar a que guardes.
                </p>
              </div>
            )}

            {/* SIN CATEGORÍA: mismo criterio que el aviso de marca de arriba. */}
            {faltaCategoria && (
              <div className="space-y-3 rounded-lg border border-warning/40 bg-warning/10 p-3">
                <div className="flex items-start gap-2">
                  <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" />
                  <p className="text-sm text-foreground">
                    Este artículo no tiene categoría cargada.{" "}
                    <span className="text-muted-foreground">
                      Elegí una existente o creá una y queda en su ficha.
                    </span>
                  </p>
                </div>

                <div className="flex flex-wrap items-center gap-2">
                  <SelectorModal
                    opciones={categoriasOpciones}
                    value={idCategoriaAAsignar}
                    onChange={setIdCategoriaAAsignar}
                    placeholder="Elegí la categoría"
                    titulo="Categoría del artículo"
                    buscarPlaceholder="Buscar categoría…"
                    cargando={cargandoCategorias}
                    className="min-w-0 flex-1"
                    alta={altaCategoria}
                  />
                  <Button
                    type="button"
                    // type="button" NO es decorativo: mismo motivo que en el
                    // botón de "Asignar" de la marca.
                    onClick={() => asignarCategoria.mutate(Number(idCategoriaAAsignar))}
                    disabled={idCategoriaAAsignar === "" || asignarCategoria.isPending}
                  >
                    {asignarCategoria.isPending && <Loader2 className="size-4 animate-spin" />}
                    Asignar
                  </Button>
                </div>

                <p className="text-xs text-muted-foreground">
                  Cambia la ficha del artículo, no este conteo — y se aplica al tocar "Asignar", sin
                  esperar a que guardes.
                </p>
              </div>
            )}

            {/* SIN UBICACIÓN EN ESTE DEPÓSITO.
                Mismo patrón que marca y categoría, con dos diferencias que se
                explican en `faltaUbicacion` y en `asignarUbicacion`: el dato
                sale de una consulta —es una tabla de cruce, no una columna— y
                asignar SUMA un estante en vez de reemplazar. */}
            {faltaUbicacion && (
              <div className="space-y-3 rounded-lg border border-warning/40 bg-warning/10 p-3">
                <div className="flex items-start gap-2">
                  <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" />
                  <p className="text-sm text-foreground">
                    Este artículo no tiene ubicación en {nombreSucursal}.{" "}
                    <span className="text-muted-foreground">
                      Acabás de ir a buscarlo: dejá anotado en qué estante estaba.
                    </span>
                  </p>
                </div>

                <div className="flex flex-wrap items-center gap-2">
                  <SelectorModal
                    opciones={ubicacionesOpciones}
                    value={idUbicacionAAsignar}
                    onChange={setIdUbicacionAAsignar}
                    placeholder="Elegí la ubicación"
                    titulo={`Ubicación en ${nombreSucursal}`}
                    buscarPlaceholder="Buscar zona, estante o nivel…"
                    vacioTexto="Esta sucursal todavía no tiene ubicaciones cargadas."
                    cargando={cargandoUbicaciones}
                    className="min-w-0 flex-1"
                    alta={altaUbicacion}
                  />
                  <Button
                    type="button"
                    // type="button" NO es decorativo: mismo motivo que en los
                    // otros dos "Asignar".
                    onClick={() => asignarUbicacion.mutate(Number(idUbicacionAAsignar))}
                    disabled={idUbicacionAAsignar === "" || asignarUbicacion.isPending}
                  >
                    {asignarUbicacion.isPending && <Loader2 className="size-4 animate-spin" />}
                    Asignar
                  </Button>
                </div>

                <p className="text-xs text-muted-foreground">
                  Se guarda en el artículo, no en este conteo, y se aplica al tocar "Asignar". Un
                  artículo puede estar en varios estantes: esto agrega uno, no reemplaza.
                </p>
              </div>
            )}

            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="fechaInventario"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Fecha y hora del conteo</FormLabel>
                    <FormControl>
                      {/* step="1" es lo que hace que el campo acepte SEGUNDOS:
                          sin él el navegador redondea a minutos y descarta lo
                          que venga después, incluso lo que ya estaba guardado. */}
                      <Input
                        type="datetime-local"
                        step="1"
                        {...field}
                        disabled={soloLectura || esperandoDetalle}
                      />
                    </FormControl>
                    <FormDescription>
                      Cuándo se contó en el depósito, no cuándo se carga acá.
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="cantidadFisica"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Cantidad contada</FormLabel>
                    <FormControl>
                      {/* inputMode decimal abre el teclado numérico en móvil sin
                          las flechas de un type="number". */}
                      <Input
                        {...field}
                        inputMode="decimal"
                        placeholder="Sin contar"
                        autoComplete="off"
                        className="tabular-nums"
                        disabled={soloLectura || esperandoDetalle}
                      />
                    </FormControl>
                    <FormDescription>Vacío = todavía no se contó.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            {/* La comparación va FUERA de los campos y no como descripción de
                uno: no pertenece a ninguno, sale de los dos. Un hijo de ui/form
                acá tiraría abajo la página, porque useFormField() lanza sin su
                <FormItem>. */}
            {idArticuloElegido > 0 && (
              <div className="grid grid-cols-3 gap-3 rounded-lg border border-border p-3">
                <div>
                  <p className="text-xs text-muted-foreground">El sistema dice</p>
                  <p className="mt-1 font-display text-lg font-bold tabular-nums text-foreground">
                    {formatearMoneda(sistema)}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-muted-foreground">Contaste</p>
                  <p className="mt-1 font-display text-lg font-bold tabular-nums text-foreground">
                    {contado === null || Number.isNaN(contado) ? "—" : formatearMoneda(contado)}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-muted-foreground">Diferencia</p>
                  <p
                    className={`mt-1 font-display text-lg font-bold tabular-nums ${
                      diferencia !== null && diferencia < 0 ? "text-destructive" : "text-foreground"
                    }`}
                  >
                    {diferencia === null
                      ? "—"
                      : `${diferencia > 0 ? "+" : ""}${formatearMoneda(diferencia)}`}
                  </p>
                </div>
              </div>
            )}

            <FormField
              control={form.control}
              name="observaciones"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Observaciones</FormLabel>
                  <FormControl>
                    <Textarea
                      {...field}
                      rows={3}
                      placeholder="Por qué difiere, quién acompañó el conteo, en qué estante…"
                      disabled={soloLectura || esperandoDetalle}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            {soloLectura && inventario && (
              <div className="space-y-1 rounded-lg border border-border p-3 text-sm">
                <Label className="text-xs text-muted-foreground">Cómo terminó</Label>
                <p className="text-foreground">
                  {inventario.estado === "CERRADO"
                    ? `Se aplicó: la existencia pasó de ${formatearMoneda(
                        inventario.cantidadSistema ?? 0,
                      )} a ${formatearMoneda(inventario.cantidadFisica ?? 0)}.`
                    : "Se descartó sin tocar el stock."}{" "}
                  {inventario.usuario ? `Cargado por ${inventario.usuario}.` : ""}
                </p>
                {/* Acá SÍ van los segundos: se está mirando una fila sola, y es
                    el dato que distingue dos conteos del mismo día. */}
                <p className="text-xs text-muted-foreground">
                  Contado el {formatearFecha(inventario.fechaInventario, true)} · Aplicado el{" "}
                  {formatearFecha(inventario.fechaActualizacion, true)}
                </p>
              </div>
            )}

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onCerrar}>
                {soloLectura ? "Cerrar" : "Cancelar"}
              </Button>
              {!soloLectura && (
                <Button type="submit" disabled={guardar.isPending || esperandoDetalle}>
                  {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                  {editando ? "Guardar" : "Cargar conteo"}
                </Button>
              )}
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}
