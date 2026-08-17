import { useEffect, useState } from "react";

import { useEmpresa } from "@/components/ctell/empresa-provider";
import { urlLogoEmpresa } from "@/lib/api";
import { LEMA_SISTEMA, NOMBRE_SISTEMA } from "@/lib/marca";
import { cn } from "@/lib/utils";

/**
 * Marca de la aplicación: isotipo + nombre del sistema.
 *
 * El isotipo es el logo de la EMPRESA ACTIVA, no una imagen fija: el sistema
 * opera con varias empresas y quien entra tiene que ver de cuál se trata sin
 * buscarlo. Sale del mismo endpoint que usa el resto de la app
 * (`/empresas/logo/:id`).
 *
 * Cae a `logo.png` —el logo del sistema— en los dos casos donde no hay empresa
 * que mostrar: el login (todavía no se eligió) y una empresa sin logo cargado.
 * El texto de al lado siempre es el nombre del sistema, no el de la empresa:
 * identifica al software, y la empresa ya la comunica el isotipo.
 */
export function Logo({
  className,
  tone = "light",
  showWordmark = true,
}: {
  className?: string;
  tone?: "light" | "dark";
  /** En espacios reducidos se puede mostrar sólo el isotipo. */
  showWordmark?: boolean;
}) {
  const { empresa } = useEmpresa();
  // Si la imagen falla —endpoint sin publicar, BLOB vacío— se cae al logo del
  // sistema en vez de dejar el ícono de imagen rota.
  const [falloCarga, setFalloCarga] = useState(false);

  useEffect(() => {
    setFalloCarga(false);
  }, [empresa?.id]);

  const mostrarLogoEmpresa = empresa?.tieneLogo === true && !falloCarga;

  return (
    <div className={cn("flex items-center gap-2.5", className)}>
      <img
        src={
          mostrarLogoEmpresa ? urlLogoEmpresa(empresa.id) : `${import.meta.env.BASE_URL}logo.png`
        }
        alt={mostrarLogoEmpresa ? empresa.nombreEmpresa : NOMBRE_SISTEMA}
        width={36}
        height={36}
        className="size-9 shrink-0 rounded-xl object-contain shadow-card"
        onError={() => setFalloCarga(true)}
      />
      {showWordmark && (
        <span className="flex flex-col leading-tight">
          {/* text-base y no text-lg: "Sistema Administrativo" es bastante más
              largo que la marca anterior y con el tamaño previo desbordaba el
              sidebar colapsado. */}
          <span
            className={cn(
              "font-display text-base font-bold tracking-tight",
              tone === "light" ? "text-foreground" : "text-navy-foreground",
            )}
          >
            {NOMBRE_SISTEMA}
          </span>
          {/* La bajada se dibuja sólo si hay texto: hoy está vacía y un <span>
              con tracking pero sin contenido dejaba un hueco bajo el nombre. */}
          {LEMA_SISTEMA && (
            <span
              className={cn(
                "text-[10px] font-medium uppercase tracking-[0.22em]",
                tone === "light" ? "text-muted-foreground" : "text-navy-foreground/60",
              )}
            >
              {LEMA_SISTEMA}
            </span>
          )}
        </span>
      )}
    </div>
  );
}
