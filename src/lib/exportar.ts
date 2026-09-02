/**
 * Exportar un listado a Excel y a PDF, en un solo lugar.
 *
 * Las dos salidas se describen con las MISMAS columnas: se declara una vez qué
 * se muestra y de dónde sale, y de ahí salen el `.xlsx` y el `.pdf`. Definirlas
 * dos veces era garantía de que en algún momento el Excel tuviera una columna
 * que el PDF no, sin que nadie lo notara hasta cruzar los dos archivos.
 *
 * Las dos librerías entran con `import()` dinámico: pesan cerca de un mega
 * entre las dos y no se usan hasta que alguien aprieta el botón. Con un import
 * normal viajarían en el bundle inicial y las pagaría también quien nunca
 * exporta nada.
 */

/**
 * Una columna de la exportación.
 *
 * `valor` devuelve el dato ya resuelto para esa fila —no el nombre de un
 * campo— porque casi ninguna columna sale de una propiedad plana: hay que
 * traducir un "A" a "Activo", concatenar la unidad de medida o caer en un
 * texto cuando el campo es null.
 */
export type ColumnaExport<T> = {
  titulo: string;
  /**
   * El dato de la fila. Devolver `number` y no el número ya formateado es lo
   * que hace que en Excel entre como número y se pueda sumar; un "1.234"
   * formateado entra como texto y rompe cualquier fórmula.
   */
  valor: (fila: T) => string | number | null;
  /** Alinea a la derecha en el PDF y fija el formato numérico en Excel. */
  numerica?: boolean;
  /** Ancho de la columna en Excel, en caracteres. */
  ancho?: number;
};

/** Fecha y hora del momento, para el nombre del archivo y el pie del reporte. */
function marcaDeTiempo() {
  const ahora = new Date();
  const dosDigitos = (n: number) => String(n).padStart(2, "0");
  return {
    /** "2026-08-28" — ordena solo al listarse en la carpeta de Descargas. */
    archivo: `${ahora.getFullYear()}-${dosDigitos(ahora.getMonth() + 1)}-${dosDigitos(ahora.getDate())}`,
    /** "28/08/2026 15:42" — para que quede impreso cuándo se sacó el reporte. */
    legible: new Intl.DateTimeFormat("es-PY", {
      dateStyle: "short",
      timeStyle: "short",
    }).format(ahora),
  };
}

/**
 * Descarga el listado como un `.xlsx` de verdad.
 *
 * No es un CSV renombrado: las cantidades entran como números y se pueden sumar
 * en la planilla sin tocarlas. Un CSV con separador `;` también abre en Excel,
 * pero cada número queda como texto y ordenar por existencia daría 10 antes
 * que 9.
 */
export async function descargarExcel<T>({
  nombreArchivo,
  hoja = "Datos",
  columnas,
  filas,
}: {
  /** Sin extensión ni fecha: las agrega esta función. */
  nombreArchivo: string;
  hoja?: string;
  columnas: ColumnaExport<T>[];
  filas: T[];
}): Promise<void> {
  // El subpath `/browser` y no el paquete pelado: la raíz no exporta nada, y
  // `/node` escribe en el sistema de archivos con APIs que en el navegador no
  // existen. Esta es la build que arma el archivo en memoria y lo descarga.
  const { default: writeXlsxFile } = await import("write-excel-file/browser");

  const columns = columnas.map((columna) => ({
    header: { value: columna.titulo, fontWeight: "bold" as const },
    width: columna.ancho ?? 22,
    cell: (fila: T) => {
      const bruto = columna.valor(fila);
      // null y no "" para la celda sin dato: una cadena vacía deja la celda
      // "ocupada" con texto y los filtros de Excel la cuentan como un valor.
      if (bruto === null || bruto === "") return null;
      // El `type` tiene que coincidir con lo que va en `value` o la librería
      // escribe la celda vacía sin avisar. Por eso se normaliza acá y no en
      // cada pantalla.
      return columna.numerica
        ? { value: Number(bruto), type: Number }
        : { value: String(bruto), type: String };
    },
  }));

  // La v4 devuelve `{ toBlob, toFile }` en vez de aceptar un `fileName` entre
  // las opciones, y las columnas se declaran en `columns` —el `schema` de las
  // versiones viejas ya no existe—. Los ejemplos que andan dando vueltas siguen
  // siendo los de la v1.
  await writeXlsxFile(filas, { columns, sheet: hoja }).toFile(
    `${nombreArchivo}-${marcaDeTiempo().archivo}.xlsx`,
  );
}

/**
 * El logo, como data URL, o `null` si no se pudo traer.
 *
 * jsPDF **no acepta una URL**: necesita los bytes. Se baja con `fetch` y se pasa
 * a base64 con `FileReader`.
 *
 * **Nunca lanza.** Un reporte sin logo es un reporte igual de válido; uno que no
 * se genera porque la imagen dio 404 no le sirve a nadie. Los tres motivos por
 * los que puede fallar —la empresa no tiene logo cargado, el endpoint todavía no
 * está publicado en APEX, o la red— terminan en el mismo lugar: se sigue sin él.
 *
 * Devuelve también las dimensiones: hacen falta para escalar sin deformar, y
 * salen de un `Image` porque el PDF no sabe cuánto mide un PNG.
 */
