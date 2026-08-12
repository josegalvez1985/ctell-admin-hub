import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { KeyRound, Loader2, Pencil, Plus, Search, Trash2, UserCheck, UserX } from "lucide-react";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { useUsuarioActual } from "@/hooks/use-usuario-actual";
import { api, ApiError, esActivo, type Usuario } from "@/lib/api";
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

/** Reglas alineadas con las que valida PKG_USUARIOS: si acá pasa, allá también. */
const PASSWORD = z.string().min(8, "Mínimo 8 caracteres").max(128, "Máximo 128 caracteres");

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
  correo: z.union([z.string().trim().email("Correo inválido"), z.literal("")]),
  password: PASSWORD,
});

const schemaEdicion = z.object({
  nombreApellido: z.string().trim().min(1, "Obligatorio").max(200, "Máximo 200 caracteres"),
  correo: z.union([z.string().trim().email("Correo inválido"), z.literal("")]),
});

const schemaPassword = z
  .object({
    password: PASSWORD,
    repetir: z.string(),
  })
  .refine((v) => v.password === v.repetir, {
    message: "Las contraseñas no coinciden",
    path: ["repetir"],
  });

type FormAlta = z.infer<typeof schemaAlta>;
type FormEdicion = z.infer<typeof schemaEdicion>;
type FormPassword = z.infer<typeof schemaPassword>;

