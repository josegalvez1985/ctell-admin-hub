import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";

import {
  COLOR_THEMES,
  DEFAULT_COLOR_THEME,
  getColorTheme,
  type ColorThemeId,
} from "@/components/ctell/color-themes";

export type Theme = "light" | "dark" | "system";

const STORAGE_KEY = "ctell-theme";
const COLOR_KEY = "ctell-color";

type ThemeContextValue = {
  /** Preferencia elegida por el usuario. */
  theme: Theme;
  /** Tema efectivo ya resuelto ("system" traducido a claro/oscuro). */
  resolvedTheme: "light" | "dark";
  setTheme: (theme: Theme) => void;
  toggleTheme: () => void;
  /** Paleta de acento seleccionada. */
  colorTheme: ColorThemeId;
  setColorTheme: (id: ColorThemeId) => void;
};

const ThemeContext = createContext<ThemeContextValue | null>(null);

function systemTheme(): "light" | "dark" {
  if (typeof window === "undefined") return "light";
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function applyTheme(resolved: "light" | "dark") {
  const root = document.documentElement;
  root.classList.toggle("dark", resolved === "dark");
  root.style.colorScheme = resolved;
}

/**
 * Escribe las variables del acento elegido como estilos inline en <html>,
 * pisando las de styles.css. Se reaplica al cambiar de claro a oscuro porque
 * cada modo tiene su propio juego de valores.
 */
function applyColorTheme(id: ColorThemeId, resolved: "light" | "dark") {
  const palette = getColorTheme(id)[resolved];
  const root = document.documentElement;
  root.style.setProperty("--primary", palette.primary);
  root.style.setProperty("--primary-glow", palette.glow);
  root.style.setProperty("--ring", palette.ring);
  root.style.setProperty("--primary-foreground", palette.foreground);
  root.style.setProperty("--sidebar-primary", palette.primary);
  root.style.setProperty("--sidebar-primary-foreground", palette.foreground);
  root.style.setProperty("--sidebar-ring", palette.ring);
  root.style.setProperty("--chart-1", palette.primary);
  root.style.setProperty("--chart-2", palette.glow);
  root.dataset["colorTheme"] = id;
}

/**
 * Script inyectado en el <head> para aplicar tema y acento ANTES del primer
 * paint. Sin esto la página renderiza en claro con el azul por defecto y
 * parpadea al pasar al modo/color guardados.
 */
export const themeInitScript = `(function(){try{
var t=localStorage.getItem("${STORAGE_KEY}")||"system";
var d=t==="dark"||(t==="system"&&matchMedia("(prefers-color-scheme: dark)").matches);
var r=document.documentElement;
r.classList.toggle("dark",d);
r.style.colorScheme=d?"dark":"light";
var P=${JSON.stringify(
  Object.fromEntries(COLOR_THEMES.map((t) => [t.id, { light: t.light, dark: t.dark }])),
)};
var c=localStorage.getItem("${COLOR_KEY}")||"${DEFAULT_COLOR_THEME}";
var p=(P[c]||P["${DEFAULT_COLOR_THEME}"])[d?"dark":"light"];
r.style.setProperty("--primary",p.primary);
r.style.setProperty("--primary-glow",p.glow);
r.style.setProperty("--ring",p.ring);
r.style.setProperty("--primary-foreground",p.foreground);
r.style.setProperty("--sidebar-primary",p.primary);
r.style.setProperty("--sidebar-primary-foreground",p.foreground);
r.style.setProperty("--sidebar-ring",p.ring);
r.style.setProperty("--chart-1",p.primary);
r.style.setProperty("--chart-2",p.glow);
r.dataset.colorTheme=c;
}catch(e){}})();`;

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setThemeState] = useState<Theme>("system");
  const [resolvedTheme, setResolvedTheme] = useState<"light" | "dark">("light");
  const [colorTheme, setColorThemeState] = useState<ColorThemeId>(DEFAULT_COLOR_THEME);

  // Lee las preferencias guardadas al montar (en SSR no hay localStorage).
  useEffect(() => {
    const stored = localStorage.getItem(STORAGE_KEY) as Theme | null;
    const initial = stored ?? "system";
    const resolved = initial === "system" ? systemTheme() : initial;
    const storedColor = getColorTheme(localStorage.getItem(COLOR_KEY)).id;

    setThemeState(initial);
    setResolvedTheme(resolved);
    setColorThemeState(storedColor);
    applyTheme(resolved);
    applyColorTheme(storedColor, resolved);
  }, []);

  // Con "system", sigue los cambios del SO en vivo.
  useEffect(() => {
    if (theme !== "system") return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => {
      const resolved = mq.matches ? "dark" : "light";
      setResolvedTheme(resolved);
      applyTheme(resolved);
      applyColorTheme(colorTheme, resolved);
    };
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, [theme, colorTheme]);

  const setTheme = useCallback(
    (next: Theme) => {
      setThemeState(next);
      localStorage.setItem(STORAGE_KEY, next);
      const resolved = next === "system" ? systemTheme() : next;
      setResolvedTheme(resolved);
      applyTheme(resolved);
      // El acento tiene valores distintos por modo: hay que reaplicarlo.
      applyColorTheme(colorTheme, resolved);
    },
    [colorTheme],
  );

  const toggleTheme = useCallback(() => {
    setTheme(resolvedTheme === "dark" ? "light" : "dark");
  }, [resolvedTheme, setTheme]);

  const setColorTheme = useCallback(
    (id: ColorThemeId) => {
      setColorThemeState(id);
      localStorage.setItem(COLOR_KEY, id);
      applyColorTheme(id, resolvedTheme);
    },
    [resolvedTheme],
  );

  return (
    <ThemeContext.Provider
      value={{ theme, resolvedTheme, setTheme, toggleTheme, colorTheme, setColorTheme }}
    >
      {children}
    </ThemeContext.Provider>
  );
}

export function useTheme() {
  const ctx = useContext(ThemeContext);
  if (!ctx) throw new Error("useTheme debe usarse dentro de <ThemeProvider>");
  return ctx;
}
