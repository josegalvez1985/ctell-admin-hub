import { useLayoutEffect, useRef, type ComponentProps } from "react";

import { Input } from "@/components/ui/input";
import { contarSignificativos, posicionTrasFormatear, separarMiles } from "@/lib/moneda";
import { cn } from "@/lib/utils";

type Props = Omit<ComponentProps<typeof Input>, "value" | "onChange" | "type"> & {
  /** El texto del monto. Se muestra siempre separado, venga como venga. */
  value: string;
  /** Recibe el texto **ya formateado** ("34.200"). Parsear con `numeroMoneda`. */
  onChange: (valor: string) => void;
};

/**
 * Campo de monto que separa los miles **mientras se escribe**.
 *
 * POR QUÉ NO ALCANZA CON FORMATEAR EN `onBlur`, que es como estaba: el número
 * sólo se lee bien al salir del campo, justo cuando ya se dejó de mirar. Quien
 * carga un monto largo lo cuenta con el dedo en la pantalla — y ahí es donde
 * "34200" y "342000" se confunden.
 *
 * EL PROBLEMA REAL ES EL CURSOR: reformatear en cada tecla reemplaza el valor
 * del input, y el navegador manda el cursor al final. Si se corrige un dígito
 * en el medio de "1.234.567", el cursor salta y el siguiente carácter se
 * escribe en el lugar equivocado. Se resuelve contando los caracteres
 * significativos a la izquierda del cursor —dígitos y coma, lo único que
 * sobrevive al formateo— y reubicándolo después de esa misma cantidad.
 *
 * El reposicionamiento va en `useLayoutEffect` y no en el `onChange`: el valor
 * lo controla el padre, así que recién después de que React pinta el nuevo
 * texto tiene sentido mover el cursor. Hacerlo antes lo ubica sobre el texto
 * viejo y el salto vuelve.
 */
export function InputMoneda({ value, onChange, className, ref: refExterno, ...resto }: Props) {
  const ref = useRef<HTMLInputElement>(null);
  const cursorPendiente = useRef<number | null>(null);

  // El componente necesita su propio ref para mover el cursor, pero no puede
  // quedarse con él: react-hook-form pasa el suyo para enfocar el campo cuando
  // la validación falla, y pisarlo dejaría el foco en la nada.
  const asignarRef = (nodo: HTMLInputElement | null) => {
    ref.current = nodo;
    if (typeof refExterno === "function") refExterno(nodo);
    else if (refExterno) refExterno.current = nodo;
  };

  useLayoutEffect(() => {
    if (cursorPendiente.current === null || ref.current === null) return;
    ref.current.setSelectionRange(cursorPendiente.current, cursorPendiente.current);
    cursorPendiente.current = null;
  });

  return (
    <Input
      {...resto}
      ref={asignarRef}
      // `text` y no `number`: un input numérico nativo rechaza "34.200" y
      // además no deja leer ni mover el cursor, que es todo lo que necesitamos.
      type="text"
      inputMode="decimal"
      // Tabulares para que los dígitos queden alineados y la cifra se lea de
      // un golpe, igual que en las tablas de importes.
      className={cn("tabular-nums", className)}
      value={separarMiles(value)}
      onChange={(e) => {
        const escrito = e.target.value;
        const significativos = contarSignificativos(
          escrito.slice(0, e.target.selectionStart ?? escrito.length),
        );
        const formateado = separarMiles(escrito);
        cursorPendiente.current = posicionTrasFormatear(formateado, significativos);
        onChange(formateado);
      }}
    />
  );
}
