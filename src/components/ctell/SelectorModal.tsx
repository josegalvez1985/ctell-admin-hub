import { Check, ChevronsUpDown, Loader2, Plus, Search } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ApiError } from "@/lib/api";
import { cn } from "@/lib/utils";

export type OpcionSelector = {
  valor: string;
  etiqueta: string;
  /**
   * Texto secundario, chico y gris — el código de país, el RUC de una persona.
   * `| undefined` explícito porque `exactOptionalPropertyTypes` distingue "la
   * propiedad no está" de "está en undefined", y los llamadores la arman con
   * `x.campo ?? undefined` desde un campo nullable de la API.
   */
  descripcion?: string | undefined;
  /**
   * Tercera línea, para lo que no entra en `descripcion`: la marca y los
   * códigos equivalentes de un artículo, por ejemplo.
   *
   * Existe porque `descripcion` va en UNA línea truncada —es corta y de apoyo—
   * y hay datos que hay que poder leer enteros para reconocer la opción. Ésta
   * se parte en hasta dos renglones.
   *
   * La búsqueda del selector la mira igual que a las otras dos: lo que se
   * muestra se puede tipear.
   */
  detalle?: string | undefined;
};

/**
 * Alta al vuelo de una opción que falta, sin salir del formulario.
 *
 * El caso: se está cargando un artículo y su marca todavía no existe. Sin esto
 * hay que descartar lo escrito, ir a /marcas, crearla y volver a empezar.
 *
 * **Pide un solo campo.** Es lo que sirve para un catálogo simple —marca,
 * categoría— donde el resto de los datos son opcionales o tienen default. Una
 * entidad con varios campos obligatorios necesita su propio diálogo: forzarla
 * acá crearía filas a medio llenar que después hay que ir a completar.
 *
 * El llamador arma el `crear`: llama a su endpoint, invalida la query del
 * catálogo y devuelve la opción ya lista. El selector no sabe de queries.
 */
export type CampoAlta = {
  /** Clave con la que el valor llega a `crear`. */
  nombre: string;
  etiqueta: string;
  placeholder?: string | undefined;
  /** `numero` muestra el teclado numérico y valida que sea un número. */
  tipo?: "texto" | "numero";
  /** Por defecto obligatorio. Un campo opcional puede quedar vacío. */
  opcional?: boolean;
};

export type AltaRapida = {
  /** Título del diálogo. "Nueva marca". */
  titulo: string;
  /** Línea de ayuda. Útil para avisar a qué sucursal o empresa se crea. */
  descripcion?: string | undefined;
  /**
   * Los campos del alta. **Pocos y sólo los obligatorios**: esto es un atajo
   * para no perder lo cargado, no un reemplazo del ABM. Lo demás se completa
   * después desde la pantalla de la entidad.
   *
   * El texto que se venía buscando precarga el PRIMERO.
   */
  campos: CampoAlta[];
  /**
   * Crea la entidad y devuelve la opción, que queda **seleccionada**. Recibe
   * los valores por el `nombre` de cada campo. Si algo falla, lanzar: el
   * selector muestra el mensaje y deja el diálogo abierto con lo tipeado.
   */
  crear: (valores: Record<string, string>) => Promise<OpcionSelector>;
};

/**
 * Selector de un valor de otra tabla, en MODAL PROPIO.
 *
 * Es el componente estándar del proyecto para toda lista de valores: FK de un
 * formulario, filtro de columna, cualquier "elegí uno de estos". Reemplazó al
 * `Combobox` de popover en todas las pantallas.
 *
 * **El modal se usa siempre, aunque la lista traiga un solo ítem.** Es una
 * decisión de consistencia, no de tamaño: si el control cambiara de forma según
 * cuántas filas haya, la misma acción se vería distinta en cada pantalla y
 * habría que aprender dos interacciones para lo mismo. Un popover angosto y
 * pegado al campo tampoco deja lugar para la búsqueda y las dos líneas por fila.
 *
 * No pide datos: recibe `opciones` ya armadas, igual que el Combobox. Para una
 * tabla cuyo listado viene PAGINADO no sirve —vería sólo la primera página— y
 * hay que usar un selector que consulte al servidor, como
 * [SelectorArticulo](./SelectorArticulo.tsx).
 */
