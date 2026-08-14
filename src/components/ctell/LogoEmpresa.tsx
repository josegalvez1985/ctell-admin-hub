import { useEffect, useState } from "react";

import { urlLogoEmpresa } from "@/lib/api";
import { cn } from "@/lib/utils";

/**
 * Iniciales de una empresa, para cuando no hay logo cargado.
 *
 * Toma la primera letra de las dos primeras palabras ("Ctell Servicios" → CS),
 * salteando las que son solo forma jurídica: "S.A." o "SRL" como inicial no
 * distingue nada, y casi todas las empresas terminan con una.
 */
function iniciales(nombre: string): string {
  const IGNORADAS = new Set(["sa", "sä", "srl", "sas", "sac", "ltda", "eirl", "de", "del", "y"]);

  const palabras = nombre
    .split(/\s+/)
    .map((p) => p.replace(/[^\p{L}\p{N}]/gu, ""))
    .filter((p) => p.length > 0 && !IGNORADAS.has(p.toLowerCase()));

  // Si al filtrar no quedó nada (una empresa llamada "S.A."), se usa el nombre
  // crudo antes que devolver un cuadro vacío.
  const base = palabras.length > 0 ? palabras : [nombre.trim()];

  return base
    .slice(0, 2)
    .map((p) => p[0]?.toUpperCase() ?? "")
    .join("");
}

/**
 * Logo de una empresa, con las iniciales como alternativa.
 *
 * El logo se pide a `/empresas/logo/:id`, que es público — lo consume el
 * selector del login, donde todavía no hay sesión.
 *
 * Dos caminos llevan a las iniciales: que la empresa no tenga logo cargado
 * (`tieneLogo` en false, y ahí ni se intenta la petición) o que la imagen falle
 * al cargar. El segundo importa tanto como el primero: si el endpoint todavía
 * no está publicado en APEX, el <img> daría 404 y sin el onError quedaría el
 * ícono de imagen rota en vez de algo presentable.
 */
export function LogoEmpresa({
  id,
  nombre,
  tieneLogo,
  className,
}: {
  id: number;
  nombre: string;
  tieneLogo: boolean;
  className?: string;
}) {
  const [falloCarga, setFalloCarga] = useState(false);

  // Si cambia la empresa, el fallo anterior no aplica: sin esto, una empresa
  // sin logo dejaría marcadas como rotas a las que se rendericen después en el
  // mismo lugar.
  useEffect(() => {
    setFalloCarga(false);
  }, [id]);

  const mostrarImagen = tieneLogo && !falloCarga;

  return (
    <span
      className={cn(
        "flex size-12 shrink-0 items-center justify-center overflow-hidden rounded-xl border border-border bg-muted",
        className,
      )}
    >
      {mostrarImagen ? (
        <img
          src={urlLogoEmpresa(id)}
          alt=""
          className="size-full object-contain"
          onError={() => setFalloCarga(true)}
        />
      ) : (
        <span className="text-sm font-bold text-muted-foreground">{iniciales(nombre)}</span>
      )}
    </span>
  );
}
