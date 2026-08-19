import { zodResolver } from "@hookform/resolvers/zod";
import { createFileRoute } from "@tanstack/react-router";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ImageUp, Loader2, MapPin, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { AppLayout } from "@/components/ctell/AppLayout";
import { SelectorModal } from "@/components/ctell/SelectorModal";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { ArticuloUbicacionesDialog } from "@/components/ctell/ArticuloUbicacionesDialog";
import { ImagenArticulo } from "@/components/ctell/ImagenArticulo";
import { SIN_FILTRO, TableHeadFiltrable } from "@/components/ctell/TableHeadFiltrable";
import { TableHeadOrdenable } from "@/components/ctell/TableHeadOrdenable";
// El helper entra con alias: `esGasto` a secas chocaría con el campo del
// formulario y con la variable de cada fila, que se llaman igual que la columna.
import {
  api,
  ApiError,
  esActivo,
  esGasto as esGastoArticulo,
  type Articulo,
  type Estado,
  type Rol,
} from "@/lib/api";
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
import { tituloPagina } from "@/lib/marca";

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
  // Lo único numérico que se carga acá. Los precios y el stock salieron de la
  // tabla: el costo va en cada lote y el stock es la suma de sus cantidades.
  // La mínima queda porque es una política del negocio, no una medición.
  cantidadMinima: decimal("La cantidad mínima"),
  // Booleano en el formulario, "S"/"N" en la API: el Switch trabaja con
  // booleanos y la traducción se hace una sola vez, al armar la mutación.
  esGasto: z.boolean(),
  activo: z.boolean(),
});

type FormValues = z.infer<typeof schema>;

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

/** Tamaño máximo de la imagen. El BLOB viaja entero en cada petición. */
const IMAGEN_MAX_BYTES = 1024 * 1024;

/**
 * Cuántas filas trae cada página, y cuántas suma cada "Mostrar más".
 *
 * Es el tamaño que se le PIDE AL SERVIDOR, no un recorte de la tabla: el
 * endpoint pagina de verdad. Traer el catálogo entero era lo que lo hacía
 * fallar con 500 — cientos de artículos con descripciones de hasta 1000
 * caracteres en un solo JSON.
 */
const POR_PAGINA = 20;

/**
 * Espera antes de mandar la búsqueda al servidor.
 *
 * La búsqueda ahora es una consulta HTTP, no un filtro en memoria: sin esta
 * espera, cada tecla dispararía un request y la lista parpadearía con
 * resultados de términos a medio escribir.
 */
const ESPERA_BUSQUEDA_MS = 350;

/**
 * Fecha del último inventario, sólo el día: la hora exacta de un conteo físico
 * no aporta nada al leer la lista.
 *
 * Devuelve "Sin inventariar" cuando es null, que hoy es TODAS las filas: la
 * columna es nueva y ningún endpoint la escribe todavía. Un guión suelto se
 * leería como "no aplica"; el texto dice que falta hacerlo.
 *
 * El backend la manda en ISO sin zona ("2026-08-17T10:30:00"), que `new Date()`
 * interpreta como hora local — correcto acá, porque el conteo se hizo en la
 * misma zona que lo mira.
 */
function formatearFechaInventario(valor: string | null): string {
  if (!valor) return "Sin inventariar";
  const fecha = new Date(valor);
  // Una fecha inválida (formato inesperado) se muestra cruda en vez de dejar
  // "Invalid Date" en pantalla.
  if (Number.isNaN(fecha.getTime())) return valor;
  return new Intl.DateTimeFormat("es-PY", { dateStyle: "medium" }).format(fecha);
}

