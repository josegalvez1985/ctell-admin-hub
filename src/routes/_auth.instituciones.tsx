import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { SelectorModal } from "@/components/ctell/SelectorModal";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, type Institucion } from "@/lib/api";
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
import { Textarea } from "@/components/ui/textarea";
import { tituloPagina } from "@/lib/marca";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

const schema = z.object({
  idPais: z.string().min(1, "Elegí un país"),
  idDepartamento: z.string().min(1, "Elegí un departamento"),
  // Opcional de verdad: el DDL deja ID_CIUDAD nullable.
  idCiudad: z.string(),
  nombreInstitucion: z.string().trim().min(1, "Obligatorio").max(200, "Máximo 200 caracteres"),
  direccion: z.string().trim().max(500, "Máximo 500 caracteres"),
  director: z.string().trim().max(200, "Máximo 200 caracteres"),
  contacto: z.string().trim().max(20, "Máximo 20 caracteres"),
  // El vacío se acepta porque el campo es opcional; `z.string().email()` sobre
  // "" daría error y obligaría a cargar un correo que puede no existir.
  correo: z
    .string()
    .trim()
    .max(100, "Máximo 100 caracteres")
    .refine((v) => v === "" || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v), "Correo inválido"),
  ubicacion: z.string().trim().max(500, "Máximo 500 caracteres"),
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

function InstitucionesPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Institucion | null>(null);
  const [creando, setCreando] = useState(false);
  // Filtro de la columna Departamento. Va acá y no en el endpoint: el listado ya
  // vino entero, así que cambiar de departamento es instantáneo.
  const [filtroDepartamento, setFiltroDepartamento] = useState<string>(SIN_FILTRO);
  const [aEliminar, setAEliminar] = useState<Institucion | null>(null);

  // Las instituciones son POR EMPRESA: la que se eligió al iniciar sesión. No
  // hay filtro ni combobox de empresa en la pantalla.
  const { empresa } = useEmpresa();

  // La empresa entra en la queryKey: al cambiarla, TanStack Query trata el
  // listado como otra consulta en vez de mostrar en caché las de la anterior.
  //
  // `enabled` evita pedir sin empresa. En el primer render todavía es null
  // —el provider hidrata desde localStorage después de montar— y sin esto la
  // petición saldría con idEmpresa vacío, devolviendo las de TODAS las empresas.
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["instituciones", empresa?.id ?? null],
    queryFn: () => api.instituciones.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  const eliminar = useMutation({
    mutationFn: (inst: Institucion) => api.instituciones.eliminar(inst.id, inst.idEmpresa),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["instituciones"] });
      toast.success("Institución eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  // El filtro se aplica ANTES de la búsqueda: buscar dentro de lo filtrado es lo
  // que espera quien acotó primero la columna.
  const filtrados = (data?.items ?? []).filter(
    (x) => filtroDepartamento === SIN_FILTRO || x.departamento === filtroDepartamento,
  );

  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    filtrados,
    (i) => [
      i.nombreInstitucion,
      i.director,
      i.contacto,
      i.correo,
      i.direccion,
      i.pais,
      i.departamento,
      i.ciudad,
    ],
  );

  // Las opciones del filtro salen de las instituciones ya listadas, no de
  // /departamentos/listar: filtrar por un departamento sin ninguna institución
  // vaciaría la tabla, así que las únicas opciones útiles son las que aparecen.
  const departamentosOpciones = Array.from(
    new Set((data?.items ?? []).map((i) => i.departamento)),
  )
    .sort((a, b) => a.localeCompare(b, "es"))
    .map((d) => ({ valor: d, etiqueta: d }));

  // Cuántas filas se están mostrando. Se resetea al cambiar la búsqueda o el
  // filtro: seguir en "80 de 90" tras filtrar a 12 perdería el sentido.
  const [visibles, setVisibles] = useState(POR_PAGINA);
  const claveVista = `${filtroDepartamento}|${termino}`;
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
    <AppLayout active="/instituciones" title="Instituciones">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Instituciones</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {empresa
                ? `Instituciones de ${empresa.nombreEmpresa}.`
                : "Instituciones de la empresa con la que iniciaste sesión."}
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null}>
            <Plus className="size-4" />
            Nueva institución
          </Button>
        </div>

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre, director, contacto, ciudad…"
            className="pl-9"
          />
        </div>

        {/* Sin empresa no hay nada que listar. Pasa si se entró con una sesión
            vieja, de antes de que el login pidiera elegirla. */}
        {empresa === null && !isPending && (
          <p className="rounded-lg border border-border px-3 py-6 text-center text-sm text-muted-foreground">
            No hay una empresa activa. Cerrá sesión y volvé a entrar eligiendo una.
          </p>
        )}

        {isPending && empresa !== null && (
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

        {!isPending && !isError && empresa !== null && resultado.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {termino || filtroDepartamento !== SIN_FILTRO
                ? `Ninguna institución coincide con la búsqueda.`
                : "Esta empresa todavía no tiene instituciones cargadas."}
            </p>
            {!termino && filtroDepartamento === SIN_FILTRO && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                <Plus className="size-4" />
                Cargar la primera
              </Button>
            )}
          </div>
        )}

        {/* Móvil: tarjetas. Una tabla de 6 columnas en 360px obliga a scrollear
            de costado para leer una fila entera. */}
        {resultado.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {mostrados.map((inst) => (
              <li key={inst.id} className="surface-card p-4">
                {/* Sin truncar: el nombre de una institución es largo por
                    naturaleza ("Colegio Nacional de la Capital") y cortado deja
                    dos filas distintas con el mismo texto. */}
                <p className="font-semibold leading-snug text-foreground">
                  {inst.nombreInstitucion}
                </p>
                <p className="mt-0.5 text-xs text-muted-foreground">
                  {[inst.ciudad, inst.departamento, inst.pais].filter(Boolean).join(" · ")}
                </p>

                <dl className="mt-3 space-y-1 border-t border-border pt-3 text-xs">
                  {inst.director && (
                    <div>
                      <dt className="inline text-muted-foreground">Director: </dt>
                      <dd className="inline text-foreground">{inst.director}</dd>
                    </div>
                  )}
                  {inst.contacto && (
                    <div>
                      <dt className="inline text-muted-foreground">Contacto: </dt>
                      <dd className="inline tabular-nums text-foreground">{inst.contacto}</dd>
                    </div>
                  )}
                  {inst.correo && (
                    <div>
                      <dt className="inline text-muted-foreground">Correo: </dt>
                      <dd className="inline break-all text-foreground">{inst.correo}</dd>
                    </div>
                  )}
                  {inst.direccion && (
                    <div>
                      <dt className="inline text-muted-foreground">Dirección: </dt>
                      <dd className="inline text-foreground">{inst.direccion}</dd>
                    </div>
                  )}
                </dl>

                <div className="mt-3 flex gap-2 border-t border-border pt-3">
                  <Button
                    variant="outline"
                    size="sm"
                    className="flex-1"
                    onClick={() => setEditando(inst)}
                  >
                    <Pencil className="size-4" />
                    Editar
                  </Button>
                  <Button
                    variant="outline"
                    size="sm"
                    className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                    onClick={() => setAEliminar(inst)}
                  >
                    <Trash2 className="size-4" />
                    Eliminar
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}

        {resultado.length > 0 && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "nombreInstitucion" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreInstitucion")}
                  >
                    Institución
                  </TableHeadOrdenable>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "departamento" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("departamento")}
                    opciones={departamentosOpciones}
                    valor={filtroDepartamento}
                    onFiltrar={setFiltroDepartamento}
                    buscarPlaceholder="Buscar departamento…"
                  >
                    Ubicación
                  </TableHeadFiltrable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "director" ? orden.direccion : null}
                    onClick={() => alternarOrden("director")}
                  >
                    Director
                  </TableHeadOrdenable>
                  <TableHead>Contacto</TableHead>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {mostrados.map((inst) => (
                  <TableRow key={inst.id}>
                    <TableCell className="font-medium text-foreground">
                      {inst.nombreInstitucion}
                      {inst.direccion && (
                        <span className="block text-xs font-normal text-muted-foreground">
                          {inst.direccion}
                        </span>
                      )}
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {/* Ciudad primero: es lo más específico y lo que más
                          identifica. El país va debajo porque suele repetirse en
                          todas las filas. */}
                      {inst.ciudad ?? "—"}
                      <span className="block text-xs">
                        {inst.departamento}, {inst.pais}
                      </span>
                    </TableCell>
                    <TableCell className="text-muted-foreground">{inst.director ?? "—"}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {inst.contacto ?? "—"}
                      {inst.correo && (
                        <span className="block break-all text-xs">{inst.correo}</span>
                      )}
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex justify-end gap-1">
                        <Button
                          variant="ghost"
                          size="icon"
                          title="Editar"
                          aria-label={`Editar ${inst.nombreInstitucion}`}
                          onClick={() => setEditando(inst)}
                        >
                          <Pencil className="size-4" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="icon"
                          title="Eliminar"
                          aria-label={`Eliminar ${inst.nombreInstitucion}`}
                          onClick={() => setAEliminar(inst)}
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
            Mostrando {mostrados.length} de {resultado.length} institución
            {resultado.length === 1 ? "" : "es"}
            {termino ? ` (${data.items.length} en total)` : ""}
          </p>
        )}

        {/* Sin empresa no se abre: el alta necesita su id. */}
        {empresa !== null && (
          <InstitucionFormDialog
            open={creando || editando !== null}
            institucion={editando}
            idEmpresa={empresa.id}
            onClose={() => {
              setCreando(false);
              setEditando(null);
            }}
          />
        )}

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreInstitucion}?</AlertDialogTitle>
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

function InstitucionFormDialog({
  open,
  institucion,
  idEmpresa,
  onClose,
}: {
  open: boolean;
  institucion: Institucion | null;
  /** Empresa activa de la sesión. No es un campo del formulario. */
  idEmpresa: number;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = institucion !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    values: {
      idPais: institucion ? String(institucion.idPais) : "",
      idDepartamento: institucion ? String(institucion.idDepartamento) : "",
      idCiudad: institucion?.idCiudad != null ? String(institucion.idCiudad) : "",
      nombreInstitucion: institucion?.nombreInstitucion ?? "",
      direccion: institucion?.direccion ?? "",
      director: institucion?.director ?? "",
      contacto: institucion?.contacto ?? "",
      correo: institucion?.correo ?? "",
      ubicacion: institucion?.ubicacion ?? "",
    },
  });

  // LOS TRES SELECTORES ESTÁN ENCADENADOS: el de departamentos se filtra por el
  // país elegido y el de ciudades por el departamento. Es lo que evita cargar
  // una cadena incoherente —el backend la rechaza con un 400, pero mejor no
  // ofrecer la combinación inválida que explicarla después.
  const idPais = form.watch("idPais");
  const idDepartamento = form.watch("idDepartamento");

  const { data: paises, isPending: cargandoPaises } = useQuery({
    queryKey: ["paises"],
    queryFn: () => api.paises.listar(),
  });

  // `enabled` evita pedir sin país: el endpoint sin filtro devolvería los
  // departamentos de TODOS los países, que es justo lo que la cascada impide.
  const { data: departamentos, isPending: cargandoDepartamentos } = useQuery({
    queryKey: ["departamentos", idPais || null],
    queryFn: () => api.departamentos.listar({ idPais: Number(idPais) }),
    enabled: idPais !== "",
  });

  const { data: ciudades, isPending: cargandoCiudades } = useQuery({
    queryKey: ["ciudades", idDepartamento || null],
    queryFn: () => api.ciudades.listar({ idDepartamento: Number(idDepartamento) }),
    enabled: idDepartamento !== "",
  });

  const paisesOpciones = (paises?.items ?? []).map((p) => ({
    valor: String(p.id),
    etiqueta: p.nombrePais,
  }));

  const departamentosOpciones = (departamentos?.items ?? []).map((d) => ({
    valor: String(d.id),
    etiqueta: d.nombreDepartamento,
  }));

  const ciudadesOpciones = (ciudades?.items ?? []).map((c) => ({
    valor: String(c.id),
    etiqueta: c.nombreCiudad,
  }));

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      // Los opcionales de texto se mandan sólo si tienen algo: mandar "" en el
      // alta guardaría una cadena vacía en vez de NULL.
      const opcionales = {
        ...(v.direccion ? { direccion: v.direccion } : {}),
        ...(v.director ? { director: v.director } : {}),
        ...(v.contacto ? { contacto: v.contacto } : {}),
        ...(v.correo ? { correo: v.correo } : {}),
        ...(v.ubicacion ? { ubicacion: v.ubicacion } : {}),
      };

      if (esEdicion) {
        return api.instituciones.actualizar(institucion.id, {
          idEmpresa: institucion.idEmpresa,
          idPais: Number(v.idPais),
          idDepartamento: Number(v.idDepartamento),
          // Vaciar la ciudad en la edición SÍ tiene que borrarla, pero para el
          // backend "ausente" significa "no cambiar". El literal "null"
          // distingue las dos intenciones.
          idCiudad: v.idCiudad ? Number(v.idCiudad) : "null",
          nombreInstitucion: v.nombreInstitucion,
          ...opcionales,
        });
      }

      return api.instituciones.crear({
        idEmpresa,
        idPais: Number(v.idPais),
        idDepartamento: Number(v.idDepartamento),
        // En el alta se omite y listo: no hay valor previo que conservar.
        ...(v.idCiudad ? { idCiudad: Number(v.idCiudad) } : {}),
        nombreInstitucion: v.nombreInstitucion,
        ...opcionales,
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["instituciones"] });
      toast.success(esEdicion ? "Institución actualizada" : "Institución creada");
      onClose();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear la institución"),
      ),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      {/* Más ancho que el `max-w-lg` por defecto: son diez campos y los nombres
          de institución son largos. */}
      <DialogContent className="scrollbar-fino max-h-[92vh] max-w-[95vw] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar institución" : "Nueva institución"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos de la institución."
              : "Agregá una institución a la empresa con la que iniciaste sesión."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="nombreInstitucion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre de la institución</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Colegio Nacional" autoComplete="off" />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <div className="grid gap-4 sm:grid-cols-3">
              <FormField
                control={form.control}
                name="idPais"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>País</FormLabel>
                    <FormControl>
                      <SelectorModal
                        opciones={paisesOpciones}
                        value={field.value}
                        onChange={(v) => {
                          field.onChange(v);
                          // Cambiar el país invalida lo que cuelga de él: el
                          // departamento elegido puede ser de otro país, y
                          // dejarlo mandaría una cadena rota que el backend
                          // rechazaría con un 400 confuso.
                          form.setValue("idDepartamento", "");
                          form.setValue("idCiudad", "");
                        }}
                        placeholder="Elegí el país"
                        titulo="Elegí el país"
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
                    <FormLabel>Departamento</FormLabel>
                    <FormControl>
                      <SelectorModal
                        opciones={departamentosOpciones}
                        value={field.value}
                        onChange={(v) => {
                          field.onChange(v);
                          // Misma razón que arriba: la ciudad cuelga del
                          // departamento.
                          form.setValue("idCiudad", "");
                        }}
                        placeholder={idPais ? "Elegí el departamento" : "Elegí un país primero"}
                        titulo="Elegí el departamento"
                        buscarPlaceholder="Buscar departamento…"
                        cargando={cargandoDepartamentos}
                        disabled={idPais === ""}
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
                    <FormLabel>Ciudad</FormLabel>
                    <FormControl>
                      <SelectorModal
                        opciones={ciudadesOpciones}
                        value={field.value}
                        onChange={field.onChange}
                        placeholder={
                          idDepartamento ? "Opcional" : "Elegí un departamento primero"
                        }
                        titulo="Elegí la ciudad"
                        buscarPlaceholder="Buscar ciudad…"
                        cargando={cargandoCiudades}
                        disabled={idDepartamento === ""}
                      />
                    </FormControl>
                    <FormDescription>Opcional.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            <FormField
              control={form.control}
              name="direccion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Dirección</FormLabel>
                  <FormControl>
                    <Input
                      {...field}
                      placeholder="Avenida Mariscal López 1234"
                      autoComplete="off"
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="director"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Director</FormLabel>
                    <FormControl>
                      <Input {...field} placeholder="Nombre y apellido" autoComplete="off" />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="contacto"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Contacto</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        inputMode="tel"
                        placeholder="0981 123 456"
                        autoComplete="off"
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            <FormField
              control={form.control}
              name="correo"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Correo</FormLabel>
                  <FormControl>
                    <Input
                      {...field}
                      type="email"
                      placeholder="contacto@institucion.edu.py"
                      autoComplete="off"
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="ubicacion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Ubicación geográfica</FormLabel>
                  <FormControl>
                    <Textarea
                      {...field}
                      rows={2}
                      placeholder="Coordenadas, link de mapa o una referencia"
                      className="scrollbar-fino"
                    />
                  </FormControl>
                  <FormDescription>
                    Opcional. Texto libre: no es la dirección postal sino cómo llegar.
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <DialogFooter className="gap-2">
              <Button
                type="submit"
                disabled={guardar.isPending}
                className="h-11 w-full sm:h-10 sm:w-auto"
              >
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {guardar.isPending
                  ? "Guardando…"
                  : esEdicion
                    ? "Guardar cambios"
                    : "Crear institución"}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={onClose}
                className="h-11 w-full sm:h-10 sm:w-auto"
              >
                Cancelar
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/instituciones")({
  head: () => ({
    meta: [
      { title: tituloPagina("Instituciones") },
      {
        name: "description",
        content: "Instituciones por empresa, con su ubicación geográfica.",
      },
    ],
  }),
  component: InstitucionesPage,
});
