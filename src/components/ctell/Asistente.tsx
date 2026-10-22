import { useRouterState } from "@tanstack/react-router";
import {
  AlertTriangle,
  ArrowUp,
  Check,
  Copy,
  RotateCcw,
  Sparkles,
  SquarePen,
  X,
} from "lucide-react";
import { useEffect, useRef, useState, useSyncExternalStore, type KeyboardEvent } from "react";
import { toast } from "sonner";

import { useEmpresa } from "@/components/ctell/empresa-provider";
import { Markdown } from "@/components/ctell/Markdown";
import { Drawer, DrawerContent, DrawerDescription, DrawerTitle } from "@/components/ui/drawer";
import {
  abrirAsistente,
  cargarManual,
  nuevaConversacion,
  preguntar,
  reintentar,
  useAsistente,
  type MensajeIA,
} from "@/lib/asistente";
import { cn } from "@/lib/utils";

/**
 * El asistente con IA: botón flotante y chat, en todas las pantallas con
 * sesión (lo monta `AppLayout`). Lógica y contrato en `lib/asistente.ts`; el
 * backend, `db/asistente.sql`.
 *
 * | | Botón | Chat |
 * | --- | --- | --- |
 * | Celular (`< lg`) | abajo a la derecha, **encima** del botón del menú | hoja casi a pantalla completa |
 * | Escritorio (`≥ lg`) | abajo a la derecha | panel fijo a la derecha, **sin tapar** la pantalla: `AppLayout` le hace lugar, y sigue abierto al navegar |
 *
 * Lo ven todos los que entran: no depende de los permisos de página (Jose,
 * 22/10/2026).
 */
export function Asistente({
  pantalla,
  ocultarBoton = false,
}: {
  /** El título de la pantalla, el mismo que muestra el header (`AppLayout`). */
  pantalla?: string | undefined;
  /** Con el menú del celular abierto el botón quedaría encima de la hoja. */
  ocultarBoton?: boolean;
}) {
  const { abierto, pendiente } = useAsistente();
  const escritorio = useEscritorio();

  return (
    <>
      {!ocultarBoton && !(escritorio && abierto) && (
        <button
          type="button"
          onClick={() => {
            void cargarManual(); // que esté listo para la primera pregunta
            abrirAsistente(true);
          }}
          aria-label="Abrir el asistente"
          title="Asistente"
          className="gradient-primary fixed bottom-24 right-6 z-30 grid size-14 place-items-center rounded-full text-primary-foreground shadow-lg transition-transform active:scale-95 lg:bottom-6"
        >
          <Sparkles className="size-6" />
          {pendiente && (
            <span className="absolute right-0.5 top-0.5 flex size-3.5">
              <span className="absolute inline-flex size-full animate-ping rounded-full bg-primary-foreground/70" />
              <span className="relative inline-flex size-3.5 rounded-full border-2 border-primary-foreground bg-destructive" />
            </span>
          )}
        </button>
      )}

      {escritorio ? (
        abierto && (
          <aside
            aria-label="Asistente"
            className="fixed inset-y-0 right-0 z-40 flex w-[420px] flex-col border-l border-border bg-background shadow-lg duration-200 animate-in fade-in slide-in-from-right"
          >
            <PanelChat escritorio pantalla={pantalla} />
          </aside>
        )
      ) : (
        <Drawer open={abierto} onOpenChange={abrirAsistente} shouldScaleBackground={false}>
          <DrawerContent className="h-[94dvh] rounded-t-3xl lg:hidden">
            <DrawerTitle className="sr-only">Asistente</DrawerTitle>
            <DrawerDescription className="sr-only">
              Preguntale sobre el sistema o sobre los datos
            </DrawerDescription>
            <PanelChat escritorio={false} pantalla={pantalla} />
          </DrawerContent>
        </Drawer>
      )}
    </>
  );
}

/** `≥ lg`, el mismo corte que el sidebar de `AppLayout`. */
function useEscritorio() {
  return useSyncExternalStore(
    (f) => {
      const mq = window.matchMedia("(min-width: 1024px)");
      mq.addEventListener("change", f);
      return () => mq.removeEventListener("change", f);
    },
    () => window.matchMedia("(min-width: 1024px)").matches,
    () => false,
  );
}

/* -------------------------------------------------------------------------- */
/* El chat                                                                     */
/* -------------------------------------------------------------------------- */

