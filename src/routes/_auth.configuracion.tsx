import { createFileRoute } from "@tanstack/react-router";
import {
  Check,
  FileText,
  KeyRound,
  LayoutGrid,
  Monitor,
  Moon,
  ShieldCheck,
  Sun,
  Users,
} from "lucide-react";
import { useState } from "react";

import { AppLayout } from "@/components/ctell/AppLayout";
import { CambiarPasswordDialog } from "@/components/ctell/CambiarPasswordDialog";
import { COLOR_THEMES } from "@/components/ctell/color-themes";
import { ModulosDialog } from "@/components/ctell/ModulosDialog";
import { PaginasDialog } from "@/components/ctell/PaginasDialog";
import { PermisosDialog } from "@/components/ctell/PermisosDialog";
import { useTheme, type Theme } from "@/components/ctell/theme-provider";
import { UsuariosDialog } from "@/components/ctell/UsuariosDialog";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export const Route = createFileRoute("/_auth/configuracion")({
  head: () => ({
    meta: [
      { title: "Configuración | CTELL" },
      {
        name: "description",
        content: "Preferencias de la cuenta y apariencia del sistema CTELL.",
      },
    ],
  }),
  component: ConfiguracionPage,
});

const themeOptions: { value: Theme; label: string; description: string; icon: typeof Sun }[] = [
  { value: "light", label: "Claro", description: "Fondo claro, ideal con buena luz.", icon: Sun },
  {
    value: "dark",
    label: "Oscuro",
    description: "Reduce el brillo en ambientes tenues.",
    icon: Moon,
  },
  {
    value: "system",
    label: "Sistema",
    description: "Sigue la preferencia de tu dispositivo.",
    icon: Monitor,
  },
];

