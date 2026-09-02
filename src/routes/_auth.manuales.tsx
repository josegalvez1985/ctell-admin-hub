import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  FileText,
  FileUp,
  Loader2,
  Pencil,
  Plus,
  Search,
  Trash2,
  TriangleAlert,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { SelectorModal } from "@/components/ctell/SelectorModal";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import {
  api,
  ApiError,
  esActivo,
  GRADOS,
  urlArchivoManual,
  type Grado,
  type Institucion,
  type Manual,
} from "@/lib/api";
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
import { Skeleton } from "@/components/ui/skeleton";
import { tituloPagina } from "@/lib/marca";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

/**
 * El grado se valida contra la lista, no como texto libre: es lo mismo que hace
 * `GRADO_VALIDO` en `db/manuales.sql`. Un valor fuera de lista entra como un
 * grado distinto que el UNIQUE deja pasar, y la institución termina con dos
 * manuales de primero.
 */
const schema = z.object({
  idInstitucion: z.string().min(1, "Elegí una institución"),
  grado: z.enum(GRADOS, { errorMap: () => ({ message: "Elegí un grado" }) }),
});

type FormValues = z.infer<typeof schema>;

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Cuántas filas se muestran de entrada, y cuántas suma cada "Mostrar más".
 *
 * El endpoint devuelve todo de una vez —poco para la red, mucho para el DOM—,
 * así que la tabla corta acá.
 */
const POR_PAGINA = 20;

/** Lo que se espera entre teclas antes de mandar la búsqueda al servidor. */
const ESPERA_BUSQUEDA_MS = 350;

/** El techo que valida el backend. Se chequea acá para no subir 20 MB en vano. */
const MAX_BYTES = 20 * 1024 * 1024;

/**
 * El peso del PDF, para mostrarlo al lado del nombre: un manual de 40 MB
 * explica solo por qué tarda en abrir.
 *
 * En MB con un decimal desde 1 MB, y en KB debajo: "0,3 MB" no dice nada.
 */
