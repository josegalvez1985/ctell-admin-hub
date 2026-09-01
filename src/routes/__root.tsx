import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  Outlet,
  Link,
  createRootRouteWithContext,
  useRouter,
  HeadContent,
  Scripts,
} from "@tanstack/react-router";
import { useEffect, type ReactNode } from "react";

import appCss from "../styles.css?url";
import { reportError } from "../lib/error-reporting";
import { EmpresaProvider } from "../components/ctell/empresa-provider";
import { SucursalProvider } from "../components/ctell/sucursal-provider";
import { ThemeProvider, themeInitScript } from "../components/ctell/theme-provider";
import { TooltipProvider } from "../components/ui/tooltip";
import { Toaster } from "../components/ui/sonner";
import { NOMBRE_SISTEMA } from "../lib/marca";

/** Origen público del sitio. Ver public/CNAME: el dominio se configura ahí. */
const SITIO = "https://www.ctell.online";

function NotFoundComponent() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="text-7xl font-bold text-foreground">404</h1>
        <h2 className="mt-4 text-xl font-semibold text-foreground">Page not found</h2>
        <p className="mt-2 text-sm text-muted-foreground">
          The page you're looking for doesn't exist or has been moved.
        </p>
        <div className="mt-6">
          <Link
            to="/"
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            Go home
          </Link>
        </div>
      </div>
    </div>
  );
}

function ErrorComponent({ error, reset }: { error: Error; reset: () => void }) {
  console.error(error);
  const router = useRouter();
  useEffect(() => {
    reportError(error, { boundary: "tanstack_root_error_component" });
  }, [error]);

  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="text-xl font-semibold tracking-tight text-foreground">
          This page didn't load
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">
          Something went wrong on our end. You can try refreshing or head back home.
        </p>
        <div className="mt-6 flex flex-wrap justify-center gap-2">
          <button
            onClick={() => {
              router.invalidate();
              reset();
            }}
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            Try again
          </button>
          <a
            href="/"
            className="inline-flex items-center justify-center rounded-md border border-input bg-background px-4 py-2 text-sm font-medium text-foreground transition-colors hover:bg-accent"
          >
            Go home
          </a>
        </div>
      </div>
    </div>
  );
}

export const Route = createRootRouteWithContext<{ queryClient: QueryClient }>()({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: NOMBRE_SISTEMA },
      {
        name: "description",
        content:
          "Sistema administrativo para compras, ventas, stock, tesorería y recursos humanos.",
      },
      { name: "theme-color", content: "#1362c0" },
      // El estándar actual. Es lo que hace que la PWA instalada abra sin la
      // barra del navegador.
      { name: "mobile-web-app-capable", content: "yes" },
      // La variante de Apple queda por compatibilidad: Chrome la marca como
      // obsoleta, pero Safari en iOS todavía la necesita para el modo
      // standalone. Sacarla haría que en iPhone la app instalada abriera
      // dentro del navegador.
      { name: "apple-mobile-web-app-capable", content: "yes" },
      // Nombre bajo el ícono en iOS. Corto a propósito: la pantalla de inicio
      // recorta alrededor de los 12 caracteres, y "Sistema Administrativo"
      // quedaría como "Sistema Admi…".
      { name: "apple-mobile-web-app-title", content: "Administración" },
      { name: "apple-mobile-web-app-status-bar-style", content: "black-translucent" },
      { property: "og:title", content: NOMBRE_SISTEMA },
      {
        property: "og:description",
        content: "Compras, ventas, stock, tesorería y RRHH en un solo panel.",
      },
      { property: "og:type", content: "website" },
      // og:url e og:image tienen que ser absolutas: quien las lee es un
      // servidor externo (WhatsApp, Slack, Twitter), que no tiene contra qué
      // resolver una ruta relativa.
      { property: "og:url", content: SITIO },
      { property: "og:image", content: `${SITIO}/icons/ctell-512.png` },
      { name: "twitter:card", content: "summary_large_image" },
    ],
    links: [
      {
        rel: "stylesheet",
        href: appCss,
      },
      // ctell.online (sin www) redirige acá, pero un buscador que llegue por
      // la otra forma vería dos sitios con el mismo contenido sin este canonical.
      { rel: "canonical", href: SITIO },
      { rel: "preconnect", href: "https://fonts.googleapis.com" },
      { rel: "preconnect", href: "https://fonts.gstatic.com", crossOrigin: "anonymous" },
      {
        rel: "stylesheet",
        href: "https://fonts.googleapis.com/css2?family=Sora:wght@400;600;700;800&family=Manrope:wght@400;500;600;700&display=swap",
      },
      // Los assets de public/ no pasan por el bundler, así que su ruta no se
      // reescribe sola. Hoy BASE_URL es "/" y esto es un no-op, pero si el
      // sitio volviera a servirse desde un subdirectorio, sin el prefijo
      // apuntarían a la raíz del dominio y darían 404.
      { rel: "manifest", href: `${import.meta.env.BASE_URL}manifest.webmanifest` },
      { rel: "icon", type: "image/png", href: `${import.meta.env.BASE_URL}favicon.png` },
      {
        rel: "apple-touch-icon",
        sizes: "180x180",
        href: `${import.meta.env.BASE_URL}icons/apple-touch-icon.png`,
      },
    ],
  }),

  shellComponent: RootShell,
  component: RootComponent,
  notFoundComponent: NotFoundComponent,
  errorComponent: ErrorComponent,
});

