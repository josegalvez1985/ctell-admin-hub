import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  AlertTriangle,
  CalendarDays,
  Clock,
  FileSpreadsheet,
  FileText,
  LayoutGrid,
  MapPin,
  Pencil,
  Plus,
  Table2,
  Trash2,
  WifiOff,
} from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { InputMoneda } from "@/components/ctell/InputMoneda";
import { MarcacionDialog } from "@/components/ctell/MarcacionDialog";
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
import { Input } from "@/components/ui/input";
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
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { api, ApiError, type AsistenciaProfesor } from "@/lib/api";
import {
  abrirPdf,
  abrirPlanillaPdf,
  descargarExcel,
  descargarPlanillaExcel,
  type ColumnaExport,
  type DatosPlanilla,
} from "@/lib/exportar";
import { tituloPagina } from "@/lib/marca";
import { formatearMoneda, numeroMoneda } from "@/lib/moneda";

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Valor del combo de profesor para "todos".
 *
 * Radix no acepta un `<SelectItem value="">`, y hace falta poder ELEGIRLO: una
 * vez que se filtra por un profesor, el Select no se deselecciona solo.
 */
const TODOS = "todos";

const MESES = [
  "Enero",
  "Febrero",
  "Marzo",
  "Abril",
  "Mayo",
  "Junio",
  "Julio",
  "Agosto",
  "Septiembre",
  "Octubre",
  "Noviembre",
  "Diciembre",
];

/** Lunes a domingo. `getDay()` devuelve 0 para domingo, de ahí el orden. */
const DIAS = ["Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb"];

/**
 * Fecha ISO (`YYYY-MM-DD`) → `Date` local.
 *
 * `new Date("2026-06-05")` la interpreta como UTC y en Paraguay (UTC-3) cae el
 * día anterior: un mes entero saldría corrido un día. Partiendo el string y
 * usando el constructor por partes, la fecha es la que dice el texto.
 */
function fechaLocal(iso: string): Date {
  const [anio, mes, dia] = iso.split("-").map(Number);
  return new Date(anio ?? 0, (mes ?? 1) - 1, dia ?? 1);
}

/** Minutos → "3:45". Con `null` (marcación incompleta) devuelve una raya. */
function formatearDuracion(minutos: number | null): string {
  if (minutos === null) return "—";
  const horas = Math.floor(minutos / 60);
  return `${horas}:${String(minutos % 60).padStart(2, "0")}`;
}

/**
 * Minutos → horas cátedra, con dos decimales.
 *
 * La duración de la cátedra la carga el usuario: 60 minutos es lo habitual,
 * pero en varias instituciones son 40 o 45 y el total del mes cambia con eso.
 */
function aHorasCatedra(minutos: number, duracionCatedra: number): number {
  return minutos / (duracionCatedra || 60);
}

export const Route = createFileRoute("/_auth/asistencias")({
  head: () => ({
    meta: [
      { title: tituloPagina("Asistencias") },
      {
        name: "description",
        content: "Reporte de asistencias de profesores, con exportación a Excel y PDF.",
      },
    ],
  }),
  component: AsistenciasPage,
});

