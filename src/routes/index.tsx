import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { Eye, EyeOff, Loader2, Lock, User } from "lucide-react";

import loginBg from "@/assets/login-bg.jpg";
import { Logo } from "@/components/ctell/Logo";
import { api, ApiError, getCredencialesRecordadas, setCredencialesRecordadas } from "@/lib/api";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "CTELL | Acceso al sistema administrativo" },
      {
        name: "description",
        content:
          "Ingresá a CTELL para gestionar compras, ventas, stock, tesorería y recursos humanos desde un solo panel.",
      },
      { property: "og:title", content: "CTELL | Acceso al sistema administrativo" },
      {
        property: "og:description",
        content: "Panel único para compras, ventas, stock, tesorería y recursos humanos.",
      },
    ],
  }),
  component: LoginPage,
});

function LoginPage() {
  const navigate = useNavigate();
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [usuario, setUsuario] = useState("");
  const [password, setPassword] = useState("");
  const [recordar, setRecordar] = useState(false);
  const passwordRef = useRef<HTMLInputElement>(null);

  // A propósito NO se redirige al panel cuando ya hay un token guardado.
  //
  // Tenerlo no prueba que sirva: puede estar vencido, revocado o ser de una
  // sesión que el servidor ya no reconoce. Mandar al panel por su sola
  // presencia deja atrapado a quien viene justamente a iniciar sesión de
  // nuevo, y en esta pantalla eso es peor que el rebote que ahorraría.
  //
  // Si el token es válido, `/auth/me` lo confirma dentro del panel; si no lo
  // es, `useCerrarSesionAlVencer` devuelve acá.

  // localStorage no existe en el servidor: leerlo durante el render rompe la
  // hidratación. Por eso la precarga ocurre después de montar.
  useEffect(() => {
    const recordado = getCredencialesRecordadas();
    if (!recordado) return;

    setUsuario(recordado.usuario);
    setPassword(recordado.password);
    setRecordar(true);

    // Si por algún motivo quedó guardado el usuario sin la clave, el foco va
    // donde todavía falta escribir.
    if (!recordado.password) passwordRef.current?.focus();
  }, []);

  /**
   * Mensaje de error del login.
   *
   * El 401 se traduce acá y no en api.ts porque el significado depende del
   * contexto: en el resto de la app un 401 es una sesión vencida, pero en el
   * login —donde todavía no hay sesión— solo puede ser credenciales que no
   * coinciden. Decirle "tu sesión expiró" a alguien que recién intenta entrar
   * lo mandaría a buscar un problema que no existe.
   */
  function mensajeDeLogin(err: unknown): string {
    if (err instanceof ApiError) {
      return err.status === 401 ? "Usuario o contraseña incorrectos." : err.message;
    }
    // No es ApiError: la petición no llegó a completarse (sin conexión, DNS,
    // servidor caído). No hay status que traducir.
    return "No se pudo conectar con el servidor. Revisá tu conexión e intentá de nuevo.";
  }

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setLoading(true);

    try {
      await api.login(usuario, password);
      // Se guarda recién con el login exitoso: recordar credenciales que no
      // sirven solo serviría para volver a fallar igual.
      setCredencialesRecordadas(recordar ? { usuario, password } : null);
      await navigate({ to: "/home" });
      // `navigate` es asíncrono: sin el await, el botón quedaba en
      // "Verificando…" mientras la ruta todavía se estaba resolviendo, y si la
      // navegación no llegaba a completarse se quedaba así para siempre.
      setLoading(false);
    } catch (err) {
      // Si las credenciales guardadas dejaron de servir (cambio de clave,
      // cuenta inactivada), se descartan: precargarlas de nuevo repetiría el
      // error en cada intento.
      if (err instanceof ApiError && err.status === 401) {
        setCredencialesRecordadas(null);
      }

      setError(mensajeDeLogin(err));
      setLoading(false);
    }
  }

  return (
    <main className="flex min-h-screen bg-background">
      <section className="relative hidden w-[52%] overflow-hidden lg:block">
        <img
          src={loginBg}
          alt=""
          width={1280}
          height={1600}
          className="absolute inset-0 size-full object-cover"
        />
        <div className="gradient-navy absolute inset-0 opacity-80" />
        <div className="relative flex h-full flex-col justify-between p-12">
          <Logo tone="dark" />
          <div className="max-w-md">
            <h1 className="font-display text-4xl font-bold leading-tight text-navy-foreground">
              Toda la operación de tu empresa en un solo lugar.
            </h1>
            <p className="mt-4 text-sm leading-relaxed text-navy-foreground/70">
              Compras, ventas, stock, tesorería y recursos humanos integrados, con información en
              tiempo real para decidir mejor.
            </p>
            <dl className="mt-10 grid grid-cols-2 gap-4">
              {[
                ["Compras y Ventas", "Circuito comercial completo"],
                ["Stock", "Control por depósito"],
                ["Tesorería", "Caja, bancos y cheques"],
                ["RRHH", "Legajos y liquidaciones"],
              ].map(([title, detail]) => (
                <div
                  key={title}
                  className="rounded-xl border border-navy-foreground/15 bg-navy-foreground/5 p-4 backdrop-blur-sm"
                >
                  <dt className="text-sm font-semibold text-navy-foreground">{title}</dt>
                  <dd className="mt-1 text-xs text-navy-foreground/60">{detail}</dd>
                </div>
              ))}
            </dl>
          </div>
          <p className="text-xs text-navy-foreground/50">
            © {new Date().getFullYear()} CTELL S.A. Todos los derechos reservados.
          </p>
        </div>
      </section>

      <section className="flex flex-1 flex-col justify-center px-6 py-10 sm:px-12 lg:px-16">
        <div className="mx-auto w-full max-w-sm">
          <div className="lg:hidden">
            <Logo />
          </div>

          <div className="mt-10 lg:mt-0">
            <img
              src={`${import.meta.env.BASE_URL}icons/ctell-192.png`}
              alt="CTELL"
              width={64}
              height={64}
              className="mb-5 hidden size-16 rounded-2xl object-cover shadow-card lg:block"
            />
            <h2 className="font-display text-2xl font-bold text-foreground sm:text-3xl">
              Iniciar sesión
            </h2>
            <p className="mt-2 text-sm text-muted-foreground">
              Ingresá con tu usuario corporativo para acceder al panel.
            </p>
          </div>

          <form onSubmit={handleSubmit} className="mt-8 space-y-5">
            <div className="space-y-2">
              <Label htmlFor="usuario">Usuario</Label>
              <div className="relative">
                <User className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
                <Input
                  id="usuario"
                  name="usuario"
                  autoComplete="username"
                  required
                  value={usuario}
                  onChange={(e) => setUsuario(e.target.value)}
                  placeholder="usuario"
                  className="h-12 pl-9"
                />
              </div>
            </div>

            <div className="space-y-2">
              <Label htmlFor="password">Contraseña</Label>
              <div className="relative">
                <Lock className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
                <Input
                  ref={passwordRef}
                  id="password"
                  name="password"
                  type={showPassword ? "text" : "password"}
                  autoComplete="current-password"
                  required
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••"
                  className="h-12 pl-9 pr-11"
                />
                <button
                  type="button"
                  onClick={() => setShowPassword((value) => !value)}
                  aria-label={showPassword ? "Ocultar contraseña" : "Mostrar contraseña"}
                  className="absolute right-2 top-1/2 flex size-8 -translate-y-1/2 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                >
                  {showPassword ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
                </button>
              </div>
            </div>

            <div className="flex items-center justify-between">
              <Label
                htmlFor="recordar"
                title="Deja tu usuario y contraseña cargados en este dispositivo la próxima vez."
                className="gap-2 text-sm font-normal text-muted-foreground"
              >
                <Checkbox
                  id="recordar"
                  checked={recordar}
                  onCheckedChange={(valor) => {
                    const activo = valor === true;
                    setRecordar(activo);
                    // Destildar borra lo guardado en el acto. Esperar al
                    // próximo login exitoso dejaría la contraseña en disco
                    // justo cuando el usuario pidió lo contrario.
                    if (!activo) setCredencialesRecordadas(null);
                  }}
                />{" "}
                Recordarme
              </Label>
              <button
                type="button"
                className="text-sm font-medium text-primary transition-opacity hover:opacity-80"
              >
                ¿Olvidaste tu clave?
              </button>
            </div>

            {error && (
              <p
                role="alert"
                className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive"
              >
                {error}
              </p>
            )}

            <Button type="submit" disabled={loading} className="h-12 w-full text-base">
              {loading ? <Loader2 className="size-4 animate-spin" /> : null}
              {loading ? "Verificando…" : "Ingresar"}
            </Button>
          </form>

          <p className="mt-8 text-center text-xs text-muted-foreground">
            Acceso restringido a personal autorizado de CTELL.
          </p>
        </div>
      </section>
    </main>
  );
}
