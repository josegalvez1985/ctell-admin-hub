import { createFileRoute } from "@tanstack/react-router";
import { Wrench, X } from "lucide-react";
import { useEffect, useState } from "react";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { SelectorVehiculo } from "@/components/ctell/SelectorVehiculo";
import { PartesListado, type VehiculoElegido } from "@/components/ctell/VehiculoPartes";
import { Input } from "@/components/ui/input";
import { tituloPagina } from "@/lib/marca";

const ESPERA_BUSQUEDA_MS = 350;

export const Route = createFileRoute("/_auth/vehiculo-partes")({
  head: () => ({
    meta: [
      { title: tituloPagina("Repuestos por vehículo") },
      {
        name: "description",
        content: "Qué repuestos lleva cada vehículo, y a qué vehículos va cada repuesto.",
      },
    ],
  }),
  component: VehiculoPartesPage,
});

/**
 * La página propia del detalle de VEHICULOS, con **los dos sentidos** de la
 * relación como filtros:
 *
 * - **Vehículo** → los repuestos que lleva (`idVehiculo`).
 * - **Código** → los vehículos que llevan ese repuesto (`codigo`, exacto).
 *
 * Y se pasa de uno al otro desde la fila: el auto de un repuesto filtra por su
 * código; la llave, por su vehículo. Cada salto deja el otro filtro vacío —si
 * quedaran los dos, "los vehículos que llevan el W-712" se reduciría al que ya
 * estaba elegido, que es justo lo que no se quería ver—.
 *
 * El listado es el mismo componente que usa el diálogo de /vehiculos
 * (`PartesListado`).
 */
function VehiculoPartesPage() {
  const { empresa } = useEmpresa();
  const [vehiculo, setVehiculo] = useState<VehiculoElegido | null>(null);

  // `codigo` es lo que se tipea y `codigoEnvio` lo que filtra: sin la espera,
  // cada tecla dispararía un request.
  const [codigo, setCodigo] = useState("");
  const [codigoEnvio, setCodigoEnvio] = useState("");

  useEffect(() => {
    const id = setTimeout(() => setCodigoEnvio(codigo), ESPERA_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [codigo]);

  const verVehiculosDe = (c: string) => {
    setVehiculo(null);
    setCodigo(c);
    // Sin esperar el retraso: viene de un click, no de tipear.
    setCodigoEnvio(c);
  };

  const verRepuestosDe = (v: VehiculoElegido) => {
    setCodigo("");
    setCodigoEnvio("");
    setVehiculo(v);
  };

  return (
    <AppLayout active="/vehiculo-partes" title="Repuestos por vehículo">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div>
          <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Repuestos por vehículo</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Elegí un vehículo para ver qué repuestos lleva, o escribí un código para ver a qué
            vehículos va.
          </p>
        </div>

        {empresa === null ? (
          <p className="text-sm text-muted-foreground">
            No hay una empresa activa. Cerrá sesión y volvé a entrar eligiendo una.
          </p>
        ) : (
          <>
            <div className="grid gap-2 sm:grid-cols-2">
              <div className="space-y-1">
                <p className="text-xs text-muted-foreground">Vehículo → sus repuestos</p>
                {/* `quitable`: acá "todos los vehículos" es un valor válido, y
                    tiene que poder volverse a él sin abrir el modal. */}
                <SelectorVehiculo
                  idEmpresa={empresa.id}
                  value={vehiculo ? String(vehiculo.id) : ""}
                  etiquetaSeleccionada={vehiculo?.nombre}
                  onChange={(valor, etiqueta) =>
                    setVehiculo(valor ? { id: Number(valor), nombre: etiqueta } : null)
                  }
                  placeholder="Todos los vehículos"
                  quitable
                />
              </div>
              <div className="space-y-1">
                <p className="text-xs text-muted-foreground">
                  Repuesto → los vehículos que lo llevan
                </p>
                <div className="relative">
                  <Wrench className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
                  <Input
                    value={codigo}
                    onChange={(e) => setCodigo(e.target.value)}
                    placeholder="Código exacto del repuesto"
                    className="pl-9 pr-9 font-mono"
                    aria-label="Filtrar por el código exacto de un repuesto"
                  />
                  {codigo !== "" && (
                    <button
                      type="button"
                      onClick={() => {
                        setCodigo("");
                        setCodigoEnvio("");
                      }}
                      className="absolute right-2 top-1/2 -translate-y-1/2 rounded p-1 text-muted-foreground hover:text-foreground"
                      title="Quitar el filtro"
                      aria-label="Quitar el filtro"
                    >
                      <X className="size-4" />
                    </button>
                  )}
                </div>
              </div>
            </div>

            <PartesListado
              idEmpresa={empresa.id}
              vehiculo={vehiculo}
              codigo={codigoEnvio}
              onVerVehiculos={verVehiculosDe}
              onVerRepuestos={verRepuestosDe}
            />
          </>
        )}
      </main>
    </AppLayout>
  );
}
