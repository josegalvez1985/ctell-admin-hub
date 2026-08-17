import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ImagePlus, Loader2, Pencil, Plus, Trash2, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
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
import { Skeleton } from "@/components/ui/skeleton";
import { api, ApiError, urlFotoDetalleMoneda, type DetalleMoneda, type Moneda } from "@/lib/api";

/** Tamaño máximo de la foto. El BLOB viaja entero en el PUT. */
const FOTO_MAX_BYTES = 1024 * 1024;

/**
 * La denominación se guarda como los DÍGITOS PELADOS ("50000"), sin separadores.
 *
 * La columna es VARCHAR2(50) y aceptaba texto libre, pero un valor así no se
 * puede ordenar ni formatear: "10.000" y "2.000" comparados como texto ponen el
 * de 10 mil antes que el de 2 mil, y no hay forma de saber qué parte de
 * "Billete de 50" es el importe. Restringir la entrada a dígitos resuelve las
 * dos cosas sin tocar el DDL.
 *
 * El separador se agrega sólo al MOSTRAR, con `formatearDenominacion`.
 */
const schema = z.object({
  denominacion: z
    .string()
    .trim()
    .min(1, "Obligatorio")
    // 15 dígitos: de sobra para cualquier billete y lejos del límite de la
    // columna, que además tiene que aguantar el valor sin separadores.
    .max(15, "Máximo 15 dígitos")
    .regex(/^\d+$/, "Sólo números, sin puntos ni letras"),
});

type FormValues = z.infer<typeof schema>;

/** Los dígitos de un valor guardado, ignorando puntos o texto de filas viejas. */
function soloDigitos(valor: string): string {
  return valor.replace(/\D/g, "");
}

/**
 * Valor numérico de una denominación, para ordenar.
 *
 * Las filas cargadas antes de esta validación pueden tener texto. Las que no
 * tengan ningún dígito devuelven `null` y se ordenan al final: no hay forma de
 * ubicarlas entre los números.
 */
function valorDenominacion(valor: string): number | null {
  const digitos = soloDigitos(valor);
  return digitos === "" ? null : Number(digitos);
}

/**
 * Denominación con separador de miles: "50000" → "50.000".
 *
 * Un valor sin dígitos (texto de una fila vieja) se muestra tal cual: es
 * preferible mostrar el dato como está que esconderlo detrás de un guión.
 */
function formatearDenominacion(valor: string): string {
  const numero = valorDenominacion(valor);
  if (numero === null) return valor;
  return new Intl.NumberFormat("es-PY").format(numero);
}

function mensajeError(e: unknown, respaldo: string): string {
  return e instanceof ApiError ? e.message : respaldo;
}

/**
 * Denominaciones de una moneda, con su foto.
 *
 * Va como diálogo sobre la página de monedas y no como página propia: el
 * detalle no tiene sentido fuera de su cabecera —siempre se mira "las
 * denominaciones DE esta moneda"— y una ruta aparte obligaría a elegir la
 * moneda de nuevo al entrar.
 *
 * La foto se sube en un segundo paso, después de crear la fila: el `PUT` de la
 * imagen necesita el id, que recién existe tras el alta. Mismo flujo que el
 * logo de una empresa.
 */