async function traerLogo(
  url: string,
): Promise<{ datos: string; ancho: number; alto: number } | null> {
  try {
    const respuesta = await fetch(url);
    if (!respuesta.ok) return null;

    const blob = await respuesta.blob();
    // Un blob vacío no es una imagen: el endpoint puede devolver 200 con cero
    // bytes si la columna está en NULL.
    if (blob.size === 0) return null;

    const datos = await new Promise<string>((resolver, rechazar) => {
      const lector = new FileReader();
      lector.onload = () => resolver(String(lector.result));
      lector.onerror = () => rechazar(new Error("No se pudo leer el logo"));
      lector.readAsDataURL(blob);
    });

    const medidas = await new Promise<{ ancho: number; alto: number }>((resolver, rechazar) => {
      const imagen = new Image();
      imagen.onload = () => resolver({ ancho: imagen.naturalWidth, alto: imagen.naturalHeight });
      imagen.onerror = () => rechazar(new Error("El logo no es una imagen legible"));
      imagen.src = datos;
    });

    if (medidas.ancho === 0 || medidas.alto === 0) return null;
    return { datos, ...medidas };
  } catch {
    return null;
  }
}

/**
 * Arma el PDF y lo abre en una pestaña nueva, con el visor del navegador.
 *
 * **La pestaña se abre ANTES de generar nada.** Los bloqueadores de ventanas
 * emergentes sólo dejan pasar un `window.open` que ocurre dentro del click; si
 * se lo llama después de un `await` —cargar la librería, pedirle las filas al
 * servidor— el navegador ya no lo asocia al gesto y lo bloquea en silencio. Por
 * eso `filas` acepta una función: primero se abre la pestaña, recién después se
 * traen los datos.
 *
 * Si aun así quedó bloqueada, el PDF se descarga. Es peor que la pestaña, y
 * mucho mejor que un botón que no hace nada.
 *
 * Ojo con los símbolos: las fuentes que jsPDF trae de fábrica cubren el
 * alfabeto latino con acentos y la ñ, pero **no el guaraní** (₲), que saldría
 * como un cuadrito. Para montos, poné "Gs." en el título de la columna y mandá
 * el número pelado.
 */
export async function abrirPdf<T>({
  nombreArchivo,
  titulo,
  subtitulos = [],
  columnas,
  filas,
  orientacion = "portrait",
  urlLogo,
}: {
  nombreArchivo: string;
  titulo: string;
  /** Contexto del reporte: empresa, filtros aplicados, totales. */
  subtitulos?: string[];
  columnas: ColumnaExport<T>[];
  /** Las filas, o cómo traerlas. La función corre con la pestaña ya abierta. */
  filas: T[] | (() => Promise<T[]>);
  orientacion?: "portrait" | "landscape";
  /**
   * Logo de la empresa, arriba a la derecha. `urlLogoEmpresa(empresa.id)`.
   *
   * **Opcional, y su fallo no rompe el reporte**: si la empresa no tiene logo
   * cargado o la imagen no se puede traer, el PDF sale igual sin él. Pasarla
   * sólo cuando `empresa.tieneLogo` es `true` ahorra una petición que ya se sabe
   * que va a dar 404.
   */
  urlLogo?: string | undefined;
}): Promise<void> {
  // Primera línea, y síncrona: ver el porqué en el encabezado.
  const pestania = window.open("", "_blank");
  if (pestania) {
    // Sin esto la pestaña queda en blanco todo lo que tarde la consulta y
    // parece que se colgó.
    pestania.document.write(
      '<title>Generando</title><p style="font:16px system-ui;padding:2rem">Generando el PDF…</p>',
    );
    pestania.document.close();
  }

  try {
    // El logo entra en el mismo Promise.all: es una petición más, y esperarla en
    // serie después de las filas sumaría su latencia a la espera de la pestaña.
    const [{ jsPDF }, { default: autoTable }, datos, logo] = await Promise.all([
      import("jspdf"),
      import("jspdf-autotable"),
      typeof filas === "function" ? filas() : Promise.resolve(filas),
      urlLogo ? traerLogo(urlLogo) : Promise.resolve(null),
    ]);

    const tiempo = marcaDeTiempo();
    // `orientation: orientacion` y no el atajo `{ orientation }`: escrito así
    // TypeScript no da error, pero resuelve contra `window.orientation` —una
    // global del DOM que es un número— y el PDF sale siempre en vertical.
    const doc = new jsPDF({ orientation: orientacion, unit: "pt", format: "a4" });
    const anchoPagina = doc.internal.pageSize.getWidth();

    /**
     * El logo va ARRIBA A LA DERECHA, no sobre el título.
     *
     * El título y los subtítulos crecen hacia abajo desde el margen izquierdo y
     * su alto depende de cuántos filtros haya; anclado a la derecha, el logo no
     * empuja nada y el encabezado se lee igual con uno o con cinco subtítulos.
     *
     * Se escala **por el lado más largo** para no deformarlo: un logo apaisado
     * toca el ancho máximo y uno cuadrado el alto. El techo de alto es lo que
     * mide el bloque de texto de un reporte típico, así que no desborda sobre la
     * tabla.
     */
    const LOGO_Y = 28;
    /** Dónde termina el logo. 0 sin logo, para que no afecte el `startY`. */
    let finLogo = 0;

    if (logo) {
      const MAX_ANCHO = 120;
      const MAX_ALTO = 42;
      const escala = Math.min(MAX_ANCHO / logo.ancho, MAX_ALTO / logo.alto);
      const ancho = logo.ancho * escala;
      const alto = logo.alto * escala;

      // addImage infiere el formato del data URL, así que sirve igual para PNG
      // que para JPEG — que es lo que puede haber cargado cada empresa.
      doc.addImage(logo.datos, anchoPagina - 40 - ancho, LOGO_Y, ancho, alto);
      finLogo = LOGO_Y + alto;
    }

    doc.setFont("helvetica", "bold");
    doc.setFontSize(15);
    doc.text(titulo, 40, 46);

    doc.setFont("helvetica", "normal");
    doc.setFontSize(9);
    doc.setTextColor(110);
    subtitulos.forEach((linea, i) => doc.text(linea, 40, 62 + i * 12));

    autoTable(doc, {
      // La tabla empieza debajo de LO MÁS BAJO del encabezado. Con pocos
      // subtítulos el bloque de texto es más corto que el logo, y sin este
      // `max` la primera fila se le montaba encima.
      startY: Math.max(62 + subtitulos.length * 12, finLogo) + 10,
      head: [columnas.map((c) => c.titulo)],
      body: datos.map((fila) =>
        columnas.map((c) => {
          const bruto = c.valor(fila);
          return bruto === null ? "" : String(bruto);
        }),
      ),
      styles: { fontSize: 8, cellPadding: 4, overflow: "linebreak" },
      // El azul del logo, en RGB: jsPDF no entiende las variables oklch del
      // design system, así que este es el único lugar donde el color se repite.
      headStyles: { fillColor: [19, 98, 192], textColor: 255, fontStyle: "bold" },
      // Gris muy claro en las filas pares: con treinta filas por hoja, seguir
      // una línea de punta a punta sin ninguna guía es donde se leen mal los
      // números.
      alternateRowStyles: { fillColor: [245, 247, 250] },
      columnStyles: Object.fromEntries(
        columnas.map((c, i) => [i, { halign: c.numerica ? "right" : "left" }]),
      ),
      margin: { left: 40, right: 40, bottom: 40 },
      // El pie va por página y no una sola vez al final: un reporte impreso se
      // desarma, y cada hoja suelta tiene que decir de cuándo es y cuál era.
      didDrawPage: (datosHoja) => {
        doc.setFont("helvetica", "normal");
        doc.setFontSize(8);
        doc.setTextColor(140);
        const alto = doc.internal.pageSize.getHeight();
        doc.text(`Emitido el ${tiempo.legible}`, 40, alto - 22);
        doc.text(`Página ${datosHoja.pageNumber}`, anchoPagina - 40, alto - 22, { align: "right" });
      },
    });

    const url = URL.createObjectURL(doc.output("blob"));

    if (pestania) {
      pestania.location.href = url;
    } else {
      // Bloqueada: que al menos se lleve el archivo.
      const enlace = document.createElement("a");
      enlace.href = url;
      enlace.download = `${nombreArchivo}-${tiempo.archivo}.pdf`;
      enlace.click();
    }

    // No se revoca en el acto: la pestaña todavía tiene que cargar el blob. Un
    // minuto alcanza de sobra y evita dejar el archivo en memoria toda la
    // sesión, que con reportes grandes se nota.
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
  } catch (error) {
    // La pestaña ya está abierta con el "Generando…": dejarla así sería mentir.
    if (pestania) pestania.close();
    throw error;
  }
}

