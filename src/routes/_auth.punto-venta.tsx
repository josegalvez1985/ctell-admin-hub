import { createFileRoute } from "@tanstack/react-router";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, ChevronRight, Minus, Plus, Search, ShoppingCart, Trash2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { AppLayout } from "@/components/ctell/AppLayout";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import { useUsuarioActual } from "@/hooks/use-usuario-actual";
import { api, ApiError, esActivo, type Articulo, type ListaDescuentos } from "@/lib/api";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { tituloPagina } from "@/lib/marca";

type Linea = Articulo & { cantidadVenta: number; precio: string };
const hoy = () => new Date().toISOString().slice(0, 19);
const dinero = (valor: number) =>
  new Intl.NumberFormat("es-PY", { maximumFractionDigits: 2 }).format(valor);
const numeroPrecio = (valor: string) => {
  const limpio = valor.trim().replace(/\s/g, "");
  if (limpio.includes(",")) return Number(limpio.replace(/\./g, "").replace(",", "."));
  if (/^\d{1,3}(\.\d{3})+$/.test(limpio)) return Number(limpio.replace(/\./g, ""));
  return Number(limpio.replace(/,/g, ""));
};
const precioVisible = (valor: string) => {
  const numero = numeroPrecio(valor);
  return Number.isFinite(numero) ? dinero(numero) : valor;
};
const errorTexto = (error: unknown) =>
  error instanceof ApiError ? error.message : "No se pudo completar la venta";

