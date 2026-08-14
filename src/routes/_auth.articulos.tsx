import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ImageUp, Loader2, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useRef, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { Combobox } from "@/components/ctell/Combobox";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { ImagenArticulo } from "@/components/ctell/ImagenArticulo";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
import { useTablaListado } from "@/hooks/use-tabla-listado";
import { api, ApiError, esActivo, type Articulo, type Estado } from "@/lib/api";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Textarea } from "@/components/ui/textarea";

/**
 * Los importes y cantidades se validan como texto y se convierten al enviar.
 *
 * Un `z.number()` sobre un `<input>` obliga a `valueAsNumber`, que devuelve NaN
 * mientras el campo está vacío y hace saltar el error antes de que la persona
 * termine de escribir. Con texto, el campo vacío es "" —un estado legítimo
 * durante la carga— y el número se arma recién en el submit.
 */
const decimal = (etiqueta: string) =>
  z
    .string()
    .trim()
    .refine((v) => v === "" || (!Number.isNaN(Number(v)) && Number(v) >= 0), {
      message: `${etiqueta} debe ser un número mayor o igual a 0`,
    });

const schema = z.object({
  nombreArticulo: z.string().trim().min(1, "Obligatorio").max(200, "Máximo 200 caracteres"),
  codigoArticulo: z.string().trim().max(50, "Máximo 50 caracteres"),
  descripcion: z.string().trim().max(1000, "Máximo 1000 caracteres"),
  // Los combobox devuelven strings; vacío significa "sin asignar".
  idCategoria: z.string(),
  idMoneda: z.string(),
  idUnidadMedida: z.string(),
  // El único importe obligatorio: la columna es NOT NULL.
  precioVenta: decimal("El precio de venta").refine((v) => v !== "", "Obligatorio"),
  precioUltimaCompra: decimal("El precio de compra"),
  cantidadStock: decimal("El stock"),
  cantidadMinima: decimal("La cantidad mínima"),
  activo: z.boolean(),
});

type FormValues = z.infer<typeof schema>;

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/** Tamaño máximo de la imagen. El BLOB viaja entero en cada petición. */
const IMAGEN_MAX_BYTES = 1024 * 1024;

/**
 * Cuántas filas se muestran de entrada, y cuántas suma cada "Mostrar más".
 *
 * El endpoint devuelve todo de una vez —poco para la red, mucho para el DOM—,
 * así que la tabla corta acá.
 */
const POR_PAGINA = 20;

/** Importe con separador de miles. Sin decimales fijos: 1500 no es "1.500,00". */
function formatearImporte(valor: number | null, simbolo: string | null): string {
  if (valor === null) return "—";
  const numero = new Intl.NumberFormat("es-PY", { maximumFractionDigits: 2 }).format(valor);
  return simbolo ? `${simbolo} ${numero}` : numero;
}

function ArticulosPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Articulo | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Articulo | null>(null);
  const [filtroCategoria, setFiltroCategoria] = useState<string>(SIN_FILTRO);

  // Los artículos son POR EMPRESA: la que se eligió al iniciar sesión.
  const { empresa } = useEmpresa();

  // La empresa entra en la queryKey: al cambiarla, TanStack Query trata el
  // listado como otra consulta en vez de mostrar en caché los de la anterior.
  // `enabled` evita pedir sin empresa (el provider hidrata tras montar).
  const { data, isPending, isError, error } = useQuery({
    queryKey: ["articulos", empresa?.id ?? null],
    queryFn: () => api.articulos.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  // Las categorías alimentan el filtro de la columna y el formulario. Misma
  // queryKey que usa la página de Categorías, así se comparte la respuesta.
  const { data: categorias } = useQuery({
    queryKey: ["categorias", empresa?.id ?? null],
    queryFn: () => api.categorias.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  const articulosFiltrados = (data?.items ?? []).filter(
    (a) => filtroCategoria === SIN_FILTRO || String(a.idCategoria) === filtroCategoria,
  );

  const eliminar = useMutation({
    mutationFn: (articulo: Articulo) => api.articulos.eliminar(articulo.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["articulos"] });
      toast.success("Artículo eliminado");
      setAEliminar(null);
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo eliminar"));
      setAEliminar(null);
    },
  });

  // Búsqueda por cualquier campo visible + orden por click en el header.
  const { busqueda, setBusqueda, orden, alternarOrden, resultado, termino } = useTablaListado(
    articulosFiltrados,
    (a) => [
      a.nombreArticulo,
      a.codigoArticulo,
      a.categoria,
      a.descripcion,
      esActivo(a.activo) ? "Activo" : "Inactivo",
    ],
  );

  const categoriasOpciones = (categorias?.items ?? []).map((c) => ({
    valor: String(c.id),
    etiqueta: c.nombreCategoria,
  }));

  // Cuántas filas se están mostrando. Se resetea al cambiar el filtro o la
  // búsqueda: seguir en "80 de 90" tras filtrar a 12 perdería el sentido.
  const [visibles, setVisibles] = useState(POR_PAGINA);
  const claveVista = `${filtroCategoria}|${termino}`;
  const [claveAnterior, setClaveAnterior] = useState(claveVista);
  if (claveVista !== claveAnterior) {
    // Ajuste de estado en render, no useEffect: React re-renderiza antes de
    // pintar, así que la lista nunca se ve con el valor viejo.
    setClaveAnterior(claveVista);
    setVisibles(POR_PAGINA);
  }

  const mostrados = resultado.slice(0, visibles);
  const quedan = resultado.length - mostrados.length;

  return (
    <AppLayout active="/articulos" title="Artículos">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">Artículos</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {empresa
                ? `Artículos de ${empresa.nombreEmpresa}.`
                : "Artículos de la empresa con la que iniciaste sesión."}
            </p>
          </div>
          <Button onClick={() => setCreando(true)} disabled={empresa === null}>
            <Plus className="size-4" />
            Nuevo artículo
          </Button>
        </div>

        {/* El filtro por categoría vive en el header de su columna. */}
        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre, código, categoría…"
            className="pl-9"
          />
        </div>

        {/* Sin empresa no hay nada que listar. Pasa si se entró con una sesión
            vieja, de antes de que el login pidiera elegirla. */}
        {empresa === null && !isPending && (
          <p className="rounded-lg border border-border px-3 py-6 text-center text-sm text-muted-foreground">
            No hay una empresa activa. Cerrá sesión y volvé a entrar eligiendo una.
          </p>
        )}

        {isPending && empresa !== null && (
          <div className="space-y-2">
            {[0, 1, 2, 3, 4].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </div>
        )}

        {isError && (
          <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
            {MENSAJE_ERROR(error, "No se pudo cargar la lista")}
          </p>
        )}

        {!isPending && !isError && empresa !== null && resultado.length === 0 && (
          <div className="surface-card px-3 py-16 text-center">
            <p className="text-sm text-muted-foreground">
              {termino
                ? `Sin resultados para "${busqueda.trim()}".`
                : filtroCategoria === SIN_FILTRO
                  ? "Esta empresa todavía no tiene artículos cargados."
                  : "Esa categoría todavía no tiene artículos cargados."}
            </p>
            {!termino && (
              <Button className="mt-4" onClick={() => setCreando(true)}>
                <Plus className="size-4" />
                Cargar el primero
              </Button>
            )}
          </div>
        )}

        {/* Móvil: tarjetas. Una tabla de 6 columnas en 360px obliga a scrollear
            de costado para leer una fila entera. */}
        {resultado.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {mostrados.map((articulo) => {
              const activo = esActivo(articulo.activo);
              const bajoMinimo = articulo.cantidadStock < articulo.cantidadMinima;

              return (
                <li key={articulo.id} className="surface-card p-4">
                  <div className="flex items-start gap-3">
                    <ImagenArticulo id={articulo.id} tieneImagen={articulo.tieneImagen} />
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold text-foreground">
                        {articulo.nombreArticulo}
                      </p>
                      <p className="mt-0.5 text-xs text-muted-foreground">
                        {articulo.codigoArticulo ? `${articulo.codigoArticulo} · ` : ""}
                        {articulo.categoria ?? "Sin categoría"}
                      </p>
                      <p className="mt-1 text-sm font-medium text-foreground">
                        {formatearImporte(articulo.precioVenta, articulo.simboloMoneda)}
                      </p>
                    </div>
                    <Badge variant={activo ? "secondary" : "outline"} className="shrink-0">
                      {activo ? "Activo" : "Inactivo"}
                    </Badge>
                  </div>

                  <p className="mt-2 text-xs text-muted-foreground">
                    Stock:{" "}
                    <span className={bajoMinimo ? "font-semibold text-destructive" : ""}>
                      {articulo.cantidadStock}
                      {articulo.abreviaturaUnidad ? ` ${articulo.abreviaturaUnidad}` : ""}
                    </span>
                    {bajoMinimo ? ` (mínimo ${articulo.cantidadMinima})` : ""}
                  </p>

                  <div className="mt-3 flex gap-2 border-t border-border pt-3">
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1"
                      onClick={() => setEditando(articulo)}
                    >
                      <Pencil className="size-4" />
                      Editar
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive"
                      onClick={() => setAEliminar(articulo)}
                    >
                      <Trash2 className="size-4" />
                      Eliminar
                    </Button>
                  </div>
                </li>
              );
            })}
          </ul>
        )}

        {resultado.length > 0 && (
          <div className="surface-card hidden overflow-x-auto sm:block">
            <Table>
              <TableHeader>
                <TableRow>
                  {/* Sin header: la columna de la miniatura no se ordena. */}
                  <TableHead className="w-14" />
                  <TableHeadOrdenable
                    direccion={orden?.campo === "nombreArticulo" ? orden.direccion : null}
                    onClick={() => alternarOrden("nombreArticulo")}
                  >
                    Artículo
                  </TableHeadOrdenable>
                  <TableHeadFiltrable
                    direccion={orden?.campo === "categoria" ? orden.direccion : null}
                    onOrdenar={() => alternarOrden("categoria")}
                    opciones={categoriasOpciones}
                    valor={filtroCategoria}
                    onFiltrar={setFiltroCategoria}
                    buscarPlaceholder="Buscar categoría…"
                  >
                    Categoría
                  </TableHeadFiltrable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "precioVenta" ? orden.direccion : null}
                    onClick={() => alternarOrden("precioVenta")}
                  >
                    Precio
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "cantidadStock" ? orden.direccion : null}
                    onClick={() => alternarOrden("cantidadStock")}
                  >
                    Stock
                  </TableHeadOrdenable>
                  <TableHeadOrdenable
                    direccion={orden?.campo === "activo" ? orden.direccion : null}
                    onClick={() => alternarOrden("activo")}
                  >
                    Estado
                  </TableHeadOrdenable>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {mostrados.map((articulo) => {
                  const activo = esActivo(articulo.activo);
                  // El stock bajo el mínimo se pinta en rojo: es el dato que
                  // justifica mirar esta tabla, y en gris pasa desapercibido.
                  const bajoMinimo = articulo.cantidadStock < articulo.cantidadMinima;

                  return (
                    <TableRow key={articulo.id}>
                      <TableCell>
                        <ImagenArticulo id={articulo.id} tieneImagen={articulo.tieneImagen} />
                      </TableCell>
                      <TableCell className="font-medium text-foreground">
                        {articulo.nombreArticulo}
                        {articulo.codigoArticulo && (
                          <span className="block text-xs font-normal text-muted-foreground">
                            {articulo.codigoArticulo}
                          </span>
                        )}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {articulo.categoria ?? "—"}
                      </TableCell>
                      <TableCell className="text-foreground">
                        {formatearImporte(articulo.precioVenta, articulo.simboloMoneda)}
                      </TableCell>
                      <TableCell className={bajoMinimo ? "font-semibold text-destructive" : ""}>
                        {articulo.cantidadStock}
                        {articulo.abreviaturaUnidad ? ` ${articulo.abreviaturaUnidad}` : ""}
                      </TableCell>
                      <TableCell>
                        <Badge variant={activo ? "secondary" : "outline"}>
                          {activo ? "Activo" : "Inactivo"}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-right">
                        <div className="flex justify-end gap-1">
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Editar"
                            aria-label={`Editar ${articulo.nombreArticulo}`}
                            onClick={() => setEditando(articulo)}
                          >
                            <Pencil className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Eliminar"
                            aria-label={`Eliminar ${articulo.nombreArticulo}`}
                            onClick={() => setAEliminar(articulo)}
                          >
                            <Trash2 className="size-4 text-destructive" />
                          </Button>
                        </div>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>
        )}

        {quedan > 0 && (
          <div className="flex justify-center">
            <Button variant="outline" onClick={() => setVisibles((v) => v + POR_PAGINA)}>
              Mostrar {Math.min(quedan, POR_PAGINA)} más
            </Button>
          </div>
        )}

        {data && resultado.length > 0 && (
          <p className="text-center text-xs text-muted-foreground">
            Mostrando {mostrados.length} de {resultado.length} artículo
            {resultado.length === 1 ? "" : "s"}
            {termino || filtroCategoria !== SIN_FILTRO ? ` (${data.items.length} en total)` : ""}
          </p>
        )}

        {/* Sin empresa no se abre: el alta necesita su id. */}
        {empresa !== null && (
          <ArticuloFormDialog
            open={creando || editando !== null}
            articulo={editando}
            idEmpresa={empresa.id}
            onClose={() => {
              setCreando(false);
              setEditando(null);
            }}
          />
        )}

        <AlertDialog open={aEliminar !== null} onOpenChange={(o) => !o && setAEliminar(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar {aEliminar?.nombreArticulo}?</AlertDialogTitle>
              <AlertDialogDescription>Esta acción no se puede deshacer.</AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancelar</AlertDialogCancel>
              <AlertDialogAction
                onClick={(e) => {
                  // Sin esto el AlertDialog se cierra antes de que la mutación
                  // termine y el error nunca se llega a mostrar.
                  e.preventDefault();
                  if (aEliminar) eliminar.mutate(aEliminar);
                }}
                disabled={eliminar.isPending}
                className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              >
                {eliminar.isPending && <Loader2 className="size-4 animate-spin" />}
                Eliminar
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </main>
    </AppLayout>
  );
}

/* -------------------------------------------------------------------------- */
/* Imagen                                                                      */
/* -------------------------------------------------------------------------- */

/**
 * Carga de la imagen de un artículo.
 *
 * Va por su propio endpoint (`PUT /articulos/imagen/:id`) y no por el
 * formulario: el binario no entra en el JSON del CRUD. Por eso se sube al
 * elegir el archivo en vez de esperar al submit — son dos peticiones distintas,
 * y encadenarlas haría que un error al guardar el artículo perdiera también la
 * imagen.
 *
 * Solo aparece en edición: sin id todavía no hay a qué artículo asociarla.
 */
function CargarImagen({ articulo }: { articulo: Articulo }) {
  const queryClient = useQueryClient();
  const inputRef = useRef<HTMLInputElement>(null);

  // Fuerza al <img> a repetir la petición tras subir: la URL es la misma, así
  // que sin remontar el componente el navegador sirve la imagen cacheada y
  // parecería que la subida no hizo nada.
  const [version, setVersion] = useState(0);

  const subir = useMutation({
    mutationFn: (archivo: File) => api.articulos.subirImagen(articulo.id, archivo),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["articulos"] });
      setVersion((v) => v + 1);
      toast.success("Imagen actualizada");
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudo subir la imagen")),
  });

  function alElegir(event: React.ChangeEvent<HTMLInputElement>) {
    const archivo = event.target.files?.[0];
    // Se limpia siempre: sin esto, elegir el mismo archivo dos veces seguidas
    // (tras corregirlo) no dispara el change y parece que se ignoró.
    event.target.value = "";
    if (!archivo) return;

    if (!archivo.type.startsWith("image/")) {
      toast.error("El archivo tiene que ser una imagen.");
      return;
    }
    if (archivo.size > IMAGEN_MAX_BYTES) {
      toast.error("La imagen no puede pesar más de 1 MB.");
      return;
    }

    subir.mutate(archivo);
  }

  return (
    <div className="flex items-center gap-3 rounded-lg border border-border p-3">
      <ImagenArticulo
        key={version}
        id={articulo.id}
        tieneImagen={articulo.tieneImagen || version > 0}
        className="size-14"
      />
      <div className="min-w-0 flex-1">
        <p className="text-sm font-medium text-foreground">Imagen</p>
        <p className="text-xs text-muted-foreground">PNG o JPG, hasta 1 MB.</p>
      </div>
      <input
        ref={inputRef}
        type="file"
        accept="image/png,image/jpeg,image/gif,image/webp,image/svg+xml"
        className="hidden"
        onChange={alElegir}
      />
      <Button
        type="button"
        variant="outline"
        size="sm"
        disabled={subir.isPending}
        onClick={() => inputRef.current?.click()}
      >
        {subir.isPending ? (
          <Loader2 className="size-4 animate-spin" />
        ) : (
          <ImageUp className="size-4" />
        )}
        {articulo.tieneImagen || version > 0 ? "Cambiar" : "Subir"}
      </Button>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Alta / Edición                                                              */
/* -------------------------------------------------------------------------- */

function ArticuloFormDialog({
  open,
  articulo,
  idEmpresa,
  onClose,
}: {
  open: boolean;
  articulo: Articulo | null;
  /** Empresa activa de la sesión. No es un campo del formulario. */
  idEmpresa: number;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const esEdicion = articulo !== null;

  // Las tres listas son de la misma empresa: un artículo no puede usar la
  // categoría de otra empresa. Mismas queryKeys que sus páginas, así TanStack
  // Query comparte las respuestas.
  const { data: categorias, isPending: cargandoCategorias } = useQuery({
    queryKey: ["categorias", idEmpresa],
    queryFn: () => api.categorias.listar({ idEmpresa }),
  });
  const { data: monedas, isPending: cargandoMonedas } = useQuery({
    queryKey: ["monedas", idEmpresa],
    queryFn: () => api.monedas.listar({ idEmpresa }),
  });
  const { data: unidades, isPending: cargandoUnidades } = useQuery({
    queryKey: ["unidades-medida", idEmpresa],
    queryFn: () => api.unidadesMedida.listar({ idEmpresa }),
  });

  const categoriasOpciones = (categorias?.items ?? []).map((c) => ({
    valor: String(c.id),
    etiqueta: c.nombreCategoria,
  }));
  const monedasOpciones = (monedas?.items ?? []).map((m) => ({
    valor: String(m.id),
    etiqueta: m.nombreMoneda,
    descripcion: m.simbolo ?? undefined,
  }));
  const unidadesOpciones = (unidades?.items ?? []).map((u) => ({
    valor: String(u.id),
    etiqueta: u.nombreUnidad,
    descripcion: u.abreviatura,
  }));

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    // Sin defaults React avisa por inputs no controlados. Un alta nace activa.
    // Los números van a string: los inputs son de texto (ver el comentario del
    // schema), y null se convierte en "" y no en "null".
    values: {
      nombreArticulo: articulo?.nombreArticulo ?? "",
      codigoArticulo: articulo?.codigoArticulo ?? "",
      descripcion: articulo?.descripcion ?? "",
      idCategoria: articulo?.idCategoria ? String(articulo.idCategoria) : "",
      idMoneda: articulo?.idMoneda ? String(articulo.idMoneda) : "",
      idUnidadMedida: articulo?.idUnidadMedida ? String(articulo.idUnidadMedida) : "",
      precioVenta: articulo ? String(articulo.precioVenta) : "",
      precioUltimaCompra:
        articulo?.precioUltimaCompra != null ? String(articulo.precioUltimaCompra) : "",
      cantidadStock: articulo ? String(articulo.cantidadStock) : "0",
      cantidadMinima: articulo ? String(articulo.cantidadMinima) : "0",
      activo: articulo ? esActivo(articulo.activo) : true,
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const activo: Estado = v.activo ? "A" : "I";

      // Los campos vacíos se omiten en vez de mandarse como "" o 0: el backend
      // trata lo ausente como "no cambiar", y un 0 explícito en precioCompra
      // pisaría el valor real con un dato que nadie ingresó.
      const opcionales = {
        ...(v.codigoArticulo ? { codigoArticulo: v.codigoArticulo } : {}),
        ...(v.descripcion ? { descripcion: v.descripcion } : {}),
        ...(v.idCategoria ? { idCategoria: Number(v.idCategoria) } : {}),
        ...(v.idMoneda ? { idMoneda: Number(v.idMoneda) } : {}),
        ...(v.idUnidadMedida ? { idUnidadMedida: Number(v.idUnidadMedida) } : {}),
        ...(v.cantidadMinima ? { cantidadMinima: Number(v.cantidadMinima) } : {}),
      };

      // En edición, precios y stock NO viajan: están bloqueados en el
      // formulario, así que el estado del form solo tiene el valor con el que
      // se abrió el diálogo. Mandarlo pisaría con ese dato viejo cualquier
      // cambio que un proceso de compra o de stock haya hecho mientras tanto.
      // El backend interpreta lo ausente como "no cambiar", que es justo lo
      // que se busca.
      return esEdicion
        ? api.articulos.actualizar(articulo.id, {
            nombreArticulo: v.nombreArticulo,
            ...opcionales,
            activo,
          })
        : api.articulos.crear({
            idEmpresa,
            nombreArticulo: v.nombreArticulo,
            precioVenta: Number(v.precioVenta),
            ...opcionales,
            ...(v.precioUltimaCompra ? { precioUltimaCompra: Number(v.precioUltimaCompra) } : {}),
            ...(v.cantidadStock ? { cantidadStock: Number(v.cantidadStock) } : {}),
          });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["articulos"] });
      toast.success(esEdicion ? "Artículo actualizado" : "Artículo creado");
      onClose();
    },
    onError: (e) =>
      toast.error(
        MENSAJE_ERROR(e, esEdicion ? "No se pudo actualizar" : "No se pudo crear el artículo"),
      ),
  });

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      {/* Más alto que los demás: son once campos y sin scroll el footer queda
          fuera de la pantalla en un portátil. */}
      <DialogContent className="scrollbar-fino max-h-[90vh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar artículo" : "Nuevo artículo"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos del artículo."
              : "Agregá un artículo a la empresa con la que iniciaste sesión."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            {/* Solo en edición: la imagen se sube contra el id del artículo,
                que en el alta todavía no existe. */}
            {esEdicion && <CargarImagen articulo={articulo} />}

            <FormField
              control={form.control}
              name="nombreArticulo"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nombre del artículo</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="Cemento Portland 50 kg" autoComplete="off" />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="codigoArticulo"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Código</FormLabel>
                  <FormControl>
                    <Input {...field} placeholder="ART-001" autoComplete="off" />
                  </FormControl>
                  <FormDescription>Opcional. Código interno o de barras.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="idCategoria"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Categoría</FormLabel>
                  <FormControl>
                    <Combobox
                      opciones={categoriasOpciones}
                      value={field.value}
                      onChange={field.onChange}
                      placeholder="Sin categoría"
                      buscarPlaceholder="Buscar categoría…"
                      cargando={cargandoCategorias}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            {/* PRECIOS Y STOCK — bloque aparte, y bloqueado en edición.

                Los tres valores de acá los gobiernan procesos, no una carga
                manual: el precio de última compra sale de una compra, el stock
                de los movimientos, y el precio de venta se fija con criterio
                comercial. Editarlos a mano desde el ABM los dejaría
                desalineados con esos procesos sin dejar rastro del cambio.

                En el ALTA sí se editan: son los valores iniciales, y
                PRECIO_VENTA es NOT NULL — bloquearlo también acá haría
                imposible crear un artículo.

                `fieldset disabled` deshabilita todo lo que contiene de una vez,
                sin repetir la condición en cada Input. */}
            <fieldset
              disabled={esEdicion}
              className="space-y-4 rounded-lg border border-border p-3"
            >
              <legend className="px-1 text-sm font-medium text-foreground">Precios y stock</legend>

              {esEdicion && (
                <p className="text-xs text-muted-foreground">
                  Se actualizan desde las compras y los movimientos de stock, no desde acá.
                </p>
              )}

              <div className="grid gap-4 sm:grid-cols-2">
                <FormField
                  control={form.control}
                  name="precioVenta"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Precio de venta</FormLabel>
                      <FormControl>
                        {/* inputMode decimal abre el teclado numérico en móvil
                            sin las flechas de un type="number". */}
                        <Input {...field} inputMode="decimal" placeholder="0" autoComplete="off" />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <FormField
                  control={form.control}
                  name="precioUltimaCompra"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Precio última compra</FormLabel>
                      <FormControl>
                        <Input {...field} inputMode="decimal" placeholder="0" autoComplete="off" />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
              </div>

              <FormField
                control={form.control}
                name="cantidadStock"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Stock actual</FormLabel>
                    <FormControl>
                      <Input {...field} inputMode="decimal" placeholder="0" autoComplete="off" />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </fieldset>

            <FormField
              control={form.control}
              name="idMoneda"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Moneda</FormLabel>
                  <FormControl>
                    <Combobox
                      opciones={monedasOpciones}
                      value={field.value}
                      onChange={field.onChange}
                      placeholder="Sin moneda"
                      buscarPlaceholder="Buscar moneda…"
                      cargando={cargandoMonedas}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            {/* La cantidad mínima queda FUERA del bloque bloqueado: es una
                política del negocio —cuándo avisar que falta stock— y no un
                valor que calcule ningún proceso, así que se edita siempre. */}
            <FormField
              control={form.control}
              name="cantidadMinima"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Cantidad mínima</FormLabel>
                  <FormControl>
                    <Input {...field} inputMode="decimal" placeholder="0" autoComplete="off" />
                  </FormControl>
                  <FormDescription>Avisa cuando el stock baja de acá.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            {/* Fuera del fieldset bloqueado: la moneda define en qué unidad se
                expresan los precios, y corregirla no altera ningún importe. */}

            <FormField
              control={form.control}
              name="idUnidadMedida"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Unidad de medida</FormLabel>
                  <FormControl>
                    <Combobox
                      opciones={unidadesOpciones}
                      value={field.value}
                      onChange={field.onChange}
                      placeholder="Sin unidad"
                      buscarPlaceholder="Buscar unidad…"
                      cargando={cargandoUnidades}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="descripcion"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Descripción</FormLabel>
                  <FormControl>
                    <Textarea
                      {...field}
                      rows={3}
                      placeholder="Detalle del artículo."
                      className="resize-none"
                    />
                  </FormControl>
                  <FormDescription>Opcional. Hasta 1000 caracteres.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            {/* Solo en edición: el alta siempre nace activa. */}
            {esEdicion && (
              <FormField
                control={form.control}
                name="activo"
                render={({ field }) => (
                  <FormItem className="flex items-center justify-between rounded-lg border border-border p-3">
                    <div className="space-y-0.5">
                      <FormLabel>Activo</FormLabel>
                      <FormDescription>
                        Un artículo inactivo deja de ofrecerse en los formularios.
                      </FormDescription>
                    </div>
                    <FormControl>
                      <Switch checked={field.value} onCheckedChange={field.onChange} />
                    </FormControl>
                  </FormItem>
                )}
              />
            )}

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onClose}>
                Cancelar
              </Button>
              <Button type="submit" disabled={guardar.isPending}>
                {guardar.isPending && <Loader2 className="size-4 animate-spin" />}
                {guardar.isPending
                  ? "Guardando…"
                  : esEdicion
                    ? "Guardar cambios"
                    : "Crear artículo"}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}

export const Route = createFileRoute("/_auth/articulos")({
  head: () => ({
    meta: [
      { title: "Artículos | CTELL" },
      { name: "description", content: "Artículos por empresa del sistema." },
    ],
  }),
  component: ArticulosPage,
});