/** Qué panel se está mostrando dentro del diálogo. */
type Vista =
  | { tipo: "lista" }
  | { tipo: "alta" }
  | { tipo: "edicion"; usuario: Usuario }
  | { tipo: "password"; usuario: Usuario };

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
    password: {
      titulo: "Cambiar contraseña",
      descripcion: "Se cerrarán todas las sesiones abiertas de este usuario.",
    },
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
        {vista.tipo === "password" && (
          <PanelPassword usuario={vista.usuario} onVolver={() => setVista({ tipo: "lista" })} />
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
  const [busquedaAplicada, setBusquedaAplicada] = useState("");
  const [aEliminar, setAEliminar] = useState<Usuario | null>(null);

  // La búsqueda no dispara una petición por tecla: se espera a que el usuario
  // deje de escribir.
  useEffect(() => {
    const id = setTimeout(() => setBusquedaAplicada(busqueda.trim()), 350);
    return () => clearTimeout(id);
  }, [busqueda]);

  const { data, isPending, isError, error } = useQuery({
    queryKey: ["usuarios", { busqueda: busquedaAplicada }],
    // Sin `tamanio`: mandarlo hacía que la URL saliera como ?tamanio=100 sin
    // `pagina`, y en ORDS un parámetro que el cliente no manda no llega NULL
    // sino como cadena vacía. El TO_NUMBER('') del handler moría con
    // ORA-01722 y el listado respondía 500.
    //
    // Sin ningún parámetro numérico el handler aplica sus valores por defecto
    // (20 por página) y devuelve el total, que es lo que necesita el modal.
    //
    // La clave se omite en vez de mandarse como undefined: el proyecto usa
    // exactOptionalPropertyTypes, donde "ausente" y "undefined" no son lo mismo.
    queryFn: () => api.usuarios.listar(busquedaAplicada ? { busqueda: busquedaAplicada } : {}),
  });

  const invalidar = () => queryClient.invalidateQueries({ queryKey: ["usuarios"] });

  const cambiarEstado = useMutation({
    mutationFn: ({ usuario, activar }: { usuario: Usuario; activar: boolean }) =>
      activar ? api.usuarios.activar(usuario.id) : api.usuarios.inactivar(usuario.id),
    onSuccess: (_, { activar }) => {
      invalidar();
      toast.success(activar ? "Usuario activado" : "Usuario inactivado");
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo cambiar el estado")),
  });

  const eliminar = useMutation({
    mutationFn: (usuario: Usuario) => api.usuarios.eliminar(usuario.id),
    onSuccess: () => {
      invalidar();
      toast.success("Usuario eliminado");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  const usuarios = data?.items ?? [];

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
          {busquedaAplicada
            ? `Sin resultados para "${busquedaAplicada}".`
            : "Todavía no hay usuarios."}
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
                  <p className="flex items-center gap-2 truncate text-sm font-semibold text-foreground">
                    {usuario.nombreApellido}
                    {esYo && (
                      <Badge variant="outline" className="text-[10px]">
                        vos
                      </Badge>
                    )}
                  </p>
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
                    title="Cambiar contraseña"
                    aria-label={`Cambiar contraseña de ${usuario.nombreApellido}`}
                    onClick={() => onCambiarVista({ tipo: "password", usuario })}
                  >
                    <KeyRound className="size-4" />
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
              Se borra la cuenta y todas sus sesiones. Esta acción no se puede deshacer. Si solo
              querés cortarle el acceso, usá <strong>Inactivar</strong>: conserva el historial.
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
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Alta                                                                        */
/* -------------------------------------------------------------------------- */

function PanelAlta({ onVolver }: { onVolver: () => void }) {
  const queryClient = useQueryClient();

  const form = useForm<FormAlta>({
    resolver: zodResolver(schemaAlta),
    // Sin defaults React avisa por inputs no controlados.
    defaultValues: { usuario: "", nombreApellido: "", correo: "", password: "" },
  });

  const crear = useMutation({
    mutationFn: (v: FormAlta) =>
      api.usuarios.crear({
        usuario: v.usuario,
        nombreApellido: v.nombreApellido,
        password: v.password,
        // El backend valida el formato si el correo viene: mandar "" daría 400,
        // así que cuando está vacío la clave directamente no se incluye.
        ...(v.correo ? { correo: v.correo } : {}),
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["usuarios"] });
      toast.success("Usuario creado");
      onVolver();
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo crear el usuario")),
  });

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
                  placeholder="nombre.apellido"
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
              <FormLabel>Correo (opcional)</FormLabel>
              <FormControl>
                <Input {...field} type="email" placeholder="nombre@ctell.com" autoComplete="off" />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="password"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Contraseña</FormLabel>
              <FormControl>
                <Input {...field} type="password" autoComplete="new-password" />
              </FormControl>
              <FormDescription>Mínimo 8 caracteres.</FormDescription>
              <FormMessage />
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

  const form = useForm<FormEdicion>({
    resolver: zodResolver(schemaEdicion),
    defaultValues: {
      nombreApellido: usuario.nombreApellido,
      correo: usuario.correo ?? "",
    },
  });

  const actualizar = useMutation({
    mutationFn: (v: FormEdicion) =>
      api.usuarios.actualizar(usuario.id, {
        nombreApellido: v.nombreApellido,
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

/* -------------------------------------------------------------------------- */
/* Contraseña                                                                  */
/* -------------------------------------------------------------------------- */

function PanelPassword({ usuario, onVolver }: { usuario: Usuario; onVolver: () => void }) {
  const { data: yo } = useUsuarioActual();
  const esYo = usuario.id === yo?.id;

  const form = useForm<FormPassword>({
    resolver: zodResolver(schemaPassword),
    defaultValues: { password: "", repetir: "" },
  });

  const cambiar = useMutation({
    mutationFn: (v: FormPassword) => api.usuarios.cambiarPassword(usuario.id, v.password),
    onSuccess: () => {
      // El backend revoca TODAS las sesiones del usuario, incluida la propia:
      // si me la cambié a mí mismo, mi token ya no sirve y hay que reingresar.
      if (esYo) {
        toast.success("Contraseña cambiada. Volvé a iniciar sesión.");
        // Recargar lleva al login: el token local ya no vale nada.
        setTimeout(() => window.location.reload(), 1500);
        return;
      }
      toast.success("Contraseña cambiada. Se cerraron sus sesiones.");
      onVolver();
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo cambiar la contraseña")),
  });

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit((v) => cambiar.mutate(v))} className="space-y-4">
        <div className="rounded-lg bg-muted px-3 py-2 text-sm">
          <span className="text-muted-foreground">Usuario: </span>
          <span className="font-medium text-foreground">{usuario.usuario}</span>
        </div>

        {esYo && (
          <p className="rounded-lg border border-warning/30 bg-warning/10 px-3 py-2 text-sm text-foreground">
            Es tu propia cuenta: al cambiarla vas a tener que iniciar sesión de nuevo.
          </p>
        )}

        <FormField
          control={form.control}
          name="password"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Nueva contraseña</FormLabel>
              <FormControl>
                <Input {...field} type="password" autoComplete="new-password" />
              </FormControl>
              <FormDescription>Mínimo 8 caracteres.</FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="repetir"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Repetir contraseña</FormLabel>
              <FormControl>
                <Input {...field} type="password" autoComplete="new-password" />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        <DialogFooter>
          <Button type="button" variant="outline" onClick={onVolver}>
            Cancelar
          </Button>
          <Button type="submit" disabled={cambiar.isPending}>
            {cambiar.isPending && <Loader2 className="size-4 animate-spin" />}
            {cambiar.isPending ? "Guardando…" : "Cambiar contraseña"}
          </Button>
        </DialogFooter>
      </form>
    </Form>
  );
}
