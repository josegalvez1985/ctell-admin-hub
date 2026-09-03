/**
 * Subida de evidencias a Cloudinary, desde el navegador.
 *
 * **El archivo NO pasa por ORDS.** Es la diferencia con los otros binarios del
 * proyecto —la foto del profesor, el logo, el PDF de un manual—, que viajan
 * como BLOB a la base: acá el navegador sube directo a Cloudinary y en Oracle
 * queda sólo la URL. Un video de 80 MB no tiene por qué atravesar el backend
 * dos veces, y las miniaturas las genera Cloudinary transformando la dirección.
 *
 * Lo que hay que saber, porque no se ve:
 *
 * - **La subida es `unsigned`**, con un `upload_preset` público. Es la única
 *   forma posible acá: firmar exige la `api_secret`, y este frontend es
 *   estático —cualquier cosa que se ponga en el bundle se puede leer—. El
 *   preset tiene que estar configurado en Cloudinary como "unsigned" y conviene
 *   acotarle carpeta, formatos y tamaño máximo desde su panel, que es donde ese
 *   límite se puede hacer cumplir de verdad.
 *
 * - **`cloud_name` y el preset son públicos por diseño**: terminan en el bundle
 *   igual que la URL de ORDS. No son secretos y no hace falta tratarlos como
 *   tales; lo que no puede salir nunca de Cloudinary es la `api_secret`.
 *
 * - **Borrar la fila del reporte no borra el archivo.** Eso necesitaría la
 *   `api_secret`, así que el binario queda en Cloudinary. Limpiarlos es una
 *   tarea aparte contra su consola.
 */

/** Se leen del entorno para no clavar la cuenta en el código: ver `.env.example`. */
const CLOUD_NAME = import.meta.env["VITE_CLOUDINARY_CLOUD_NAME"] ?? "";
const UPLOAD_PRESET = import.meta.env["VITE_CLOUDINARY_UPLOAD_PRESET"] ?? "";

/**
 * Carpeta donde caen las evidencias. Vacía = la raíz del preset.
 *
 * La cuenta está en modo **carpetas dinámicas**: ahí `folder` fija el *asset
 * folder* —la carpeta que se ve en el panel— y no se mete en el `public_id`,
 * así que mover un archivo de carpeta después no rompe la URL guardada. En una
 * cuenta con carpetas fijas el mismo parámetro sí formaría parte del id; el
 * código no necesita distinguirlo, pero conviene saberlo antes de reorganizar
 * la biblioteca.
 */
const CARPETA = import.meta.env["VITE_CLOUDINARY_CARPETA"] ?? "reportes-actividades";

/**
 * `true` si la cuenta está configurada.
 *
 * Cuando es `false` la pantalla ofrece pegar una URL a mano en vez del selector
 * de archivos: sin cloud name no hay a dónde subir, y un botón que falla
 * siempre es peor que un campo de texto que funciona.
 */
export const subidaDirectaDisponible = Boolean(CLOUD_NAME && UPLOAD_PRESET);

/** Los tres tipos de `REPORTES_MULTIMEDIA.TIPO_ARCHIVO`, resueltos desde el archivo. */
export type TipoArchivo = "foto" | "video" | "documento";

export type ArchivoSubido = {
  url: string;
  tipo: TipoArchivo;
  nombre: string;
  bytes: number;
};

/**
 * Qué es el archivo, según su MIME.
 *
 * Se mira el MIME y no la extensión: un `.jpeg` renombrado a `.pdf` seguiría
 * siendo una imagen, y lo que importa acá es cómo se va a mostrar después.
 * Todo lo que no sea imagen ni video cae en `documento`, que la galería
 * representa con un ícono en vez de una miniatura.
 */
export function tipoDeArchivo(mime: string): TipoArchivo {
  if (mime.startsWith("image/")) return "foto";
  if (mime.startsWith("video/")) return "video";
  return "documento";
}

/**
 * Un identificador propio para el archivo, único y todavía legible.
 *
 * **Por qué no se deja que lo resuelva el preset.** `reportes_ctell` está
 * configurado con `use_filename: true`, `unique_filename: false` y
 * `overwrite: false`: con eso el `public_id` ES el nombre del archivo, y dos
 * fotos distintas llamadas `IMG_0001.jpg` —lo más común del mundo, son dos
 * celulares— comparten identificador. Cloudinary entonces **no sube la
 * segunda**: devuelve 200 con la URL de la primera. La evidencia de una clase
 * termina mostrando la foto de otra, sin ningún error a la vista.
 *
 * Mandando el `public_id` desde acá el problema no depende de cómo quede
 * configurado el preset, que es una pantalla que cualquiera puede tocar. El
 * nombre original se conserva igual en la fila (`NOMBRE_ARCHIVO`), así que no
 * se pierde nada por no usarlo como identificador.
 */
