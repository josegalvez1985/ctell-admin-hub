import { createFileRoute } from "@tanstack/react-router";
import { Check, Monitor, Moon, Sun } from "lucide-react";

import { AppLayout } from "@/components/ctell/AppLayout";
import { COLOR_THEMES } from "@/components/ctell/color-themes";
import { useTheme, type Theme } from "@/components/ctell/theme-provider";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export const Route = createFileRoute("/configuracion")({
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

  return (
    <AppLayout active="Configuración" title="Configuración" showSearch={false}>
      <main className="mx-auto max-w-3xl space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div>
          <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Configuración</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Preferencias de tu cuenta y del sistema.
          </p>
        </div>

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