/* -------------------------------------------------------------------------- */
/* Planilla mensual: la grilla de días con encabezado y totales                */
/* -------------------------------------------------------------------------- */

/**
 * Un reporte con FORMA, no una lista de filas.
 *
 * `descargarExcel` y `abrirPdf` sirven para un listado: mismas columnas, una
 * fila por registro. Una planilla mensual es otra cosa — tiene un encabezado
 * con los datos del período, columnas agrupadas de a pares (Ent./Sal.), una
 * fila por día del mes incluidos los que no tienen marcas, y un bloque de
 * totales abajo. Nada de eso entra en `ColumnaExport`.
 *
 * Por eso son funciones aparte y no un parámetro más de las otras: forzar los
 * dos formatos en una sola API dejaría una función con la mitad de los
 * parámetros ignorados según el caso.
 */
export type FilaPlanilla = {
  /**
   * Semana DEL MES a la que pertenece el día: 1 a 5, o 6.
   *
   * Viene calculada de afuera y no se deriva acá: quien arma los datos ya
   * recorrió los días del mes, y así el archivo agrupa igual que la pantalla en
   * vez de repetir la regla de corte por su cuenta.
   */
  semana: number;
  /** Número de día del mes. */
  dia: number;
  /** "Lun", "Mar"… */
  diaSemana: string;
  /** Marcas del día, en orden. Una posición vacía es un par sin usar. */
  marcas: Array<{ entrada: string | null; salida: string | null }>;
  /** Horas cátedra del día. 0 si no trabajó. */
  horas: number;
  /** Sábado o domingo: se pinta distinto. */
  finDeSemana: boolean;
};

export type DatosPlanilla = {
  profesor: string;
  institucion: string;
  /** "Junio 2026" */
  periodo: string;
  /** Minutos que dura una hora cátedra. */
  horaCatedra: number;
  precioHora: number;
  filas: FilaPlanilla[];
  /** Cuántos pares Ent./Sal. mostrar. */
  columnasMarca: number;
  totalHoras: number;
  totalImporte: number;
  /** IVA contenido en `totalImporte`, no un importe a sumarle. */
  totalIva: number;
  /**
   * Horas de cada semana del mes, por número de semana.
   *
   * Viene calculada de afuera por lo mismo que `semana` en cada fila: quien arma
   * los datos ya sumó los minutos del período, y recalcular acá partiendo de las
   * horas ya redondeadas de cada día daría un total distinto del de la pantalla.
   */
  horasPorSemana?: Map<number, number>;
  /**
   * El nombre que encabeza el bloque de resumen: "RESUMEN <empresa>".
   *
   * Opcional: sin empresa activa el bloque sale igual, sólo que rotulado
   * "RESUMEN" a secas.
   */
  nombreEmpresa?: string;
  /**
   * Renglones en blanco del bloque "Actividad extra".
   *
   * Ese bloque NO sale de la base: no hay tabla que lo respalde. Se imprime
   * vacío para completarlo a mano sobre el papel, que es como se usa hoy. En 0
   * el bloque no se dibuja.
   */
  filasActividadExtra?: number;
};

