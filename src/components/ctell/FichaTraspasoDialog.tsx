import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Plus, Printer, Trash2, TriangleAlert } from "lucide-react";
import { useState } from "react";
import { useFieldArray, useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

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
import { Textarea } from "@/components/ui/textarea";
import { api, ApiError, type FichaTraspaso, type FichaTraspasoDeJustificacion } from "@/lib/api";

/**
 * Ficha de traspaso de clase: qué tiene que hacer el suplente de un profesor
 * ausente.
 *
 * **Vive dentro de justificaciones y no en una pantalla propia**, porque la
 * ficha existe por y para una ausencia concreta: se entra por la solicitud que
 * la motivó, no por un listado de fichas sueltas. Por eso el diálogo se abre
 * con el id de la **justificación** y no con el de la ficha — al abrirlo todavía
 * no se sabe si existe.
 *
 * Eso es exactamente lo que resuelve `porJustificacion()`: devuelve la ficha o
 * `null` con un **200**, no un 404. "Esta ausencia no tiene ficha todavía" es el
 * camino normal de una solicitud recién recibida, y tratarlo como error
 * obligaría a la pantalla a pintar una falla donde no la hay.
 */

/** Los topes de las columnas. El backend los valida igual: esto evita el viaje. */
const MAX_MATERIA = 200;
const MAX_CONTACTO = 200;
const MAX_TEXTO = 1000;
const MAX_GRADO = 100;

/** El mismo techo que `C_MAX_LINEAS` en `db/fichas-traspaso-clase.sql`. */
const MAX_LINEAS = 40;

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Una hora `HH:MM` de 24 horas, o vacío.
 *
 * Se valida acá **y** en el backend, que además la normaliza: la columna es
 * `VARCHAR2(10)` sin `CHECK` y aceptaría "a la mañana", dejando la ficha impresa
 * con una columna de horario que no tiene horarios.
 */
const HORA = /^([01]\d|2[0-3]):[0-5]\d$/;

const horaOpcional = z
  .string()
  .trim()
  .refine((v) => v === "" || HORA.test(v), "Usá el formato HH:MM (ej. 07:30)");

const lineaSchema = z
  .object({
    gradoCurso: z
      .string()
      .trim()
      .min(1, "Poné el grado o curso")
      .max(MAX_GRADO, `Máximo ${MAX_GRADO} caracteres`),
    horaDesde: horaOpcional,
    horaHasta: horaOpcional,
    temaDesarrollar: z.string().max(MAX_TEXTO, `Máximo ${MAX_TEXTO} caracteres`),
    observacionesGrupo: z.string().max(MAX_TEXTO, `Máximo ${MAX_TEXTO} caracteres`),
  })
  // Las dos horas están normalizadas a HH:MM con cero a la izquierda, así que
  // comparar los textos es exacto. Sin el cero, "9:00" > "13:30".
  .refine((l) => !l.horaDesde || !l.horaHasta || l.horaHasta > l.horaDesde, {
    message: "La hora de fin tiene que ser posterior a la de inicio",
    path: ["horaHasta"],
  });

const schema = z.object({
  materiaArea: z.string().max(MAX_MATERIA, `Máximo ${MAX_MATERIA} caracteres`),
  personaContacto: z.string().max(MAX_CONTACTO, `Máximo ${MAX_CONTACTO} caracteres`),
  ingresoRequisitos: z.string().max(MAX_TEXTO, `Máximo ${MAX_TEXTO} caracteres`),
  materialesRecursos: z.string().max(MAX_TEXTO, `Máximo ${MAX_TEXTO} caracteres`),
  otrasIndicaciones: z.string().max(MAX_TEXTO, `Máximo ${MAX_TEXTO} caracteres`),
  observacionesAdicionales: z.string().max(MAX_TEXTO, `Máximo ${MAX_TEXTO} caracteres`),
  detalle: z.array(lineaSchema).max(MAX_LINEAS, `No más de ${MAX_LINEAS} grados`),
});

type FormValues = z.infer<typeof schema>;

/** Una línea vacía, la que agrega el botón. */
const LINEA_VACIA = {
  gradoCurso: "",
  horaDesde: "",
  horaHasta: "",
  temaDesarrollar: "",
  observacionesGrupo: "",
};

export function FichaTraspasoDialog({
  idJustificacion,
  idEmpresa,
  profesor,
  onClose,
}: {
  /** `null` cierra el diálogo. Es el id de la **ausencia**, no el de la ficha. */
  idJustificacion: number | null;
  idEmpresa: number;
  /** Sólo para el título: la ficha ya trae el suyo. */
  profesor: string;
  onClose: () => void;
}) {
  const abierto = idJustificacion !== null;

  const { data, isPending, isError, error } = useQuery({
    queryKey: ["fichas-traspaso-clase", "por-justificacion", idJustificacion, idEmpresa],
    queryFn: () => api.fichasTraspasoClase.porJustificacion(idJustificacion!, idEmpresa),
    enabled: abierto,
  });

  return (
    <Dialog open={abierto} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="scrollbar-fino max-h-[92vh] max-w-[95vw] overflow-y-auto sm:max-w-3xl">
        <DialogHeader>
          <DialogTitle className="break-words">Ficha de traspaso · {profesor}</DialogTitle>
          <DialogDescription>
            Lo que necesita saber quien cubre las clases: por dónde entra, con quién se presenta, y
            grado por grado qué tema toca. Se imprime y se le entrega.
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
            {MENSAJE_ERROR(error, "No se pudo cargar la ficha")}
          </p>
        )}

        {data && (
          <FichaForm
            datos={data}
            idJustificacion={idJustificacion!}
            idEmpresa={idEmpresa}
            onClose={onClose}
          />
        )}
      </DialogContent>
    </Dialog>
  );
}