export function DetalleMonedasDialog({
  moneda,
  onOpenChange,
}: {
  /** Moneda cuyo detalle se está viendo. `null` cierra el diálogo. */
  moneda: Moneda | null;
  onOpenChange: (abierto: boolean) => void;
}) {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<DetalleMoneda | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<DetalleMoneda | null>(null);

  const idMoneda = moneda?.id ?? null;

  const { data, isPending, isError } = useQuery({
    queryKey: ["detalle-monedas", idMoneda],
    queryFn: () => api.detalleMonedas.listar({ idMoneda: idMoneda! }),
    // El diálogo cerrado no tiene moneda: sin esto la primera petición saldría
    // sin filtro y traería las denominaciones de todas.
    enabled: idMoneda !== null,
  });

  // De menor a mayor por valor numérico. El backend ordena por la columna, que
  // es VARCHAR2: como texto, "10000" va antes que "2000". Se reordena acá y no
  // en el SQL porque un TO_NUMBER sobre la columna reventaría con ORA-01722 en
  // cuanto una fila vieja tuviera texto.
  //
  // useMemo: sin esto el sort corre en cada render del diálogo, y `items` sería
  // un array nuevo cada vez.
  const items = useMemo(() => {
    const lista = [...(data?.items ?? [])];
    return lista.sort((a, b) => {
      const va = valorDenominacion(a.denominacion);
      const vb = valorDenominacion(b.denominacion);
      // Las que no tienen número van al final, alfabéticas entre sí.
      if (va === null && vb === null) return a.denominacion.localeCompare(b.denominacion, "es");
      if (va === null) return 1;
      if (vb === null) return -1;
      return va - vb;
    });
  }, [data?.items]);

  function invalidar() {
    queryClient.invalidateQueries({ queryKey: ["detalle-monedas", idMoneda] });
  }

  const eliminar = useMutation({
    mutationFn: (id: number) => api.detalleMonedas.eliminar(id),
    onSuccess: () => {
      toast.success("Denominación eliminada");
      setAEliminar(null);
      invalidar();
    },
    onError: (e) => toast.error(mensajeError(e, "No se pudo eliminar")),
  });

  return (
    <>
      <Dialog open={moneda !== null} onOpenChange={onOpenChange}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>Denominaciones de {moneda?.nombreMoneda}</DialogTitle>
            <DialogDescription>
              Los billetes y monedas que se cuentan en los cierres de caja. La foto ayuda a
              identificarlos.
            </DialogDescription>
          </DialogHeader>

          {isPending ? (
            <div className="space-y-2">
              {[0, 1, 2].map((i) => (
                <Skeleton key={i} className="h-16 w-full" />
              ))}
            </div>
          ) : isError ? (
            <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">
              No se pudieron cargar las denominaciones.
            </p>
          ) : items.length === 0 ? (
            <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
              Esta moneda todavía no tiene denominaciones cargadas.
            </p>
          ) : (
            // <ul> y no <Table>: dentro de un diálogo el ancho es acotado y una
            // tabla obligaría a scrollear de costado. Mismo criterio que el
            // resto de los diálogos con listado del proyecto.
            <ul className="scrollbar-fino max-h-80 space-y-2 overflow-y-auto">
              {items.map((detalle) => (
                <li
                  key={detalle.id}
                  className="flex items-center gap-3 rounded-lg border border-border p-2"
                >
                  <FotoDetalle detalle={detalle} onSubida={invalidar} />

                  {/* tabular-nums: los dígitos ocupan todos lo mismo, así los
                      valores quedan alineados en columna al leerlos de arriba
                      abajo. */}
                  <span className="min-w-0 flex-1 truncate text-sm font-medium tabular-nums text-foreground">
                    {formatearDenominacion(detalle.denominacion)}
                    {moneda?.simbolo && (
                      <span className="ml-1.5 text-xs font-normal text-muted-foreground">
                        {moneda.simbolo}
                      </span>
                    )}
                  </span>

                  <Button
                    variant="ghost"
                    size="icon"
                    title="Editar"
                    aria-label={`Editar ${formatearDenominacion(detalle.denominacion)}`}
                    onClick={() => setEditando(detalle)}
                  >
                    <Pencil className="size-4" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    title="Eliminar"
                    aria-label={`Eliminar ${formatearDenominacion(detalle.denominacion)}`}
                    onClick={() => setAEliminar(detalle)}
                  >
                    <Trash2 className="size-4 text-destructive" />
                  </Button>
                </li>
              ))}
            </ul>
          )}

          <DialogFooter className="gap-2 sm:gap-2">
            <Button variant="outline" onClick={() => onOpenChange(false)}>
              Cerrar
            </Button>
            <Button onClick={() => setCreando(true)} disabled={idMoneda === null}>
              <Plus className="size-4" />
              Agregar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Alta y edición comparten formulario: los campos son los mismos. */}
      {idMoneda !== null && (creando || editando !== null) && (
        <FormularioDetalle
          idMoneda={idMoneda}
          detalle={editando}
          onCerrar={() => {
            setCreando(false);
            setEditando(null);
          }}
          onGuardado={invalidar}
        />
      )}

      <Dialog open={aEliminar !== null} onOpenChange={(a) => !a && setAEliminar(null)}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Eliminar denominación</DialogTitle>
            <DialogDescription>
              Se va a eliminar «{aEliminar ? formatearDenominacion(aEliminar.denominacion) : ""}»
              junto con su foto. No se puede deshacer.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2 sm:gap-2">
            <Button variant="outline" onClick={() => setAEliminar(null)}>
              Cancelar
            </Button>
            <Button
              variant="destructive"
              disabled={eliminar.isPending}
              onClick={() => aEliminar && eliminar.mutate(aEliminar.id)}
            >
              {eliminar.isPending && <Loader2 className="size-4 animate-spin" />}
              Eliminar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

/**
 * Miniatura de la denominación, que además es el botón para cambiarla.
 *
 * Sin foto muestra un ícono; con foto, la imagen. En los dos casos el click
 * abre el selector de archivos: es el único lugar donde se carga la imagen, y
 * separarlo en un botón aparte sumaría un control por fila sin ganar claridad.
 */
function FotoDetalle({ detalle, onSubida }: { detalle: DetalleMoneda; onSubida: () => void }) {
  const input = useRef<HTMLInputElement>(null);
  // Cambia al subir para romper la caché del navegador: la URL es la misma y
  // sin esto seguiría mostrando la foto anterior.
  const [version, setVersion] = useState(0);
  const [falloCarga, setFalloCarga] = useState(false);

  const subir = useMutation({
    mutationFn: (archivo: File) => api.detalleMonedas.subirFoto(detalle.id, archivo),
    onSuccess: () => {
      setVersion((v) => v + 1);
      setFalloCarga(false);
      toast.success("Foto actualizada");
      onSubida();
    },
    onError: (e) => toast.error(mensajeError(e, "No se pudo subir la foto")),
  });

  function alElegir(e: React.ChangeEvent<HTMLInputElement>) {
    const archivo = e.target.files?.[0];
    // Se limpia siempre: sin esto, elegir el mismo archivo dos veces seguidas
    // no dispara el change y el reintento no haría nada.
    e.target.value = "";
    if (!archivo) return;

    if (archivo.size > FOTO_MAX_BYTES) {
      toast.error("La imagen no puede superar 1 MB");
      return;
    }
    subir.mutate(archivo);
  }

  const mostrarImagen = (detalle.tieneFoto || version > 0) && !falloCarga;

  return (
    <>
      <input
        ref={input}
        type="file"
        accept="image/*"
        className="hidden"
        onChange={alElegir}
        aria-hidden
        tabIndex={-1}
      />
      <button
        type="button"
        title={mostrarImagen ? "Cambiar foto" : "Subir foto"}
        aria-label={`${mostrarImagen ? "Cambiar" : "Subir"} foto de ${formatearDenominacion(detalle.denominacion)}`}
        onClick={() => input.current?.click()}
        disabled={subir.isPending}
        className="flex size-12 shrink-0 items-center justify-center overflow-hidden rounded-lg border border-border bg-muted transition-colors hover:border-primary"
      >
        {subir.isPending ? (
          <Loader2 className="size-4 animate-spin text-muted-foreground" />
        ) : mostrarImagen ? (
          <img
            src={`${urlFotoDetalleMoneda(detalle.id)}${version > 0 ? `?v=${version}` : ""}`}
            alt=""
            className="size-full object-cover"
            onError={() => setFalloCarga(true)}
          />
        ) : (
          <ImagePlus className="size-4 text-muted-foreground" />
        )}
      </button>
    </>
  );
}

/** Alta y edición de una denominación. La foto se carga desde el listado. */
function FormularioDetalle({
  idMoneda,
  detalle,
  onCerrar,
  onGuardado,
}: {
  idMoneda: number;
  /** `null` en el alta. */
  detalle: DetalleMoneda | null;
  onCerrar: () => void;
  onGuardado: () => void;
}) {
  const esEdicion = detalle !== null;

  // Se normaliza a dígitos al cargar: una fila vieja con "Billete de 50.000" no
  // pasaría la validación y el formulario se abriría en un estado inválido que
  // el usuario no causó. Editarla la deja limpia.
  const valorInicial = soloDigitos(detalle?.denominacion ?? "");

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { denominacion: valorInicial },
  });

  useEffect(() => {
    form.reset({ denominacion: valorInicial });
  }, [valorInicial, form]);

  const guardar = useMutation({
    mutationFn: (v: FormValues) =>
      esEdicion
        ? api.detalleMonedas.actualizar(detalle.id, { denominacion: v.denominacion })
        : api.detalleMonedas.crear({ idMoneda, denominacion: v.denominacion }),
    onSuccess: () => {
      toast.success(esEdicion ? "Denominación actualizada" : "Denominación creada");
      onGuardado();
      onCerrar();
    },
    onError: (e) =>
      form.setError("root", { message: mensajeError(e, "No se pudo guardar la denominación") }),
  });

  return (
    <Dialog open onOpenChange={(a) => !a && onCerrar()}>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar denominación" : "Nueva denominación"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá el valor de la denominación."
              : "Agregá un billete o moneda. La foto se carga después, desde el listado."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="denominacion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Valor</FormLabel>
                  <FormControl>
                    <Input
                      {...field}
                      // Los separadores se agregan al mostrar, no al escribir:
                      // formatear mientras se tipea obliga a recolocar el cursor
                      // en cada tecla. Acá se descarta lo que no sea dígito.
                      onChange={(e) => field.onChange(soloDigitos(e.target.value))}
                      // inputMode y no type="number": el teclado numérico del
                      // celular sin las flechas de incremento, que en un importe
                      // no aportan y permiten valores negativos con la rueda.
                      inputMode="numeric"
                      placeholder="50000"
                      autoComplete="off"
                      autoFocus
                      className="tabular-nums"
                    />
                  </FormControl>
                  {/* Devuelve lo tipeado con separadores: confirma de un vistazo
                      que no se comió ni sobró un cero. */}
                  <FormDescription>
                    {field.value
                      ? `Se guarda como ${formatearDenominacion(field.value)}`
                      : "Sólo números. El separador de miles se agrega solo."}
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            {form.formState.errors.root && (
              <p
                role="alert"
                className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive"
              >
                {form.formState.errors.root.message}
              </p>
            )}

            <DialogFooter className="gap-2 sm:gap-2">
              <Button type="button" variant="outline" onClick={onCerrar}>
                <X className="size-4" />
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                Guardar
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}
