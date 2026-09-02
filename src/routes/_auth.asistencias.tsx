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
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
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
  descargarExcel,
  descargarPlanillaExcel,
  type ColumnaExport,
  type DatosPlanilla,
} from "@/lib/exportar";
import { tituloPagina } from "@/lib/marca";
import { cn } from "@/lib/utils";
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
 * El mismo orden, con el nombre completo.
 *
 * La grilla usa la forma corta porque ahí manda el ancho de la columna; el
 * título del modal del día tiene lugar de sobra, y "Jueves" se lee mejor que
 * "Jue" cuando es lo primero que aparece al abrirlo.
 */
const DIAS_LARGOS = ["Domingo", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado"];

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

/** Minutos que dura una hora cátedra cuando el profesor no tiene otro valor. */
const CATEDRA_POR_DEFECTO = "60";

/**
 * Precio por hora de arranque.
 *
 * Formateado como lo escribe `InputMoneda`, con el separador de miles: el
 * componente lee su propio formato, y un "60000" pelado se mostraría sin punto.
 *
 * Con el campo vacío, la columna Importe y el resumen del pie arrancaban en cero
 * — una planilla completa diciendo que no se le debe nada a nadie.
 */
const PRECIO_POR_DEFECTO = "60.000";

export const Route = createFileRoute("/_auth/asistencias")({
  head: () => ({
    meta: [
      { title: tituloPagina("Asistencias") },
      {
        name: "description",
        content: "Reporte de asistencias de profesores, con exportación a Excel.",
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

  /**
   * El día cuyo modal está abierto, en ISO, o `null`.
   *
   * Es la puerta a las acciones desde la planilla: la vista que se mira para
   * liquidar es esta, y es donde se ve el problema —un día en blanco, una
   * entrada sin salida—, pero hasta ahora había que cambiar a Detalle y buscar
   * la fila entre las del mes entero para poder corregirlo.
   */
  const [diaAbierto, setDiaAbierto] = useState<string | null>(null);

  /**
   * Con qué fecha arranca el alta: la del día que se abrió, si vino de ahí.
   *
   * En `null` cae en `fechaSugerida`, que es el comportamiento del botón de
   * arriba. Se guarda aparte y no se lee `diaAbierto` porque son cosas
   * distintas: el modal del día puede quedar abierto detrás mientras se carga,
   * y el alta ya tiene su fecha decidida desde que se abrió.
   */
  const [fechaAlta, setFechaAlta] = useState<string | null>(null);

  /**
   * Hora cátedra y precio, **por profesor**.
   *
   * No hay un valor global: no todos los profesores tienen la misma carga —uno
   * da cátedras de 45 minutos y otro de 60 en el mismo período— ni cobran lo
   * mismo, así que un único campo arriba haría que el total de alguno salga mal
   * sin que nada lo avise. Cada planilla trae los suyos en su encabezado.
   *
   * Quien no está en el mapa usa `CATEDRA_POR_DEFECTO` / `PRECIO_POR_DEFECTO`,
   * que es lo que se ve al abrir la pantalla.
   *
   * Viven acá y no en la base: `PROFESORES` no tiene columna para esto (ver la
   * nota de `db/asistencias-profesores.sql`) y agregarla es un cambio de DDL.
   * Se pierden al recargar.
   */
  const [catedraPorProfesor, setCatedraPorProfesor] = useState<Record<number, string>>({});
  const [precioPorProfesor, setPrecioPorProfesor] = useState<Record<number, string>>({});

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

  /**
   * Los meses que tienen marcaciones, para no ofrecer meses vacíos.
   *
   * Endpoint propio y no `listar` sin mes: para saber qué meses del año tienen
   * datos habría que traer el año entero —miles de marcaciones— y contarlas
   * acá. Esto devuelve una fila por mes.
   *
   * Se pide una vez por empresa y no por período: la respuesta ya trae todos
   * los años, así que cambiar de año no dispara otra consulta.
   *
   * La queryKey arranca con "asistencias" —y no con una propia— para que el
   * `invalidateQueries(["asistencias"])` del alta y de la baja también la
   * refresque: sin eso, la primera marcación de un mes nuevo no aparecería en
   * el combo hasta recargar la página. Las keys se comparan elemento por
   * elemento, así que "asistencias-periodos" no habría entrado en ese prefijo.
   */
  const periodos = useQuery({
    queryKey: ["asistencias", "periodos", empresa?.id ?? null],
    queryFn: () => api.asistenciasProfesores.periodos(empresa!.id),
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

  const itemsPeriodos = useMemo(() => periodos.data?.items ?? [], [periodos.data?.items]);

  /**
   * Los años que tienen marcaciones.
   *
   * Salen de la tabla y NO de un rango alrededor de hoy: un combo con seis años
   * fijos obliga a probarlos de a uno para encontrar dónde hay datos, y un año
   * vacío no se distingue de un filtro mal puesto.
   *
   * Tampoco se agrega el año en curso cuando no tiene marcaciones: la lista es
   * lo que hay cargado, sin excepciones.
   */
  const aniosDisponibles = useMemo(
    () => [...new Set(itemsPeriodos.map((p) => p.anio))].sort((a, b) => b - a),
    [itemsPeriodos],
  );

  /** Los meses con marcaciones del año elegido, de enero a diciembre. */
  const mesesDisponibles = useMemo(
    () =>
      [...new Set(itemsPeriodos.filter((p) => String(p.anio) === anio).map((p) => p.mes))].sort(
        (a, b) => a - b,
      ),
    [itemsPeriodos, anio],
  );

  /**
   * El período arranca en hoy, que puede no tener ninguna marcación.
   *
   * Cuando el año o el mes elegidos no están entre los que hay cargados, se cae
   * al más reciente con datos. Sin esto la pantalla abre vacía sobre un mes que
   * el propio combo ya no ofrece, y no hay forma de saber dónde sí hay algo.
   *
   * Es el mismo patrón que corrige la institución y el profesor unas líneas más
   * abajo: se ajusta el estado en el render, sin pedir nada.
   */
  const anioFueraDeLista = aniosDisponibles.length > 0 && !aniosDisponibles.includes(Number(anio));
  if (anioFueraDeLista) setAnio(String(aniosDisponibles[0]));

  // El `!anioFueraDeLista` importa: en el render en que el año todavía es el
  // viejo, `mesesDisponibles` es el del año viejo y el mes saltaría a un valor
  // que el año nuevo no tiene.
  const mesFueraDeLista =
    !anioFueraDeLista && mesesDisponibles.length > 0 && !mesesDisponibles.includes(Number(mes));
  if (mesFueraDeLista) setMes(String(mesesDisponibles[mesesDisponibles.length - 1]));

  /**
   * La hora cátedra y el precio que le corresponden a un profesor: los suyos, o
   * los de arranque si todavía no se los tocó.
   *
   * Son funciones y no dos mapas ya resueltos porque las usan tanto el cálculo
   * de las grillas como el del Excel y el de los KPI, y así los tres preguntan
   * lo mismo en vez de repetir el `??`.
   */
  const catedraDe = (idProfesor: number) =>
    Number(catedraPorProfesor[idProfesor] ?? CATEDRA_POR_DEFECTO) || 60;

  const precioDe = (idProfesor: number) =>
    numeroMoneda(precioPorProfesor[idProfesor] ?? PRECIO_POR_DEFECTO) || 0;

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
    // Los minutos de cada profesor por separado: cada uno se convierte con SU
    // hora cátedra y se cobra a SU precio. Sumar todo con un solo valor daría un
    // total que no coincide con la suma de las planillas — que es el número que
    // alguien va a controlar.
    const minutosPorProfesor = new Map<number, number>();

    for (const a of items) {
      if (a.minutos === null) incompletas += 1;
      else {
        minutos += a.minutos;
        dias.add(a.fecha);
        minutosPorProfesor.set(
          a.idProfesor,
          (minutosPorProfesor.get(a.idProfesor) ?? 0) + a.minutos,
        );
      }
    }

    let horas = 0;
    let importe = 0;
    for (const [idProfesor, m] of minutosPorProfesor) {
      const suyas = aHorasCatedra(m, catedraDe(idProfesor));
      horas += suyas;
      importe += suyas * precioDe(idProfesor);
    }
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items, catedraPorProfesor, precioPorProfesor]);

  /** Las marcaciones de cada día, para el modal del día y el conteo de columnas. */
  const porDia = useMemo(() => {
    const mapa = new Map<string, AsistenciaProfesor[]>();
    for (const a of items) {
      const lista = mapa.get(a.fecha);
      if (lista) lista.push(a);
      else mapa.set(a.fecha, [a]);
    }
    return mapa;
  }, [items]);

  /**
   * Las marcaciones agrupadas POR PROFESOR, cada una con su propio mapa por día.
   *
   * **Una planilla es de una persona.** Si en la institución marcaron tres
   * profesores, la pantalla muestra tres grillas apiladas y no una sola con las
   * marcas mezcladas: en la grilla mezclada, un día con dos entradas puede ser
   * un profesor que entró y salió dos veces o dos profesores distintos, y el
   * papel que se firma no permite esa ambigüedad. Además el total del pie sería
   * la suma de todos, que no es lo que nadie cobra.
   *
   * Es la misma agrupación que ya hacía `planillas` para el Excel — de hecho
   * era la diferencia que el aviso de "sale una planilla para cada uno" tenía
   * que explicar. Ahora la pantalla y el archivo muestran lo mismo.
   *
   * Orden alfabético, como el Excel y el cuadro de resumen por profesor.
   */
  const grillasPorProfesor = useMemo(() => {
    const porProfesor = new Map<number, AsistenciaProfesor[]>();
    for (const a of items) {
      const lista = porProfesor.get(a.idProfesor);
      if (lista) lista.push(a);
      else porProfesor.set(a.idProfesor, [a]);
    }

    return [...porProfesor.entries()]
      .map(([idProfesor, marcas]) => {
        const dias = new Map<string, AsistenciaProfesor[]>();
        for (const a of marcas) {
          const lista = dias.get(a.fecha);
          if (lista) lista.push(a);
          else dias.set(a.fecha, [a]);
        }
        return {
          idProfesor,
          // Los suyos, o los globales si no tiene propios. Van acá para que la
          // grilla, su pie y el Excel usen todos el mismo número.
          catedra: catedraDe(idProfesor),
          precio: precioDe(idProfesor),
          profesor: marcas[0]?.profesor ?? "—",
          // De las marcas y no del filtro: sin filtro de institución, dice en
          // cuáles estuvo realmente esta persona.
          institucion:
            [...new Set(marcas.map((a) => a.institucion).filter(Boolean))].join(" · ") || "—",
          marcas,
          porDia: dias,
          // POR PROFESOR y no el máximo global: si otro tuvo cuatro marcas en un
          // día, no tiene por qué agregar dos columnas vacías a esta grilla.
          maxMarcas: Math.max(2, ...[...dias.values()].map((l) => l.length)),
        };
      })
      .sort((a, b) => a.profesor.localeCompare(b.profesor, "es"));
    // Los mapas de overrides y los globales entran como dependencia: cambiar
    // cualquiera de los cuatro cambia los totales de las grillas.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items, catedraPorProfesor, precioPorProfesor]);

  /**
   * Cuánto le corresponde a cada profesor: el consolidado del pie.
   *
   * Sale de `grillasPorProfesor` y no de `items` otra vez para que las dos cosas
   * no puedan discrepar — es la misma gente, en el mismo orden, con las mismas
   * marcas que se ven en las grillas de arriba.
   *
   * Se suman los MINUTOS de cada uno y recién ahí se convierte a horas cátedra,
   * por lo mismo que los totales por semana: redondear antes de sumar haría que
   * la fila no cierre contra el pie de su propia planilla.
   */
  const resumenPorProfesor = useMemo(
    () =>
      grillasPorProfesor.map((g) => {
        const minutos = g.marcas.reduce((s, a) => s + (a.minutos ?? 0), 0);
        return {
          profesor: g.profesor,
          // CON LA CÁTEDRA Y EL PRECIO DE CADA UNO, no los globales: si dos
          // profesores tienen cátedras distintas, usar un solo valor haría que
          // el consolidado no coincida con el pie de sus propias planillas.
          monto: Math.round((minutos > 0 ? aHorasCatedra(minutos, g.catedra) : 0) * g.precio),
        };
      }),
    [grillasPorProfesor],
  );

  /** Todos los días del mes elegido, haya o no marcaciones. */
  const diasDelMes = useMemo(() => {
    const total = new Date(Number(anio), Number(mes), 0).getDate();
    return Array.from({ length: total }, (_, i) => {
      const fecha = new Date(Number(anio), Number(mes) - 1, i + 1);
      const iso = `${anio}-${String(mes).padStart(2, "0")}-${String(i + 1).padStart(2, "0")}`;
      return { dia: i + 1, iso, diaSemana: fecha.getDay() };
    });
  }, [anio, mes]);

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
        a.minutos === null
          ? null
          : Number(aHorasCatedra(a.minutos, catedraDe(a.idProfesor)).toFixed(2)),
      numerica: true,
      ancho: 10,
    },
    {
      // "Gs." en el título y el número PELADO, sin separadores: así entra en
      // Excel como número y la columna se puede sumar. Formatearlo lo volvería
      // texto.
      titulo: "Importe Gs.",
      valor: (a) =>
        a.minutos === null
          ? null
          : Math.round(aHorasCatedra(a.minutos, catedraDe(a.idProfesor)) * precioDe(a.idProfesor)),
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
  const planillas: DatosPlanilla[] = useMemo(
    () =>
      // SALE DE LA MISMA AGRUPACIÓN QUE LAS GRILLAS de la pantalla, no de una
      // propia: son las mismas personas, en el mismo orden, con las mismas
      // marcas y el mismo conteo de columnas. Cuando eran dos agrupaciones
      // paralelas, la pantalla mostraba una grilla mezclada y el archivo salía
      // separado por profesor — una diferencia que hubo que explicar con un
      // aviso en pantalla.
      grillasPorProfesor.map((g) => {
        // Los totales son de ESTE profesor: los de la pantalla son del período
        // entero y acá firma una sola persona.
        let minutosTotales = 0;
        for (const a of g.marcas) minutosTotales += a.minutos ?? 0;
        // CON LOS VALORES DE ESTE PROFESOR, no los globales: puede tener una
        // hora catedra distinta de la del resto.
        const horas = aHorasCatedra(minutosTotales, g.catedra);
        const importe = horas * g.precio;

        // Las mismas filas de la grilla, y de paso los minutos de cada semana.
        // Se acumulan en minutos y se convierten al final, igual que en la
        // pantalla: sumando las horas ya redondeadas de cada día, el total de la
        // semana no cerraría contra su propia columna.
        const minutosPorSemana = new Map<number, number>();
        const filas = agruparPorSemana(diasDelMes).map(({ dia, iso, diaSemana, semana }) => {
          const marcas = g.porDia.get(iso) ?? [];
          const minutos = marcas.reduce((s, m) => s + (m.minutos ?? 0), 0);
          minutosPorSemana.set(semana, (minutosPorSemana.get(semana) ?? 0) + minutos);
          return {
            semana,
            dia,
            diaSemana: DIAS[diaSemana] ?? "",
            marcas: marcas.map((m) => ({ entrada: m.horaEntrada, salida: m.horaSalida })),
            horas: minutos > 0 ? Number(aHorasCatedra(minutos, g.catedra).toFixed(2)) : 0,
            finDeSemana: diaSemana === 0 || diaSemana === 6,
          };
        });

        return {
          profesor: g.profesor,
          institucion: g.institucion,
          periodo,
          horaCatedra: g.catedra,
          precioHora: g.precio,
          columnasMarca: g.maxMarcas,
          filas,
          horasPorSemana: new Map(
            [...minutosPorSemana].map(([s, m]) => [
              s,
              m > 0 ? Number(aHorasCatedra(m, g.catedra).toFixed(2)) : 0,
            ]),
          ),
          totalHoras: Number(horas.toFixed(2)),
          totalImporte: importe,
          // El IVA se DESGLOSA de un precio que ya lo incluye, igual que en el
          // resto del sistema. Mismo criterio que `totales`.
          totalIva: importe - Math.round((importe / 1.1) * 100) / 100,
          nombreEmpresa: empresa?.nombreEmpresa ?? "",
          // Seis renglones en blanco: el bloque no sale de la base y se completa
          // a mano sobre el papel. Los mismos que muestra la pantalla.
          filasActividadExtra: 6,
        };
      }),
    [grillasPorProfesor, periodo, diasDelMes, empresa],
  );

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

  function abrirAlta(fecha?: string) {
    setEditando(null);
    setFechaAlta(fecha ?? null);
    setDialogoAbierto(true);
  }

  function abrirEdicion(a: AsistenciaProfesor) {
    setEditando(a);
    setDialogoAbierto(true);
  }

  /** "Jueves 12 de junio de 2026", para el encabezado del modal del día. */
  const tituloDia = useMemo(() => {
    if (diaAbierto === null) return "";
    const d = fechaLocal(diaAbierto);
    return `${DIAS_LARGOS[d.getDay()]} ${d.getDate()} de ${MESES[d.getMonth()]?.toLowerCase()} de ${d.getFullYear()}`;
  }, [diaAbierto]);

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

  const sinDatos = !asistencias.isPending && !asistencias.isError && items.length === 0;

  return (
    <AppLayout active="/asistencias" title="Asistencias">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Asistencias</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Marcaciones de profesores por período. Tocá un día de la planilla para corregirlo.
            </p>
          </div>
          {/* El título dice QUÉ sale, que depende de la vista activa: exportar
              algo distinto de lo que se está mirando es lo que un reporte no
              puede hacer. */}
          <div className="flex gap-2">
            <Button onClick={() => abrirAlta()} disabled={empresa === null}>
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
                {aniosDisponibles.map((a) => (
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
                {mesesDisponibles.map((n) => (
                  <SelectItem key={n} value={String(n)}>
                    {MESES[n - 1]}
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
        </div>

        {periodos.isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-3 text-center text-sm text-destructive">
            No se pudieron cargar los períodos con marcaciones, así que los combos de año y mes
            quedan vacíos. {MENSAJE_ERROR(periodos.error, "Reintentá en unos segundos")}
          </p>
        )}

        {!periodos.isPending && !periodos.isError && aniosDisponibles.length === 0 && (
          <p className="rounded-lg border border-border bg-muted px-3 py-6 text-center text-sm text-muted-foreground">
            No hay ninguna marcación cargada para esta empresa.
          </p>
        )}

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
                  totales.importe > 0
                    ? `IVA incluido: ${formatearMoneda(Math.round(totales.iva))}`
                    : "Cargá el precio por hora en cada planilla"
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

                {vista === "planilla" ? (
                  /* UNA PLANILLA POR PROFESOR, apiladas. Ya no hace falta el
                     aviso de que el archivo sale distinto de la pantalla:
                     ahora muestran lo mismo. */
                  <div className="space-y-6">
                    {grillasPorProfesor.map((g) => (
                      <section key={g.idProfesor} className="space-y-2">
                        {/* Nombre a la izquierda y los dos parámetros del
                            cálculo a la derecha, como el encabezado del Excel.

                            LOS CAMPOS VAN POR PROFESOR: no todos tienen la misma
                            hora cátedra —45 minutos en un colegio, 60 en otro— y
                            con un solo valor global el total de horas de alguno
                            sale mal. Arrancan en el valor de arriba y sólo se
                            tocan los que difieren. */}
                        <div className="flex flex-wrap items-end justify-between gap-3">
                          <h2 className="text-sm font-semibold text-foreground">
                            {g.profesor}
                            <span className="ml-2 font-normal text-muted-foreground">
                              {g.institucion}
                            </span>
                          </h2>
                          <div className="flex items-end gap-2">
                            <label className="space-y-1">
                              <span className="block text-xs font-medium text-muted-foreground">
                                Hora cátedra (min)
                              </span>
                              <Input
                                type="number"
                                min={1}
                                className="h-8 w-24"
                                value={catedraPorProfesor[g.idProfesor] ?? CATEDRA_POR_DEFECTO}
                                onChange={(e) =>
                                  setCatedraPorProfesor((previo) => ({
                                    ...previo,
                                    [g.idProfesor]: e.target.value,
                                  }))
                                }
                              />
                            </label>
                            <label className="space-y-1">
                              <span className="block text-xs font-medium text-muted-foreground">
                                Precio por hora
                              </span>
                              {/* InputMoneda y no un `type="number"`: es un
                                  monto, y va con separador de miles como todo
                                  importe del sistema. */}
                              <InputMoneda
                                className="h-8 w-32"
                                value={precioPorProfesor[g.idProfesor] ?? PRECIO_POR_DEFECTO}
                                onChange={(valor) =>
                                  setPrecioPorProfesor((previo) => ({
                                    ...previo,
                                    [g.idProfesor]: valor,
                                  }))
                                }
                              />
                            </label>
                          </div>
                        </div>
                        <Planilla
                          dias={diasDelMes}
                          porDia={g.porDia}
                          maxMarcas={g.maxMarcas}
                          catedra={g.catedra}
                          precio={g.precio}
                          nombreEmpresa={empresa?.nombreEmpresa ?? ""}
                          onAbrirDia={setDiaAbierto}
                        />
                      </section>
                    ))}

                    {/* AL FINAL DE TODAS, y sólo con más de un profesor: es el
                        consolidado del período, no el pie de ninguna planilla en
                        particular. Cada planilla ya cierra con su propio total,
                        y éste dice cuánto se paga en conjunto. */}
                    {resumenPorProfesor.length > 1 && (
                      <div className="flex justify-center pt-2">
                        <ResumenPorProfesor filas={resumenPorProfesor} />
                      </div>
                    )}
                  </div>
                ) : (
                  <Detalle
                    items={items}
                    catedraDe={catedraDe}
                    precioDe={precioDe}
                    onEditar={abrirEdicion}
                    onEliminar={setAEliminar}
                  />
                )}
              </>
            )}
          </>
        )}

        {/* El modal del día queda ABAJO en el stack: al editar o eliminar desde
            acá, el diálogo correspondiente se abre encima y al cerrarse se
            vuelve a ver el día ya actualizado, sin tener que abrirlo de nuevo. */}
        <MarcacionesDelDia
          abierto={diaAbierto !== null}
          titulo={tituloDia}
          // Se lee de `porDia` en cada render y no de una copia: así, al borrar
          // una marcación, la lista de abajo se actualiza sola cuando la query
          // se invalida.
          marcas={diaAbierto !== null ? (porDia.get(diaAbierto) ?? []) : []}
          catedraDe={catedraDe}
          precioDe={precioDe}
          onCerrar={() => setDiaAbierto(null)}
          onEditar={abrirEdicion}
          onEliminar={setAEliminar}
          onAgregar={() => diaAbierto !== null && abrirAlta(diaAbierto)}
          puedeAgregar={empresa !== null}
        />

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
            fechaSugerida={fechaAlta ?? fechaSugerida}
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
 * Líneas verticales entre columnas, para toda una tabla de una vez.
 *
 * Va como selector sobre los descendientes y no como clase en cada
 * `<TableHead>` y `<TableCell>`: entre las dos grillas son casi treinta lugares
 * donde repetir lo mismo, y uno donde olvidarse.
 *
 * `:not(:last-child)` deja la última columna sin borde, que si no dibuja una
 * línea pegada al filo de la tarjeta. El color sale del reset global de
 * `styles.css`, que le da `--color-border` a todo: `border-r` solo alcanza, y
 * sigue al tema claro y oscuro sin tocar nada más.
 *
 * **OJO CON `rowSpan`**: `:last-child` mira las celdas QUE ESA FILA DECLARA, no
 * la columna en la que caen visualmente. En la planilla, las columnas de total
 * se declaran una vez y se estiran hacia abajo, así que en las filas
 * intermedias la última celda declarada es Horas y el selector se la saltea —
 * dejando la columna sin separador justo donde más se la sigue con el dedo.
 * Esas celdas llevan `border-r` explícito; ver `Planilla`.
 */
const COLUMNAS_DIVIDIDAS = "[&_th:not(:last-child)]:border-r [&_td:not(:last-child)]:border-r";

/**
 * Devuelve el borde inferior de la ÚLTIMA fila del cuerpo.
 *
 * `TableBody` trae `[&_tr:last-child]:border-0` y lo quita a propósito: en una
 * tarjeta ajustada, ese borde y el de `surface-card` se superponen y dibujan una
 * línea doble.
 *
 * Acá no se superponen. Estas dos grillas van dentro de un contenedor con
 * `overflow-x-auto`, y **cuando aparece la barra de scroll horizontal ésta ocupa
 * lugar dentro de la tarjeta**: el borde de abajo queda separado de la tabla y
 * la última fila se cierra igual. Sin barra —una tabla angosta, un mes de pocas
 * marcaciones— la fila termina pegada al borde y, sin su propia línea, se lee
 * como si le faltara: es más alta que las demás y no cierra.
 *
 * Por eso se lo devuelve. Va junto a `COLUMNAS_DIVIDIDAS` porque es el mismo
 * problema —los marcos de la grilla— y las dos tablas lo necesitan igual.
 */
const CIERRA_ULTIMA_FILA = "[&_tbody_tr:last-child]:border-b";

/**
 * Agrupa los días del mes en semanas, cortando los LUNES.
 *
 * La semana es la **del mes** (1 a 5 o 6), no la del año: en una planilla
 * mensual que se firma, "semana 3" se entiende solo, mientras que la semana ISO
 * —"semana 27"— obliga a un calendario para saber de qué días habla.
 *
 * La primera semana suele estar cortada: si el mes arranca un jueves, la
 * semana 1 tiene cuatro días. Se cuenta igual como semana, porque son los días
 * que efectivamente se trabajaron dentro de ese mes.
 *
 * Devuelve, por día, su número de semana y cuántos días tiene esa semana — lo
 * segundo es el `rowSpan` de la celda que los agrupa.
 */
function agruparPorSemana(dias: Array<{ dia: number; iso: string; diaSemana: number }>) {
  let semana = 1;
  const conSemana = dias.map((d, i) => {
    // `getDay()` da 1 para el lunes. El primer día del mes abre la semana 1 sea
    // el día que sea, de ahí el `i > 0`.
    if (i > 0 && d.diaSemana === 1) semana += 1;
    return { ...d, semana };
  });

  const cuantosDias = new Map<number, number>();
  for (const d of conSemana) cuantosDias.set(d.semana, (cuantosDias.get(d.semana) ?? 0) + 1);

  return conSemana.map((d, i) => ({
    ...d,
    // La celda se dibuja una sola vez por semana, en su primer día.
    abreSemana: i === 0 || conSemana[i - 1]?.semana !== d.semana,
    diasDeLaSemana: cuantosDias.get(d.semana) ?? 1,
    // Cuántas filas quedan hasta el final del mes, contando ésta: es el
    // `rowSpan` de la celda del total general, que se estira sobre toda la
    // grilla igual que la de la semana sobre sus días.
    diasHastaFinDeMes: conSemana.length - i,
  }));
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
  precio,
  nombreEmpresa,
  onAbrirDia,
}: {
  dias: Array<{ dia: number; iso: string; diaSemana: number }>;
  /**
   * Las marcaciones de UN profesor, por día.
   *
   * Una planilla es de una persona: la agrupación por profesor la hace la
   * página, que renderiza una de éstas por cada uno.
   */
  porDia: Map<string, AsistenciaProfesor[]>;
  maxMarcas: number;
  catedra: number;
  /** Precio por hora cátedra, para el resumen del pie. */
  precio: number;
  /** Encabeza el resumen. Vacío si todavía no hay empresa activa. */
  nombreEmpresa: string;
  /** Abre el modal con las marcaciones de ese día. */
  onAbrirDia: (iso: string) => void;
}) {
  const filas = agruparPorSemana(dias);

  /**
   * Las horas de cada semana y las del mes.
   *
   * Se suman los MINUTOS y recién al final se convierten a horas cátedra. Al
   * revés —sumando las horas ya redondeadas de cada día— el total de la semana
   * no coincidiría con la suma de su propia columna: cinco días redondeados a
   * dos decimales arrastran hasta media centésima de error cada uno, y sobre una
   * planilla que se firma esa diferencia hay que poder explicarla.
   *
   * Es el mismo criterio con el que ya se calcula el KPI "Horas trabajadas".
   */
  const { horasPorSemana, horasDelMes } = useMemo(() => {
    const minutosPorSemana = new Map<number, number>();
    let minutosDelMes = 0;

    for (const { iso, semana } of filas) {
      const minutos = (porDia.get(iso) ?? []).reduce((s, m) => s + (m.minutos ?? 0), 0);
      minutosPorSemana.set(semana, (minutosPorSemana.get(semana) ?? 0) + minutos);
      minutosDelMes += minutos;
    }

    return {
      horasPorSemana: new Map(
        [...minutosPorSemana].map(([s, m]) => [s, m > 0 ? aHorasCatedra(m, catedra) : 0]),
      ),
      horasDelMes: minutosDelMes > 0 ? aHorasCatedra(minutosDelMes, catedra) : 0,
    };
  }, [filas, porDia, catedra]);

  return (
    <div className="surface-card overflow-x-auto">
      <Table className={cn(COLUMNAS_DIVIDIDAS, CIERRA_ULTIMA_FILA)}>
        <TableHeader>
          <TableRow>
            <TableHead className="w-14 text-center">Sem.</TableHead>
            <TableHead className="w-20">Día</TableHead>
            <TableHead className="w-24">Fecha</TableHead>
            {Array.from({ length: maxMarcas }, (_, i) => (
              <TableHead key={i} className="text-center" colSpan={2}>
                {i + 1}
              </TableHead>
            ))}
            <TableHead className="text-right">Horas</TableHead>
            {/* Los dos totales al final, en el orden en que se acumulan: el día
                suma a la semana y la semana al mes. */}
            <TableHead className="w-20 text-right">Semana</TableHead>
            <TableHead className="w-20 text-right">Total</TableHead>
          </TableRow>
          {/* Cierra la cabecera con la misma línea gruesa que separa las
              semanas: así el encabezado y cada bloque semanal se leen como
              cuadros, y no como una lista de filas sueltas. */}
          <TableRow className="border-b-2 border-b-border">
            <TableHead />
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
            <TableHead />
            <TableHead />
          </TableRow>
        </TableHeader>
        <TableBody>
          {filas.map(
            (
              { dia, iso, diaSemana, semana, abreSemana, diasDeLaSemana, diasHastaFinDeMes },
              indice,
            ) => {
              const marcas = porDia.get(iso) ?? [];
              const finDeSemana = diaSemana === 0 || diaSemana === 6;
              const minutos = marcas.reduce((s, m) => s + (m.minutos ?? 0), 0);
              const horas = minutos > 0 ? aHorasCatedra(minutos, catedra) : 0;

              return (
                <TableRow
                  key={iso}
                  onClick={() => onAbrirDia(iso)}
                  className={cn(
                    // Toda la fila abre el día: el objetivo es grande y no obliga a
                    // apuntarle a una celda de dos dígitos.
                    "cursor-pointer transition-colors hover:bg-accent/60",
                    // El fin de semana en gris: sin marcarlo, un sábado vacío se lee
                    // igual que un día laboral sin marcar, que sí es un problema.
                    finDeSemana && "bg-muted/40",
                    // LÍNEA MÁS MARCADA AL ABRIR CADA SEMANA. Con los totales
                    // estirados por rowSpan hay que poder ver de un vistazo qué
                    // filas entran en cada suma; sin este corte, las semanas se
                    // separan sólo por el número de la primera columna y el
                    // total de abajo parece pertenecer a cualquiera de ellas.
                    // No va en la primera fila: ahí ya está el borde del header.
                    abreSemana && indice > 0 && "border-t-2 border-t-border",
                  )}
                >
                  {/* Una sola celda por semana, estirada sobre sus días con
                    rowSpan. `bg-card` explícito para que no herede el gris de la
                    fila cuando la semana arranca un sábado —pasa en la primera
                    semana del mes— y quede una columna de dos colores. */}
                  {abreSemana && (
                    <TableCell
                      rowSpan={diasDeLaSemana}
                      className="bg-card text-center align-middle text-sm font-medium text-muted-foreground"
                    >
                      {semana}
                    </TableCell>
                  )}
                  <TableCell className="text-xs text-muted-foreground">{DIAS[diaSemana]}</TableCell>
                  <TableCell className="font-medium">
                    {/* Un <button> de verdad dentro de la celda: la fila clickeable
                      es cómoda con el mouse, pero no la alcanza nadie que navegue
                      con el teclado ni la anuncia un lector de pantalla.
                      `stopPropagation` evita que el click cuente dos veces. */}
                    <button
                      type="button"
                      onClick={(e) => {
                        e.stopPropagation();
                        onAbrirDia(iso);
                      }}
                      className="rounded px-1 underline-offset-4 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                      title={`Ver las marcaciones del ${dia}`}
                    >
                      {dia}
                    </button>
                  </TableCell>
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
                  {/* `border-r` explícito: con las columnas de total estiradas
                      por rowSpan, ésta es la última celda que declara la fila y
                      `COLUMNAS_DIVIDIDAS` la saltea. */}
                  <TableCell className="border-r text-right font-medium tabular-nums">
                    {horas > 0 ? horas.toFixed(2) : ""}
                  </TableCell>
                  {/* LAS DOS SE DECLARAN EN EL PRIMER DÍA DEL BLOQUE, no en el
                      último: un `rowSpan` sólo se estira hacia abajo. El número
                      va con `align-bottom` para que se lea al pie de la semana
                      —y del mes—, que es donde se lo busca al cerrar la cuenta
                      sobre el papel.

                      `bg-card` explícito por lo mismo que la celda de Sem.: sin
                      él la celda hereda el gris del fin de semana cuando el
                      bloque arranca sábado y la columna queda de dos colores. */}
                  {abreSemana && (
                    <TableCell
                      rowSpan={diasDeLaSemana}
                      className="border-r bg-card text-right align-bottom font-semibold tabular-nums"
                    >
                      {(horasPorSemana.get(semana) ?? 0) > 0
                        ? (horasPorSemana.get(semana) ?? 0).toFixed(2)
                        : ""}
                    </TableCell>
                  )}
                  {/* El total del mes se dibuja UNA sola vez, en la primera fila
                      de la grilla, estirado sobre todas: es una única cuenta. */}
                  {indice === 0 && (
                    <TableCell
                      rowSpan={diasHastaFinDeMes}
                      className="bg-card text-right align-bottom text-base font-bold tabular-nums"
                    >
                      {horasDelMes > 0 ? horasDelMes.toFixed(2) : ""}
                    </TableCell>
                  )}
                </TableRow>
              );
            },
          )}
        </TableBody>
      </Table>

      {/* EL PIE DE LA PLANILLA: actividad extra a la izquierda, resumen a la
          derecha, como en el papel.

          `flex-wrap` y no dos columnas fijas: en una pantalla angosta el resumen
          baja debajo del cuadro en vez de comprimir los dos hasta que no se lean.
          `items-start` para que no se estiren a la altura del más alto. */}
      <div className="flex flex-wrap items-start justify-between gap-4 p-4">
        <ActividadExtra />
        <ResumenPlanilla horas={horasDelMes} precio={precio} nombreEmpresa={nombreEmpresa} />
      </div>
    </div>
  );
}

/**
 * El cuadro de actividad extra: **informativo y en blanco, se completa a mano**.
 *
 * No sale de la base y no puede salir: una actividad extra es un trabajo en otro
 * colegio, con su propio concepto y su propio precio por hora, y nada de eso
 * existe hoy en `ASISTENCIAS_PROFESORES` —que sólo guarda entradas y salidas de
 * una institución—. Inventarle un origen sería mostrar números que no se pueden
 * justificar.
 *
 * Va igual porque la planilla se imprime y se firma: el cuadro tiene que estar
 * en el papel para poder anotarlo ahí, como la firma misma. Es el mismo criterio
 * de los renglones en blanco que ya lleva el Excel.
 *
 * Si algún día se cargan desde el sistema, esto pasa a recibir sus filas y el
 * TOTAL se calcula — la forma del cuadro no cambia.
 */
function ActividadExtra() {
  const columnas = ["COLEGIO", "FECHA", "CONCEPTO", "HS. TRAB", "PAGO POR HS.", "IMPORTE"];
  // Seis renglones, los mismos que trae la planilla de papel. Es lo que entra
  // sin que el bloque crezca más que el resumen de al lado.
  const renglones = [0, 1, 2, 3, 4, 5];

  return (
    <div className="overflow-hidden rounded-lg border border-border">
      {/* Las líneas verticales con el mismo helper que la grilla de arriba, para
          que los dos cuadros de la hoja se vean como el mismo dibujo. */}
      <table className={cn("text-sm", COLUMNAS_DIVIDIDAS)}>
        <thead>
          <tr>
            <th
              colSpan={columnas.length}
              className="border-b border-border bg-muted/60 px-3 py-1.5 text-center font-semibold text-foreground"
            >
              ACTIVIDAD EXTRA
            </th>
          </tr>
          <tr>
            {columnas.map((c) => (
              <th
                key={c}
                className="border-b border-border px-3 py-1.5 text-center text-xs font-semibold whitespace-nowrap text-muted-foreground"
              >
                {c}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {renglones.map((r) => (
            <tr key={r} className="border-b border-border">
              {columnas.map((c) => (
                // Alto fijo: una celda vacía sin él colapsa a nada y el renglón
                // desaparece — que es justamente lo que hay que poder escribir.
                <td key={c} className="h-7 min-w-24 px-3" />
              ))}
            </tr>
          ))}
          <tr>
            <td className="border-r border-border px-3 py-1.5 font-semibold text-foreground">
              TOTAL
            </td>
            {columnas.slice(1).map((c) => (
              <td key={c} className="h-7 px-3" />
            ))}
          </tr>
        </tbody>
      </table>
    </div>
  );
}

/**
 * Cuánto le corresponde a cada profesor, cuando en el período hay más de uno.
 *
 * Va al centro del pie, entre la actividad extra y el resumen general: es el
 * desglose de ese total, y leerlo al lado deja ver de un vistazo que las partes
 * suman el todo.
 *
 * **El monto de cada uno sale de SUS horas**, no del total repartido: dos
 * profesores del mismo mes trabajaron distinta cantidad, y en un papel que
 * autoriza un pago cada cifra tiene que poder rastrearse hasta las marcaciones
 * de esa persona.
 *
 * La fila TOTALES suma los montos ya redondeados de la columna, no el importe
 * general: es la cuenta que alguien va a rehacer con la calculadora sobre el
 * papel, y tiene que darle exactamente lo que está impreso.
 *
 * **Puede quedar 1 o 2 guaraníes por encima del TOTAL GENERAL del resumen de al
 * lado**, y es correcto que así sea. Aquél redondea una sola vez, al final; éste
 * redondea el monto de cada persona —que es la cifra que se le paga y no puede
 * llevar centavos— y después suma. Con hora cátedra de 60 minutos coinciden
 * siempre; la diferencia aparece con 40 o 45, donde las horas dan fracciones
 * periódicas. Forzar el cuadre haría que alguna fila no coincida con el pago
 * real de esa persona, que es peor: el desglose existe justamente para poder
 * justificar cada monto por separado.
 */
function ResumenPorProfesor({ filas }: { filas: Array<{ profesor: string; monto: number }> }) {
  const total = filas.reduce((suma, f) => suma + f.monto, 0);

  return (
    <div className="overflow-hidden rounded-lg border border-border">
      <table className={cn("text-sm", COLUMNAS_DIVIDIDAS)}>
        <thead>
          <tr>
            <th
              colSpan={2}
              className="border-b border-border bg-muted/60 px-3 py-1.5 text-center font-semibold text-foreground"
            >
              RESUMEN
            </th>
          </tr>
          <tr>
            <th className="border-b border-border px-3 py-1.5 text-center text-xs font-semibold whitespace-nowrap text-muted-foreground">
              PROFESORES
            </th>
            <th className="border-b border-border px-3 py-1.5 text-center text-xs font-semibold whitespace-nowrap text-muted-foreground">
              MONTO
            </th>
          </tr>
        </thead>
        <tbody>
          {filas.map(({ profesor, monto }) => (
            <tr key={profesor} className="border-b border-border">
              <td className="px-3 py-1.5 whitespace-nowrap text-foreground">{profesor}</td>
              <td className="px-3 py-1.5 text-right tabular-nums text-foreground">
                {formatearMoneda(monto)}
              </td>
            </tr>
          ))}
          <tr>
            <td className="px-3 py-1.5 text-center font-semibold whitespace-nowrap text-foreground">
              TOTALES
            </td>
            <td className="px-3 py-1.5 text-right font-bold tabular-nums text-foreground">
              {formatearMoneda(total)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  );
}

/**
 * El resumen del pie: horas, precio e importes.
 *
 * **El IVA se DESGLOSA de un importe que ya lo incluye**, no se suma: el precio
 * por hora que se carga arriba es el precio final. Es la misma regla que el
 * punto de venta y las compras —"el precio incluye IVA, se desglosa nunca se
 * suma"— y la que ya usa el KPI "Importe total" de esta pantalla. Sumarle un
 * 10% acá haría que el pie de la planilla y el indicador de arriba mostraran
 * dos totales distintos del mismo mes.
 *
 * **IMPORTE NORMAL es todo el importe y EXTRA va vacío**: hoy nada distingue
 * una hora extra de una normal —no hay campo que la marque— y repartir el total
 * inventando un tope sería un número que nadie puede justificar. La fila queda
 * para completarla a mano sobre el papel, como el resto del bloque de firmas.
 */
function ResumenPlanilla({
  horas,
  precio,
  nombreEmpresa,
}: {
  horas: number;
  precio: number;
  nombreEmpresa: string;
}) {
  const importe = horas * precio;
  // Redondeado a guaraníes: no hay centavos en la moneda, y el desglose tiene
  // que cerrar contra el número que se muestra, no contra uno con decimales.
  const total = Math.round(importe);
  // Mismo cálculo que `totales.iva` y que `totalIva` del Excel: una sola
  // división y una resta, para que gravado + IVA dé exactamente el total.
  const iva = total - Math.round(total / 1.1);

  const filas: Array<{ etiqueta: string; valor: string; destacada?: boolean }> = [
    { etiqueta: "TOTAL HORAS TRABAJADAS", valor: horas.toFixed(2) },
    { etiqueta: "IMPORTE POR HORA", valor: formatearMoneda(precio) },
    { etiqueta: "IMPORTE NORMAL", valor: formatearMoneda(total) },
    // Raya y no un cero: un cero afirma que se calcularon las extras y dieron
    // cero, y lo que pasa es que no se calculan.
    { etiqueta: "IMPORTE EXTRA", valor: "-" },
    { etiqueta: "IMPORTE TOTAL", valor: formatearMoneda(total) },
    { etiqueta: "IVA INCLUIDO EN EL TOTAL", valor: formatearMoneda(iva), destacada: true },
    { etiqueta: "TOTAL GENERAL", valor: formatearMoneda(total), destacada: true },
  ];

  return (
    <div className="flex overflow-hidden rounded-lg border border-border">
      {/* El rótulo estirado sobre todas las filas, como el rowSpan de la
          planilla de papel. */}
      <div className="flex w-32 items-center justify-center bg-muted/60 px-3 py-2 text-center">
        <span className="font-display text-lg font-bold leading-tight text-foreground">
          RESUMEN
          {nombreEmpresa && (
            <>
              <br />
              {nombreEmpresa}
            </>
          )}
        </span>
      </div>

      <table className="border-l border-border text-sm">
        <tbody>
          {filas.map(({ etiqueta, valor, destacada }) => (
            <tr key={etiqueta} className="border-b border-border last:border-b-0">
              <td
                className={cn(
                  "border-r border-border px-3 py-1.5 whitespace-nowrap",
                  // Las dos últimas en rojo, como en la planilla: son las que se
                  // controlan contra la factura.
                  destacada ? "font-semibold text-destructive" : "text-foreground",
                )}
              >
                {etiqueta}
              </td>
              <td
                className={cn(
                  "px-3 py-1.5 text-right tabular-nums whitespace-nowrap",
                  destacada ? "font-bold text-destructive" : "text-foreground",
                )}
              >
                {valor}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/**
 * Las marcaciones de UN día, con sus acciones.
 *
 * Se abre desde la planilla, que es la vista con la que se liquida: ahí se ve
 * el problema —un día en blanco, una entrada sin salida— y hasta ahora había
 * que cambiar a Detalle y buscar esa fila entre las del mes entero.
 *
 * Es una LISTA y no un formulario directo: un día puede tener varias
 * marcaciones —se entra y se sale más de una vez— y cuál corregir lo elige la
 * persona. Con el día vacío queda sólo el botón de agregar, que es lo único
 * que se puede hacer ahí.
 *
 * No guarda ni borra nada por su cuenta: delega en el mismo diálogo de carga y
 * en la misma confirmación de baja que usa la vista Detalle. Duplicar el
 * formulario acá habría dejado dos validaciones que mantener sincronizadas.
 */
function MarcacionesDelDia({
  abierto,
  titulo,
  marcas,
  catedraDe,
  precioDe,
  onCerrar,
  onEditar,
  onEliminar,
  onAgregar,
  puedeAgregar,
}: {
  abierto: boolean;
  titulo: string;
  marcas: AsistenciaProfesor[];
  // Funciones y no numeros: un dia puede tener marcas de varios profesores, y
  // cada uno tiene su hora catedra y su precio.
  catedraDe: (idProfesor: number) => number;
  precioDe: (idProfesor: number) => number;
  onCerrar: () => void;
  onEditar: (a: AsistenciaProfesor) => void;
  onEliminar: (a: AsistenciaProfesor) => void;
  onAgregar: () => void;
  /** Sin empresa activa no hay a qué empresa cargarle la marcación. */
  puedeAgregar: boolean;
}) {
  // Las horas y el importe se acumulan POR PROFESOR: un mismo día puede tener
  // marcas de varias personas, y convertir el total de minutos con una sola hora
  // cátedra daría un número que no es de nadie.
  const { horas, importe } = marcas.reduce(
    (acumulado, m) => {
      const suyas = aHorasCatedra(m.minutos ?? 0, catedraDe(m.idProfesor));
      return {
        horas: acumulado.horas + suyas,
        importe: acumulado.importe + suyas * precioDe(m.idProfesor),
      };
    },
    { horas: 0, importe: 0 },
  );

  return (
    <Dialog open={abierto} onOpenChange={(v) => !v && onCerrar()}>
      <DialogContent className="sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>{titulo}</DialogTitle>
          <DialogDescription>
            {marcas.length === 0
              ? "Sin marcaciones este día."
              : `${marcas.length} marcación(es) · ${horas.toFixed(2)} hs cátedra${
                  importe > 0 ? ` · ${formatearMoneda(Math.round(importe))} Gs.` : ""
                }`}
          </DialogDescription>
        </DialogHeader>

        {marcas.length === 0 ? (
          <p className="rounded-lg border border-dashed border-border px-3 py-8 text-center text-sm text-muted-foreground">
            No hay ninguna marcación cargada para este día.
          </p>
        ) : (
          // Con muchas marcaciones en un día el modal no puede crecer sin
          // límite: la lista scrollea y el pie con las acciones queda fijo.
          <ul className="max-h-[50vh] space-y-2 overflow-y-auto">
            {marcas.map((m) => {
              const horasFila =
                m.minutos === null ? null : aHorasCatedra(m.minutos, catedraDe(m.idProfesor));
              return (
                <li
                  key={m.id}
                  className="flex items-center justify-between gap-3 rounded-lg border border-border p-3"
                >
                  <div className="min-w-0">
                    <p className="truncate font-medium text-foreground">{m.profesor}</p>
                    <p className="truncate text-xs text-muted-foreground">
                      {m.institucion ?? "Sin institución"}
                    </p>
                    {/* <div> y no <p>: adentro va un Badge, que renderiza un <div>,
                        y el HTML no admite un <div> dentro de un <p>. */}
                    <div className="mt-1 text-sm tabular-nums">
                      {m.horaEntrada ?? "—"}
                      {m.entradaOffline === "S" && <IconoOffline />}
                      <span className="mx-1.5 text-muted-foreground">→</span>
                      {m.horaSalida ?? "—"}
                      {m.salidaOffline === "S" && <IconoOffline />}
                      {horasFila === null ? (
                        <Badge variant="outline" className="ml-2 text-warning">
                          Incompleta
                        </Badge>
                      ) : (
                        <span className="ml-2 text-muted-foreground">
                          {horasFila.toFixed(2)} hs
                        </span>
                      )}
                    </div>
                  </div>
                  <div className="flex shrink-0 gap-1">
                    <Button
                      variant="ghost"
                      size="icon"
                      onClick={() => onEditar(m)}
                      title="Editar la marcación"
                    >
                      <Pencil className="size-4" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      onClick={() => onEliminar(m)}
                      title="Eliminar la marcación"
                      className="text-destructive hover:text-destructive"
                    >
                      <Trash2 className="size-4" />
                    </Button>
                  </div>
                </li>
              );
            })}
          </ul>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={onCerrar}>
            Cerrar
          </Button>
          <Button onClick={onAgregar} disabled={!puedeAgregar}>
            <Plus className="size-4" />
            Agregar marcación
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
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

/**
 * El punto donde se marcó, como enlace a Google Maps.
 *
 * Un solo componente para la entrada y la salida: son el mismo dato en dos
 * momentos, y con dos bloques copiados el día que cambie la URL del mapa habría
 * que acordarse de tocar los dos.
 *
 * **`rel="noopener noreferrer"` no es decorativo**: sin `noopener`, la pestaña
 * que se abre puede redirigir a ésta desde `window.opener`.
 *
 * El `title` prefiere lo que grabó la app —`MARCADO_EN_ENTRADA`/`_SALIDA`, que
 * suele ser el nombre del lugar— y cae en un texto genérico si viene vacío: sin
 * él, el enlace sería un pin sin ninguna pista de adónde lleva.
 */
function EnlaceMapa({
  latitud,
  longitud,
  titulo,
  momento,
}: {
  latitud: string | null;
  longitud: string | null;
  titulo: string | null;
  momento: "entrada" | "salida";
}) {
  // Las dos o ninguna: con una sola coordenada el mapa abriría en un punto
  // equivocado, que es peor que no ofrecer el enlace.
  if (!latitud || !longitud) return <span className="text-muted-foreground">—</span>;

  return (
    <a
      href={`https://www.google.com/maps?q=${latitud},${longitud}`}
      target="_blank"
      rel="noopener noreferrer"
      className="text-primary hover:underline"
      title={titulo ?? `Ver en el mapa dónde marcó la ${momento}`}
    >
      <MapPin className="mx-auto size-4" />
    </a>
  );
}

/** Una fila por marcación, con institución, ubicación e importe. */
function Detalle({
  items,
  catedraDe,
  precioDe,
  onEditar,
  onEliminar,
}: {
  items: AsistenciaProfesor[];
  /**
   * Funciones y no dos números: cada fila es de un profesor distinto, y cada uno
   * tiene su hora cátedra y su precio. Con valores fijos, la columna Importe
   * mostraría el mismo precio para todos.
   */
  catedraDe: (idProfesor: number) => number;
  precioDe: (idProfesor: number) => number;
  onEditar: (a: AsistenciaProfesor) => void;
  onEliminar: (a: AsistenciaProfesor) => void;
}) {
  return (
    <div className="surface-card overflow-x-auto">
      <Table className={cn(COLUMNAS_DIVIDIDAS, CIERRA_ULTIMA_FILA)}>
        <TableHeader>
          <TableRow>
            <TableHead>Fecha</TableHead>
            <TableHead>Profesor</TableHead>
            <TableHead>Institución</TableHead>
            <TableHead className="text-center">Entrada</TableHead>
            <TableHead className="text-center">Salida</TableHead>
            <TableHead className="text-right">Horas</TableHead>
            <TableHead className="text-right">Importe</TableHead>
            {/* DOS UBICACIONES, no una: se marca al entrar y al salir, y son
                puntos distintos. Con una sola columna no había forma de saber
                si el profesor salió del mismo lugar donde entró — que es
                justamente lo que se controla al revisar una marcación. */}
            <TableHead className="text-center">Ubic. entrada</TableHead>
            <TableHead className="text-center">Ubic. salida</TableHead>
            <TableHead className="text-right">Acciones</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {items.map((a) => {
            const horas =
              a.minutos === null ? null : aHorasCatedra(a.minutos, catedraDe(a.idProfesor));
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
                  {horas === null
                    ? "—"
                    : formatearMoneda(Math.round(horas * precioDe(a.idProfesor)))}
                </TableCell>
                <TableCell className="text-center">
                  <EnlaceMapa
                    latitud={a.latitud}
                    longitud={a.longitud}
                    titulo={a.marcadoEnEntrada}
                    momento="entrada"
                  />
                </TableCell>
                <TableCell className="text-center">
                  <EnlaceMapa
                    latitud={a.latitudSalida}
                    longitud={a.longitudSalida}
                    titulo={a.marcadoEnSalida}
                    momento="salida"
                  />
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
