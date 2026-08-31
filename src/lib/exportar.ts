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
}: {
  nombreArchivo: string;
  titulo: string;
  /** Contexto del reporte: empresa, filtros aplicados, totales. */
  subtitulos?: string[];
  columnas: ColumnaExport<T>[];
  /** Las filas, o cómo traerlas. La función corre con la pestaña ya abierta. */
  filas: T[] | (() => Promise<T[]>);
  orientacion?: "portrait" | "landscape";
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
    const [{ jsPDF }, { default: autoTable }, datos] = await Promise.all([
      import("jspdf"),
      import("jspdf-autotable"),
      typeof filas === "function" ? filas() : Promise.resolve(filas),
    ]);

    const tiempo = marcaDeTiempo();
    // `orientation: orientacion` y no el atajo `{ orientation }`: escrito así
    // TypeScript no da error, pero resuelve contra `window.orientation` —una
    // global del DOM que es un número— y el PDF sale siempre en vertical.
    const doc = new jsPDF({ orientation: orientacion, unit: "pt", format: "a4" });
    const anchoPagina = doc.internal.pageSize.getWidth();

    doc.setFont("helvetica", "bold");
    doc.setFontSize(15);
    doc.text(titulo, 40, 46);

    doc.setFont("helvetica", "normal");
    doc.setFontSize(9);
    doc.setTextColor(110);
    subtitulos.forEach((linea, i) => doc.text(linea, 40, 62 + i * 12));

    autoTable(doc, {
      startY: 62 + subtitulos.length * 12 + 10,
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
   * Renglones en blanco del bloque "Actividad extra".
   *
   * Ese bloque NO sale de la base: no hay tabla que lo respalde. Se imprime
   * vacío para completarlo a mano sobre el papel, que es como se usa hoy. En 0
   * el bloque no se dibuja.
   */
  filasActividadExtra?: number;
};

/** El azul del logo en RGB: jsPDF no entiende las variables oklch del tema. */
const AZUL: [number, number, number] = [19, 98, 192];
/** Amarillo suave de las celdas de carga, como la planilla de papel. */
const CREMA = "#FFF9E6";
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
export async function descargarPlanillaExcel(datos: DatosPlanilla): Promise<void> {
  const { default: writeXlsxFile } = await import("write-excel-file/browser");

  const n = datos.columnasMarca;
  // Día, Fecha, (Ent./Sal.) × n, Total horas
  const anchoTotal = 2 + n * 2 + 1;

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

  filas.push(
    completar([
      rotulo("Profesor/a"),
      { value: datos.profesor, columnSpan: Math.max(1, n), fontWeight: "bold" as const },
    ]),
  );
  filas.push(
    completar([rotulo("Institución"), { value: datos.institucion, columnSpan: Math.max(1, n) }]),
  );
  filas.push(completar([rotulo("Mes"), { value: datos.periodo }]));
  filas.push(completar([rotulo("Hora cátedra (min)"), { value: datos.horaCatedra, type: Number }]));
  filas.push(completar([]));

  // --- Cabecera de la grilla ----------------------------------------------
  // Dos filas: la de arriba numera los pares, la de abajo dice Ent./Sal.
  const cabecera1: unknown[] = [
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
  cabecera1.push({
    value: "Total Cant. Hs.",
    fontWeight: "bold" as const,
    backgroundColor: CELESTE,
    align: "center" as const,
    rowSpan: 2,
  });
  filas.push(cabecera1);

  // Las celdas de la fila combinada van en null: la librería las ignora, pero
  // tienen que estar para que las columnas no se corran.
  const cabecera2: unknown[] = [null, null];
  for (let i = 0; i < n; i++) {
    cabecera2.push(
      { value: "Ent.", fontWeight: "bold" as const, align: "center" as const },
      { value: "Sal.", fontWeight: "bold" as const, align: "center" as const },
    );
  }
  cabecera2.push(null);
  filas.push(cabecera2);

  // --- Un renglón por día del mes -----------------------------------------
  for (const fila of datos.filas) {
    const fondo = fila.finDeSemana ? GRIS : CREMA;
    const celdas: unknown[] = [
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
    filas.push(celdas);
  }

  // --- Resumen ------------------------------------------------------------
  filas.push(completar([]));
  const resumen: Array<[string, number]> = [
    ["TOTAL HORAS TRABAJADAS", datos.totalHoras],
    ["IMPORTE POR HORA", datos.precioHora],
    ["IMPORTE TOTAL", datos.totalImporte],
    ["IVA INCLUIDO", datos.totalIva],
  ];
  for (const [etiqueta, valor] of resumen) {
    filas.push(
      completar([
        {
          value: etiqueta,
          fontWeight: "bold" as const,
          columnSpan: 2,
          align: "right" as const,
        },
        null,
        { value: valor, type: Number, fontWeight: "bold" as const },
      ]),
    );
  }

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

  const columns = [
    { width: 8 },
    { width: 8 },
    ...Array.from({ length: n * 2 }, () => ({ width: 7 })),
    { width: 14 },
  ];

  // La v4 devuelve `{ toBlob, toFile }` en vez de aceptar un `fileName` entre
  // las opciones. Los ejemplos que andan dando vueltas siguen siendo los de v1.
  await writeXlsxFile(filas as never, { columns, sheet: "Planilla" }).toFile(
    `planilla-${datos.periodo.replace(/\s+/g, "-").toLowerCase()}-${marcaDeTiempo().archivo}.xlsx`,
  );
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
export async function abrirPlanillaPdf(datos: DatosPlanilla): Promise<void> {
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
      { content: "Día", rowSpan: 2, styles: { valign: "middle" } },
      { content: "Fecha", rowSpan: 2, styles: { valign: "middle" } },
    ];
    for (let i = 0; i < n; i++) {
      head1.push({ content: String(i + 1), colSpan: 2, styles: { halign: "center" } });
    }
    head1.push({ content: "Total Hs.", rowSpan: 2, styles: { valign: "middle" } });

    const head2: string[] = [];
    for (let i = 0; i < n; i++) head2.push("Ent.", "Sal.");

    const body = datos.filas.map((fila) => {
      const celdas: string[] = [fila.diaSemana, String(fila.dia)];
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
      body,
      styles: { fontSize: 7, cellPadding: 2, overflow: "linebreak", halign: "center" },
      headStyles: { fillColor: AZUL, textColor: 255, fontStyle: "bold", halign: "center" },
      // El fin de semana en gris: sin marcarlo, un sábado vacío se lee igual que
      // un día laboral sin marcar, que sí es un problema.
      didParseCell: (celda) => {
        if (celda.section === "body") {
          const fila = datos.filas[celda.row.index];
          if (fila?.finDeSemana) celda.cell.styles.fillColor = [239, 239, 239];
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