function ArticulosPage() {
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState<Articulo | null>(null);
  const [creando, setCreando] = useState(false);
  const [aEliminar, setAEliminar] = useState<Articulo | null>(null);
  // Artículo cuyas ubicaciones se están viendo. Va en diálogo y no en ruta
  // propia: siempre se mira "dónde está ESTE artículo".
  const [verUbicaciones, setVerUbicaciones] = useState<Articulo | null>(null);
  const [filtroCategoria, setFiltroCategoria] = useState<string>(SIN_FILTRO);

  // Los artículos son POR EMPRESA: la que se eligió al iniciar sesión.
  const { empresa } = useEmpresa();

  // La búsqueda se escribe acá y viaja al backend con un retraso: `busqueda` es
  // lo que se ve en el input (inmediato, sin lag al tipear) y `busquedaEnvio` lo
  // que entra en la queryKey.
  const [busqueda, setBusqueda] = useState("");
  const [busquedaEnvio, setBusquedaEnvio] = useState("");

  useEffect(() => {
    const id = setTimeout(() => setBusquedaEnvio(busqueda), ESPERA_BUSQUEDA_MS);
    return () => clearTimeout(id);
  }, [busqueda]);

  // La empresa, la búsqueda y el filtro entran en la queryKey: al cambiar
  // cualquiera, TanStack Query trata el listado como otra consulta —y descarta
  // las páginas ya traídas, que eran de otro filtro— en vez de mostrar la
  // caché anterior. `enabled` evita pedir sin empresa (el provider hidrata tras
  // montar).
  //
  // useInfiniteQuery y no useQuery: "Mostrar más" ACUMULA páginas del servidor.
  // Con useQuery cada página reemplazaría a la anterior y el botón navegaría en
  // vez de agregar filas.
  const { data, isPending, isError, error, fetchNextPage, hasNextPage, isFetchingNextPage } =
    useInfiniteQuery({
      queryKey: ["articulos", empresa?.id ?? null, busquedaEnvio.trim(), filtroCategoria],
      queryFn: ({ pageParam }) =>
        api.articulos.listar({
          idEmpresa: empresa!.id,
          busqueda: busquedaEnvio,
          idCategoria: filtroCategoria === SIN_FILTRO ? undefined : Number(filtroCategoria),
          pagina: pageParam,
          tamanio: POR_PAGINA,
        }),
      enabled: empresa !== null,
      initialPageParam: 1,
      // `total` es el de las filas que pasan el filtro, así que sumar lo ya
      // traído y compararlo dice si queda otra página. Devolver undefined es lo
      // que apaga `hasNextPage` y esconde el botón.
      getNextPageParam: (ultima, paginas) => {
        const traidos = paginas.reduce((suma, p) => suma + p.items.length, 0);
        return traidos < ultima.total ? paginas.length + 1 : undefined;
      },
    });

  // Las categorías alimentan el filtro de la columna y el formulario. Misma
  // queryKey que usa la página de Categorías, así se comparte la respuesta.
  const { data: categorias } = useQuery({
    queryKey: ["categorias", empresa?.id ?? null],
    queryFn: () => api.categorias.listar({ idEmpresa: empresa!.id }),
    enabled: empresa !== null,
  });

  const eliminar = useMutation({
    mutationFn: (articulo: Articulo) => api.articulos.eliminar(articulo.id, articulo.idEmpresa),
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

  // Todas las páginas traídas hasta ahora, aplanadas. Es lo que la tabla pinta:
  // NO hay recorte en el cliente, porque cada fila que llegó ya la eligió el
  // servidor.
  const cargados = (data?.pages ?? []).flatMap((p) => p.items);

  // El orden por click en el header ORDENA SOLO LO YA CARGADO, no el catálogo.
  // Es una diferencia real con el resto de las pantallas: acá "ordenar por
  // nombre descendente" con 40 de 300 artículos traídos muestra el último de
  // esos 40, no el último del catálogo.
  //
  // Se mantiene igual porque el uso es reordenar lo que se está mirando. Para
  // encontrar un artículo puntual está la búsqueda, que sí va al servidor.
  //
  // useTablaListado ya no sirve: su filtrado por término era en memoria y
  // ahora esa parte la hace el SQL. Sólo se conserva el orden.
  const [orden, setOrden] = useState<{
    campo: keyof Articulo;
    direccion: "asc" | "desc";
  } | null>(null);

  function alternarOrden(campo: keyof Articulo) {
    setOrden((actual) => {
      if (!actual || actual.campo !== campo) return { campo, direccion: "asc" };
      if (actual.direccion === "asc") return { campo, direccion: "desc" };
      return null; // Tercer click: vuelve al orden del backend (por nombre).
    });
  }

  const mostrados = orden
    ? [...cargados].sort(
        (a, b) =>
          (orden.direccion === "asc" ? 1 : -1) *
          String(a[orden.campo] ?? "").localeCompare(String(b[orden.campo] ?? ""), "es"),
      )
    : cargados;

  const categoriasOpciones = (categorias?.items ?? []).map((c) => ({
    valor: String(c.id),
    etiqueta: c.nombreCategoria,
  }));

  // El total del backend son las filas que pasan el filtro, no las traídas.
  const total = data?.pages[0]?.total ?? 0;
  const quedan = total - cargados.length;

  // El término que el servidor está respondiendo, no el que se está tipeando:
  // los mensajes de "sin resultados" tienen que nombrar lo que se buscó de
  // verdad, no un texto a medio escribir cuyo request todavía no salió.
  const termino = busquedaEnvio.trim();

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

        {!isPending && !isError && empresa !== null && cargados.length === 0 && (
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
        {cargados.length > 0 && (
          <ul className="space-y-3 sm:hidden">
            {mostrados.map((articulo) => {
              const activo = esActivo(articulo.activo);
              const gasto = esGastoArticulo(articulo.esGasto);
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
                        {/* Texto y no un Badge: la tarjeta ya tiene el de estado
                            arriba, y dos badges compitiendo en 360px se leen
                            como si fueran lo mismo. */}
                        {gasto ? " · Gasto" : ""}
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
                  <p className="text-xs text-muted-foreground">
                    Inventario: {formatearFechaInventario(articulo.fechaUltimoInventario)}
                  </p>

                  <div className="mt-3 space-y-2 border-t border-border pt-3">
                    <Button
                      variant="outline"
                      size="sm"
                      className="w-full"
                      onClick={() => setVerUbicaciones(articulo)}
                    >
                      <MapPin className="size-4" />
                      Ubicaciones
                    </Button>
                    <div className="flex gap-2">
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
                  </div>
                </li>
              );
            })}
          </ul>
        )}

        {cargados.length > 0 && (
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
                  {/* Sin columna de precio: los precios salieron de ARTICULOS y
                      viven en cada lote. El stock sigue, pero ahora es la suma
                      de los lotes que calcula el backend. */}
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
                  const gasto = esGastoArticulo(articulo.esGasto);
                  // El stock bajo el mínimo se pinta en rojo: es el dato que
                  // justifica mirar esta tabla, y en gris pasa desapercibido.
                  const bajoMinimo = articulo.cantidadStock < articulo.cantidadMinima;

                  return (
                    <TableRow key={articulo.id}>
                      <TableCell>
                        <ImagenArticulo id={articulo.id} tieneImagen={articulo.tieneImagen} />
                      </TableCell>
                      <TableCell className="font-medium text-foreground">
                        <span className="flex items-center gap-2">
                          {articulo.nombreArticulo}
                          {/* Sólo se marca el gasto, que es la excepción: poner
                              también "Stock" en todas las demás filas repetiría
                              lo mismo decenas de veces y taparía justo lo que la
                              marca quiere destacar. */}
                          {gasto && (
                            <Badge variant="outline" className="shrink-0 font-normal">
                              Gasto
                            </Badge>
                          )}
                        </span>
                        {articulo.codigoArticulo && (
                          <span className="block text-xs font-normal text-muted-foreground">
                            {articulo.codigoArticulo}
                          </span>
                        )}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {articulo.categoria ?? "—"}
                      </TableCell>
                      <TableCell>
                        <span className={bajoMinimo ? "font-semibold text-destructive" : ""}>
                          {articulo.cantidadStock}
                          {articulo.abreviaturaUnidad ? ` ${articulo.abreviaturaUnidad}` : ""}
                        </span>
                        {/* La fecha del último conteo va debajo del stock y no en
                            columna propia: es el dato que dice si ESE número es
                            confiable, y la tabla ya tiene siete columnas. */}
                        <span className="block text-xs text-muted-foreground">
                          {formatearFechaInventario(articulo.fechaUltimoInventario)}
                        </span>
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
                            title="Ubicaciones"
                            aria-label={`Ubicaciones de ${articulo.nombreArticulo}`}
                            onClick={() => setVerUbicaciones(articulo)}
                          >
                            <MapPin className="size-4" />
                          </Button>
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

        {/* El botón PIDE OTRA PÁGINA AL SERVIDOR, no descubre filas ya traídas:
            se deshabilita mientras llega, porque un segundo click dispararía un
            request de más. */}
        {hasNextPage && (
          <div className="flex justify-center">
            <Button variant="outline" onClick={() => fetchNextPage()} disabled={isFetchingNextPage}>
              {isFetchingNextPage ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  Cargando…
                </>
              ) : (
                `Mostrar ${Math.min(quedan, POR_PAGINA)} más`
              )}
            </Button>
          </div>
        )}

        {cargados.length > 0 && (
          <p className="text-center text-xs text-muted-foreground">
            Mostrando {cargados.length} de {total} artículo{total === 1 ? "" : "s"}
            {termino || filtroCategoria !== SIN_FILTRO ? " que coinciden" : ""}
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

        {/* En qué ubicaciones del depósito está el artículo. */}
        <ArticuloUbicacionesDialog
          articulo={verUbicaciones}
          onOpenChange={(abierto) => !abierto && setVerUbicaciones(null)}
        />

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
      cantidadMinima: articulo ? String(articulo.cantidadMinima) : "0",
      // Un alta nace como artículo de stock, que es el caso habitual y el mismo
      // default que aplica el backend si el campo no viaja.
      esGasto: articulo ? esGastoArticulo(articulo.esGasto) : false,
      activo: articulo ? esActivo(articulo.activo) : true,
    },
  });

  const guardar = useMutation({
    mutationFn: (v: FormValues) => {
      const activo: Estado = v.activo ? "A" : "I";
      // Va SIEMPRE, también en el alta y también cuando es false: al revés que
      // los opcionales de abajo, acá "no mandarlo" no significa "sin dato" sino
      // "dejarlo como estaba", y destildar la casilla no llegaría nunca.
      const esGasto: Rol = v.esGasto ? "S" : "N";

      // Los campos vacíos se omiten en vez de mandarse como "" o 0: el backend
      // trata lo ausente como "no cambiar", y un 0 explícito pisaría el valor
      // real con un dato que nadie ingresó.
      const opcionales = {
        ...(v.codigoArticulo ? { codigoArticulo: v.codigoArticulo } : {}),
        ...(v.descripcion ? { descripcion: v.descripcion } : {}),
        ...(v.idCategoria ? { idCategoria: Number(v.idCategoria) } : {}),
        ...(v.idMoneda ? { idMoneda: Number(v.idMoneda) } : {}),
        ...(v.idUnidadMedida ? { idUnidadMedida: Number(v.idUnidadMedida) } : {}),
        ...(v.cantidadMinima ? { cantidadMinima: Number(v.cantidadMinima) } : {}),
      };

      // Alta y edición mandan lo mismo: ya no hay campos que sólo existan en el
      // alta. Los precios y el stock salieron de la tabla —el costo va en cada
      // lote y el stock se calcula sumándolos—, así que el formulario quedó
      // siendo sólo la ficha del artículo.
      return esEdicion
        ? api.articulos.actualizar(articulo.id, {
            // OBLIGATORIO aunque no sea un campo del formulario: el backend lo
            // usa en el WHERE para acotar A CUAL fila se aplica el cambio, no
            // como un dato más a guardar. Sin él responde 400.
            idEmpresa: articulo.idEmpresa,
            nombreArticulo: v.nombreArticulo,
            ...opcionales,
            esGasto,
            activo,
          })
        : api.articulos.crear({
            idEmpresa,
            nombreArticulo: v.nombreArticulo,
            ...opcionales,
            esGasto,
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
      {/* ANCHO DE ERP, NO DE DIÁLOGO. Son once campos: en una columna de
          `max-w-lg` obligaban a scrollear para llegar al botón de guardar, y
          cargar un artículo con el formulario a medias visible es justo lo que
          un sistema de gestión no debe pedir.

          A dos columnas entran todos de una en un portátil (~768px de alto).
          `max-h-[92vh]` queda como red de seguridad para pantallas muy bajas o
          zoom alto: sigue existiendo, pero deja de ser el caso normal. */}
      <DialogContent className="scrollbar-fino max-h-[92vh] overflow-y-auto sm:max-w-3xl">
        <DialogHeader>
          <DialogTitle>{esEdicion ? "Editar artículo" : "Nuevo artículo"}</DialogTitle>
          <DialogDescription>
            {esEdicion
              ? "Modificá los datos del artículo."
              : "Agregá un artículo a la empresa con la que iniciaste sesión."}
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          {/* space-y-4 y no -6: con tres secciones, el aire de más es lo que
              empujaba el footer fuera de la pantalla. */}
          <form onSubmit={form.handleSubmit((v) => guardar.mutate(v))} className="space-y-4">
            {/* IDENTIFICACIÓN — qué es el artículo.

                La imagen va a la izquierda y los campos a la derecha: es el
                bloque que identifica la fila, y la miniatura al lado del nombre
                se lee de un vistazo. Sólo en edición, porque la imagen se sube
                contra el id del artículo, que en el alta todavía no existe. */}
            <section className="space-y-3">
              <h3 className="text-sm font-semibold text-foreground">Identificación</h3>

              <div className={esEdicion ? "flex gap-4" : undefined}>
                {esEdicion && <CargarImagen articulo={articulo} />}

                <div className="grid flex-1 gap-4 sm:grid-cols-2">
                  <FormField
                    control={form.control}
                    name="nombreArticulo"
                    render={({ field }) => (
                      <FormItem className="sm:col-span-2">
                        <FormLabel>Nombre del artículo</FormLabel>
                        <FormControl>
                          <Input
                            {...field}
                            placeholder="Cemento Portland 50 kg"
                            autoComplete="off"
                          />
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
                        <FormLabel>Código/Cod. OEM</FormLabel>
                        <FormControl>
                          <Input {...field} placeholder="ART-001" autoComplete="off" />
                        </FormControl>
                        <FormDescription>Opcional. Interno, de barras u OEM.</FormDescription>
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
                          <SelectorModal
                            opciones={categoriasOpciones}
                            value={field.value}
                            onChange={field.onChange}
                            placeholder="Sin categoría"
                            titulo="Elegí una categoría"
                            buscarPlaceholder="Buscar categoría…"
                            cargando={cargandoCategorias}
                          />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />

                  {/* Va acá y no en "Stock y medida" porque dice QUÉ ES el
                      artículo, no cuánto hay. Y está también en el alta —al
                      revés que el toggle de activo—: si un gasto se creara
                      siempre como artículo de stock, habría que entrar a
                      editarlo de inmediato para corregirlo. */}
                  <FormField
                    control={form.control}
                    name="esGasto"
                    render={({ field }) => (
                      <FormItem className="flex h-fit items-center justify-between rounded-lg border border-border p-3 sm:col-span-2">
                        <div className="space-y-0.5">
                          <FormLabel>Es un gasto</FormLabel>
                          <FormDescription>
                            Servicios, alquileres u honorarios: se compran y se consumen, no se
                            guardan en depósito.
                          </FormDescription>
                        </div>
                        <FormControl>
                          <Switch checked={field.value} onCheckedChange={field.onChange} />
                        </FormControl>
                      </FormItem>
                    )}
                  />
                </div>
              </div>
            </section>

            {/* STOCK Y MEDIDA.

                Ya NO hay campos de precio: PRECIO_VENTA, PRECIO_ULTIMA_COMPRA y
                CANTIDAD_STOCK se eliminaron de la tabla. El costo es de cada
                PARTIDA —dos lotes del mismo artículo entran a precios
                distintos— así que vive en Lotes, y el stock es la suma de sus
                cantidades.

                Queda la cantidad mínima, que no es una medición sino una
                política: a partir de cuánto avisar que falta. Y la moneda y la
                unidad, que dan sentido a esos números aunque no los produzcan. */}
            <section className="space-y-3">
              <h3 className="text-sm font-semibold text-foreground">Stock y medida</h3>

              <div className="grid gap-4 sm:grid-cols-3">
                <FormField
                  control={form.control}
                  name="cantidadMinima"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Cantidad mínima</FormLabel>
                      <FormControl>
                        {/* inputMode decimal abre el teclado numérico en móvil
                            sin las flechas de un type="number". */}
                        <Input
                          {...field}
                          inputMode="decimal"
                          placeholder="0"
                          autoComplete="off"
                          className="tabular-nums"
                        />
                      </FormControl>
                      <FormDescription>Avisa cuando el stock baja de acá.</FormDescription>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <FormField
                  control={form.control}
                  name="idUnidadMedida"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Unidad de medida</FormLabel>
                      <FormControl>
                        <SelectorModal
                          opciones={unidadesOpciones}
                          value={field.value}
                          onChange={field.onChange}
                          placeholder="Sin unidad"
                          titulo="Elegí una unidad de medida"
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
                  name="idMoneda"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Moneda</FormLabel>
                      <FormControl>
                        <SelectorModal
                          opciones={monedasOpciones}
                          value={field.value}
                          onChange={field.onChange}
                          placeholder="Sin moneda"
                          titulo="Elegí una moneda"
                          buscarPlaceholder="Buscar moneda…"
                          cargando={cargandoMonedas}
                        />
                      </FormControl>
                      <FormDescription>En la que se expresan sus costos.</FormDescription>
                      <FormMessage />
                    </FormItem>
                  )}
                />
              </div>

              {/* Stock actual: SÓLO LECTURA y sólo en edición. No es un campo
                  del formulario —no está en el schema ni viaja en el submit—:
                  lo calcula el backend sumando los lotes. Se muestra porque es
                  el dato que alguien viene a mirar acá, aunque se modifique
                  cargando lotes y no editando esta ficha. */}
              {esEdicion && (
                <div className="flex items-center justify-between gap-3 rounded-lg border border-dashed border-border px-3 py-2">
                  <div>
                    <p className="text-sm font-medium text-foreground">Stock actual</p>
                    <p className="text-xs text-muted-foreground">
                      Suma de sus lotes. Se modifica en Lotes, no acá.
                    </p>
                  </div>
                  <span
                    className={
                      articulo.cantidadStock < articulo.cantidadMinima
                        ? "text-sm font-semibold tabular-nums text-destructive"
                        : "text-sm tabular-nums text-foreground"
                    }
                  >
                    {articulo.cantidadStock}
                    {articulo.abreviaturaUnidad ? ` ${articulo.abreviaturaUnidad}` : ""}
                  </span>
                </div>
              )}

              {/* Último inventario: SÓLO LECTURA, y sólo en edición —un alta no
                  tiene conteo previo. No es un campo del formulario (no está en
                  el schema ni viaja en el submit): lo estampa el proceso de
                  inventario. Se muestra acá porque es el dato que dice si el
                  stock de arriba es confiable, y es donde alguien lo busca. */}
              {esEdicion && (
                <div className="flex items-center justify-between gap-3 rounded-lg border border-dashed border-border px-3 py-2">
                  <div>
                    <p className="text-sm font-medium text-foreground">Último inventario</p>
                    <p className="text-xs text-muted-foreground">
                      Lo registra el conteo físico, no se carga a mano.
                    </p>
                  </div>
                  <span
                    className={
                      articulo.fechaUltimoInventario
                        ? "text-sm tabular-nums text-foreground"
                        : "text-sm text-muted-foreground"
                    }
                  >
                    {formatearFechaInventario(articulo.fechaUltimoInventario)}
                  </span>
                </div>
              )}
            </section>

            {/* DETALLE — lo largo al final, para que no parta las dos columnas
                de arriba. El switch de estado comparte fila con la descripción
                en escritorio: es un control chico y solo aparece en edición. */}
            <section className="space-y-3">
              <h3 className="text-sm font-semibold text-foreground">Detalle</h3>

              <div className="grid gap-4 sm:grid-cols-2">
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
                      <FormItem className="flex h-fit items-center justify-between rounded-lg border border-border p-3">
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
              </div>
            </section>

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
      { title: tituloPagina("Artículos") },
      { name: "description", content: "Artículos por empresa del sistema." },
    ],
  }),
  component: ArticulosPage,
});