export function SelectorModal({
  opciones,
  value,
  onChange,
  placeholder = "Elegí una opción",
  buscarPlaceholder = "Buscar…",
  vacioTexto = "Sin resultados.",
  titulo = "Elegí una opción",
  descripcion,
  cargando = false,
  disabled = false,
  className,
  alta,
}: {
  opciones: OpcionSelector[];
  value: string;
  onChange: (valor: string) => void;
  placeholder?: string;
  buscarPlaceholder?: string;
  vacioTexto?: string;
  /** Título del modal. Por defecto genérico; conviene nombrar la entidad. */
  titulo?: string;
  /** Línea de ayuda bajo el título. Se omite si no se pasa. */
  descripcion?: string | undefined;
  cargando?: boolean;
  disabled?: boolean;
  /** Clases del botón que abre el modal — el login lo necesita en h-12. */
  className?: string;
  /**
   * Con esto, el selector deja crear la opción que falta sin salir de la
   * pantalla: aparece un botón "+" al lado y otro dentro del modal. Sin esto,
   * el selector se comporta como siempre.
   */
  alta?: AltaRapida | undefined;
}) {
  const [abierto, setAbierto] = useState(false);
  // El texto con el que arranca el alta. Cuando se crea desde el modal de la
  // lista, es lo que la persona ya había tipeado en el buscador: no tiene por
  // qué escribirlo dos veces.
  const [creandoCon, setCreandoCon] = useState<string | null>(null);
  const seleccionada = opciones.find((o) => o.valor === value);

  const boton = (
    <Button
      type="button"
      variant="outline"
      role="combobox"
      aria-expanded={abierto}
      disabled={disabled || cargando}
      onClick={() => setAbierto(true)}
      className={cn(
        // `h-auto` + `min-h-9` y no la altura fija del Button: una etiqueta
        // larga necesita dos líneas, y con `h-9` el texto se salía del borde.
        // `whitespace-normal` anula el `whitespace-nowrap` de la clase base,
        // que es lo que impedía el salto de línea.
        "h-auto min-h-9 w-full justify-between whitespace-normal py-1.5 text-left font-normal",
        className,
      )}
      // El `title` deja leer el nombre completo al pasar el mouse aunque las
      // dos líneas no alcancen para mostrarlo entero.
      {...(seleccionada ? { title: seleccionada.etiqueta } : {})}
    >
      {/* `min-w-0` es lo que permite que el span se achique por debajo de su
            contenido: sin él, un nombre de artículo largo estiraba el botón y
            desbordaba el diálogo en vez de partirse. `line-clamp-2` lo deja
            crecer hasta dos líneas y recién ahí corta, para que el botón no se
            estire sin techo con un nombre muy largo. */}
      <span
        className={cn(
          "line-clamp-2 min-w-0 flex-1 break-words",
          !seleccionada && "text-muted-foreground",
        )}
      >
        {cargando ? "Cargando…" : (seleccionada?.etiqueta ?? placeholder)}
      </span>
      <ChevronsUpDown className="ml-2 size-4 shrink-0 self-center opacity-50" />
    </Button>
  );

  return (
    <>
      {/* Con alta rápida, el "+" va PEGADO al selector y no dentro del modal
          solamente: quien ya sabe que la marca no existe no tiene por qué abrir
          la lista y buscarla para descubrirlo. */}
      {alta ? (
        <div className="flex items-start gap-2">
          {boton}
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="min-h-9 shrink-0"
            disabled={disabled || cargando}
            onClick={() => setCreandoCon("")}
            title={alta.titulo}
            aria-label={alta.titulo}
          >
            <Plus className="size-4" />
          </Button>
        </div>
      ) : (
        boton
      )}

      <ListaEnModal
        abierto={abierto}
        onCerrar={() => setAbierto(false)}
        opciones={opciones}
        value={value}
        onElegir={(v) => {
          onChange(v);
          setAbierto(false);
        }}
        titulo={titulo}
        {...(descripcion !== undefined ? { descripcion } : {})}
        buscarPlaceholder={buscarPlaceholder}
        vacioTexto={vacioTexto}
        // El texto buscado arranca el alta: si alguien escribió "Sakura" y no
        // aparece, lo más probable es que quiera crear justamente eso.
        {...(alta ? { onCrear: (termino: string) => setCreandoCon(termino) } : {})}
        {...(alta ? { textoCrear: alta.titulo } : {})}
      />

      {alta && (
        <DialogoAltaRapida
          alta={alta}
          valorInicial={creandoCon}
          onCerrar={() => setCreandoCon(null)}
          onCreada={(opcion) => {
            // Queda elegida: crearla y tener que buscarla después sería la
            // mitad del trabajo.
            onChange(opcion.valor);
            setCreandoCon(null);
            setAbierto(false);
          }}
        />
      )}
    </>
  );
}

