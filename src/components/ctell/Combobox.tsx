import { Check, ChevronsUpDown } from "lucide-react";
import { useState } from "react";

import { Button } from "@/components/ui/button";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { cn } from "@/lib/utils";

export type ComboboxOpcion = {
  valor: string;
  etiqueta: string;
  /**
   * Texto secundario, chico y gris — para el código de país, el módulo, etc.
   * `| undefined` explícito porque `exactOptionalPropertyTypes` distingue
   * "la propiedad no está" de "está con valor undefined": el caller arma
   * estas opciones con `p.codigoPais ?? undefined` desde un campo nullable de
   * la API, y eso es undefined explícito, no una key ausente.
   */
  descripcion?: string | undefined;
};

/**
 * Encuentra la opción a la que corresponde un value emitido por cmdk.
 *
 * cmdk normaliza el `value` de cada CommandItem —lo pasa a minúsculas y le
 * recorta los espacios— tanto al filtrar como al seleccionar. Comparar ese
 * valor contra `opcion.valor` crudo funciona de casualidad mientras los
 * valores sean numéricos o ya vengan en minúscula, y falla en silencio en
 * cuanto uno tiene mayúsculas: la opción no se encuentra, el filtro la
 * descarta y al elegirla se emite un id que el consumidor no reconoce.
 */
function buscarOpcion(
  opciones: ComboboxOpcion[],
  valorNormalizado: string,
): ComboboxOpcion | undefined {
  const buscado = valorNormalizado.trim().toLowerCase();
  return opciones.find((o) => o.valor.trim().toLowerCase() === buscado);
}

/**
 * Selector con buscador para listas de valores (país, módulo, cualquier FK).
 *
 * Reemplaza al `<Select>` simple de shadcn en los formularios: un `<Select>`
 * nativo no filtra sus opciones, así que una lista de 200 países se vuelve
 * inmanejable para quien busca "Par" y tiene que scrollear a mano hasta
 * Paraguay. Acá el popover se abre con un input arriba que filtra en vivo.
 *
 * Es sólo el control — no pide datos ni sabe de países ni de departamentos.
 * Quien lo usa arma `opciones` a partir de lo que ya haya cargado con
 * useQuery, igual que se hacía con SelectItem antes.
 */
export function Combobox({
  opciones,
  value,
  onChange,
  placeholder = "Elegí una opción",
  buscarPlaceholder = "Buscar…",
  vacioTexto = "Sin resultados.",
  cargando = false,
  disabled = false,
}: {
  opciones: ComboboxOpcion[];
  value: string;
  onChange: (valor: string) => void;
  placeholder?: string;
  buscarPlaceholder?: string;
  vacioTexto?: string;
  cargando?: boolean;
  disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const seleccionada = opciones.find((o) => o.valor === value);

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          type="button"
          variant="outline"
          role="combobox"
          aria-expanded={open}
          disabled={disabled || cargando}
          className="w-full justify-between font-normal"
        >
          <span className={cn("truncate", !seleccionada && "text-muted-foreground")}>
            {cargando ? "Cargando…" : (seleccionada?.etiqueta ?? placeholder)}
          </span>
          <ChevronsUpDown className="ml-2 size-4 shrink-0 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-(--radix-popover-trigger-width) p-0" align="start">
        <Command
          filter={(itemValue, search) => {
            // cmdk filtra por el `value` del CommandItem, pero ese `value` es
            // el id (para poder mapearlo de vuelta) — no lo que la persona lee
            // en pantalla. Se busca contra la etiqueta visible, si no "1"
            // nunca matchearía con "Argentina".
            //
            // El itemValue llega normalizado por cmdk (minúsculas y sin
            // espacios en los extremos), así que la comparación contra el
            // valor original tiene que normalizar de este lado también: sin
            // esto, cualquier opción cuyo valor no sea ya minúscula no se
            // encuentra y termina filtrada como si no matcheara nunca.
            const opcion = buscarOpcion(opciones, itemValue);
            const texto = `${opcion?.etiqueta ?? ""} ${opcion?.descripcion ?? ""}`.toLowerCase();
            return texto.includes(search.toLowerCase()) ? 1 : 0;
          }}
        >
          <CommandInput placeholder={buscarPlaceholder} />
          <CommandList>
            <CommandEmpty>{vacioTexto}</CommandEmpty>
            <CommandGroup>
              {opciones.map((opcion) => (
                <CommandItem
                  key={opcion.valor}
                  value={opcion.valor}
                  onSelect={(valorElegido) => {
                    // cmdk devuelve el value normalizado, no el original: hay
                    // que mapearlo de vuelta antes de propagarlo. Si se
                    // emitiera tal cual, el consumidor recibiría un id que no
                    // existe en su lista y el filtro no cambiaría nada.
                    onChange(buscarOpcion(opciones, valorElegido)?.valor ?? valorElegido);
                    setOpen(false);
                  }}
                >
                  <Check
                    className={cn("size-4", value === opcion.valor ? "opacity-100" : "opacity-0")}
                  />
                  <div className="flex min-w-0 flex-1 flex-col">
                    <span className="truncate">{opcion.etiqueta}</span>
                    {opcion.descripcion && (
                      <span className="truncate text-xs text-muted-foreground">
                        {opcion.descripcion}
                      </span>
                    )}
                  </div>
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
