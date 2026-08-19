import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { AlertTriangle, Loader2, Pencil, Plus, Trash2 } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, type Iva } from "@/lib/api";
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
 * Sólo porcentaje y descripción.
 *
 * **Los dos divisores no están en el formulario**: los calcula el backend a
 * partir del porcentaje, y valida contra la fórmula cualquier valor que reciba.
 * Pedirlos sería ofrecer la posibilidad de equivocarse en los únicos números que
 * no avisan cuando están mal — sólo dan cifras equivocadas en cada factura.
 */
const schema = z.object({
  porcentaje: z
    .string()
    .trim()
    .min(1, "Obligatorio")
    .refine((v) => !Number.isNaN(Number(v)), "Tiene que ser un número")
    .refine((v) => Number(v) >= 0 && Number(v) <= 100, "Tiene que estar entre 0 y 100"),
  descripcion: z.string().trim().max(100, "Máximo 100 caracteres"),
});

type FormValues = z.infer<typeof schema>;

/**
 * Los dos divisores que corresponden a un porcentaje.
 *
 * Duplican las fórmulas del SQL a propósito: acá son la vista previa de lo que
 * va a calcular el backend, que sigue siendo el único que decide qué se guarda.
 *
 * **La exenta usa criterios opuestos en los dos**, y es lo fácil de confundir:
 * `iva` va en 0 —no divide nada— y `gravada` en 1 —el monto entero es gravado—.
 */
function divisoresEsperados(porcentaje: number): { iva: number; gravada: number } {
  return {
    iva: porcentaje === 0 ? 0 : Math.round((100 / porcentaje + 1) * 100) / 100,
    gravada: Math.round((1 + porcentaje / 100) * 100) / 100,
  };
}

/**
 * Las dos opciones del filtro "En uso". Se filtra por si la tasa tiene o no
 * facturas, no por la cantidad: "usada 47 veces" y "usada 3 veces" son el mismo
 * caso a la hora de decidir si se puede borrar.
 */
const OPCIONES_USO = [
  { valor: "si", etiqueta: "En uso" },
  { valor: "no", etiqueta: "Sin usar" },
];

/**
 * Tasas de IVA.
 *
 * ABM completo, pero con una advertencia que ninguna otra pantalla necesita:
 * **el impuesto de cada línea de factura no se guarda, se calcula** como
 * `subtotal / ivaDivision`. Editar una tasa cambia el desglose de todas las
 * facturas que ya la usaban — incluidas las de períodos ya declarados.
 *
 * Por eso el listado muestra en cuántas líneas se usa cada tasa, y el
 * formulario avisa antes de dejar guardar. No se bloquea: a veces corregir una
 * tasa mal cargada es exactamente lo que hay que hacer, y ahí arreglar las
 * facturas viejas es lo correcto.
 *
 * Es un catálogo global: no cuelga de la empresa activa.
 */
