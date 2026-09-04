import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { KeyRound, Loader2, Pencil, Plus, Search, Trash2, UserCheck, UserX } from "lucide-react";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { useUsuarioActual } from "@/hooks/use-usuario-actual";
import { api, ApiError, esActivo, esAdmin, type Usuario } from "@/lib/api";
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

const schemaAlta = z.object({
  usuario: z
    .string()
    .trim()
    .min(3, "Mínimo 3 caracteres")
    .max(50, "Máximo 50 caracteres")
    // El backend lo guarda en minúsculas: mostrarlo así evita la sorpresa de
    // crear "Jose" y que la lista muestre "jose".
    .regex(/^[a-z0-9._-]+$/, "Solo minúsculas, números, punto, guion y guion bajo"),
  nombreApellido: z.string().trim().min(1, "Obligatorio").max(200, "Máximo 200 caracteres"),
  // Obligatorio en el alta: es a donde va la contraseña inicial. En edición
  // sigue siendo opcional (ver schemaEdicion) — ahí no hay clave que mandar.
  correo: z
    .string()
    .trim()
    .min(1, "Obligatorio: ahí se envía la contraseña")
    .email("Correo inválido"),
  // No hay campo de contraseña: la genera el backend y la manda por correo.
  // Booleano en el formulario porque un switch lo es; se traduce a "S"/"N" al
  // enviarlo. La traducción vive sólo acá, en el borde con el control de UI.
  esAdmin: z.boolean(),
});

const schemaEdicion = z.object({
  nombreApellido: z.string().trim().min(1, "Obligatorio").max(200, "Máximo 200 caracteres"),
  correo: z.union([z.string().trim().email("Correo inválido"), z.literal("")]),
  esAdmin: z.boolean(),
});

type FormAlta = z.infer<typeof schemaAlta>;
type FormEdicion = z.infer<typeof schemaEdicion>;

/** Qué panel se está mostrando dentro del diálogo. */
type Vista = { tipo: "lista" } | { tipo: "alta" } | { tipo: "edicion"; usuario: Usuario };

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

export function UsuariosDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const [vista, setVista] = useState<Vista>({ tipo: "lista" });

  // Cada apertura empieza en la lista: reabrir y caer en el formulario que
  // quedó a medias la vez anterior sería desconcertante.
  useEffect(() => {
    if (open) setVista({ tipo: "lista" });
  }, [open]);

  const titulos: Record<Vista["tipo"], { titulo: string; descripcion: string }> = {
    lista: {
      titulo: "Usuarios",
      descripcion: "Altas, modificaciones y bajas de las cuentas del sistema.",
    },
    alta: { titulo: "Nuevo usuario", descripcion: "Creá una cuenta para acceder al sistema." },
    edicion: { titulo: "Editar usuario", descripcion: "Modificá los datos de la cuenta." },
  };

  const { titulo, descripcion } = titulos[vista.tipo];

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85vh] max-w-3xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{titulo}</DialogTitle>
          <DialogDescription>{descripcion}</DialogDescription>
        </DialogHeader>

        {vista.tipo === "lista" && <PanelLista onCambiarVista={setVista} />}
        {vista.tipo === "alta" && <PanelAlta onVolver={() => setVista({ tipo: "lista" })} />}
        {vista.tipo === "edicion" && (
          <PanelEdicion usuario={vista.usuario} onVolver={() => setVista({ tipo: "lista" })} />
        )}
      </DialogContent>
    </Dialog>
  );
}

/* -------------------------------------------------------------------------- */
/* Lista                                                                       */
/* -------------------------------------------------------------------------- */

