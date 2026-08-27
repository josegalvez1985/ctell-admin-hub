import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Landmark, Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { InputMoneda } from "@/components/ctell/InputMoneda";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type CuentaBancaria, type Estado } from "@/lib/api";
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
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { tituloPagina } from "@/lib/marca";
import { numeroMoneda } from "@/lib/moneda";

const schema = z.object({
  idBanco: z.string().min(1, "Elegí un banco"),
  numeroCuenta: z.string().trim().min(1, "Obligatorio").max(50, "Máximo 50 caracteres"),
  tipoCuenta: z.string().trim().max(20, "Máximo 20 caracteres"),
  titular: z.string().trim().max(200, "Máximo 200 caracteres"),
  saldoInicial: z
    .string()
    .refine((v) => v === "" || Number.isFinite(numeroMoneda(v)), "Ingresá un importe válido"),
  idMoneda: z.string(),
  activo: z.boolean(),
});
type FormValues = z.infer<typeof schema>;
const opcionesEstado = [
  { valor: "A", etiqueta: "Activo" },
  { valor: "I", etiqueta: "Inactivo" },
];
const mensajeError = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;
const importe = (valor: number | null) =>
  valor === null ? "—" : new Intl.NumberFormat("es-PY", { minimumFractionDigits: 2 }).format(valor);

