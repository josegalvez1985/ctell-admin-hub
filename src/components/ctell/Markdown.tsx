import { Fragment, type ReactNode } from "react";

import { cn } from "@/lib/utils";

/**
 * Markdown chico para las respuestas del asistente.
 *
 * Propio y no `react-markdown`: la IA usa un subconjunto conocido (títulos,
 * listas, tablas, negrita, código, enlaces) y así no se suma una dependencia ni
 * su peso —el mismo motivo por el que la pantalla Ayuda está escrita en JSX—.
 * **Nunca arma HTML a partir del texto**: todo sale como nodos de React, así
 * que una respuesta no puede inyectar nada en la página.
 *
 * Lo que entiende:
 *
 * - Bloques: `#`/`##`/`###`, listas con `-`, `*` o `1.` (la sangría se respeta
 *   como un nivel más), tablas con `|` y su fila `---`, bloques de código con
 *   tres comillas invertidas, citas con `>` y `---` como separador.
 * - En línea: `**negrita**`, `*cursiva*` / `_cursiva_`, `` `código` `` y
 *   `[texto](https://...)` (sólo enlaces http/https, en pestaña nueva).
 */
export function Markdown({ texto, className }: { texto: string; className?: string }) {
  return (
    <div className={cn("space-y-2.5 break-words text-sm leading-relaxed", className)}>
      {bloques(texto.replace(/\r\n?/g, "\n"))}
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Bloques                                                                     */
/* -------------------------------------------------------------------------- */

const RE_LISTA = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
const RE_TITULO = /^(#{1,6})\s+(.*)$/;
const RE_SEPARADOR_TABLA = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;
const RE_SEPARADOR = /^\s*([-*_])(\s*\1){2,}\s*$/;
const esFilaTabla = (l: string) => l.trim().startsWith("|") || /\S\s*\|\s*\S/.test(l);
/** La fila de guiones de una tabla: con al menos un `|`, para no confundirla con `---`. */
const esSeparadorTabla = (l = "") => l.includes("|") && RE_SEPARADOR_TABLA.test(l);

type Alineacion = "left" | "center" | "right";

function bloques(md: string): ReactNode[] {
  const lineas = md.split("\n");
  // Con `noUncheckedIndexedAccess` cada `lineas[i]` es `string | undefined`:
  // fuera de rango vale como línea vacía, que es lo que corta cada bloque.
  const en = (n: number) => lineas[n] ?? "";
  const empiezaTabla = (n: number) => esFilaTabla(en(n)) && esSeparadorTabla(lineas[n + 1]);
  const out: ReactNode[] = [];
  let i = 0;
  let k = 0;

  while (i < lineas.length) {
    const linea = en(i);

    if (!linea.trim()) {
      i++;
      continue;
    }

    // Código
    if (linea.trim().startsWith("```")) {
      const codigo: string[] = [];
      i++;
      while (i < lineas.length && !en(i).trim().startsWith("```")) codigo.push(en(i++));
      i++; // la que cierra
      out.push(
        <pre
          key={k++}
          className="overflow-x-auto rounded-xl bg-muted px-3 py-2.5 font-mono text-xs leading-snug"
        >
          {codigo.join("\n")}
        </pre>,
      );
      continue;
    }

    // Título
    const titulo = RE_TITULO.exec(linea);
    if (titulo) {
      const nivel = (titulo[1] ?? "").length;
      out.push(
        <p
          key={k++}
          className={cn("font-display font-bold", nivel <= 2 ? "pt-1 text-base" : "text-sm")}
        >
          {enLinea(titulo[2] ?? "")}
        </p>,
      );
      i++;
      continue;
    }

    // Separador
    if (RE_SEPARADOR.test(linea)) {
      out.push(<hr key={k++} className="border-border" />);
      i++;
      continue;
    }

    // Tabla: una fila con | seguida de la fila de guiones.
    if (empiezaTabla(i)) {
      const encabezado = celdas(linea);
      const alineacion = celdas(en(i + 1)).map((c): Alineacion =>
        c.endsWith(":") ? (c.startsWith(":") ? "center" : "right") : "left",
      );
      const filas: string[][] = [];
      i += 2;
      while (i < lineas.length && en(i).trim() && esFilaTabla(en(i))) {
        filas.push(celdas(en(i++)));
      }
      out.push(<Tabla key={k++} encabezado={encabezado} alineacion={alineacion} filas={filas} />);
      continue;
    }

    // Lista: los ítems seguidos (y sus líneas de continuación, con sangría).
    if (RE_LISTA.test(linea)) {
      const items: { nivel: number; ordenada: boolean; marca: string; texto: string }[] = [];
      while (i < lineas.length) {
        const m = RE_LISTA.exec(en(i));
        const anterior = items[items.length - 1];
        if (m) {
          const marca = m[2] ?? "";
          items.push({
            nivel: Math.min(3, Math.floor((m[1] ?? "").replace(/\t/g, "  ").length / 2)),
            ordenada: /\d/.test(marca),
            marca,
            texto: m[3] ?? "",
          });
          i++;
        } else if (en(i).trim() && /^\s+/.test(en(i)) && anterior) {
          anterior.texto += " " + en(i).trim();
          i++;
        } else break;
      }
      out.push(
        <ul key={k++} className="space-y-1">
          {items.map((it, j) => (
            <li key={j} className="flex gap-2" style={{ paddingLeft: `${it.nivel * 1.1}rem` }}>
              <span
                aria-hidden
                className={cn(
                  "shrink-0 tabular-nums text-muted-foreground",
                  it.ordenada ? "min-w-[1.1rem] text-right" : "pt-[0.55em]",
                )}
              >
                {it.ordenada ? (
                  it.marca.replace(")", ".")
                ) : (
                  <span className="block size-1.5 rounded-full bg-current" />
                )}
              </span>
              <span className="min-w-0 flex-1">{enLinea(it.texto)}</span>
            </li>
          ))}
        </ul>,
      );
      continue;
    }

    // Cita
    if (linea.trimStart().startsWith(">")) {
      const cita: string[] = [];
      while (i < lineas.length && en(i).trimStart().startsWith(">")) {
        cita.push(en(i++).trimStart().replace(/^>\s?/, ""));
      }
      out.push(
        <div key={k++} className="border-l-2 border-primary/40 pl-3 text-muted-foreground">
          {bloques(cita.join("\n"))}
        </div>,
      );
      continue;
    }

    // Párrafo: hasta una línea vacía o el comienzo de otro bloque. Cada salto
    // de línea se respeta (la IA los usa como tales).
    const parrafo: string[] = [];
    while (
      i < lineas.length &&
      en(i).trim() &&
      !RE_TITULO.test(en(i)) &&
      !RE_SEPARADOR.test(en(i)) &&
      !RE_LISTA.test(en(i)) &&
      !en(i).trim().startsWith("```") &&
      !en(i).trimStart().startsWith(">") &&
      !empiezaTabla(i)
    ) {
      parrafo.push(en(i++).trim());
    }
    // Nunca quedarse en la misma línea: si ningún bloque la tomó, va sola.
    if (!parrafo.length) parrafo.push(en(i++).trim());
    out.push(
      <p key={k++}>
        {parrafo.map((l, j) => (
          <Fragment key={j}>
            {j > 0 && <br />}
            {enLinea(l)}
          </Fragment>
        ))}
      </p>,
    );
  }
  return out;
}

function celdas(linea: string) {
  return linea
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split(/(?<!\\)\|/)
    .map((c) => c.trim().replace(/\\\|/g, "|"));
}

function Tabla({
  encabezado,
  alineacion,
  filas,
}: {
  encabezado: string[];
  alineacion: Alineacion[];
  filas: string[][];
}) {
  return (
    <div className="scrollbar-fino overflow-x-auto rounded-xl border border-border">
      <table className="w-full border-collapse text-xs">
        <thead className="bg-muted/70">
          <tr>
            {encabezado.map((c, j) => (
              <th
                key={j}
                style={{ textAlign: alineacion[j] ?? "left" }}
                className="whitespace-nowrap px-2.5 py-1.5 font-semibold"
              >
                {enLinea(c)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {filas.map((f, i) => (
            <tr key={i} className="border-t border-border even:bg-muted/30">
              {encabezado.map((_, j) => (
                <td
                  key={j}
                  style={{ textAlign: alineacion[j] ?? "left" }}
                  className="px-2.5 py-1.5 align-top tabular-nums"
                >
                  {enLinea(f[j] ?? "")}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* En línea                                                                    */
/* -------------------------------------------------------------------------- */

const RE_EN_LINEA =
  /(`[^`]+`)|(\*\*(?=\S)[\s\S]*?\S\*\*)|(__(?=\S)[\s\S]*?\S__)|(\[[^\]]+\]\(https?:\/\/[^)\s]+\))|(\*(?=\S)[^*]*?\S\*)|((?<![\p{L}\p{N}])_(?=\S)[^_]*?\S_(?![\p{L}\p{N}]))/gu;

function enLinea(texto: string): ReactNode[] {
  const out: ReactNode[] = [];
  let ultimo = 0;
  let k = 0;
  for (const m of texto.matchAll(RE_EN_LINEA)) {
    const desde = m.index ?? 0;
    if (desde > ultimo) out.push(texto.slice(ultimo, desde));
    const t = m[0];
    if (m[1]) {
      out.push(
        <code key={k++} className="rounded bg-muted px-1 py-0.5 font-mono text-[0.88em]">
          {t.slice(1, -1)}
        </code>,
      );
    } else if (m[2] || m[3]) {
      out.push(
        <strong key={k++} className="font-semibold">
          {enLinea(t.slice(2, -2))}
        </strong>,
      );
    } else if (m[4]) {
      const enlace = /^\[([^\]]+)\]\((.+)\)$/.exec(t);
      out.push(
        <a
          key={k++}
          href={enlace?.[2]}
          target="_blank"
          rel="noopener noreferrer"
          className="font-medium text-primary underline underline-offset-2"
        >
          {enLinea(enlace?.[1] ?? t)}
        </a>,
      );
    } else {
      out.push(<em key={k++}>{enLinea(t.slice(1, -1))}</em>);
    }
    ultimo = desde + t.length;
  }
  if (ultimo < texto.length) out.push(texto.slice(ultimo));
  return out;
}