/**
 * El formulario, montado sólo con los datos ya traídos.
 *
 * Sirve para el alta y para la edición: la única diferencia es si `datos.ficha`
 * vino o no. Separarlos en dos componentes duplicaría el formulario entero para
 * cambiar a qué endpoint pega el submit.
 */
function FichaForm({
  datos,
  idJustificacion,
  idEmpresa,
  onClose,
}: {
  datos: FichaTraspasoDeJustificacion;
  idJustificacion: number;
  idEmpresa: number;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const ficha = datos.ficha;
  const esNueva = ficha === null;

  const form = useForm<FormValues>({
    values: {
      // En el alta se propone la materia que declaró el profesor. No es un dato
      // fijo: la ficha puede precisarla para el suplente ("Matemática" →
      // "Matemática - Geometría, unidad 4").
      materiaArea: ficha?.materiaArea ?? datos.materiaSugerida ?? "",
      personaContacto: ficha?.personaContacto ?? "",
      ingresoRequisitos: ficha?.ingresoRequisitos ?? "",
      materialesRecursos: ficha?.materialesRecursos ?? "",
      otrasIndicaciones: ficha?.otrasIndicaciones ?? "",
      observacionesAdicionales: ficha?.observacionesAdicionales ?? "",
      detalle:
        ficha?.detalle.map((d) => ({
          gradoCurso: d.gradoCurso,
          horaDesde: d.horaDesde ?? "",
          horaHasta: d.horaHasta ?? "",
          temaDesarrollar: d.temaDesarrollar ?? "",
          observacionesGrupo: d.observacionesGrupo ?? "",
        })) ?? [],
    },
    resolver: zodResolver(schema),
  });

  const { fields, append, remove } = useFieldArray({ control: form.control, name: "detalle" });

  /**
   * Invalida las dos claves que el guardado cambia: la de esta ficha y la del
   * listado. Sin la segunda, la fila de la bandeja seguiría diciendo "Sin ficha"
   * después de crearla.
   */
  function invalidar() {
    queryClient.invalidateQueries({ queryKey: ["fichas-traspaso-clase"] });
  }

  const guardar = useMutation({
    // Todas las claves van siempre, incluso vacías: una omitida deja el bind sin
    // definir en vez de en NULL y el backend responde 400. Vacío BORRA, que es
    // la única forma de sacar una indicación cargada por error.
    mutationFn: (v: FormValues) => {
      const cuerpo = {
        idEmpresa,
        materiaArea: v.materiaArea,
        personaContacto: v.personaContacto,
        ingresoRequisitos: v.ingresoRequisitos,
        materialesRecursos: v.materialesRecursos,
        otrasIndicaciones: v.otrasIndicaciones,
        observacionesAdicionales: v.observacionesAdicionales,
        detalle: v.detalle,
      };

      return esNueva
        ? api.fichasTraspasoClase.crear({ ...cuerpo, idJustificacion })
        : api.fichasTraspasoClase.actualizar(ficha.id, cuerpo);
    },
    onSuccess: () => {
      invalidar();
      toast.success(esNueva ? "Ficha creada" : "Ficha actualizada");
      onClose();
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo guardar la ficha")),
  });

  const eliminar = useMutation({
    mutationFn: () => api.fichasTraspasoClase.eliminar(ficha!.id, idEmpresa),
    onSuccess: () => {
      invalidar();
      toast.success("Ficha eliminada");
      onClose();
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo eliminar la ficha")),
  });

  const [confirmarBorrado, setConfirmarBorrado] = useState(false);

  const sinGrados = fields.length === 0;

  return (
    <div className="space-y-5">
      {/* Lo derivado de la ausencia: se muestra para que se vea de qué ficha se
          trata, pero no se edita. Cambiar la fecha o la institución acá las
          desalinearía de la justificación que las define. */}
      <dl className="grid gap-x-4 gap-y-3 rounded-lg border border-border p-3 text-sm sm:grid-cols-2">
        <Dato titulo="Institución" valor={ficha?.institucion ?? null} />
        <Dato titulo="Fecha de la ausencia" valor={formatearFecha(datos.fechaAusencia)} />
        <Dato titulo="Turno u horario" valor={ficha?.turno ?? null} />
        <Dato titulo="Suplente asignado" valor={ficha?.suplente ?? null} />
      </dl>

      {/* Un suplente sin asignar no impide cargar la ficha —se prepara antes de
          saber quién va— pero conviene decirlo: la ficha es para alguien. */}
      {!ficha?.suplente && (
        <p className="flex items-start gap-2 rounded-lg border border-warning/30 bg-warning/10 px-3 py-2 text-sm text-foreground">
          <TriangleAlert className="mt-0.5 size-4 shrink-0 text-warning" />
          <span>
            Esta ausencia todavía no tiene suplente asignado. La ficha se puede preparar igual; el
            suplente se carga al resolver la solicitud.
          </span>
        </p>
      )}

      <Form {...form}>
        <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
          <FormField
            control={form.control}
            name="materiaArea"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Materia o área</FormLabel>
                <FormControl>
                  <Input {...field} placeholder="Matemática" />
                </FormControl>
                <FormDescription>
                  {esNueva && datos.materiaSugerida
                    ? "Viene de la solicitud. Precisala si hace falta."
                    : "La que va a dar el suplente."}
                </FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          <FormField
            control={form.control}
            name="personaContacto"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Persona de contacto</FormLabel>
                <FormControl>
                  <Input {...field} placeholder="Con quién se presenta al llegar" />
                </FormControl>
                <FormDescription>Opcional. Vacío lo borra.</FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          <FormField
            control={form.control}
            name="ingresoRequisitos"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Ingreso y requisitos</FormLabel>
                <FormControl>
                  <Textarea
                    {...field}
                    rows={2}
                    placeholder="Por qué puerta entra, si hay que registrarse en portería, credencial…"
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />

          <FormField
            control={form.control}
            name="materialesRecursos"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Materiales y recursos</FormLabel>
                <FormControl>
                  <Textarea
                    {...field}
                    rows={2}
                    placeholder="Qué lleva, qué hay en el aula, dónde están las llaves…"
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />

          {/* ------------------------------------------------------------- */}
          {/* El detalle: un grado por línea                                 */}
          {/* ------------------------------------------------------------- */}
          <div className="space-y-3">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div>
                <h3 className="text-sm font-medium text-foreground">Grados y horarios</h3>
                <p className="text-xs text-muted-foreground">
                  Qué clases hay ese día y qué tema toca en cada una.
                </p>
              </div>
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() => append(LINEA_VACIA)}
                disabled={fields.length >= MAX_LINEAS}
              >
                <Plus className="size-4" />
                Agregar grado
              </Button>
            </div>

            {/* Sin grados la ficha se guarda igual —se puede cargar el acceso
                ahora y los horarios después— pero no le sirve al suplente, que
                es para quien se escribe. Se avisa, no se bloquea. */}
            {sinGrados && (
              <p className="flex items-start gap-2 rounded-lg border border-dashed border-border px-3 py-4 text-sm text-muted-foreground">
                <TriangleAlert className="mt-0.5 size-4 shrink-0" />
                <span>
                  Todavía no hay ningún grado cargado. La ficha se puede guardar así y completarse
                  después, pero sin los horarios el suplente no sabe a qué aula entrar.
                </span>
              </p>
            )}

            {fields.map((f, i) => (
              <div key={f.id} className="space-y-3 rounded-lg border border-border p-3">
                <div className="flex items-start justify-between gap-2">
                  <span className="text-xs font-medium text-muted-foreground">Grado {i + 1}</span>
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    onClick={() => remove(i)}
                    className="h-8 text-destructive hover:text-destructive"
                  >
                    <Trash2 className="size-4" />
                    <span className="sr-only">Quitar el grado {i + 1}</span>
                  </Button>
                </div>

                <div className="grid gap-3 sm:grid-cols-[1fr_auto_auto]">
                  <FormField
                    control={form.control}
                    name={`detalle.${i}.gradoCurso`}
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Grado o curso</FormLabel>
                        <FormControl>
                          <Input {...field} placeholder="3ro. A" />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />

                  <FormField
                    control={form.control}
                    name={`detalle.${i}.horaDesde`}
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Desde</FormLabel>
                        <FormControl>
                          {/* type="time" da el selector nativo y garantiza el
                              HH:MM que el backend espera. */}
                          <Input {...field} type="time" className="w-full sm:w-32" />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />

                  <FormField
                    control={form.control}
                    name={`detalle.${i}.horaHasta`}
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Hasta</FormLabel>
                        <FormControl>
                          <Input {...field} type="time" className="w-full sm:w-32" />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>

                <FormField
                  control={form.control}
                  name={`detalle.${i}.temaDesarrollar`}
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Tema a desarrollar</FormLabel>
                      <FormControl>
                        <Textarea {...field} rows={2} placeholder="Qué se da en esa clase" />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <FormField
                  control={form.control}
                  name={`detalle.${i}.observacionesGrupo`}
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Observaciones del grupo</FormLabel>
                      <FormControl>
                        <Textarea
                          {...field}
                          rows={2}
                          placeholder="Lo que convenga saber del curso"
                        />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
              </div>
            ))}
          </div>

          <FormField
            control={form.control}
            name="otrasIndicaciones"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Otras indicaciones</FormLabel>
                <FormControl>
                  <Textarea
                    {...field}
                    rows={2}
                    placeholder="Lo que no entre en los campos de arriba"
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />

          <FormField
            control={form.control}
            name="observacionesAdicionales"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Observaciones adicionales</FormLabel>
                <FormControl>
                  <Textarea {...field} rows={2} placeholder="Notas del docente" />
                </FormControl>
                <FormDescription>Máximo {MAX_TEXTO} caracteres.</FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          <DialogFooter className="gap-2 sm:justify-between">
            <div className="flex flex-wrap gap-2">
              {/* Sólo con la ficha guardada: imprimir un formulario a medio
                  llenar sacaría un papel que no es el que se va a entregar. */}
              {!esNueva && (
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => imprimirFicha(ficha)}
                  className="h-11 sm:h-10"
                >
                  <Printer className="size-4" />
                  Imprimir
                </Button>
              )}
              {!esNueva && (
                <Button
                  type="button"
                  variant="ghost"
                  onClick={() => setConfirmarBorrado(true)}
                  className="h-11 text-destructive hover:text-destructive sm:h-10"
                >
                  <Trash2 className="size-4" />
                  Eliminar
                </Button>
              )}
            </div>

            <div className="flex flex-wrap gap-2">
              <Button
                type="submit"
                disabled={guardar.isPending}
                className="h-11 w-full sm:h-10 sm:w-auto"
              >
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {guardar.isPending ? "Guardando…" : esNueva ? "Crear ficha" : "Guardar"}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={onClose}
                className="h-11 w-full sm:h-10 sm:w-auto"
              >
                Cancelar
              </Button>
            </div>
          </DialogFooter>
        </form>
      </Form>

      {/* El borrado se lleva los grados y no se deshace: se confirma. */}
      <Dialog open={confirmarBorrado} onOpenChange={setConfirmarBorrado}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>¿Eliminar la ficha?</DialogTitle>
            <DialogDescription>
              Se borran también los grados y horarios cargados. La solicitud de ausencia no se toca:
              queda sin ficha, y se puede volver a hacer.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2">
            <Button
              type="button"
              variant="destructive"
              onClick={() => eliminar.mutate()}
              disabled={eliminar.isPending}
              className="h-11 w-full sm:h-10 sm:w-auto"
            >
              {eliminar.isPending && <Loader2 className="size-4 animate-spin" />}
              {eliminar.isPending ? "Eliminando…" : "Eliminar"}
            </Button>
            <Button
              type="button"
              variant="outline"
              onClick={() => setConfirmarBorrado(false)}
              className="h-11 w-full sm:h-10 sm:w-auto"
            >
              Cancelar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

/**
 * Sin `new Date`: `new Date("2026-09-04")` es medianoche **UTC**, y en Asunción
 * eso es el día anterior a las 21:00 — una ausencia del 4 se mostraría como del
 * 3. Es el mismo criterio de `_auth.justificaciones-ausencia.tsx`.
 */
function formatearFecha(iso: string | null): string | null {
  if (!iso) return null;
  const [a, m, d] = iso.split("-");
  return a && m && d ? `${d}/${m}/${a}` : iso;
}

/** Un dato derivado. `—` cuando está vacío: el hueco también informa. */
function Dato({ titulo, valor }: { titulo: string; valor: string | null }) {
  return (
    <div>
      <dt className="text-xs text-muted-foreground">{titulo}</dt>
      <dd className="mt-0.5 break-words text-foreground">{valor ?? "—"}</dd>
    </div>
  );
}

/**
 * Abre la ficha en una ventana nueva, lista para imprimir.
 *
 * **La ventana se abre en la primera línea, antes de cualquier trabajo**: los
 * bloqueadores de ventanas emergentes sólo dejan pasar el `window.open` que
 * ocurre dentro del click. Es la misma regla que `abrirPdf` en `lib/exportar.ts`.
 *
 * No usa jsPDF a propósito: esto es un documento de texto que se imprime y se
 * firma, no una tabla de datos: el HTML del navegador lo resuelve sin sumar dos
 * librerías al bundle por una pantalla.
 */
function imprimirFicha(ficha: FichaTraspaso) {
  const ventana = window.open("", "_blank");
  if (!ventana) {
    toast.error("El navegador bloqueó la ventana de impresión");
    return;
  }

  const escapar = (t: string | null) =>
    (t ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");

  const bloque = (titulo: string, texto: string | null) =>
    texto ? `<section><h2>${titulo}</h2><p>${escapar(texto)}</p></section>` : "";

  const filas = ficha.detalle
    .map(
      (d) => `<tr>
        <td>${escapar(d.gradoCurso)}</td>
        <td>${escapar([d.horaDesde, d.horaHasta].filter(Boolean).join(" a ")) || "—"}</td>
        <td>${escapar(d.temaDesarrollar) || "—"}</td>
        <td>${escapar(d.observacionesGrupo) || "—"}</td>
      </tr>`,
    )
    .join("");

  ventana.document.write(`<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<title>Ficha de traspaso — ${escapar(ficha.profesor)}</title>
<style>
  body { font: 12pt/1.5 system-ui, sans-serif; margin: 2cm; color: #111; }
  h1 { font-size: 16pt; margin: 0 0 .2em; }
  h2 { font-size: 11pt; margin: 1.2em 0 .3em; text-transform: uppercase;
       letter-spacing: .04em; color: #444; }
  p { margin: 0; white-space: pre-wrap; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: .2em 1em; margin: 1em 0; }
  dt { color: #555; }
  table { width: 100%; border-collapse: collapse; margin-top: .4em; }
  th, td { border: 1px solid #999; padding: .4em .6em; text-align: left;
           vertical-align: top; font-size: 10pt; }
  th { background: #f0f0f0; }
  .firma { margin-top: 3em; display: flex; gap: 4em; }
  .firma div { flex: 1; border-top: 1px solid #333; padding-top: .4em;
               font-size: 10pt; color: #555; }
</style></head><body>
<h1>Ficha de traspaso de clase</h1>
<dl>
  <dt>Profesor ausente</dt><dd>${escapar(ficha.profesor)}</dd>
  <dt>Institución</dt><dd>${escapar(ficha.institucion) || "—"}</dd>
  <dt>Fecha</dt><dd>${formatearFecha(ficha.fechaAusencia) ?? "—"}</dd>
  <dt>Materia o área</dt><dd>${escapar(ficha.materiaArea) || "—"}</dd>
  <dt>Suplente</dt><dd>${escapar(ficha.suplente) || "—"}</dd>
  <dt>Persona de contacto</dt><dd>${escapar(ficha.personaContacto) || "—"}</dd>
</dl>
${bloque("Ingreso y requisitos", ficha.ingresoRequisitos)}
${bloque("Materiales y recursos", ficha.materialesRecursos)}
${
  filas
    ? `<section><h2>Grados y horarios</h2><table>
        <thead><tr><th>Grado</th><th>Horario</th><th>Tema</th><th>Observaciones</th></tr></thead>
        <tbody>${filas}</tbody></table></section>`
    : ""
}
${bloque("Otras indicaciones", ficha.otrasIndicaciones)}
${bloque("Observaciones adicionales", ficha.observacionesAdicionales)}
<div class="firma"><div>Firma del suplente</div><div>Firma de la institución</div></div>
</body></html>`);

  ventana.document.close();
  ventana.focus();
  ventana.print();
}
