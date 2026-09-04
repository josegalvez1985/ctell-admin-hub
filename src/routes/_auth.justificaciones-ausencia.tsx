import { zodResolver } from "@hookform/resolvers/zod";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import {
  ClipboardCheck,
  ExternalLink,
  Loader2,
  Paperclip,
  Search,
  TriangleAlert,
} from "lucide-react";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { SelectorModal } from "@/components/ctell/SelectorModal";
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
import {
  api,
  ApiError,
  esActivo,
  ESTADOS_JUSTIFICACION,
  type EstadoJustificacion,
  type JustificacionAusencia,
} from "@/lib/api";
import { tituloPagina } from "@/lib/marca";

/**
 * Bandeja de justificaciones de ausencia.
 *
 * **Acá no se da de alta ni se borra, y no es un olvido.** La solicitud la carga
 * el profesor desde su app; esta pantalla la resuelve: estado, suplente y
 * observaciones. Todo lo demás es de lectura. Ver la cabecera de
 * `db/justificaciones-ausencia.sql`.
 */

/** Cuántas filas trae cada página, y cuántas suma cada "Mostrar más". */
const POR_PAGINA = 20;

/** Lo que se espera entre teclas antes de mandar la búsqueda al servidor. */
const ESPERA_BUSQUEDA_MS = 350;

/** Valor de "sin filtro" de los selectores. La opción va ADENTRO del selector. */
const TODOS = "todos";

/** Los topes que valida el backend, para avisar antes de mandar. */
const MAX_SUPLENTE = 200;
const MAX_OBSERVACIONES = 1000;

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

const ETIQUETA_ESTADO: Record<EstadoJustificacion, string> = {
  PENDIENTE: "Pendiente",
  "EN REVISION": "En revisión",
  APROBADA: "Aprobada",
  RECHAZADA: "Rechazada",
};

/**
 * Una fecha `YYYY-MM-DD` a `DD/MM/AAAA`, **sin pasar por `new Date`**.
 *
 * `new Date("2026-09-04")` es medianoche UTC, y en Asunción (UTC-3) eso es el
 * 3 de septiembre a las 21:00: la fecha se muestra un día antes. Con hora
 * —`fechaEnvio`— no pasa, porque un ISO sin zona se parsea como local.
 */
function formatearFecha(iso: string | null): string {
  if (!iso) return "—";
  const [anio, mes, dia] = iso.slice(0, 10).split("-");
  return `${dia}/${mes}/${anio}`;
}

function formatearFechaHora(iso: string | null): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("es-PY", { dateStyle: "short", timeStyle: "short" });
}

/** El período de la ausencia en una línea. `fechaFin` en null es un solo día. */
function rangoAusencia(j: JustificacionAusencia): string {
  if (!j.fechaFin || j.fechaFin === j.fechaInicio) return formatearFecha(j.fechaInicio);
  return `${formatearFecha(j.fechaInicio)} — ${formatearFecha(j.fechaFin)}`;
}

