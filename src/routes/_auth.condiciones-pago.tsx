import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Trash2 } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, type CondicionPago } from "@/lib/api";
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

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Las dos reglas cruzadas van en un `superRefine`: "contado" y "cuotas" no son
 * inválidos por separado, lo son en combinación.
 *
 * Es la misma validación que hace el backend. Acá se repite para no gastar un
 * viaje a la red en un error que se ve en el formulario.
 */
const schema = z
  .object({
    nombreCondicion: z.string().trim().min(1, "Obligatorio").max(100, "Máximo 100 caracteres"),
    diasPago: z
      .string()
      .trim()
      .min(1, "Obligatorio")
      .refine((v) => !Number.isNaN(Number(v)), "Tiene que ser un número")
      .refine((v) => Number(v) >= 0, "No puede ser negativo"),
    cantidadCuotas: z
      .string()
      .trim()
      .min(1, "Obligatorio")
      .refine((v) => !Number.isNaN(Number(v)), "Tiene que ser un número")
      .refine((v) => Number(v) >= 1, "Tiene que ser al menos 1"),
  })
  .superRefine((v, ctx) => {
    // Pagar en varias veces YA es un plazo, aunque el campo de días diga 0. Sin
    // este control quedan condiciones como "Contado en 3 cuotas" que después
    // nadie sabe cómo interpretar.
    if (Number(v.diasPago) === 0 && Number(v.cantidadCuotas) > 1) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Una condición de contado no puede tener más de una cuota",
        path: ["cantidadCuotas"],
      });
    }
  });

type FormValues = z.infer<typeof schema>;

/**
 * Cómo se lee una condición en una frase.
 *
 * Los dos números por separado no dicen mucho —"30 / 3" no es información— y
 * juntos sí: "3 cuotas, la última a 30 días". Se arma acá y no en el backend
 * porque es texto de presentación, no un dato.
 */
function describir(condicion: { diasPago: number; cantidadCuotas: number }): string {
  const { diasPago, cantidadCuotas } = condicion;

  if (diasPago === 0) return "Contado";
  if (cantidadCuotas === 1) return `Pago único a ${diasPago} días`;
  return `${cantidadCuotas} cuotas, la última a ${diasPago} días`;
}

/**
 * Las dos opciones del filtro "En uso": lo que importa es SI tiene facturas, no
 * cuántas — para decidir si se puede borrar, 47 y 3 son el mismo caso.
 */
const OPCIONES_USO = [
  { valor: "si", etiqueta: "En uso" },
  { valor: "no", etiqueta: "Sin usar" },
];

/**
 * Condiciones de pago: contado, plazos y cuotas.
 *
 * Catálogo global, como Países o Personas: no cuelga de la empresa activa, así
 * que no usa `useEmpresa()` ni lleva `idEmpresa` en la queryKey.
 *
 * La tabla no tiene columna de estado, así que la única baja es física — y una
 * condición usada por alguna factura no se puede borrar.
 */
