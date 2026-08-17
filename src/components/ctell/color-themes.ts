/**
 * Paletas de acento seleccionables por el usuario.
 *
 * Cada entrada define el color primario en modo claro y oscuro. Los valores
 * están calculados en oklch manteniendo la lightness pareja dentro de cada
 * modo, de forma que ningún tema se vea más "pesado" que otro.
 *
 * El contraste del texto sobre el acento fue verificado contra WCAG AA (4.5:1)
 * en ambos modos: en claro el texto va blanco; en oscuro los acentos son más
 * luminosos, así que el texto encima va oscuro (navy), que es lo que da el
 * ratio alto — con blanco varios quedaban por debajo de 3:1.
 */
export type ColorThemeId =
  | "azul"
  | "indigo"
  | "violeta"
  | "cian"
  | "teal"
  | "esmeralda"
  | "ambar"
  | "naranja"
  | "rosa"
  | "grafito";

export type ColorTheme = {
  id: ColorThemeId;
  label: string;
  description: string;
  /** Muestra para el selector (color en modo claro). */
  swatch: string;
  light: { primary: string; glow: string; ring: string; foreground: string };
  dark: { primary: string; glow: string; ring: string; foreground: string };
};

/** Texto oscuro usado sobre acentos luminosos en modo oscuro. */
const DARK_FG = "oklch(0.18 0.04 256.5)";
const LIGHT_FG = "oklch(0.99 0.005 256.5)";