function PanelChat({
  escritorio,
  pantalla: titulo,
}: {
  escritorio: boolean;
  pantalla?: string | undefined;
}) {
  const { mensajes, pendiente, usadasHoy, limite } = useAsistente();
  const pantalla = usePantallaActual(titulo);
  const [texto, setTexto] = useState("");
  const lista = useRef<HTMLDivElement>(null);
  const entrada = useRef<HTMLTextAreaElement>(null);

  // Siempre a la vista lo último: la pregunta recién mandada y la respuesta.
  useEffect(() => {
    lista.current?.scrollTo({ top: lista.current.scrollHeight, behavior: "smooth" });
  }, [mensajes.length, pendiente]);

  // En la computadora se escribe enseguida; en el celular no se abre el
  // teclado solo, que tapa la mitad de la hoja.
  useEffect(() => {
    if (escritorio) entrada.current?.focus();
  }, [escritorio]);

  // Escape cierra el panel de la computadora (la hoja del celular ya lo hace).
  useEffect(() => {
    if (!escritorio) return;
    const onKey = (e: globalThis.KeyboardEvent) => {
      if (e.key === "Escape") abrirAsistente(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [escritorio]);

  const enviar = (t = texto) => {
    if (!t.trim() || pendiente) return;
    void preguntar(t, pantalla.texto);
    setTexto("");
    entrada.current?.style.removeProperty("height");
  };

  const onKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      enviar();
    }
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* Cabecera */}
      <div className="flex items-center gap-3 border-b border-border px-4 py-3">
        <span className="gradient-primary grid size-9 shrink-0 place-items-center rounded-full text-primary-foreground">
          <Sparkles className="size-[18px]" />
        </span>
        <div className="min-w-0 flex-1">
          <h2 className="font-display text-[15px] font-bold leading-tight">Asistente</h2>
          <p className="truncate text-xs leading-tight text-muted-foreground">
            Sobre el sistema o sobre los datos
          </p>
        </div>
        {mensajes.length > 0 && (
          <button
            type="button"
            onClick={nuevaConversacion}
            disabled={pendiente}
            title="Nueva conversación"
            aria-label="Nueva conversación"
            className="grid size-9 place-items-center rounded-full text-muted-foreground hover:bg-muted disabled:opacity-40"
          >
            <SquarePen className="size-[18px]" />
          </button>
        )}
        <button
          type="button"
          onClick={() => abrirAsistente(false)}
          title="Cerrar"
          aria-label="Cerrar el asistente"
          className="grid size-9 place-items-center rounded-full text-muted-foreground hover:bg-muted"
        >
          <X className="size-5" />
        </button>
      </div>

      {/* Conversación */}
      <div
        ref={lista}
        className="scrollbar-fino min-h-0 flex-1 space-y-4 overflow-y-auto px-4 py-4"
      >
        {mensajes.length === 0 ? (
          <Bienvenida pantalla={pantalla.nombre} onElegir={enviar} />
        ) : (
          mensajes.map((m, i) => (
            <Mensaje
              key={m.id}
              m={m}
              ultimo={i === mensajes.length - 1}
              onReintentar={() => reintentar(pantalla.texto)}
            />
          ))
        )}
        {pendiente && <Pensando />}
      </div>

      {/* Entrada */}
      <div className="border-t border-border px-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-3">
        <div className="flex items-end gap-2 rounded-2xl border border-border bg-card px-3 py-2 focus-within:border-primary/60 focus-within:ring-2 focus-within:ring-primary/15">
          <textarea
            ref={entrada}
            value={texto}
            onChange={(e) => {
              setTexto(e.target.value);
              // Crece con el texto hasta unas 6 líneas.
              e.target.style.height = "auto";
              e.target.style.height = `${Math.min(e.target.scrollHeight, 150)}px`;
            }}
            onKeyDown={onKeyDown}
            rows={1}
            maxLength={4000}
            enterKeyHint="send"
            placeholder="Escribí tu pregunta…"
            aria-label="Tu pregunta"
            className="max-h-[150px] min-h-[24px] flex-1 resize-none bg-transparent py-1 text-sm leading-snug outline-none placeholder:text-muted-foreground"
          />
          <button
            type="button"
            onClick={() => enviar()}
            disabled={!texto.trim() || pendiente}
            aria-label="Enviar"
            className="grid size-9 shrink-0 place-items-center rounded-full bg-primary text-primary-foreground disabled:bg-muted disabled:text-muted-foreground"
          >
            <ArrowUp className="size-[18px]" />
          </button>
        </div>
        <p className="mt-1.5 px-1 text-center text-[10.5px] leading-tight text-muted-foreground">
          Lo responde una IA con los datos del sistema: revisá lo importante.
          {usadasHoy != null && limite != null && (
            <>
              {" "}
              Hoy: {usadasHoy} de {limite} preguntas.
            </>
          )}
        </p>
      </div>
    </div>
  );
}

/**
 * La pantalla abierta, para la IA ("¿cómo uso esta pantalla?") y para la
 * primera sugerencia. El nombre es el título que cada página le pasa a
 * `AppLayout`; la ruta va al lado para que no haya dudas de cuál es.
 */
function usePantallaActual(titulo: string | undefined): { nombre: string | null; texto: string } {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const nombre = titulo?.trim() || null;
  return { nombre, texto: nombre ? `${nombre} (${pathname})` : pathname };
}

