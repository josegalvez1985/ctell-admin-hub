import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { Loader2 } from "lucide-react";
import { useEffect } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { api, ApiError } from "@/lib/api";
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

const schema = z
  .object({
    passwordActual: z.string().min(1, "Obligatorio"),
    // Mismas reglas que valida PKG_AUTH: si acá pasa, allá también.
    passwordNueva: z.string().min(8, "Mínimo 8 caracteres").max(128, "Máximo 128 caracteres"),
    confirmacion: z.string().min(1, "Obligatorio"),
  })
  // La confirmación es sólo del formulario: el backend no la recibe. Existe
  // porque un error de tipeo en una clave que no se ve dejaría al usuario
  // afuera, y sin sesión para arreglarlo.
  .refine((v) => v.passwordNueva === v.confirmacion, {
    message: "Las contraseñas no coinciden",
    path: ["confirmacion"],
  })
  .refine((v) => v.passwordNueva !== v.passwordActual, {
    message: "La nueva tiene que ser distinta de la actual",
    path: ["passwordNueva"],
  });

type FormValues = z.infer<typeof schema>;

/**
 * Cambio de contraseña del usuario logueado.
 *
 * **Un cambio exitoso cierra la sesión**: el backend revoca todos los tokens,
 * incluido el de esta pestaña. Es deliberado —si se cambia por sospecha de
 * robo, dejar viva cualquier sesión anterior anularía el motivo— así que al
 * terminar se vuelve al login.
 */
export function CambiarPasswordDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const navigate = useNavigate();

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { passwordActual: "", passwordNueva: "", confirmacion: "" },
  });

  // Reabrir no debe mostrar lo tipeado la vez anterior: son credenciales.
  useEffect(() => {
    if (open) form.reset({ passwordActual: "", passwordNueva: "", confirmacion: "" });
  }, [open, form]);

  const cambiar = useMutation({
    mutationFn: (v: FormValues) =>
      api.cambiarPassword({
        passwordActual: v.passwordActual,
        passwordNueva: v.passwordNueva,
      }),
    onSuccess: () => {
      // `api.cambiarPassword` ya limpió token, usuario y empresa: el token con
      // el que se llamó quedó revocado en el servidor.
      toast.success("Contraseña cambiada. Volvé a entrar con la nueva.");
      onOpenChange(false);
      navigate({ to: "/" });
    },
    onError: (e) =>
      form.setError("root", {
        message:
          e instanceof ApiError ? e.message : "No se pudo cambiar la contraseña. Probá de nuevo.",
      }),
  });

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Cambiar contraseña</DialogTitle>
          <DialogDescription>
            Al cambiarla se cierran todas tus sesiones, incluida esta: vas a tener que entrar de
            nuevo.
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => cambiar.mutate(v))} className="space-y-4">
            <FormField
              control={form.control}
              name="passwordActual"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Contraseña actual</FormLabel>
                  <FormControl>
                    <Input {...field} type="password" autoComplete="current-password" />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="passwordNueva"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Contraseña nueva</FormLabel>
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
              name="confirmacion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Repetir la nueva</FormLabel>
                  <FormControl>
                    <Input {...field} type="password" autoComplete="new-password" />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            {form.formState.errors.root && (
              <p
                role="alert"
                className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive"
              >
                {form.formState.errors.root.message}
              </p>
            )}

            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
                Cancelar
              </Button>
              <Button type="submit" disabled={cambiar.isPending}>
                {cambiar.isPending && <Loader2 className="size-4 animate-spin" />}
                {cambiar.isPending ? "Cambiando…" : "Cambiar contraseña"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}
