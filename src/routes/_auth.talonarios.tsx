import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { type ReactNode, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type Talonario } from "@/lib/api";
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
import { tituloPagina } from "@/lib/marca";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

export const Route = createFileRoute("/_auth/talonarios")({
  head: () => ({ meta: [{ title: tituloPagina("Talonarios") }] }),
  component: TalonariosPage,
});

const schema = z
  .object({
    tipoComprobante: z.enum(["FCO", "FCR", "NCR"], { message: "Elegí un tipo" }),
    nroTimbrado: z.string().trim().min(1, "Obligatorio").max(20, "Máximo 20 caracteres"),
    establecimiento: z
      .string()
      .trim()
      .regex(/^\d{3}$/, "Usá 3 dígitos"),
    puntoExpedicion: z
      .string()
      .trim()
      .regex(/^\d{3}$/, "Usá 3 dígitos"),
    nroInicial: z.coerce.number().int("Sin decimales").min(1, "Mayor a cero"),
    nroFinal: z.coerce.number().int("Sin decimales").min(1, "Mayor a cero"),
    nroActual: z.coerce.number().int("Sin decimales").min(1, "Mayor a cero"),
    fechaInicio: z.string().regex(/^$|^\d{4}-\d{2}-\d{2}$/, "Fecha inválida"),
    fechaVencimiento: z.string().regex(/^$|^\d{4}-\d{2}-\d{2}$/, "Fecha inválida"),
    activo: z.boolean(),
  })
  .superRefine((v, ctx) => {
    if (v.nroFinal < v.nroInicial)
      ctx.addIssue({
        code: "custom",
        message: "El final debe ser mayor o igual al inicial",
        path: ["nroFinal"],
      });
    if (v.nroActual < v.nroInicial || v.nroActual > v.nroFinal)
      ctx.addIssue({ code: "custom", message: "Debe estar dentro del rango", path: ["nroActual"] });
    if (v.fechaInicio && v.fechaVencimiento && v.fechaVencimiento < v.fechaInicio)
      ctx.addIssue({
        code: "custom",
        message: "No puede ser anterior al inicio",
        path: ["fechaVencimiento"],
      });
  });
type FormValues = z.infer<typeof schema>;
const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;
const TIPOS = [
  { value: "FCO", label: "Factura contado" },
  { value: "FCR", label: "Factura crédito" },
  { value: "NCR", label: "Nota de crédito" },
] as const;

function etiqueta(t: Talonario) {
  return `${t.establecimiento}-${t.puntoExpedicion}-${String(t.nroActual).padStart(7, "0")}`;
}
function fecha(valor: string | null) {
  return valor
    ? new Intl.DateTimeFormat("es-PY", { dateStyle: "medium" }).format(
        new Date(`${valor}T00:00:00`),
      )
    : "Sin vencimiento";
}

