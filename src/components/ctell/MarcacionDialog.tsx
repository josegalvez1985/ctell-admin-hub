import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { useEffect } from "react";
import { useForm } from "react-hook-form";
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { api, ApiError, type AsistenciaProfesor } from "@/lib/api";

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * `HH:MM` en 24 horas, o vacío.
 *
 * Vacío es válido a propósito: una entrada sin salida es un estado real —el
 * profesor entró y todavía no salió— y es justamente uno de los casos que este
 * diálogo viene a poder corregir.
 */
const HORA = /^([01]\d|2[0-3]):[0-5]\d$/;

const schema = z
  .object({
    idProfesor: z.string().min(1, "Elegí un profesor"),
    idInstitucion: z.string().min(1, "Elegí una institución"),
    fecha: z.string().min(1, "Obligatoria"),
    horaEntrada: z
      .string()
      .trim()
      .refine((v) => v === "" || HORA.test(v), "Formato HH:MM (24 horas)"),
    horaSalida: z
      .string()
      .trim()
      .refine((v) => v === "" || HORA.test(v), "Formato HH:MM (24 horas)"),
  })
  // La comparación va como refinamiento del objeto y no de un campo: necesita
  // los dos valores, y el mensaje tiene que colgar de "horaSalida" para que
  // aparezca debajo del campo que hay que corregir.
  .refine((v) => v.horaEntrada === "" || v.horaSalida === "" || v.horaSalida > v.horaEntrada, {
    message: "Tiene que ser posterior a la entrada",
    path: ["horaSalida"],
  });

type FormValues = z.infer<typeof schema>;

type Opcion = { id: number; nombre: string };

/**
 * Alta y edición manual de una marcación.
 *
 * `marcacion` en `null` es un alta; con una marcación, la edita. El mismo
 * diálogo hace las dos cosas porque el formulario es idéntico — separarlos
 * duplicaría la validación y el mapeo de campos.
 *
 * Las horas viajan como `HH:MM` y el backend las compone con la fecha: mandar
 * un ISO completo haría que una diferencia de zona horaria corriera el día.
 */
export function MarcacionDialog({
  abierto,
  onCerrar,
  marcacion,
  idEmpresa,
  profesores,
  instituciones,
  fechaSugerida,
}: {
  abierto: boolean;
  onCerrar: () => void;
  /** `null` para dar de alta. */
  marcacion: AsistenciaProfesor | null;
  idEmpresa: number;
  profesores: Opcion[];
  instituciones: Opcion[];
  /** Con qué fecha arranca un alta: el período que se está mirando. */
  fechaSugerida: string;
}) {
  const queryClient = useQueryClient();
  const editando = marcacion !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      idProfesor: "",
      idInstitucion: "",
      fecha: fechaSugerida,
      horaEntrada: "",
      horaSalida: "",
    },
  });

  // El formulario se rellena al abrir y no en `defaultValues`: el diálogo se
  // monta una sola vez y se reusa para cada fila, así que sin esto la segunda
  // marcación que se abriera mostraría los datos de la primera.
  useEffect(() => {
    if (!abierto) return;
    form.reset(
      marcacion
        ? {
            idProfesor: String(marcacion.idProfesor),
            idInstitucion: String(marcacion.idInstitucion),
            fecha: marcacion.fecha,
            horaEntrada: marcacion.horaEntrada ?? "",
            horaSalida: marcacion.horaSalida ?? "",
          }
        : {
            idProfesor: "",
            idInstitucion: "",
            fecha: fechaSugerida,
            horaEntrada: "",
            horaSalida: "",
          },
    );
  }, [abierto, marcacion, fechaSugerida, form]);

  const guardar = useMutation({
    mutationFn: (valores: FormValues) => {
      // Las horas vacías se omiten en vez de mandarse como "": el backend las
      // trata como NULL, que es lo que significa "no marcó".
      const datos = {
        idEmpresa,
        idProfesor: Number(valores.idProfesor),
        idInstitucion: Number(valores.idInstitucion),
        fecha: valores.fecha,
        ...(valores.horaEntrada !== "" ? { horaEntrada: valores.horaEntrada } : {}),
        ...(valores.horaSalida !== "" ? { horaSalida: valores.horaSalida } : {}),
      };
      return marcacion
        ? api.asistenciasProfesores.actualizar(marcacion.id, datos)
        : api.asistenciasProfesores.crear(datos);
    },
    onSuccess: () => {
      // La queryKey completa incluye los filtros y el período: se invalida el
      // prefijo para que se refresquen tanto el listado filtrado como la
      // consulta que alimenta los combos.
      queryClient.invalidateQueries({ queryKey: ["asistencias"] });
      toast.success(editando ? "Marcación actualizada" : "Marcación agregada");
      onCerrar();
    },
    onError: (error) => {
      toast.error(MENSAJE_ERROR(error, "No se pudo guardar la marcación"));
    },
  });

  return (
    <Dialog open={abierto} onOpenChange={(v) => !v && onCerrar()}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{editando ? "Editar marcación" : "Nueva marcación"}</DialogTitle>
          <DialogDescription>
            Carga manual, para corregir lo que la app no registró. No lleva ubicación GPS.
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form
            onSubmit={form.handleSubmit((v) => guardar.mutate(v))}
            className="space-y-4"
            noValidate
          >
            <FormField
              control={form.control}
              name="idProfesor"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Profesor</FormLabel>
                  <Select value={field.value} onValueChange={field.onChange}>
                    <FormControl>
                      <SelectTrigger>
                        <SelectValue placeholder="Elegí un profesor" />
                      </SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      {profesores.map((p) => (
                        <SelectItem key={p.id} value={String(p.id)}>
                          {p.nombre}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="idInstitucion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Institución</FormLabel>
                  <Select value={field.value} onValueChange={field.onChange}>
                    <FormControl>
                      <SelectTrigger>
                        <SelectValue placeholder="Elegí una institución" />
                      </SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      {instituciones.map((i) => (
                        <SelectItem key={i.id} value={String(i.id)}>
                          {i.nombre}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="fecha"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Fecha</FormLabel>
                  <FormControl>
                    <Input type="date" {...field} />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="horaEntrada"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Entrada</FormLabel>
                    <FormControl>
                      {/* `type="time"` y no texto: el teclado del teléfono
                          muestra el selector de hora y el formato lo garantiza
                          el navegador. El schema igual lo valida, porque un
                          `<input type="time">` acepta vacío. */}
                      <Input type="time" {...field} />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="horaSalida"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Salida</FormLabel>
                    <FormControl>
                      <Input type="time" {...field} />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            <FormDescription>
              Dejá la salida vacía si el profesor entró y todavía no salió.
            </FormDescription>

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onCerrar}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {editando ? "Guardar" : "Agregar"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}
