import { Download, Plus, Share } from "lucide-react";
import { useEffect, useState } from "react";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useInstalarPwa } from "@/hooks/use-instalar-pwa";
import { useIsMobile } from "@/hooks/use-mobile";
import { NOMBRE_SISTEMA } from "@/lib/marca";

/** Espera antes de sugerir, en ms. */
const DEMORA = 3000;

/**
 * Sugerencia de instalar la aplicación en el celular.
 *
 * Va montado en el layout autenticado, así que sólo lo ve quien ya inició
 * sesión: instalar tiene sentido para quien va a usar la app seguido, no para
 * alguien que todavía no entró.
 *
 * No aparece de inmediato. Un diálogo que interrumpe apenas carga la pantalla
 * se descarta por reflejo, sin leerlo — y como descartar es definitivo, esa
 * sería la última vez que se ofrece. Los segundos de espera dejan ver primero
 * qué es la app.
 *
 * En iOS no hay forma de instalar por código: ahí el diálogo explica el camino
 * manual en vez de ofrecer un botón que no podría funcionar.
 */
export function InstalarPwaDialog() {
  const esMovil = useIsMobile();
  const { puedeSugerir, soloInstrucciones, instalar, descartar } = useInstalarPwa();
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    if (!esMovil || !puedeSugerir) return;
    const id = setTimeout(() => setVisible(true), DEMORA);
    return () => clearTimeout(id);
  }, [esMovil, puedeSugerir]);

  // La sugerencia es sólo para el celular: en escritorio la app se usa en el
  // navegador y no hay nada que instalar.
  if (!esMovil || !puedeSugerir) return null;

  /** Cerrar por la X o el fondo cuenta como descartar: no vuelve a aparecer. */
  function alCambiarApertura(abierto: boolean) {
    if (!abierto) {
      setVisible(false);
      descartar();
    }
  }

  async function alInstalar() {
    setVisible(false);
    // Descarta antes de abrir el diálogo nativo: si lo rechazan ahí, no
    // queremos volver a insistir en la próxima pantalla.
    descartar();
    await instalar();
  }

  return (
    <Dialog open={visible} onOpenChange={alCambiarApertura}>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle>Instalá {NOMBRE_SISTEMA}</DialogTitle>
          <DialogDescription>
            Agregala a tu pantalla de inicio para abrirla como una app, sin la barra del navegador.
          </DialogDescription>
        </DialogHeader>

        {soloInstrucciones ? (
          // iOS: Safari no expone ninguna API de instalación, así que lo único
          // que se puede hacer es indicar los dos pasos del menú Compartir.
          <ol className="space-y-3 text-sm text-foreground">
            <li className="flex items-center gap-3">
              <Share className="size-5 shrink-0 text-primary" />
              <span>
                Tocá <strong>Compartir</strong> en la barra de Safari.
              </span>
            </li>
            <li className="flex items-center gap-3">
              <Plus className="size-5 shrink-0 text-primary" />
              <span>
                Elegí <strong>Agregar a inicio</strong>.
              </span>
            </li>
          </ol>
        ) : null}

        <DialogFooter className="gap-2 sm:gap-2">
          <Button variant="outline" onClick={() => alCambiarApertura(false)}>
            Ahora no
          </Button>
          {!soloInstrucciones && (
            <Button onClick={alInstalar}>
              <Download className="size-4" />
              Instalar
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
