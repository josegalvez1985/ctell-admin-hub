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
