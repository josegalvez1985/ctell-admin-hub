import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation } from "@tanstack/react-query";
import { CheckCircle2, Loader2 } from "lucide-react";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
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

const schema = z.object({
  usuario: z
    .string()
    .trim()
    .min(1, "Obligatorio")
    // Igual que en el login: el backend guarda y busca en minúscula.
    .max(50, "Máximo 50 caracteres"),
  correo: z.string().trim().min(1, "Obligatorio").email("Correo inválido"),
});

type FormValues = z.infer<typeof schema>;

/**
 * "Olvidé mi contraseña": pide usuario + correo y manda una clave provisoria.
 *
 * El backend responde lo mismo coincidan o no los datos, así que esta pantalla
 * **nunca dice si la cuenta existe**. Confirmarlo convertiría el modal en un
 * verificador de usuarios y de sus direcciones. Por eso el estado final es un
 * mensaje neutro y no un "listo, te lo mandamos".
 */
export function RecuperarPasswordDialog({
  open,
  onOpenChange,
  /** Se precarga con lo que ya haya tipeado en el login: un campo menos. */
  usuarioInicial = "",
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  usuarioInicial?: string;
}) {
  const [enviado, setEnviado] = useState(false);

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { usuario: usuarioInicial, correo: "" },
  });

  // Cada apertura arranca limpia: reabrir y encontrar la confirmación de la vez
  // anterior haría creer que el correo se mandó de nuevo.
  useEffect(() => {
    if (open) {
      setEnviado(false);
      form.reset({ usuario: usuarioInicial, correo: "" });
    }
  }, [open, usuarioInicial, form]);

  const recuperar = useMutation({
    mutationFn: (v: FormValues) =>
      api.recuperarPassword({ usuario: v.usuario.toLowerCase(), correo: v.correo }),
    onSuccess: () => setEnviado(true),
    // Un error acá es de red o del servidor: el "no coincide" no llega como
    // error, llega como el mismo 200 de siempre.
    onError: (e) =>
      form.setError("root", {
        message:
          e instanceof ApiError ? e.message : "No se pudo procesar el pedido. Probá de nuevo.",
      }),
  });

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{enviado ? "Revisá tu correo" : "Recuperar contraseña"}</DialogTitle>
          <DialogDescription>
            {enviado
              ? "Si los datos son correctos, vas a recibir una contraseña provisoria."
              : "Indicá tu usuario y el correo de tu cuenta. Te enviamos una contraseña provisoria para volver a entrar."}
          </DialogDescription>
        </DialogHeader>

        {enviado ? (
          <div className="space-y-4">
            <div className="flex gap-3 rounded-lg border border-border bg-muted px-4 py-3">
              <CheckCircle2 className="mt-0.5 size-5 shrink-0 text-success" />
              <div className="space-y-1 text-sm">
                <p className="text-foreground">
                  Si el usuario y el correo corresponden a una cuenta activa, el mensaje ya está en
                  camino.
                </p>
                <p className="text-muted-foreground">
                  Puede tardar unos minutos. Revisá también la carpeta de correo no deseado.
                </p>
              </div>
            </div>

            {/* Al entrar con la provisoria, la anterior ya no sirve: conviene
                decirlo acá y no sólo en el correo. */}
            <p className="text-xs text-muted-foreground">
              Tu contraseña anterior dejó de funcionar. Cuando entres, cambiala desde Configuración.
            </p>

            <DialogFooter>
              <Button onClick={() => onOpenChange(false)}>Volver al inicio</Button>
            </DialogFooter>
          </div>
        ) : (
          <Form {...form}>
            <form onSubmit={form.handleSubmit((v) => recuperar.mutate(v))} className="space-y-4">
              <FormField
                control={form.control}
                name="usuario"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Usuario</FormLabel>
                    <FormControl>
                      <Input
                        {...field}
                        onChange={(e) => field.onChange(e.target.value.toLowerCase().trim())}
                        placeholder="joseg"
                        // El usuario NO es el correo. Con autoComplete="username"
                        // el navegador ofrece acá la dirección guardada (y el
                        // usuario en el campo de correo), porque trata a ambos
                        // como la misma identidad. "off" corta ese cruce.
                        autoComplete="off"
                        autoCorrect="off"
                        autoCapitalize="none"
                        spellCheck={false}
                      />
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
                      <Input
                        {...field}
                        type="email"
                        placeholder="joseg@ctell.com"
                        // Ídem el campo de usuario: sin esto el navegador
                        // autocompleta con el nombre de usuario guardado.
                        autoComplete="off"
                        autoCorrect="off"
                        autoCapitalize="none"
                        spellCheck={false}
                      />
                    </FormControl>
                    <FormDescription>
                      Tiene que ser el correo registrado en tu cuenta.
                    </FormDescription>
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
                <Button type="submit" disabled={recuperar.isPending}>
                  {recuperar.isPending && <Loader2 className="size-4 animate-spin" />}
                  {recuperar.isPending ? "Enviando…" : "Enviar contraseña"}
                </Button>
              </DialogFooter>
            </form>
          </Form>
        )}
      </DialogContent>
    </Dialog>
  );
}