function JustificacionesAusenciaPage() {
  const { empresa } = useEmpresa();

  const [gestionando, setGestionando] = useState<JustificacionAusencia | null>(null);

  // Dos estados para la búsqueda: `busqueda` es lo que se ve en el input
  // (inmediato, sin lag al tipear) y `busquedaEnvio` lo que entra en la
  // queryKey, para no disparar una consulta por tecla.
  const [busqueda, setBusqueda] = useState("");
  const [busquedaEnvio, setBusquedaEnvio] = useState("");

  useEffect(() => {
    const id = setTimeout(() => setBusquedaEnvio(busqueda), ESPERA_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  /**
   * TODOS los filtros van al servidor, no en memoria.
   *
   * El listado está paginado: filtrar en el cliente sólo miraría las páginas ya
   * traídas, y el resultado dependería de cuántas veces se tocó "Mostrar más".
   * Por eso tampoco hay orden por columna acá — ordenaría media lista.
   */
  const [filtroEstado, setFiltroEstado] = useState(TODOS);
  const [filtroProfesor, setFiltroProfesor] = useState(TODOS);
  const [filtroInstitucion, setFiltroInstitucion] = useState(TODOS);
  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");

  // Los catálogos alimentan los dos selectores. Sólo los activos: filtrar por un
  // profesor dado de baja es pedir una lista que no se va a volver a mover.
  const { data: profesoresData, isPending: cargandoProfesores } = useQuery({
    queryKey: ["profesores", empresa?.id ?? null],
    queryFn: () => api.profesores.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });
  const profesores = (profesoresData?.items ?? []).filter((p) => esActivo(p.activo));

  const { data: institucionesData, isPending: cargandoInstituciones } = useQuery({
    queryKey: ["instituciones", empresa?.id ?? null],
    queryFn: () => api.instituciones.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });
  const instituciones = (institucionesData?.items ?? []).filter((i) => esActivo(i.activo));

  // La empresa y CADA filtro entran en la queryKey: al cambiar cualquiera,
  // TanStack Query trata el listado como otra consulta en vez de servir en
  // caché el de la anterior.
  //
  // `enabled` evita pedir sin empresa. En el primer render todavía es null —el
  // provider hidrata desde localStorage después de montar— y sin esto la
  // petición saldría sin idEmpresa, que acá además es un 400 del backend.
  const { data, isPending, isError, error, fetchNextPage, hasNextPage, isFetchingNextPage } =
    useInfiniteQuery({
      queryKey: [
        "justificaciones-ausencia",
        empresa?.id ?? null,
        filtroEstado,
        filtroProfesor,
        filtroInstitucion,
        desde,
        hasta,
        busquedaEnvio.trim(),
      ],
      queryFn: ({ pageParam }) =>
        api.justificacionesAusencia.listar({
          idEmpresa: empresa!.id,
          estado: filtroEstado === TODOS ? undefined : (filtroEstado as EstadoJustificacion),
          idProfesor: filtroProfesor === TODOS ? undefined : Number(filtroProfesor),
          idInstitucion: filtroInstitucion === TODOS ? undefined : Number(filtroInstitucion),
          desde: desde || undefined,
          hasta: hasta || undefined,
          busqueda: busquedaEnvio,
          pagina: pageParam,
          tamanio: POR_PAGINA,
        }),
      enabled: empresa !== null,
      initialPageParam: 1,
      getNextPageParam: (ultima, paginas) => {
        const traidos = paginas.reduce((suma, p) => suma + p.items.length, 0);
        return traidos < ultima.total ? paginas.length + 1 : undefined;
      },
    });

  /**
   * Cuántas quedan sin resolver, **en toda la empresa y sin los filtros de la
   * pantalla**.
   *
   * Es una consulta aparte y no una cuenta sobre las filas cargadas: con el
   * listado paginado y filtrado, contar lo que está en pantalla daría "3
   * pendientes" cuando hay treinta. Pide una sola fila y usa el `total`.
   */
  const { data: pendientes } = useQuery({
    queryKey: ["justificaciones-ausencia", "pendientes", empresa?.id ?? null],
    queryFn: () =>
      api.justificacionesAusencia.listar({
        idEmpresa: empresa!.id,
        estado: "PENDIENTE",
        tamanio: 1,
      }),
    enabled: empresa !== null,
  });
  const cantidadPendientes = pendientes?.total ?? 0;

  const filas = data?.pages.flatMap((p) => p.items) ?? [];
  const total = data?.pages[0]?.total ?? 0;

  const termino = busquedaEnvio.trim();
  const hayFiltros =
    termino !== "" ||
    filtroEstado !== TODOS ||
    filtroProfesor !== TODOS ||
    filtroInstitucion !== TODOS ||
    desde !== "" ||
    hasta !== "";

  function limpiarFiltros() {
    setBusqueda("");
    setBusquedaEnvio("");
    setFiltroEstado(TODOS);
    setFiltroProfesor(TODOS);
    setFiltroInstitucion(TODOS);
    setDesde("");
    setHasta("");
  }

  // La opción "todas" va ADENTRO del selector, no como un botón al lado: es un
  // valor más de la misma lista y así se limpia donde se eligió.
  const opcionesEstado = [
    { valor: TODOS, etiqueta: "Todos los estados" },
    ...ESTADOS_JUSTIFICACION.map((e) => ({ valor: e, etiqueta: ETIQUETA_ESTADO[e] })),
  ];

  const opcionesProfesor = [
    { valor: TODOS, etiqueta: "Todos los profesores" },
    ...profesores
      .map((p) => ({
        valor: String(p.id),
        etiqueta: `${p.apellido}, ${p.nombre}`,
        descripcion: p.numeroCi,
      }))
      .sort((a, b) => a.etiqueta.localeCompare(b.etiqueta, "es")),
  ];

  const opcionesInstitucion = [
    { valor: TODOS, etiqueta: "Todas las instituciones" },
    ...instituciones
      .map((i) => ({
        valor: String(i.id),
        etiqueta: i.nombreInstitucion,
        ...(i.ciudad ? { descripcion: i.ciudad } : {}),
      }))
      .sort((a, b) => a.etiqueta.localeCompare(b.etiqueta, "es")),
  ];

  return (
    <AppLayout active="/justificaciones-ausencia" title="Justificaciones">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div>
          <h1 className="text-2xl font-bold text-foreground sm:text-3xl">
            Justificaciones de ausencia
          </h1>
          <p className="mt-1 text-sm text-muted-foreground">
            {empresa
              ? `Solicitudes que mandaron los profesores de ${empresa.nombreEmpresa}.`
              : "Solicitudes que mandaron los profesores."}
          </p>
        </div>

        {/* Las pendientes primero: es lo que se viene a hacer a esta pantalla.
            El botón deja el filtro puesto en vez de sólo informar. */}
        {cantidadPendientes > 0 && (
          <div className="flex flex-wrap items-center gap-3 rounded-lg border border-warning/30 bg-warning/10 px-3 py-2 text-sm text-foreground">
            <TriangleAlert className="size-4 shrink-0 text-warning" />
            <span className="flex-1">
              {cantidadPendientes === 1
                ? "Hay 1 solicitud pendiente de resolver."
                : `Hay ${cantidadPendientes} solicitudes pendientes de resolver.`}
            </span>
            {filtroEstado !== "PENDIENTE" && (
              <Button size="sm" variant="outline" onClick={() => setFiltroEstado("PENDIENTE")}>
                Ver pendientes
              </Button>
            )}
          </div>
        )}

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por profesor, institución, materia, curso o motivo…"
            className="pl-9"
          />
        </div>

        <div className="surface-card grid gap-3 p-3 sm:grid-cols-2 lg:grid-cols-5">
          <div className="space-y-1.5">
            <Label className="text-xs text-muted-foreground">Estado</Label>
            <SelectorModal
              opciones={opcionesEstado}
              value={filtroEstado}
              onChange={setFiltroEstado}
              titulo="Filtrar por estado"
              buscarPlaceholder="Buscar estado…"
            />
          </div>

          <div className="space-y-1.5">
            <Label className="text-xs text-muted-foreground">Profesor</Label>
            <SelectorModal
              opciones={opcionesProfesor}
              value={filtroProfesor}
              onChange={setFiltroProfesor}
              titulo="Filtrar por profesor"
              buscarPlaceholder="Buscar profesor…"
              cargando={cargandoProfesores}
            />
          </div>

          <div className="space-y-1.5">
            <Label className="text-xs text-muted-foreground">Institución</Label>
            <SelectorModal
              opciones={opcionesInstitucion}
              value={filtroInstitucion}
              onChange={setFiltroInstitucion}
              titulo="Filtrar por institución"
              buscarPlaceholder="Buscar institución…"
              cargando={cargandoInstituciones}
            />
          </div>

          {/* Solapamiento, no "empieza entre": una licencia del 29 de marzo al 4
              de abril sale en los dos meses. Lo resuelve el backend. */}
          <div className="space-y-1.5">
            <Label htmlFor="desde" className="text-xs text-muted-foreground">
              Ausencias desde
            </Label>
            <Input
              id="desde"
              type="date"
              value={desde}
              onChange={(e) => setDesde(e.target.value)}
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="hasta" className="text-xs text-muted-foreground">
              Hasta
            </Label>
            <Input
              id="hasta"
              type="date"
              value={hasta}
              onChange={(e) => setHasta(e.target.value)}
            />
          </div>

          {hayFiltros && (
            <div className="sm:col-span-2 lg:col-span-5">
              <Button variant="ghost" size="sm" onClick={limpiarFiltros}>
                Limpiar filtros
              </Button>
            </div>
          )}
        </div>

        {/* Sin empresa no hay nada que listar. Pasa si se entró con una sesión
            vieja, de antes de que el login pidiera elegirla. */}
        {empresa === null && !isPending && (
          <p className="rounded-lg border border-border px-3 py-6 text-center text-sm text-muted-foreground">
            No hay una empresa activa. Cerrá sesión y volvé a entrar eligiendo una.
          </p>
        )}

        {isPending && empresa !== null && (
          <div className="space-y-2">
            {[0, 1, 2, 3, 4].map((i) => (
              <Skeleton key={i} className="h-16 w-full" />
            ))}
          </div>
        )}

        {isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
            {MENSAJE_ERROR(error, "No se pudo cargar la lista")}
          </p>
        )}

        {!isPending && !isError && empresa !== null && filas.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {hayFiltros
                ? termino
                  ? `Sin resultados para "${termino}".`
                  : "Ninguna solicitud coincide con los filtros."
                : "Todavía no hay solicitudes de justificación."}
            </p>
            {/* Explica la ausencia del botón "Nueva": no falta, no va. */}
            {!hayFiltros && (
              <p className="mx-auto mt-2 max-w-md text-xs text-muted-foreground">
                Las cargan los profesores desde su app. Acá se reciben y se resuelven.
              </p>
            )}
          </div>
        )}

        {/* Móvil: tarjetas. Una tabla de 7 columnas en 360px obliga a scrollear
            de costado para leer una fila entera. */}
        {filas.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {filas.map((j) => (
              <li key={j.id} className="surface-card p-4">
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <p className="break-words font-semibold leading-snug text-foreground">
                      {j.profesor}
                    </p>
                    <p className="mt-0.5 break-words text-xs text-muted-foreground">
                      {j.institucion ?? "Institución eliminada"}
                      {j.materia ? ` · ${j.materia}` : ""}
                    </p>
                  </div>
                  <EstadoBadge estado={j.estado} />
                </div>

                <p className="mt-2 text-sm text-foreground">{rangoAusencia(j)}</p>
                <p className="text-xs text-muted-foreground">
                  {j.dias === 1 ? "1 día" : `${j.dias} días`}
                  {j.cantidadDeclarada ? ` · declaró ${j.cantidadDeclarada}` : ""}
                </p>

                {j.motivo && (
                  <p className="mt-2 break-words text-sm text-muted-foreground">
                    {j.motivo}
                    {j.motivoTruncado === "S" && "…"}
                  </p>
                )}

                <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-border pt-3">
                  <Adjunto justificacion={j} />
                  <Button size="sm" className="flex-1" onClick={() => setGestionando(j)}>
                    <ClipboardCheck className="size-4" />
                    Gestionar
                  </Button>
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
                  <TableHead>Profesor</TableHead>
                  <TableHead>Institución</TableHead>
                  <TableHead>Ausencia</TableHead>
                  <TableHead>Motivo</TableHead>
                  <TableHead>Estado</TableHead>
                  <TableHead>Enviada</TableHead>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {filas.map((j) => (
                  <TableRow key={j.id}>
                    <TableCell className="font-medium text-foreground">
                      <span className="block">{j.profesor}</span>
                      {j.materia && (
                        <span className="block text-xs font-normal text-muted-foreground">
                          {j.materia}
                        </span>
                      )}
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {j.institucion ?? "—"}
                      {j.cursos && (
                        <span className="block text-xs text-muted-foreground">{j.cursos}</span>
                      )}
                    </TableCell>
                    <TableCell className="whitespace-nowrap text-muted-foreground">
                      <span className="block text-foreground">{rangoAusencia(j)}</span>
                      <span className="block text-xs">
                        {j.dias === 1 ? "1 día" : `${j.dias} días`}
                        {j.cantidadDeclarada ? ` · ${j.cantidadDeclarada}` : ""}
                      </span>
                    </TableCell>
                    {/* Truncado en el SQL, no con CSS: el texto entero no viaja.
                        La ficha completa se lee en el diálogo. */}
                    <TableCell className="max-w-xs text-muted-foreground">
                      <span className="line-clamp-2">
                        {j.motivo ?? "—"}
                        {j.motivoTruncado === "S" && "…"}
                      </span>
                    </TableCell>
                    <TableCell>
                      <EstadoBadge estado={j.estado} />
                      {j.recibidoPor && (
                        <span className="mt-1 block text-xs text-muted-foreground">
                          {j.recibidoPor}
                        </span>
                      )}
                    </TableCell>
                    <TableCell className="whitespace-nowrap text-xs text-muted-foreground">
                      {formatearFechaHora(j.fechaEnvio)}
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex items-center justify-end gap-1">
                        <Adjunto justificacion={j} />
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setGestionando(j)}
                          aria-label={`Gestionar la solicitud de ${j.profesor}`}
                        >
                          <ClipboardCheck className="size-4" />
                          Gestionar
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}

        {hasNextPage && (
          <div className="flex justify-center">
            <Button variant="outline" onClick={() => fetchNextPage()} disabled={isFetchingNextPage}>
              {isFetchingNextPage && <Loader2 className="size-4 animate-spin" />}
              Mostrar más
            </Button>
          </div>
        )}

        {filas.length > 0 && (
          <p className="text-center text-xs text-muted-foreground">
            Mostrando {filas.length} de {total} solicitud{total === 1 ? "" : "es"}
          </p>
        )}

        {/* Sin empresa no se abre: la ficha y el guardado la necesitan. */}
        {empresa !== null && (
          <GestionDialog
            justificacion={gestionando}
            idEmpresa={empresa.id}
            onClose={() => setGestionando(null)}
          />
        )}
      </main>
    </AppLayout>
  );
}

/* -------------------------------------------------------------------------- */
/* Estado y adjunto                                                            */
/* -------------------------------------------------------------------------- */

/**
 * El estado, con color.
 *
 * **Tiene caso por defecto a propósito.** La columna no tiene `CHECK` y la
 * escribe otro programa: puede llegar un valor fuera de la lista, y ahí se
 * muestra tal cual en vez de quedar en blanco. Es el criterio de `PROCESADO` en
 * el reporte de inventarios — se ve, aunque no se pueda filtrar.
 */
function EstadoBadge({ estado }: { estado: EstadoJustificacion }) {
  if (estado === "APROBADA") {
    return <Badge className="bg-success/15 text-success hover:bg-success/15">Aprobada</Badge>;
  }
  if (estado === "RECHAZADA") {
    return (
      <Badge className="bg-destructive/15 text-destructive hover:bg-destructive/15">
        Rechazada
      </Badge>
    );
  }
  if (estado === "EN REVISION") return <Badge variant="secondary">En revisión</Badge>;
  if (estado === "PENDIENTE") {
    return <Badge className="bg-warning/15 text-warning hover:bg-warning/15">Pendiente</Badge>;
  }
  return (
    <Badge variant="outline" className="text-muted-foreground">
      {estado}
    </Badge>
  );
}

/**
 * El respaldo que adjuntó el profesor.
 *
 * Es un `<a>` a la URL, no un `fetch`: el navegador abre el certificado en su
 * visor, desde donde se imprime. `rel="noreferrer"` porque el destino es un
 * dominio ajeno (Cloudinary).
 *
 * **Tres estados, no dos.** Sin adjunto no se ofrece nada; con un adjunto que
 * el backend no devuelve —la URL no es `https://`— se avisa en vez de callar,
 * porque para quien resuelve la solicitud "no adjuntó" y "adjuntó algo roto"
 * son cosas distintas.
 */
function Adjunto({ justificacion }: { justificacion: JustificacionAusencia }) {
  if (justificacion.urlArchivo) {
    return (
      <Button asChild size="sm" variant="outline">
        <a href={justificacion.urlArchivo} target="_blank" rel="noreferrer">
          <Paperclip className="size-4" />
          Respaldo
          <ExternalLink className="size-3 opacity-60" />
        </a>
      </Button>
    );
  }
  if (justificacion.tieneArchivo === "S") {
    return (
      <span
        className="inline-flex items-center gap-1 rounded-full bg-warning/15 px-2 py-0.5 text-xs font-medium text-warning"
        title="El adjunto guardado no es un enlace https válido"
      >
        <TriangleAlert className="size-3" />
        Adjunto no válido
      </span>
    );
  }
  return null;
}

/* -------------------------------------------------------------------------- */
/* Gestión                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * La ficha completa y su resolución.
 *
 * **Carga con `obtener()`, nunca con la fila del listado**, y por eso el
 * formulario vive en un componente aparte que sólo se monta con la ficha ya
 * traída: en el listado el motivo y las observaciones vienen recortados a 200
 * caracteres, y guardar ese resumen escribiría 200 encima de los 1000. Que el
 * formulario no pueda ni ver la fila del listado es lo que garantiza que no
 * vuelva a pasar.
 */
function GestionDialog({
  justificacion,
  idEmpresa,
  onClose,
}: {
  justificacion: JustificacionAusencia | null;
  idEmpresa: number;
  onClose: () => void;
}) {
  const abierto = justificacion !== null;

  const {
    data: ficha,
    isPending,
    isError,
    error,
  } = useQuery({
    queryKey: ["justificaciones-ausencia", "ficha", justificacion?.id ?? null, idEmpresa],
    queryFn: () => api.justificacionesAusencia.obtener(justificacion!.id, idEmpresa),
    enabled: abierto,
  });

  return (
    <Dialog open={abierto} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="scrollbar-fino max-h-[92vh] max-w-[95vw] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle className="break-words">
            {justificacion ? `Solicitud de ${justificacion.profesor}` : "Solicitud"}
          </DialogTitle>
          <DialogDescription>
            Los datos de la ausencia los cargó el profesor y no se editan acá. Lo que se resuelve es
            el estado, el suplente y las observaciones.
          </DialogDescription>
        </DialogHeader>

        {isPending && abierto && (
          <div className="space-y-3">
            {[0, 1, 2, 3].map((i) => (
              <Skeleton key={i} className="h-12 w-full" />
            ))}
          </div>
        )}

        {isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
            {MENSAJE_ERROR(error, "No se pudo cargar la solicitud")}
          </p>
        )}

        {ficha && <GestionForm ficha={ficha} idEmpresa={idEmpresa} onClose={onClose} />}
      </DialogContent>
    </Dialog>
  );
}

/**
 * El estado se valida contra la lista, no como texto libre: es lo mismo que
 * hace `ESTADO_VALIDO` en `db/justificaciones-ausencia.sql`.
 *
 * Los `max` repiten los topes de las columnas para avisar en el formulario. El
 * backend los valida igual: esto evita el viaje, no lo reemplaza.
 */
const schema = z.object({
  estado: z.enum(ESTADOS_JUSTIFICACION, {
    errorMap: () => ({ message: "Elegí un estado" }),
  }),
  suplenteAsignado: z.string().max(MAX_SUPLENTE, `Máximo ${MAX_SUPLENTE} caracteres`),
  observaciones: z.string().max(MAX_OBSERVACIONES, `Máximo ${MAX_OBSERVACIONES} caracteres`),
});

type FormValues = z.infer<typeof schema>;

function GestionForm({
  ficha,
  idEmpresa,
  onClose,
}: {
  ficha: JustificacionAusencia;
  idEmpresa: number;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();

  const form = useForm<FormValues>({
    values: {
      estado: ficha.estado,
      suplenteAsignado: ficha.suplente ?? "",
      observaciones: ficha.observaciones ?? "",
    },
    resolver: zodResolver(schema),
  });

  const guardar = useMutation({
    // Las tres claves van siempre, incluso vacías: una omitida deja el bind sin
    // definir en vez de en NULL, y el backend responde 400. Vacío BORRA, que es
    // la única forma de sacar un suplente cargado por error.
    mutationFn: (v: FormValues) =>
      api.justificacionesAusencia.actualizar(ficha.id, {
        idEmpresa,
        estado: v.estado,
        suplenteAsignado: v.suplenteAsignado,
        observaciones: v.observaciones,
      }),
    onSuccess: () => {
      // Invalida la bandeja Y el contador de pendientes: los dos cuelgan de la
      // misma clave, y resolver una solicitud cambia los dos números.
      queryClient.invalidateQueries({ queryKey: ["justificaciones-ausencia"] });
      toast.success("Solicitud actualizada");
      onClose();
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo actualizar la solicitud")),
  });

  return (
    <div className="space-y-5">
      {/* Lo que cargó el profesor: se lee, no se toca. */}
      <dl className="grid gap-x-4 gap-y-3 rounded-lg border border-border p-3 text-sm sm:grid-cols-2">
        <Dato titulo="Institución" valor={ficha.institucion ?? "Institución eliminada"} />
        <Dato titulo="Materia o área" valor={ficha.materia} />
        <Dato titulo="Ausencia" valor={rangoAusencia(ficha)} />
        <Dato
          titulo="Duración"
          valor={`${ficha.dias === 1 ? "1 día" : `${ficha.dias} días`}${
            ficha.cantidadDeclarada ? ` · declaró ${ficha.cantidadDeclarada}` : ""
          }`}
        />
        <Dato titulo="Turno u horario" valor={ficha.turno} />
        <Dato titulo="Cursos o grupos" valor={ficha.cursos} />
        <div className="sm:col-span-2">
          <dt className="text-xs text-muted-foreground">Motivo</dt>
          <dd className="mt-0.5 whitespace-pre-wrap break-words text-foreground">
            {ficha.motivo ?? "—"}
          </dd>
        </div>
        <div className="sm:col-span-2 flex flex-wrap items-center gap-3">
          <Adjunto justificacion={ficha} />
          <span className="text-xs text-muted-foreground">
            Enviada el {formatearFechaHora(ficha.fechaEnvio)}
          </span>
        </div>
      </dl>

      {/* Quién la recibió no es un campo: lo sella el backend con el usuario de
          la sesión la primera vez que se guarda, y no se vuelve a pisar. Se
          muestra para que se vea que quedó registrado. */}
      {ficha.recibidoPor && (
        <p className="text-xs text-muted-foreground">
          Recibida por {ficha.recibidoPor}
          {ficha.fechaRecepcion ? ` el ${formatearFecha(ficha.fechaRecepcion)}` : ""}.
        </p>
      )}

      <Form {...form}>
        <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
          <FormField
            control={form.control}
            name="estado"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Estado</FormLabel>
                <FormControl>
                  <SelectorModal
                    opciones={ESTADOS_JUSTIFICACION.map((e) => ({
                      valor: e,
                      etiqueta: ETIQUETA_ESTADO[e],
                    }))}
                    value={field.value}
                    onChange={(v) => field.onChange(v as EstadoJustificacion)}
                    placeholder="Elegí un estado"
                    titulo="Estado de la solicitud"
                    buscarPlaceholder="Buscar estado…"
                  />
                </FormControl>
                <FormDescription>
                  Se puede volver a cambiar: un rechazo cargado por error se corrige.
                </FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          <FormField
            control={form.control}
            name="suplenteAsignado"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Suplente asignado</FormLabel>
                <FormControl>
                  <Input {...field} placeholder="Nombre de quien cubre las clases" />
                </FormControl>
                <FormDescription>Opcional. Vacío lo borra.</FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          <FormField
            control={form.control}
            name="observaciones"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Observaciones</FormLabel>
                <FormControl>
                  <Textarea {...field} rows={4} placeholder="Lo que haya que dejar anotado…" />
                </FormControl>
                <FormDescription>
                  Las lee el profesor desde su app. Máximo {MAX_OBSERVACIONES} caracteres.
                </FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          <DialogFooter className="gap-2">
            <Button
              type="submit"
              disabled={guardar.isPending}
              className="h-11 w-full sm:h-10 sm:w-auto"
            >
              {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
              {guardar.isPending ? "Guardando…" : "Guardar"}
            </Button>
            <Button
              type="button"
              variant="outline"
              onClick={onClose}
              className="h-11 w-full sm:h-10 sm:w-auto"
            >
              Cancelar
            </Button>
          </DialogFooter>
        </form>
      </Form>
    </div>
  );
}

/** Un dato de la ficha. `—` cuando está vacío: el hueco también informa. */
function Dato({ titulo, valor }: { titulo: string; valor: string | null }) {
  return (
    <div>
      <dt className="text-xs text-muted-foreground">{titulo}</dt>
      <dd className="mt-0.5 break-words text-foreground">{valor ?? "—"}</dd>
    </div>
  );
}

export const Route = createFileRoute("/_auth/justificaciones-ausencia")({
  head: () => ({
    meta: [
      { title: tituloPagina("Justificaciones de ausencia") },
      {
        name: "description",
        content: "Solicitudes de justificación de ausencia de profesores: recepción y resolución.",
      },
    ],
  }),
  component: JustificacionesAusenciaPage,
});