function ConfiguracionPage() {
  const { theme, setTheme, colorTheme, setColorTheme } = useTheme();
  const [usuariosAbierto, setUsuariosAbierto] = useState(false);
  const [modulosAbierto, setModulosAbierto] = useState(false);
  const [paginasAbierto, setPaginasAbierto] = useState(false);
  const [permisosAbierto, setPermisosAbierto] = useState(false);
  const [passwordAbierto, setPasswordAbierto] = useState(false);

  return (
    <AppLayout active="Configuración" title="Configuración" showSearch={false}>
      <main className="mx-auto max-w-3xl space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div>
          <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Configuración</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Preferencias de tu cuenta y del sistema.
          </p>
        </div>

        {/* Va antes de Administración a propósito: esto lo usa cualquier
            usuario, mientras que las tarjetas de abajo son de gestión. */}
        <Card className="surface-card">
          <CardHeader>
            <CardTitle>Tu cuenta</CardTitle>
            <CardDescription>Datos de acceso al sistema.</CardDescription>
          </CardHeader>
          <CardContent>
            <button
              onClick={() => setPasswordAbierto(true)}
              className="flex w-full items-center gap-4 rounded-xl border border-border p-4 text-left transition-colors hover:border-primary/40 hover:bg-accent/30"
            >
              <span className="gradient-primary flex size-10 shrink-0 items-center justify-center rounded-xl text-primary-foreground">
                <KeyRound className="size-5" />
              </span>
              <span className="min-w-0 flex-1">
                <span className="block text-sm font-semibold text-foreground">
                  Cambiar contraseña
                </span>
                <span className="mt-0.5 block text-xs text-muted-foreground">
                  Se cierran todas tus sesiones y tenés que volver a entrar.
                </span>
              </span>
              <Button asChild variant="outline" size="sm" className="pointer-events-none shrink-0">
                <span>Cambiar</span>
              </Button>
            </button>
          </CardContent>
        </Card>

        <CambiarPasswordDialog open={passwordAbierto} onOpenChange={setPasswordAbierto} />

        <Card className="surface-card">
          <CardHeader>
            <CardTitle>Administración</CardTitle>
            <CardDescription>Cuentas, estructura del menú y permisos de acceso.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <button
              onClick={() => setUsuariosAbierto(true)}
              className="flex w-full items-center gap-4 rounded-xl border border-border p-4 text-left transition-colors hover:border-primary/40 hover:bg-accent/30"
            >
              <span className="gradient-primary flex size-10 shrink-0 items-center justify-center rounded-xl text-primary-foreground">
                <Users className="size-5" />
              </span>
              <span className="min-w-0 flex-1">
                <span className="block text-sm font-semibold text-foreground">Usuarios</span>
                <span className="mt-0.5 block text-xs text-muted-foreground">
                  Crear, editar, cambiar contraseñas y dar de baja cuentas.
                </span>
              </span>
              <Button asChild variant="outline" size="sm" className="pointer-events-none shrink-0">
                <span>Abrir</span>
              </Button>
            </button>

            <button
              onClick={() => setModulosAbierto(true)}
              className="flex w-full items-center gap-4 rounded-xl border border-border p-4 text-left transition-colors hover:border-primary/40 hover:bg-accent/30"
            >
              <span className="gradient-primary flex size-10 shrink-0 items-center justify-center rounded-xl text-primary-foreground">
                <LayoutGrid className="size-5" />
              </span>
              <span className="min-w-0 flex-1">
                <span className="block text-sm font-semibold text-foreground">Módulos</span>
                <span className="mt-0.5 block text-xs text-muted-foreground">
                  Crear, editar y eliminar los módulos del menú.
                </span>
              </span>
              <Button asChild variant="outline" size="sm" className="pointer-events-none shrink-0">
                <span>Abrir</span>
              </Button>
            </button>

            <button
              onClick={() => setPaginasAbierto(true)}
              className="flex w-full items-center gap-4 rounded-xl border border-border p-4 text-left transition-colors hover:border-primary/40 hover:bg-accent/30"
            >
              <span className="gradient-primary flex size-10 shrink-0 items-center justify-center rounded-xl text-primary-foreground">
                <FileText className="size-5" />
              </span>
              <span className="min-w-0 flex-1">
                <span className="block text-sm font-semibold text-foreground">Páginas</span>
                <span className="mt-0.5 block text-xs text-muted-foreground">
                  Las páginas que hay dentro de cada módulo.
                </span>
              </span>
              <Button asChild variant="outline" size="sm" className="pointer-events-none shrink-0">
                <span>Abrir</span>
              </Button>
            </button>

            <button
              onClick={() => setPermisosAbierto(true)}
              className="flex w-full items-center gap-4 rounded-xl border border-border p-4 text-left transition-colors hover:border-primary/40 hover:bg-accent/30"
            >
              <span className="gradient-primary flex size-10 shrink-0 items-center justify-center rounded-xl text-primary-foreground">
                <ShieldCheck className="size-5" />
              </span>
              <span className="min-w-0 flex-1">
                <span className="block text-sm font-semibold text-foreground">Permisos</span>
                <span className="mt-0.5 block text-xs text-muted-foreground">
                  Qué páginas puede ver cada usuario.
                </span>
              </span>
              <Button asChild variant="outline" size="sm" className="pointer-events-none shrink-0">
                <span>Abrir</span>
              </Button>
            </button>
          </CardContent>
        </Card>

        <UsuariosDialog open={usuariosAbierto} onOpenChange={setUsuariosAbierto} />
        <ModulosDialog open={modulosAbierto} onOpenChange={setModulosAbierto} />
        <PaginasDialog open={paginasAbierto} onOpenChange={setPaginasAbierto} />
        <PermisosDialog open={permisosAbierto} onOpenChange={setPermisosAbierto} />

        <Card className="surface-card">
          <CardHeader>
            <CardTitle>Apariencia</CardTitle>
            <CardDescription>
              Elegí cómo se ve CTELL. La preferencia se guarda en este dispositivo.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div
              role="radiogroup"
              aria-label="Tema de la interfaz"
              className="grid gap-3 sm:grid-cols-3"
            >
              {themeOptions.map((option) => {
                const selected = theme === option.value;
                return (
                  <button
                    key={option.value}
                    role="radio"
                    aria-checked={selected}
                    onClick={() => setTheme(option.value)}
                    className={`flex flex-col items-start gap-2 rounded-xl border p-4 text-left transition-colors ${
                      selected
                        ? "border-primary bg-accent/60 ring-2 ring-primary/30"
                        : "border-border hover:border-primary/40 hover:bg-accent/30"
                    }`}
                  >
                    <span
                      className={`flex size-9 items-center justify-center rounded-lg ${
                        selected
                          ? "bg-primary text-primary-foreground"
                          : "bg-muted text-muted-foreground"
                      }`}
                    >
                      <option.icon className="size-5" />
                    </span>
                    <span className="text-sm font-semibold text-foreground">{option.label}</span>
                    <span className="text-xs text-muted-foreground">{option.description}</span>
                  </button>
                );
              })}
            </div>
          </CardContent>
        </Card>

        <Card className="surface-card">
          <CardHeader>
            <CardTitle>Color de acento</CardTitle>
            <CardDescription>
              Define el color de botones, enlaces y elementos destacados. Todos mantienen buen
              contraste en modo claro y oscuro.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div
              role="radiogroup"
              aria-label="Color de acento"
              className="grid grid-cols-2 gap-3 sm:grid-cols-5"
            >
              {COLOR_THEMES.map((option) => {
                const selected = colorTheme === option.id;
                return (
                  <button
                    key={option.id}
                    role="radio"
                    aria-checked={selected}
                    onClick={() => setColorTheme(option.id)}
                    title={option.description}
                    className={`group flex flex-col items-center gap-2 rounded-xl border p-3 transition-colors ${
                      selected
                        ? "border-primary bg-accent/60 ring-2 ring-primary/30"
                        : "border-border hover:border-primary/40 hover:bg-accent/30"
                    }`}
                  >
                    <span
                      className="flex size-9 items-center justify-center rounded-full shadow-card transition-transform group-hover:scale-105"
                      style={{ backgroundColor: option.swatch }}
                    >
                      {selected && <Check className="size-5 text-white" strokeWidth={3} />}
                    </span>
                    <span className="text-center text-xs font-semibold leading-tight text-foreground">
                      {option.label}
                    </span>
                  </button>
                );
              })}
            </div>
            <p className="mt-4 text-xs text-muted-foreground">
              El color elegido se guarda en este dispositivo y se aplica al iniciar sesión.
            </p>
          </CardContent>
        </Card>
      </main>
    </AppLayout>
  );
}