function PuntoVentaPage() {
  const { empresa } = useEmpresa();
  const { sucursal } = useSucursal();
  const { data: usuario } = useUsuarioActual();
  const queryClient = useQueryClient();
  const [busqueda, setBusqueda] = useState("");
  const [carrito, setCarrito] = useState<Linea[]>([]);
  const [idCliente, setIdCliente] = useState("");
  const [idLista, setIdLista] = useState("");
  const [idCondicion, setIdCondicion] = useState("");
  const [idMoneda, setIdMoneda] = useState("");
  const [idTalonario, setIdTalonario] = useState("");
  const [observacion, setObservacion] = useState("");

  const articulos = useInfiniteQuery({
    queryKey: ["pos-articulos", empresa?.id ?? null, sucursal?.id ?? null, busqueda],
    queryFn: ({ pageParam }) =>
      api.articulos.listar({
        idEmpresa: empresa!.id,
        busqueda,
        pagina: pageParam,
        tamanio: 50,
      }),
    initialPageParam: 1,
    getNextPageParam: (ultimaPagina) =>
      ultimaPagina.pagina * ultimaPagina.tamanio < ultimaPagina.total
        ? ultimaPagina.pagina + 1
        : undefined,
    enabled: empresa !== null && sucursal !== null,
  });
  const clientes = useQuery({ queryKey: ["personas"], queryFn: () => api.personas.listar() });
  const listas = useQuery({
    queryKey: ["listas-descuentos", empresa?.id ?? null],
    queryFn: () => api.listasDescuentos.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });
  const condiciones = useQuery({
    queryKey: ["condiciones-pago"],
    queryFn: () => api.condicionesPago.listar(),
  });
  const monedas = useQuery({
    queryKey: ["monedas", empresa?.id ?? null],
    queryFn: () => api.monedas.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });
  const talonarios = useQuery({
    queryKey: ["talonarios", empresa?.id ?? null, sucursal?.id ?? null],
    queryFn: () => api.talonarios.listar({ idEmpresa: empresa!.id, idSucursal: sucursal!.id }),
    enabled: empresa !== null && sucursal !== null,
  });
  const listaElegida = (listas.data?.items ?? []).find((lista) => String(lista.id) === idLista);
  const articulosDisponibles = articulos.data?.pages.flatMap((pagina) => pagina.items) ?? [];
  const descuento = listaElegida?.porcentajeDescuento ?? 0;
  const subtotal = carrito.reduce(
    (suma, linea) => suma + linea.cantidadVenta * (numeroPrecio(linea.precio) || 0),
    0,
  );
  const totalDescuento = Math.round(subtotal * descuento) / 100;
  const total = subtotal - totalDescuento;
  const agregar = (articulo: Articulo) =>
    setCarrito((actual) => {
      const existente = actual.find((linea) => linea.id === articulo.id);
      if (existente)
        return actual.map((linea) =>
          linea.id === articulo.id ? { ...linea, cantidadVenta: linea.cantidadVenta + 1 } : linea,
        );
      return [...actual, { ...articulo, cantidadVenta: 1, precio: "" }];
    });
  const actualizar = (id: number, cambios: Partial<Linea>) =>
    setCarrito((actual) =>
      actual.map((linea) => (linea.id === id ? { ...linea, ...cambios } : linea)),
    );
  const venta = useMutation({
    mutationFn: () =>
      api.ventas.crear({
        idEmpresa: empresa!.id,
        idSucursal: sucursal!.id,
        idUsuario: usuario!.id,
        ...(idCliente ? { idCliente: Number(idCliente) } : {}),
        ...(idLista ? { idListaDescuentos: Number(idLista) } : {}),
        idCondicionPago: Number(idCondicion),
        idMoneda: Number(idMoneda),
        fechaVenta: hoy(),
        idTalonario: Number(idTalonario),
        observacion,
        detalle: carrito.map((linea) => ({
          idArticulo: linea.id,
          cantidad: linea.cantidadVenta,
          precioUnitario: numeroPrecio(linea.precio),
        })),
      }),
    onSuccess: () => {
      toast.success("Venta registrada");
      setCarrito([]);
      setObservacion("");
      setIdTalonario("");
      queryClient.invalidateQueries({ queryKey: ["pos-articulos"] });
      queryClient.invalidateQueries({ queryKey: ["articulos"] });
    },
    onError: (error) => toast.error(errorTexto(error)),
  });
  const puedeConfirmar =
    empresa &&
    sucursal &&
    usuario &&
    carrito.length > 0 &&
    carrito.every((linea) => {
      const precio = numeroPrecio(linea.precio);
      return linea.precio.trim() !== "" && Number.isFinite(precio) && precio >= 0;
    }) &&
    idCondicion &&
    idMoneda &&
    idTalonario;

  return (
    <AppLayout active="/punto-venta" title="Punto de venta">
      <main className="min-h-[calc(100vh-4rem)] bg-muted/20 px-4 pb-28 pt-5 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-7xl space-y-5">
          <header className="flex flex-wrap items-end justify-between gap-3">
            <div>
              <div className="mb-2 flex items-center gap-2 text-xs font-medium uppercase tracking-[0.16em] text-primary">
                <ShoppingCart className="size-4" />
                Venta rápida
              </div>
              <h1 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
                Punto de venta
              </h1>
              <p className="mt-1 text-sm text-muted-foreground">
                {sucursal
                  ? `${empresa?.nombreEmpresa} · ${sucursal.nombreSucursal}`
                  : "Elegí una empresa y sucursal activas."}
              </p>
            </div>
            <Badge variant="secondary" className="px-3 py-1">
              {carrito.length} {carrito.length === 1 ? "artículo" : "artículos"}
            </Badge>
          </header>
          <div className="grid items-start gap-5 lg:grid-cols-[minmax(0,1fr)_390px]">
            <section className="space-y-4">
              <div className="surface-card p-4">
                <div className="relative">
                  <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
                  <Input
                    value={busqueda}
                    onChange={(e) => setBusqueda(e.target.value)}
                    placeholder="Buscar artículo por nombre o código..."
                    className="h-11 pl-9"
                  />
                </div>
              </div>
              <div className="surface-card max-h-[calc(100vh-13rem)] divide-y divide-border overflow-y-auto">
                {articulosDisponibles.map((articulo) => (
                  <article key={articulo.id} className="flex items-center gap-3 p-3 transition-colors hover:bg-muted/40 sm:px-4">
                    <div className="min-w-0 flex-1">
                      <h2 className="break-words text-xs font-semibold leading-tight text-foreground">
                        {articulo.nombreArticulo}
                      </h2>
                      <p className="break-words text-[0.7rem] leading-tight text-muted-foreground">
                        {articulo.codigoArticulo || "Sin código"}
                      </p>
                      {articulo.descripcion && (
                        <p className="mt-1 break-words text-[0.7rem] leading-tight text-muted-foreground/80">
                          {articulo.descripcion}
                        </p>
                      )}
                    </div>
                    <Badge className="shrink-0" variant={articulo.cantidadStock > 0 ? "outline" : "destructive"}>
                      {dinero(articulo.cantidadStock)} disp.
                    </Badge>
                    <Button
                      className="shrink-0"
                      variant="secondary"
                      disabled={articulo.cantidadStock <= 0}
                      onClick={() => agregar(articulo)}
                    >
                      <Plus className="size-4" />
                      <span className="hidden sm:inline">Agregar</span>
                    </Button>
                  </article>
                ))}
                {articulos.hasNextPage && (
                  <div className="flex justify-center p-3">
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => articulos.fetchNextPage()}
                      disabled={articulos.isFetchingNextPage}
                    >
                      {articulos.isFetchingNextPage ? "Cargando..." : "Mostrar más artículos"}
                    </Button>
                  </div>
                )}
              </div>
              {articulos.isError && (
                <p className="rounded-lg border border-destructive/30 bg-destructive/10 p-4 text-sm text-destructive">
                  No se pudieron cargar los artículos.
                </p>
              )}
              {!articulos.isPending && !articulos.isError && articulosDisponibles.length === 0 && (
                <div className="surface-card p-12 text-center text-sm text-muted-foreground">
                  No hay artículos que coincidan con la búsqueda.
                </div>
              )}
            </section>
            <aside className="surface-card max-h-[calc(100vh-6rem)] overflow-y-auto lg:sticky lg:top-5">
              <div className="border-b border-border bg-card px-5 py-4">
                <h2 className="font-semibold text-foreground">Venta actual</h2>
                <p className="mt-1 text-xs text-muted-foreground">
                  Cargá precios manuales y confirmá al finalizar.
                </p>
              </div>
              <div className="max-h-[360px] space-y-3 overflow-y-auto p-4">
                {carrito.length === 0 ? (
                  <div className="py-12 text-center text-sm text-muted-foreground">
                    <ShoppingCart className="mx-auto mb-3 size-8 opacity-40" />
                    El carrito está vacío
                  </div>
                ) : (
                  carrito.map((linea) => (
                    <div key={linea.id} className="rounded-lg border border-border p-3">
                      <div className="flex items-start justify-between gap-2">
                        <p className="min-w-0 flex-1 break-words text-xs font-medium leading-tight">
                          {linea.nombreArticulo}
                        </p>
                        <Button
                          variant="ghost"
                          size="icon"
                          className="size-7 shrink-0"
                          onClick={() =>
                            setCarrito((actual) => actual.filter((item) => item.id !== linea.id))
                          }
                        >
                          <Trash2 className="size-4 text-destructive" />
                        </Button>
                      </div>
                      <div className="mt-3 grid grid-cols-[auto_1fr_auto] items-center gap-2">
                        <div className="flex items-center rounded-md border border-border">
                          <Button
                            variant="ghost"
                            size="icon"
                            className="size-8"
                            onClick={() =>
                              actualizar(linea.id, {
                                cantidadVenta: Math.max(1, linea.cantidadVenta - 1),
                              })
                            }
                          >
                            <Minus className="size-3" />
                          </Button>
                          <span className="w-7 text-center text-sm">{linea.cantidadVenta}</span>
                          <Button
                            variant="ghost"
                            size="icon"
                            className="size-8"
                            onClick={() =>
                              actualizar(linea.id, {
                                cantidadVenta: Math.min(
                                  linea.cantidadStock,
                                  linea.cantidadVenta + 1,
                                ),
                              })
                            }
                          >
                            <Plus className="size-3" />
                          </Button>
                        </div>
                        <Input
                          value={linea.precio}
                          onChange={(e) => actualizar(linea.id, { precio: e.target.value })}
                          onBlur={() => actualizar(linea.id, { precio: precioVisible(linea.precio) })}
                          type="text"
                          inputMode="decimal"
                          placeholder="0,00"
                          className="h-8"
                        />
                        <span className="text-right text-sm font-semibold">
                          {dinero(linea.cantidadVenta * (numeroPrecio(linea.precio) || 0))}
                        </span>
                      </div>
                    </div>
                  ))
                )}
              </div>
              <div className="space-y-3 border-t border-border p-4">
                <Select value={idCliente} onValueChange={setIdCliente}>
                  <SelectTrigger>
                    <SelectValue placeholder="Cliente ocasional" />
                  </SelectTrigger>
                  <SelectContent>
                    {(clientes.data?.items ?? []).map((cliente) => (
                      <SelectItem key={cliente.id} value={String(cliente.id)}>
                        {cliente.nombreCompleto}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-1">
                  <Select
                    value={idLista || "__ninguna__"}
                    onValueChange={(valor) => setIdLista(valor === "__ninguna__" ? "" : valor)}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="Lista de descuentos" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="__ninguna__">Sin descuento</SelectItem>
                      {(listas.data?.items ?? [])
                        .filter((lista: ListaDescuentos) => esActivo(lista.vigente))
                        .map((lista) => (
                          <SelectItem key={lista.id} value={String(lista.id)}>
                            {lista.nombreLista} · {lista.porcentajeDescuento}%
                          </SelectItem>
                        ))}
                    </SelectContent>
                  </Select>
                  <Select value={idCondicion} onValueChange={setIdCondicion}>
                    <SelectTrigger>
                      <SelectValue placeholder="Condición de pago" />
                    </SelectTrigger>
                    <SelectContent>
                      {(condiciones.data?.items ?? []).map((condicion) => (
                        <SelectItem key={condicion.id} value={String(condicion.id)}>
                          {condicion.nombreCondicion}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <Select value={idMoneda} onValueChange={setIdMoneda}>
                  <SelectTrigger>
                    <SelectValue placeholder="Moneda" />
                  </SelectTrigger>
                  <SelectContent>
                    {(monedas.data?.items ?? [])
                      .filter((moneda) => esActivo(moneda.activo))
                      .map((moneda) => (
                        <SelectItem key={moneda.id} value={String(moneda.id)}>
                          {moneda.nombreMoneda}
                          {moneda.simbolo ? ` (${moneda.simbolo})` : ""}
                        </SelectItem>
                      ))}
                  </SelectContent>
                </Select>
                <Select value={idTalonario} onValueChange={setIdTalonario}>
                  <SelectTrigger>
                    <SelectValue placeholder="Talonario de comprobantes" />
                  </SelectTrigger>
                  <SelectContent>
                    {(talonarios.data?.items ?? [])
                      .filter((talonario) => esActivo(talonario.activo))
                      .map((talonario) => (
                        <SelectItem key={talonario.id} value={String(talonario.id)}>
                          {talonario.tipoComprobante} · {talonario.establecimiento}-
                          {talonario.puntoExpedicion} · desde {talonario.nroActual}
                        </SelectItem>
                      ))}
                  </SelectContent>
                </Select>
                <Textarea
                  value={observacion}
                  onChange={(e) => setObservacion(e.target.value)}
                  placeholder="Observación opcional"
                  className="min-h-16 resize-none"
                />
                <div className="space-y-2 border-t border-border pt-3 text-sm">
                  <div className="flex justify-between text-muted-foreground">
                    <span>Subtotal</span>
                    <span>{dinero(subtotal)}</span>
                  </div>
                  <div className="flex justify-between text-muted-foreground">
                    <span>Descuento {descuento > 0 ? `(${descuento}%)` : ""}</span>
                    <span>- {dinero(totalDescuento)}</span>
                  </div>
                  <div className="flex items-end justify-between pt-1">
                    <span className="font-semibold">Total</span>
                    <strong className="text-2xl text-primary">{dinero(total)}</strong>
                  </div>
                </div>
                <Button
                  className="h-11 w-full"
                  disabled={!puedeConfirmar || venta.isPending}
                  onClick={() => venta.mutate()}
                >
                  {venta.isPending ? (
                    "Registrando..."
                  ) : (
                    <>
                      <Check className="size-4" />
                      Confirmar venta
                      <ChevronRight className="ml-auto size-4" />
                    </>
                  )}
                </Button>
              </div>
            </aside>
          </div>
        </div>
      </main>
    </AppLayout>
  );
}

export const Route = createFileRoute("/_auth/punto-venta")({
  head: () => ({
    meta: [
      { title: tituloPagina("Punto de venta") },
      { name: "description", content: "Venta rápida con carrito y cobro." },
    ],
  }),
  component: PuntoVentaPage,
});