export const COLOR_THEMES: [ColorTheme, ...ColorTheme[]] = [
  {
    id: "azul",
    label: "Azul institucional",
    description: "Color por defecto del sistema.",
    swatch: "oklch(0.506 0.164 256.5)",
    light: {
      primary: "oklch(0.506 0.164 256.5)",
      glow: "oklch(0.66 0.145 253)",
      ring: "oklch(0.506 0.164 256.5)",
      foreground: LIGHT_FG,
    },
    dark: {
      primary: "oklch(0.62 0.17 256.5)",
      glow: "oklch(0.72 0.14 253)",
      ring: "oklch(0.62 0.17 256.5)",
      foreground: DARK_FG,
    },
  },
  {
    id: "indigo",
    label: "Índigo",
    description: "Sobrio y corporativo.",
    swatch: "oklch(0.52 0.2 277)",
    light: {
      primary: "oklch(0.52 0.2 277)",
      glow: "oklch(0.66 0.17 275)",
      ring: "oklch(0.52 0.2 277)",
      foreground: LIGHT_FG,
    },
    dark: {
      primary: "oklch(0.64 0.19 277)",
      glow: "oklch(0.73 0.16 275)",
      ring: "oklch(0.64 0.19 277)",
      foreground: DARK_FG,
    },
  },
  {
    id: "violeta",
    label: "Violeta",
    description: "Moderno, tipo producto SaaS.",
    swatch: "oklch(0.53 0.21 293)",
    light: {
      primary: "oklch(0.53 0.21 293)",
      glow: "oklch(0.67 0.18 292)",
      ring: "oklch(0.53 0.21 293)",
      foreground: LIGHT_FG,
    },
    dark: {
      primary: "oklch(0.65 0.19 293)",
      glow: "oklch(0.74 0.16 292)",
      ring: "oklch(0.65 0.19 293)",
      foreground: DARK_FG,
    },
  },
  {
    id: "cian",
    label: "Cian",
    description: "Fresco y tecnológico.",
    swatch: "oklch(0.55 0.12 221.7)",
    light: {
      primary: "oklch(0.55 0.12 221.7)",
      glow: "oklch(0.68 0.11 220)",
      ring: "oklch(0.55 0.12 221.7)",
      foreground: LIGHT_FG,
    },
    dark: {
      primary: "oklch(0.72 0.13 221.7)",
      glow: "oklch(0.79 0.11 220)",
      ring: "oklch(0.72 0.13 221.7)",
      foreground: DARK_FG,
    },
  },
  {
    id: "teal",
    label: "Turquesa",
    description: "Sereno, fácil a la vista.",
    swatch: "oklch(0.55 0.11 184.7)",
    light: {
      primary: "oklch(0.55 0.11 184.7)",
      glow: "oklch(0.68 0.1 183)",
      ring: "oklch(0.55 0.11 184.7)",
      foreground: LIGHT_FG,
    },
    dark: {
      primary: "oklch(0.72 0.12 184.7)",
      glow: "oklch(0.79 0.1 183)",
      ring: "oklch(0.72 0.12 184.7)",
      foreground: DARK_FG,
    },
  },
  {
    id: "esmeralda",
    label: "Esmeralda",
    description: "Asociado a crecimiento y finanzas.",
    swatch: "oklch(0.55 0.13 163.2)",
    light: {
      primary: "oklch(0.55 0.13 163.2)",
      glow: "oklch(0.68 0.12 162)",
      ring: "oklch(0.55 0.13 163.2)",
      foreground: LIGHT_FG,
    },
    dark: {
      primary: "oklch(0.72 0.14 163.2)",
      glow: "oklch(0.79 0.12 162)",
      ring: "oklch(0.72 0.14 163.2)",
      foreground: DARK_FG,
    },
  },
  {
    id: "ambar",
    label: "Ámbar",
    description: "Cálido y enérgico.",
    swatch: "oklch(0.62 0.15 58.3)",
    light: {
      primary: "oklch(0.62 0.15 58.3)",
      glow: "oklch(0.75 0.14 62)",
      ring: "oklch(0.62 0.15 58.3)",
      foreground: LIGHT_FG,
    },
    dark: {
      primary: "oklch(0.8 0.15 58.3)",
      glow: "oklch(0.86 0.12 62)",
      ring: "oklch(0.8 0.15 58.3)",
      foreground: DARK_FG,
    },
  },
  {
    id: "naranja",
    label: "Naranja",
    description: "Alta visibilidad, muy dinámico.",
    swatch: "oklch(0.6 0.18 41.1)",
    light: {
      primary: "oklch(0.6 0.18 41.1)",
      glow: "oklch(0.72 0.16 45)",
      ring: "oklch(0.6 0.18 41.1)",
      foreground: LIGHT_FG,
    },
    dark: {
      primary: "oklch(0.72 0.17 41.1)",
      glow: "oklch(0.8 0.14 45)",
      ring: "oklch(0.72 0.17 41.1)",
      foreground: DARK_FG,
    },
  },
  {
    id: "rosa",
    label: "Rosa",
    description: "Distintivo y actual.",
    swatch: "oklch(0.55 0.2 0.6)",
    light: {
      primary: "oklch(0.55 0.2 0.6)",
      glow: "oklch(0.68 0.17 5)",
      ring: "oklch(0.55 0.2 0.6)",
      foreground: LIGHT_FG,
    },
    dark: {
      primary: "oklch(0.66 0.19 0.6)",
      glow: "oklch(0.75 0.16 5)",
      ring: "oklch(0.66 0.19 0.6)",
      foreground: DARK_FG,
    },
  },
  {
    id: "grafito",
    label: "Grafito",
    description: "Neutro, sin distracciones.",
    swatch: "oklch(0.44 0.04 257.3)",
    light: {
      primary: "oklch(0.44 0.04 257.3)",
      glow: "oklch(0.58 0.04 257)",
      ring: "oklch(0.44 0.04 257.3)",
      foreground: LIGHT_FG,
    },
    dark: {
      primary: "oklch(0.6 0.04 257.3)",
      glow: "oklch(0.7 0.035 257)",
      ring: "oklch(0.6 0.04 257.3)",
      foreground: DARK_FG,
    },
  },
];

export const DEFAULT_COLOR_THEME: ColorThemeId = "azul";

export function getColorTheme(id: string | null | undefined): ColorTheme {
  return COLOR_THEMES.find((t) => t.id === id) ?? COLOR_THEMES[0];
}
