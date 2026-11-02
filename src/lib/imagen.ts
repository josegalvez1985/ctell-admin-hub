const MAX_LADO = 1200;
const MAX_BYTES_SALIDA = 1.8 * 1024 * 1024;

export type OpcionesOptimizar = {
  /** Lado mayor de la salida, en píxeles. */
  maxLado?: number;
  /** Peso al que se intenta llegar bajando la calidad. */
  maxBytes?: number;
  /**
   * Recorta el centro en un cuadrado antes de achicar. Se pierde lo que sobra
   * del lado largo, que en una foto de producto suele ser fondo.
   */
  cuadrada?: boolean;
};

/**
 * Redimensiona y comprime una imagen antes de enviarla al backend.
 * JPEG de calidad alta reduce mucho las fotos de cámara sin afectar su uso
 * como foto de perfil y deja margen bajo el límite de 2 MB del endpoint.
 *
 * Los valores por defecto son los de la foto del profesor; quien sube a otro
 * lado pasa los suyos.
 */
export async function optimizarImagen(
  archivo: File,
  { maxLado = MAX_LADO, maxBytes = MAX_BYTES_SALIDA, cuadrada = false }: OpcionesOptimizar = {},
): Promise<File> {
  if (!archivo.type.startsWith("image/")) {
    throw new Error("El archivo seleccionado no es una imagen");
  }

  const bitmap = await createImageBitmap(archivo);

  // El rectángulo de origen: la foto entera, o el cuadrado del centro.
  const corte = cuadrada ? Math.min(bitmap.width, bitmap.height) : null;
  const origen = corte
    ? {
        x: Math.round((bitmap.width - corte) / 2),
        y: Math.round((bitmap.height - corte) / 2),
        ancho: corte,
        alto: corte,
      }
    : { x: 0, y: 0, ancho: bitmap.width, alto: bitmap.height };

  const escala = Math.min(1, maxLado / Math.max(origen.ancho, origen.alto));
  const ancho = Math.max(1, Math.round(origen.ancho * escala));
  const alto = Math.max(1, Math.round(origen.alto * escala));
  const canvas = document.createElement("canvas");
  canvas.width = ancho;
  canvas.height = alto;

  const contexto = canvas.getContext("2d");
  if (!contexto) {
    bitmap.close();
    throw new Error("No se pudo preparar la imagen");
  }

  contexto.imageSmoothingEnabled = true;
  contexto.imageSmoothingQuality = "high";
  contexto.fillStyle = "#ffffff";
  contexto.fillRect(0, 0, ancho, alto);
  contexto.drawImage(bitmap, origen.x, origen.y, origen.ancho, origen.alto, 0, 0, ancho, alto);
  bitmap.close();

  for (const calidad of [0.9, 0.82, 0.74, 0.66]) {
    const blob = await canvasToBlob(canvas, calidad);
    if (blob.size <= maxBytes || calidad === 0.66) {
      return new File([blob], `${archivo.name.replace(/\.[^.]+$/, "")}.jpg`, {
        type: "image/jpeg",
        lastModified: Date.now(),
      });
    }
  }

  throw new Error("No se pudo comprimir la imagen");
}

function canvasToBlob(canvas: HTMLCanvasElement, calidad: number): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => (blob ? resolve(blob) : reject(new Error("No se pudo comprimir la imagen"))),
      "image/jpeg",
      calidad,
    );
  });
}