function CuentasBancariasPage() {
  const { empresa } = useEmpresa();
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<CuentaBancaria | null>(null);
  const [creando, setCreando] = useState(false);
  const [filtroEstado, setFiltroEstado] = useState(SIN_FILTRO);
  const [aEliminar, setAEliminar] = useState<CuentaBancaria | null>(null);
  const cuentas = useQuery({
    queryKey: ["cuentas-bancarias", empresa?.id ?? null],
    queryFn: () => api.cuentasBancarias.listar(empresa!.id),
    enabled: empresa !== null,
  });
  const filtradas = (cuentas.data?.items ?? []).filter(
    (cuenta) => filtroEstado === SIN_FILTRO || cuenta.activo === filtroEstado,
  );
  const listado = useTablaListado(filtradas, (cuenta) => [
    cuenta.banco,
    cuenta.numeroCuenta,
    cuenta.tipoCuenta,
    cuenta.titular,
    cuenta.moneda,
    esActivo(cuenta.activo) ? "Activo" : "Inactivo",
  ]);
  const eliminar = useMutation({
    mutationFn: (cuenta: CuentaBancaria) =>
      api.cuentasBancarias.eliminar(cuenta.id, cuenta.idEmpresa),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["cuentas-bancarias"] });
      toast.success("Cuenta bancaria eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(mensajeError(e, "No se pudo eliminar la cuenta bancaria"));
      setAEliminar(null);
    },
  });

  return (
    <AppLayout active="/cuentas-bancarias" title="Cuentas bancarias">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Cuentas bancarias</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {empresa ? `Cuentas de ${empresa.nombreEmpresa}.` : "Cuentas de la empresa activa."}
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null}>
            <Plus className="size-4" />
            Nueva cuenta
          </Button>
        </div>
        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={listado.busqueda}
            onChange={(e) => listado.setBusqueda(e.target.value)}
            placeholder="Buscar por banco, número o titular..."
            className="pl-9"
          />
        </div>
        {empresa === null && !cuentas.isPending && (
          <p className="rounded-lg border border-border px-3 py-6 text-center text-sm text-muted-foreground">
            No hay una empresa activa. Cerrá sesión y volvé a entrar eligiendo una.
          </p>
        )}
        {cuentas.isPending && empresa !== null && (
          <div className="space-y-2">
            {[0, 1, 2, 3].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        )}
        {cuentas.isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
            {mensajeError(cuentas.error, "No se pudo cargar la lista")}
          </p>
        )}
        {!cuentas.isPending &&
          !cuentas.isError &&
          empresa !== null &&
          listado.resultado.length === 0 && (
            <div className="surface-card px-3 py-16 text-center">
              <p className="text-sm text-muted-foreground">
                {listado.termino
                  ? `Sin resultados para "${listado.busqueda.trim()}".`
                  : "Esta empresa todavía no tiene cuentas bancarias."}
              </p>
              {!listado.termino && (
                <Button className="mt-4" onClick={() => setCreando(true)}>
                  <Plus className="size-4" />
                  Cargar la primera
                </Button>
              )}
            </div>
          )}
        {listado.resultado.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {listado.resultado.map((cuenta) => (
              <CuentaCard
                key={cuenta.id}
                cuenta={cuenta}
                onEdit={() => setEditando(cuenta)}
                onDelete={() => setAEliminar(cuenta)}
              />
            ))}
          </ul>
        )}
        {listado.resultado.length > 0 && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHeadOrdenable
                    direccion={listado.orden?.campo === "banco" ? listado.orden.direccion : null}
                    onClick={() => listado.alternarOrden("banco")}
                  >
                    Banco
                  </TableHeadOrdenable>
                  <TableHead>Cuenta</TableHead>
                  <TableHead>Titular</TableHead>
                  <TableHead>Moneda</TableHead>
                  <TableHead>Saldo inicial</TableHead>
                  <TableHeadFiltrable
                    direccion={listado.orden?.campo === "activo" ? listado.orden.direccion : null}
                    onOrdenar={() => listado.alternarOrden("activo")}
                    opciones={opcionesEstado}
                    valor={filtroEstado}
                    onFiltrar={setFiltroEstado}
                    buscarPlaceholder="Buscar estado..."
                  >
                    Estado
                  </TableHeadFiltrable>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {listado.resultado.map((cuenta) => (
                  <TableRow key={cuenta.id}>
                    <TableCell className="font-medium">
                      <span className="inline-flex items-center gap-2">
                        <Landmark className="size-4 text-muted-foreground" />
                        {cuenta.banco}
                      </span>
                    </TableCell>
                    <TableCell>
                      <div>{cuenta.numeroCuenta}</div>
                      <div className="text-xs text-muted-foreground">
                        {cuenta.tipoCuenta || "Sin tipo"}
                      </div>
                    </TableCell>
                    <TableCell className="text-muted-foreground">{cuenta.titular || "—"}</TableCell>
                    <TableCell className="text-muted-foreground">{cuenta.moneda || "—"}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {importe(cuenta.saldoInicial)}
                    </TableCell>
                    <TableCell>
                      <Badge variant={esActivo(cuenta.activo) ? "secondary" : "outline"}>
                        {esActivo(cuenta.activo) ? "Activo" : "Inactivo"}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-right">
                      <Button
                        variant="ghost"
                        size="icon"
                        title="Editar"
                        aria-label={`Editar ${cuenta.numeroCuenta}`}
                        onClick={() => setEditando(cuenta)}
                      >
                        <Pencil className="size-4" />
                      </Button>
                      <Button
                        variant="ghost"
                        size="icon"
                        title="Eliminar"
                        aria-label={`Eliminar ${cuenta.numeroCuenta}`}
                        onClick={() => setAEliminar(cuenta)}
                      >
                        <Trash2 className="size-4 text-destructive" />
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
        {cuentas.data && listado.resultado.length > 0 && (
          <p className="text-xs text-muted-foreground">
            {listado.resultado.length} de {cuentas.data.items.length} cuenta
            {cuentas.data.items.length === 1 ? "" : "s"}
          </p>
        )}
        {empresa && (
          <CuentaFormDialog
            open={creando || editando !== null}
            cuenta={editando}
            idEmpresa={empresa.id}
            onClose={() => {
              setCreando(false);
              setEditando(null);
            }}
          />
        )}
        <AlertDialog open={aEliminar !== null} onOpenChange={(open) => !open && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar la cuenta {aEliminar?.numeroCuenta}?</AlertDialogTitle>
              <AlertDialogDescription>Esta acción no se puede deshacer.</AlertDialogDescription>
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
      </main>
    </AppLayout>
  );
}

function CuentaCard({
  cuenta,
  onEdit,
  onDelete,
}: {
  cuenta: CuentaBancaria;
  onEdit: () => void;
  onDelete: () => void;
}) {
  return (
    <li className="surface-card p-4">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-semibold text-foreground">{cuenta.banco}</p>
          <p className="mt-1 text-sm text-muted-foreground">
            {cuenta.numeroCuenta}
            {cuenta.tipoCuenta ? ` · ${cuenta.tipoCuenta}` : ""}
          </p>
          <p className="mt-1 text-xs text-muted-foreground">
            {cuenta.titular || "Sin titular"} · {cuenta.moneda || "Sin moneda"}
          </p>
        </div>
        <Badge variant={esActivo(cuenta.activo) ? "secondary" : "outline"}>
          {esActivo(cuenta.activo) ? "Activo" : "Inactivo"}
        </Badge>
      </div>
      <div className="mt-3 flex items-center justify-between border-t border-border pt-3">
        <span className="text-sm text-muted-foreground">
          Saldo inicial: {importe(cuenta.saldoInicial)}
        </span>
        <div className="flex gap-1">
          <Button
            variant="ghost"
            size="icon"
            title="Editar"
            aria-label={`Editar ${cuenta.numeroCuenta}`}
            onClick={onEdit}
          >
            <Pencil className="size-4" />
          </Button>
          <Button
            variant="ghost"
            size="icon"
            title="Eliminar"
            aria-label={`Eliminar ${cuenta.numeroCuenta}`}
            onClick={onDelete}
          >
            <Trash2 className="size-4 text-destructive" />
          </Button>
        </div>
      </div>
    </li>
  );
}

function CuentaFormDialog({
  open,
  cuenta,
  idEmpresa,
  onClose,
}: {
  open: boolean;
  cuenta: CuentaBancaria | null;
  idEmpresa: number;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = cuenta !== null;
  const bancos = useQuery({ queryKey: ["bancos"], queryFn: () => api.bancos.listar() });
  const monedas = useQuery({
    queryKey: ["monedas", idEmpresa],
    queryFn: () => api.monedas.listar({ idEmpresa }),
  });
  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    values: {
      idBanco: cuenta ? String(cuenta.idBanco) : "",
      numeroCuenta: cuenta?.numeroCuenta ?? "",
      tipoCuenta: cuenta?.tipoCuenta ?? "",
      titular: cuenta?.titular ?? "",
      saldoInicial:
        cuenta?.saldoInicial === null || cuenta?.saldoInicial === undefined
          ? ""
          : importe(cuenta.saldoInicial),
      idMoneda: cuenta?.idMoneda ? String(cuenta.idMoneda) : "",
      activo: cuenta ? esActivo(cuenta.activo) : true,
    },
  });
  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const datos = {
        idEmpresa,
        idBanco: Number(v.idBanco),
        numeroCuenta: v.numeroCuenta,
        tipoCuenta: v.tipoCuenta,
        titular: v.titular,
        ...(v.saldoInicial ? { saldoInicial: numeroMoneda(v.saldoInicial) } : {}),
        ...(v.idMoneda ? { idMoneda: Number(v.idMoneda) } : {}),
      };
      return esEdicion
        ? api.cuentasBancarias.actualizar(cuenta.id, {
            ...datos,
            activo: (v.activo ? "A" : "I") as Estado,
          })
        : api.cuentasBancarias.crear(datos);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["cuentas-bancarias"] });
      toast.success(esEdicion ? "Cuenta actualizada" : "Cuenta creada");
      onClose();
    },
    onError: (e) =>
      toast.error(
        mensajeError(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear la cuenta"),
      ),
  });
  return (
    <Dialog open={open} onOpenChange={(value) => !value && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {esEdicion ? "Editar cuenta bancaria" : "Nueva cuenta bancaria"}
          </DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos de la cuenta."
              : "Agregá una cuenta a la empresa activa."}
          </DialogDescription>
        </DialogHeader>
        <Form {...form}>
          <form
            id="cuenta-bancaria-form"
            onSubmit={form.handleSubmit((v) => guardar.mutate(v))}
            className="space-y-4"
          >
            <FormField
              control={form.control}
              name="idBanco"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Banco</FormLabel>
                  <Select value={field.value} onValueChange={field.onChange}>
                    <FormControl>
                      <SelectTrigger>
                        <SelectValue
                          placeholder={bancos.isPending ? "Cargando bancos..." : "Elegí un banco"}
                        />
                      </SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      {(bancos.data?.items ?? [])
                        .filter((b) => esActivo(b.activo))
                        .map((banco) => (
                          <SelectItem key={banco.id} value={String(banco.id)}>
                            {banco.nombreBanco}
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
              name="numeroCuenta"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Número de cuenta</FormLabel>
                  <FormControl>
                    <Input {...field} maxLength={50} autoComplete="off" />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="tipoCuenta"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Tipo de cuenta</FormLabel>
                    <FormControl>
                      <Input {...field} placeholder="Corriente" maxLength={20} />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
              <FormField
                control={form.control}
                name="idMoneda"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Moneda</FormLabel>
                    <Select value={field.value} onValueChange={field.onChange}>
                      <FormControl>
                        <SelectTrigger>
                          <SelectValue
                            placeholder={monedas.isPending ? "Cargando monedas..." : "Opcional"}
                          />
                        </SelectTrigger>
                      </FormControl>
                      <SelectContent>
                        {(monedas.data?.items ?? [])
                          .filter((m) => esActivo(m.activo))
                          .map((moneda) => (
                            <SelectItem key={moneda.id} value={String(moneda.id)}>
                              {moneda.nombreMoneda}
                              {moneda.simbolo ? ` (${moneda.simbolo})` : ""}
                            </SelectItem>
                          ))}
                      </SelectContent>
                    </Select>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>
            <FormField
              control={form.control}
              name="titular"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Titular</FormLabel>
                  <FormControl>
                    <Input {...field} maxLength={200} autoComplete="off" />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
            <FormField
              control={form.control}
              name="saldoInicial"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Saldo inicial</FormLabel>
                  <FormControl>
                    {/* Se sale de `type="number"`: un input numérico nativo
                        rechaza "1.500,00" y no deja mover el cursor, que es lo
                        que necesita el separador de miles en vivo. */}
                    <InputMoneda {...field} />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
            {esEdicion && (
              <FormField
                control={form.control}
                name="activo"
                render={({ field }) => (
                  <FormItem className="flex items-center justify-between rounded-lg border border-border p-3">
                    <div>
                      <FormLabel>Activo</FormLabel>
                      <p className="text-xs text-muted-foreground">
                        Una cuenta inactiva no se ofrece para nuevas operaciones.
                      </p>
                    </div>
                    <FormControl>
                      <Switch checked={field.value} onCheckedChange={field.onChange} />
                    </FormControl>
                  </FormItem>
                )}
              />
            )}
          </form>
        </Form>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>
            Cancelar
          </Button>
          <Button type="submit" form="cuenta-bancaria-form" disabled={guardar.isPending}>
            {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
            {guardar.isPending ? "Guardando..." : "Guardar"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/cuentas-bancarias")({
  head: () => ({
    meta: [
      { title: tituloPagina("Cuentas bancarias") },
      { name: "description", content: "Catálogo de cuentas bancarias por empresa." },
    ],
  }),
  component: CuentasBancariasPage,
});
