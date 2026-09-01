import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Eye, Loader2, Search, Trash2, TrendingUp } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import { api, ApiError, type Venta } from "@/lib/api";
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
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { tituloPagina } from "@/lib/marca";
import { formatearMoneda } from "@/lib/moneda";

const mensajeError = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Ventas emitidas: consulta y baja.
 *
 * NO ES UN ABM. No se puede editar una venta: cambiar el detalle después de
 * emitida movería stock y montos de un comprobante que ya se le entregó al
 * cliente. Lo único que se ofrece es ver y eliminar.
 *
 * Es la pantalla que faltaba: `/cobros` lista ventas pero desde la mirada de
 * tesorería —cuánto falta cobrar—, no desde la de administración de ventas.
 */
function VentasPage() {
  const { empresa } = useEmpresa();
  const { sucursal } = useSucursal();
  const queryClient = useQueryClient();
  const [busqueda, setBusqueda] = useState("");
  const [viendo, setViendo] = useState<Venta | null>(null);
  const [aEliminar, setAEliminar] = useState<Venta | null>(null);

  const ventas = useQuery({
    queryKey: ["ventas", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => api.ventas.listar({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
    enabled: empresa !== null && sucursal !== null,
  });

  const detalle = useQuery({
    queryKey: ["venta-detalle", viendo?.id ?? null, empresa?.id ?? null],
    queryFn: () => api.ventas.obtener(viendo!.id, empresa!.id),
    enabled: viendo !== null && empresa !== null,
  });

  const eliminar = useMutation({
    mutationFn: (venta: Venta) => api.ventas.eliminar(venta.id, empresa!.id),
    onSuccess: () => {
      toast.success("Venta eliminada");
      setAEliminar(null);
      queryClient.invalidateQueries({ queryKey: ["ventas"] });
      queryClient.invalidateQueries({ queryKey: ["cobros-ventas"] });
    },
    onError: (error) => {
      setAEliminar(null);
      toast.error(mensajeError(error, "No se pudo eliminar la venta"));
    },
  });

  const filtradas = (ventas.data?.items ?? []).filter((v) => {
    if (!busqueda) return true;
    const b = busqueda.toLowerCase();
    return v.numeroVenta.toLowerCase().includes(b) || (v.cliente ?? "").toLowerCase().includes(b);
  });

  return (
    <AppLayout active="/ventas" title="Ventas">
      <main className="min-h-[calc(100vh-4rem)] bg-muted/20 px-4 pb-10 pt-5 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-6xl space-y-5">
          <header>
            <div className="mb-2 flex items-center gap-2 text-xs font-medium uppercase tracking-[0.16em] text-primary">
              <TrendingUp className="size-4" />
              Comprobantes emitidos
            </div>
            <h1 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
              Ventas
            </h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {sucursal
                ? `${empresa?.nombreEmpresa} · ${sucursal.nombreSucursal}`
                : "Elegí una empresa y sucursal."}
            </p>
          </header>

          <div className="surface-card p-4">
            <div className="relative">
              <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={busqueda}
                onChange={(e) => setBusqueda(e.target.value)}
                placeholder="Buscar por número de comprobante o cliente…"
                className="pl-9"
              />
            </div>
          </div>

          <div className="surface-card overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Comprobante</TableHead>
                  <TableHead>Fecha</TableHead>
                  <TableHead>Tipo</TableHead>
                  <TableHead>Cliente</TableHead>
                  <TableHead className="text-right">Total</TableHead>
                  <TableHead className="text-right">Saldo</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {ventas.isPending && (
                  <TableRow>
                    <TableCell
                      colSpan={7}
                      className="py-10 text-center text-sm text-muted-foreground"
                    >
                      Cargando ventas…
                    </TableCell>
                  </TableRow>
                )}
                {ventas.isError && (
                  <TableRow>
                    <TableCell colSpan={7} className="py-10 text-center text-sm text-destructive">
                      {mensajeError(ventas.error, "No se pudo cargar la lista")}
                    </TableCell>
                  </TableRow>
                )}
                {!ventas.isPending && !ventas.isError && filtradas.length === 0 && (
                  <TableRow>
                    <TableCell
                      colSpan={7}
                      className="py-10 text-center text-sm text-muted-foreground"
                    >
                      {busqueda ? `Sin resultados para "${busqueda}".` : "Todavía no hay ventas."}
                    </TableCell>
                  </TableRow>
                )}
                {filtradas.map((v) => (
                  <TableRow key={v.id}>
                    <TableCell className="font-medium">{v.numeroVenta}</TableCell>
                    <TableCell className="text-sm text-muted-foreground">
                      {v.fechaVenta.slice(0, 10)}
                    </TableCell>
                    <TableCell>
                      <Badge variant="outline" className="text-xs">
                        {v.tipoComprobante}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-sm">
                      {v.cliente ?? <span className="text-muted-foreground">Ocasional</span>}
                    </TableCell>
                    <TableCell className="text-right text-sm font-semibold">
                      {formatearMoneda(v.montoTotal)}
                    </TableCell>
                    <TableCell className="text-right text-sm">
                      {v.saldoPendiente > 0 ? (
                        <span className="font-semibold text-primary">
                          {formatearMoneda(v.saldoPendiente)}
                        </span>
                      ) : (
                        <Badge variant="secondary" className="text-xs">
                          Cobrada
                        </Badge>
                      )}
                    </TableCell>
                    <TableCell>
                      <div className="flex justify-end gap-1">
                        <Button
                          variant="ghost"
                          size="icon"
                          className="size-8"
                          title="Ver detalle"
                          aria-label={`Ver la venta ${v.numeroVenta}`}
                          onClick={() => setViendo(v)}
                        >
                          <Eye className="size-4" />
                        </Button>
                        {/* Con cobros el backend responde 409: se deshabilita
                            acá para explicar el porqué antes del error. */}
                        <Button
                          variant="ghost"
                          size="icon"
                          className="size-8"
                          disabled={v.montoCobrado > 0}
                          title={
                            v.montoCobrado > 0
                              ? "Tiene cobros registrados: anulalos primero desde Cobros"
                              : "Eliminar venta"
                          }
                          aria-label={`Eliminar la venta ${v.numeroVenta}`}
                          onClick={() => setAEliminar(v)}
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
        </div>
      </main>

      {/* Detalle de sólo lectura: una venta emitida no se edita. */}
      <Dialog open={viendo !== null} onOpenChange={(open) => !open && setViendo(null)}>
        <DialogContent className="max-h-[90vh] max-w-3xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Venta {viendo?.numeroVenta}</DialogTitle>
            <p className="text-sm text-muted-foreground">
              {viendo?.cliente ?? "Cliente ocasional"} · {viendo?.fechaVenta.slice(0, 10)} ·
              Timbrado {viendo?.nroTimbrado}
            </p>
          </DialogHeader>

          {detalle.isPending ? (
            <p className="py-6 text-center text-sm text-muted-foreground">Cargando detalle…</p>
          ) : detalle.isError ? (
            <p className="rounded-lg border border-destructive/30 bg-destructive/10 p-4 text-sm text-destructive">
              No se pudo cargar el detalle.
            </p>
          ) : (
            <div className="space-y-4">
              <div className="overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="h-8 text-xs">Artículo</TableHead>
                      <TableHead className="h-8 text-right text-xs">Cant.</TableHead>
                      <TableHead className="h-8 text-right text-xs">Precio</TableHead>
                      <TableHead className="h-8 text-right text-xs">IVA</TableHead>
                      <TableHead className="h-8 text-right text-xs">Total</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {(detalle.data?.detalle ?? []).map((d) => (
                      <TableRow key={d.id} className="text-sm">
                        <TableCell className="py-2">{d.articulo ?? `#${d.idArticulo}`}</TableCell>
                        <TableCell className="py-2 text-right">{d.cantidad}</TableCell>
                        <TableCell className="py-2 text-right">
                          {formatearMoneda(d.precioUnitario)}
                        </TableCell>
                        <TableCell className="py-2 text-right text-muted-foreground">
                          {formatearMoneda(d.montoIva)}
                        </TableCell>
                        <TableCell className="py-2 text-right font-semibold">
                          {formatearMoneda(d.total)}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>

              <div className="ml-auto max-w-xs space-y-1 border-t border-border pt-3 text-sm">
                <div className="flex justify-between text-muted-foreground">
                  <span>Gravado</span>
                  <span>{formatearMoneda(detalle.data?.cabecera.montoGravado ?? 0)}</span>
                </div>
                {/* "incluido", no un renglón a sumar: el precio ya lo trae. */}
                <div className="flex justify-between text-muted-foreground">
                  <span>IVA incluido</span>
                  <span>{formatearMoneda(detalle.data?.cabecera.montoIva ?? 0)}</span>
                </div>
                <div className="flex justify-between pt-1 font-semibold">
                  <span>Total</span>
                  <span>{formatearMoneda(detalle.data?.cabecera.montoTotal ?? 0)}</span>
                </div>
              </div>

              {(detalle.data?.cuotas ?? []).length > 0 && (
                <div>
                  <p className="mb-2 text-xs font-medium uppercase tracking-wider text-muted-foreground">
                    Cuotas
                  </p>
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead className="h-8 text-xs">Cuota</TableHead>
                        <TableHead className="h-8 text-xs">Vence</TableHead>
                        <TableHead className="h-8 text-right text-xs">Monto</TableHead>
                        <TableHead className="h-8 text-right text-xs">Pendiente</TableHead>
                        <TableHead className="h-8 text-xs">Estado</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {(detalle.data?.cuotas ?? []).map((c) => (
                        <TableRow key={c.id} className="text-sm">
                          <TableCell className="py-2">#{c.nroCuota}</TableCell>
                          <TableCell className="py-2 text-muted-foreground">
                            {c.fechaVencimiento}
                          </TableCell>
                          <TableCell className="py-2 text-right">
                            {formatearMoneda(c.montoCuota)}
                          </TableCell>
                          <TableCell className="py-2 text-right">
                            {formatearMoneda(c.saldoPendiente)}
                          </TableCell>
                          <TableCell className="py-2">
                            <Badge
                              variant={c.estado === "PAGADO" ? "secondary" : "outline"}
                              className="text-xs"
                            >
                              {c.estado}
                            </Badge>
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
              )}
            </div>
          )}
        </DialogContent>
      </Dialog>

      <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar la venta {aEliminar?.numeroVenta}?</AlertDialogTitle>
            {/* El aviso dice lo que REALMENTE pasa, incluido lo que no se
                deshace: el número de comprobante ya se consumió del talonario y
                no vuelve, así que la secuencia queda con un hueco. */}
            <AlertDialogDescription>
              Las unidades vendidas <strong>no</strong> vuelven al stock: por ahora vender tampoco
              lo descuenta. El número de comprobante <strong>no</strong> se reutiliza: la secuencia
              del talonario queda con un hueco. Esta acción no se puede deshacer.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              onClick={(e) => {
                e.preventDefault();
                if (aEliminar) eliminar.mutate(aEliminar);
              }}
              disabled={eliminar.isPending}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {eliminar.isPending && <Loader2 className="size-4 animate-spin" />}Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </AppLayout>
  );
}

export const Route = createFileRoute("/_auth/ventas")({
  head: () => ({
    meta: [
      { title: tituloPagina("Ventas") },
      { name: "description", content: "Comprobantes de venta emitidos: consulta y baja." },
    ],
  }),
  component: VentasPage,
});