/**
 * Dónde empieza cada semana y cuántos días abarca.
 *
 * Es lo que necesitan las dos exportaciones para estirar una sola celda sobre
 * los días de su semana: `rowSpan` en Excel, `rowSpan` en autoTable. Se calcula
 * una vez acá y no en cada formato, así los dos archivos agrupan idéntico.
 */
function gruposDeSemana(filas: FilaPlanilla[]): Map<number, { inicio: number; cantidad: number }> {
  const grupos = new Map<number, { inicio: number; cantidad: number }>();
  filas.forEach((fila, i) => {
    const grupo = grupos.get(fila.semana);
    if (grupo) grupo.cantidad += 1;
    else grupos.set(fila.semana, { inicio: i, cantidad: 1 });
  });
  return grupos;
}

/** El azul del logo en RGB: jsPDF no entiende las variables oklch del tema. */
const AZUL: [number, number, number] = [19, 98, 192];
/** Amarillo suave de las celdas de carga, como la planilla de papel. */
const CREMA = "#FFF9E6";
/**
 * Rojo de las dos últimas filas del resumen: IVA y total general.
 *
 * Es un color literal y no el `--destructive` del tema: el archivo se abre en
 * Excel, donde las variables CSS no existen, y además una planilla impresa tiene
 * que verse igual sin importar si quien la generó usaba el tema claro u oscuro.
 */
const ROJO = "#C00000";
/** Celeste de la columna de totales. */
const CELESTE = "#DCE9F7";
/** Gris del fin de semana. */
const GRIS = "#EFEFEF";

/**
 * La planilla mensual como `.xlsx`, con la forma de la planilla de papel.
 *
 * Usa el modo `sheetData` de write-excel-file —filas de celdas sueltas— y no el
 * modo `columns`/`schema`: ese último produce una tabla uniforme, y acá cada
 * zona tiene su propio ancho, color y combinación de celdas.
 */
export async function descargarPlanillaExcel(
  planillas: DatosPlanilla | DatosPlanilla[],
): Promise<void> {
  // Acepta una sola o varias, igual que abrirPlanillaPdf.
  const lista = Array.isArray(planillas) ? planillas : [planillas];
  if (lista.length === 0) throw new Error("No hay planillas para exportar");

  const { default: writeXlsxFile } = await import("write-excel-file/browser");

  const armadas = lista.map(armarPlanillaExcel);
  const periodo = lista[0]?.periodo ?? "";
  const archivo = `planilla-${periodo.replace(/\s+/g, "-").toLowerCase()}-${marcaDeTiempo().archivo}.xlsx`;

  // Una hoja por profesor. Con varias hojas write-excel-file espera arreglos
  // paralelos: datos[], y `columns`/`sheets` con un elemento por hoja.
  if (armadas.length === 1) {
    const unica = armadas[0]!;
    await writeXlsxFile(unica.filas as never, {
      columns: unica.columnas,
      sheet: "Planilla",
    }).toFile(archivo);
    return;
  }

  // Acá abajo ya hay más de una planilla —la de una sola salió por el `return`
  // de arriba—, así que la hoja de resumen siempre corresponde: consolida cuánto
  // le toca a cada profesor, igual que el cuadro del pie de la pantalla. Con un
  // solo profesor no aparece, porque repetiría el total que su propia planilla
  // ya cierra.
  const consolidado = armarResumenProfesores(lista);

  await writeXlsxFile(
    [...armadas.map((p) => p.filas), consolidado.filas] as never,
    {
      columns: [...armadas.map((p) => p.columnas), consolidado.columnas],
      sheets: [...armadas.map((p, i) => nombreHoja(p.profesor, i, armadas)), "Resumen"],
    } as never,
  ).toFile(archivo);
}

/**
 * La hoja consolidada: cuánto le corresponde a cada profesor.
 *
 * Es el mismo cuadro que la pantalla muestra al pie de todas las planillas.
 * Va en su propia hoja y no al final de la última planilla porque no pertenece a
 * ninguna: cada planilla se imprime y se firma por separado, y el consolidado es
 * de quien liquida.
 *
 * **El monto de cada uno sale de SUS horas**, redondeado a guaraníes — es la
 * cifra que se le paga y no puede llevar centavos. El total suma esos montos ya
 * redondeados, que es la cuenta que alguien va a rehacer sobre el papel.
 */
function armarResumenProfesores(lista: DatosPlanilla[]): {
  filas: unknown[][];
  columnas: { width: number }[];
} {
  const filas: unknown[][] = [];

  filas.push([
    {
      value: "RESUMEN",
      fontWeight: "bold" as const,
      backgroundColor: CELESTE,
      align: "center" as const,
      columnSpan: 2,
    },
    null,
  ]);
  filas.push([
    {
      value: "PROFESORES",
      fontWeight: "bold" as const,
      backgroundColor: CELESTE,
      align: "center" as const,
    },
    {
      value: "MONTO",
      fontWeight: "bold" as const,
      backgroundColor: CELESTE,
      align: "center" as const,
    },
  ]);

  let total = 0;
  for (const p of lista) {
    const monto = Math.round(p.totalImporte);
    total += monto;
    filas.push([
      { value: p.profesor, type: String },
      { value: monto, type: Number, align: "right" as const },
    ]);
  }

  filas.push([
    { value: "TOTALES", fontWeight: "bold" as const, align: "center" as const },
    { value: total, type: Number, fontWeight: "bold" as const, align: "right" as const },
  ]);

  return { filas, columnas: [{ width: 34 }, { width: 16 }] };
}

/**
 * Nombre de hoja válido para Excel a partir del nombre del profesor.
 *
 * Excel rechaza `: \ / ? * [ ]`, corta en 31 caracteres y no admite dos hojas
 * con el mismo nombre — con dos profesores homónimos, o con nombres largos que
 * al truncarse coinciden, el archivo saldría corrupto. Por eso se desduplica
 * con un sufijo.
 */