function formatearPeso(bytes: number): string {
  if (bytes <= 0) return "—";
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / 1024 / 1024).toLocaleString("es-PY", { maximumFractionDigits: 1 })} MB`;
}

function ManualesPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Manual | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Manual | null>(null);

  // Dos estados para la búsqueda: `busqueda` es lo que se ve en el input
  // (inmediato, sin lag al tipear) y `busquedaEnvio` lo que entra en la
  // queryKey, para no disparar una consulta por tecla.
  const [busqueda, setBusqueda] = useState("");
  const [busquedaEnvio, setBusquedaEnvio] = useState("");

  useEffect(() => {
    const id = setTimeout(() => setBusquedaEnvio(busqueda), ESPERA_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  // Los manuales son POR EMPRESA aunque la tabla no tenga la columna: cuelgan de
  // INSTITUCIONES, y el backend acota con un JOIN contra el padre.
  const { empresa } = useEmpresa();

  // Las instituciones alimentan el selector del formulario Y el filtro de la
  // columna. Sólo las activas: dar de alta un manual en una institución
  // inactiva es cargar trabajo que nadie va a mirar.
  const { data: institucionesData, isPending: cargandoInstituciones } = useQuery({
    queryKey: ["instituciones", empresa?.id ?? null],
    queryFn: () => api.instituciones.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });
  const instituciones = (institucionesData?.items ?? []).filter((i) => esActivo(i.activo));

  // La empresa y la búsqueda entran en la queryKey: al cambiar cualquiera,
  // TanStack Query trata el listado como otra consulta en vez de mostrar en
  // caché el de la anterior.
  //
  // `enabled` evita pedir sin empresa. En el primer render todavía es null
  // —el provider hidrata desde localStorage después de montar— y sin esto la
  // petición saldría sin idEmpresa, que acá además es un 400 del backend.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["manuales", empresa?.id ?? null, busquedaEnvio.trim()],
    queryFn: () => api.manuales.listar({ idEmpresa: empresa!.id, busqueda: busquedaEnvio }),
    enabled: empresa !== null,
  });

  const eliminar = useMutation({
    mutationFn: (manual: Manual) => api.manuales.eliminar(manual.id, empresa!.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["manuales"] });
      toast.success("Manual eliminado");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  const items = data?.items ?? [];

  /**
   * El orden por click en el header ordena en memoria lo que llegó. La búsqueda
   * sí va al servidor: filtrar en el cliente sólo miraría lo ya traído.
   */
  const [orden, setOrden] = useState<{
    campo: keyof Manual;
    direccion: "asc" | "desc";
  } | null>(null);

  // Los dos filtros de columna. Institución y grado son justamente las columnas
  // con valores repetidos, que es donde el embudo tiene sentido.
  const [filtroInstitucion, setFiltroInstitucion] = useState(SIN_FILTRO);
  const [filtroGrado, setFiltroGrado] = useState(SIN_FILTRO);

  function alternarOrden(campo: keyof Manual) {
    setOrden((actual) => {
      if (!actual || actual.campo !== campo) return { campo, direccion: "asc" };
      if (actual.direccion === "asc") return { campo, direccion: "desc" };
      return null; // Tercer click: vuelve al orden del backend (institución, grado).
    });
  }

  const filtrados = items.filter(
    (m) =>
      (filtroInstitucion === SIN_FILTRO || String(m.idInstitucion) === filtroInstitucion) &&
      (filtroGrado === SIN_FILTRO || m.grado === filtroGrado),
  );

  const ordenados = orden
    ? [...filtrados].sort((a, b) => {
        const signo = orden.direccion === "asc" ? 1 : -1;
        // El grado se ordena por su posición real, no alfabéticamente: con un
        // orden de texto, "1ME." cae entre "1ro." y "2do." y la media queda
        // intercalada con la escolar básica. Es el mismo criterio que el
        // ORDER BY del backend.
        if (orden.campo === "grado") {
          return signo * (GRADOS.indexOf(a.grado) - GRADOS.indexOf(b.grado));
        }
        // El peso es numérico: comparado como texto, "9 KB" quedaría después de
        // "10 MB".
        if (orden.campo === "bytesArchivo") {
          return signo * (a.bytesArchivo - b.bytesArchivo);
        }
        return (
          signo * String(a[orden.campo] ?? "").localeCompare(String(b[orden.campo] ?? ""), "es")
        );
      })
    : filtrados;

  // El término que el servidor está respondiendo, no el que se está tipeando:
  // los mensajes de "sin resultados" tienen que nombrar lo que se buscó de
  // verdad, no lo que quedó a medio escribir.
  const termino = busquedaEnvio.trim();
  const hayFiltros =
    termino !== "" || filtroInstitucion !== SIN_FILTRO || filtroGrado !== SIN_FILTRO;

  // Cuántas filas se están mostrando. Se resetea al cambiar CUALQUIER filtro,
  // no sólo la búsqueda: seguir en "80 de 90" tras filtrar a 12 perdería el
  // sentido.
  const [visibles, setVisibles] = useState(POR_PAGINA);
  const claveFiltros = `${termino}|${filtroInstitucion}|${filtroGrado}`;
  const [filtrosAnteriores, setFiltrosAnteriores] = useState(claveFiltros);
  if (claveFiltros !== filtrosAnteriores) {
    // Ajuste de estado en render, no useEffect: React re-renderiza antes de
    // pintar, así que la lista nunca se ve con el valor viejo.
    setFiltrosAnteriores(claveFiltros);
    setVisibles(POR_PAGINA);
  }

  const mostrados = ordenados.slice(0, visibles);
  const quedan = ordenados.length - mostrados.length;

  // Las opciones del embudo salen de las filas ya listadas, no del catálogo
  // entero: así no se ofrece una institución que dejaría la tabla vacía.
  const opcionesInstitucion = [...new Map(items.map((m) => [m.idInstitucion, m])).values()]
    .map((m) => ({ valor: String(m.idInstitucion), etiqueta: m.institucion }))
    .sort((a, b) => a.etiqueta.localeCompare(b.etiqueta, "es"));

  const opcionesGrado = GRADOS.filter((g) => items.some((m) => m.grado === g)).map((g) => ({
    valor: g,
    etiqueta: g,
  }));

  const sinArchivo = items.filter((m) => !m.tieneArchivo).length;

  return (
    <AppLayout active="/manuales" title="Manuales">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Manuales</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {empresa
                ? `Manuales en PDF por institución y grado de ${empresa.nombreEmpresa}.`
                : "Manuales en PDF por institución y grado."}
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null}>
            <Plus className="size-4" />
            Nuevo manual
          </Button>
        </div>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por institución o grado…"
            className="pl-9"
          />
        </div>

        {/* Un manual sin PDF es un alta que alguien empezó y no terminó. Se
            avisa arriba porque en la fila se ve de a uno, y lo que importa es
            que no queden olvidados. */}
        {sinArchivo > 0 && (
          <p className="flex items-start gap-2 rounded-lg border border-warning/30 bg-warning/10 px-3 py-2 text-sm text-foreground">
            <TriangleAlert className="mt-0.5 size-4 shrink-0 text-warning" />
            <span>
              {sinArchivo === 1
                ? "Hay 1 manual sin el PDF cargado."
                : `Hay ${sinArchivo} manuales sin el PDF cargado.`}{" "}
              Subilo desde el botón de la fila.
            </span>
          </p>
        )}

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
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        )}

        {isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
            {MENSAJE_ERROR(error, "No se pudo cargar la lista")}
          </p>
        )}

        {!isPending && !isError && empresa !== null && ordenados.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {hayFiltros
                ? termino
                  ? `Sin resultados para "${termino}".`
                  : "Ningún manual coincide con los filtros."
                : "Esta empresa todavía no tiene manuales cargados."}
            </p>
            {!hayFiltros && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                <Plus className="size-4" />
                Cargar el primero
              </Button>
            )}
          </div>
        )}

        {/* Móvil: tarjetas. Una tabla de 5 columnas en 360px obliga a scrollear
            de costado para leer una fila entera. */}
        {ordenados.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {mostrados.map((manual) => (
              <li key={manual.id} className="surface-card p-4">
                <p className="break-words font-semibold leading-snug text-foreground">
                  {manual.institucion}
                </p>
                <p className="mt-0.5 text-xs text-muted-foreground">Grado {manual.grado}</p>
                <div className="mt-2">
                  <EstadoArchivo manual={manual} />
                </div>

                <div className="mt-3 flex flex-wrap gap-2 border-t border-border pt-3">
                  <ArchivoManual manual={manual} />
                  <Button
                    variant="outline"
                    size="sm"
                    className="flex-1"
                    onClick={() => setEditando(manual)}
                  >
                    <Pencil className="size-4" />
                    Editar
                  </Button>
                  <Button
                    variant="outline"
                    size="sm"
                    className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                    onClick={() => setAEliminar(manual)}
                  >
                    <Trash2 className="size-4" />
                    Eliminar
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}

        {ordenados.length > 0 && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "institucion" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("institucion")}
                    opciones={opcionesInstitucion}
                    valor={filtroInstitucion}
                    onFiltrar={setFiltroInstitucion}
                    buscarPlaceholder="Buscar institución…"
                  >
                    Institución
                  </TableHeadFiltrable>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "grado" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("grado")}
                    opciones={opcionesGrado}
                    valor={filtroGrado}
                    onFiltrar={setFiltroGrado}
                    buscarPlaceholder="Buscar grado…"
                    className="w-28"
                  >
                    Grado
                  </TableHeadFiltrable>
                  <TableHead>Archivo</TableHead>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "fechaCarga" ? orden.direccion : null}
                    onClick={() => alternarOrden("fechaCarga")}
                  >
                    Cargado
                  </TableHeadOrdenable>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {mostrados.map((manual) => (
                  <TableRow key={manual.id}>
                    <TableCell className="font-medium text-foreground">
                      {manual.institucion}
                    </TableCell>
                    <TableCell className="tabular-nums text-muted-foreground">
                      {manual.grado}
                    </TableCell>
                    <TableCell>
                      <EstadoArchivo manual={manual} />
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {manual.tieneArchivo && manual.fechaCarga
                        ? new Date(manual.fechaCarga).toLocaleDateString("es-PY")
                        : "—"}
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex justify-end gap-1">
                        <ArchivoManual manual={manual} />
                        <Button
                          variant="ghost"
                          size="icon"
                          title="Editar"
                          aria-label={`Editar el manual de ${manual.grado} de ${manual.institucion}`}
                          onClick={() => setEditando(manual)}
                        >
                          <Pencil className="size-4" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="icon"
                          title="Eliminar"
                          aria-label={`Eliminar el manual de ${manual.grado} de ${manual.institucion}`}
                          onClick={() => setAEliminar(manual)}
                        >
                          <Trash2 className="size-4 text-destructive" />
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}

        {quedan > 0 && (
          <div className="flex justify-center">
            <Button variant="outline" onClick={() => setVisibles((v) => v + POR_PAGINA)}>
              Mostrar {Math.min(quedan, POR_PAGINA)} más
            </Button>
          </div>
        )}

        {data && ordenados.length > 0 && (
          <p className="text-center text-xs text-muted-foreground">
            Mostrando {mostrados.length} de {ordenados.length} manual
            {ordenados.length === 1 ? "" : "es"}
          </p>
        )}

        {/* Sin empresa no se abre: el alta necesita su id. */}
        {empresa !== null && (
          <ManualFormDialog
            open={creando || editando !== null}
            manual={editando}
            idEmpresa={empresa.id}
            instituciones={instituciones}
            cargandoInstituciones={cargandoInstituciones}
            onClose={() => {
              setCreando(false);
              setEditando(null);
            }}
          />
        )}

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle className="break-words">
                ¿Eliminar el manual de {aEliminar?.grado} de {aEliminar?.institucion}?
              </AlertDialogTitle>
              <AlertDialogDescription>
                {aEliminar?.tieneArchivo
                  ? "Se borra también el PDF cargado. Esta acción no se puede deshacer."
                  : "Esta acción no se puede deshacer."}
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancelar</AlertDialogCancel>
              <AlertDialogAction
                onClick={(e) => {
                  // Sin esto el AlertDialog se cierra antes de que la mutación
                  // termine y el error nunca se llega a mostrar.
                  e.preventDefault();
                  if (aEliminar) eliminar.mutate(aEliminar);
                }}
                disabled={eliminar.isPending}
                className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              >
                {eliminar.isPending && <Loader2 className="size-4 animate-spin" />}
                Eliminar
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </main>
    </AppLayout>
  );
}

/* -------------------------------------------------------------------------- */
/* Archivo                                                                     */
/* -------------------------------------------------------------------------- */

/** Si el PDF está cargado, con su peso. Lo que la fila necesita de un vistazo. */
function EstadoArchivo({ manual }: { manual: Manual }) {
  if (!manual.tieneArchivo) {
    return (
      <span className="inline-flex items-center gap-1 rounded-full bg-warning/15 px-2 py-0.5 text-xs font-medium text-warning">
        <TriangleAlert className="size-3" />
        Sin PDF
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-1 rounded-full bg-success/15 px-2 py-0.5 text-xs font-medium text-success">
      <FileText className="size-3" />
      PDF · {formatearPeso(manual.bytesArchivo)}
    </span>
  );
}

/**
 * Ver el PDF y reemplazarlo, desde la fila.
 *
 * **Reemplazar es la operación normal**, no una excepción: como sólo hay un
 * manual por grado, cargar el del año siguiente es subirlo sobre la misma fila.
 *
 * El link es un `<a>` a la URL pública, no un `fetch`: el navegador abre el PDF
 * en su visor, desde donde se imprime y se descarga. Bajarlo con `fetch` para
 * armar un object URL costaría lo mismo y perdería el link compartible.
 */
function ArchivoManual({ manual }: { manual: Manual }) {
  const queryClient = useQueryClient();
  const entrada = useRef<HTMLInputElement>(null);

  const subir = useMutation({
    mutationFn: (archivo: File) => api.manuales.subirArchivo(manual.id, archivo),
    onSuccess: () => {
      // El listado trae `tieneArchivo`, `bytesArchivo` y `fechaCarga`: los tres
      // acaban de cambiar.
      queryClient.invalidateQueries({ queryKey: ["manuales"] });
      toast.success(manual.tieneArchivo ? "PDF reemplazado" : "PDF cargado");
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo subir el archivo")),
  });

  function alElegir(e: React.ChangeEvent<HTMLInputElement>) {
    const archivo = e.target.files?.[0];
    // Sin esto, elegir el mismo archivo dos veces no dispara el onChange.
    e.target.value = "";
    if (!archivo) return;

    // Las dos validaciones que el backend también hace. Acá evitan subir 20 MB
    // para recibir un 413, que con una conexión lenta es un minuto perdido.
    if (archivo.type !== "application/pdf") {
      toast.error("El archivo debe ser un PDF");
      return;
    }
    if (archivo.size > MAX_BYTES) {
      toast.error(`El archivo pesa ${formatearPeso(archivo.size)} y el máximo es 20 MB`);
      return;
    }
    subir.mutate(archivo);
  }

  return (
    <>
      <input
        ref={entrada}
        type="file"
        accept="application/pdf"
        className="hidden"
        onChange={alElegir}
        aria-hidden
        tabIndex={-1}
      />

      {/* Sólo si hay archivo: el endpoint devuelve 404 mientras no se subió, y
          mandar a alguien a una pestaña con un error es peor que no ofrecerlo. */}
      {manual.tieneArchivo && (
        <Button
          asChild
          variant="ghost"
          size="icon"
          title="Ver el PDF"
          aria-label={`Ver el manual de ${manual.grado} de ${manual.institucion}`}
        >
          <a href={urlArchivoManual(manual.id)} target="_blank" rel="noopener noreferrer">
            <FileText className="size-4" />
          </a>
        </Button>
      )}

      <Button
        variant="ghost"
        size="icon"
        title={manual.tieneArchivo ? "Reemplazar el PDF" : "Subir el PDF"}
        aria-label={`${manual.tieneArchivo ? "Reemplazar" : "Subir"} el PDF del manual de ${manual.grado} de ${manual.institucion}`}
        onClick={() => entrada.current?.click()}
        disabled={subir.isPending}
      >
        {subir.isPending ? (
          <Loader2 className="size-4 animate-spin" />
        ) : (
          <FileUp className={manual.tieneArchivo ? "size-4" : "size-4 text-warning"} />
        )}
      </Button>
    </>
  );
}

/* -------------------------------------------------------------------------- */
/* Alta / Edición                                                              */
/* -------------------------------------------------------------------------- */

function ManualFormDialog({
  open,
  manual,
  idEmpresa,
  instituciones,
  cargandoInstituciones,
  onClose,
}: {
  open: boolean;
  manual: Manual | null;
  /** Empresa activa de la sesión. No es un campo del formulario. */
  idEmpresa: number;
  instituciones: Institucion[];
  cargandoInstituciones: boolean;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = manual !== null;

  /**
   * El PDF elegido en el alta, que se sube después de crear la fila.
   *
   * No entra en react-hook-form: un `File` no es un valor de formulario que zod
   * valide bien, y el archivo tiene su propio flujo (se manda al endpoint
   * binario, no en el JSON).
   */
  const [archivo, setArchivo] = useState<File | null>(null);
  const entrada = useRef<HTMLInputElement>(null);

  // Al cerrar y volver a abrir, el archivo elegido no tiene que sobrevivir: si
  // no, el alta siguiente arrancaría con el PDF de la anterior.
  useEffect(() => {
    if (!open) setArchivo(null);
  }, [open]);

  const form = useForm<FormValues>({
    values: {
      idInstitucion: manual ? String(manual.idInstitucion) : "",
      // El default no importa en edición (siempre hay grado) y en el alta es lo
      // primero que se elige.
      grado: manual?.grado ?? GRADOS[0],
    },
    resolver: zodResolver(schema),
  });

  const guardar = useMutation({
    mutationFn: async (v: FormValues) => {
      if (esEdicion) {
        return api.manuales.actualizar(manual.id, {
          idEmpresa,
          idInstitucion: Number(v.idInstitucion),
          grado: v.grado,
        });
      }

      // ALTA EN DOS LLAMADAS, UNA SOLA OPERACIÓN PARA QUIEN CARGA: el PDF no
      // viaja en el JSON, así que primero se crea la fila y con el id que
      // devuelve se sube el archivo. Es el mismo flujo que la foto de un
      // profesor.
      const creado = await api.manuales.crear({
        idEmpresa,
        idInstitucion: Number(v.idInstitucion),
        grado: v.grado,
      });

      // Si la subida falla, el manual YA quedó creado: no se puede deshacer con
      // un DELETE sin arriesgarse a borrar algo que otro acaba de tocar. Se
      // avisa y la fila queda con su cartel de "Sin PDF", desde donde se
      // reintenta. Por eso el error se traga acá en vez de propagarse: el alta
      // fue exitosa aunque el archivo no.
      if (archivo) {
        try {
          await api.manuales.subirArchivo(creado.id, archivo);
        } catch (e) {
          toast.warning(
            MENSAJE_ERROR(
              e,
              "El manual se creó, pero el PDF no se pudo subir. Reintentá desde la fila.",
            ),
          );
        }
      }
      return creado;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["manuales"] });
      toast.success(esEdicion ? "Manual actualizado" : "Manual creado");
      onClose();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear el manual"),
      ),
  });

  function alElegirArchivo(e: React.ChangeEvent<HTMLInputElement>) {
    const elegido = e.target.files?.[0];
    // Sin esto, elegir el mismo archivo dos veces no dispara el onChange.
    e.target.value = "";
    if (!elegido) return;

    if (elegido.type !== "application/pdf") {
      toast.error("El archivo debe ser un PDF");
      return;
    }
    if (elegido.size > MAX_BYTES) {
      toast.error(`El archivo pesa ${formatearPeso(elegido.size)} y el máximo es 20 MB`);
      return;
    }
    setArchivo(elegido);
  }

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="scrollbar-fino max-h-[92vh] max-w-[95vw] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar manual" : "Nuevo manual"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Cambiá la institución o el grado. El PDF se reemplaza desde la fila."
              : "Elegí la institución, el grado y el archivo PDF."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="idInstitucion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Institución</FormLabel>
                  <FormControl>
                    <SelectorModal
                      opciones={instituciones.map((i) => ({
                        valor: String(i.id),
                        etiqueta: i.nombreInstitucion,
                        ...(i.ciudad ? { descripcion: i.ciudad } : {}),
                      }))}
                      value={field.value}
                      onChange={field.onChange}
                      placeholder="Elegí una institución"
                      titulo="Elegí una institución"
                      buscarPlaceholder="Buscar institución…"
                      cargando={cargandoInstituciones}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="grado"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Grado</FormLabel>
                  <FormControl>
                    <SelectorModal
                      opciones={GRADOS.map((g) => ({ valor: g, etiqueta: g }))}
                      value={field.value}
                      onChange={(v) => field.onChange(v as Grado)}
                      placeholder="Elegí un grado"
                      titulo="Elegí un grado"
                      buscarPlaceholder="Buscar grado…"
                    />
                  </FormControl>
                  <FormDescription>
                    Cada institución puede tener un solo manual por grado.
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            {/* El archivo va fuera de react-hook-form (ver el useState de
                arriba), así que su bloque no es un FormField — pero igual está
                dentro del <form>, donde se lee junto a los demás campos. */}
            {!esEdicion && (
              <div className="space-y-2">
                <p className="text-sm font-medium leading-none">Archivo PDF</p>
                <input
                  ref={entrada}
                  type="file"
                  accept="application/pdf"
                  className="hidden"
                  onChange={alElegirArchivo}
                  aria-hidden
                  tabIndex={-1}
                />
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => entrada.current?.click()}
                  // Un nombre de archivo largo tiene que envolver, no estirar el
                  // diálogo: el <Button> de shadcn trae whitespace-nowrap y h-9,
                  // y hay que anular las dos.
                  className="h-auto min-h-9 w-full justify-start whitespace-normal break-all text-left"
                >
                  <FileUp className="size-4 shrink-0" />
                  {archivo ? `${archivo.name} · ${formatearPeso(archivo.size)}` : "Elegir un PDF…"}
                </Button>
                <p className="text-[0.8rem] text-muted-foreground">
                  Opcional: se puede subir después desde la fila. Máximo 20 MB.
                </p>
              </div>
            )}

            <DialogFooter className="gap-2">
              <Button
                type="submit"
                disabled={guardar.isPending}
                className="h-11 w-full sm:h-10 sm:w-auto"
              >
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {guardar.isPending ? "Guardando…" : esEdicion ? "Guardar cambios" : "Crear manual"}
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
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/manuales")({
  head: () => ({
    meta: [
      { title: tituloPagina("Manuales") },
      { name: "description", content: "Manuales en PDF por institución y grado." },
    ],
  }),
  component: ManualesPage,
});