/**
 * El diálogo del alta rápida.
 *
 * `valorInicial` en null es "cerrado"; con un string —aunque sea vacío— se
 * abre, y ese texto precarga el primer campo. Así el mismo estado dice si está
 * abierto y con qué arranca.
 */
export function DialogoAltaRapida({
  alta,
  valorInicial,
  onCerrar,
  onCreada,
}: {
  alta: AltaRapida;
  valorInicial: string | null;
  onCerrar: () => void;
  onCreada: (opcion: OpcionSelector) => void;
}) {
  const [valores, setValores] = useState<Record<string, string>>({});
  const [guardando, setGuardando] = useState(false);

  // Se rellena al abrir y no en el estado inicial: el diálogo se monta una vez
  // y se reusa, así que sin esto la segunda vez mostraría lo de la primera.
  useEffect(() => {
    if (valorInicial === null) return;
    const inicial: Record<string, string> = {};
    alta.campos.forEach((campo, i) => {
      inicial[campo.nombre] = i === 0 ? valorInicial : "";
    });
    setValores(inicial);
  }, [valorInicial, alta.campos]);

  /** Todos los obligatorios con algo cargado. */
  const completo = alta.campos.every(
    (campo) => campo.opcional === true || (valores[campo.nombre] ?? "").trim() !== "",
  );

  async function guardar() {
    if (!completo || guardando) return;
    setGuardando(true);
    try {
      // Se recortan acá y no en cada llamador: ninguno quiere guardar el
      // espacio que quedó al final de lo tipeado.
      const limpios: Record<string, string> = {};
      for (const campo of alta.campos) limpios[campo.nombre] = (valores[campo.nombre] ?? "").trim();

      const opcion = await alta.crear(limpios);
      toast.success(`${alta.titulo}: "${opcion.etiqueta}"`);
      onCreada(opcion);
    } catch (error) {
      // El diálogo NO se cierra: lo tipeado se conserva para corregirlo. Un
      // 409 por duplicado es el caso típico y el mensaje del backend dice qué
      // hacer.
      toast.error(error instanceof ApiError ? error.message : "No se pudo crear");
    } finally {
      setGuardando(false);
    }
  }

  return (
    <Dialog open={valorInicial !== null} onOpenChange={(a) => !a && onCerrar()}>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>{alta.titulo}</DialogTitle>
          <DialogDescription>
            {alta.descripcion ??
              "Se crea y queda elegida. Los demás datos se completan después desde su propia pantalla."}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          {alta.campos.map((campo, i) => (
            <div key={campo.nombre} className="space-y-2">
              <Label htmlFor={`alta-${campo.nombre}`}>{campo.etiqueta}</Label>
              <Input
                id={`alta-${campo.nombre}`}
                autoFocus={i === 0}
                type={campo.tipo === "numero" ? "number" : "text"}
                value={valores[campo.nombre] ?? ""}
                onChange={(e) =>
                  setValores((previos) => ({ ...previos, [campo.nombre]: e.target.value }))
                }
                {...(campo.placeholder !== undefined ? { placeholder: campo.placeholder } : {})}
                // Enter guarda. NO es un <form>: esto vive dentro del formulario
                // de la pantalla, y un form anidado no es HTML válido — el
                // submit del de adentro dispararía el de afuera y guardaría el
                // registro entero.
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    void guardar();
                  }
                }}
                autoComplete="off"
              />
            </div>
          ))}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={onCerrar}>
            Cancelar
          </Button>
          <Button type="button" onClick={() => void guardar()} disabled={!completo || guardando}>
            {guardando && <Loader2 className="size-4 animate-spin" />}
            Crear
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/**
 * El modal con el buscador y la lista. Se exporta porque el filtro de columna
 * (`TableHeadFiltrable`) lo abre desde su propio botón —el embudo del
 * encabezado— en vez del botón de arriba.
 *
 * La búsqueda filtra por etiqueta Y descripción, no por `valor`: el valor suele
 * ser un id, y tipear "Central" no encontraría nada si se comparara contra "12".
 */