function nombreHoja(profesor: string, indice: number, todas: { profesor: string }[]): string {
  const limpio = profesor.replace(/[:\\/?*[\]]/g, " ").trim() || `Profesor ${indice + 1}`;
  const base = limpio.slice(0, 31);
  const previos = todas
    .slice(0, indice)
    .filter((p) => (p.profesor.replace(/[:\\/?*[\]]/g, " ").trim() || "").slice(0, 31) === base);
  if (previos.length === 0) return base;
  const sufijo = ` (${previos.length + 1})`;
  return base.slice(0, 31 - sufijo.length) + sufijo;
}

/** Las filas y los anchos de UNA planilla. Extraído para poder repetirlo. */
function armarPlanillaExcel(datos: DatosPlanilla): {
  filas: unknown[][];
  columnas: { width: number }[];
  profesor: string;
} {
  const n = datos.columnasMarca;
  // Semana, Día, Fecha, (Ent./Sal.) × n, Horas, Total semana, Total mes
  const anchoTotal = 3 + n * 2 + 3;
  const semanas = gruposDeSemana(datos.filas);

  /**
   * Horas de cada semana. Si no vienen calculadas, se derivan de las filas.
   *
   * El respaldo existe para no romper a quien ya llamaba a esto sin el campo,
   * pero suma las horas YA REDONDEADAS de cada día: puede quedar un par de
   * centésimas por debajo del total real. Quien quiera el número exacto —la
   * pantalla— lo manda hecho.
   */
  const horasSemana =
    datos.horasPorSemana ??
    datos.filas.reduce((mapa, f) => {
      mapa.set(f.semana, Number(((mapa.get(f.semana) ?? 0) + f.horas).toFixed(2)));
      return mapa;
    }, new Map<number, number>());

  /** Fila de `anchoTotal` celdas, rellenando con null lo que no se usa. */
  const completar = (celdas: unknown[]): unknown[] => [
    ...celdas,
    ...Array<null>(Math.max(0, anchoTotal - celdas.length)).fill(null),
  ];

  const filas: unknown[][] = [];

  // --- Encabezado ---------------------------------------------------------
  const rotulo = (texto: string) => ({
    value: texto,
    fontWeight: "bold" as const,
    backgroundColor: CELESTE,
    align: "right" as const,
  });

  /**
   * DOS FILAS, no cuatro apiladas: quién y cuándo a la izquierda, los datos del
   * cálculo a la derecha.
   *
   * Cada rótulo va pegado a su valor, y el par de la derecha arranca donde
   * terminan los pares Ent./Sal. — así el encabezado ocupa el mismo ancho que la
   * grilla de abajo en vez de dejar media hoja vacía.
   *
   * `anchoIzquierda` es cuántas columnas ocupa el valor de la izquierda: todo lo
   * que hay entre su rótulo y el rótulo de la derecha. Se descuentan tres —el
   * rótulo de la izquierda, el de la derecha y su valor— y `completar` rellena
   * lo que sobre, así la fila mide exactamente `anchoTotal`.
   */
  const anchoIzquierda = Math.max(1, anchoTotal - 3);

  const encabezado = (
    rotuloIzq: string,
    valorIzq: string,
    rotuloDer: string,
    valorDer: string | number,
  ): unknown[] =>
    completar([
      rotulo(rotuloIzq),
      { value: valorIzq, columnSpan: anchoIzquierda, fontWeight: "bold" as const },
      ...Array<null>(anchoIzquierda - 1).fill(null),
      rotulo(rotuloDer),
      {
        value: valorDer,
        // El tipo sigue al dato: la hora cátedra es un número y tiene que entrar
        // como tal, o Excel la alinea como texto y no se puede usar en una cuenta.
        type: typeof valorDer === "number" ? Number : String,
        align: "center" as const,
        fontWeight: "bold" as const,
      },
    ]);

  filas.push(encabezado("Profesor/a", datos.profesor, "Mes", datos.periodo));
  filas.push(encabezado("Institución", datos.institucion, "Hora Cátedra", datos.horaCatedra));
  filas.push(completar([]));

  // --- Cabecera de la grilla ----------------------------------------------
  // Dos filas: la de arriba numera los pares, la de abajo dice Ent./Sal.
  const cabecera1: unknown[] = [
    {
      value: "Sem.",
      fontWeight: "bold" as const,
      backgroundColor: "#FFF200",
      align: "center" as const,
      rowSpan: 2,
    },
    {
      value: "Día",
      fontWeight: "bold" as const,
      backgroundColor: "#FFF200",
      align: "center" as const,
      rowSpan: 2,
    },
    {
      value: "Fecha",
      fontWeight: "bold" as const,
      backgroundColor: "#FFF200",
      align: "center" as const,
      rowSpan: 2,
    },
  ];
  for (let i = 0; i < n; i++) {
    cabecera1.push(
      {
        value: i + 1,
        type: Number,
        fontWeight: "bold" as const,
        align: "center" as const,
        columnSpan: 2,
      },
      null,
    );
  }
  cabecera1.push(
    {
      value: "Total Cant. Hs.",
      fontWeight: "bold" as const,
      backgroundColor: CELESTE,
      align: "center" as const,
      rowSpan: 2,
    },
    // Los dos acumulados, en el orden en que se suman: el día va a la semana y
    // la semana al mes. Mismas columnas que la grilla de la pantalla.
    {
      value: "Total Semana",
      fontWeight: "bold" as const,
      backgroundColor: CELESTE,
      align: "center" as const,
      rowSpan: 2,
    },
    {
      value: "Total",
      fontWeight: "bold" as const,
      backgroundColor: CELESTE,
      align: "center" as const,
      rowSpan: 2,
    },
  );
  filas.push(cabecera1);

  // Las celdas de la fila combinada van en null: la librería las ignora, pero
  // tienen que estar para que las columnas no se corran.
  // Una celda por cada columna de la cabecera1 que abarca las dos filas.
  const cabecera2: unknown[] = [null, null, null];
  for (let i = 0; i < n; i++) {
    cabecera2.push(
      { value: "Ent.", fontWeight: "bold" as const, align: "center" as const },
      { value: "Sal.", fontWeight: "bold" as const, align: "center" as const },
    );
  }
  // Tres null: Horas, Total semana y Total, que abarcan las dos filas.
  cabecera2.push(null, null, null);
  filas.push(cabecera2);

  // --- Un renglón por día del mes -----------------------------------------
  for (const [indice, fila] of datos.filas.entries()) {
    const fondo = fila.finDeSemana ? GRIS : CREMA;
    const grupo = semanas.get(fila.semana);
    const celdas: unknown[] = [
      // La celda de la semana se escribe una sola vez, en su primer día, y se
      // estira sobre el resto con rowSpan. Las filas que quedan tapadas van en
      // null: la librería las ignora, pero tienen que estar o las columnas se
      // corren. Sin backgroundColor a propósito, para que no herede el gris de
      // un fin de semana que abra el grupo.
      grupo && grupo.inicio === indice
        ? {
            value: fila.semana,
            type: Number,
            align: "center" as const,
            alignVertical: "center" as const,
            rowSpan: grupo.cantidad,
          }
        : null,
      { value: fila.diaSemana, align: "center" as const, backgroundColor: fondo },
      { value: fila.dia, type: Number, align: "center" as const, backgroundColor: fondo },
    ];
    for (let i = 0; i < n; i++) {
      const marca = fila.marcas[i];
      // null y no "" en la celda sin dato: una cadena vacía deja la celda
      // "ocupada" con texto y los filtros de Excel la cuentan como un valor.
      celdas.push(
        marca?.entrada
          ? { value: marca.entrada, type: String, align: "center" as const, backgroundColor: fondo }
          : { value: null, backgroundColor: fondo },
        marca?.salida
          ? { value: marca.salida, type: String, align: "center" as const, backgroundColor: fondo }
          : { value: null, backgroundColor: fondo },
      );
    }
    celdas.push(
      fila.horas > 0
        ? {
            // Número y no "3,00": la columna tiene que poder sumarse en la
            // planilla, que es la mitad del sentido de bajarla a Excel.
            value: fila.horas,
            type: Number,
            align: "center" as const,
            backgroundColor: CELESTE,
          }
        : { value: null, backgroundColor: CELESTE },
    );

    // Total de la semana: una celda estirada sobre sus días, igual que la de
    // Sem. Se declara en el PRIMER día del grupo porque un rowSpan sólo crece
    // hacia abajo, y se alinea abajo para que el número quede donde cierra la
    // cuenta — el mismo criterio que la pantalla.
    const horasDeLaSemana = horasSemana.get(fila.semana) ?? 0;
    celdas.push(
      grupo && grupo.inicio === indice
        ? {
            value: horasDeLaSemana > 0 ? Number(horasDeLaSemana.toFixed(2)) : null,
            type: Number,
            align: "center" as const,
            alignVertical: "bottom" as const,
            fontWeight: "bold" as const,
            backgroundColor: CELESTE,
            rowSpan: grupo.cantidad,
          }
        : null,
    );

    // Total del mes: una sola celda sobre TODA la grilla, declarada en el primer
    // día. Es una única cuenta, no una por semana.
    celdas.push(
      indice === 0
        ? {
            value: datos.totalHoras > 0 ? datos.totalHoras : null,
            type: Number,
            align: "center" as const,
            alignVertical: "bottom" as const,
            fontWeight: "bold" as const,
            backgroundColor: CELESTE,
            rowSpan: datos.filas.length,
          }
        : null,
    );
    filas.push(celdas);
  }

  // --- Resumen ------------------------------------------------------------
  // Las mismas siete filas que el bloque de la pantalla, en el mismo orden. El
  // importe va redondeado a guaraníes: no hay centavos en la moneda, y el
  // desglose del IVA tiene que cerrar contra el número que se muestra.
  filas.push(completar([]));
  // El rótulo lateral toma dos columnas y el importe una: lo del medio es la
  // etiqueta.
  const anchoEtiquetaResumen = Math.max(1, anchoTotal - 3);
  const importe = Math.round(datos.totalImporte);
  const resumen: Array<{ etiqueta: string; valor: number | null; destacada?: boolean }> = [
    { etiqueta: "TOTAL HORAS TRABAJADAS", valor: datos.totalHoras },
    { etiqueta: "IMPORTE POR HORA", valor: datos.precioHora },
    { etiqueta: "IMPORTE NORMAL", valor: importe },
    // En null y no en 0: un cero afirma que se calcularon las horas extra y
    // dieron cero, y lo que pasa es que hoy nada las distingue de las normales.
    { etiqueta: "IMPORTE EXTRA", valor: null },
    { etiqueta: "IMPORTE TOTAL", valor: importe },
    // "INCLUIDO EN EL TOTAL" y no "IVA" a secas: es un desglose, no algo que
    // haya que sumarle al total de abajo. Ver la nota de `totalIva`.
    { etiqueta: "IVA INCLUIDO EN EL TOTAL", valor: Math.round(datos.totalIva), destacada: true },
    { etiqueta: "TOTAL GENERAL", valor: importe, destacada: true },
  ];

  resumen.forEach(({ etiqueta, valor, destacada }, i) => {
    filas.push(
      completar([
        // El rótulo lateral estirado sobre las siete filas, como en la pantalla.
        i === 0
          ? {
              value: datos.nombreEmpresa ? `RESUMEN ${datos.nombreEmpresa}` : "RESUMEN",
              fontWeight: "bold" as const,
              backgroundColor: CELESTE,
              align: "center" as const,
              alignVertical: "center" as const,
              wrap: true,
              rowSpan: resumen.length,
              columnSpan: 2,
            }
          : null,
        null,
        {
          value: etiqueta,
          fontWeight: "bold" as const,
          align: "left" as const,
          // Ocupa todo lo que hay entre el rótulo lateral y la columna del
          // importe, para que el número caiga en la ÚLTIMA columna de la grilla
          // —alineado con los totales de arriba— y no a media hoja.
          columnSpan: anchoEtiquetaResumen,
          // Las dos últimas en rojo, como en la planilla de papel: son las que
          // se controlan contra la factura.
          ...(destacada ? { color: ROJO } : {}),
        },
        ...Array<null>(anchoEtiquetaResumen - 1).fill(null),
        {
          value: valor,
          type: Number,
          fontWeight: "bold" as const,
          align: "right" as const,
          ...(destacada ? { color: ROJO } : {}),
        },
      ]),
    );
  });

  // --- Actividad extra: renglones en blanco para llenar a mano -------------
  const filasExtra = datos.filasActividadExtra ?? 0;
  if (filasExtra > 0) {
    filas.push(completar([]));
    filas.push(
      completar([
        {
          value: "ACTIVIDAD EXTRA",
          fontWeight: "bold" as const,
          backgroundColor: "#F8D7DA",
          align: "center" as const,
          columnSpan: 6,
        },
      ]),
    );
    filas.push(
      completar(
        ["Colegio", "Fecha", "Concepto", "Hs. Trab.", "Pago por Hs.", "Importe"].map((t) => ({
          value: t,
          fontWeight: "bold" as const,
          backgroundColor: "#F8D7DA",
          align: "center" as const,
        })),
      ),
    );
    // Celdas vacías CON fondo: un renglón sin color no se distingue del resto
    // de la hoja y deja de leerse como un espacio para completar.
    for (let i = 0; i < filasExtra; i++) {
      filas.push(
        completar(Array.from({ length: 6 }, () => ({ value: null, backgroundColor: CREMA }))),
      );
    }
  }

  // Semana, Día, Fecha, los pares Ent./Sal. y los TRES totales. Tiene que haber
  // tantos anchos como columnas tiene la grilla, o Excel las corre.
  const columnas = [
    { width: 6 },
    { width: 8 },
    { width: 8 },
    ...Array.from({ length: n * 2 }, () => ({ width: 7 })),
    { width: 14 },
    { width: 14 },
    { width: 12 },
  ];

  return { filas, columnas, profesor: datos.profesor };
}

