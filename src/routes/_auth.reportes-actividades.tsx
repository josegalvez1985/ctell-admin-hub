import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  CalendarDays,
  ChevronLeft,
  ChevronRight,
  FileText,
  ImageIcon,
  Loader2,
  NotebookPen,
  Paperclip,
  PenLine,
  Play,
  Plus,
  Search,
  Trash2,
  Upload,
  X,
} from "lucide-react";
import { useMemo, useRef, useState } from "react";
import { toast } from "sonner";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import {
  api,
  ApiError,
  MAX_DESCRIPCION_REPORTE,
  MAX_PIE_MULTIMEDIA,
  type AsistenciaSinReporte,
  type ReporteActividad,
  type ReporteMultimedia,
} from "@/lib/api";
import {
  miniatura,
  pesoLegible,
  subidaDirectaDisponible,
  subirACloudinary,
  type TipoArchivo,
} from "@/lib/cloudinary";
import { tituloPagina } from "@/lib/marca";
import { cn } from "@/lib/utils";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
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
import { Textarea } from "@/components/ui/textarea";

export const Route = createFileRoute("/_auth/reportes-actividades")({
  head: () => ({ meta: [{ title: tituloPagina("Reportes de actividades") }] }),
  component: ReportesActividadesPage,
});

const TODOS = "todos";

/**
 * De a 20 y no de a 200 aunque el backend lo acepte: cada reporte lleva texto
 * libre y una página grande revienta el bind de ORDS con un 500 mudo. Ver
 * GUIA-IMPLEMENTACION, "los tres pisos del mismo 4000".
 */
const POR_PAGINA = 20;
const MAX_PAGINAS = 40;

const mensajeError = (error: unknown, respaldo: string) =>
  error instanceof ApiError ? error.message : error instanceof Error ? error.message : respaldo;

/* -------------------------------------------------------------------------- */
/*  Fechas                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * `YYYY-MM-DD` a `Date` **local**.
 *
 * `new Date("2026-09-02")` lo interpreta como UTC y en Paraguay (UTC-3) muestra
 * el 1: la hora agregada lo ancla al día correcto.
 */
const fechaLocal = (iso: string) => new Date(`${iso}T00:00:00`);

const formatoDia = new Intl.DateTimeFormat("es-PY", {
  weekday: "long",
  day: "numeric",
  month: "long",
});

const formatoMes = new Intl.DateTimeFormat("es-PY", { month: "long", year: "numeric" });

const capitalizar = (texto: string) => texto.charAt(0).toLocaleUpperCase("es-PY") + texto.slice(1);

const iso = (anio: number, mes: number, dia: number) =>
  `${anio}-${String(mes).padStart(2, "0")}-${String(dia).padStart(2, "0")}`;

/** Último día del mes: el día 0 del siguiente. */
const ultimoDia = (anio: number, mes: number) => new Date(anio, mes, 0).getDate();

const iniciales = (nombre: string) =>
  nombre
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((parte) => parte.charAt(0).toLocaleUpperCase("es-PY"))
    .join("");

/* -------------------------------------------------------------------------- */
/*  Carga                                                                      */
/* -------------------------------------------------------------------------- */

type Filtros = {
  idEmpresa: number;
  desde: string;
  hasta: string;
  idProfesor?: number | undefined;
  idInstitucion?: number | undefined;
};

/**
 * Todos los reportes del período, paginando.
 *
 * La línea de tiempo mezcla reportes con marcaciones pendientes y las agrupa por
 * día: con paginado incremental, el día 3 podría aparecer, desaparecer y volver
 * según cuánto se haya cargado de cada lista. Un mes tiene un volumen acotado,
 * así que se trae entero y se ordena una sola vez.
 */
async function traerReportes(filtros: Filtros, busqueda: string): Promise<ReporteActividad[]> {
  const todos: ReporteActividad[] = [];

  for (let pagina = 1; pagina <= MAX_PAGINAS; pagina++) {
    const respuesta = await api.reportesActividades.listar({
      ...filtros,
      ...(busqueda ? { busqueda } : {}),
      pagina,
      tamanio: POR_PAGINA,
    });
    todos.push(...respuesta.items);

    // Dos cortes: el total del backend y una página incompleta. El segundo cubre
    // el caso de un `total` mal calculado, que si no daría vueltas hasta el tope.
    if (todos.length >= respuesta.total || respuesta.items.length < POR_PAGINA) break;
  }

  return todos;
}

async function traerPendientes(filtros: Filtros): Promise<AsistenciaSinReporte[]> {
  const todos: AsistenciaSinReporte[] = [];

  for (let pagina = 1; pagina <= MAX_PAGINAS; pagina++) {
    const respuesta = await api.reportesActividades.pendientes({
      ...filtros,
      pagina,
      tamanio: POR_PAGINA,
    });
    todos.push(...respuesta.items);
    if (todos.length >= respuesta.total || respuesta.items.length < POR_PAGINA) break;
  }

  return todos;
}

/** Una entrada de la línea de tiempo: lo reportado y lo que falta reportar. */
type Entrada =
  | { clase: "reporte"; fecha: string; reporte: ReporteActividad }
  | { clase: "pendiente"; fecha: string; asistencia: AsistenciaSinReporte };

/* -------------------------------------------------------------------------- */
/*  Pantalla                                                                   */
/* -------------------------------------------------------------------------- */