export function ListaEnModal({
  abierto,
  onCerrar,
  opciones,
  value,
  onElegir,
  titulo,
  descripcion,
  buscarPlaceholder = "Buscar…",
  vacioTexto = "Sin resultados.",
  onCrear,
  textoCrear = "Crear",
}: {
  abierto: boolean;
  onCerrar: () => void;
  opciones: OpcionSelector[];
  value: string;
  onElegir: (valor: string) => void;
  titulo: string;
  descripcion?: string | undefined;
  buscarPlaceholder?: string;
  vacioTexto?: string;
  /** Recibe lo que se estaba buscando, para arrancar el alta con ese texto. */
  onCrear?: ((termino: string) => void) | undefined;
  /** Rótulo del botón cuando no hay término. "Nueva marca". */
  textoCrear?: string;
}) {
  const [busqueda, setBusqueda] = useState("");

  // El término se limpia al cerrar: reabrir con el filtro anterior puesto haría
  // creer que faltan opciones.
  useEffect(() => {
    if (!abierto) setBusqueda("");
  }, [abierto]);

  const termino = busqueda.trim().toLowerCase();
  const filtradas = useMemo(() => {
    if (termino === "") return opciones;
    // Las TRES líneas, no sólo la etiqueta: la regla es que todo lo que la
    // opción muestra se pueda tipear. Un dato visible que no filtra se lee como
    // que el selector no lo encuentra.
    return opciones.filter((o) =>
      `${o.etiqueta} ${o.descripcion ?? ""} ${o.detalle ?? ""}`.toLowerCase().includes(termino),
    );
  }, [opciones, termino]);

  return (
    <Dialog open={abierto} onOpenChange={(a) => !a && onCerrar()}>
      {/* `max-w-lg` y no `max-w-md`: las opciones suelen ser nombres de
          artículo, que con 28rem se cortaban a mitad de palabra. `max-w-[95vw]`
          lo mantiene dentro de la pantalla en móvil. */}
      <DialogContent className="flex max-h-[85vh] max-w-[95vw] flex-col sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{titulo}</DialogTitle>
          {descripcion && <DialogDescription>{descripcion}</DialogDescription>}
        </DialogHeader>

        {/* El buscador se muestra desde unas pocas opciones: con tres o cuatro
            ocupa más de lo que ayuda, y la lista entra entera en pantalla. */}
        {opciones.length > 6 && (
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              autoFocus
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
              placeholder={buscarPlaceholder}
              className="pl-9"
            />
          </div>
        )}

        <div className="-mx-1 min-h-0 flex-1 overflow-y-auto px-1">
          {filtradas.length === 0 ? (
            <div className="py-8 text-center">
              <p className="text-sm text-muted-foreground">{vacioTexto}</p>
              {/* Justo donde se descubre que falta: buscar algo y no encontrarlo
                  es el momento exacto en que hace falta crearlo. */}
              {onCrear && termino !== "" && (
                <Button
                  type="button"
                  variant="outline"
                  className="mt-4"
                  onClick={() => onCrear(busqueda.trim())}
                >
                  <Plus className="size-4" />
                  Crear "{busqueda.trim()}"
                </Button>
              )}
            </div>
          ) : (
            filtradas.map((opcion) => {
              const elegida = opcion.valor === value;
              return (
                <button
                  key={opcion.valor}
                  type="button"
                  onClick={() => onElegir(opcion.valor)}
                  className={cn(
                    "flex w-full items-center gap-2 rounded-md px-2 py-2 text-left text-sm transition-colors hover:bg-accent",
                    elegida && "bg-accent",
                  )}
                >
                  <Check className={cn("size-4 shrink-0", elegida ? "opacity-100" : "opacity-0")} />
                  {/* La etiqueta se PARTE en varias líneas en vez de truncarse:
                      acá es donde hay que poder leer el nombre entero para
                      elegir, y dos artículos con el mismo prefijo largo se
                      veían idénticos cortados. La descripción sí sigue en una
                      línea: es corta y de apoyo. */}
                  <span className="flex min-w-0 flex-1 flex-col">
                    <span className="break-words">{opcion.etiqueta}</span>
                    {opcion.descripcion && (
                      <span className="truncate text-xs text-muted-foreground">
                        {opcion.descripcion}
                      </span>
                    )}
                    {/* El detalle SÍ se parte, hasta dos renglones: lleva los
                        datos largos —marca, códigos equivalentes— que hay que
                        leer enteros para reconocer la opción. Va más apagado
                        que la descripción para que la jerarquía se mantenga. */}
                    {opcion.detalle && (
                      <span className="line-clamp-2 break-words text-xs text-muted-foreground/80">
                        {opcion.detalle}
                      </span>
                    )}
                  </span>
                </button>
              );
            })
          )}
        </div>

        {/* Al pie y fuera del área que scrollea: con una lista larga, un botón
            al final de las opciones no se ve nunca. */}
        {onCrear && filtradas.length > 0 && (
          <Button
            type="button"
            variant="outline"
            className="w-full"
            onClick={() => onCrear(busqueda.trim())}
          >
            <Plus className="size-4" />
            {textoCrear}
          </Button>
        )}
      </DialogContent>
    </Dialog>
  );
}
