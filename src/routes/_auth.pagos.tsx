import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Banknote, Loader2, Receipt, Search, Trash2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { AppLayout } from "@/components/ctell/AppLayout";
import { InputMoneda } from "@/components/ctell/InputMoneda";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import {
  api,
  ApiError,
  esActivo,
  requiereCuentaBancaria,
  type CanalPago,
  type CuentaBancaria,
  type FacturaCompra,
  type PagoCompra,
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
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { tituloPagina } from "@/lib/marca";
import { formatearMoneda, numeroMoneda } from "@/lib/moneda";

const hoy = () => new Date().toISOString().slice(0, 19);
const errorTexto = (error: unknown) =>
  error instanceof ApiError ? error.message : "No se pudo registrar el pago";

/**
 * Pagos a proveedores. Espejo de `/cobros`, con la plata saliendo.
 *
 * Si cambia una de las dos pantallas, mirar la otra: comparten el criterio de
 * saldo derivado, el tope por cuota y el historial con baja.
 */
function PagosPage() {
  const { empresa } = useEmpresa();
  const { sucursal } = useSucursal();
  const queryClient = useQueryClient();
  const [busqueda, setBusqueda] = useState("");
  const [facturaSeleccionada, setFacturaSeleccionada] = useState<FacturaCompra | null>(null);
  const [idCuota, setIdCuota] = useState("");
  const [idCanalPago, setIdCanalPago] = useState("");
  const [montoPago, setMontoPago] = useState("");
  const [referencia, setReferencia] = useState("");
  const [idCuentaBancaria, setIdCuentaBancaria] = useState("");
  /** Se guarda el id, no la fila: así los totales del modal se actualizan solos. */
  const [idFacturaHistorial, setIdFacturaHistorial] = useState<number | null>(null);
  const [pagoAEliminar, setPagoAEliminar] = useState<PagoCompra | null>(null);

  const facturas = useQuery({
    queryKey: ["facturas-compras", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => api.facturasCompras.listar({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
    enabled: empresa !== null && sucursal !== null,
  });

  const facturaDetalle = useQuery({
    queryKey: ["pagos-detalle", facturaSeleccionada?.id ?? null, empresa?.id ?? null],
    queryFn: () => api.facturasCompras.obtener(facturaSeleccionada!.id, empresa!.id),
    enabled: facturaSeleccionada !== null && empresa !== null,
  });

  const canales = useQuery({
    queryKey: ["canales-pagos"],
    queryFn: () => api.canalesPagos.listar(),
  });

  const cuentas = useQuery({
    queryKey: ["cuentas-bancarias", empresa?.id ?? null],
    queryFn: () => api.cuentasBancarias.listar(empresa!.id),
    enabled: empresa !== null,
  });

  const historial = useQuery({
    queryKey: ["pagos-historial", idFacturaHistorial, empresa?.id ?? null],
    queryFn: () => api.comprasPagos.listar(idFacturaHistorial!, empresa!.id),
    enabled: idFacturaHistorial !== null && empresa !== null,
  });

  const cuotasPendientes = (facturaDetalle.data?.cuotas ?? []).filter((c) => c.saldoPendiente > 0);
  const canalElegido = (canales.data?.items ?? []).find(
    (canal) => String(canal.id) === idCanalPago,
  );
  /**
   * El tope real de este pago: el saldo de la cuota si se imputa a una, si no el
   * de la factura. El backend valida lo mismo con la cabecera bloqueada.
   */
  const cuotaElegida = cuotasPendientes.find((c) => String(c.id) === idCuota);
  const saldoTope = cuotaElegida?.saldoPendiente ?? facturaSeleccionada?.saldoPendiente ?? 0;
  const montoIngresado = numeroMoneda(montoPago);
  const excedeSaldo = Number.isFinite(montoIngresado) && montoIngresado > saldoTope;

  const abrirDialog = (factura: FacturaCompra) => {
    setFacturaSeleccionada(factura);
    setIdCuota("");
    setIdCanalPago("");
    setMontoPago("");
    setReferencia("");
    setIdCuentaBancaria("");
  };

  const cerrarDialog = () => setFacturaSeleccionada(null);

  // Al elegir cuota, pre-llena el monto con su saldo pendiente.
  const onCuotaChange = (valor: string) => {
    setIdCuota(valor);
    const cuota = cuotasPendientes.find((c) => String(c.id) === valor);
    if (cuota) setMontoPago(formatearMoneda(cuota.saldoPendiente));
  };

  const invalidarTodo = () => {
    queryClient.invalidateQueries({ queryKey: ["facturas-compras"] });
    queryClient.invalidateQueries({ queryKey: ["pagos-detalle"] });
    queryClient.invalidateQueries({ queryKey: ["pagos-historial"] });
  };

  const pago = useMutation({
    mutationFn: () =>
      api.comprasPagos.crear({
        idFactura: facturaSeleccionada!.id,
        idEmpresa: empresa!.id,
        ...(idCuota ? { idCuota: Number(idCuota) } : {}),
        idCanalPago: Number(idCanalPago),
        idMoneda: facturaSeleccionada!.idMoneda,
        monto: numeroMoneda(montoPago),
        fechaPago: hoy(),
        ...(referencia ? { referencia } : {}),
        ...(idCuentaBancaria ? { idCuentaBancaria: Number(idCuentaBancaria) } : {}),
      }),
    onSuccess: () => {
      toast.success("Pago registrado");
      cerrarDialog();
      invalidarTodo();
    },
    onError: (error) => toast.error(errorTexto(error)),
  });

  const eliminarPago = useMutation({
    mutationFn: (p: PagoCompra) => api.comprasPagos.eliminar(p.id, empresa!.id),
    onSuccess: () => {
      toast.success("Pago eliminado, la factura vuelve a tener saldo");
      setPagoAEliminar(null);
      invalidarTodo();
    },
    onError: (error) => {
      setPagoAEliminar(null);
      toast.error(error instanceof ApiError ? error.message : "No se pudo eliminar el pago");
    },
  });

  const puedeConfirmar =
    facturaSeleccionada &&
    idCanalPago &&
    Number.isFinite(montoIngresado) &&
    montoIngresado > 0 &&
    !excedeSaldo;

  const facturaHistorial =
    (facturas.data?.items ?? []).find((f) => f.id === idFacturaHistorial) ?? null;

  const filtradas = (facturas.data?.items ?? []).filter((f) => {
    if (!busqueda) return true;
    const b = busqueda.toLowerCase();
    return f.numeroFactura.toLowerCase().includes(b) || f.proveedor.toLowerCase().includes(b);
  });

  return (
    <AppLayout active="/pagos" title="Pagos a proveedores">
      <main className="min-h-[calc(100vh-4rem)] bg-muted/20 px-4 pb-10 pt-5 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-5xl space-y-5">
          <header>
            <div className="mb-2 flex items-center gap-2 text-xs font-medium uppercase tracking-[0.16em] text-primary">
              <Banknote className="size-4" />
              Tesorería
            </div>
            <h1 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
              Pagos a proveedores
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
                placeholder="Buscar por número de factura o proveedor…"
                className="pl-9"
              />
            </div>
          </div>

          <div className="surface-card overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Factura</TableHead>
                  <TableHead>Fecha</TableHead>
                  <TableHead>Proveedor</TableHead>
                  <TableHead className="text-right">Total</TableHead>
                  <TableHead className="text-right">Saldo</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {facturas.isPending && (
                  <TableRow>
                    <TableCell
                      colSpan={6}
                      className="py-10 text-center text-sm text-muted-foreground"
                    >
                      Cargando facturas…
                    </TableCell>
                  </TableRow>
                )}
                {!facturas.isPending && filtradas.length === 0 && (
                  <TableRow>
                    <TableCell
                      colSpan={6}
                      className="py-10 text-center text-sm text-muted-foreground"
                    >
                      No hay facturas de compra
                    </TableCell>
                  </TableRow>
                )}
                {filtradas.map((f) => (
                  <TableRow key={f.id}>
                    <TableCell className="font-medium">{f.numeroFactura}</TableCell>
                    <TableCell className="text-sm text-muted-foreground">
                      {f.fechaFactura}
                    </TableCell>
                    <TableCell className="text-sm">{f.proveedor}</TableCell>
                    <TableCell className="text-right text-sm font-semibold">
                      {formatearMoneda(f.total)}
                    </TableCell>
                    <TableCell className="text-right text-sm">
                      {f.saldoPendiente > 0 ? (
                        <span className="font-semibold text-primary">
                          {formatearMoneda(f.saldoPendiente)}
                        </span>
                      ) : (
                        <Badge variant="secondary" className="text-xs">
                          Pagada
                        </Badge>
                      )}
                    </TableCell>
                    <TableCell>
                      <div className="flex justify-end gap-2">
                        {/* La factura saldada no se puede pagar pero SÍ auditar:
                            es cuando más se pregunta cómo se pagó. */}
                        <Button
                          size="sm"
                          variant="ghost"
                          disabled={f.montoPagado <= 0}
                          onClick={() => setIdFacturaHistorial(f.id)}
                          title="Ver cómo se pagó"
                        >
                          <Receipt className="size-4" />
                          <span className="hidden sm:inline">Ver pagos</span>
                        </Button>
                        <Button
                          size="sm"
                          variant="outline"
                          disabled={f.saldoPendiente <= 0}
                          onClick={() => abrirDialog(f)}
                        >
                          Registrar pago
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

      <Dialog open={facturaSeleccionada !== null} onOpenChange={(open) => !open && cerrarDialog()}>
        <DialogContent className="max-h-[90vh] max-w-lg overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Pago — Factura {facturaSeleccionada?.numeroFactura}</DialogTitle>
            <p className="text-sm text-muted-foreground">
              Total {formatearMoneda(facturaSeleccionada?.total ?? 0)} · Pagado{" "}
              {formatearMoneda(facturaSeleccionada?.montoPagado ?? 0)} ·{" "}
              <strong className="text-foreground">
                Saldo {formatearMoneda(facturaSeleccionada?.saldoPendiente ?? 0)}
              </strong>
            </p>
          </DialogHeader>

          {facturaDetalle.isPending ? (
            <p className="py-6 text-center text-sm text-muted-foreground">Cargando cuotas…</p>
          ) : (
            <div className="space-y-4">
              {cuotasPendientes.length > 0 ? (
                <div>
                  <p className="mb-2 text-xs font-medium uppercase tracking-wider text-muted-foreground">
                    Cuotas pendientes
                  </p>
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead className="h-8 text-xs">Cuota</TableHead>
                        <TableHead className="h-8 text-xs">Vence</TableHead>
                        <TableHead className="h-8 text-right text-xs">Monto</TableHead>
                        <TableHead className="h-8 text-right text-xs">Pendiente</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {cuotasPendientes.map((c) => (
                        <TableRow key={c.id} className="text-sm">
                          <TableCell className="py-2">#{c.nroCuota}</TableCell>
                          <TableCell className="py-2 text-muted-foreground">
                            {c.fechaVencimiento}
                          </TableCell>
                          <TableCell className="py-2 text-right">
                            {formatearMoneda(c.montoCuota)}
                          </TableCell>
                          <TableCell className="py-2 text-right font-semibold text-primary">
                            {formatearMoneda(c.saldoPendiente)}
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
              ) : (
                <Badge variant="secondary">Esta factura no tiene cuotas pendientes</Badge>
              )}

              <div className="space-y-3 border-t border-border pt-3">
                {cuotasPendientes.length > 1 && (
                  <Select value={idCuota} onValueChange={onCuotaChange}>
                    <SelectTrigger>
                      <SelectValue placeholder="Aplicar a cuota específica (opcional)" />
                    </SelectTrigger>
                    <SelectContent>
                      {cuotasPendientes.map((c) => (
                        <SelectItem key={c.id} value={String(c.id)}>
                          Cuota #{c.nroCuota} · Pendiente: {formatearMoneda(c.saldoPendiente)}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                )}

                <Select
                  value={idCanalPago}
                  onValueChange={(valor) => {
                    setIdCanalPago(valor);
                    const canal = (canales.data?.items ?? []).find((c) => String(c.id) === valor);
                    if (!requiereCuentaBancaria(canal)) setIdCuentaBancaria("");
                  }}
                >
                  <SelectTrigger>
                    <SelectValue placeholder="Canal de pago *" />
                  </SelectTrigger>
                  <SelectContent>
                    {(canales.data?.items ?? [])
                      .filter((c: CanalPago) => esActivo(c.activo))
                      .map((c) => (
                        <SelectItem key={c.id} value={String(c.id)}>
                          {c.nombreCanal}
                        </SelectItem>
                      ))}
                  </SelectContent>
                </Select>

                <InputMoneda
                  value={montoPago}
                  onChange={setMontoPago}
                  placeholder="Monto pagado *"
                />
                {excedeSaldo && (
                  <p className="text-xs text-destructive">
                    El monto supera el saldo pendiente ({formatearMoneda(saldoTope)}).
                  </p>
                )}

                <Input
                  value={referencia}
                  onChange={(e) => setReferencia(e.target.value)}
                  placeholder="Referencia (N° transferencia, cheque…)"
                />

                {idCanalPago && requiereCuentaBancaria(canalElegido) && (
                  <Select value={idCuentaBancaria} onValueChange={setIdCuentaBancaria}>
                    <SelectTrigger>
                      <SelectValue placeholder="Cuenta bancaria de origen" />
                    </SelectTrigger>
                    <SelectContent>
                      {(cuentas.data?.items ?? [])
                        .filter((c: CuentaBancaria) => esActivo(c.activo))
                        .map((c) => (
                          <SelectItem key={c.id} value={String(c.id)}>
                            {c.banco} · {c.numeroCuenta}
                          </SelectItem>
                        ))}
                    </SelectContent>
                  </Select>
                )}

                <Button
                  className="h-11 w-full"
                  disabled={!puedeConfirmar || pago.isPending}
                  onClick={() => pago.mutate()}
                >
                  {pago.isPending ? "Registrando..." : "Confirmar pago"}
                </Button>
              </div>
            </div>
          )}
        </DialogContent>
      </Dialog>

      {/* Historial: cómo se pagó esta factura */}
      <Dialog
        open={idFacturaHistorial !== null}
        onOpenChange={(open) => !open && setIdFacturaHistorial(null)}
      >
        <DialogContent className="max-h-[90vh] max-w-2xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Pagos — Factura {facturaHistorial?.numeroFactura}</DialogTitle>
            <p className="text-sm text-muted-foreground">
              {facturaHistorial?.proveedor} · {facturaHistorial?.fechaFactura}
            </p>
          </DialogHeader>

          <div className="grid grid-cols-3 gap-3 rounded-lg border border-border p-3 text-sm">
            <div>
              <p className="text-xs text-muted-foreground">Total</p>
              <p className="font-semibold">{formatearMoneda(facturaHistorial?.total ?? 0)}</p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Pagado</p>
              <p className="font-semibold text-success">
                {formatearMoneda(facturaHistorial?.montoPagado ?? 0)}
              </p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Saldo</p>
              <p className="font-semibold text-primary">
                {formatearMoneda(facturaHistorial?.saldoPendiente ?? 0)}
              </p>
            </div>
          </div>

          {historial.isPending ? (
            <p className="py-6 text-center text-sm text-muted-foreground">Cargando pagos…</p>
          ) : historial.isError ? (
            <p className="rounded-lg border border-destructive/30 bg-destructive/10 p-4 text-sm text-destructive">
              No se pudieron cargar los pagos.
            </p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="h-8 text-xs">Fecha</TableHead>
                  <TableHead className="h-8 text-xs">Canal</TableHead>
                  <TableHead className="h-8 text-xs">Imputado a</TableHead>
                  <TableHead className="h-8 text-xs">Referencia</TableHead>
                  <TableHead className="h-8 text-right text-xs">Monto</TableHead>
                  <TableHead className="h-8" />
                </TableRow>
              </TableHeader>
              <TableBody>
                {(historial.data?.items ?? []).length === 0 && (
                  <TableRow>
                    <TableCell
                      colSpan={6}
                      className="py-8 text-center text-sm text-muted-foreground"
                    >
                      Esta factura todavía no tiene pagos
                    </TableCell>
                  </TableRow>
                )}
                {(historial.data?.items ?? []).map((p) => (
                  <TableRow key={p.id} className="text-sm">
                    <TableCell className="py-2 text-muted-foreground">
                      {p.fechaPago.slice(0, 10)}
                    </TableCell>
                    <TableCell className="py-2">
                      {p.canalPago ?? <span className="text-muted-foreground">—</span>}
                      {p.banco && (
                        <span className="block text-xs text-muted-foreground">
                          {p.banco} · {p.numeroCuenta}
                        </span>
                      )}
                    </TableCell>
                    <TableCell className="py-2">
                      {p.nroCuota === null ? (
                        <span className="text-muted-foreground">La factura</span>
                      ) : (
                        <Badge variant="outline" className="text-xs">
                          Cuota #{p.nroCuota}
                        </Badge>
                      )}
                    </TableCell>
                    <TableCell className="py-2 text-xs text-muted-foreground">
                      {p.referencia ?? "—"}
                    </TableCell>
                    <TableCell className="py-2 text-right font-semibold">
                      {formatearMoneda(p.monto)}
                    </TableCell>
                    <TableCell className="py-2 text-right">
                      <Button
                        variant="ghost"
                        size="icon"
                        className="size-8"
                        title="Eliminar pago"
                        aria-label={`Eliminar pago de ${formatearMoneda(p.monto)}`}
                        onClick={() => setPagoAEliminar(p)}
                      >
                        <Trash2 className="size-4 text-destructive" />
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </DialogContent>
      </Dialog>

      <AlertDialog open={pagoAEliminar !== null} onOpenChange={(o) => !o && setPagoAEliminar(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              ¿Eliminar el pago de {formatearMoneda(pagoAEliminar?.monto ?? 0)}?
            </AlertDialogTitle>
            <AlertDialogDescription>
              La factura vuelve a quedar con saldo por ese monto
              {pagoAEliminar?.nroCuota !== null &&
                pagoAEliminar !== null &&
                `, y la cuota #${pagoAEliminar.nroCuota} se reabre`}
              . Esta acción no se puede deshacer.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              onClick={(e) => {
                e.preventDefault();
                if (pagoAEliminar) eliminarPago.mutate(pagoAEliminar);
              }}
              disabled={eliminarPago.isPending}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {eliminarPago.isPending && <Loader2 className="size-4 animate-spin" />}Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </AppLayout>
  );
}

export const Route = createFileRoute("/_auth/pagos")({
  head: () => ({
    meta: [
      { title: tituloPagina("Pagos a proveedores") },
      { name: "description", content: "Registrar pagos de facturas de compra con saldo." },
    ],
  }),
  component: PagosPage,
});
