import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esJuridica, type Persona, type TipoPersona } from "@/lib/api";
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
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/** Cuántas filas se muestran de entrada, y cuántas suma cada "Mostrar más". */
const POR_PAGINA = 20;

/**
 * Los campos obligatorios dependen del tipo, así que la validación cruzada va en
 * un `superRefine` y no en cada campo: `nombre` no es "obligatorio" ni
 * "opcional" por sí solo, lo es según lo que valga `tipoPersona`.
 *
 * Es la misma regla que aplica el backend. Acá se valida además para no gastar
 * un viaje a la red en un error que se ve en el formulario.
 */
const schema = z
  .object({
    tipoPersona: z.enum(["F", "J"]),
    nombre: z.string().trim().max(100, "Máximo 100 caracteres"),
    apellido: z.string().trim().max(100, "Máximo 100 caracteres"),
    razonSocial: z.string().trim().max(200, "Máximo 200 caracteres"),
    numeroCi: z.string().trim().max(20, "Máximo 20 caracteres"),
    ruc: z.string().trim().max(20, "Máximo 20 caracteres"),
    // El mail se valida sólo si se cargó: es opcional, y un `z.string().email()`
    // sobre "" fallaría en cada alta que no lo incluya.
    email: z
      .string()
      .trim()
      .max(100, "Máximo 100 caracteres")
      .refine((v) => v === "" || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v), "Correo inválido"),
    telefono: z.string().trim().max(50, "Máximo 50 caracteres"),
    direccion: z.string().trim().max(500, "Máximo 500 caracteres"),
  })
  .superRefine((v, ctx) => {
    if (v.tipoPersona === "J") {
      if (v.razonSocial === "") {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: "Obligatoria en una persona jurídica",
          path: ["razonSocial"],
        });
      }
      return;
    }

    if (v.nombre === "") {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Obligatorio", path: ["nombre"] });
    }
    if (v.apellido === "") {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Obligatorio", path: ["apellido"] });
    }
  });

type FormValues = z.infer<typeof schema>;

/** Cómo se rotula cada tipo. Una sola definición para la tabla y los filtros. */
const ETIQUETA_TIPO: Record<TipoPersona, string> = {
  F: "Física",
  J: "Jurídica",
};

/**
 * Personas: el padrón de físicas y jurídicas.
 *
 * ES UN CATÁLOGO GLOBAL, como Países o Ciudades: no cuelga de la empresa activa,
 * así que no usa `useEmpresa()` ni lleva `idEmpresa` en la queryKey. El padrón
 * es uno solo y lo comparten todas las empresas — la misma persona puede ser
 * cliente de una y proveedor de otra sin cargarse dos veces.
 *
 * Y NO TIENE ESTADO: la tabla no lleva columna `ACTIVO`, así que no hay baja
 * lógica ni toggle de activo. La única baja es física, y va a dar 409 cuando la
 * persona tenga movimientos asociados.
 */
function PersonasPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Persona | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Persona | null>(null);
  const [filtroTipo, setFiltroTipo] = useState<string>(SIN_FILTRO);
  const [visibles, setVisibles] = useState(POR_PAGINA);

  // Sin empresa en la queryKey: el padrón no depende de ella.
  const { data, isPending, isError } = useQuery({
    queryKey: ["personas"],
    queryFn: () => api.personas.listar(),
  });

  const items = data?.items ?? [];

  // El endpoint acepta ?tipo=, pero el filtro se aplica en el cliente: el
  // listado ya vino entero, así que cambiar de tipo es instantáneo.
  const filtrados = items.filter((p) => filtroTipo === SIN_FILTRO || p.tipoPersona === filtroTipo);

  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    filtrados,
    (p) => [
      p.nombreCompleto,
      p.numeroCi,
      p.ruc,
      p.email,
      p.telefono,
      p.direccion,
      ETIQUETA_TIPO[p.tipoPersona],
    ],
  );

  const mostrados = resultado.slice(0, visibles);

  // Se resetea al cambiar filtro o búsqueda: seguir en "80 de 90" después de
  // filtrar a 12 resultados mostraría todo de golpe. Ajuste en render, no
  // useEffect: React re-renderiza antes de pintar.
  const claveVista = `${filtroTipo}|${termino}`;
  const [claveAnterior, setClaveAnterior] = useState(claveVista);
  if (claveVista !== claveAnterior) {
    setClaveAnterior(claveVista);
    setVisibles(POR_PAGINA);
  }

  const eliminar = useMutation({
    mutationFn: (persona: Persona) => api.personas.eliminar(persona.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["personas"] });
      toast.success("Persona eliminada");
      setAEliminar(null);
    },
    onError: (e) => {
      // El 409 de dependencias llega con su mensaje del backend, que explica por
      // qué no se puede: se muestra tal cual en vez de un "no se pudo" genérico.
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar la persona"));
      setAEliminar(null);
    },
  });

  const opcionesTipo = [
    { valor: "F", etiqueta: "Física" },
    { valor: "J", etiqueta: "Jurídica" },
  ];

  return (
    <AppLayout active="/personas" title="Personas">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Personas</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Padrón de personas físicas y jurídicas, compartido por todas las empresas.
            </p>
          </div>
          <Button onClick={() => setCreando(true)}>
            <Plus className="size-4" />
            Nueva persona
          </Button>
        </div>

        <div className="relative max-w-sm">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre, CI, RUC o contacto…"
            className="pl-9"
            aria-label="Buscar personas"
          />
        </div>

        {isPending ? (
          <div className="space-y-2">
            {[0, 1, 2, 3].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        ) : isError ? (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
            No se pudieron cargar las personas.
          </p>
        ) : resultado.length === 0 ? (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {termino || filtroTipo !== SIN_FILTRO
                ? "Ninguna persona coincide con la búsqueda."
                : "Todavía no hay personas cargadas."}
            </p>
            {!termino && filtroTipo === SIN_FILTRO && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                Cargar la primera
              </Button>
            )}
          </div>
        ) : (
          <>
            {/* Móvil: tarjetas. Una tabla de 6 columnas en 360px obliga a
                scrollear de costado para leer una fila entera. */}
            <ul className="space-y-3 sm:hidden">
              {mostrados.map((persona) => {
                const juridica = esJuridica(persona.tipoPersona);

                return (
                  <li key={persona.id} className="surface-card p-4">
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0 flex-1">
                        <p className="truncate font-semibold text-foreground">
                          {persona.nombreCompleto}
                        </p>
                        <p className="mt-0.5 text-xs text-muted-foreground">
                          {/* El documento que corresponde a cada tipo: en una
                              empresa el CI no aplica, y mostrarlo vacío haría
                              pensar que falta cargarlo. */}
                          {juridica
                            ? persona.ruc
                              ? `RUC ${persona.ruc}`
                              : "Sin RUC"
                            : persona.numeroCi
                              ? `CI ${persona.numeroCi}`
                              : "Sin CI"}
                        </p>
                      </div>
                      <Badge variant={juridica ? "secondary" : "outline"} className="shrink-0">
                        {ETIQUETA_TIPO[persona.tipoPersona]}
                      </Badge>
                    </div>

                    {(persona.email || persona.telefono) && (
                      <p className="mt-2 text-xs text-muted-foreground">
                        {[persona.email, persona.telefono].filter(Boolean).join(" · ")}
                      </p>
                    )}

                    <div className="mt-3 flex gap-2 border-t border-border pt-3">
                      <Button
                        variant="outline"
                        size="sm"
                        className="flex-1"
                        onClick={() => setEditando(persona)}
                      >
                        <Pencil className="size-4" />
                        Editar
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                        onClick={() => setAEliminar(persona)}
                      >
                        <Trash2 className="size-4" />
                        Eliminar
                      </Button>
                    </div>
                  </li>
                );
              })}
            </ul>

            <div className="surface-card hidden overflow-x-auto sm:block">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHeadOrdenable
                      direccion={orden?.campo === "nombreCompleto" ? orden.direccion : null}
                      onClick={() => alternarOrden("nombreCompleto")}
                    >
                      Nombre
                    </TableHeadOrdenable>
                    <TableHeadFiltrable
                      direccion={orden?.campo === "tipoPersona" ? orden.direccion : null}
                      onOrdenar={() => alternarOrden("tipoPersona")}
                      opciones={opcionesTipo}
                      valor={filtroTipo}
                      onFiltrar={setFiltroTipo}
                      buscarPlaceholder="Buscar tipo…"
                    >
                      Tipo
                    </TableHeadFiltrable>
                    <TableHeadOrdenable
                      direccion={orden?.campo === "numeroCi" ? orden.direccion : null}
                      onClick={() => alternarOrden("numeroCi")}
                    >
                      CI
                    </TableHeadOrdenable>
                    <TableHeadOrdenable
                      direccion={orden?.campo === "ruc" ? orden.direccion : null}
                      onClick={() => alternarOrden("ruc")}
                    >
                      RUC
                    </TableHeadOrdenable>
                    <TableHead>Contacto</TableHead>
                    <TableHead className="text-right">Acciones</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {mostrados.map((persona) => {
                    const juridica = esJuridica(persona.tipoPersona);

                    return (
                      <TableRow key={persona.id}>
                        <TableCell className="font-medium text-foreground">
                          {persona.nombreCompleto}
                        </TableCell>
                        <TableCell>
                          <Badge variant={juridica ? "secondary" : "outline"}>
                            {ETIQUETA_TIPO[persona.tipoPersona]}
                          </Badge>
                        </TableCell>
                        <TableCell className="tabular-nums text-muted-foreground">
                          {persona.numeroCi ?? "—"}
                        </TableCell>
                        <TableCell className="tabular-nums text-muted-foreground">
                          {persona.ruc ?? "—"}
                        </TableCell>
                        <TableCell className="text-muted-foreground">
                          {persona.email ?? "—"}
                          {persona.telefono && (
                            <span className="block text-xs">{persona.telefono}</span>
                          )}
                        </TableCell>
                        <TableCell className="text-right">
                          <div className="flex justify-end gap-1">
                            <Button
                              variant="ghost"
                              size="icon"
                              title="Editar"
                              aria-label={`Editar ${persona.nombreCompleto}`}
                              onClick={() => setEditando(persona)}
                            >
                              <Pencil className="size-4" />
                            </Button>
                            <Button
                              variant="ghost"
                              size="icon"
                              title="Eliminar"
                              aria-label={`Eliminar ${persona.nombreCompleto}`}
                              onClick={() => setAEliminar(persona)}
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

            {resultado.length > mostrados.length && (
              <div className="flex justify-center">
                <Button variant="outline" onClick={() => setVisibles((v) => v + POR_PAGINA)}>
                  Mostrar {Math.min(resultado.length - mostrados.length, POR_PAGINA)} más
                </Button>
              </div>
            )}

            <p className="text-center text-xs text-muted-foreground">
              Mostrando {mostrados.length} de {resultado.length} persona
              {resultado.length === 1 ? "" : "s"}
              {termino || filtroTipo !== SIN_FILTRO ? ` (${items.length} en total)` : ""}
            </p>
          </>
        )}

        <PersonaFormDialog
          open={creando || editando !== null}
          persona={editando}
          onClose={() => {
            setCreando(false);
            setEditando(null);
          }}
        />

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreCompleto}?</AlertDialogTitle>
              <AlertDialogDescription>
                {/* Se avisa que la baja es física porque acá NO hay alternativa:
                    en el resto del sistema se puede inactivar, y quien conoce esa
                    opción esperaría encontrarla. */}
                La persona se borra del padrón: esta tabla no tiene baja lógica. No se puede
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

function PersonaFormDialog({
  open,
  persona,
  onClose,
}: {
  open: boolean;
  persona: Persona | null;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = persona !== null;

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    values: {
      // Física por defecto: es el caso habitual y el mismo default del DDL.
      tipoPersona: persona?.tipoPersona ?? "F",
      // En una jurídica el backend guarda una copia de la razón social en
      // `nombre`; no se precarga acá para que el campo no aparezca "ya
      // completado" al cambiar el tipo a física.
      nombre: persona && !esJuridica(persona.tipoPersona) ? persona.nombre : "",
      apellido: persona?.apellido ?? "",
      razonSocial: persona?.razonSocial ?? "",
      numeroCi: persona?.numeroCi ?? "",
      ruc: persona?.ruc ?? "",
      email: persona?.email ?? "",
      telefono: persona?.telefono ?? "",
      direccion: persona?.direccion ?? "",
    },
  });

  // El tipo decide qué campos se muestran, así que se observa en vivo.
  const tipo = form.watch("tipoPersona");
  const juridica = tipo === "J";

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      // Los campos vacíos se omiten en vez de mandarse como "": el backend trata
      // lo ausente como "no cambiar", y un "" no lo borraría igual.
      const contacto = {
        ...(v.numeroCi ? { numeroCi: v.numeroCi } : {}),
        ...(v.ruc ? { ruc: v.ruc } : {}),
        ...(v.email ? { email: v.email } : {}),
        ...(v.telefono ? { telefono: v.telefono } : {}),
        ...(v.direccion ? { direccion: v.direccion } : {}),
      };

      // Se manda SÓLO lo que corresponde al tipo. En una jurídica el backend
      // completa `nombre` y `apellido` por su cuenta —son NOT NULL en la base—
      // y mandarlos desde acá pisaría esa lógica con los restos del formulario.
      const identidad = juridica
        ? { razonSocial: v.razonSocial }
        : { nombre: v.nombre, apellido: v.apellido };

      return esEdicion
        ? api.personas.actualizar(persona.id, {
            tipoPersona: v.tipoPersona,
            ...identidad,
            ...contacto,
          })
        : api.personas.crear({ tipoPersona: v.tipoPersona, ...identidad, ...contacto });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["personas"] });
      toast.success(esEdicion ? "Persona actualizada" : "Persona creada");
      onClose();
    },
    onError: (e) =>
      toast.error(MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear")),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="scrollbar-fino max-h-[92vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar persona" : "Nueva persona"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos de la persona."
              : "Cargá una persona al padrón. Queda disponible para todas las empresas."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            {/* EL TIPO VA PRIMERO Y CONDICIONA EL RESTO: elegirlo cambia qué
                campos aparecen abajo, así que preguntarlo después obligaría a
                volver a completar lo ya cargado. */}
            <FormField
              control={form.control}
              name="tipoPersona"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Tipo de persona</FormLabel>
                  <FormControl>
                    {/* Tabs y no un Select: son sólo dos opciones y las dos
                        importan, así que conviene verlas sin abrir nada. */}
                    <Tabs value={field.value} onValueChange={field.onChange}>
                      <TabsList className="grid w-full grid-cols-2">
                        <TabsTrigger value="F">Física</TabsTrigger>
                        <TabsTrigger value="J">Jurídica</TabsTrigger>
                      </TabsList>
                    </Tabs>
                  </FormControl>
                  <FormDescription>
                    {juridica
                      ? "Una empresa: lleva razón social y RUC."
                      : "Un individuo: lleva nombre, apellido y CI."}
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            {/* IDENTIFICACIÓN — cambia entera según el tipo.

                No se muestran los campos del otro tipo deshabilitados: un campo
                gris igual se lee como "algo que falta completar". */}
            {juridica ? (
              <FormField
                control={form.control}
                name="razonSocial"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Razón social</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        placeholder="Comercial San Miguel S.A."
                        autoComplete="off"
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
            ) : (
              <div className="grid gap-4 sm:grid-cols-2">
                <FormField
                  control={form.control}
                  name="nombre"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Nombre</FormLabel>
                      <FormControl>
                        <Input {...field} placeholder="María" autoComplete="off" />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <FormField
                  control={form.control}
                  name="apellido"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Apellido</FormLabel>
                      <FormControl>
                        <Input {...field} placeholder="González" autoComplete="off" />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
              </div>
            )}

            {/* DOCUMENTOS. Los dos son opcionales y únicos: se muestran siempre,
                porque una empresa puede tener CI de su representante y una
                persona física puede tener RUC si factura. */}
            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="numeroCi"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Número de CI</FormLabel>
                    <FormControl>
                      <Input {...field} placeholder="4123456" autoComplete="off" />
                    </FormControl>
                    <FormDescription>Opcional, pero no se puede repetir.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="ruc"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>RUC</FormLabel>
                    <FormControl>
                      <Input {...field} placeholder="80012345-6" autoComplete="off" />
                    </FormControl>
                    <FormDescription>Opcional, pero no se puede repetir.</FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            {/* CONTACTO. */}
            <div className="grid gap-4 sm:grid-cols-2">
              <FormField
                control={form.control}
                name="email"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Correo</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        type="email"
                        placeholder="contacto@ejemplo.com"
                        autoComplete="off"
                      />
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
                    <FormLabel>Teléfono</FormLabel>
                    <FormControl>
                      <Input {...field} placeholder="0981 123 456" autoComplete="off" />
                    </FormControl>
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
                    <Textarea
                      {...field}
                      rows={2}
                      placeholder="Av. España 1234, Asunción"
                      className="scrollbar-fino"
                    />
                  </FormControl>
                  <FormDescription>Opcional. Hasta 500 caracteres.</FormDescription>
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
                {guardar.isPending ? "Guardando…" : esEdicion ? "Guardar cambios" : "Crear persona"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/personas")({
  head: () => ({
    meta: [
      { title: tituloPagina("Personas") },
      {
        name: "description",
        content: "Padrón de personas físicas y jurídicas del sistema.",
      },
    ],
  }),
  component: PersonasPage,
});