function nombrePublico(archivo: File): string {
  const base = archivo.name
    .replace(/\.[^./]+$/, "")
    // NFD separa la tilde de su letra y el filtro siguiente se la lleva: "Educación"
    // queda "Educacion" en vez de "Educaci-n".
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/[^a-zA-Z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);

  const sello = Date.now().toString(36);
  const azar = Math.random().toString(36).slice(2, 8);

  return `${base || "evidencia"}-${sello}${azar}`;
}

/**
 * Sube un archivo y devuelve lo que hay que guardar en la fila.
 *
 * Usa `/auto/upload`: Cloudinary decide solo si es `image`, `video` o `raw`.
 * Elegirlo desde acá obligaría a mantener dos listas de MIME —la nuestra y la
 * suya— y un desacuerdo entre ambas termina en un 400 sin explicación.
 */
export async function subirACloudinary(archivo: File): Promise<ArchivoSubido> {
  if (!subidaDirectaDisponible) {
    throw new Error("La subida directa no está configurada. Pegá la URL del archivo.");
  }

  const datos = new FormData();
  datos.append("file", archivo);
  datos.append("upload_preset", UPLOAD_PRESET);
  // `public_id` es uno de los pocos parámetros que una subida unsigned acepta,
  // y le gana al `use_filename` del preset.
  datos.append("public_id", nombrePublico(archivo));
  if (CARPETA) datos.append("folder", CARPETA);

  const respuesta = await fetch(`https://api.cloudinary.com/v1_1/${CLOUD_NAME}/auto/upload`, {
    method: "POST",
    body: datos,
  });

  if (!respuesta.ok) {
    // Cloudinary contesta el motivo en `error.message` —preset inexistente,
    // formato no permitido, archivo demasiado grande—. Mostrarlo tal cual
    // ahorra la vuelta de ir a mirar su consola.
    const detalle = (await respuesta.json().catch(() => null)) as {
      error?: { message?: string };
    } | null;
    throw new Error(detalle?.error?.message ?? "No se pudo subir el archivo a Cloudinary");
  }

  const subido = (await respuesta.json()) as {
    secure_url: string;
    bytes: number;
    resource_type: string;
    format?: string;
    original_filename?: string;
  };

  return {
    // `secure_url` y no `url`: la otra viene en http y el backend exige https
    // (una URL http en un <img> de una página https no carga).
    url: subido.secure_url,
    tipo:
      subido.resource_type === "image"
        ? "foto"
        : subido.resource_type === "video"
          ? "video"
          : "documento",
    nombre: archivo.name,
    bytes: subido.bytes,
  };
}

/**
 * La misma imagen, recortada al cuadrado que muestra la tira de miniaturas.
 *
 * Es una transformación en la URL: Cloudinary la genera y la cachea la primera
 * vez que alguien la pide. Sin esto, una tira de seis fotos baja seis originales
 * de 4 MB para mostrarlas de 80 píxeles.
 *
 * De un video devuelve su primer cuadro como JPG (`so_0` + extensión cambiada).
 * De un documento devuelve `null`: no hay imagen que mostrar y la galería pone
 * su ícono.
 */
export function miniatura(url: string, tipo: TipoArchivo, lado = 320): string | null {
  if (tipo === "documento") return null;

  // Sólo se puede transformar una URL de Cloudinary. Una pegada a mano desde
  // otro lado se devuelve intacta: se verá pesada, pero se verá.
  const marca = "/upload/";
  const corte = url.indexOf(marca);
  if (corte === -1) return url;

  const antes = url.slice(0, corte + marca.length);
  const despues = url.slice(corte + marca.length);

  if (tipo === "video") {
    const sinExtension = despues.replace(/\.[^./]+$/, "");
    return `${antes}c_fill,w_${lado},h_${lado},q_auto,so_0/${sinExtension}.jpg`;
  }

  return `${antes}c_fill,w_${lado},h_${lado},q_auto,f_auto/${despues}`;
}

/** "2,4 MB". Para el pie de una evidencia; `null` cuando el peso no se guardó. */
export function pesoLegible(bytes: number | null): string | null {
  if (bytes === null || bytes <= 0) return null;
  const unidades = ["B", "KB", "MB", "GB"];
  let valor = bytes;
  let i = 0;
  while (valor >= 1024 && i < unidades.length - 1) {
    valor /= 1024;
    i += 1;
  }
  return `${valor.toLocaleString("es-PY", { maximumFractionDigits: 1 })} ${unidades[i]}`;
}