function IvaPage() {
  const queryClient = useQueryClient();
  const [creando, setCreando] = useState(false);
  const [editando, setEditando] = useState<Iva | null>(null);
  const [aEliminar, setAEliminar] = useState<Iva | null>(null);
  const [filtroUso, setFiltroUso] = useState<string>(SIN_FILTRO);

  const { data, isPending, isError } = useQuery({
    queryKey: ["iva"],
    queryFn: () => api.iva.listar(),
  });

  const items = data?.items ?? [];

  const filtrados = items.filter((i) => {
    if (filtroUso === SIN_FILTRO) return true;
    return filtroUso === "si" ? i.usos > 0 : i.usos === 0;
  });

  // Sin buscador ni paginado, al revés que el resto de los listados: son tres o
  // cuatro filas. Un input de búsqueda sobre eso es ruido — pero el filtro de la
  // columna sí, porque responde "cuáles puedo borrar" de un click.
  const { orden, alternarOrden, resultado } = useTablaListado(filtrados, (i) => [
    i.descripcion,
    String(i.porcentaje),
  ]);

  const eliminar = useMutation({
    mutationFn: (tasa: Iva) => api.iva.eliminar(tasa.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["iva"] });
      toast.success("Tasa eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      // El 409 llega con la cantidad de líneas que la usan: se muestra tal cual
      // en vez de un "no se pudo" que obligaría a ir a buscar por qué.
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar la tasa"));
      setAEliminar(null);
    },
  });

  return (
    <AppLayout active="/iva" title="Tasas de IVA">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Tasas de IVA</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Las alícuotas que se aplican al detalle de las facturas.
            </p>
          </div>
          <Button onClick={() => setCreando(true)}>
            <Plus className="size-4" />
            Nueva tasa
          </Button>
        </div>

        {/* EL AVISO ES LA PARTE IMPORTANTE DE ESTA PANTALLA. Editar una tasa no
            se siente peligroso —es un número chico en una tabla de tres filas—
            y sin embargo alcanza para cambiar el IVA declarado de meses. */}
        <div className="flex gap-3 rounded-lg border border-warning/30 bg-warning/10 px-4 py-3">
          <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" />
          <div className="space-y-1 text-sm text-muted-foreground">
            <p className="font-medium text-foreground">
              Editar una tasa cambia las facturas que ya la usan.
            </p>
            <p>
              El IVA de cada línea no se guarda: se calcula con estos valores cada vez que se mira
              una factura. Si cambia la ley, conviene crear una tasa nueva y dejar la anterior para
              los comprobantes históricos; editá sólo cuando la tasa se haya cargado mal.
            </p>
          </div>
        </div>

        {isPending ? (
          <div className="space-y-2">
            {[0, 1, 2].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        ) : isError ? (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
            No se pudieron cargar las tasas.
          </p>
        ) : items.length === 0 ? (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              Todavía no hay tasas cargadas. Sin al menos una, el detalle de las facturas no puede
              asignar IVA.
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
                    direccion={orden?.campo === "descripcion" ? orden.direccion : null}
                    onClick={() => alternarOrden("descripcion")}
                  >
                    Descripción
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "porcentaje" ? orden.direccion : null}
                    onClick={() => alternarOrden("porcentaje")}
                  >
                    Porcentaje
                  </TableHeadOrdenable>
                  <TableHead className="text-right">Div. IVA</TableHead>
                  <TableHead className="text-right">Div. gravada</TableHead>
                  {/* Filtrable y no un simple header: con varias tasas, aislar
                      las que no usó nadie es la forma de ver cuáles se pueden
                      borrar sin abrir cada una. */}
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
                {resultado.map((tasa) => {
                  // Una tasa que no usó nadie se puede tocar sin consecuencias;
                  // una en uso arrastra facturas.
                  const enUso = tasa.usos > 0;

                  return (
                    <TableRow key={tasa.id}>
                      <TableCell className="font-medium text-foreground">
                        {tasa.descripcion}
                      </TableCell>
                      <TableCell className="tabular-nums">{tasa.porcentaje}%</TableCell>
                      <TableCell className="text-right tabular-nums text-muted-foreground">
                        {/* La exenta lleva 0 y no divide nada: mostrar "0" a
                            secas se leería como un divisor válido. */}
                        {tasa.ivaDivision === 0 ? "—" : tasa.ivaDivision}
                      </TableCell>
                      <TableCell className="text-right tabular-nums text-muted-foreground">
                        {/* Null es distinto de "—": la tasa es anterior a esta
                            columna y usa el cálculo viejo. Se marca para que se
                            note que hay algo que completar — editarla y guardar
                            la migra sola. */}
                        {tasa.gravadaDivision === null ? (
                          <span className="text-xs text-warning">Sin cargar</span>
                        ) : (
                          tasa.gravadaDivision
                        )}
                      </TableCell>
                      <TableCell className="text-right">
                        {enUso ? (
                          <Badge variant="secondary">
                            {tasa.usos} línea{tasa.usos === 1 ? "" : "s"}
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
                            aria-label={`Editar ${tasa.descripcion}`}
                            onClick={() => setEditando(tasa)}
                          >
                            <Pencil className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            // El botón de borrar se deshabilita cuando la tasa
                            // está en uso: el backend igual lo rechaza con 409,
                            // pero enterarse después de confirmar es peor que no
                            // poder apretarlo. El title explica por qué.
                            title={
                              enUso
                                ? `No se puede eliminar: la usan ${tasa.usos} línea(s) de factura`
                                : "Eliminar"
                            }
                            aria-label={`Eliminar ${tasa.descripcion}`}
                            disabled={enUso}
                            onClick={() => setAEliminar(tasa)}
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

        {/* QUÉ ES EL DIVISOR: la columna no se explica sola, y es justo el número
            del que depende que el IVA de cada factura esté bien. */}
        <p className="text-xs text-muted-foreground">
          Los precios se cargan con IVA incluido, así que el impuesto se obtiene{" "}
          <strong>dividiendo</strong> el subtotal por el divisor —no multiplicando por el
          porcentaje—. Una línea de 110.000 al 10% contiene 10.000 de IVA (110.000 ÷ 11), no 11.000.
        </p>

        <IvaFormDialog
          open={creando || editando !== null}
          tasa={editando}
          onClose={() => {
            setCreando(false);
            setEditando(null);
          }}
        />

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.descripcion}?</AlertDialogTitle>
              <AlertDialogDescription>
                Ninguna factura usa esta tasa, así que se puede borrar sin afectar nada. No se puede
                deshacer.
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

function IvaFormDialog({
  open,
  tasa,
  onClose,
}: {
  open: boolean;
  tasa: Iva | null;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = tasa !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    values: {
      porcentaje: tasa ? String(tasa.porcentaje) : "",
      descripcion: tasa?.descripcion ?? "",
    },
  });

  const porcentajeTexto = form.watch("porcentaje");
  const porcentaje = Number(porcentajeTexto);
  const porcentajeValido =
    porcentajeTexto !== "" && !Number.isNaN(porcentaje) && porcentaje >= 0 && porcentaje <= 100;

  // Los divisores que van a quedar. Es sólo una vista previa: los calcula el
  // backend, que además rechaza cualquier valor que no cuadre con la fórmula.
  const divisores = porcentajeValido ? divisoresEsperados(porcentaje) : null;

  // Si se cambió el porcentaje de una tasa en uso, el aviso deja de ser genérico
  // y pasa a decir cuántas facturas se ven afectadas.
  const cambioElCalculo = esEdicion && tasa.usos > 0 && porcentaje !== tasa.porcentaje;

  // Una tasa anterior a GRAVADA_DIVISION: guardar la completa y la pasa al
  // método nuevo. Se avisa porque el desglose de sus facturas puede moverse un
  // guaraní al recalcularse.
  const completaGravada = esEdicion && tasa.gravadaDivision === null;

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const datos = {
        porcentaje: Number(v.porcentaje),
        // LOS DIVISORES NO VIAJAN: los calcula el backend. Omitirlos es lo que
        // hace que al cambiar el porcentaje se recalculen los dos, en vez de
        // quedar los viejos con una tasa nueva.
        ...(v.descripcion ? { descripcion: v.descripcion } : {}),
      };

      return esEdicion ? api.iva.actualizar(tasa.id, datos) : api.iva.crear(datos);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["iva"] });
      // Las facturas también: su desglose depende de estos números, así que el
      // detalle en caché quedó viejo.
      queryClient.invalidateQueries({ queryKey: ["factura-compra"] });
      toast.success(esEdicion ? "Tasa actualizada" : "Tasa creada");
      form.reset();
      onClose();
    },
    onError: (e) =>
      toast.error(MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear")),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="scrollbar-fino max-h-[92vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar tasa" : "Nueva tasa de IVA"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Los cambios se reflejan en todas las facturas que usan esta tasa."
              : "Definí la alícuota. El divisor se calcula solo a partir del porcentaje."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="porcentaje"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Porcentaje</FormLabel>
                  <FormControl>
                    {/* inputMode decimal abre el teclado numérico en móvil sin
                        las flechas de un type="number". */}
                    <Input
                      {...field}
                      inputMode="decimal"
                      placeholder="10"
                      autoComplete="off"
                      className="tabular-nums"
                    />
                  </FormControl>
                  <FormDescription>Sin el signo %. Un 0 crea una tasa exenta.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            {/* LOS DIVISORES SON UNA VISTA PREVIA, no campos: los calcula el
                backend. Se muestran igual porque son lo que define el desglose
                de cada factura, y conviene verlos antes de guardar. */}
            {divisores !== null && (
              <div className="space-y-2 rounded-lg border border-border bg-muted p-3">
                <p className="text-sm font-medium text-foreground">Divisores calculados</p>

                {porcentaje === 0 ? (
                  <p className="text-sm text-muted-foreground">
                    Tasa exenta: el monto entero es gravado y no aporta impuesto.
                  </p>
                ) : (
                  <>
                    <dl className="space-y-1 text-sm text-muted-foreground">
                      <div className="flex justify-between gap-4">
                        <dt>Gravada (base imponible)</dt>
                        <dd className="tabular-nums text-foreground">{divisores.gravada}</dd>
                      </div>
                      <div className="flex justify-between gap-4">
                        <dt>IVA</dt>
                        <dd className="tabular-nums text-foreground">{divisores.iva}</dd>
                      </div>
                    </dl>
                    {/* El ejemplo concreto: es lo que permite verificar de un
                        vistazo que la tasa quedó bien, sin entender la fórmula. */}
                    <p className="text-xs text-muted-foreground">
                      Una línea de 100 con esta tasa se desglosa en{" "}
                      <strong className="text-foreground">
                        {(Math.round((100 / divisores.gravada) * 100) / 100).toLocaleString(
                          "es-PY",
                        )}
                      </strong>{" "}
                      de gravado y{" "}
                      <strong className="text-foreground">
                        {(Math.round((100 - 100 / divisores.gravada) * 100) / 100).toLocaleString(
                          "es-PY",
                        )}
                      </strong>{" "}
                      de IVA.
                    </p>
                  </>
                )}
              </div>
            )}

            {/* Las tasas anteriores a GRAVADA_DIVISION se completan al guardar.
                Se avisa porque el desglose de sus facturas puede moverse un
                guaraní: pasan del cálculo por resta al cálculo por división. */}
            {completaGravada && (
              <p className="rounded-lg border border-border bg-muted px-3 py-2 text-sm text-muted-foreground">
                Esta tasa no tiene cargado el divisor de gravada. Al guardar se completa y su
                desglose pasa a calcularse con el método nuevo.
              </p>
            )}

            {/* EL AVISO CONCRETO, no el genérico de la página: acá ya se sabe
                cuántas facturas se van a ver afectadas por este cambio puntual. */}
            {cambioElCalculo && (
              <div className="flex gap-3 rounded-lg border border-warning/30 bg-warning/10 px-3 py-2">
                <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" />
                <p className="text-sm text-muted-foreground">
                  Este cambio afecta el IVA de{" "}
                  <strong className="text-foreground">
                    {tasa.usos} línea{tasa.usos === 1 ? "" : "s"}
                  </strong>{" "}
                  de factura ya cargadas. Su desglose se va a recalcular con los valores nuevos.
                </p>
              </div>
            )}

            <FormField
              control={form.control}
              name="descripcion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Descripción</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="IVA 10%" autoComplete="off" />
                  </FormControl>
                  <FormDescription>
                    Es lo que se ve en el combobox de las facturas. Si la dejás vacía se arma sola.
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onClose}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {guardar.isPending ? "Guardando…" : esEdicion ? "Guardar cambios" : "Crear tasa"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/iva")({
  head: () => ({
    meta: [
      { title: tituloPagina("Tasas de IVA") },
      { name: "description", content: "Alícuotas de IVA que se aplican en las facturas." },
    ],
  }),
  component: IvaPage,
});