function TalonariosPage() {
  const { empresa } = useEmpresa();
  const { sucursal, cargando: cargandoSucursal } = useSucursal();
  const queryClient = useQueryClient();
  const [creando, setCreando] = useState(false);
  const [editando, setEditando] = useState<Talonario | null>(null);
  const [aEliminar, setAEliminar] = useState<Talonario | null>(null);
  const [visibles, setVisibles] = useState(20);
  const [filtroTipo, setFiltroTipo] = useState("todos");
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["talonarios", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => api.talonarios.listar({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
    enabled: empresa !== null && sucursal !== null,
  });
  const items = data?.items ?? [];
  const filtrados = items.filter((t) => filtroTipo === "todos" || t.tipoComprobante === filtroTipo);
  const { busqueda, setBusqueda, orden, alternarOrden, resultado } = useTablaListado(
    filtrados,
    (t) => [
      t.tipoComprobante,
      t.nroTimbrado,
      t.establecimiento,
      t.puntoExpedicion,
      etiqueta(t),
      esActivo(t.activo) ? "Activo" : "Inactivo",
    ],
  );
  const eliminar = useMutation({
    mutationFn: (t: Talonario) => api.talonarios.eliminar(t.id, t.idEmpresa),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["talonarios"] });
      setAEliminar(null);
      toast.success("Talonario eliminado");
    },
    onError: (e) => {
      setAEliminar(null);
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar el talonario"));
    },
  });
  const sinSucursal = !cargandoSucursal && sucursal === null;
  return (
    <AppLayout active="/talonarios" title="Talonarios">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Talonarios</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Numeración fiscal de {sucursal?.nombreSucursal ?? "la sucursal activa"}.
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={sinSucursal}>
            <Plus className="size-4" />
            Nuevo talonario
          </Button>
        </div>
        {sinSucursal ? (
          <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
            La empresa no tiene sucursales activas. Cargá una antes de definir talonarios.
          </p>
        ) : (
          <>
            <div className="flex max-w-xl gap-2">
              <div className="relative flex-1">
                <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
                <Input
                  className="pl-9"
                  value={busqueda}
                  onChange={(e) => setBusqueda(e.target.value)}
                  placeholder="Buscar talonario…"
                />
              </div>
              <Select
                value={filtroTipo}
                onValueChange={(v) => {
                  setFiltroTipo(v);
                  setVisibles(20);
                }}
              >
                <SelectTrigger className="w-44">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="todos">Todos los tipos</SelectItem>
                  {TIPOS.map((t) => (
                    <SelectItem key={t.value} value={t.value}>
                      {t.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            {isPending || cargandoSucursal ? (
              <div className="space-y-2">
                {[1, 2, 3].map((i) => (
                  <Skeleton key={i} className="h-14 w-full" />
                ))}
              </div>
            ) : isError ? (
              <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
                {MENSAJE_ERROR(error, "No se pudieron cargar los talonarios")}
              </p>
            ) : resultado.length === 0 ? (
              <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
                {busqueda.trim() || filtroTipo !== "todos"
                  ? "Ningún talonario coincide con el filtro."
                  : "Todavía no hay talonarios cargados."}
              </p>
            ) : (
              <>
                <ul className="space-y-3 sm:hidden">
                  {resultado.slice(0, visibles).map((t) => (
                    <li key={t.id} className="surface-card p-4">
                      <div className="flex items-start justify-between gap-3">
                        <div>
                          <p className="font-semibold text-foreground">{etiqueta(t)}</p>
                          <p className="text-xs text-muted-foreground">
                            {TIPOS.find((x) => x.value === t.tipoComprobante)?.label} · Timbrado{" "}
                            {t.nroTimbrado}
                          </p>
                          <p className="mt-1 text-xs text-muted-foreground">
                            Vence: {fecha(t.fechaVencimiento)}
                          </p>
                        </div>
                        <Badge variant={esActivo(t.activo) ? "secondary" : "outline"}>
                          {esActivo(t.activo) ? "Activo" : "Inactivo"}
                        </Badge>
                      </div>
                      <div className="mt-3 flex gap-2 border-t border-border pt-3">
                        <Button
                          variant="outline"
                          size="sm"
                          className="flex-1"
                          onClick={() => setEditando(t)}
                        >
                          <Pencil className="size-4" />
                          Editar
                        </Button>
                        <Button
                          variant="outline"
                          size="sm"
                          className="flex-1 text-destructive"
                          onClick={() => setAEliminar(t)}
                        >
                          <Trash2 className="size-4" />
                          Eliminar
                        </Button>
                      </div>
                    </li>
                  ))}
                </ul>
                <div className="surface-card hidden overflow-x-auto sm:block">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "tipoComprobante" ? orden.direccion : null}
                          onClick={() => alternarOrden("tipoComprobante")}
                        >
                          Tipo
                        </TableHeadOrdenable>
                        <TableHeadOrdenable
                          direccion={orden?.campo === "nroTimbrado" ? orden.direccion : null}
                          onClick={() => alternarOrden("nroTimbrado")}
                        >
                          Timbrado
                        </TableHeadOrdenable>
                        <TableHead>Numeración</TableHead>
                        <TableHead>Vigencia</TableHead>
                        <TableHead>Estado</TableHead>
                        <TableHead className="text-right">Acciones</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {resultado.slice(0, visibles).map((t) => (
                        <TableRow key={t.id}>
                          <TableCell>
                            <Badge variant="outline">{t.tipoComprobante}</Badge>
                          </TableCell>
                          <TableCell className="font-medium">{t.nroTimbrado}</TableCell>
                          <TableCell className="tabular-nums text-muted-foreground">
                            {t.establecimiento}-{t.puntoExpedicion}-
                            {String(t.nroInicial).padStart(7, "0")} a{" "}
                            {String(t.nroFinal).padStart(7, "0")}
                          </TableCell>
                          <TableCell className="text-muted-foreground">
                            {t.fechaInicio ? `Desde ${fecha(t.fechaInicio)}` : "Sin inicio"}
                            <br />
                            {fecha(t.fechaVencimiento)}
                          </TableCell>
                          <TableCell>
                            <Badge variant={esActivo(t.activo) ? "secondary" : "outline"}>
                              {esActivo(t.activo) ? "Activo" : "Inactivo"}
                            </Badge>
                          </TableCell>
                          <TableCell className="text-right">
                            <Button
                              variant="ghost"
                              size="icon"
                              title="Editar"
                              aria-label={`Editar ${etiqueta(t)}`}
                              onClick={() => setEditando(t)}
                            >
                              <Pencil className="size-4" />
                            </Button>
                            <Button
                              variant="ghost"
                              size="icon"
                              title="Eliminar"
                              aria-label={`Eliminar ${etiqueta(t)}`}
                              onClick={() => setAEliminar(t)}
                            >
                              <Trash2 className="size-4 text-destructive" />
                            </Button>
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
                {resultado.length > visibles && (
                  <div className="flex justify-center">
                    <Button variant="outline" onClick={() => setVisibles((v) => v + 20)}>
                      Mostrar más ({resultado.length - visibles} restantes)
                    </Button>
                  </div>
                )}
              </>
            )}
          </>
        )}
        {empresa && sucursal && (
          <TalonarioFormDialog
            open={creando || editando !== null}
            talonario={editando}
            idEmpresa={empresa.id}
            idSucursal={sucursal.id}
            onClose={() => {
              setCreando(false);
              setEditando(null);
            }}
          />
        )}
        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>
                ¿Eliminar {aEliminar ? etiqueta(aEliminar) : "el talonario"}?
              </AlertDialogTitle>
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

function TalonarioFormDialog({
  open,
  talonario,
  idEmpresa,
  idSucursal,
  onClose,
}: {
  open: boolean;
  talonario: Talonario | null;
  idEmpresa: number;
  idSucursal: number;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const editar = talonario !== null;
  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    values: {
      tipoComprobante: talonario?.tipoComprobante ?? "FCO",
      nroTimbrado: talonario?.nroTimbrado ?? "",
      establecimiento: talonario?.establecimiento ?? "001",
      puntoExpedicion: talonario?.puntoExpedicion ?? "001",
      nroInicial: talonario?.nroInicial ?? 1,
      nroFinal: talonario?.nroFinal ?? 100,
      nroActual: talonario?.nroActual ?? 1,
      fechaInicio: talonario?.fechaInicio ?? "",
      fechaVencimiento: talonario?.fechaVencimiento ?? "",
      activo: talonario ? esActivo(talonario.activo) : true,
    },
  });
  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const datos = {
        tipoComprobante: v.tipoComprobante,
        nroTimbrado: v.nroTimbrado,
        establecimiento: v.establecimiento,
        puntoExpedicion: v.puntoExpedicion,
        nroInicial: v.nroInicial,
        nroFinal: v.nroFinal,
        nroActual: v.nroActual,
        ...(v.fechaInicio ? { fechaInicio: v.fechaInicio } : {}),
        ...(v.fechaVencimiento ? { fechaVencimiento: v.fechaVencimiento } : {}),
        ...(editar ? { activo: v.activo ? ("A" as const) : ("I" as const) } : {}),
      };
      return editar
        ? api.talonarios.actualizar(talonario.id, { idEmpresa: talonario.idEmpresa, ...datos })
        : api.talonarios.crear({ idEmpresa, idSucursal, ...datos });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["talonarios"] });
      toast.success(editar ? "Talonario actualizado" : "Talonario creado");
      onClose();
    },
    onError: (e) =>
      form.setError("root", { message: MENSAJE_ERROR(e, "No se pudo guardar el talonario") }),
  });
  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{editar ? "Editar talonario" : "Nuevo talonario"}</DialogTitle>
          <DialogDescription>
            Configurá la numeración fiscal de la sucursal activa.
          </DialogDescription>
        </DialogHeader>
        <Form {...form}>
          <form
            onSubmit={form.handleSubmit((v) => guardar.mutate(v))}
            className="grid gap-4 sm:grid-cols-2"
          >
            <Field form={form} name="tipoComprobante" label="Tipo">
              <Select
                value={form.watch("tipoComprobante")}
                onValueChange={(v) =>
                  form.setValue("tipoComprobante", v as FormValues["tipoComprobante"], {
                    shouldValidate: true,
                  })
                }
              >
                <FormControl>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                </FormControl>
                <SelectContent>
                  {TIPOS.map((t) => (
                    <SelectItem key={t.value} value={t.value}>
                      {t.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field form={form} name="nroTimbrado" label="Nro. de timbrado" />
            <Field form={form} name="establecimiento" label="Establecimiento" />
            <Field form={form} name="puntoExpedicion" label="Punto de expedición" />
            <Field form={form} name="nroInicial" label="Número inicial" type="number" />
            <Field form={form} name="nroFinal" label="Número final" type="number" />
            <Field form={form} name="nroActual" label="Número actual" type="number" />
            <Field form={form} name="fechaInicio" label="Fecha de inicio" type="date" />
            <Field form={form} name="fechaVencimiento" label="Fecha de vencimiento" type="date" />
            {editar && (
              <FormField
                control={form.control}
                name="activo"
                render={({ field }) => (
                  <FormItem className="flex items-center justify-between rounded-md border p-3">
                    <FormLabel>Talón activo</FormLabel>
                    <FormControl>
                      <Switch checked={field.value} onCheckedChange={field.onChange} />
                    </FormControl>
                  </FormItem>
                )}
              />
            )}
            <FormMessage />
            {form.formState.errors.root && (
              <p className="text-sm text-destructive sm:col-span-2">
                {form.formState.errors.root.message}
              </p>
            )}
            <DialogFooter className="sm:col-span-2">
              <Button type="button" variant="outline" onClick={onClose}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}Guardar
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

function Field({
  form,
  name,
  label,
  type = "text",
  children,
}: {
  form: ReturnType<typeof useForm<FormValues>>;
  name: keyof FormValues;
  label: string;
  type?: string;
  children?: ReactNode;
}) {
  return (
    <FormField
      control={form.control}
      name={name}
      render={({ field }) => (
        <FormItem>
          <FormLabel>{label}</FormLabel>
          <FormControl>
            {children ?? (
              <Input
                {...field}
                type={type}
                value={field.value as string | number}
                onChange={(e) =>
                  field.onChange(type === "number" ? Number(e.target.value) : e.target.value)
                }
              />
            )}
          </FormControl>
          <FormMessage />
        </FormItem>
      )}
    />
  );
}