function CondicionesPagoPage() {
  const queryClient = useQueryClient();
  const [creando, setCreando] = useState(false);
  const [editando, setEditando] = useState<CondicionPago | null>(null);
  const [aEliminar, setAEliminar] = useState<CondicionPago | null>(null);
  const [filtroUso, setFiltroUso] = useState<string>(SIN_FILTRO);

  const { data, isPending, isError } = useQuery({
    queryKey: ["condiciones-pago"],
    queryFn: () => api.condicionesPago.listar(),
  });

  const items = data?.items ?? [];

  const filtrados = items.filter((c) => {
    if (filtroUso === SIN_FILTRO) return true;
    return filtroUso === "si" ? c.usos > 0 : c.usos === 0;
  });

  // Sin buscador ni paginado: son unas pocas filas, y un input de búsqueda sobre
  // cinco opciones es ruido — pero el filtro de la columna sí, porque responde
  // "cuáles puedo borrar" de un click.
  const { orden, alternarOrden, resultado } = useTablaListado(filtrados, (c) => [
    c.nombreCondicion,
    describir(c),
  ]);

  const eliminar = useMutation({
    mutationFn: (condicion: CondicionPago) => api.condicionesPago.eliminar(condicion.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["condiciones-pago"] });
      toast.success("Condición eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      // El 409 llega con la cantidad de facturas que la usan: se muestra tal
      // cual en vez de un "no se pudo" que obligaría a ir a buscar por qué.
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar la condición"));
      setAEliminar(null);
    },
  });

  return (
    <AppLayout active="/condiciones-pago" title="Condiciones de pago">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Condiciones de pago</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Los plazos y las cuotas que se aplican a las facturas.
            </p>
          </div>
          <Button onClick={() => setCreando(true)}>
            <Plus className="size-4" />
            Nueva condición
          </Button>
        </div>

        {isPending ? (
          <div className="space-y-2">
            {[0, 1, 2].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        ) : isError ? (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
            No se pudieron cargar las condiciones.
          </p>
        ) : items.length === 0 ? (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              Todavía no hay condiciones cargadas. Sin al menos una, las facturas no pueden indicar
              cómo se pagan.
            </p>
            <Button className="mt-4" onClick={() => setCreando(true)}>
              Cargar la primera
            </Button>
          </div>
        ) : (
          <div className="surface-card overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "nombreCondicion" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreCondicion")}
                  >
                    Condición
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "diasPago" ? orden.direccion : null}
                    onClick={() => alternarOrden("diasPago")}
                  >
                    Días
                  </TableHeadOrdenable>
                  <TableHead className="text-right">Cuotas</TableHead>
                  {/* Filtrable: aislar las que no usó nadie responde "cuáles
                      puedo borrar" sin abrir una por una. */}
                  <TableHeadFiltrable
                    direccion={orden?.campo === "usos" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("usos")}
                    opciones={OPCIONES_USO}
                    valor={filtroUso}
                    onFiltrar={setFiltroUso}
                    buscarPlaceholder="Buscar…"
                    className="text-right"
                  >
                    En uso
                  </TableHeadFiltrable>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {resultado.map((condicion) => {
                  // Una condición sin uso se puede borrar; una en uso arrastra
                  // facturas y la FK lo impide.
                  const enUso = condicion.usos > 0;

                  return (
                    <TableRow key={condicion.id}>
                      <TableCell className="font-medium text-foreground">
                        {condicion.nombreCondicion}
                        {/* La frase en claro debajo del nombre: los dos números
                            sueltos de las columnas de al lado no se leen como
                            una forma de pago hasta que se los junta. */}
                        <span className="block text-xs font-normal text-muted-foreground">
                          {describir(condicion)}
                        </span>
                      </TableCell>
                      <TableCell className="tabular-nums text-muted-foreground">
                        {condicion.diasPago}
                      </TableCell>
                      <TableCell className="text-right tabular-nums text-muted-foreground">
                        {condicion.cantidadCuotas}
                      </TableCell>
                      <TableCell className="text-right">
                        {enUso ? (
                          <Badge variant="secondary">
                            {condicion.usos} factura{condicion.usos === 1 ? "" : "s"}
                          </Badge>
                        ) : (
                          <span className="text-xs text-muted-foreground">Sin usar</span>
                        )}
                      </TableCell>
                      <TableCell className="text-right">
                        <div className="flex justify-end gap-1">
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Editar"
                            aria-label={`Editar ${condicion.nombreCondicion}`}
                            onClick={() => setEditando(condicion)}
                          >
                            <Pencil className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            // Deshabilitado cuando está en uso: el backend igual
                            // lo rechaza con 409, pero enterarse después de
                            // confirmar es peor que no poder apretarlo.
                            title={
                              enUso
                                ? `No se puede eliminar: la usan ${condicion.usos} factura(s)`
                                : "Eliminar"
                            }
                            aria-label={`Eliminar ${condicion.nombreCondicion}`}
                            disabled={enUso}
                            onClick={() => setAEliminar(condicion)}
                          >
                            <Trash2 className="size-4 text-destructive" />
                          </Button>
                        </div>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>
        )}

        <p className="text-xs text-muted-foreground">
          El vencimiento de cada factura se calcula sumando los días de su condición a la fecha del
          comprobante. Editar una condición cambia el vencimiento de todas las facturas que la usan.
        </p>

        <CondicionFormDialog
          open={creando || editando !== null}
          condicion={editando}
          onClose={() => {
            setCreando(false);
            setEditando(null);
          }}
        />

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreCondicion}?</AlertDialogTitle>
              <AlertDialogDescription>
                Ninguna factura usa esta condición, así que se puede borrar sin afectar nada. No se
                puede deshacer.
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
/* Formulario                                                                  */
/* -------------------------------------------------------------------------- */

function CondicionFormDialog({
  open,
  condicion,
  onClose,
}: {
  open: boolean;
  condicion: CondicionPago | null;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = condicion !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    values: {
      nombreCondicion: condicion?.nombreCondicion ?? "",
      // Los defaults son los de contado, que es la condición más común y la
      // única que se puede asumir sin equivocarse.
      diasPago: condicion ? String(condicion.diasPago) : "0",
      cantidadCuotas: condicion ? String(condicion.cantidadCuotas) : "1",
    },
  });

  // La descripción en vivo, para ver cómo se va a leer la condición antes de
  // guardarla.
  const dias = Number(form.watch("diasPago"));
  const cuotas = Number(form.watch("cantidadCuotas"));
  const descripcion =
    !Number.isNaN(dias) && !Number.isNaN(cuotas) && dias >= 0 && cuotas >= 1
      ? describir({ diasPago: dias, cantidadCuotas: cuotas })
      : null;

  // Editar los plazos de una condición en uso mueve el vencimiento de esas
  // facturas. No se bloquea —corregir una condición mal cargada es válido— pero
  // se avisa con el número concreto.
  const cambioLosPlazos =
    esEdicion &&
    condicion.usos > 0 &&
    (dias !== condicion.diasPago || cuotas !== condicion.cantidadCuotas);

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const datos = {
        nombreCondicion: v.nombreCondicion,
        diasPago: Number(v.diasPago),
        cantidadCuotas: Number(v.cantidadCuotas),
      };

      return esEdicion
        ? api.condicionesPago.actualizar(condicion.id, datos)
        : api.condicionesPago.crear(datos);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["condiciones-pago"] });
      // Las facturas también: su vencimiento se calcula con estos días, así que
      // el listado en caché quedó viejo.
      queryClient.invalidateQueries({ queryKey: ["facturas-compras"] });
      queryClient.invalidateQueries({ queryKey: ["factura-compra"] });
      toast.success(esEdicion ? "Condición actualizada" : "Condición creada");
      form.reset();
      onClose();
    },
    onError: (e) =>
      toast.error(MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear")),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar condición" : "Nueva condición de pago"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Los cambios afectan el vencimiento de las facturas que la usan."
              : "Definí el plazo y las cuotas. Queda disponible para todas las empresas."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="nombreCondicion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Crédito 30 días" autoComplete="off" />
                  </FormControl>
                  <FormDescription>Es lo que se elige al cargar una factura.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="diasPago"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Días para pagar</FormLabel>
                    <FormControl>
                      {/* inputMode numeric abre el teclado numérico en móvil sin
                          las flechas de un type="number". */}
                      <Input
                        {...field}
                        inputMode="numeric"
                        placeholder="0"
                        autoComplete="off"
                        className="tabular-nums"
                      />
                    </FormControl>
                    <FormDescription>0 es contado.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="cantidadCuotas"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Cantidad de cuotas</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        inputMode="numeric"
                        placeholder="1"
                        autoComplete="off"
                        className="tabular-nums"
                      />
                    </FormControl>
                    <FormDescription>1 es pago único.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            {/* Cómo se va a leer: los dos números sueltos no dicen mucho, la
                frase sí. */}
            {descripcion !== null && (
              <p className="rounded-lg border border-border bg-muted px-3 py-2 text-sm text-muted-foreground">
                Se va a leer como: <strong className="text-foreground">{descripcion}</strong>
              </p>
            )}

            {cambioLosPlazos && (
              <p className="rounded-lg border border-warning/30 bg-warning/10 px-3 py-2 text-sm text-muted-foreground">
                Este cambio mueve el vencimiento de{" "}
                <strong className="text-foreground">
                  {condicion.usos} factura{condicion.usos === 1 ? "" : "s"}
                </strong>{" "}
                que usan esta condición.
              </p>
            )}

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onClose}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {guardar.isPending
                  ? "Guardando…"
                  : esEdicion
                    ? "Guardar cambios"
                    : "Crear condición"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/condiciones-pago")({
  head: () => ({
    meta: [
      { title: tituloPagina("Condiciones de pago") },
      { name: "description", content: "Plazos y cuotas que se aplican a las facturas." },
    ],
  }),
  component: CondicionesPagoPage,
});
