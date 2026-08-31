import { createFileRoute } from "@tanstack/react-router";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Check,
  ChevronRight,
  CreditCard,
  Minus,
  Plus,
  Search,
  ShoppingCart,
  Trash2,
} from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { AppLayout } from "@/components/ctell/AppLayout";
import { InputMoneda } from "@/components/ctell/InputMoneda";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { useSucursal } from "@/components/ctell/sucursal-provider";
import { useUsuarioActual } from "@/hooks/use-usuario-actual";
import {
  api,
  ApiError,
  esActivo,
  requiereCuentaBancaria,
  type Articulo,
  type CanalPago,
  type CuentaBancaria,
  type Iva,
  type ListaDescuentos,
} from "@/lib/api";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
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
import { formatearMoneda, numeroMoneda } from "@/lib/moneda";

type Linea = Articulo & {
  cantidadVenta: number;
  precio: string;
  idIva: string;
  /**
   * De qué lote sale la línea. Se elige por línea porque `VENTAS_DETALLES`
   * guarda **un solo** `ID_LOTE`: las 10 unidades salen todas del mismo lote, no
   * se reparten. Vacío hasta que carguen los lotes del artículo.
   */
  idLote: string;
};
const hoy = () => new Date().toISOString().slice(0, 19);

/**
 * El impuesto **contenido** en un monto que ya lo incluye.
 *
 * Replica el cálculo del backend, redondeos incluidos: si difirieran, el IVA de
 * la pantalla no coincidiría con el de la venta ya guardada, y esa diferencia
 * de un guaraní no hay forma de explicarla en el libro de ventas.
 *
 * Con `gravadaDivision` se divide para el gravado y el IVA sale por resta, así
 * `gravado + iva` da el neto exacto. Sin ella (tasas viejas) se cae al método
 * anterior. Nunca `monto * porcentaje / 100`: eso cobraría impuesto sobre
 * impuesto — 110.000 al 10% contiene 10.000, no 11.000.
 */
const ivaContenido = (monto: number, tasa: Iva | undefined) => {
  if (!tasa) return 0;
  if (tasa.gravadaDivision !== null && tasa.gravadaDivision > 0) {
    return monto - Math.round((monto / tasa.gravadaDivision) * 100) / 100;
  }
  // La exenta tiene `ivaDivision = 0`: sin la guarda daría Infinity.
  if (!tasa.ivaDivision || tasa.ivaDivision <= 0) return 0;
  return Math.round((monto / tasa.ivaDivision) * 100) / 100;
};
/**
 * Valor del combo de lista de descuentos para "sin descuento".
 *
 * Radix no acepta un `<SelectItem value="">`, así que la opción necesita un
 * valor propio. Y hace falta poder ELEGIRLA —no alcanza con dejar el campo
 * vacío—: una vez que el cajero elige una lista, el Select no se deselecciona
 * solo, y sin esta opción no habría forma de volver atrás sin recargar.
 */
