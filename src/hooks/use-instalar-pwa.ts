import { useCallback, useEffect, useState } from "react";

/**
 * Evento que Chrome dispara cuando el sitio cumple los requisitos de
 * instalación. No está en las definiciones estándar de TypeScript porque es
 * una API propia de navegadores basados en Chromium.
 */
type BeforeInstallPromptEvent = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
};

/** Marca de que el usuario descartó la sugerencia. No se vuelve a ofrecer. */
const CLAVE_DESCARTADO = "ctell.pwa.descartado";

/** Ya corre instalada: no tiene sentido sugerir instalarla de nuevo. */
function esStandalone(): boolean {
  if (typeof window === "undefined") return false;
  return (
    window.matchMedia("(display-mode: standalone)").matches ||
    // Safari en iOS no soporta display-mode y expone esto en su lugar.
    (window.navigator as { standalone?: boolean }).standalone === true
  );
}

function esIOS(): boolean {
  if (typeof navigator === "undefined") return false;
  // iPadOS 13+ se identifica como Mac: el maxTouchPoints lo desambigua.
  return (
    /iphone|ipad|ipod/i.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
  );
}

/**
 * Sugerencia de instalar la PWA, solo en celular.
 *
 * Los dos sistemas se comportan distinto y el hook lo refleja:
 *
 * - **Android/Chrome** dispara `beforeinstallprompt`, que se guarda para
 *   abrir el diálogo nativo cuando el usuario acepte. Requiere que haya un
 *   service worker registrado con handler de `fetch` (ver `public/sw.js`);
 *   sin eso el evento no llega nunca y este hook queda inactivo.
 * - **iOS/Safari** no tiene esa API: no hay forma de instalar por código. Lo
 *   único posible es explicar el camino manual (Compartir → Agregar a inicio),
 *   así que ahí se muestran instrucciones en vez de un botón.
 *
 * No sugiere nada si la app ya corre instalada o si el usuario descartó la
 * sugerencia antes.
 */
export function useInstalarPwa() {
  const [evento, setEvento] = useState<BeforeInstallPromptEvent | null>(null);
  const [instrucciones, setInstrucciones] = useState(false);
  const [descartado, setDescartado] = useState(true);

  useEffect(() => {
    // Se lee acá y no en el useState inicial: localStorage no existe durante el
    // prerender del build y leerlo en el primer render rompe la hidratación.
    const yaDescarto = localStorage.getItem(CLAVE_DESCARTADO) === "1";
    setDescartado(yaDescarto);

    if (yaDescarto || esStandalone()) return;

    // iOS no dispara el evento: si es iPhone/iPad se muestran las
    // instrucciones manuales directamente.
    if (esIOS()) {
      setInstrucciones(true);
      return;
    }

    function alPoderInstalar(e: Event) {
      // Sin preventDefault, Chrome muestra su propia barra de instalación
      // además de este diálogo.
      e.preventDefault();
      setEvento(e as BeforeInstallPromptEvent);
    }

    window.addEventListener("beforeinstallprompt", alPoderInstalar);
    return () => window.removeEventListener("beforeinstallprompt", alPoderInstalar);
  }, []);

  // Si la instalan por fuera del diálogo (menú del navegador), se limpia el
  // estado para que la sugerencia desaparezca sin recargar.
  useEffect(() => {
    function alInstalar() {
      setEvento(null);
      setInstrucciones(false);
    }
    window.addEventListener("appinstalled", alInstalar);
    return () => window.removeEventListener("appinstalled", alInstalar);
  }, []);

  const instalar = useCallback(async () => {
    if (!evento) return;
    await evento.prompt();
    // El evento sirve una sola vez: después de usarlo hay que soltarlo.
    setEvento(null);
  }, [evento]);

  const descartar = useCallback(() => {
    localStorage.setItem(CLAVE_DESCARTADO, "1");
    setDescartado(true);
  }, []);

  return {
    /** Hay algo para ofrecer: el botón de Android o las instrucciones de iOS. */
    puedeSugerir: !descartado && (evento !== null || instrucciones),
    /** En iOS no hay instalación por código: se explica el camino manual. */
    soloInstrucciones: instrucciones,
    instalar,
    descartar,
  };
}
