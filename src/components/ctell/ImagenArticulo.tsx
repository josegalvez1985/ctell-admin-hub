import { Package } from "lucide-react";
import { useEffect, useState } from "react";

import { urlImagenArticulo } from "@/lib/api";
import { cn } from "@/lib/utils";

/**
 * Imagen de un artículo, con un ícono como alternativa.
 *
 * Mismo mecanismo que `LogoEmpresa`, con una diferencia deliberada: acá el
 * fallback es un ícono y no las iniciales. Un artículo no se reconoce por sus
 * letras —"CE" no dice nada de "Cemento Portland"—, así que un marcador neutro
 * comunica mejor "sin foto" que dos letras arbitrarias.
 *
 * Dos caminos llevan al ícono: que el artículo no tenga imagen cargada
 * (`tieneImagen` en false, y ahí ni se intenta la petición) o que la imagen
 * falle al cargar. El segundo importa tanto como el primero: si el endpoint
 * todavía no está publicado en APEX, el <img> daría 404 y sin el onError
 * quedaría el ícono de imagen rota del navegador.
 */
export function ImagenArticulo({
  id,
  tieneImagen,
  className,
}: {
  id: number;
  tieneImagen: boolean;
  className?: string;
}) {
  const [falloCarga, setFalloCarga] = useState(false);

  // Si cambia el artículo, el fallo anterior no aplica: sin esto, uno sin
  // imagen dejaría marcados como rotos a los que se rendericen después en el
  // mismo lugar (una fila reutilizada de la tabla, por ejemplo).
  useEffect(() => {
    setFalloCarga(false);
  }, [id]);

  const mostrarImagen = tieneImagen && !falloCarga;

  return (
    <span
      className={cn(
        "flex size-10 shrink-0 items-center justify-center overflow-hidden rounded-lg border border-border bg-muted",
        className,
      )}
    >
      {mostrarImagen ? (
        <img
          src={urlImagenArticulo(id)}
          alt=""
          className="size-full object-cover"
          onError={() => setFalloCarga(true)}
        />
      ) : (
        <Package className="size-4 text-muted-foreground" />
      )}
    </span>
  );
}