function AsistenciasPage() {
  const { empresa } = useEmpresa();
  const queryClient = useQueryClient();
  const hoy = new Date();

  const [anio, setAnio] = useState(String(hoy.getFullYear()));
  const [mes, setMes] = useState(String(hoy.getMonth() + 1));
  const [idInstitucion, setIdInstitucion] = useState(TODOS);
  const [idProfesor, setIdProfesor] = useState(TODOS);
  const [vista, setVista] = useState<"planilla" | "detalle">("planilla");

  // Carga manual. `editando` en null con el diálogo abierto es un alta.
  const [dialogoAbierto, setDialogoAbierto] = useState(false);
  const [editando, setEditando] = useState<AsistenciaProfesor | null>(null);
  const [aEliminar, setAEliminar] = useState<AsistenciaProfesor | null>(null);

  // Los dos parámetros del cálculo. Viven en la pantalla y no en la base: ver
  // la nota de db/asistencias-profesores.sql.
  const [precioHora, setPrecioHora] = useState("");
  const [duracionCatedra, setDuracionCatedra] = useState("60");

  /**
   * Las marcaciones del período SIN filtrar por institución ni profesor.
   *
   * De acá salen las dos listas de los combos, y por eso no se puede reusar
   * `asistencias`: esa ya viene filtrada, así que elegir una institución dejaría
   * el combo con esa sola opción y no habría cómo volver a otra.
   *
   * Tampoco salen de `/instituciones/listar` ni de `/profesores/listar`: esos
   * traen los catálogos completos y ofrecerían decenas de opciones que en el mes
   * elegido no tienen ninguna marcación — elegir una devuelve una pantalla
   * vacía, y no hay forma de saber cuál sí tiene sin probarlas de a una.
   */
  const delPeriodo = useQuery({
    queryKey: ["asistencias", empresa?.id ?? null, anio, mes, "periodo-completo"],
    queryFn: () =>
      api.asistenciasProfesores.listar({
        idEmpresa: empresa!.id,
        anio: Number(anio),
        mes: Number(mes),
      }),
    enabled: empresa !== null,
  });

  const asistencias = useQuery({
    queryKey: ["asistencias", empresa?.id ?? null, anio, mes, idInstitucion, idProfesor],
    queryFn: () =>
      api.asistenciasProfesores.listar({
        idEmpresa: empresa!.id,
        anio: Number(anio),
        mes: Number(mes),
        ...(idInstitucion !== TODOS ? { idInstitucion: Number(idInstitucion) } : {}),
        ...(idProfesor !== TODOS ? { idProfesor: Number(idProfesor) } : {}),
      }),
    enabled: empresa !== null,
  });

  const items = useMemo(() => asistencias.data?.items ?? [], [asistencias.data?.items]);

  const itemsPeriodo = useMemo(() => delPeriodo.data?.items ?? [], [delPeriodo.data?.items]);

  /** Las instituciones con al menos una marcación en el período. */
  const institucionesConMarcas = useMemo(() => {
    const mapa = new Map<number, string>();
    for (const a of itemsPeriodo) {
      if (a.idInstitucion !== null && !mapa.has(a.idInstitucion)) {
        mapa.set(a.idInstitucion, a.institucion ?? `Institución ${a.idInstitucion}`);
      }
    }
    return [...mapa.entries()]
      .map(([id, nombre]) => ({ id, nombre }))
      .sort((a, b) => a.nombre.localeCompare(b.nombre, "es"));
  }, [itemsPeriodo]);

  /**
   * Los profesores con marcaciones, acotados a la institución elegida.
   *
   * Es el subfiltro: elegida una institución, el combo ofrece sólo a quienes
   * dieron clase ahí. Sin institución, todos los del período.
   */
  const profesoresConMarcas = useMemo(() => {
    const mapa = new Map<number, string>();
    for (const a of itemsPeriodo) {
      if (idInstitucion !== TODOS && String(a.idInstitucion) !== idInstitucion) continue;
      if (!mapa.has(a.idProfesor)) mapa.set(a.idProfesor, a.profesor);
    }
    return [...mapa.entries()]
      .map(([id, nombre]) => ({ id, nombre }))
      .sort((a, b) => a.nombre.localeCompare(b.nombre, "es"));
  }, [itemsPeriodo, idInstitucion]);

  /**
   * Si el profesor elegido no da clase en la institución elegida, el filtro
   * queda en una combinación sin resultados y la pantalla se ve vacía sin
   * explicar por qué. Se vuelve a "Todos" en cuanto deja de ser una opción.
   *
   * Se compara contra la lista ya calculada y no se pide nada: es corregir el
   * estado, no un efecto sobre datos externos.
   */
  // Al cambiar de mes la institución elegida puede no tener marcaciones en el
  // nuevo período: quedaría filtrando por algo que ya no está en la lista.
  const institucionFueraDeLista =
    idInstitucion !== TODOS &&
    !delPeriodo.isPending &&
    !institucionesConMarcas.some((i) => String(i.id) === idInstitucion);
  if (institucionFueraDeLista) setIdInstitucion(TODOS);

  // El `!isPending` importa: mientras la consulta del período está en vuelo la
  // lista está vacía, y sin esa guarda el filtro se resetearía solo cada vez que
  // se cambia de mes.
  const profesorFueraDeLista =
    idProfesor !== TODOS &&
    !delPeriodo.isPending &&
    !profesoresConMarcas.some((p) => String(p.id) === idProfesor);
  if (profesorFueraDeLista) setIdProfesor(TODOS);

  const catedra = Number(duracionCatedra) || 60;
  const precio = numeroMoneda(precioHora) || 0;

  /**
   * Los totales del período.
   *
   * `minutos` en `null` es una marcación INCOMPLETA y no suma: contarla como 0
   * la escondería entre las jornadas normales, y es justo lo que hay que
   * revisar antes de liquidar.
   */
  const totales = useMemo(() => {
    let minutos = 0;
    let incompletas = 0;
    const dias = new Set<string>();

    for (const a of items) {
      if (a.minutos === null) incompletas += 1;
      else {
        minutos += a.minutos;
        dias.add(a.fecha);
      }
    }

    const horas = aHorasCatedra(minutos, catedra);
    const importe = horas * precio;
    return {
      minutos,
      horas,
      dias: dias.size,
      incompletas,
      importe,
      // El IVA se DESGLOSA de un precio que ya lo incluye, igual que en el resto
      // del sistema: nunca se suma encima. Ver la nota de IVA en CLAUDE.md.
      iva: importe - Math.round((importe / 1.1) * 100) / 100,
    };
  }, [items, catedra, precio]);

  /** Las marcaciones de cada día, para la grilla de la planilla. */
  const porDia = useMemo(() => {
    const mapa = new Map<string, AsistenciaProfesor[]>();
    for (const a of items) {
      const lista = mapa.get(a.fecha);
      if (lista) lista.push(a);
      else mapa.set(a.fecha, [a]);
    }
    return mapa;
  }, [items]);

  /** Todos los días del mes elegido, haya o no marcaciones. */
  const diasDelMes = useMemo(() => {
    const total = new Date(Number(anio), Number(mes), 0).getDate();
    return Array.from({ length: total }, (_, i) => {
      const fecha = new Date(Number(anio), Number(mes) - 1, i + 1);
      const iso = `${anio}-${String(mes).padStart(2, "0")}-${String(i + 1).padStart(2, "0")}`;
      return { dia: i + 1, iso, diaSemana: fecha.getDay() };
    });
  }, [anio, mes]);

  /** Cuántos pares Ent./Sal. mostrar: el máximo real del mes, mínimo 2. */
  const maxMarcas = useMemo(
    () => Math.max(2, ...[...porDia.values()].map((l) => l.length)),
    [porDia],
  );

  // Los nombres salen de las mismas listas que alimentan los combos: el nombre
  // que ya viene en la marcación, sin volver a pedir el catálogo.
  const nombreProfesor =
    profesoresConMarcas.find((p) => String(p.id) === idProfesor)?.nombre ?? "Todos los profesores";

  const nombreInstitucion =
    institucionesConMarcas.find((i) => String(i.id) === idInstitucion)?.nombre ??
    "Todas las instituciones";

  const periodo = `${MESES[Number(mes) - 1]} ${anio}`;

  const columnas: ColumnaExport<AsistenciaProfesor>[] = [
    { titulo: "Fecha", valor: (a) => a.fecha, ancho: 12 },
    {
      titulo: "Día",
      valor: (a) => DIAS[fechaLocal(a.fecha).getDay()] ?? "",
      ancho: 8,
    },
    { titulo: "Profesor", valor: (a) => a.profesor, ancho: 28 },
    { titulo: "CI", valor: (a) => a.numeroCi, ancho: 14 },
    { titulo: "Institución", valor: (a) => a.institucion ?? "—", ancho: 26 },
    { titulo: "Entrada", valor: (a) => a.horaEntrada ?? "—", ancho: 10 },
    { titulo: "Salida", valor: (a) => a.horaSalida ?? "—", ancho: 10 },
    {
      // Número y no "3:45": en Excel tiene que poder sumarse.
      titulo: "Horas",
      valor: (a) =>
        a.minutos === null ? null : Number(aHorasCatedra(a.minutos, catedra).toFixed(2)),
      numerica: true,
      ancho: 10,
    },
    {
      // "Gs." en el título y el número pelado: el símbolo ₲ no existe en las
      // fuentes de fábrica de jsPDF y saldría como un cuadrito.
      titulo: "Importe Gs.",
      valor: (a) =>
        a.minutos === null ? null : Math.round(aHorasCatedra(a.minutos, catedra) * precio),
      numerica: true,
      ancho: 16,
    },
    {
      titulo: "Observación",
      valor: (a) =>
        a.minutos === null
          ? "Marcación incompleta"
          : a.entradaOffline === "S" || a.salidaOffline === "S"
            ? "Marcado sin conexión"
            : "",
      ancho: 22,
    },
  ];

  const subtitulos = [
    `${nombreProfesor} · ${nombreInstitucion} · ${periodo}`,
    `Hora cátedra: ${catedra} min · Precio por hora: ${formatearMoneda(precio)} Gs.`,
    `Total: ${totales.horas.toFixed(2)} hs en ${totales.dias} día(s) · Importe: ${formatearMoneda(Math.round(totales.importe))} Gs.`,
  ];

  const nombreArchivo = `asistencias-${anio}-${String(mes).padStart(2, "0")}`;

  /**
   * Una planilla POR PROFESOR, con la forma de la planilla de papel.
   *
   * Se arma acá y no dentro de `exportar.ts` porque depende de la hora cátedra
   * y del precio, que son parámetros de esta pantalla.
   *
   * Es una lista y no un solo objeto porque la planilla se firma de a una
   * persona: filtrando por institución salen todos los que dieron clase ahí, y
   * cada uno necesita la suya. Con un profesor elegido la lista tiene un solo
   * elemento, que es el caso de siempre.
   */
  const planillas: DatosPlanilla[] = useMemo(() => {
    // Agrupar preservando el orden en que llegan del backend (fecha, entrada):
    // así las planillas salen en un orden estable y no en el del hash.
    const porProfesor = new Map<number, AsistenciaProfesor[]>();
    for (const a of items) {
      const lista = porProfesor.get(a.idProfesor);
      if (lista) lista.push(a);
      else porProfesor.set(a.idProfesor, [a]);
    }

    return [...porProfesor.values()]
      .sort((a, b) => (a[0]?.profesor ?? "").localeCompare(b[0]?.profesor ?? "", "es"))
      .map((marcasProfesor) => {
        // Los totales se recalculan sobre las marcas de ESTE profesor: los de
        // la pantalla son del período entero y acá firma una sola persona.
        let minutosTotales = 0;
        for (const a of marcasProfesor) minutosTotales += a.minutos ?? 0;
        const horas = aHorasCatedra(minutosTotales, catedra);
        const importe = horas * precio;

        const diasProfesor = new Map<string, AsistenciaProfesor[]>();
        for (const a of marcasProfesor) {
          const lista = diasProfesor.get(a.fecha);
          if (lista) lista.push(a);
          else diasProfesor.set(a.fecha, [a]);
        }

        return {
          profesor: marcasProfesor[0]?.profesor ?? nombreProfesor,
          // Con el filtro de institución puesto es esa; sin filtro, todas
          // aquellas donde este profesor marcó. Sale de las marcas y no del
          // filtro para no afirmar una institución en la que no estuvo.
          institucion:
            [...new Set(marcasProfesor.map((a) => a.institucion).filter(Boolean))].join(" · ") ||
            "—",
          periodo,
          horaCatedra: catedra,
          precioHora: precio,
          // Por profesor y no el máximo global: si otro tuvo 4 marcas en un día,
          // no tiene por qué agregar dos columnas vacías a esta planilla.
          columnasMarca: Math.max(2, ...[...diasProfesor.values()].map((l) => l.length)),
          filas: diasDelMes.map(({ dia, iso, diaSemana }) => {
            const marcas = diasProfesor.get(iso) ?? [];
            const minutos = marcas.reduce((s, m) => s + (m.minutos ?? 0), 0);
            return {
              dia,
              diaSemana: DIAS[diaSemana] ?? "",
              marcas: marcas.map((m) => ({ entrada: m.horaEntrada, salida: m.horaSalida })),
              horas: minutos > 0 ? Number(aHorasCatedra(minutos, catedra).toFixed(2)) : 0,
              finDeSemana: diaSemana === 0 || diaSemana === 6,
            };
          }),
          totalHoras: Number(horas.toFixed(2)),
          totalImporte: importe,
          // El IVA se DESGLOSA de un precio que ya lo incluye, igual que en el
          // resto del sistema. Mismo criterio que `totales`.
          totalIva: importe - Math.round((importe / 1.1) * 100) / 100,
          // Seis renglones en blanco: el bloque no sale de la base y se completa
          // a mano sobre el papel. Es la misma cantidad que trae la planilla
          // actual.
          filasActividadExtra: 6,
        };
      });
  }, [items, catedra, precio, periodo, diasDelMes, nombreProfesor]);

  const exportaPlanilla = vista === "planilla";
  const exportarBloqueado = items.length === 0;

  const eliminar = useMutation({
    mutationFn: (a: AsistenciaProfesor) => api.asistenciasProfesores.eliminar(a.id, empresa!.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["asistencias"] });
      toast.success("Marcación eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  /**
   * El alta arranca en el período que se está mirando, no en hoy.
   *
   * Si alguien está corrigiendo agosto, la marcación que va a cargar es de
   * agosto: ofrecerle la fecha de hoy lo obliga a corregirla siempre, y una
   * fecha fuera del período elegido desaparece del listado apenas se guarda.
   */
  const fechaSugerida = useMemo(() => {
    const primero = `${anio}-${String(mes).padStart(2, "0")}-01`;
    const hoyIso = `${hoy.getFullYear()}-${String(hoy.getMonth() + 1).padStart(2, "0")}-${String(hoy.getDate()).padStart(2, "0")}`;
    // Si el período elegido es el mes en curso, hoy; si no, el primero del mes.
    return hoyIso.startsWith(`${anio}-${String(mes).padStart(2, "0")}`) ? hoyIso : primero;
    // eslint-disable-next-line react-hooks/exhaustive-deps -- `hoy` es un new Date() por render
  }, [anio, mes]);

  function abrirAlta() {
    setEditando(null);
    setDialogoAbierto(true);
  }

  function abrirEdicion(a: AsistenciaProfesor) {
    setEditando(a);
    setDialogoAbierto(true);
  }

  /**
   * La exportación sigue a la vista activa.
   *
   * En Planilla baja la grilla del mes con el formato de la planilla de papel;
   * en Detalle, la lista plana de marcaciones. Exportar siempre lo mismo haría
   * que el archivo no se parezca a lo que la persona está mirando, que es
   * justamente lo que un reporte no puede hacer.
   */
  async function exportarExcel() {
    try {
      if (exportaPlanilla) {
        await descargarPlanillaExcel(planillas);
      } else {
        await descargarExcel({ nombreArchivo, hoja: "Asistencias", columnas, filas: items });
      }
    } catch (error) {
      toast.error(MENSAJE_ERROR(error, "No se pudo generar el Excel"));
    }
  }

  // NO es async: las dos funciones de PDF abren la pestaña en su primera línea,
  // y los bloqueadores sólo dejan pasar el window.open que ocurre dentro del
  // click. Con un `await` antes, el navegador ya no lo asocia al gesto.
  function exportarPdf() {
    const promesa = exportaPlanilla
      ? abrirPlanillaPdf(planillas)
      : abrirPdf({
          nombreArchivo,
          titulo: "Reporte de asistencias",
          subtitulos,
          columnas,
          filas: items,
          orientacion: "landscape",
        });
    promesa.catch((error) => toast.error(MENSAJE_ERROR(error, "No se pudo generar el PDF")));
  }

  const anios = Array.from({ length: 6 }, (_, i) => hoy.getFullYear() - 4 + i);
  const sinDatos = !asistencias.isPending && !asistencias.isError && items.length === 0;

  return (
    <AppLayout active="/asistencias" title="Asistencias">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Asistencias</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Marcaciones de profesores por período. Es una consulta: no da de alta ni edita.
            </p>
          </div>
          {/* El título dice qué formato sale, que depende de la vista activa:
              exportar algo distinto de lo que se está mirando es lo que un
              reporte no puede hacer. */}
          <div className="flex gap-2">
            <Button onClick={abrirAlta} disabled={empresa === null}>
              <Plus className="size-4" />
              Nueva marcación
            </Button>
            <Button
              variant="outline"
              onClick={exportarExcel}
              disabled={exportarBloqueado}
              title={
                exportaPlanilla
                  ? planillas.length > 1
                    ? `Una planilla por profesor (${planillas.length}) en Excel`
                    : "Planilla del mes en Excel"
                  : "Listado de marcaciones en Excel"
              }
            >
              <FileSpreadsheet className="size-4" />
              Excel
            </Button>
            <Button
              variant="outline"
              onClick={exportarPdf}
              disabled={exportarBloqueado}
              title={
                exportaPlanilla
                  ? planillas.length > 1
                    ? `Una planilla por profesor (${planillas.length}) en PDF`
                    : "Planilla del mes en PDF"
                  : "Listado de marcaciones en PDF"
              }
            >
              <FileText className="size-4" />
              PDF
            </Button>
          </div>
        </div>

        {/* Filtros y parámetros del cálculo, juntos: los cinco cambian lo que se
            ve, y separarlos obligaría a buscar en dos lugares por qué cambió un
            total. */}
        <div className="surface-card grid gap-3 p-4 sm:grid-cols-2 lg:grid-cols-6">
          <label className="space-y-1.5">
            <span className="text-xs font-medium text-muted-foreground">Año</span>
            <Select value={anio} onValueChange={setAnio}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {anios.map((a) => (
                  <SelectItem key={a} value={String(a)}>
                    {a}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </label>

          <label className="space-y-1.5">
            <span className="text-xs font-medium text-muted-foreground">Mes</span>
            <Select value={mes} onValueChange={setMes}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {MESES.map((nombre, i) => (
                  <SelectItem key={nombre} value={String(i + 1)}>
                    {nombre}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </label>

          <label className="space-y-1.5">
            <span className="text-xs font-medium text-muted-foreground">Institución</span>
            <Select value={idInstitucion} onValueChange={setIdInstitucion}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={TODOS}>Todas las instituciones</SelectItem>
                {institucionesConMarcas.map((i) => (
                  <SelectItem key={i.id} value={String(i.id)}>
                    {i.nombre}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </label>

          <label className="space-y-1.5">
            <span className="text-xs font-medium text-muted-foreground">Profesor</span>
            <Select value={idProfesor} onValueChange={setIdProfesor}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={TODOS}>Todos los profesores</SelectItem>
                {profesoresConMarcas.map((p) => (
                  <SelectItem key={p.id} value={String(p.id)}>
                    {p.nombre}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </label>

          <label className="space-y-1.5">
            <span className="text-xs font-medium text-muted-foreground">Hora cátedra (min)</span>
            <Input
              type="number"
              min={1}
              max={120}
              value={duracionCatedra}
              onChange={(e) => setDuracionCatedra(e.target.value)}
              placeholder="60"
            />
          </label>

          <label className="space-y-1.5">
            <span className="text-xs font-medium text-muted-foreground">Precio por hora</span>
            {/* InputMoneda y no un <input number>: separa los miles mientras se
                escribe. Number("60.000") daría 60, mil veces menos. */}
            <InputMoneda value={precioHora} onChange={setPrecioHora} placeholder="60.000" />
          </label>
        </div>

        {asistencias.isPending && (
          <div className="space-y-2">
            {[0, 1, 2, 3].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        )}

        {asistencias.isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
            {MENSAJE_ERROR(asistencias.error, "No se pudieron cargar las asistencias")}
          </p>
        )}

        {!asistencias.isPending && !asistencias.isError && (
          <>
            {/* Los KPI del período. Van arriba de la grilla porque son la
                respuesta a "cuánto se le paga", que es a lo que se entra. */}
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <Kpi
                icono={<Clock className="size-4" />}
                etiqueta="Horas trabajadas"
                valor={totales.horas.toFixed(2)}
                detalle={`${formatearDuracion(totales.minutos)} reloj`}
              />
              <Kpi
                icono={<CalendarDays className="size-4" />}
                etiqueta="Días con marca"
                valor={String(totales.dias)}
                detalle={`${items.length} marcación(es)`}
              />
              <Kpi
                icono={<FileText className="size-4" />}
                etiqueta="Importe total"
                valor={formatearMoneda(Math.round(totales.importe))}
                detalle={
                  precio > 0
                    ? `IVA incluido: ${formatearMoneda(Math.round(totales.iva))}`
                    : "Cargá el precio por hora"
                }
              />
              <Kpi
                icono={<AlertTriangle className="size-4" />}
                etiqueta="Incompletas"
                valor={String(totales.incompletas)}
                detalle={totales.incompletas > 0 ? "Entrada sin salida" : "Todo cerrado"}
                alerta={totales.incompletas > 0}
              />
            </div>

            {sinDatos ? (
              <div className="surface-card px-3 py-16 text-center">
                <p className="text-sm text-muted-foreground">
                  No hay marcaciones para {nombreProfesor.toLowerCase()} en{" "}
                  {nombreInstitucion.toLowerCase()} en {periodo}.
                </p>
              </div>
            ) : (
              <>
                <div className="flex items-center justify-between gap-3">
                  <p className="text-sm text-muted-foreground">
                    {nombreProfesor} · {nombreInstitucion} · {periodo}
                  </p>
                  {/* Dos vistas de lo mismo: la planilla se imprime y se firma;
                      el detalle sirve para revisar y auditar. */}
                  <div className="flex gap-1 rounded-lg border border-border p-1">
                    <Button
                      variant={vista === "planilla" ? "secondary" : "ghost"}
                      size="sm"
                      onClick={() => setVista("planilla")}
                    >
                      <LayoutGrid className="size-4" />
                      Planilla
                    </Button>
                    <Button
                      variant={vista === "detalle" ? "secondary" : "ghost"}
                      size="sm"
                      onClick={() => setVista("detalle")}
                    >
                      <Table2 className="size-4" />
                      Detalle
                    </Button>
                  </div>
                </div>

                {/* Con varios profesores la exportación ya no se bloquea: sale
                    una planilla por cada uno. Se avisa igual porque la pantalla
                    muestra la grilla mezclada y el archivo NO — sin esto, la
                    diferencia entre lo que se ve y lo que se baja sorprende. */}
                {exportaPlanilla && planillas.length > 1 && (
                  <p className="flex items-center gap-2 rounded-lg border border-border bg-muted px-3 py-2 text-sm text-muted-foreground">
                    <AlertTriangle className="size-4 shrink-0 text-warning" />
                    Hay {planillas.length} profesores en el período: al exportar sale una planilla
                    para cada uno, en un solo archivo. Elegí un profesor arriba para ver su grilla
                    sola.
                  </p>
                )}

                {vista === "planilla" ? (
                  <Planilla
                    dias={diasDelMes}
                    porDia={porDia}
                    maxMarcas={maxMarcas}
                    catedra={catedra}
                  />
                ) : (
                  <Detalle
                    items={items}
                    catedra={catedra}
                    precio={precio}
                    onEditar={abrirEdicion}
                    onEliminar={setAEliminar}
                  />
                )}
              </>
            )}
          </>
        )}

        {empresa !== null && (
          <MarcacionDialog
            abierto={dialogoAbierto}
            onCerrar={() => setDialogoAbierto(false)}
            marcacion={editando}
            idEmpresa={empresa.id}
            // Los combos del diálogo ofrecen el catálogo del período, igual que
            // los filtros. Para un alta de un profesor que todavía no marcó
            // nunca hay que elegir un mes donde sí aparezca — es la
            // contrapartida de no traer los catálogos completos.
            profesores={profesoresConMarcas}
            instituciones={institucionesConMarcas}
            fechaSugerida={fechaSugerida}
          />
        )}

        <AlertDialog open={aEliminar !== null} onOpenChange={(v) => !v && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar la marcación?</AlertDialogTitle>
              <AlertDialogDescription>
                {aEliminar
                  ? `${aEliminar.profesor} · ${aEliminar.fecha} · ${aEliminar.horaEntrada ?? "sin entrada"} a ${aEliminar.horaSalida ?? "sin salida"}. Esta acción no se puede deshacer.`
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

function Kpi({
  icono,
  etiqueta,
  valor,
  detalle,
  alerta,
}: {
  icono: React.ReactNode;
  etiqueta: string;
  valor: string;
  detalle: string;
  alerta?: boolean;
}) {
  return (
    <div className="surface-card p-4">
      <div className="flex items-center gap-2 text-muted-foreground">
        <span className={alerta ? "text-warning" : "text-primary"}>{icono}</span>
        <span className="text-xs font-medium">{etiqueta}</span>
      </div>
      <p className={`mt-2 text-2xl font-bold ${alerta ? "text-warning" : "text-foreground"}`}>
        {valor}
      </p>
      <p className="mt-0.5 text-xs text-muted-foreground">{detalle}</p>
    </div>
  );
}

/**
 * La grilla del mes: una fila por día, con los pares Ent./Sal. al costado.
 *
 * Muestra TODOS los días —incluidos los sin marca— porque es la vista que se
 * imprime y se firma: un día faltante tiene que verse como un hueco, no
 * desaparecer de la planilla.
 *
 * Las columnas de marcación son las que el mes realmente usa, no doce fijas:
 * con doce, diez salen vacías en un mes normal y la grilla se vuelve ilegible.
 */
function Planilla({
  dias,
  porDia,
  maxMarcas,
  catedra,
}: {
  dias: Array<{ dia: number; iso: string; diaSemana: number }>;
  porDia: Map<string, AsistenciaProfesor[]>;
  maxMarcas: number;
  catedra: number;
}) {
  return (
    <div className="surface-card overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-20">Día</TableHead>
            <TableHead className="w-24">Fecha</TableHead>
            {Array.from({ length: maxMarcas }, (_, i) => (
              <TableHead key={i} className="text-center" colSpan={2}>
                {i + 1}
              </TableHead>
            ))}
            <TableHead className="text-right">Horas</TableHead>
          </TableRow>
          <TableRow>
            <TableHead />
            <TableHead />
            {Array.from({ length: maxMarcas }, (_, i) => [
              <TableHead key={`e${i}`} className="text-center text-xs font-normal">
                Ent.
              </TableHead>,
              <TableHead key={`s${i}`} className="text-center text-xs font-normal">
                Sal.
              </TableHead>,
            ])}
            <TableHead />
          </TableRow>
        </TableHeader>
        <TableBody>
          {dias.map(({ dia, iso, diaSemana }) => {
            const marcas = porDia.get(iso) ?? [];
            const finDeSemana = diaSemana === 0 || diaSemana === 6;
            const minutos = marcas.reduce((s, m) => s + (m.minutos ?? 0), 0);
            const horas = minutos > 0 ? aHorasCatedra(minutos, catedra) : 0;

            return (
              <TableRow
                key={iso}
                // El fin de semana en gris: sin marcarlo, un sábado vacío se lee
                // igual que un día laboral sin marcar, que sí es un problema.
                className={finDeSemana ? "bg-muted/40" : undefined}
              >
                <TableCell className="text-xs text-muted-foreground">{DIAS[diaSemana]}</TableCell>
                <TableCell className="font-medium">{dia}</TableCell>
                {Array.from({ length: maxMarcas }, (_, i) => {
                  const m = marcas[i];
                  return [
                    <TableCell key={`e${i}`} className="text-center text-sm tabular-nums">
                      {m?.horaEntrada ?? ""}
                      {m?.entradaOffline === "S" && <IconoOffline />}
                    </TableCell>,
                    <TableCell key={`s${i}`} className="text-center text-sm tabular-nums">
                      {m && m.horaEntrada && !m.horaSalida ? (
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <AlertTriangle className="mx-auto size-4 text-warning" />
                          </TooltipTrigger>
                          <TooltipContent>Entró y no marcó salida</TooltipContent>
                        </Tooltip>
                      ) : (
                        <>
                          {m?.horaSalida ?? ""}
                          {m?.salidaOffline === "S" && <IconoOffline />}
                        </>
                      )}
                    </TableCell>,
                  ];
                })}
                <TableCell className="text-right font-medium tabular-nums">
                  {horas > 0 ? horas.toFixed(2) : ""}
                </TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
    </div>
  );
}

/** Marca que la hora vino del teléfono sin conexión, no del servidor. */
function IconoOffline() {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <WifiOff className="ml-1 inline size-3 text-muted-foreground" />
      </TooltipTrigger>
      <TooltipContent>Marcado sin conexión: la hora es la del teléfono</TooltipContent>
    </Tooltip>
  );
}

/** Una fila por marcación, con institución, ubicación e importe. */
function Detalle({
  items,
  catedra,
  precio,
  onEditar,
  onEliminar,
}: {
  items: AsistenciaProfesor[];
  catedra: number;
  precio: number;
  onEditar: (a: AsistenciaProfesor) => void;
  onEliminar: (a: AsistenciaProfesor) => void;
}) {
  return (
    <div className="surface-card overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Fecha</TableHead>
            <TableHead>Profesor</TableHead>
            <TableHead>Institución</TableHead>
            <TableHead className="text-center">Entrada</TableHead>
            <TableHead className="text-center">Salida</TableHead>
            <TableHead className="text-right">Horas</TableHead>
            <TableHead className="text-right">Importe</TableHead>
            <TableHead className="text-center">Ubic.</TableHead>
            <TableHead className="text-right">Acciones</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {items.map((a) => {
            const horas = a.minutos === null ? null : aHorasCatedra(a.minutos, catedra);
            return (
              <TableRow key={a.id}>
                <TableCell className="whitespace-nowrap">
                  <span className="font-medium">{a.fecha}</span>
                  <span className="ml-1.5 text-xs text-muted-foreground">
                    {DIAS[fechaLocal(a.fecha).getDay()]}
                  </span>
                </TableCell>
                <TableCell>
                  <span className="font-medium text-foreground">{a.profesor}</span>
                  <span className="ml-1.5 text-xs text-muted-foreground">{a.numeroCi}</span>
                </TableCell>
                <TableCell className="text-muted-foreground">{a.institucion ?? "—"}</TableCell>
                <TableCell className="text-center tabular-nums">
                  {a.horaEntrada ?? "—"}
                  {a.entradaOffline === "S" && <IconoOffline />}
                </TableCell>
                <TableCell className="text-center tabular-nums">
                  {a.horaSalida ?? "—"}
                  {a.salidaOffline === "S" && <IconoOffline />}
                </TableCell>
                <TableCell className="text-right tabular-nums">
                  {horas === null ? (
                    <Badge variant="outline" className="text-warning">
                      Incompleta
                    </Badge>
                  ) : (
                    horas.toFixed(2)
                  )}
                </TableCell>
                <TableCell className="text-right tabular-nums">
                  {horas === null ? "—" : formatearMoneda(Math.round(horas * precio))}
                </TableCell>
                <TableCell className="text-center">
                  {a.latitud && a.longitud ? (
                    <a
                      href={`https://www.google.com/maps?q=${a.latitud},${a.longitud}`}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-primary hover:underline"
                      title={a.marcadoEnEntrada ?? "Ver en el mapa"}
                    >
                      <MapPin className="mx-auto size-4" />
                    </a>
                  ) : (
                    <span className="text-muted-foreground">—</span>
                  )}
                </TableCell>
                <TableCell className="text-right">
                  <div className="flex justify-end gap-1">
                    <Button
                      variant="ghost"
                      size="icon"
                      onClick={() => onEditar(a)}
                      title="Editar la marcación"
                    >
                      <Pencil className="size-4" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      onClick={() => onEliminar(a)}
                      title="Eliminar la marcación"
                      className="text-destructive hover:text-destructive"
                    >
                      <Trash2 className="size-4" />
                    </Button>
                  </div>
                </TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
    </div>
  );
}