function RootShell({ children }: { children: ReactNode }) {
  return (
    <html lang="es" suppressHydrationWarning>
      <head>
        <HeadContent />
        {/* Aplica el tema guardado antes del primer paint para evitar el flash de modo claro. */}
        <script dangerouslySetInnerHTML={{ __html: themeInitScript }} />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}

function RootComponent() {
  const { queryClient } = Route.useRouteContext();

  // Registra el service worker de public/sw.js. Su única función es habilitar
  // la instalación de la PWA: Chrome no ofrece instalar un sitio que no tenga
  // uno con handler de fetch. No cachea nada — ver el comentario del archivo.
  //
  // En dev no se registra: el SW quedaría activo entre recargas y confunde el
  // HMR de Vite sin aportar nada, porque instalar se prueba sobre el build.
  useEffect(() => {
    if (import.meta.env.DEV) return;
    if (!("serviceWorker" in navigator)) return;

    // BASE_URL y no "/sw.js": el scope de un SW no puede ser más amplio que su
    // propia ruta, así que un path fijo rompería si el sitio se sirviera desde
    // un subdirectorio.
    const url = `${import.meta.env.BASE_URL}sw.js`;
    navigator.serviceWorker.register(url, { scope: import.meta.env.BASE_URL }).catch(() => {
      // Un fallo acá sólo significa que no se va a poder instalar la app. La
      // web sigue funcionando igual, así que no se molesta al usuario con esto.
    });
  }, []);

  return (
    <QueryClientProvider client={queryClient}>
      <ThemeProvider>
        {/* Envuelve todo, no solo las rutas con sesión: la empresa se elige en
            el login, que está fuera de _auth. */}
        <EmpresaProvider>
          {/* Adentro de EmpresaProvider, no al lado: la sucursal se lista por
              empresa, así que necesita leer la empresa activa. */}
          <SucursalProvider>
            {/* Radix exige un Provider por encima de CADA <Tooltip>, y va acá y
                no en AppLayout: AppLayout no usa el <Sidebar> de shadcn —que
                trae el suyo adentro—, así que las páginas quedaban sin ninguno
                y el primer tooltip reventaba con "must be used within
                TooltipProvider". Global, cualquier página futura ya lo tiene. */}
            <TooltipProvider delayDuration={200}>
              {/* Required: nested routes render here. Removing <Outlet /> breaks all child routes. */}
              <Outlet />
              {/* Sin esto los toast() de las mutaciones no se renderizan en ningún lado. */}
              <Toaster richColors position="top-right" />
            </TooltipProvider>
          </SucursalProvider>
        </EmpresaProvider>
      </ThemeProvider>
    </QueryClientProvider>
  );
}