function PanelLista({ onCambiarVista }: { onCambiarVista: (v: Vista) => void }) {
  const queryClient = useQueryClient();
  const { data: yo } = useUsuarioActual();
  const [busqueda, setBusqueda] = useState("");
  const [aEliminar, setAEliminar] = useState<Usuario | null>(null);
  const [aResetear, setAResetear] = useState<Usuario | null>(null);

  const { data, isPending, isError, error } = useQuery({
    queryKey: ["usuarios"],
    queryFn: () => api.usuarios.listar(),
  });

  const invalidar = () => queryClient.invalidateQueries({ queryKey: ["usuarios"] });

  // Activar/inactivar no tienen endpoint propio: van por PUT con `activo`.
  // El backend revoca las sesiones abiertas al dejar la cuenta inactiva.
  const cambiarEstado = useMutation({
    mutationFn: ({ usuario, activar }: { usuario: Usuario; activar: boolean }) =>
      api.usuarios.actualizar(usuario.id, { activo: activar ? "A" : "I" }),
    onSuccess: (_, { activar }) => {
      invalidar();
      toast.success(activar ? "Usuario activado" : "Usuario inactivado");
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo cambiar el estado")),
  });

  /**
   * Manda una contraseña provisoria al correo del usuario.
   *
   * **Reusa el endpoint del login** (`/auth/recuperar`), que es el mismo que
   * usa "olvidé mi contraseña": genera la clave, la guarda hasheada, **revoca
   * todas las sesiones abiertas** de esa cuenta y manda el correo. No hay un
   * endpoint administrativo aparte, así que acá no se inventa uno.
   *
   * Eso trae una limitación que hay que conocer y que el texto de la pantalla
   * respeta: el endpoint **siempre responde 200 con el mismo mensaje**, coincida
   * o no el par usuario/correo y salga o no el correo. Es deliberado —así no
   * sirve para enumerar cuentas ni direcciones—, pero significa que **un `ok`
   * acá no prueba que el mail llegó**. Por eso el toast dice "se envió a esa
   * dirección" y no "listo, ya lo recibió", y por eso el botón se deshabilita
   * antes en los casos que sabemos que no van a funcionar.
   *
   * `usuario` y `correo` salen de la fila: el admin no los tipea, así que no
   * puede equivocarse y resetear la cuenta de otro.
   */
  const resetearPassword = useMutation({
    mutationFn: (usuario: Usuario) =>
      api.recuperarPassword({
        usuario: usuario.usuario.toLowerCase(),
        // El botón está deshabilitado sin correo; el `?? ""` es sólo para el
        // tipo, no un caso que se pueda alcanzar desde la pantalla.
        correo: usuario.correo ?? "",
      }),
    onSuccess: (_, usuario) => {
      toast.success(`Se envió una contraseña provisoria a ${usuario.correo}`, {
        description:
          "Sus sesiones abiertas se cerraron. Al entrar con esa clave, puede cambiarla desde Configuración.",
      });
      setAResetear(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo enviar la contraseña"));
      setAResetear(null);
    },
  });

  const eliminar = useMutation({
    mutationFn: (usuario: Usuario) => api.usuarios.eliminar(usuario.id),
    onSuccess: () => {
      invalidar();
      // Sus permisos se fueron con él: sin esto, el diálogo de Permisos sigue
      // contando páginas de un usuario que ya no existe —y el listado de
      // Páginas seguiría creyendo que están en uso—.
      queryClient.invalidateQueries({ queryKey: ["usuario-paginas"] });
      toast.success("Usuario eliminado");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  // El backend devuelve la lista completa: el filtro se aplica acá. Son pocas
  // cuentas, así que no justifica un ida y vuelta por cada tecla.
  const termino = busqueda.trim().toLowerCase();
  const usuarios = (data?.items ?? []).filter(
    (u) =>
      termino === "" ||
      u.usuario.toLowerCase().includes(termino) ||
      u.nombreApellido.toLowerCase().includes(termino) ||
      (u.correo ?? "").toLowerCase().includes(termino),
  );

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <div className="relative min-w-48 flex-1">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por usuario, nombre o correo…"
            className="pl-9"
          />
        </div>
        <Button onClick={() => onCambiarVista({ tipo: "alta" })}>
          <Plus className="size-4" />
          Nuevo
        </Button>
      </div>

      {isPending && (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <Skeleton key={i} className="h-16 w-full" />
          ))}
        </div>
      )}

      {isError && (
        <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
          {MENSAJE_ERROR(error, "No se pudo cargar la lista")}
        </p>
      )}

      {!isPending && !isError && usuarios.length === 0 && (
        <p className="px-3 py-10 text-center text-sm text-muted-foreground">
          {termino ? `Sin resultados para "${busqueda.trim()}".` : "Todavía no hay usuarios."}
        </p>
      )}

      {usuarios.length > 0 && (
        <ul className="divide-y divide-border rounded-lg border border-border">
          {usuarios.map((usuario) => {
            const activo = esActivo(usuario.activo);
            // El backend rechaza estas dos acciones sobre uno mismo (400); se
            // deshabilitan acá para no ofrecer algo que va a fallar.
            const esYo = usuario.id === yo?.id;

            return (
              <li
                key={usuario.id}
                className="flex flex-wrap items-center justify-between gap-3 px-3 py-3"
              >
                <div className="min-w-0 flex-1">
                  {/* div y no p: Badge renderiza un <div>, y el HTML no
                      permite anidarlo dentro de un <p> — React lo reporta
                      como error de hidratación. */}
                  <div className="flex items-center gap-2 truncate text-sm font-semibold text-foreground">
                    {usuario.nombreApellido}
                    {esYo && (
                      <Badge variant="outline" className="text-[10px]">
                        vos
                      </Badge>
                    )}
                    {esAdmin(usuario.esAdmin) && (
                      <Badge variant="outline" className="text-[10px]">
                        admin
                      </Badge>
                    )}
                  </div>
                  <p className="truncate text-xs text-muted-foreground">
                    {usuario.usuario}
                    {usuario.correo ? ` · ${usuario.correo}` : ""}
                  </p>
                </div>

                <Badge variant={activo ? "secondary" : "outline"} className="shrink-0">
                  {activo ? "Activo" : "Inactivo"}
                </Badge>

                <div className="flex shrink-0 gap-1">
                  <Button
                    variant="ghost"
                    size="icon"
                    title="Editar"
                    aria-label={`Editar ${usuario.nombreApellido}`}
                    onClick={() => onCambiarVista({ tipo: "edicion", usuario })}
                  >
                    <Pencil className="size-4" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    title={
                      esYo
                        ? "No podés inactivar tu propia cuenta"
                        : activo
                          ? "Inactivar"
                          : "Activar"
                    }
                    aria-label={activo ? "Inactivar" : "Activar"}
                    disabled={esYo || cambiarEstado.isPending}
                    onClick={() => cambiarEstado.mutate({ usuario, activar: !activo })}
                  >
                    {activo ? (
                      <UserX className="size-4" />
                    ) : (
                      <UserCheck className="size-4 text-success" />
                    )}
                  </Button>
                  {/* Mandar la clave provisoria. Deshabilitado —con el motivo
                      en el tooltip— en los dos casos que no pueden salir bien:

                      · SIN CORREO no hay a dónde mandarla, y el endpoint igual
                        resetearía la contraseña vigente. El usuario quedaría
                        afuera sin enterarse y sin forma de volver a entrar.
                      · INACTIVO: `RECUPERAR_PASSWORD` exige la cuenta activa,
                        así que no hace nada y responde el mismo 200 de siempre.
                        Reactivarla es el paso previo, no este botón.

                      Sobre uno mismo SÍ se permite: cerrarse las sesiones y
                      recibir una clave nueva por correo es una operación
                      válida, no un tiro en el pie como eliminarse. */}
                  <Button
                    variant="ghost"
                    size="icon"
                    title={
                      !usuario.correo
                        ? "No tiene correo cargado: editalo primero"
                        : !activo
                          ? "La cuenta está inactiva: activala primero"
                          : "Enviar una contraseña provisoria por correo"
                    }
                    aria-label={`Enviar una contraseña provisoria a ${usuario.nombreApellido}`}
                    disabled={!usuario.correo || !activo || resetearPassword.isPending}
                    onClick={() => setAResetear(usuario)}
                  >
                    <KeyRound className="size-4" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    title={esYo ? "No podés eliminar tu propia cuenta" : "Eliminar"}
                    aria-label={`Eliminar ${usuario.nombreApellido}`}
                    disabled={esYo}
                    onClick={() => setAEliminar(usuario)}
                  >
                    <Trash2 className="size-4 text-destructive" />
                  </Button>
                </div>
              </li>
            );
          })}
        </ul>
      )}

      {data && usuarios.length > 0 && (
        <p className="text-xs text-muted-foreground">
          {usuarios.length} de {data.total} usuario{data.total === 1 ? "" : "s"}
        </p>
      )}

      {/* Eliminar borra el rastro y no se puede deshacer: se confirma aparte. */}
      <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar a {aEliminar?.nombreApellido}?</AlertDialogTitle>
            <AlertDialogDescription>
              Se borra la cuenta con sus sesiones y sus permisos. Esta acción no se puede deshacer.
              Si el usuario ya cargó ventas, compras o inventarios <strong>no</strong> se va a poder
              borrar: ahí, y si sólo querés cortarle el acceso, usá <strong>Inactivar</strong>, que
              conserva el historial.
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

      {/* Confirmación y no un clic directo: esto INVALIDA la contraseña vigente
          y cierra las sesiones abiertas. Tocado por error sobre la fila
          equivocada, deja a alguien afuera en medio de su trabajo — y no hay
          forma de deshacerlo, sólo de volver a mandar otra clave. */}
      <AlertDialog open={aResetear !== null} onOpenChange={(o) => !o && setAResetear(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle className="break-words">
              ¿Enviar una contraseña nueva a {aResetear?.nombreApellido}?
            </AlertDialogTitle>
            <AlertDialogDescription>
              Se genera una contraseña provisoria y se manda a{" "}
              <strong className="break-all">{aResetear?.correo}</strong>. La contraseña actual deja
              de servir en el momento y se cierran sus sesiones abiertas, así que va a tener que
              entrar con la que reciba. Después puede cambiarla desde Configuración.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              onClick={(e) => {
                // Sin esto el AlertDialog se cierra antes de que la mutación
                // termine y el error nunca se llega a mostrar.
                e.preventDefault();
                if (aResetear) resetearPassword.mutate(aResetear);
              }}
              disabled={resetearPassword.isPending}
            >
              {resetearPassword.isPending && <Loader2 className="size-4 animate-spin" />}
              {resetearPassword.isPending ? "Enviando…" : "Enviar contraseña"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Alta                                                                        */
/* -------------------------------------------------------------------------- */

function PanelAlta({ onVolver }: { onVolver: () => void }) {
  const queryClient = useQueryClient();

  // Sólo se llena si el correo no salió: es el respaldo para que la cuenta no
  // quede con una clave que nadie conoce. Mientras haya algo acá el panel
  // muestra la clave en vez de volver a la lista.
  const [respaldo, setRespaldo] = useState<{ correo: string; password?: string } | null>(null);

  const form = useForm<FormAlta>({
    resolver: zodResolver(schemaAlta),
    // Sin defaults React avisa por inputs no controlados.
    defaultValues: {
      usuario: "",
      nombreApellido: "",
      correo: "",
      // El default seguro es no ser administrador.
      esAdmin: false,
    },
  });

  const crear = useMutation({
    mutationFn: (v: FormAlta) =>
      api.usuarios.crear({
        usuario: v.usuario,
        nombreApellido: v.nombreApellido,
        correo: v.correo,
        esAdmin: v.esAdmin ? "S" : "N",
      }),
    onSuccess: (data, v) => {
      queryClient.invalidateQueries({ queryKey: ["usuarios"] });

      if (data.correoEnviado) {
        toast.success(`Usuario creado. La contraseña se envió a ${v.correo}`);
        onVolver();
        return;
      }

      // El usuario existe pero el correo no salió: no se vuelve a la lista sin
      // mostrar cómo entrar, o la cuenta queda inaccesible.
      toast.warning("Usuario creado, pero el correo no se pudo enviar");
      setRespaldo({
        correo: v.correo,
        ...(data.passwordInicial ? { password: data.passwordInicial } : {}),
      });
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo crear el usuario")),
  });

  if (respaldo) {
    return (
      <div className="space-y-4">
        <div className="rounded-lg border border-warning/30 bg-warning/10 px-4 py-3">
          <p className="text-sm font-semibold text-foreground">
            La cuenta se creó, pero el correo no salió
          </p>
          <p className="mt-1 text-sm text-muted-foreground">
            No se pudo enviar el mensaje a <strong>{respaldo.correo}</strong>.{" "}
            {respaldo.password
              ? "Pasale estos datos por otro medio: no se vuelven a mostrar."
              : "Pedile que use “Olvidé mi contraseña” desde el login para recibir una nueva."}
          </p>
        </div>

        {respaldo.password && (
          <div className="space-y-1 rounded-lg bg-muted px-3 py-3">
            <p className="text-xs text-muted-foreground">Contraseña inicial</p>
            <p className="select-all break-all font-mono text-base font-semibold text-foreground">
              {respaldo.password}
            </p>
          </div>
        )}

        <DialogFooter>
          <Button onClick={onVolver}>Entendido</Button>
        </DialogFooter>
      </div>
    );
  }

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit((v) => crear.mutate(v))} className="space-y-4">
        <FormField
          control={form.control}
          name="usuario"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Usuario</FormLabel>
              <FormControl>
                {/* Se normaliza al tipear para que coincida con lo que guarda
                    el backend, que hace LOWER(TRIM(...)). */}
                <Input
                  {...field}
                  onChange={(e) => field.onChange(e.target.value.toLowerCase().trim())}
                  placeholder="joseg"
                  autoComplete="off"
                />
              </FormControl>
              <FormDescription>
                Con esto inicia sesión. No se puede cambiar después.
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="nombreApellido"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Nombre y apellido</FormLabel>
              <FormControl>
                <Input {...field} placeholder="Jose Galvez" autoComplete="off" />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="correo"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Correo</FormLabel>
              <FormControl>
                <Input {...field} type="email" placeholder="joseg@ctell.com" autoComplete="off" />
              </FormControl>
              <FormDescription>
                Obligatorio: el sistema genera la contraseña y la envía a esta dirección.
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="esAdmin"
          render={({ field }) => (
            <FormItem className="flex items-center justify-between gap-4 rounded-lg border border-border px-3 py-3">
              <div className="space-y-0.5">
                <FormLabel>Es administrador</FormLabel>
                <FormDescription>Puede gestionar las cuentas del sistema.</FormDescription>
              </div>
              <FormControl>
                {/* Switch no es un input nativo: usa checked/onCheckedChange en
                    vez del {...field} que sirve para los Input de texto. */}
                <Switch checked={field.value} onCheckedChange={field.onChange} />
              </FormControl>
            </FormItem>
          )}
        />

        <DialogFooter>
          <Button type="button" variant="outline" onClick={onVolver}>
            Cancelar
          </Button>
          <Button type="submit" disabled={crear.isPending}>
            {crear.isPending && <Loader2 className="size-4 animate-spin" />}
            {crear.isPending ? "Creando…" : "Crear usuario"}
          </Button>
        </DialogFooter>
      </form>
    </Form>
  );
}

/* -------------------------------------------------------------------------- */
/* Edición                                                                     */
/* -------------------------------------------------------------------------- */

function PanelEdicion({ usuario, onVolver }: { usuario: Usuario; onVolver: () => void }) {
  const queryClient = useQueryClient();
  const { data: yo } = useUsuarioActual();

  // Quitarse a uno mismo el rol de administrador es un camino sin vuelta: al
  // guardar se pierde el acceso a esta pantalla, que es justamente donde se
  // repondría. El backend lo permite —no es un caso que deba bloquear—, así
  // que se evita acá, donde se puede explicar el motivo.
  const esYo = usuario.id === yo?.id;

  const form = useForm<FormEdicion>({
    resolver: zodResolver(schemaEdicion),
    defaultValues: {
      nombreApellido: usuario.nombreApellido,
      correo: usuario.correo ?? "",
      esAdmin: esAdmin(usuario.esAdmin),
    },
  });

  const actualizar = useMutation({
    mutationFn: (v: FormEdicion) =>
      api.usuarios.actualizar(usuario.id, {
        nombreApellido: v.nombreApellido,
        esAdmin: v.esAdmin ? "S" : "N",
        // Vaciar el campo no borra el correo: ACTUALIZAR_USUARIO usa NVL, con
        // lo que un NULL conserva el valor anterior. Se omite la clave para
        // ser explícitos sobre eso en vez de simular un borrado que no ocurre.
        ...(v.correo ? { correo: v.correo } : {}),
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["usuarios"] });
      // Si me edité a mí mismo, el nombre del panel quedaría desactualizado.
      queryClient.invalidateQueries({ queryKey: ["usuario-actual"] });
      toast.success("Usuario actualizado");
      onVolver();
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo actualizar")),
  });

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit((v) => actualizar.mutate(v))} className="space-y-4">
        <div className="rounded-lg bg-muted px-3 py-2 text-sm">
          <span className="text-muted-foreground">Usuario: </span>
          <span className="font-medium text-foreground">{usuario.usuario}</span>
        </div>

        <FormField
          control={form.control}
          name="nombreApellido"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Nombre y apellido</FormLabel>
              <FormControl>
                <Input {...field} autoComplete="off" />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="correo"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Correo (opcional)</FormLabel>
              <FormControl>
                <Input {...field} type="email" autoComplete="off" />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="esAdmin"
          render={({ field }) => (
            <FormItem className="flex items-center justify-between gap-4 rounded-lg border border-border px-3 py-3">
              <div className="space-y-0.5">
                <FormLabel>Es administrador</FormLabel>
                <FormDescription>
                  {esYo
                    ? "No podés cambiar tu propio rol: perderías el acceso a esta pantalla."
                    : "Puede gestionar las cuentas del sistema."}
                </FormDescription>
              </div>
              <FormControl>
                <Switch checked={field.value} onCheckedChange={field.onChange} disabled={esYo} />
              </FormControl>
            </FormItem>
          )}
        />

        <DialogFooter>
          <Button type="button" variant="outline" onClick={onVolver}>
            Cancelar
          </Button>
          <Button type="submit" disabled={actualizar.isPending}>
            {actualizar.isPending && <Loader2 className="size-4 animate-spin" />}
            {actualizar.isPending ? "Guardando…" : "Guardar cambios"}
          </Button>
        </DialogFooter>
      </form>
    </Form>
  );
}
