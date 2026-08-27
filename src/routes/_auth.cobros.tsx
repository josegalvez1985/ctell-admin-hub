import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CreditCard, Loader2, Receipt, Search, Trash2 } from "lucide-react";
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
  type Venta,
  type VentaCobro,
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
  error instanceof ApiError ? error.message : "No se pudo registrar el cobro";

function CobrosPage() {
  const { empresa } = useEmpresa();
  const { sucursal } = useSucursal();
  const queryClient = useQueryClient();
  const [busqueda, setBusqueda] = useState("");
  const [ventaSeleccionada, setVentaSeleccionada] = useState<Venta | null>(null);
  const [idCuota, setIdCuota] = useState("");
  const [idCanalPago, setIdCanalPago] = useState("");
  const [montoCobro, setMontoCobro] = useState("");
  const [referencia, setReferencia] = useState("");
  const [idCuentaBancaria, setIdCuentaBancaria] = useState("");
  /**
   * Venta cuyo historial se está mirando. Se guarda el **id**, no la fila: la
   * fila se resuelve contra el listado en cada render, así los totales del
   * modal se actualizan solos cuando se registra un cobro.
   */
  const [idVentaHistorial, setIdVentaHistorial] = useState<number | null>(null);
  const [cobroAEliminar, setCobroAEliminar] = useState<VentaCobro | null>(null);

  const ventas = useQuery({
    queryKey: ["cobros-ventas", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => api.ventas.listar({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
    enabled: empresa !== null && sucursal !== null,
  });

  const ventaDetalle = useQuery({
    queryKey: ["cobros-detalle", ventaSeleccionada?.id ?? null, empresa?.id ?? null],
    queryFn: () => api.ventas.obtener(ventaSeleccionada!.id, empresa!.id),
    enabled: ventaSeleccionada !== null && empresa !== null,
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
    queryKey: ["cobros-historial", idVentaHistorial, empresa?.id ?? null],
    queryFn: () => api.ventasCobros.listar(idVentaHistorial!, empresa!.id),
    enabled: idVentaHistorial !== null && empresa !== null,
  });

  const cuotasPendientes = (ventaDetalle.data?.cuotas ?? []).filter((c) => c.saldoPendiente > 0);
  const canalElegido = (canales.data?.items ?? []).find(
    (canal) => String(canal.id) === idCanalPago,
  );
  /**
   * El tope real de este cobro. Si se imputa a una cuota manda el saldo de la
   * cuota; si no, el de la venta. El backend valida lo mismo con la cabecera
   * bloqueada — esto sólo evita el viaje de ida y vuelta para fallar.
   */
  const cuotaElegida = cuotasPendientes.find((c) => String(c.id) === idCuota);
  const saldoTope = cuotaElegida?.saldoPendiente ?? ventaSeleccionada?.saldoPendiente ?? 0;
  const montoIngresado = numeroMoneda(montoCobro);
  const excedeSaldo = Number.isFinite(montoIngresado) && montoIngresado > saldoTope;

  const abrirDialog = (venta: Venta) => {
    setVentaSeleccionada(venta);
    setIdCuota("");
    setIdCanalPago("");
    setMontoCobro("");
    setReferencia("");
    setIdCuentaBancaria("");
  };

  const cerrarDialog = () => setVentaSeleccionada(null);

  // Al elegir cuota específica, pre-llena el monto con su saldo pendiente
  const onCuotaChange = (val: string) => {
    setIdCuota(val);
    const cuota = cuotasPendientes.find((c) => String(c.id) === val);
    if (cuota) setMontoCobro(formatearMoneda(cuota.saldoPendiente));
  };

  const cobro = useMutation({
    mutationFn: () =>
      api.ventasCobros.crear({
        idVenta: ventaSeleccionada!.id,
        idEmpresa: empresa!.id,
        ...(idCuota ? { idCuota: Number(idCuota) } : {}),
        idCanalPago: Number(idCanalPago),
        idMoneda: ventaSeleccionada!.idMoneda,
        monto: numeroMoneda(montoCobro),
        fechaCobro: hoy(),
        ...(referencia ? { referencia } : {}),
        ...(idCuentaBancaria ? { idCuentaBancaria: Number(idCuentaBancaria) } : {}),
      }),
    onSuccess: () => {
      toast.success("Cobro registrado");
      cerrarDialog();
      queryClient.invalidateQueries({ queryKey: ["cobros-ventas"] });
      queryClient.invalidateQueries({ queryKey: ["cobros-detalle"] });
      queryClient.invalidateQueries({ queryKey: ["cobros-historial"] });
    },
    onError: (error) => toast.error(errorTexto(error)),
  });

  const eliminarCobro = useMutation({
    mutationFn: (c: VentaCobro) => api.ventasCobros.eliminar(c.id, empresa!.id),
    onSuccess: () => {
      toast.success("Cobro eliminado, la venta vuelve a tener saldo");
      setCobroAEliminar(null);
      queryClient.invalidateQueries({ queryKey: ["cobros-ventas"] });
      queryClient.invalidateQueries({ queryKey: ["cobros-detalle"] });
      queryClient.invalidateQueries({ queryKey: ["cobros-historial"] });
    },
    onError: (error) => {
      setCobroAEliminar(null);
      toast.error(error instanceof ApiError ? error.message : "No se pudo eliminar el cobro");
    },
  });

  const puedeConfirmar =
    ventaSeleccionada &&
    idCanalPago &&
    Number.isFinite(montoIngresado) &&
    montoIngresado > 0 &&
    !excedeSaldo;

  const ventaHistorial = (ventas.data?.items ?? []).find((v) => v.id === idVentaHistorial) ?? null;

  const ventasFiltradas = (ventas.data?.items ?? []).filter((v) => {
    if (!busqueda) return true;
    const b = busqueda.toLowerCase();
    return v.numeroVenta.toLowerCase().includes(b) || (v.cliente ?? "").toLowerCase().includes(b);
  });

  return (
    <AppLayout active="/cobros" title="Cobros">
      <main className="min-h-[calc(100vh-4rem)] bg-muted/20 px-4 pb-10 pt-5 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-5xl space-y-5">
          <header className="flex flex-wrap items-end justify-between gap-3">
            <div>
              <div className="mb-2 flex items-center gap-2 text-xs font-medium uppercase tracking-[0.16em] text-primary">
                <CreditCard className="size-4" />
                Tesorería
              </div>
              <h1 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
                Cobros
              </h1>
              <p className="mt-1 text-sm text-muted-foreground">
                {sucursal
                  ? `${empresa?.nombreEmpresa} · ${sucursal.nombreSucursal}`
                  : "Elegí una empresa y sucursal."}
              </p>
            </div>
          </header>

          <div className="surface-card p-4">
            <div className="relative">
              <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={busqueda}
                onChange={(e) => setBusqueda(e.target.value)}
                placeholder="Buscar por número de venta o cliente…"
                className="pl-9"
              />
            </div>
          </div>

          <div className="surface-card overflow-hidden">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead># Venta</TableHead>
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
                {!ventas.isPending && ventasFiltradas.length === 0 && (
                  <TableRow>
                    <TableCell
                      colSpan={7}
                      className="py-10 text-center text-sm text-muted-foreground"
                    >
                      No hay ventas
                    </TableCell>
                  </TableRow>
                )}
                {ventasFiltradas.map((v) => (
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
                      <div className="flex justify-end gap-2">
                        {/* La venta saldada no se puede cobrar pero SÍ se
                            puede auditar: es justo cuando más se pregunta
                            cómo se pagó. */}
                        <Button
                          size="sm"
                          variant="ghost"
                          disabled={v.montoCobrado <= 0}
                          onClick={() => setIdVentaHistorial(v.id)}
                          title="Ver cómo se cobró"
                        >
                          <Receipt className="size-4" />
                          <span className="hidden sm:inline">Ver cobros</span>
                        </Button>
                        {/* Sin saldo no hay nada que cobrar: el backend lo
                            rechaza con 409, así que ofrecer el botón sólo
                            serviría para llevar al cajero a un error. */}
                        <Button
                          size="sm"
                          variant="outline"
                          disabled={v.saldoPendiente <= 0}
                          onClick={() => abrirDialog(v)}
                        >
                          Registrar cobro
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

      <Dialog open={ventaSeleccionada !== null} onOpenChange={(open) => !open && cerrarDialog()}>
        <DialogContent className="max-h-[90vh] max-w-lg overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Cobro — Venta {ventaSeleccionada?.numeroVenta}</DialogTitle>
            <p className="text-sm text-muted-foreground">
              Total {formatearMoneda(ventaSeleccionada?.montoTotal ?? 0)} · Cobrado{" "}
              {formatearMoneda(ventaSeleccionada?.montoCobrado ?? 0)} ·{" "}
              <strong className="text-foreground">
                Saldo {formatearMoneda(ventaSeleccionada?.saldoPendiente ?? 0)}
              </strong>
            </p>
          </DialogHeader>

          {ventaDetalle.isPending ? (
            <p className="py-6 text-center text-sm text-muted-foreground">Cargando cuotas…</p>
          ) : (
            <div className="space-y-4">
              {/* Cuotas pendientes */}
              {cuotasPendientes.length > 0 ? (
                <div>
                  <p className="mb-2 text-xs font-medium uppercase tracking-wider text-muted-foreground">
                    Cuotas pendientes
                  </p>
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead className="h-8 text-xs">Cuota</TableHead>
                        <TableHead className="h-8 text-xs">Vencimiento</TableHead>
                        <TableHead className="h-8 text-xs">Monto</TableHead>
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
                          <TableCell className="py-2">{formatearMoneda(c.montoCuota)}</TableCell>
                          <TableCell className="py-2 text-right font-semibold text-primary">
                            {formatearMoneda(c.saldoPendiente)}
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
              ) : (
                <Badge variant="secondary">Esta venta no tiene cuotas pendientes</Badge>
              )}

              {/* Formulario de cobro */}
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
                    // Pasar a efectivo esconde el select de cuenta, y sin
                    // limpiarlo se mandaría la cuenta que quedó elegida.
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
                  value={montoCobro}
                  onChange={setMontoCobro}
                  placeholder="Monto cobrado *"
                />
                {excedeSaldo && (
                  <p className="text-xs text-destructive">
                    El monto supera el saldo pendiente ({formatearMoneda(saldoTope)}).
                  </p>
                )}

                <Input
                  value={referencia}
                  onChange={(e) => setReferencia(e.target.value)}
                  placeholder="Referencia (N° transferencia, etc.)"
                />

                {idCanalPago && requiereCuentaBancaria(canalElegido) && (
                  <Select value={idCuentaBancaria} onValueChange={setIdCuentaBancaria}>
                    <SelectTrigger>
                      <SelectValue placeholder="Cuenta bancaria receptora" />
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
                  disabled={!puedeConfirmar || cobro.isPending}
                  onClick={() => cobro.mutate()}
                >
                  {cobro.isPending ? "Registrando..." : "Confirmar cobro"}
                </Button>
              </div>
            </div>
          )}
        </DialogContent>
      </Dialog>

      {/* Historial: cómo se cobró esta venta */}
      <Dialog
        open={idVentaHistorial !== null}
        onOpenChange={(open) => !open && setIdVentaHistorial(null)}
      >
        <DialogContent className="max-h-[90vh] max-w-2xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Cobros — Venta {ventaHistorial?.numeroVenta}</DialogTitle>
            <p className="text-sm text-muted-foreground">
              {ventaHistorial?.cliente ?? "Cliente ocasional"} ·{" "}
              {ventaHistorial?.fechaVenta.slice(0, 10)}
            </p>
          </DialogHeader>

          <div className="grid grid-cols-3 gap-3 rounded-lg border border-border p-3 text-sm">
            <div>
              <p className="text-xs text-muted-foreground">Total</p>
              <p className="font-semibold">{formatearMoneda(ventaHistorial?.montoTotal ?? 0)}</p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Cobrado</p>
              <p className="font-semibold text-success">
                {formatearMoneda(ventaHistorial?.montoCobrado ?? 0)}
              </p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Saldo</p>
              <p className="font-semibold text-primary">
                {formatearMoneda(ventaHistorial?.saldoPendiente ?? 0)}
              </p>
            </div>
          </div>

          {historial.isPending ? (
            <p className="py-6 text-center text-sm text-muted-foreground">Cargando cobros…</p>
          ) : historial.isError ? (
            <p className="rounded-lg border border-destructive/30 bg-destructive/10 p-4 text-sm text-destructive">
              No se pudieron cargar los cobros.
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
                      Esta venta todavía no tiene cobros
                    </TableCell>
                  </TableRow>
                )}
                {(historial.data?.items ?? []).map((c) => (
                  <TableRow key={c.id} className="text-sm">
                    <TableCell className="py-2 text-muted-foreground">
                      {c.fechaCobro.slice(0, 10)}
                    </TableCell>
                    <TableCell className="py-2">
                      {/* El canal pudo borrarse después: el cobro sigue valiendo. */}
                      {c.canalPago ?? <span className="text-muted-foreground">—</span>}
                      {c.banco && (
                        <span className="block text-xs text-muted-foreground">
                          {c.banco} · {c.numeroCuenta}
                        </span>
                      )}
                    </TableCell>
                    <TableCell className="py-2">
                      {c.nroCuota === null ? (
                        <span className="text-muted-foreground">La venta</span>
                      ) : (
                        <Badge variant="outline" className="text-xs">
                          Cuota #{c.nroCuota}
                        </Badge>
                      )}
                    </TableCell>
                    <TableCell className="py-2 text-xs text-muted-foreground">
                      {c.referencia ?? "—"}
                    </TableCell>
                    <TableCell className="py-2 text-right font-semibold">
                      {formatearMoneda(c.monto)}
                    </TableCell>
                    <TableCell className="py-2 text-right">
                      <Button
                        variant="ghost"
                        size="icon"
                        className="size-8"
                        title="Eliminar cobro"
                        aria-label={`Eliminar cobro de ${formatearMoneda(c.monto)}`}
                        onClick={() => setCobroAEliminar(c)}
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

      <AlertDialog
        open={cobroAEliminar !== null}
        onOpenChange={(o) => !o && setCobroAEliminar(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              ¿Eliminar el cobro de {formatearMoneda(cobroAEliminar?.monto ?? 0)}?
            </AlertDialogTitle>
            <AlertDialogDescription>
              La venta vuelve a quedar con saldo por ese monto
              {cobroAEliminar?.nroCuota !== null &&
                cobroAEliminar !== null &&
                `, y la cuota #${cobroAEliminar.nroCuota} se reabre`}
              . Esta acción no se puede deshacer.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              onClick={(e) => {
                e.preventDefault();
                if (cobroAEliminar) eliminarCobro.mutate(cobroAEliminar);
              }}
              disabled={eliminarCobro.isPending}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {eliminarCobro.isPending && <Loader2 className="size-4 animate-spin" />}Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </AppLayout>
  );
}

export const Route = createFileRoute("/_auth/cobros")({
  head: () => ({
    meta: [
      { title: tituloPagina("Cobros") },
      { name: "description", content: "Registrar cobros de ventas con saldo pendiente." },
    ],
  }),
  component: CobrosPage,
});