/** Separador de miles es-PY, sin símbolo: para los totales del PDF. */
function formatearNumero(valor: number): string {
  return new Intl.NumberFormat("es-PY", { maximumFractionDigits: 0 }).format(Math.round(valor));
}

/**
 * La misma planilla en PDF, apaisada.
 *
 * La pestaña se abre en la primera línea, antes de cualquier `await`: los
 * bloqueadores sólo dejan pasar el `window.open` que ocurre dentro del click.
 */
export async function abrirPlanillaPdf(planillas: DatosPlanilla | DatosPlanilla[]): Promise<void> {
  // Acepta una sola o varias: la pantalla siempre manda un arreglo, pero
  // normalizar acá evita que cada llamador tenga que envolverla.
  const lista = Array.isArray(planillas) ? planillas : [planillas];
  if (lista.length === 0) throw new Error("No hay planillas para exportar");

  const pestania = window.open("", "_blank");
  if (pestania) {
    pestania.document.write(
      '<title>Generando</title><p style="font:16px system-ui;padding:2rem">Generando el PDF…</p>',
    );
    pestania.document.close();
  }

  try {
    const [{ jsPDF }, { default: autoTable }] = await Promise.all([
      import("jspdf"),
      import("jspdf-autotable"),
    ]);

    const tiempo = marcaDeTiempo();
    // `orientation: "landscape"` explícito y no el atajo `{ orientation }`:
    // escrito así resolvería contra `window.orientation`, que es un número.
    const doc = new jsPDF({ orientation: "landscape", unit: "pt", format: "a4" });
    const anchoPagina = doc.internal.pageSize.getWidth();

    // Cada profesor arranca en su propia hoja: la planilla se firma de a una
    // persona, así que no pueden compartir página.
    lista.forEach((datos, indice) => {
      if (indice > 0) doc.addPage();
      dibujarPlanilla(doc, autoTable, datos, anchoPagina, tiempo);
    });

    const url = URL.createObjectURL(doc.output("blob"));
    if (pestania) {
      pestania.location.href = url;
    } else {
      // Bloqueada: que al menos se lleve el archivo.
      const enlace = document.createElement("a");
      enlace.href = url;
      enlace.download = `planilla-${tiempo.archivo}.pdf`;
      enlace.click();
    }
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
  } catch (error) {
    if (pestania) pestania.close();
    throw error;
  }
}

