import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { Combobox } from "@/components/ctell/Combobox";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type Empresa, type Estado } from "@/lib/api";
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
import { Switch } from "@/components/ui/switch";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

const schema = z.object({
  nombreEmpresa: z.string().trim().min(1, "Obligatorio").max(150, "Máximo 150 caracteres"),
  ruc: z.string().trim().max(20, "Máximo 20 caracteres"),
  correoEmpresa: z
    .string()
    .trim()
    .max(100, "Máximo 100 caracteres")
    .refine((v) => v === "" || z.string().email().safeParse(v).success, "Correo inválido"),
  telefono: z.string().trim().max(20, "Máximo 20 caracteres"),
  direccion: z.string().trim().max(255, "Máximo 255 caracteres"),
  // Los tres combobox devuelven strings. Son opcionales: una empresa puede
  // cargarse sin dirección todavía.
  idPais: z.string(),
  idDepartamento: z.string(),
  idCiudad: z.string(),
  monedaDefecto: z.string().trim().max(3, "Máximo 3 caracteres"),
  representanteLegal: z.string().trim().max(200, "Máximo 200 caracteres"),
  activo: z.boolean(),
});

type FormValues = z.infer<typeof schema>;

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/**
 * Cuántas filas se muestran de entrada, y cuántas suma cada "Mostrar más".
 *
 * El endpoint devuelve todo de una vez —poco para la red, mucho para el DOM—,
 * así que la tabla corta acá.
 */
const POR_PAGINA = 20;

function EmpresasPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Empresa | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Empresa | null>(null);
  const [filtroCiudad, setFiltroCiudad] = useState<string>(SIN_FILTRO);

  // El endpoint trae todas las empresas y el filtro se aplica acá abajo, sobre
  // la columna Ubicación. Cambiar de ciudad no dispara un viaje a la red.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["empresas", null],
    queryFn: () => api.empresas.listar(),
  });

  const empresasFiltradas = (data?.items ?? []).filter(
    (e) => filtroCiudad === SIN_FILTRO || String(e.idCiudad) === filtroCiudad,
  );

  // Las ciudades alimentan el filtro. Misma queryKey que usa la página de
  // Ciudades al listar sin filtrar, así TanStack Query las comparte.
  const { data: ciudades } = useQuery({
    queryKey: ["ciudades", null],
    queryFn: () => api.ciudades.listar(),
  });

  const eliminar = useMutation({
    mutationFn: (empresa: Empresa) => api.empresas.eliminar(empresa.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["empresas"] });
      toast.success("Empresa eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  // Búsqueda por cualquier campo visible + orden por click en el header.
  // Ver el criterio general en la guía de frontend, sección "Listados".
  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    empresasFiltradas,
    (e) => [e.nombreEmpresa, e.ruc, e.ciudad, e.pais, esActivo(e.activo) ? "Activo" : "Inactivo"],
  );

  const ciudadesOpciones = (ciudades?.items ?? []).map((c) => ({
    valor: String(c.id),
    etiqueta: c.nombreCiudad,
    descripcion: c.departamento,
  }));

  // Cuántas filas se están mostrando. Se resetea al cambiar el filtro o la
  // búsqueda: seguir en "80 de 90" tras filtrar a 12 perdería el sentido.
  const [visibles, setVisibles] = useState(POR_PAGINA);
  const claveVista = `${filtroCiudad}|${termino}`;
  const [claveAnterior, setClaveAnterior] = useState(claveVista);
  if (claveVista !== claveAnterior) {
    // Ajuste de estado en render, no useEffect: React re-renderiza antes de
    // pintar, así que la lista nunca se ve con el valor viejo.
    setClaveAnterior(claveVista);
    setVisibles(POR_PAGINA);
  }

  const mostrados = resultado.slice(0, visibles);
  const quedan = resultado.length - mostrados.length;

  return (
    <AppLayout active="/empresas" title="Empresas">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Empresas</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Empresas registradas en el sistema.
            </p>
          </div>
          <Button onClick={() => setCreando(true)}>
            <Plus className="size-4" />
            Nueva empresa
          </Button>
        </div>

        {/* El filtro por ciudad vive en el header de la columna Ubicación. */}
        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre, RUC, ciudad…"
            className="pl-9"
          />
        </div>

        {isPending && (
          <div className="space-y-2">
            {[0, 1, 2, 3, 4].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        )}

        {isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
            {MENSAJE_ERROR(error, "No se pudo cargar la lista")}
          </p>
        )}

        {!isPending && !isError && resultado.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {termino
                ? `Sin resultados para "${busqueda.trim()}".`
                : filtroCiudad === SIN_FILTRO
                  ? "Todavía no hay empresas cargadas."
                  : "Esa ciudad todavía no tiene empresas cargadas."}
            </p>
            {!termino && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                <Plus className="size-4" />
                Cargar la primera
              </Button>
            )}
          </div>
        )}

        {/* Móvil: tarjetas. Una tabla de 5 columnas en 360px obliga a scrollear
            de costado para leer una fila entera. */}
        {resultado.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {mostrados.map((empresa) => {
              const activo = esActivo(empresa.activo);

              return (
                <li key={empresa.id} className="surface-card p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">
                        {empresa.nombreEmpresa}
                      </p>
                      {empresa.ruc && (
                        <p className="mt-0.5 text-xs text-muted-foreground">RUC {empresa.ruc}</p>
                      )}
                      {empresa.ciudad && (
                        <p className="mt-0.5 text-xs text-muted-foreground">{empresa.ciudad}</p>
                      )}
                    </div>
                    <Badge variant={activo ? "secondary" : "outline"} className="shrink-0">
                      {activo ? "Activo" : "Inactivo"}
                    </Badge>
                  </div>

                  <div className="mt-3 flex gap-2 border-t border-border pt-3">
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1"
                      onClick={() => setEditando(empresa)}
                    >
                      <Pencil className="size-4" />
                      Editar
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                      onClick={() => setAEliminar(empresa)}
                    >
                      <Trash2 className="size-4" />
                      Eliminar
                    </Button>
                  </div>
                </li>
              );
            })}
          </ul>
        )}

        {resultado.length > 0 && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "nombreEmpresa" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreEmpresa")}
                  >
                    Empresa
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "ruc" ? orden.direccion : null}
                    onClick={() => alternarOrden("ruc")}
                  >
                    RUC
                  </TableHeadOrdenable>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "ciudad" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("ciudad")}
                    opciones={ciudadesOpciones.map((c) => ({
                      valor: c.valor,
                      etiqueta: c.etiqueta,
                    }))}
                    valor={filtroCiudad}
                    onFiltrar={setFiltroCiudad}
                    buscarPlaceholder="Buscar ciudad…"
                  >
                    Ubicación
                  </TableHeadFiltrable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "activo" ? orden.direccion : null}
                    onClick={() => alternarOrden("activo")}
                  >
                    Estado
                  </TableHeadOrdenable>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {mostrados.map((empresa) => {
                  const activo = esActivo(empresa.activo);

                  return (
                    <TableRow key={empresa.id}>
                      <TableCell className="font-medium text-foreground">
                        {empresa.nombreEmpresa}
                      </TableCell>
                      <TableCell className="text-muted-foreground">{empresa.ruc || "—"}</TableCell>
                      <TableCell className="text-muted-foreground">
                        {empresa.ciudad
                          ? `${empresa.ciudad}${empresa.pais ? ` (${empresa.pais})` : ""}`
                          : "—"}
                      </TableCell>
                      <TableCell>
                        <Badge variant={activo ? "secondary" : "outline"}>
                          {activo ? "Activo" : "Inactivo"}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-right">
                        <div className="flex justify-end gap-1">
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Editar"
                            aria-label={`Editar ${empresa.nombreEmpresa}`}
                            onClick={() => setEditando(empresa)}
                          >
                            <Pencil className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Eliminar"
                            aria-label={`Eliminar ${empresa.nombreEmpresa}`}
                            onClick={() => setAEliminar(empresa)}
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

        {quedan > 0 && (
          <div className="flex justify-center">
            <Button variant="outline" onClick={() => setVisibles((v) => v + POR_PAGINA)}>
              Mostrar {Math.min(quedan, POR_PAGINA)} más
            </Button>
          </div>
        )}

        {data && resultado.length > 0 && (
          <p className="text-center text-xs text-muted-foreground">
            Mostrando {mostrados.length} de {resultado.length} empresa
            {resultado.length === 1 ? "" : "s"}
            {termino || filtroCiudad !== SIN_FILTRO ? ` (${data.items.length} en total)` : ""}
          </p>
        )}

        <EmpresaFormDialog
          open={creando || editando !== null}
          empresa={editando}
          onClose={() => {
            setCreando(false);
            setEditando(null);
          }}
        />

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreEmpresa}?</AlertDialogTitle>
              <AlertDialogDescription>Esta acción no se puede deshacer.</AlertDialogDescription>
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
/* Alta / Edición                                                              */
/* -------------------------------------------------------------------------- */

function EmpresaFormDialog({
  open,
  empresa,
  onClose,
}: {
  open: boolean;
  empresa: Empresa | null;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = empresa !== null;

  const { data: paises, isPending: cargandoPaises } = useQuery({
    queryKey: ["paises"],
    queryFn: () => api.paises.listar(),
  });
  const { data: departamentos, isPending: cargandoDepartamentos } = useQuery({
    queryKey: ["departamentos", null],
    queryFn: () => api.departamentos.listar(),
  });
  const { data: ciudades, isPending: cargandoCiudades } = useQuery({
    queryKey: ["ciudades", null],
    queryFn: () => api.ciudades.listar(),
  });

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Sin defaults React avisa por inputs no controlados. Un alta nace activa:
    // cargar una empresa para dejarla inactiva de entrada no tiene sentido.
    values: {
      nombreEmpresa: empresa?.nombreEmpresa ?? "",
      ruc: empresa?.ruc ?? "",
      correoEmpresa: empresa?.correoEmpresa ?? "",
      telefono: empresa?.telefono ?? "",
      direccion: empresa?.direccion ?? "",
      idPais: empresa?.idPais ? String(empresa.idPais) : "",
      idDepartamento: empresa?.idDepartamento ? String(empresa.idDepartamento) : "",
      idCiudad: empresa?.idCiudad ? String(empresa.idCiudad) : "",
      monedaDefecto: empresa?.monedaDefecto ?? "PYG",
      representanteLegal: empresa?.representanteLegal ?? "",
      activo: empresa ? esActivo(empresa.activo) : true,
    },
  });

  // La cascada: cada nivel acota al siguiente. Se miran los valores actuales
  // del formulario, no un estado aparte, para que al editar una empresa ya
  // cargada los combobox hijos muestren las opciones correctas de entrada.
  const idPaisElegido = form.watch("idPais");
  const idDepartamentoElegido = form.watch("idDepartamento");

  const paisesOpciones = (paises?.items ?? []).map((p) => ({
    valor: String(p.id),
    etiqueta: p.nombrePais,
    descripcion: p.codigoPais ?? undefined,
  }));

  const departamentosOpciones = (departamentos?.items ?? [])
    .filter((d) => !idPaisElegido || String(d.idPais) === idPaisElegido)
    .map((d) => ({
      valor: String(d.id),
      etiqueta: d.nombreDepartamento,
      descripcion: d.pais,
    }));

  const ciudadesOpciones = (ciudades?.items ?? [])
    .filter((c) => !idDepartamentoElegido || String(c.idDepartamento) === idDepartamentoElegido)
    .map((c) => ({
      valor: String(c.id),
      etiqueta: c.nombreCiudad,
      descripcion: c.departamento,
    }));

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const activo: Estado = v.activo ? "A" : "I";
      // Los opcionales vacíos no se mandan: en el UPDATE un campo ausente
      // significa "no cambiar", que es justo lo que corresponde.
      const opcionales = {
        ...(v.ruc ? { ruc: v.ruc } : {}),
        ...(v.correoEmpresa ? { correoEmpresa: v.correoEmpresa } : {}),
        ...(v.telefono ? { telefono: v.telefono } : {}),
        ...(v.direccion ? { direccion: v.direccion } : {}),
        ...(v.idPais ? { idPais: Number(v.idPais) } : {}),
        ...(v.idDepartamento ? { idDepartamento: Number(v.idDepartamento) } : {}),
        ...(v.idCiudad ? { idCiudad: Number(v.idCiudad) } : {}),
        ...(v.monedaDefecto ? { monedaDefecto: v.monedaDefecto } : {}),
        ...(v.representanteLegal ? { representanteLegal: v.representanteLegal } : {}),
      };

      return esEdicion
        ? api.empresas.actualizar(empresa.id, {
            nombreEmpresa: v.nombreEmpresa,
            activo,
            ...opcionales,
          })
        : api.empresas.crear({
            nombreEmpresa: v.nombreEmpresa,
            ...opcionales,
          });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["empresas"] });
      toast.success(esEdicion ? "Empresa actualizada" : "Empresa creada");
      onClose();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear la empresa"),
      ),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-h-[85vh] max-w-2xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar empresa" : "Nueva empresa"}</DialogTitle>
          <DialogDescription>
            {esEdicion ? "Modificá los datos de la empresa." : "Agregá una empresa al sistema."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="nombreEmpresa"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre de la empresa</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Ctell S.A." autoComplete="off" />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="ruc"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>RUC (opcional)</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="80012345-6" autoComplete="off" />
                  </FormControl>
                  <FormDescription>No puede repetirse.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="correoEmpresa"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Correo (opcional)</FormLabel>
                    <FormControl>
                      <Input {...field} type="email" placeholder="info@ctell.com" />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="telefono"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Teléfono (opcional)</FormLabel>
                    <FormControl>
                      <Input {...field} placeholder="021 123 456" autoComplete="off" />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            {/* Ubicación en cascada: el país acota los departamentos, y el
                departamento las ciudades. Elegir un nivel superior limpia los
                de abajo, o quedarían apuntando a un lugar que ya no aplica. */}
            <FormField
              control={form.control}
              name="idPais"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>País (opcional)</FormLabel>
                  <FormControl>
                    <Combobox
                      opciones={paisesOpciones}
                      value={field.value}
                      onChange={(v) => {
                        field.onChange(v);
                        form.setValue("idDepartamento", "");
                        form.setValue("idCiudad", "");
                      }}
                      placeholder="Elegí un país"
                      buscarPlaceholder="Buscar país…"
                      cargando={cargandoPaises}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="idDepartamento"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Departamento (opcional)</FormLabel>
                  <FormControl>
                    <Combobox
                      opciones={departamentosOpciones}
                      value={field.value}
                      onChange={(v) => {
                        field.onChange(v);
                        form.setValue("idCiudad", "");
                      }}
                      placeholder={
                        idPaisElegido ? "Elegí un departamento" : "Elegí primero el país"
                      }
                      buscarPlaceholder="Buscar departamento…"
                      cargando={cargandoDepartamentos}
                      disabled={!idPaisElegido}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="idCiudad"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Ciudad (opcional)</FormLabel>
                  <FormControl>
                    <Combobox
                      opciones={ciudadesOpciones}
                      value={field.value}
                      onChange={field.onChange}
                      placeholder={
                        idDepartamentoElegido ? "Elegí una ciudad" : "Elegí primero el departamento"
                      }
                      buscarPlaceholder="Buscar ciudad…"
                      cargando={cargandoCiudades}
                      disabled={!idDepartamentoElegido}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="direccion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Dirección (opcional)</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Avda. España 123" autoComplete="off" />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="monedaDefecto"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Moneda por defecto</FormLabel>
                    <FormControl>
                      <Input {...field} placeholder="PYG" autoComplete="off" maxLength={3} />
                    </FormControl>
                    <FormDescription>Código de tres letras.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="representanteLegal"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Representante legal (opcional)</FormLabel>
                    <FormControl>
                      <Input {...field} placeholder="Juan Pérez" autoComplete="off" />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            {/* Solo en edición: el alta siempre nace activa. */}
            {esEdicion && (
              <FormField
                control={form.control}
                name="activo"
                render={({ field }) => (
                  <FormItem className="flex items-center justify-between rounded-lg border border-border p-3">
                    <div className="space-y-0.5">
                      <FormLabel>Activo</FormLabel>
                      <FormDescription>
                        Una empresa inactiva deja de ofrecerse en los formularios.
                      </FormDescription>
                    </div>
                    <FormControl>
                      <Switch checked={field.value} onCheckedChange={field.onChange} />
                    </FormControl>
                  </FormItem>
                )}
              />
            )}

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onClose}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {guardar.isPending ? "Guardando…" : esEdicion ? "Guardar cambios" : "Crear empresa"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/empresas")({
  head: () => ({
    meta: [
      { title: "Empresas | CTELL" },
      { name: "description", content: "Empresas registradas en el sistema." },
    ],
  }),
  component: EmpresasPage,
});