function ReportesActividadesPage() {
  const { empresa } = useEmpresa();
  const queryClient = useQueryClient();
  const hoy = new Date();

  const [anio, setAnio] = useState(hoy.getFullYear());
  const [mes, setMes] = useState(hoy.getMonth() + 1);
  const [profesorFiltro, setProfesorFiltro] = useState(TODOS);
  const [institucionFiltro, setInstitucionFiltro] = useState(TODOS);
  const [busqueda, setBusqueda] = useState("");

  const [fichaAbierta, setFichaAbierta] = useState<number | null>(null);
  const [escribiendo, setEscribiendo] = useState<AsistenciaSinReporte | null>(null);
  const [aEliminar, setAEliminar] = useState<ReporteActividad | null>(null);

  const desde = iso(anio, mes, 1);
  const hasta = iso(anio, mes, ultimoDia(anio, mes));

  const filtros: Filtros = {
    idEmpresa: empresa?.id ?? 0,
    desde,
    hasta,
    ...(profesorFiltro !== TODOS ? { idProfesor: Number(profesorFiltro) } : {}),
    ...(institucionFiltro !== TODOS ? { idInstitucion: Number(institucionFiltro) } : {}),
  };
  const clavePeriodo = [empresa?.id ?? null, desde, hasta, profesorFiltro, institucionFiltro];

  const reportes = useQuery({
    queryKey: ["reportes-actividades", ...clavePeriodo, busqueda],
    queryFn: () => traerReportes(filtros, busqueda),
    enabled: empresa !== null,
  });

  const pendientes = useQuery({
    queryKey: ["reportes-actividades", "pendientes", ...clavePeriodo],
    queryFn: () => traerPendientes(filtros),
    enabled: empresa !== null,
  });

  const profesores = useQuery({
    queryKey: ["profesores", empresa?.id ?? null],
    queryFn: () => api.profesores.listar({ idEmpresa: empresa!.id, activo: "A" }),
    enabled: empresa !== null,
  });

  const instituciones = useQuery({
    queryKey: ["instituciones", empresa?.id ?? null],
    queryFn: () => api.instituciones.listar({ idEmpresa: empresa!.id, activo: "A" }),
    enabled: empresa !== null,
  });

  /**
   * Qué profesor estuvo en qué institución este mes.
   *
   * **No depende de los filtros**, sólo del período: si dependiera del profesor
   * elegido, el combo se quedaría con la única opción ya seleccionada y no
   * habría forma de volver atrás.
   */
  const vinculos = useQuery({
    queryKey: ["reportes-actividades", "vinculos", empresa?.id ?? null, desde, hasta],
    queryFn: () => api.reportesActividades.vinculos({ idEmpresa: empresa!.id, desde, hasta }),
    enabled: empresa !== null,
  });

  /**
   * Las instituciones que ofrece el combo.
   *
   * Con un profesor elegido, sólo donde marcó: en una empresa con veinte
   * colegios, diecinueve de esas opciones devuelven la pantalla vacía. Es el
   * mismo criterio del selector de ubicaciones de Artículos, que ofrece sólo
   * estantes con artículos.
   */
  const institucionesOfrecidas = useMemo(() => {
    const todas = instituciones.data?.items ?? [];
    if (profesorFiltro === TODOS) return todas;

    const suyas = new Set(
      (vinculos.data?.items ?? [])
        .filter((v) => String(v.idProfesor) === profesorFiltro)
        .map((v) => v.idInstitucion),
    );
    return todas.filter((i) => suyas.has(i.id));
  }, [instituciones.data, vinculos.data, profesorFiltro]);

  /**
   * Al cambiar de profesor, la institución elegida puede no ser suya.
   *
   * Se limpia en vez de dejarla: un filtro que ya no figura en su propio combo
   * es invisible, y la pantalla quedaría vacía sin que se vea por qué.
   */
  const elegirProfesor = (valor: string) => {
    setProfesorFiltro(valor);
    if (institucionFiltro === TODOS || valor === TODOS) return;

    const sigueSiendoSuya = (vinculos.data?.items ?? []).some(
      (v) => String(v.idProfesor) === valor && String(v.idInstitucion) === institucionFiltro,
    );
    if (!sigueSiendoSuya) setInstitucionFiltro(TODOS);
  };

  const invalidar = () => {
    void queryClient.invalidateQueries({ queryKey: ["reportes-actividades"] });
  };

  const eliminar = useMutation({
    mutationFn: (reporte: ReporteActividad) =>
      api.reportesActividades.eliminar(reporte.id, empresa!.id),
    onSuccess: (respuesta) => {
      invalidar();
      setAEliminar(null);
      toast.success(
        respuesta.archivosEliminados > 0
          ? `Reporte eliminado junto con ${respuesta.archivosEliminados} evidencia${respuesta.archivosEliminados === 1 ? "" : "s"}`
          : "Reporte eliminado",
      );
    },
    onError: (error) => toast.error(mensajeError(error, "No se pudo eliminar el reporte")),
  });

  /**
   * La búsqueda de los reportes la resuelve el SQL, pero los pendientes no
   * tienen texto que buscar: se filtran acá por profesor e institución para que
   * escribir en el buscador no deje la línea de tiempo a medias.
   */
  const pendientesVisibles = useMemo(() => {
    const items = pendientes.data ?? [];
    const texto = busqueda.trim().toLocaleLowerCase("es-PY");
    if (!texto) return items;
    return items.filter((a) =>
      `${a.profesor} ${a.institucion ?? ""}`.toLocaleLowerCase("es-PY").includes(texto),
    );
  }, [pendientes.data, busqueda]);

  /**
   * Un solo hilo cronológico con las dos listas.
   *
   * Dentro del día, primero lo reportado y después lo pendiente: el hueco queda
   * al pie del día al que le falta, que es donde se lo busca.
   */
  const dias = useMemo(() => {
    const entradas: Entrada[] = [
      ...(reportes.data ?? []).map((reporte): Entrada => ({
        clase: "reporte",
        fecha: reporte.fecha,
        reporte,
      })),
      ...pendientesVisibles.map((asistencia): Entrada => ({
        clase: "pendiente",
        fecha: asistencia.fecha,
        asistencia,
      })),
    ];

    const porDia = new Map<string, Entrada[]>();
    for (const entrada of entradas) {
      const delDia = porDia.get(entrada.fecha);
      if (delDia) delDia.push(entrada);
      else porDia.set(entrada.fecha, [entrada]);
    }

    return [...porDia.entries()]
      .sort((a, b) => b[0].localeCompare(a[0]))
      .map(([fecha, items]) => ({
        fecha,
        items: items.sort((a, b) => (a.clase === b.clase ? 0 : a.clase === "reporte" ? -1 : 1)),
      }));
  }, [reportes.data, pendientesVisibles]);

  const totalEvidencias = (reportes.data ?? []).reduce((suma, r) => suma + r.cantidadMultimedia, 0);
  const cargando = reportes.isPending || pendientes.isPending;
  const esMesActual = anio === hoy.getFullYear() && mes === hoy.getMonth() + 1;

  const moverMes = (pasos: number) => {
    const referencia = new Date(anio, mes - 1 + pasos, 1);
    setAnio(referencia.getFullYear());
    setMes(referencia.getMonth() + 1);
  };

  return (
    <AppLayout active="/reportes-actividades" title="Reportes de actividades">
      <main className="mx-auto w-full max-w-4xl space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <header className="space-y-4">
          <div>
            <p className="text-sm font-medium uppercase tracking-[0.12em] text-primary">
              Bitácora de clases
            </p>
            <h1 className="mt-1 text-2xl font-bold text-foreground sm:text-3xl">
              Reportes de actividades
            </h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Qué se hizo en cada clase, con sus fotos. Cada reporte cuelga de una marcación.
            </p>
          </div>

          {/* Navegación por mes: es como se piensa este dato —"lo de agosto"— y
              evita dos selectores de fecha para el 95% de los casos. */}
          <div className="flex flex-wrap items-center gap-2">
            <div className="flex items-center gap-1 rounded-lg border border-border bg-card p-1">
              <Button
                variant="ghost"
                size="icon"
                aria-label="Mes anterior"
                onClick={() => moverMes(-1)}
              >
                <ChevronLeft className="size-4" />
              </Button>
              <span className="min-w-40 text-center text-sm font-semibold">
                {capitalizar(formatoMes.format(new Date(anio, mes - 1, 1)))}
              </span>
              <Button
                variant="ghost"
                size="icon"
                aria-label="Mes siguiente"
                onClick={() => moverMes(1)}
              >
                <ChevronRight className="size-4" />
              </Button>
            </div>
            {!esMesActual && (
              <Button
                variant="ghost"
                size="sm"
                onClick={() => {
                  setAnio(hoy.getFullYear());
                  setMes(hoy.getMonth() + 1);
                }}
              >
                <CalendarDays className="size-4" /> Este mes
              </Button>
            )}
          </div>

          {/* Los tres números del mes. El de pendientes es el que importa: dice
              cuánto trabajo queda, y por eso se pinta distinto. */}
          <div className="flex flex-wrap items-center gap-2 text-sm">
            <Badge variant="secondary" className="gap-1.5 py-1">
              <NotebookPen className="size-3.5" />
              {(reportes.data ?? []).length} reporte
              {(reportes.data ?? []).length === 1 ? "" : "s"}
            </Badge>
            <Badge
              variant={pendientesVisibles.length > 0 ? "destructive" : "secondary"}
              className="gap-1.5 py-1"
            >
              <PenLine className="size-3.5" />
              {pendientesVisibles.length} sin reporte
            </Badge>
            <Badge variant="secondary" className="gap-1.5 py-1">
              <Paperclip className="size-3.5" />
              {totalEvidencias} evidencia{totalEvidencias === 1 ? "" : "s"}
            </Badge>
          </div>
        </header>

        <section className="grid gap-3 rounded-xl border border-border bg-card p-4 shadow-sm sm:grid-cols-3">
          <div>
            <Label>Profesor</Label>
            <Select value={profesorFiltro} onValueChange={elegirProfesor}>
              <SelectTrigger>
                <SelectValue placeholder="Todos" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={TODOS}>Todos</SelectItem>
                {(profesores.data?.items ?? []).map((p) => (
                  <SelectItem key={p.id} value={String(p.id)}>
                    {p.nombre} {p.apellido}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div>
            <Label>Institución</Label>
            <Select value={institucionFiltro} onValueChange={setInstitucionFiltro}>
              <SelectTrigger>
                <SelectValue placeholder="Todas" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={TODOS}>Todas</SelectItem>
                {institucionesOfrecidas.map((i) => (
                  <SelectItem key={i.id} value={String(i.id)}>
                    {i.nombreInstitucion}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {/* Se dice por qué la lista es corta: sin el cartel, un colegio que
                falta parece un dato que se perdió. */}
            {profesorFiltro !== TODOS && (
              <p className="mt-1 text-xs text-muted-foreground">
                {institucionesOfrecidas.length === 0
                  ? "Este profesor no marcó en el mes."
                  : `Sólo donde marcó este mes (${institucionesOfrecidas.length}).`}
              </p>
            )}
          </div>
          <div>
            <Label htmlFor="buscar-reportes">Buscar</Label>
            <div className="relative">
              <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                id="buscar-reportes"
                className="pl-9"
                placeholder="Tema, profesor, colegio"
                value={busqueda}
                onChange={(e) => setBusqueda(e.target.value)}
              />
            </div>
          </div>
        </section>

        {cargando && (
          <div className="space-y-3">
            {[1, 2, 3].map((n) => (
              <Skeleton key={n} className="h-28 w-full rounded-xl" />
            ))}
          </div>
        )}

        {reportes.isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 p-4 text-sm text-destructive">
            {mensajeError(reportes.error, "No se pudieron cargar los reportes")}
          </p>
        )}

        {!cargando && !reportes.isError && dias.length === 0 && (
          <div className="rounded-xl border border-dashed border-border p-12 text-center">
            <NotebookPen className="mx-auto size-9 text-muted-foreground" />
            <p className="mt-3 font-medium">
              No hay nada en {formatoMes.format(new Date(anio, mes - 1, 1))}
            </p>
            <p className="mx-auto mt-1 max-w-md text-sm text-muted-foreground">
              Un reporte se escribe sobre una marcación. Si el mes no tiene marcaciones, primero se
              cargan en Asistencias.
            </p>
          </div>
        )}

        {!cargando && dias.length > 0 && (
          <div className="space-y-8">
            {dias.map((dia) => (
              <section key={dia.fecha} className="space-y-3">
                <h2 className="sticky top-0 z-10 -mx-1 bg-background/95 px-1 py-2 text-xs font-semibold uppercase tracking-[0.14em] text-muted-foreground backdrop-blur">
                  {capitalizar(formatoDia.format(fechaLocal(dia.fecha)))}
                </h2>
                <div className="space-y-3">
                  {dia.items.map((entrada) =>
                    entrada.clase === "reporte" ? (
                      <TarjetaReporte
                        key={`r-${entrada.reporte.id}`}
                        reporte={entrada.reporte}
                        onAbrir={() => setFichaAbierta(entrada.reporte.id)}
                        onEliminar={() => setAEliminar(entrada.reporte)}
                      />
                    ) : (
                      <TarjetaPendiente
                        key={`p-${entrada.asistencia.idAsistencia}`}
                        asistencia={entrada.asistencia}
                        onEscribir={() => setEscribiendo(entrada.asistencia)}
                      />
                    ),
                  )}
                </div>
              </section>
            ))}
          </div>
        )}
      </main>

      {fichaAbierta !== null && empresa && (
        <FichaReporte
          idReporte={fichaAbierta}
          idEmpresa={empresa.id}
          onCerrar={() => setFichaAbierta(null)}
          onCambio={invalidar}
        />
      )}

      {escribiendo && empresa && (
        <EscribirReporte
          asistencia={escribiendo}
          idEmpresa={empresa.id}
          onCerrar={() => setEscribiendo(null)}
          onCreado={(idReporte) => {
            invalidar();
            setEscribiendo(null);
            // Se abre la ficha del reporte recién creado: el paso siguiente
            // natural es cargarle las fotos, y obligar a buscarlo de nuevo en la
            // lista es hacer que el usuario repita lo que acaba de hacer.
            setFichaAbierta(idReporte);
          }}
        />
      )}

      {aEliminar && (
        <Dialog open onOpenChange={(abierto) => !abierto && setAEliminar(null)}>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Eliminar el reporte</DialogTitle>
              <DialogDescription>
                Se borra el texto de {aEliminar.profesor} del{" "}
                {formatoDia.format(fechaLocal(aEliminar.fecha))}
                {aEliminar.cantidadMultimedia > 0
                  ? ` y sus ${aEliminar.cantidadMultimedia} evidencia${aEliminar.cantidadMultimedia === 1 ? "" : "s"}`
                  : ""}
                . La marcación no se toca: vuelve a aparecer como pendiente.
              </DialogDescription>
            </DialogHeader>
            <DialogFooter>
              <Button variant="outline" onClick={() => setAEliminar(null)}>
                Cancelar
              </Button>
              <Button
                variant="destructive"
                onClick={() => eliminar.mutate(aEliminar)}
                disabled={eliminar.isPending}
              >
                {eliminar.isPending && <Loader2 className="size-4 animate-spin" />}
                Eliminar
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      )}
    </AppLayout>
  );
}

/* -------------------------------------------------------------------------- */
/*  Tarjetas de la línea de tiempo                                             */
/* -------------------------------------------------------------------------- */

function Horario({ entrada, salida }: { entrada: string | null; salida: string | null }) {
  if (!entrada && !salida) return null;
  return (
    <span className="whitespace-nowrap text-xs tabular-nums text-muted-foreground">
      {entrada ?? "--:--"} a {salida ?? "--:--"}
    </span>
  );
}

function TarjetaReporte({
  reporte,
  onAbrir,
  onEliminar,
}: {
  reporte: ReporteActividad;
  onAbrir: () => void;
  onEliminar: () => void;
}) {
  return (
    <article className="group rounded-xl border border-border bg-card p-4 shadow-sm transition hover:border-primary/40 hover:shadow">
      <div className="flex items-start gap-3">
        <Avatar className="size-9 shrink-0">
          <AvatarFallback className="bg-primary/10 text-xs font-semibold text-primary">
            {iniciales(reporte.profesor)}
          </AvatarFallback>
        </Avatar>

        <button type="button" className="min-w-0 flex-1 text-left" onClick={onAbrir}>
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span className="font-semibold">{reporte.profesor}</span>
            <span className="text-muted-foreground">·</span>
            <span className="truncate text-sm text-muted-foreground">
              {reporte.institucion ?? "Institución eliminada"}
            </span>
            <Horario entrada={reporte.horaEntrada} salida={reporte.horaSalida} />
          </div>

          <p
            className={cn(
              "mt-1.5 whitespace-pre-wrap text-sm leading-6",
              reporte.descripcion ? "line-clamp-3" : "italic text-muted-foreground",
            )}
          >
            {reporte.descripcion || "Sin descripción todavía. Tocá para escribirla."}
          </p>
          {reporte.truncada === "S" && (
            <span className="mt-1 inline-block text-xs font-medium text-primary">
              Seguir leyendo
            </span>
          )}
        </button>

        <div className="flex shrink-0 items-center gap-1">
          <Button variant="ghost" size="icon" aria-label="Abrir reporte" onClick={onAbrir}>
            <PenLine className="size-4" />
          </Button>
          <Button variant="ghost" size="icon" aria-label="Eliminar reporte" onClick={onEliminar}>
            <Trash2 className="size-4 text-destructive" />
          </Button>
        </div>
      </div>

      {reporte.cantidadMultimedia > 0 && (
        <button
          type="button"
          onClick={onAbrir}
          className="mt-3 flex items-center gap-1.5 text-xs font-medium text-muted-foreground transition hover:text-primary"
        >
          <Paperclip className="size-3.5" />
          {reporte.cantidadMultimedia} evidencia{reporte.cantidadMultimedia === 1 ? "" : "s"}
        </button>
      )}
    </article>
  );
}

/**
 * Una marcación sin reporte, en el mismo hilo que los reportes.
 *
 * El borde punteado y la falta de texto la separan de un reporte cargado sin
 * necesidad de leer nada: el hueco se ve donde está, el día al que le falta, y
 * no en una segunda pantalla que hay que acordarse de mirar.
 */
function TarjetaPendiente({
  asistencia,
  onEscribir,
}: {
  asistencia: AsistenciaSinReporte;
  onEscribir: () => void;
}) {
  return (
    <article className="flex flex-wrap items-center gap-3 rounded-xl border border-dashed border-border bg-muted/30 p-4">
      <Avatar className="size-9 shrink-0">
        <AvatarFallback className="bg-muted text-xs font-semibold text-muted-foreground">
          {iniciales(asistencia.profesor)}
        </AvatarFallback>
      </Avatar>
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <span className="font-medium">{asistencia.profesor}</span>
          <span className="text-muted-foreground">·</span>
          <span className="truncate text-sm text-muted-foreground">
            {asistencia.institucion ?? "Sin institución"}
          </span>
          <Horario entrada={asistencia.horaEntrada} salida={asistencia.horaSalida} />
        </div>
        <p className="mt-0.5 text-sm text-muted-foreground">Marcó, pero todavía no reportó.</p>
      </div>
      <Button size="sm" onClick={onEscribir}>
        <Plus className="size-4" /> Escribir reporte
      </Button>
    </article>
  );
}

/* -------------------------------------------------------------------------- */
/*  Alta: escribir el reporte de una marcación                                 */
/* -------------------------------------------------------------------------- */

/**
 * El alta no pide profesor, institución ni fecha: los tres son de la marcación
 * y el backend los deriva de `idAsistencia`. Acá sólo se escribe el texto — y
 * hasta eso es opcional, porque un reporte que arranca con las fotos y se
 * redacta después sigue siendo un reporte.
 */
function EscribirReporte({
  asistencia,
  idEmpresa,
  onCerrar,
  onCreado,
}: {
  asistencia: AsistenciaSinReporte;
  idEmpresa: number;
  onCerrar: () => void;
  onCreado: (idReporte: number) => void;
}) {
  const [descripcion, setDescripcion] = useState("");

  const crear = useMutation({
    mutationFn: () =>
      api.reportesActividades.crear({
        idEmpresa,
        idAsistencia: asistencia.idAsistencia,
        // Siempre la clave, aunque vaya vacía: una omitida deja el bind de ORDS
        // sin definir y el backend responde 400.
        descripcion,
      }),
    onSuccess: (respuesta) => {
      toast.success("Reporte creado");
      onCreado(respuesta.id);
    },
    onError: (error) => toast.error(mensajeError(error, "No se pudo crear el reporte")),
  });

  return (
    <Dialog open onOpenChange={(abierto) => !abierto && onCerrar()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Reporte de {asistencia.profesor}</DialogTitle>
          <DialogDescription>
            {capitalizar(formatoDia.format(fechaLocal(asistencia.fecha)))} ·{" "}
            {asistencia.institucion ?? "Sin institución"}
            {asistencia.horaEntrada
              ? ` · ${asistencia.horaEntrada} a ${asistencia.horaSalida ?? "--:--"}`
              : ""}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-2">
          <Label htmlFor="descripcion-nueva">Qué se trabajó</Label>
          <Textarea
            id="descripcion-nueva"
            rows={6}
            maxLength={MAX_DESCRIPCION_REPORTE}
            value={descripcion}
            onChange={(e) => setDescripcion(e.target.value)}
            placeholder="Tema de la clase, cómo se trabajó, cómo respondió el grupo…"
          />
          <p className="text-right text-xs text-muted-foreground">
            {descripcion.length} / {MAX_DESCRIPCION_REPORTE}
          </p>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onCerrar}>
            Cancelar
          </Button>
          <Button onClick={() => crear.mutate()} disabled={crear.isPending}>
            {crear.isPending && <Loader2 className="size-4 animate-spin" />}
            Crear y agregar fotos
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/* -------------------------------------------------------------------------- */
/*  Ficha: texto completo + galería                                            */
/* -------------------------------------------------------------------------- */

/**
 * La ficha carga con `obtener()` y **no reusa la fila del listado**: ahí la
 * descripción viene recortada a 200 caracteres, y guardar ese resumen escribiría
 * 200 encima de los 2000 que había. Es la trampa que ya costó cara en
 * Inventarios con sus observaciones.
 */
function FichaReporte({
  idReporte,
  idEmpresa,
  onCerrar,
  onCambio,
}: {
  idReporte: number;
  idEmpresa: number;
  onCerrar: () => void;
  onCambio: () => void;
}) {
  const queryClient = useQueryClient();
  const [borrador, setBorrador] = useState<string | null>(null);
  const [viendo, setViendo] = useState<number | null>(null);

  const ficha = useQuery({
    queryKey: ["reporte-actividad", idReporte, idEmpresa],
    queryFn: () => api.reportesActividades.obtener(idReporte, idEmpresa),
  });

  const evidencias = useQuery({
    queryKey: ["reportes-multimedia", idReporte, idEmpresa],
    queryFn: () => api.reportesMultimedia.listar({ idReporte, idEmpresa }),
  });

  const guardar = useMutation({
    mutationFn: (texto: string) =>
      api.reportesActividades.actualizar(idReporte, { idEmpresa, descripcion: texto }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["reporte-actividad", idReporte] });
      onCambio();
      setBorrador(null);
      toast.success("Reporte guardado");
    },
    onError: (error) => toast.error(mensajeError(error, "No se pudo guardar el reporte")),
  });

  const refrescarEvidencias = () => {
    void queryClient.invalidateQueries({ queryKey: ["reportes-multimedia", idReporte] });
    void queryClient.invalidateQueries({ queryKey: ["reporte-actividad", idReporte] });
    onCambio();
  };

  const archivos = evidencias.data?.items ?? [];
  const texto = borrador ?? ficha.data?.descripcion ?? "";
  const hayCambios = borrador !== null && borrador !== (ficha.data?.descripcion ?? "");
  const enVisor = viendo === null ? null : (archivos.find((a) => a.id === viendo) ?? null);

  return (
    <>
      <Dialog open onOpenChange={(abierto) => !abierto && onCerrar()}>
        <DialogContent className="max-h-[90vh] max-w-2xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{ficha.data?.profesor ?? "Reporte"}</DialogTitle>
            <DialogDescription>
              {ficha.data
                ? `${capitalizar(formatoDia.format(fechaLocal(ficha.data.fecha)))} · ${ficha.data.institucion ?? "Sin institución"}${
                    ficha.data.horaEntrada
                      ? ` · ${ficha.data.horaEntrada} a ${ficha.data.horaSalida ?? "--:--"}`
                      : ""
                  }`
                : "Cargando…"}
            </DialogDescription>
          </DialogHeader>

          {ficha.isPending && <Skeleton className="h-32 w-full" />}

          {ficha.isError && (
            <p className="rounded-lg border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
              {mensajeError(ficha.error, "No se pudo abrir el reporte")}
            </p>
          )}

          {ficha.data && (
            <div className="space-y-5">
              <div className="space-y-2">
                <Label htmlFor="descripcion-ficha">Qué se trabajó</Label>
                <Textarea
                  id="descripcion-ficha"
                  rows={7}
                  maxLength={MAX_DESCRIPCION_REPORTE}
                  value={texto}
                  onChange={(e) => setBorrador(e.target.value)}
                  placeholder="Tema de la clase, cómo se trabajó, cómo respondió el grupo…"
                />
                <div className="flex items-center justify-between gap-3">
                  <p className="text-xs text-muted-foreground">
                    {texto.length} / {MAX_DESCRIPCION_REPORTE}
                  </p>
                  {hayCambios && (
                    <div className="flex gap-2">
                      <Button variant="ghost" size="sm" onClick={() => setBorrador(null)}>
                        Descartar
                      </Button>
                      <Button
                        size="sm"
                        onClick={() => guardar.mutate(borrador ?? "")}
                        disabled={guardar.isPending}
                      >
                        {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                        Guardar
                      </Button>
                    </div>
                  )}
                </div>
              </div>

              <Galeria
                idReporte={idReporte}
                idEmpresa={idEmpresa}
                archivos={archivos}
                cargando={evidencias.isPending}
                onVer={setViendo}
                onCambio={refrescarEvidencias}
              />
            </div>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={onCerrar}>
              Cerrar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {enVisor && (
        <Visor
          archivo={enVisor}
          idEmpresa={idEmpresa}
          onCerrar={() => setViendo(null)}
          onCambio={refrescarEvidencias}
        />
      )}
    </>
  );
}

/* -------------------------------------------------------------------------- */
/*  Galería de evidencias                                                      */
/* -------------------------------------------------------------------------- */

function IconoTipo({ tipo, className }: { tipo: TipoArchivo; className?: string }) {
  if (tipo === "video") return <Play className={className} />;
  if (tipo === "documento") return <FileText className={className} />;
  return <ImageIcon className={className} />;
}

function Galeria({
  idReporte,
  idEmpresa,
  archivos,
  cargando,
  onVer,
  onCambio,
}: {
  idReporte: number;
  idEmpresa: number;
  archivos: ReporteMultimedia[];
  cargando: boolean;
  onVer: (id: number) => void;
  onCambio: () => void;
}) {
  const selector = useRef<HTMLInputElement>(null);
  const [subiendo, setSubiendo] = useState<string[]>([]);
  const [urlPegada, setUrlPegada] = useState("");

  /**
   * Sube cada archivo a Cloudinary y recién ahí guarda su fila.
   *
   * En ese orden y no al revés: la fila exige la URL, que sólo existe una vez
   * subido. Si una falla, las demás siguen —se sube de a varias fotos y perder
   * las cinco buenas porque la sexta pesaba de más sería peor que avisar cuál
   * falló.
   */
  const subir = async (lista: FileList | null) => {
    if (!lista || lista.length === 0) return;
    const seleccionados = [...lista];
    setSubiendo(seleccionados.map((archivo) => archivo.name));

    let subidos = 0;
    for (const archivo of seleccionados) {
      try {
        const resultado = await subirACloudinary(archivo);
        await api.reportesMultimedia.crear({
          idReporte,
          idEmpresa,
          tipoArchivo: resultado.tipo,
          urlArchivo: resultado.url,
          nombreArchivo: resultado.nombre,
          tamanioBytes: resultado.bytes,
          descripcionTexto: "",
        });
        subidos += 1;
      } catch (error) {
        toast.error(`${archivo.name}: ${mensajeError(error, "no se pudo subir")}`);
      }
      setSubiendo((pendientes) => pendientes.filter((nombre) => nombre !== archivo.name));
    }

    if (subidos > 0) {
      toast.success(
        `${subidos} evidencia${subidos === 1 ? "" : "s"} agregada${subidos === 1 ? "" : "s"}`,
      );
      onCambio();
    }
    if (selector.current) selector.current.value = "";
  };

  const guardarUrl = useMutation({
    mutationFn: (url: string) =>
      api.reportesMultimedia.crear({
        idReporte,
        idEmpresa,
        // Sin el archivo en la mano no hay MIME que mirar: se deduce de la
        // extensión, y lo que no se reconoce entra como documento —que es el
        // tipo que la galería representa con un ícono, nunca con una miniatura
        // rota.
        tipoArchivo: /\.(jpe?g|png|gif|webp|avif|heic)$/i.test(url)
          ? "foto"
          : /\.(mp4|mov|webm|mkv|avi)$/i.test(url)
            ? "video"
            : "documento",
        urlArchivo: url.trim(),
        nombreArchivo: url.split("/").pop() ?? "",
        tamanioBytes: 0,
        descripcionTexto: "",
      }),
    onSuccess: () => {
      setUrlPegada("");
      onCambio();
      toast.success("Evidencia agregada");
    },
    onError: (error) => toast.error(mensajeError(error, "No se pudo agregar la evidencia")),
  });

  return (
    <section className="space-y-3">
      <div className="flex items-center justify-between gap-3">
        <h3 className="text-sm font-semibold">
          Evidencias{archivos.length > 0 ? ` (${archivos.length})` : ""}
        </h3>
        {subidaDirectaDisponible && (
          <Button
            variant="outline"
            size="sm"
            onClick={() => selector.current?.click()}
            disabled={subiendo.length > 0}
          >
            {subiendo.length > 0 ? (
              <Loader2 className="size-4 animate-spin" />
            ) : (
              <Upload className="size-4" />
            )}
            Agregar
          </Button>
        )}
      </div>

      <input
        ref={selector}
        type="file"
        multiple
        accept="image/*,video/*,application/pdf"
        className="hidden"
        onChange={(e) => void subir(e.target.files)}
      />

      {cargando && <Skeleton className="h-24 w-full" />}

      {!cargando && archivos.length === 0 && subiendo.length === 0 && (
        <div className="rounded-lg border border-dashed border-border p-6 text-center">
          <ImageIcon className="mx-auto size-6 text-muted-foreground" />
          <p className="mt-2 text-sm text-muted-foreground">
            Todavía no hay fotos ni videos de esta clase.
          </p>
        </div>
      )}

      {(archivos.length > 0 || subiendo.length > 0) && (
        <div className="grid grid-cols-3 gap-2 sm:grid-cols-4">
          {archivos.map((archivo) => {
            const previa = miniatura(archivo.urlArchivo, archivo.tipoArchivo);
            return (
              <button
                key={archivo.id}
                type="button"
                onClick={() => onVer(archivo.id)}
                className="group relative aspect-square overflow-hidden rounded-lg border border-border bg-muted"
                aria-label={archivo.nombreArchivo ?? "Ver evidencia"}
              >
                {previa ? (
                  <img
                    src={previa}
                    alt={archivo.descripcionTexto ?? archivo.nombreArchivo ?? ""}
                    loading="lazy"
                    className="size-full object-cover transition group-hover:scale-105"
                  />
                ) : (
                  <span className="flex size-full items-center justify-center">
                    <FileText className="size-6 text-muted-foreground" />
                  </span>
                )}
                {archivo.tipoArchivo === "video" && (
                  <span className="absolute inset-0 flex items-center justify-center bg-black/25">
                    <Play className="size-6 text-white drop-shadow" />
                  </span>
                )}
                {archivo.descripcionTexto && (
                  <span className="absolute inset-x-0 bottom-0 truncate bg-gradient-to-t from-black/70 to-transparent px-1.5 pb-1 pt-4 text-left text-[11px] text-white">
                    {archivo.descripcionTexto}
                  </span>
                )}
              </button>
            );
          })}

          {subiendo.map((nombre) => (
            <div
              key={nombre}
              className="flex aspect-square flex-col items-center justify-center gap-1 rounded-lg border border-dashed border-border bg-muted/50 p-2"
            >
              <Loader2 className="size-5 animate-spin text-muted-foreground" />
              <span className="line-clamp-2 text-center text-[11px] text-muted-foreground">
                {nombre}
              </span>
            </div>
          ))}
        </div>
      )}

      {/* Sin cuenta de Cloudinary configurada no hay a dónde subir, así que la
          pantalla ofrece lo único que sí funciona: pegar una URL ya subida. */}
      {!subidaDirectaDisponible && (
        <div className="rounded-lg border border-dashed border-border p-3">
          <Label htmlFor="url-evidencia" className="text-xs">
            La subida directa no está configurada. Pegá la URL del archivo (https://)
          </Label>
          <div className="mt-2 flex gap-2">
            <Input
              id="url-evidencia"
              value={urlPegada}
              onChange={(e) => setUrlPegada(e.target.value)}
              placeholder="https://res.cloudinary.com/…"
            />
            <Button
              onClick={() => guardarUrl.mutate(urlPegada)}
              disabled={!urlPegada.trim().startsWith("https://") || guardarUrl.isPending}
            >
              Agregar
            </Button>
          </div>
        </div>
      )}
    </section>
  );
}

/* -------------------------------------------------------------------------- */
/*  Visor                                                                      */
/* -------------------------------------------------------------------------- */

/**
 * La evidencia en grande, con su pie editable.
 *
 * El pie se escribe acá y no al subir: se cargan cinco fotos de una y pedir la
 * descripción de cada una antes de guardar convierte un gesto en un formulario.
 * Acá se ve la foto mientras se la describe, que es cuando se sabe qué decir.
 */
function Visor({
  archivo,
  idEmpresa,
  onCerrar,
  onCambio,
}: {
  archivo: ReporteMultimedia;
  idEmpresa: number;
  onCerrar: () => void;
  onCambio: () => void;
}) {
  const [pie, setPie] = useState(archivo.descripcionTexto ?? "");
  const [confirmando, setConfirmando] = useState(false);
  const peso = pesoLegible(archivo.tamanioBytes);

  const guardarPie = useMutation({
    mutationFn: () =>
      api.reportesMultimedia.actualizar(archivo.id, { idEmpresa, descripcionTexto: pie }),
    onSuccess: () => {
      onCambio();
      toast.success("Descripción guardada");
    },
    onError: (error) => toast.error(mensajeError(error, "No se pudo guardar la descripción")),
  });

  const eliminar = useMutation({
    mutationFn: () => api.reportesMultimedia.eliminar(archivo.id, idEmpresa),
    onSuccess: () => {
      onCambio();
      onCerrar();
      // El archivo sigue en Cloudinary: lo que se borra es la referencia. Se
      // dice, para que nadie cuente con que la foto dejó de existir.
      toast.success("Evidencia quitada del reporte");
    },
    onError: (error) => toast.error(mensajeError(error, "No se pudo quitar la evidencia")),
  });

  return (
    <Dialog open onOpenChange={(abierto) => !abierto && onCerrar()}>
      <DialogContent className="max-h-[92vh] max-w-3xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 text-base">
            <IconoTipo tipo={archivo.tipoArchivo} className="size-4 text-primary" />
            {archivo.nombreArchivo || `Evidencia ${archivo.id}`}
          </DialogTitle>
          <DialogDescription>
            {archivo.tipoArchivo}
            {peso ? ` · ${peso}` : ""}
          </DialogDescription>
        </DialogHeader>

        <div className="overflow-hidden rounded-lg border border-border bg-muted">
          {archivo.tipoArchivo === "foto" && (
            <img
              src={archivo.urlArchivo}
              alt={archivo.descripcionTexto ?? ""}
              className="mx-auto max-h-[55vh] w-auto object-contain"
            />
          )}
          {archivo.tipoArchivo === "video" && (
            <video src={archivo.urlArchivo} controls className="mx-auto max-h-[55vh] w-full" />
          )}
          {archivo.tipoArchivo === "documento" && (
            <div className="p-8 text-center">
              <FileText className="mx-auto size-8 text-muted-foreground" />
              <a
                href={archivo.urlArchivo}
                target="_blank"
                rel="noreferrer"
                className="mt-3 inline-block text-sm font-medium text-primary underline"
              >
                Abrir el archivo
              </a>
            </div>
          )}
        </div>

        <div className="space-y-2">
          <Label htmlFor="pie-evidencia">Qué muestra</Label>
          <Input
            id="pie-evidencia"
            value={pie}
            maxLength={MAX_PIE_MULTIMEDIA}
            onChange={(e) => setPie(e.target.value)}
            placeholder="Los chicos armando el mapa en grupo"
          />
        </div>

        <DialogFooter className="sm:justify-between">
          <Button
            variant="ghost"
            className="text-destructive hover:text-destructive"
            onClick={() => setConfirmando(true)}
            disabled={eliminar.isPending}
          >
            <Trash2 className="size-4" /> Quitar
          </Button>
          <div className="flex gap-2">
            <Button variant="outline" onClick={onCerrar}>
              <X className="size-4" /> Cerrar
            </Button>
            <Button
              onClick={() => guardarPie.mutate()}
              disabled={guardarPie.isPending || pie === (archivo.descripcionTexto ?? "")}
            >
              {guardarPie.isPending && <Loader2 className="size-4 animate-spin" />}
              Guardar
            </Button>
          </div>
        </DialogFooter>

        {confirmando && (
          <Dialog open onOpenChange={(abierto) => !abierto && setConfirmando(false)}>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Quitar la evidencia</DialogTitle>
                <DialogDescription>
                  Se saca del reporte. El archivo en sí queda guardado en Cloudinary: esto borra la
                  referencia, no el original.
                </DialogDescription>
              </DialogHeader>
              <DialogFooter>
                <Button variant="outline" onClick={() => setConfirmando(false)}>
                  Cancelar
                </Button>
                <Button
                  variant="destructive"
                  onClick={() => eliminar.mutate()}
                  disabled={eliminar.isPending}
                >
                  Quitar
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        )}
      </DialogContent>
    </Dialog>
  );
}
