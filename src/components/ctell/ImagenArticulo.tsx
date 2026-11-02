import { Package } from "lucide-react";
import { useEffect, useState } from "react";

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { urlImagenArticulo } from "@/lib/api";
import { imagenAjustada, miniatura } from "@/lib/cloudinary";
import { cn } from "@/lib/utils";

/**
 * Imagen de un artículo, con un ícono como alternativa.
 *
 * Mismo mecanismo que `LogoEmpresa`, con una diferencia deliberada: acá el
 * fallback es un ícono y no las iniciales. Un artículo no se reconoce por sus
 * letras —"CE" no dice nada de "Cemento Portland"—, así que un marcador neutro
 * comunica mejor "sin foto" que dos letras arbitrarias.
 *
 * La imagen sale de dos lugares: `imagenUrl` (Cloudinary, las de ahora) o el
 * endpoint viejo `/articulos/imagen/:id` (las guardadas como BLOB antes del
 * cambio). La de Cloudinary se pide **recortada al tamaño de la miniatura**:
 * sin eso, una tabla de 50 filas baja 50 fotos enteras para mostrarlas de 40px.
 *
 * Dos caminos llevan al ícono: que el artículo no tenga imagen cargada
 * (`tieneImagen` en false, y ahí ni se intenta la petición) o que la imagen
 * falle al cargar. El segundo importa tanto como el primero: sin el onError
 * quedaría el ícono de imagen rota del navegador.
 *
 * **Con `ampliar`, tocarla la abre en grande en un modal.** El mismo en el
 * listado y en la ficha, por eso vive acá y no en cada pantalla. Sin imagen no
 * hay nada que ampliar y queda como un dibujo quieto, no un botón que no hace
 * nada.
 */
export function ImagenArticulo({
  id,
  imagenUrl,
  tieneImagen,
  lado = 160,
  ampliar,
  className,
}: {
  id: number;
  imagenUrl: string | null;
  tieneImagen: boolean;
  /** Lado de la miniatura que se le pide a Cloudinary, en píxeles (≈ 2× lo que se ve). */
  lado?: number;
  /** Título y subtítulo del modal. Sin esto, la imagen no se puede ampliar. */
  ampliar?: { titulo: string; subtitulo?: string | null };
  className?: string;
}) {
  const [falloCarga, setFalloCarga] = useState(false);
  const [ampliada, setAmpliada] = useState(false);

  // Si cambia la imagen, el fallo anterior no aplica: sin esto, uno sin
  // imagen dejaría marcados como rotos a los que se rendericen después en el
  // mismo lugar (una fila reutilizada de la tabla, por ejemplo).
  useEffect(() => {
    setFalloCarga(false);
  }, [id, imagenUrl]);

  const src = imagenUrl
    ? (miniatura(imagenUrl, "foto", lado) ?? imagenUrl)
    : tieneImagen
      ? urlImagenArticulo(id)
      : null;
  const mostrarImagen = src !== null && !falloCarga;

  const marco = cn(
    "flex size-10 shrink-0 items-center justify-center overflow-hidden rounded-lg border border-border bg-muted",
    className,
  );

  const contenido = mostrarImagen ? (
    <img
      src={src}
      alt=""
      loading="lazy"
      className="size-full object-cover"
      onError={() => setFalloCarga(true)}
    />
  ) : (
    <Package className="size-4 text-muted-foreground" />
  );

  if (!ampliar || !mostrarImagen) {
    return <span className={marco}>{contenido}</span>;
  }

  // La grande: la de Cloudinary a 800px (ya es cuadrada, no se recorta más), o
  // la vieja del BLOB tal cual está.
  const srcGrande = imagenUrl ? imagenAjustada(imagenUrl, 800) : urlImagenArticulo(id);

  return (
    <>
      <button
        type="button"
        onClick={(e) => {
          // En una fila de la tabla, el click no tiene que llegar a la fila.
          e.stopPropagation();
          setAmpliada(true);
        }}
        title="Ver en grande"
        aria-label={`Ver en grande la imagen de ${ampliar.titulo}`}
        className={cn(
          marco,
          "cursor-zoom-in transition-opacity hover:opacity-80 focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none",
        )}
      >
        {contenido}
      </button>

      <Dialog open={ampliada} onOpenChange={setAmpliada}>
        <DialogContent className="sm:max-w-xl">
          <DialogHeader>
            <DialogTitle>{ampliar.titulo}</DialogTitle>
            {ampliar.subtitulo && <DialogDescription>{ampliar.subtitulo}</DialogDescription>}
          </DialogHeader>
          {/* aspect-square: la imagen es cuadrada y así ocupa el ancho del modal
              sin bandas. Las viejas en BLOB pueden no serlo y se recortan igual
              que en la tabla. El tope de alto es para un celular acostado. */}
          <img
            src={srcGrande}
            alt={ampliar.titulo}
            className="mx-auto aspect-square w-full max-w-[min(100%,70dvh)] rounded-lg bg-muted object-cover"
          />
        </DialogContent>
      </Dialog>
    </>
  );
}