/**
 * Dibuja UNA planilla en la página actual del documento.
 *
 * Extraído de `abrirPlanillaPdf` para poder repetirlo por profesor. Recibe
 * `autoTable` en vez de importarlo: el import dinámico se hace una sola vez en
 * el llamador, no una por planilla.
 */
function dibujarPlanilla(
  doc: import("jspdf").jsPDF,
  autoTable: typeof import("jspdf-autotable").default,
  datos: DatosPlanilla,
  anchoPagina: number,
  tiempo: { legible: string; archivo: string },
): void {
  {
    const n = datos.columnasMarca;

    doc.setFont("helvetica", "bold");
    doc.setFontSize(14);
    doc.text("Planilla de asistencia", 40, 40);

    doc.setFont("helvetica", "normal");
    doc.setFontSize(9);
    doc.setTextColor(60);
    doc.text(`Profesor/a: ${datos.profesor}`, 40, 58);
    doc.text(`Institución: ${datos.institucion}`, 40, 70);
    doc.text(`Mes: ${datos.periodo}`, anchoPagina - 260, 58);
    doc.text(`Hora cátedra: ${datos.horaCatedra} min`, anchoPagina - 260, 70);

    // Dos filas de cabecera: los pares numerados arriba, Ent./Sal. abajo.
    const head1: unknown[] = [
      { content: "Sem.", rowSpan: 2, styles: { valign: "middle" } },
      { content: "Día", rowSpan: 2, styles: { valign: "middle" } },
      { content: "Fecha", rowSpan: 2, styles: { valign: "middle" } },
    ];
    for (let i = 0; i < n; i++) {
      head1.push({ content: String(i + 1), colSpan: 2, styles: { halign: "center" } });
    }
    head1.push({ content: "Total Hs.", rowSpan: 2, styles: { valign: "middle" } });

    const head2: string[] = [];
    for (let i = 0; i < n; i++) head2.push("Ent.", "Sal.");

    const semanas = gruposDeSemana(datos.filas);

    const body = datos.filas.map((fila, indice) => {
      const grupo = semanas.get(fila.semana);
      const celdas: unknown[] = [];

      // La celda de la semana se emite SÓLO en su primer día, con rowSpan:
      // autoTable corre las demás filas una columna a la izquierda solo, así
      // que las tapadas no llevan celda (al revés que en Excel, donde van null).
      if (grupo && grupo.inicio === indice) {
        celdas.push({
          content: String(fila.semana),
          rowSpan: grupo.cantidad,
          styles: { valign: "middle", fontStyle: "bold" },
        });
      }

      celdas.push(fila.diaSemana, String(fila.dia));
      for (let i = 0; i < n; i++) {
        const marca = fila.marcas[i];
        celdas.push(marca?.entrada ?? "", marca?.salida ?? "");
      }
      celdas.push(fila.horas > 0 ? fila.horas.toFixed(2) : "");
      return celdas;
    });

    autoTable(doc, {
      startY: 84,
      head: [head1, head2] as never,
      body: body as never,
      styles: { fontSize: 7, cellPadding: 2, overflow: "linebreak", halign: "center" },
      headStyles: { fillColor: AZUL, textColor: 255, fontStyle: "bold", halign: "center" },
      // El fin de semana en gris: sin marcarlo, un sábado vacío se lee igual que
      // un día laboral sin marcar, que sí es un problema.
      didParseCell: (celda) => {
        if (celda.section === "body") {
          const fila = datos.filas[celda.row.index];
          // La columna 0 es la de la semana: abarca varios días con rowSpan, así
          // que pintarla del gris del sábado que abre el grupo dejaría la
          // columna de dos colores. Mismo criterio que la grilla en pantalla.
          if (fila?.finDeSemana && celda.column.index > 0) {
            celda.cell.styles.fillColor = [239, 239, 239];
          }
        }
      },
      margin: { left: 40, right: 40, bottom: 60 },
      // El pie va por página y no una sola vez al final: un reporte impreso se
      // desarma, y cada hoja suelta tiene que decir de cuándo es.
      didDrawPage: (datosHoja) => {
        doc.setFont("helvetica", "normal");
        doc.setFontSize(8);
        doc.setTextColor(140);
        const alto = doc.internal.pageSize.getHeight();
        doc.text(`Emitido el ${tiempo.legible}`, 40, alto - 22);
        doc.text(`Página ${datosHoja.pageNumber}`, anchoPagina - 40, alto - 22, { align: "right" });
      },
    });

    // El bloque de totales, debajo de la grilla.
    const finTabla = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY;
    autoTable(doc, {
      startY: finTabla + 14,
      // "Gs." en el rótulo y el número pelado: el guaraní (₲) no existe en las
      // fuentes de fábrica de jsPDF y saldría como un cuadrito.
      body: [
        ["TOTAL HORAS TRABAJADAS", datos.totalHoras.toFixed(2)],
        ["IMPORTE POR HORA Gs.", formatearNumero(datos.precioHora)],
        ["IMPORTE TOTAL Gs.", formatearNumero(datos.totalImporte)],
        ["IVA INCLUIDO Gs.", formatearNumero(datos.totalIva)],
      ],
      theme: "grid",
      styles: { fontSize: 9, cellPadding: 4 },
      columnStyles: {
        0: { fontStyle: "bold", cellWidth: 200 },
        1: { halign: "right", cellWidth: 120 },
      },
      margin: { left: 40 },
      tableWidth: 320,
    });

    // El bloque de actividad extra, en blanco para completar a mano.
    const filasExtra = datos.filasActividadExtra ?? 0;
    if (filasExtra > 0) {
      const finTotales = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable
        .finalY;
      autoTable(doc, {
        startY: finTotales + 14,
        head: [["Colegio", "Fecha", "Concepto", "Hs. Trab.", "Pago por Hs.", "Importe Gs."]],
        body: Array.from({ length: filasExtra }, () => ["", "", "", "", "", ""]),
        theme: "grid",
        styles: { fontSize: 8, cellPadding: 6, minCellHeight: 18 },
        // Rosa suave, como el bloque de la planilla de papel.
        headStyles: { fillColor: [248, 215, 218], textColor: 40, fontStyle: "bold" },
        margin: { left: 40, right: 40 },
      });
      doc.setFont("helvetica", "bold");
      doc.setFontSize(9);
      doc.setTextColor(60);
      doc.text("ACTIVIDAD EXTRA", 40, finTotales + 8);
    }
  }
}
