import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Barcode, Check, Loader2, Pencil, Plus, Trash2, X } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { useEmpresa } from "@/components/ctell/empresa-provider";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import { api, ApiError, type Articulo, type CodigoEquivalente } from "@/lib/api";

function mensajeError(e: unknown, respaldo: string): string {
  return e instanceof ApiError ? e.message : respaldo;
}

/**
 * Códigos equivalentes de un artículo: los alias con los que se lo pide.
 *
 * Un repuesto casi nunca se busca por el código interno, sino por el del
 * fabricante, el del proveedor o el del catálogo del vehículo. Acá se cargan
 * todos esos alias contra el mismo artículo.
 *
 * Va como diálogo sobre la ficha del artículo y no como página propia: siempre
 * se mira "los códigos de ESTE artículo", así que una ruta aparte obligaría a
 * elegir el artículo de nuevo al entrar. Mismo criterio que
 * `ArticuloUbicacionesDialog`.
 *
 * **La edición es en la misma fila**, no en otro diálogo: son dos campos cortos
 * y abrir un tercer modal encima para cambiar un código sería más ceremonia que
 * el dato que se edita.
 */
export function CodigosEquivalentesDialog({
  articulo,
  onOpenChange,
}: {
  /** Artículo cuyos códigos se están viendo. `null` cierra el diálogo. */
  articulo: Articulo | null;
  onOpenChange: (abierto: boolean) => void;
}) {
  const queryClient = useQueryClient();
  const { empresa } = useEmpresa();

  const [codigoNuevo, setCodigoNuevo] = useState("");
  const [descripcionNueva, setDescripcionNueva] = useState("");
  const [editando, setEditando] = useState<CodigoEquivalente | null>(null);
  const [codigoEditado, setCodigoEditado] = useState("");
  const [descripcionEditada, setDescripcionEditada] = useState("");
  const [aBorrar, setABorrar] = useState<CodigoEquivalente | null>(null);

  const idArticulo = articulo?.id ?? null;

  const codigos = useQuery({
    queryKey: ["codigos-equivalentes", empresa?.id ?? null, idArticulo],
    queryFn: () =>
      api.codigosEquivalentes.listar({ idEmpresa: empresa!.id, idArticulo: idArticulo! }),
    enabled: idArticulo !== null && empresa !== null,
  });

  const items = codigos.data?.items ?? [];

  function invalidar() {
    queryClient.invalidateQueries({ queryKey: ["codigos-equivalentes"] });
  }

  const crear = useMutation({
    mutationFn: () =>
      api.codigosEquivalentes.crear({
        idEmpresa: empresa!.id,
        idArticulo: idArticulo!,
        codigoEquivalente: codigoNuevo,
        // Se omite si está vacía: la columna es nullable y una cadena vacía
        // guardaría un dato que nadie cargó.
        ...(descripcionNueva.trim() ? { descripcion: descripcionNueva } : {}),
      }),
    onSuccess: () => {
      toast.success("Código agregado");
      // Sólo se limpian los campos, el diálogo queda abierto: lo habitual es
      // cargar varios códigos del mismo artículo de corrido.
      setCodigoNuevo("");
      setDescripcionNueva("");
      invalidar();
    },
    // El 409 de duplicado llega con su mensaje del backend, que es más preciso
    // que cualquier texto de acá.
    onError: (e) => toast.error(mensajeError(e, "No se pudo agregar el código")),
  });

  const guardarEdicion = useMutation({
    mutationFn: (codigo: CodigoEquivalente) =>
      api.codigosEquivalentes.actualizar(codigo.id, {
        idEmpresa: empresa!.id,
        codigoEquivalente: codigoEditado,
        ...(descripcionEditada.trim() ? { descripcion: descripcionEditada } : {}),
      }),
    onSuccess: () => {
      toast.success("Código actualizado");
      setEditando(null);
      invalidar();
    },
    onError: (e) => toast.error(mensajeError(e, "No se pudo actualizar el código")),
  });

  const borrar = useMutation({
    mutationFn: (codigo: CodigoEquivalente) =>
      api.codigosEquivalentes.eliminar(codigo.id, empresa!.id),
    onSuccess: () => {
      toast.success("Código eliminado");
      setABorrar(null);
      invalidar();
    },
    onError: (e) => toast.error(mensajeError(e, "No se pudo eliminar el código")),
  });

  function abrirEdicion(codigo: CodigoEquivalente) {
    setEditando(codigo);
    setCodigoEditado(codigo.codigoEquivalente);
    setDescripcionEditada(codigo.descripcion ?? "");
  }

  return (
    <>
      <Dialog open={articulo !== null} onOpenChange={onOpenChange}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>Códigos de {articulo?.nombreArticulo}</DialogTitle>
            <DialogDescription>
              Los códigos con los que también se pide este repuesto: del fabricante, del proveedor o
              del catálogo del vehículo. Se guardan en mayúsculas.
            </DialogDescription>
          </DialogHeader>

          {/* Agregar arriba: es la acción principal cuando la lista está vacía,
              que es el caso inicial de todo artículo. */}
          <div className="space-y-2 rounded-lg border border-border p-3">
            <div className="grid gap-2 sm:grid-cols-[1fr_1.4fr]">
              <div className="space-y-1.5">
                <Label htmlFor="codigo-nuevo">Código</Label>
                <Input
                  id="codigo-nuevo"
                  value={codigoNuevo}
                  onChange={(e) => setCodigoNuevo(e.target.value)}
                  placeholder="W-712/75"
                  autoComplete="off"
                  // Enter agrega. NO es un <form>: este diálogo se abre desde la
                  // ficha del artículo, que ya es un formulario, y un form
                  // anidado no es HTML válido — el submit de adentro dispararía
                  // el de afuera y guardaría el artículo entero.
                  onKeyDown={(e) => {
                    if (e.key === "Enter") {
                      e.preventDefault();
                      if (codigoNuevo.trim()) crear.mutate();
                    }
                  }}
                />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="descripcion-nueva">Referencia</Label>
                <Input
                  id="descripcion-nueva"
                  value={descripcionNueva}
                  onChange={(e) => setDescripcionNueva(e.target.value)}
                  placeholder="Mann Filter · opcional"
                  autoComplete="off"
                  onKeyDown={(e) => {
                    if (e.key === "Enter") {
                      e.preventDefault();
                      if (codigoNuevo.trim()) crear.mutate();
                    }
                  }}
                />
              </div>
            </div>
            <Button
              className="w-full"
              onClick={() => crear.mutate()}
              disabled={!codigoNuevo.trim() || crear.isPending}
            >
              {crear.isPending ? (
                <Loader2 className="size-4 animate-spin" />
              ) : (
                <Plus className="size-4" />
              )}
              Agregar código
            </Button>
          </div>

          {codigos.isPending ? (
            <div className="space-y-2">
              {[0, 1].map((i) => (
                <Skeleton key={i} className="h-14 w-full" />
              ))}
            </div>
          ) : codigos.isError ? (
            <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">
              {mensajeError(codigos.error, "No se pudieron cargar los códigos.")}
            </p>
          ) : items.length === 0 ? (
            <p className="rounded-lg border border-border bg-muted px-4 py-6 text-center text-sm text-muted-foreground">
              Este artículo todavía no tiene códigos equivalentes.
            </p>
          ) : (
            // <ul> y no <Table>: dentro de un diálogo el ancho es acotado y una
            // tabla obligaría a scrollear de costado.
            <ul className="scrollbar-fino max-h-72 space-y-2 overflow-y-auto">
              {items.map((codigo) =>
                editando?.id === codigo.id ? (
                  // La edición reemplaza la fila en su lugar: así se ve contra
                  // qué otros códigos se está comparando el que se corrige.
                  <li key={codigo.id} className="space-y-2 rounded-lg border border-primary p-3">
                    <div className="grid gap-2 sm:grid-cols-[1fr_1.4fr]">
                      <Input
                        value={codigoEditado}
                        onChange={(e) => setCodigoEditado(e.target.value)}
                        placeholder="Código"
                        autoComplete="off"
                        autoFocus
                      />
                      <Input
                        value={descripcionEditada}
                        onChange={(e) => setDescripcionEditada(e.target.value)}
                        placeholder="Referencia"
                        autoComplete="off"
                      />
                    </div>
                    <div className="flex justify-end gap-2">
                      <Button variant="outline" size="sm" onClick={() => setEditando(null)}>
                        <X className="size-4" />
                        Cancelar
                      </Button>
                      <Button
                        size="sm"
                        onClick={() => guardarEdicion.mutate(codigo)}
                        disabled={!codigoEditado.trim() || guardarEdicion.isPending}
                      >
                        {guardarEdicion.isPending ? (
                          <Loader2 className="size-4 animate-spin" />
                        ) : (
                          <Check className="size-4" />
                        )}
                        Guardar
                      </Button>
                    </div>
                  </li>
                ) : (
                  <li
                    key={codigo.id}
                    className="flex items-center gap-3 rounded-lg border border-border p-3"
                  >
                    <Barcode className="size-5 shrink-0 text-primary" />
                    <div className="min-w-0 flex-1">
                      {/* `break-words` y no truncate: el código es el dato que
                          hay que poder leer entero para compararlo, y cortado
                          se pierde justo eso. */}
                      <p className="break-words font-mono text-sm font-medium text-foreground">
                        {codigo.codigoEquivalente}
                      </p>
                      {codigo.descripcion && (
                        <p className="mt-0.5 break-words text-xs text-muted-foreground">
                          {codigo.descripcion}
                        </p>
                      )}
                    </div>
                    <Button
                      variant="ghost"
                      size="icon"
                      title="Editar"
                      aria-label={`Editar ${codigo.codigoEquivalente}`}
                      onClick={() => abrirEdicion(codigo)}
                    >
                      <Pencil className="size-4" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      title="Eliminar"
                      aria-label={`Eliminar ${codigo.codigoEquivalente}`}
                      onClick={() => setABorrar(codigo)}
                    >
                      <Trash2 className="size-4 text-destructive" />
                    </Button>
                  </li>
                ),
              )}
            </ul>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => onOpenChange(false)}>
              Cerrar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={aBorrar !== null} onOpenChange={(a) => !a && setABorrar(null)}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Eliminar código</DialogTitle>
            <DialogDescription>
              Se borra {aBorrar?.codigoEquivalente} de este artículo. El artículo no se toca.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2 sm:gap-2">
            <Button variant="outline" onClick={() => setABorrar(null)}>
              Cancelar
            </Button>
            <Button
              variant="destructive"
              disabled={borrar.isPending}
              onClick={() => aBorrar && borrar.mutate(aBorrar)}
            >
              {borrar.isPending && <Loader2 className="size-4 animate-spin" />}
              Eliminar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
