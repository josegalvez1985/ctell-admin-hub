const MAX_LADO = 1200;
const MAX_BYTES_SALIDA = 1.8 * 1024 * 1024;

/**
 * Redimensiona y comprime una imagen antes de enviarla al backend.
 * JPEG de calidad alta reduce mucho las fotos de cámara sin afectar su uso
 * como foto de perfil y deja margen bajo el límite de 2 MB del endpoint.
 */
export async function optimizarImagen(archivo: File): Promise<File> {
  if (!archivo.type.startsWith("image/")) {
    throw new Error("El archivo seleccionado no es una imagen");
  }

  const bitmap = await createImageBitmap(archivo);
  const escala = Math.min(1, MAX_LADO / Math.max(bitmap.width, bitmap.height));
  const ancho = Math.max(1, Math.round(bitmap.width * escala));
  const alto = Math.max(1, Math.round(bitmap.height * escala));
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
  contexto.drawImage(bitmap, 0, 0, ancho, alto);
  bitmap.close();

  for (const calidad of [0.9, 0.82, 0.74, 0.66]) {
    const blob = await canvasToBlob(canvas, calidad);
    if (blob.size <= MAX_BYTES_SALIDA || calidad === 0.66) {
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