function Bienvenida({
  pantalla,
  onElegir,
}: {
  pantalla: string | null;
  onElegir: (t: string) => void;
}) {
  const { empresa } = useEmpresa();
  const sugerencias = [
    pantalla && pantalla !== "Dashboard" ? `¿Cómo se usa ${pantalla}?` : null,
    "¿Cuánto vendimos este mes?",
    "¿Qué artículos están por debajo del stock mínimo?",
    "¿Qué justificaciones de ausencia están pendientes?",
    "¿Cómo le doy permisos a un usuario?",
  ].filter((s): s is string => !!s);

  return (
    <div className="flex flex-col items-center pt-6 text-center">
      <span className="gradient-primary grid size-14 place-items-center rounded-2xl text-primary-foreground shadow-md">
        <Sparkles className="size-7" />
      </span>
      <p className="mt-3 font-display text-lg font-bold">¿En qué te ayudo?</p>
      <p className="mt-1 max-w-[19rem] text-[13px] text-muted-foreground">
        Preguntame cómo se usa una pantalla o cualquier cosa sobre los datos
        {empresa?.nombreEmpresa ? ` de ${empresa.nombreEmpresa}` : ""}: ventas, compras, stock,
        cobros, asistencias…
      </p>
      <div className="mt-5 flex w-full flex-col gap-2">
        {sugerencias.map((s) => (
          <button
            key={s}
            type="button"
            onClick={() => onElegir(s)}
            className="rounded-xl border border-border bg-card px-3.5 py-2.5 text-left text-[13.5px] transition-colors hover:border-primary/40 hover:bg-primary/10"
          >
            {s}
          </button>
        ))}
      </div>
    </div>
  );
}

function Mensaje({
  m,
  ultimo,
  onReintentar,
}: {
  m: MensajeIA;
  ultimo: boolean;
  onReintentar: () => void;
}) {
  if (m.rol === "usuario") {
    return (
      <div className="flex justify-end">
        <p className="max-w-[85%] whitespace-pre-wrap rounded-2xl rounded-br-md bg-primary px-3.5 py-2 text-sm leading-snug text-primary-foreground">
          {m.texto}
        </p>
      </div>
    );
  }

  if (m.error) {
    return (
      <div className="rounded-2xl border border-destructive/30 bg-destructive/5 px-3.5 py-3">
        <p className="flex items-start gap-2 text-[13.5px] text-destructive">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          <span>{m.texto}</span>
        </p>
        {ultimo && (
          <button
            type="button"
            onClick={onReintentar}
            className="mt-2.5 inline-flex h-9 items-center gap-1.5 rounded-xl bg-muted px-3.5 text-[13px] font-semibold"
          >
            <RotateCcw className="size-3.5" />
            Reintentar
          </button>
        )}
      </div>
    );
  }

  return (
    <div className="space-y-2">
      {/*
        Sin "Ver consultas": el usuario ve sólo la respuesta, y el backend no
        manda el SQL. Queda en IA_CONSULTAS.CONSULTAS.
      */}
      <Markdown texto={m.texto} />
      <BotonCopiar texto={m.texto} />
    </div>
  );
}

function BotonCopiar({ texto }: { texto: string }) {
  const [copiado, setCopiado] = useState(false);
  return (
    <button
      type="button"
      onClick={() => {
        navigator.clipboard
          ?.writeText(texto)
          .then(() => {
            setCopiado(true);
            setTimeout(() => setCopiado(false), 1500);
          })
          .catch(() => toast.error("No se pudo copiar"));
      }}
      className={cn(
        "inline-flex h-7 items-center gap-1 rounded-lg px-2 text-[11.5px] font-medium text-muted-foreground hover:bg-muted",
        copiado && "text-success",
      )}
    >
      {copiado ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
      {copiado ? "Copiado" : "Copiar"}
    </button>
  );
}

/**
 * Mientras espera. No hay avance real que mostrar (la respuesta llega
 * entera), así que el texto cambia con el tiempo: una pregunta sobre datos
 * suele llevar varias consultas.
 */
function Pensando() {
  const [segundos, setSegundos] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setSegundos((s) => s + 1), 1000);
    return () => clearInterval(t);
  }, []);
  const texto =
    segundos < 4
      ? "Pensando…"
      : segundos < 15
        ? "Buscando en los datos…"
        : `Sigue trabajando… (${segundos} s)`;

  return (
    <div className="flex items-center gap-2.5 text-[13px] text-muted-foreground" aria-live="polite">
      <span className="flex gap-1" aria-hidden>
        {[0, 1, 2].map((i) => (
          <span
            key={i}
            className="size-1.5 animate-bounce rounded-full bg-primary/70"
            style={{ animationDelay: `${i * 150}ms` }}
          />
        ))}
      </span>
      {texto}
    </div>
  );
}