const SIN_DESCUENTO = "sin-descuento";

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
  const [idCanalPago, setIdCanalPago] = useState("");
  const [montoCobro, setMontoCobro] = useState("");
  const [referenciaCobro, setReferenciaCobro] = useState("");
  const [idCuentaBancaria, setIdCuentaBancaria] = useState("");

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
  const canales = useQuery({
    queryKey: ["canales-pagos"],
    queryFn: () => api.canalesPagos.listar(),
  });
  const cuentas = useQuery({
    queryKey: ["cuentas-bancarias", empresa?.id ?? null],
    queryFn: () => api.cuentasBancarias.listar(empresa!.id),
    enabled: empresa !== null,
  });
  /**
   * Los lotes de los artículos que están en el carrito, en una sola consulta.
   *
   * Se piden todos juntos y no uno por línea: `useQuery` no se puede llamar
   * dentro de un `map`, y una consulta por artículo dispararía N peticiones cada
   * vez que cambia el carrito.
   */
  const idsEnCarrito = carrito.map((linea) => linea.id);
  const lotes = useQuery({
    queryKey: ["pos-lotes", empresa?.id ?? null, sucursal?.id ?? null, idsEnCarrito.join(",")],
    queryFn: async () => {
      const paginas = await Promise.all(
        idsEnCarrito.map((idArticulo) =>
          api.lotes.listar({
            idEmpresa: empresa!.id,
            idSucursal: sucursal!.id,
            idArticulo,
            tamanio: 200,
          }),
        ),
      );
      return paginas.flatMap((pagina) => pagina.items);
    },
    enabled: empresa !== null && sucursal !== null && idsEnCarrito.length > 0,
  });
  /** Lotes con existencia de un artículo, el que vence primero adelante. */
  const lotesDe = (idArticulo: number) =>
    (lotes.data ?? [])
      .filter((lote) => lote.idArticulo === idArticulo && lote.cantidadDispon > 0)
      .sort((a, b) => (a.fechaVencimiento ?? "9999").localeCompare(b.fechaVencimiento ?? "9999"));
  const tasasIva = useQuery({ queryKey: ["iva"], queryFn: () => api.iva.listar() });
  const listaTasas = tasasIva.data?.items ?? [];
  const ivaPorId = new Map(listaTasas.map((tasa) => [String(tasa.id), tasa]));
  /**
   * La tasa con la que entra cada artículo al carrito: el 10% si existe, si no
   * la primera cargada. Precargarla es lo que mantiene rápida la venta — el
   * cajero sólo toca el select en la línea excepcional (exenta, 5%).
   */
  const ivaPorDefecto = String(
    (listaTasas.find((tasa) => tasa.porcentaje === 10) ?? listaTasas[0])?.id ?? "",
  );
  const listaElegida = (listas.data?.items ?? []).find((lista) => String(lista.id) === idLista);
  const canalElegido = (canales.data?.items ?? []).find(
    (canal) => String(canal.id) === idCanalPago,
  );
  const articulosDisponibles = articulos.data?.pages.flatMap((pagina) => pagina.items) ?? [];
  const descuento = listaElegida?.porcentajeDescuento ?? 0;
  /**
   * Si la línea entró antes de que cargaran las tasas se queda sin `idIva`;
   * ahí vale el default. Resolverlo en un solo lugar evita que la pantalla
   * muestre una tasa y el backend guarde otra.
   */
  const ivaDeLinea = (linea: Linea) => linea.idIva || ivaPorDefecto;
  /**
   * El lote de la línea: el elegido, o el que vence primero **con existencia
   * suficiente para la cantidad cargada**.
   *
   * El default mira la cantidad y no sólo la fecha: si el lote más viejo tiene 4
   * y se venden 10, preseleccionarlo obligaría al cajero a corregir algo que el
   * sistema podía resolver. Si ninguno alcanza queda vacío y el aviso lo dice.
   */
  const loteDeLinea = (linea: Linea) => {
    if (linea.idLote) return linea.idLote;
    const alcanza = lotesDe(linea.id).find((lote) => lote.cantidadDispon >= linea.cantidadVenta);
    return alcanza ? String(alcanza.id) : "";
  };
  /**
   * Cuántas unidades tiene el lote elegido. Es el techo real de la línea: el
   * stock del artículo puede ser 40 repartido en cuatro lotes de 10, y de esta
   * línea sólo se pueden vender las del lote que sale.
   */
  const dispoDeLinea = (linea: Linea) =>
    lotesDe(linea.id).find((lote) => String(lote.id) === loteDeLinea(linea))?.cantidadDispon ?? 0;
  const subtotal = carrito.reduce(
    (suma, linea) => suma + linea.cantidadVenta * (numeroMoneda(linea.precio) || 0),
    0,
  );
  const totalDescuento = Math.round(subtotal * descuento) / 100;
  // El IVA NO se suma al total: ya viene dentro del precio. Se muestra el
  // impuesto contenido en el neto, que es lo que va al libro de ventas.
  const total = subtotal - totalDescuento;
  const netoDeLinea = (linea: Linea) => {
    const bruto = linea.cantidadVenta * (numeroMoneda(linea.precio) || 0);
    return bruto - Math.round(bruto * descuento) / 100;
  };
  const totalIva = carrito.reduce(
    (suma, linea) => suma + ivaContenido(netoDeLinea(linea), ivaPorId.get(ivaDeLinea(linea))),
    0,
  );
  const agregar = (articulo: Articulo) =>
    setCarrito((actual) => {
      const existente = actual.find((linea) => linea.id === articulo.id);
      if (existente)
        return actual.map((linea) =>
          linea.id === articulo.id ? { ...linea, cantidadVenta: linea.cantidadVenta + 1 } : linea,
        );
      return [
        ...actual,
        { ...articulo, cantidadVenta: 1, precio: "", idIva: ivaPorDefecto, idLote: "" },
      ];
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
        // Sin lista el campo no viaja: el backend lo toma como 0% y deja
        // ID_LISTA_DESCUENTOS en NULL. Mandar Number("") daría 0, que es un id
        // que no existe y haría fallar la venta entera.
        ...(idLista && idLista !== SIN_DESCUENTO ? { idListaDescuentos: Number(idLista) } : {}),
        idCondicionPago: Number(idCondicion),
        idMoneda: Number(idMoneda),
        fechaVenta: hoy(),
        idTalonario: Number(idTalonario),
        observacion,
        detalle: carrito.map((linea) => ({
          idArticulo: linea.id,
          cantidad: linea.cantidadVenta,
          precioUnitario: numeroMoneda(linea.precio),
          idIva: Number(ivaDeLinea(linea)),
          idLote: Number(loteDeLinea(linea)),
        })),
      }),
    onSuccess: (data) => {
      toast.success(`Venta #${data.id} registrada`);
      setMontoCobro(formatearMoneda(data.total));
      queryClient.invalidateQueries({ queryKey: ["pos-articulos"] });
      queryClient.invalidateQueries({ queryKey: ["articulos"] });
      // La venta descontó de los lotes: sin esto el disponible que se ve en el
      // selector queda con el valor de antes de vender.
      queryClient.invalidateQueries({ queryKey: ["pos-lotes"] });
      queryClient.invalidateQueries({ queryKey: ["lotes"] });
    },
    onError: (error) => toast.error(errorTexto(error)),
  });
  const puedeConfirmar =
    empresa &&
    sucursal &&
    usuario &&
    carrito.length > 0 &&
    carrito.every((linea) => {
      const precio = numeroMoneda(linea.precio);
      // Exigir la tasa: sin ella el backend guardaría la venta con IVA 0 y el
      // libro de ventas quedaría mal sin que nadie vea un error.
      // Exigir lote y que alcance: el backend rechaza igual con el lote
      // bloqueado, pero fallar recién al confirmar pierde toda la venta cargada.
      return (
        linea.precio.trim() !== "" &&
        Number.isFinite(precio) &&
        precio >= 0 &&
        ivaDeLinea(linea) !== "" &&
        loteDeLinea(linea) !== "" &&
        dispoDeLinea(linea) >= linea.cantidadVenta
      );
    }) &&
    // idLista NO se exige: una venta sin lista es una venta a precio de
    // etiqueta. Antes obligaba a cargar una lista de 0% sólo para poder cobrar.
    idCondicion &&
    idMoneda &&
    idTalonario;
  const resetVenta = () => {
    venta.reset();
    setCarrito([]);
    setObservacion("");
    setIdTalonario("");
    setIdCanalPago("");
    setMontoCobro("");
    setReferenciaCobro("");
    setIdCuentaBancaria("");
  };
  const cobro = useMutation({
    mutationFn: () =>
      api.ventasCobros.crear({
        idVenta: venta.data!.id,
        idEmpresa: empresa!.id,
        idCanalPago: Number(idCanalPago),
        idMoneda: Number(idMoneda),
        monto: numeroMoneda(montoCobro),
        fechaCobro: hoy(),
        ...(referenciaCobro ? { referencia: referenciaCobro } : {}),
        ...(idCuentaBancaria ? { idCuentaBancaria: Number(idCuentaBancaria) } : {}),
      }),
    onSuccess: () => {
      toast.success("Cobro registrado");
      resetVenta();
    },
    onError: (error) => toast.error(errorTexto(error)),
  });
  /**
   * El cobro no puede superar el total recién guardado. El backend lo rechaza
   * igual con la cabecera bloqueada; esto sólo evita el viaje para fallar.
   */
  const montoCobroNumero = numeroMoneda(montoCobro);
  const excedeTotal =
    Number.isFinite(montoCobroNumero) && montoCobroNumero > (venta.data?.total ?? 0);
  const puedeConfirmarCobro =
    venta.isSuccess &&
    venta.data &&
    idCanalPago &&
    idMoneda &&
    Number.isFinite(montoCobroNumero) &&
    montoCobroNumero > 0 &&
    !excedeTotal;

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
                  <article
                    key={articulo.id}
                    className="flex items-center gap-3 p-3 transition-colors hover:bg-muted/40 sm:px-4"
                  >
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
                    <Badge
                      className="shrink-0"
                      variant={articulo.cantidadStock > 0 ? "outline" : "destructive"}
                    >
                      {formatearMoneda(articulo.cantidadStock)} disp.
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
                                // El techo es el LOTE elegido, no el stock del
                                // artículo: 40 en cuatro lotes de 10 no permiten
                                // vender 11 en una línea.
                                cantidadVenta: Math.min(
                                  dispoDeLinea(linea) || linea.cantidadStock,
                                  linea.cantidadVenta + 1,
                                ),
                              })
                            }
                          >
                            <Plus className="size-3" />
                          </Button>
                        </div>
                        <InputMoneda
                          value={linea.precio}
                          onChange={(valor) => actualizar(linea.id, { precio: valor })}
                          placeholder="0"
                          className="h-8"
                        />
                        <span className="text-right text-sm font-semibold">
                          {formatearMoneda(linea.cantidadVenta * (numeroMoneda(linea.precio) || 0))}
                        </span>
                      </div>
                      <div className="mt-2 flex items-center gap-2">
                        <Select
                          value={ivaDeLinea(linea)}
                          onValueChange={(valor) => actualizar(linea.id, { idIva: valor })}
                        >
                          <SelectTrigger className="h-7 w-28 text-xs">
                            <SelectValue placeholder="IVA *" />
                          </SelectTrigger>
                          <SelectContent>
                            {listaTasas.map((tasa) => (
                              <SelectItem key={tasa.id} value={String(tasa.id)}>
                                {tasa.descripcion ?? `${tasa.porcentaje}%`}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                        <span className="text-[0.7rem] text-muted-foreground">
                          IVA{" "}
                          {formatearMoneda(
                            ivaContenido(netoDeLinea(linea), ivaPorId.get(ivaDeLinea(linea))),
                          )}
                        </span>
                      </div>
                      {/* El lote: una línea sale de UNO solo, así que si ninguno
                          tiene suficiente hay que bajar la cantidad o cargar el
                          artículo en dos ventas. */}
                      <div className="mt-2">
                        <Select
                          value={loteDeLinea(linea)}
                          onValueChange={(valor) => actualizar(linea.id, { idLote: valor })}
                        >
                          <SelectTrigger className="h-7 w-full text-xs">
                            <SelectValue placeholder="Elegí el lote *" />
                          </SelectTrigger>
                          <SelectContent>
                            {lotesDe(linea.id).map((lote) => (
                              <SelectItem
                                key={lote.id}
                                value={String(lote.id)}
                                disabled={lote.cantidadDispon < linea.cantidadVenta}
                              >
                                {lote.numeroLote === null
                                  ? "Sin número"
                                  : `Lote ${lote.numeroLote}`}
                                {lote.fechaVencimiento ? ` · vence ${lote.fechaVencimiento}` : ""} ·{" "}
                                {lote.cantidadDispon} disp.
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                        {lotesDe(linea.id).length === 0 && !lotes.isPending && (
                          <p className="mt-1 text-[0.7rem] text-destructive">
                            Sin lotes con existencia.
                          </p>
                        )}
                        {loteDeLinea(linea) === "" && lotesDe(linea.id).length > 0 && (
                          <p className="mt-1 text-[0.7rem] text-destructive">
                            Ningún lote tiene {linea.cantidadVenta} unidades. Bajá la cantidad o
                            elegí otro.
                          </p>
                        )}
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
                  <Select value={idLista} onValueChange={setIdLista}>
                    <SelectTrigger>
                      {/* Sin asterisco: el campo dejó de ser obligatorio, y el
                          placeholder dice qué pasa si no se toca. */}
                      <SelectValue placeholder="Sin descuento" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value={SIN_DESCUENTO}>Sin descuento</SelectItem>
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
                    <span>{formatearMoneda(subtotal)}</span>
                  </div>
                  <div className="flex justify-between text-muted-foreground">
                    <span>Descuento {descuento > 0 ? `(${descuento}%)` : ""}</span>
                    <span>- {formatearMoneda(totalDescuento)}</span>
                  </div>
                  {/* "incluido", no un renglón más a sumar: el precio ya lo trae. */}
                  <div className="flex justify-between text-muted-foreground">
                    <span>IVA incluido</span>
                    <span>{formatearMoneda(totalIva)}</span>
                  </div>
                  <div className="flex items-end justify-between pt-1">
                    <span className="font-semibold">Total</span>
                    <strong className="text-2xl text-primary">{formatearMoneda(total)}</strong>
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

      {/*
        Se abre solo al guardar la venta. Antes esto reemplazaba al carrito en
        el panel derecho, y el cajero podía no registrar nunca el cobro sin
        notarlo: el panel se veía igual de "normal" que el carrito. Un modal
        obliga a decidir — cobrar o salir explícitamente sin cobro.

        No se cierra al hacer clic afuera ni con Escape a propósito: la venta ya
        está guardada y el cobro es el paso que falta.
      */}
      <Dialog open={venta.isSuccess && venta.data !== undefined}>
        <DialogContent
          className="max-w-md"
          onPointerDownOutside={(e) => e.preventDefault()}
          onEscapeKeyDown={(e) => e.preventDefault()}
        >
          <DialogHeader>
            <div className="mb-1 flex items-center gap-2 text-xs font-medium uppercase tracking-[0.16em] text-primary">
              <CreditCard className="size-4" />
              Cobro
            </div>
            <DialogTitle>¿Cómo se cobra esta venta?</DialogTitle>
            <p className="text-sm text-muted-foreground">
              Venta {venta.data?.numeroVenta ?? `#${venta.data?.id}`} ·{" "}
              <strong className="text-foreground">{formatearMoneda(venta.data?.total ?? 0)}</strong>
            </p>
          </DialogHeader>

          <div className="space-y-3">
            {/*
              Botonera y no un <Select>: en una caja los canales son cuatro o
              cinco y se elige uno en cada venta. Un clic contra tres (abrir,
              buscar, elegir) es la diferencia entre una cola que avanza y una
              que no.
            */}
            <div>
              <p className="mb-2 text-xs font-medium text-muted-foreground">Forma de cobro *</p>
              <div className="grid grid-cols-2 gap-2">
                {(canales.data?.items ?? [])
                  .filter((c: CanalPago) => esActivo(c.activo))
                  .map((c) => (
                    <Button
                      key={c.id}
                      type="button"
                      variant={String(c.id) === idCanalPago ? "default" : "outline"}
                      className="h-11 justify-start"
                      onClick={() => {
                        setIdCanalPago(String(c.id));
                        // Pasar a efectivo esconde el select de cuenta, y sin
                        // limpiarlo se mandaría la cuenta que quedó elegida.
                        if (!requiereCuentaBancaria(c)) setIdCuentaBancaria("");
                      }}
                    >
                      {String(c.id) === idCanalPago && <Check className="size-4" />}
                      <span className="truncate">{c.nombreCanal}</span>
                    </Button>
                  ))}
              </div>
            </div>

            <div>
              <p className="mb-2 text-xs font-medium text-muted-foreground">Monto cobrado *</p>
              <InputMoneda
                value={montoCobro}
                onChange={setMontoCobro}
                className="h-11 text-lg font-semibold"
                placeholder="0"
              />
              {excedeTotal && (
                <p className="mt-1 text-xs text-destructive">
                  El monto supera el total de la venta ({formatearMoneda(venta.data?.total ?? 0)}).
                </p>
              )}
            </div>

            <Input
              value={referenciaCobro}
              onChange={(e) => setReferenciaCobro(e.target.value)}
              placeholder="Referencia (N° transferencia, QR…)"
            />

            {idCanalPago && requiereCuentaBancaria(canalElegido) && (
              <Select value={idCuentaBancaria} onValueChange={setIdCuentaBancaria}>
                <SelectTrigger>
                  <SelectValue placeholder="Cuenta bancaria receptora" />
                </SelectTrigger>
                <SelectContent>
                  {(cuentas.data?.items ?? [])
                    .filter((c: CuentaBancaria) => esActivo(c.activo))
                    .map((c) => (
                      <SelectItem key={c.id} value={String(c.id)}>
                        {c.banco} · {c.numeroCuenta}
                      </SelectItem>
                    ))}
                </SelectContent>
              </Select>
            )}

            <div className="space-y-2 pt-1">
              <Button
                className="h-11 w-full"
                disabled={!puedeConfirmarCobro || cobro.isPending}
                onClick={() => cobro.mutate()}
              >
                {cobro.isPending ? (
                  "Registrando..."
                ) : (
                  <>
                    <Check className="size-4" />
                    Confirmar cobro
                    <ChevronRight className="ml-auto size-4" />
                  </>
                )}
              </Button>
              {/*
                La salida sin cobro existe y se ve: una venta a crédito es
                legítima y queda con saldo para la pantalla de Cobros.
              */}
              <Button
                variant="ghost"
                className="h-9 w-full text-xs"
                onClick={resetVenta}
                disabled={cobro.isPending}
              >
                Registrar sin cobro (queda con saldo)
              </Button>
            </div>
          </div>
        </DialogContent>
      </Dialog>
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
