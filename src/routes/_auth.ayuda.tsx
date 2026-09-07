import { createFileRoute } from "@tanstack/react-router";
import {
  Archive,
  BookOpen,
  Cog,
  Contact,
  Database,
  FileBarChart,
  Info,
  Settings,
  ShoppingCart,
  Sliders,
  TrendingUp,
  TriangleAlert,
  Wallet,
  Workflow,
} from "lucide-react";
import { useState, type ReactNode } from "react";

import { AppLayout } from "@/components/ctell/AppLayout";
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "@/components/ui/accordion";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Separator } from "@/components/ui/separator";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { tituloPagina } from "@/lib/marca";

/**
 * Manual de uso, dentro del sistema.
 *
 * ESTRUCTURA: módulo › sección › pantalla — los TRES niveles del menú, no dos.
 * Los módulos salen de `ICONOS_MODULO` (menu-iconos.ts) y las secciones son las
 * entradas D/O/R que agrupa `use-menu-usuario`, con sus mismos rótulos e íconos.
 *
 * Quien busca ayuda llega desde una pantalla concreta y la busca por donde la
 * abre: en el menú despliega Ventas, después Operaciones, y ahí está Cobros.
 * Saltear el nivel del medio dejaría una lista plana que no se parece a lo que
 * esa persona tiene delante, y ordenar por temas propios sería peor todavía —
 * obligaría a traducir "estoy en Cobros" a "esto es Tesorería" antes de
 * encontrar nada.
 *
 * Cada pantalla es un item de acordeón con su ruta a la vista, así que la
 * página abre plegada —ocho módulos y sus títulos entran en un pantallazo— y se
 * despliega sólo lo que se está consultando.
 *
 * El contenido es el mismo de `docs/MANUAL-DE-USO.md`, escrito acá como JSX en
 * vez de leerse del markdown: renderizarlo pediría sumar react-markdown al
 * bundle para una pantalla que se abre poco, y el proyecto no tiene ninguna
 * librería de markdown instalada.
 *
 * LA CONTRAPARTIDA ES QUE SON DOS ARCHIVOS: si cambia una regla del sistema, va
 * en el .md **y** acá. Están enlazados entre sí en sus encabezados.
 *
 * No lleva `useEmpresa()` ni queryKey: no consulta datos, así que no hay nada
 * que recortar por empresa ni caché que invalidar al cambiarla.
 */

/**
 * Sección del menú dentro de un módulo, con el mismo código que guarda
 * `PAGINAS.ENTRADA`: 'D' Definiciones, 'O' Operaciones, 'R' Reportes.
 *
 * Es el nivel intermedio de la jerarquía real —módulo › entrada › página— y por
 * eso el manual lo respeta: quien busca una pantalla la ubica por donde la abre,
 * y en el menú abre Ventas, después Operaciones, y ahí está Cobros.
 */
type Entrada = "D" | "O" | "R";

/** Los mismos rótulos e íconos que usa el menú (`use-menu-usuario`). */
const ENTRADAS: { codigo: Entrada; label: string; icono: typeof Sliders; explica: string }[] = [
  {
    codigo: "D",
    label: "Definiciones",
    icono: Sliders,
    explica: "Lo que se carga una vez y después se elige desde otras pantallas.",
  },
  {
    codigo: "O",
    label: "Operaciones",
    icono: Workflow,
    explica: "El trabajo de todos los días: lo que se registra a medida que pasa.",
  },
  {
    codigo: "R",
    label: "Reportes",
    icono: FileBarChart,
    explica: "Consultas que no modifican nada. Se miran y se exportan.",
  },
];

/** Una pantalla del sistema, con su ficha. */
type Pantalla = {
  /** Nombre tal como figura en el menú. */
  nombre: string;
  /** Sección del menú en la que aparece. */
  entrada: Entrada;
  /** Ruta, o null si no es una pantalla propia (se abre desde otra). */
  ruta: string | null;
  /** Una línea: qué se hace ahí. Se ve sin desplegar. */
  resumen: string;
  /** Palabras extra para el buscador, más allá del nombre y el resumen. */
  buscable?: string;
  ficha: ReactNode;
};

type Modulo = {
  id: string;
  nombre: string;
  icono: typeof Database;
  descripcion: string;
  pantallas: Pantalla[];
};

/** Las pantallas de un módulo agrupadas por entrada, en el orden del menú. */
function porEntrada(pantallas: Pantalla[]) {
  return ENTRADAS.map((e) => ({
    ...e,
    pantallas: pantallas.filter((p) => p.entrada === e.codigo),
  })).filter((e) => e.pantallas.length > 0);
}

/** Aviso: lo que parece un error del sistema y no lo es. */
function Aviso({ titulo, children }: { titulo: string; children: ReactNode }) {
  return (
    <Alert className="my-3">
      <Info className="size-4" />
      <AlertTitle>{titulo}</AlertTitle>
      <AlertDescription className="text-sm leading-relaxed">{children}</AlertDescription>
    </Alert>
  );
}

/** Aviso fuerte: un comportamiento con consecuencias que no se deshacen. */
function Atencion({ titulo, children }: { titulo: string; children: ReactNode }) {
  return (
    <Alert variant="destructive" className="my-3">
      <TriangleAlert className="size-4" />
      <AlertTitle>{titulo}</AlertTitle>
      <AlertDescription className="text-sm leading-relaxed">{children}</AlertDescription>
    </Alert>
  );
}

function P({ children }: { children: ReactNode }) {
  return <p className="text-sm leading-relaxed text-muted-foreground">{children}</p>;
}

function Lista({ children }: { children: ReactNode }) {
  return (
    <ul className="ml-5 list-disc space-y-1.5 text-sm leading-relaxed text-muted-foreground">
      {children}
    </ul>
  );
}

/** Encabezado de un bloque dentro de una ficha. */
function H({ children }: { children: ReactNode }) {
  return <h4 className="mt-4 mb-1.5 text-sm font-semibold first:mt-0">{children}</h4>;
}

const MODULOS: Modulo[] = [
  /* ────────────────────────────── VENTAS ────────────────────────────── */
  {
    id: "ventas",
    nombre: "Ventas",
    icono: TrendingUp,
    descripcion: "La caja, los comprobantes emitidos y la plata que entra.",
    pantallas: [
      {
        nombre: "Punto de venta",
        entrada: "O",
        ruta: "/punto-venta",
        resumen: "La caja: se arma el carrito y se cobra.",
        buscable: "carrito iva precio etiqueta descuento lista cajero vender",
        ficha: (
          <>
            <H>Cómo se usa</H>
            <P>
              Se buscan los artículos, se arma el carrito y se guarda. Al guardar se abre el modal
              de cobro, donde se registra cómo paga el cliente.
            </P>
            <Aviso titulo="El precio que cargás ya incluye el IVA">
              Como se factura en Paraguay. Si la etiqueta dice 11.000, ponés 11.000 — no 10.000 más
              impuesto. El sistema desglosa solo cuánto es gravado y cuánto es IVA.
            </Aviso>
            <H>Detalles</H>
            <Lista>
              <li>
                <strong>La lista de descuentos es opcional.</strong> Sin lista se usa el precio de
                etiqueta y 0% de descuento.
              </li>
              <li>
                Según el <strong>canal de pago</strong>, se pide la cuenta bancaria receptora. Eso
                depende de cómo esté configurado el canal, no de su nombre.
              </li>
              <li>
                La venta se registra en la <strong>sucursal activa</strong>.
              </li>
            </Lista>
            <Aviso titulo="Hoy se puede vender sin existencia">
              El sistema no te frena si el artículo está en cero. Es un estado transitorio mientras
              se migra el manejo de stock — ver el módulo Stock.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Ventas",
        entrada: "O",
        ruta: "/ventas",
        resumen: "Los comprobantes ya emitidos: se consultan y se eliminan.",
        buscable: "comprobantes emitidos detalle eliminar borrar factura",
        ficha: (
          <>
            <H>Cómo se usa</H>
            <P>
              Se consulta el detalle de cada venta emitida y, si hace falta, se elimina.{" "}
              <strong>No se edita</strong>: una venta emitida no se corrige. Si está mal, se elimina
              y se hace de nuevo.
            </P>
            <Aviso titulo="Una venta con cobros registrados no se puede borrar">
              Primero hay que eliminar sus cobros. El sistema lo avisa en vez de dejar plata cobrada
              contra una venta que ya no existe.
            </Aviso>
            <Aviso titulo="Borrar una venta no repone stock">
              Hoy ninguna transacción mueve el stock — ver el módulo Stock.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Cobros",
        entrada: "O",
        ruta: "/cobros",
        resumen: "La plata que entra por cada venta, con su historial.",
        buscable: "cobrar saldo canal pago cuenta bancaria historial",
        ficha: (
          <>
            <H>Cómo se usa</H>
            <P>
              Se elige la venta, se registra el cobro y queda el historial. Se puede cobrar en
              varias veces.
            </P>
            <H>Reglas</H>
            <Lista>
              <li>
                <strong>El monto se valida contra el saldo:</strong> no se puede cobrar más de lo
                que se debe.
              </li>
              <li>
                Según el canal de pago, el sistema <strong>pide la cuenta receptora</strong>. Un
                canal sin el indicador de banco se trata como efectivo.
              </li>
              <li>
                <strong>Borrar un cobro devuelve el saldo</strong> a la venta.
              </li>
            </Lista>
          </>
        ),
      },
    ],
  },

  /* ────────────────────────────── COMPRAS ───────────────────────────── */
  {
    id: "compras",
    nombre: "Compras",
    icono: ShoppingCart,
    descripcion: "Las facturas de proveedores y lo que se les paga.",
    pantallas: [
      {
        nombre: "Facturas de compras",
        entrada: "O",
        ruta: "/facturas-compras",
        resumen: "Las facturas que emiten los proveedores.",
        buscable: "proveedor factura compra cabecera detalle",
        ficha: (
          <>
            <H>Cómo se usa</H>
            <P>
              Se carga la factura del proveedor con su detalle de artículos. Funciona igual que una
              venta, pero al revés: el IVA se desglosa del mismo modo y los totales se calculan del
              detalle.
            </P>
            <Aviso titulo="Una factura con pagos no se elimina">
              Primero hay que borrar sus pagos.
            </Aviso>
            <Aviso titulo="Hoy una compra no ingresa stock">Ver el módulo Stock.</Aviso>
          </>
        ),
      },
      {
        nombre: "Pagos",
        entrada: "O",
        ruta: "/pagos",
        resumen: "Lo que se le paga a cada proveedor. Espejo de Cobros.",
        buscable: "pagar proveedor saldo canal cuenta bancaria egreso",
        ficha: (
          <>
            <H>Cómo se usa</H>
            <P>
              Es el espejo exacto de Cobros, con la plata saliendo: se elige la factura, se registra
              el pago y queda el historial.
            </P>
            <H>Reglas</H>
            <Lista>
              <li>El monto se valida contra el saldo pendiente.</li>
              <li>Según el canal, se pide la cuenta desde la que sale la plata.</li>
              <li>Borrar un pago devuelve el saldo a la factura.</li>
            </Lista>
          </>
        ),
      },
    ],
  },

  /* ─────────────────────────────── STOCK ────────────────────────────── */
  {
    id: "stock",
    nombre: "Stock",
    icono: Archive,
    descripcion: "Qué hay en cada depósito, y el conteo físico que lo corrige.",
    pantallas: [
      {
        nombre: "Existencias",
        entrada: "R",
        ruta: "/existencias",
        resumen: "Cuánto hay de cada artículo, por sucursal. Sólo consulta.",
        buscable: "existencia cantidad deposito consultar exportar excel pdf",
        ficha: (
          <>
            <Atencion titulo="El stock está en transición">
              Hoy <strong>ninguna venta ni compra mueve el stock</strong>: vender no descuenta,
              comprar no ingresa, y borrar una venta no repone nada. El único que escribe las
              existencias es el <strong>cierre de un conteo físico</strong>.
              <br />
              <br />
              Es un estado intermedio, conocido y en curso de resolución. Mientras tanto, la
              cantidad confiable es la del último conteo.
            </Atencion>
            <H>Cómo se usa</H>
            <P>
              Es una <strong>consulta</strong>: no se da de alta ni se edita nada. Se exporta a
              Excel y PDF, y lo que sale en el archivo es exactamente lo que ves en pantalla — trae
              el catálogo entero, no sólo la página visible.
            </P>
          </>
        ),
      },
      {
        nombre: "Inventarios",
        entrada: "O",
        ruta: "/inventarios",
        resumen: "La carga del conteo físico de la sucursal activa.",
        buscable: "conteo fisico contar deposito abierto cerrado anulado estante diferencia",
        ficha: (
          <>
            <H>Cómo se usa</H>
            <P>
              Se cuenta lo que hay en el depósito y se anota, artículo por artículo. El diálogo de
              alta ofrece completar la ficha del artículo si le falta marca, categoría o ubicación,
              y hay un filtro por estante para ir contando mientras se recorre el depósito.
            </P>
            <H>Los estados</H>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Estado</TableHead>
                  <TableHead>Qué se puede hacer</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                <TableRow>
                  <TableCell>
                    <Badge variant="secondary">Abierto</Badge>
                  </TableCell>
                  <TableCell>Editarlo, anularlo o eliminarlo</TableCell>
                </TableRow>
                <TableRow>
                  <TableCell>
                    <Badge variant="outline">Cerrado</Badge>
                  </TableCell>
                  <TableCell>Sólo mirarlo — ya se aplicó al stock</TableCell>
                </TableRow>
                <TableRow>
                  <TableCell>
                    <Badge variant="outline">Anulado</Badge>
                  </TableCell>
                  <TableCell>Sólo mirarlo — se descartó</TableCell>
                </TableRow>
              </TableBody>
            </Table>
            <Aviso titulo="Desde esta pantalla no se cierra un conteo, y es a propósito">
              Contar y aplicar son dos actos distintos: el conteo se corrige las veces que haga
              falta, pero <strong>aplicarlo cambia el stock y no se deshace</strong>. Una acción así
              no va como un ícono más en la fila, al lado de editar y borrar, donde se toca de paso.
              Anular sí está, porque no toca el stock.
            </Aviso>
            <H>Eliminar y anular no son lo mismo</H>
            <Lista>
              <li>
                <strong>Eliminar</strong> es para el borrador que se cargó por error.
              </li>
              <li>
                <strong>Anular</strong> es para el conteo que se hizo de verdad y se decide no
                aplicar. Deja la constancia de que alguien fue al depósito.
              </li>
            </Lista>
          </>
        ),
      },
      {
        nombre: "Reporte de inventarios",
        entrada: "R",
        ruta: "/inventarios-reporte",
        resumen: "Los conteos por período, con exportación. Sólo consulta.",
        buscable: "reporte conteos periodo fechas estado diferencia exportar excel pdf",
        ficha: (
          <>
            <H>Cómo se usa</H>
            <P>
              Los conteos de la sucursal activa por período. Es una consulta: no da de alta, no
              edita, no cierra.
            </P>
            <H>Filtros</H>
            <Lista>
              <li>
                <strong>Fechas</strong> (desde/hasta, con atajos)
              </li>
              <li>
                <strong>Estado</strong> del conteo
              </li>
              <li>
                <strong>Diferencia</strong>: con o sin
              </li>
            </Lista>
            <P>Se exporta a Excel y PDF, con exactamente lo que se ve en pantalla.</P>
          </>
        ),
      },
      {
        nombre: "Artículos",
        entrada: "D",
        ruta: "/articulos",
        resumen: "El catálogo de productos.",
        buscable: "catalogo producto categoria marca ubicacion estante precio codigo",
        ficha: (
          <>
            <H>Cómo se usa</H>
            <P>Alta, edición y baja de los productos, con su precio, categoría, marca y unidad.</P>
            <H>Filtrar</H>
            <P>
              Categoría y marca se filtran desde el <strong>encabezado de su columna</strong>. La
              ubicación no, y hay una razón: un artículo puede estar en varios estantes a la vez,
              así que no hay una columna que la muestre. Se filtra con el selector que está al lado
              del buscador.
            </P>
            <Aviso titulo="El selector de ubicación sólo ofrece estantes con artículos">
              Y de la sucursal activa. En un depósito con la grilla entera cargada la mayoría están
              vacíos, y ofrecerlos sería ofrecer búsquedas que ya se sabe que no devuelven nada.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Ubicaciones de artículos",
        entrada: "D",
        ruta: "/articulos-ubicaciones",
        resumen: "En qué estante está cada artículo.",
        buscable: "estante deposito cruce ubicar donde esta",
        ficha: (
          <>
            <H>Cómo se usa</H>
            <P>
              Es un cruce entre artículos y estantes:{" "}
              <strong>un artículo puede estar en varios lugares</strong> a la vez, y por eso no es
              un campo de la ficha del artículo sino una pantalla propia.
            </P>
          </>
        ),
      },
      {
        nombre: "Ubicaciones",
        entrada: "D",
        ruta: "/ubicaciones",
        resumen: "Los estantes del depósito.",
        buscable: "estante deposito definir lugar",
        ficha: (
          <>
            <H>Cómo se usa</H>
            <P>
              Alta y baja de los estantes o lugares del depósito. Son los que después se asignan a
              los artículos y los que ofrece el filtro por estante al contar.
            </P>
          </>
        ),
      },
    ],
  },

  /* ───────────────────────────── TESORERÍA ──────────────────────────── */
  {
    id: "tesoreria",
    nombre: "Tesorería",
    icono: Wallet,
    descripcion: "Dónde entra y sale la plata, y con qué medios.",
    pantallas: [
      {
        nombre: "Bancos",
        entrada: "D",
        ruta: "/bancos",
        resumen: "Los bancos con los que se opera.",
        buscable: "banco entidad financiera",
        ficha: (
          <P>
            Alta y baja de los bancos. Son los que después se eligen al crear una cuenta bancaria.
          </P>
        ),
      },
      {
        nombre: "Cuentas bancarias",
        entrada: "D",
        ruta: "/cuentas-bancarias",
        resumen: "Las cuentas donde entra y sale la plata.",
        buscable: "cuenta banco numero moneda receptora",
        ficha: (
          <>
            <P>
              Las cuentas de la empresa, con su banco y su moneda. Son las que el sistema ofrece al
              cobrar o pagar con un canal que requiere banco.
            </P>
            <Aviso titulo="Los montos se escriben con separador de miles">
              El campo lo va formateando mientras escribís. No hace falta poner los puntos.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Canales de pago",
        entrada: "D",
        ruta: "/canales-pagos",
        resumen: "Efectivo, transferencia, tarjeta…",
        buscable: "canal medio pago efectivo transferencia tarjeta banco indicador",
        ficha: (
          <>
            <P>Los medios con los que se cobra y se paga.</P>
            <Aviso titulo="El indicador de banco es el que decide si se pide la cuenta">
              Al cobrar con un canal que lo tenga marcado, el sistema pide la cuenta receptora. Un
              canal <strong>sin</strong> ese indicador se trata como efectivo. No depende del nombre
              del canal: hay que marcarlo.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Condiciones de pago",
        entrada: "D",
        ruta: "/condiciones-pago",
        resumen: "Contado, crédito a 30 días…",
        buscable: "condicion contado credito cuotas plazo dias",
        ficha: <P>Las formas de pago acordadas, que después se eligen en una venta o compra.</P>,
      },
      {
        nombre: "Monedas",
        entrada: "D",
        ruta: "/monedas",
        resumen: "Las monedas y su detalle de billetes.",
        buscable: "moneda guarani dolar billete cotizacion denominacion",
        ficha: (
          <P>
            Las monedas con las que se opera. Cada una lleva su detalle de billetes y monedas, que
            se carga desde la misma fila.
          </P>
        ),
      },
      {
        nombre: "Listas de descuentos",
        entrada: "D",
        ruta: "/listas-descuentos",
        resumen: "Listas de precios con descuento.",
        buscable: "descuento lista precio porcentaje mayorista",
        ficha: (
          <P>
            Las listas que se pueden elegir en el punto de venta. Son opcionales: sin lista, se usa
            el precio de etiqueta y 0% de descuento.
          </P>
        ),
      },
    ],
  },

  /* ─────────────────────────────── RRHH ─────────────────────────────── */
  {
    id: "rrhh",
    nombre: "Recursos humanos",
    icono: Contact,
    descripcion:
      "Profesores, sus marcaciones, sus reportes de clase y sus ausencias. Trabaja junto con la app del profesor.",
    pantallas: [
      {
        nombre: "Profesores",
        entrada: "D",
        ruta: "/profesores",
        resumen: "El padrón de profesores, con su foto.",
        buscable: "profesor docente padron cedula foto",
        ficha: (
          <>
            <P>Alta, edición y baja de los profesores. Cada uno lleva su foto y su cédula.</P>
            <Aviso titulo="La cédula es única en todo el sistema">
              Un profesor pertenece a una sola empresa, y eso es lo que define en qué empresa se ven
              sus marcaciones y sus ausencias.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Instituciones",
        entrada: "D",
        ruta: "/instituciones",
        resumen: "Los colegios donde dan clase.",
        buscable: "institucion colegio escuela",
        ficha: <P>Alta y baja de las instituciones, con sus datos de contacto.</P>,
      },
      {
        nombre: "Asistencias",
        entrada: "R",
        ruta: "/asistencias",
        resumen: "Las marcaciones de entrada y salida, con su planilla para firmar.",
        buscable:
          "marcaciones planilla firma hora catedra precio total semana excel actividad extra periodo",
        ficha: (
          <>
            <H>Las dos vistas</H>
            <Lista>
              <li>
                <strong>Planilla</strong> — la que se imprime y se firma.
              </li>
              <li>
                <strong>Detalle</strong> — para revisar y corregir.
              </li>
            </Lista>
            <P>
              Tocando un día se abre el detalle de sus marcaciones, donde se editan, se borran o se
              agrega una a mano. Los combos de año y mes ofrecen sólo períodos que tienen datos.
            </P>
            <Aviso titulo="Una planilla es de UNA persona">
              Si en la institución marcaron tres profesores, vas a ver tres grillas apiladas, no una
              sola mezclada. En un papel que se firma, un día con dos entradas no puede dejar la
              duda de si fue alguien que entró y salió dos veces o dos personas distintas.
            </Aviso>
            <H>La hora cátedra y el precio</H>
            <P>
              Se cargan <strong>por profesor</strong>, en el encabezado de cada planilla: no todos
              dan cátedras de la misma duración —45 minutos en un colegio, 60 en otro— ni cobran lo
              mismo. <strong>Estos valores no se guardan</strong>: se escriben cada vez que se
              genera la planilla.
            </P>
            <P>
              Al pie va <strong>Actividad extra</strong>, en blanco para completar a mano, y el
              resumen con el desglose del IVA. Con varios profesores hay un cuadro consolidado al
              final.
            </P>
            <Aviso titulo="Se exporta sólo a Excel">El PDF se retiró.</Aviso>
          </>
        ),
      },
      {
        nombre: "Reportes de actividades",
        entrada: "O",
        ruta: "/reportes-actividades",
        resumen: "La bitácora de clases: qué se hizo cada día, con fotos.",
        buscable:
          "bitacora clase descripcion fotos evidencias galeria linea de tiempo pendientes cloudinary descargar",
        ficha: (
          <>
            <H>Cómo se usa</H>
            <P>
              Se ve como una <strong>línea de tiempo por mes</strong>, no como una tabla. Cada día
              con clase muestra su reporte, y se le cargan fotos.
            </P>
            <Aviso titulo="Un reporte se escribe sobre una marcación">
              No se elige profesor, institución ni fecha: salen de la marcación. Por eso{" "}
              <strong>no se puede reportar un día que no se marcó</strong> — si falta la marcación,
              primero se carga en Asistencias.
              <br />
              <br />
              Los días marcados <strong>sin reporte</strong> aparecen en la misma línea de tiempo,
              como tarjetas punteadas, con el botón para escribirlo. Así el hueco se ve donde está.
            </Aviso>
            <H>Las fotos</H>
            <Lista>
              <li>
                El <strong>pie de foto se escribe en el visor</strong>, con la foto a la vista — se
                pueden subir cinco de una y describirlas después.
              </li>
              <li>
                Cada foto se descarga con un <strong>nombre que la explica</strong> (fecha, hora,
                profesor, institución y posición), porque fuera del sistema una{" "}
                <em>IMG_0001.jpg</em> en Descargas no le dice nada a nadie.
              </li>
              <li>
                El combo de institución <strong>depende del profesor elegido</strong>: ofrece sólo
                donde ese profesor marcó ese mes.
              </li>
            </Lista>
            <Aviso titulo="Borrar una foto no la borra del servidor de imágenes">
              La referencia desaparece de la galería, pero el archivo queda allá.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Justificaciones de ausencia",
        entrada: "O",
        ruta: "/justificaciones-ausencia",
        resumen: "La bandeja de solicitudes que mandaron los profesores.",
        buscable:
          "ausencia licencia permiso solicitud estado suplente observaciones pendiente aprobada rechazada adjunto",
        ficha: (
          <>
            <Aviso titulo="Acá no se dan de alta ni se borran, y no es un olvido">
              Las cargan los profesores desde su app. Una justificación es un documento que mandó
              una persona: poder crearla acá dejaría cargar una ausencia a nombre de quien nunca la
              pidió, y poder borrarla eliminaría la única constancia de una que sí.
            </Aviso>
            <H>Cómo se usa</H>
            <P>
              Lo que se hace acá es <strong>resolverlas</strong>: poner el estado, asignar un
              suplente y dejar observaciones. Arriba hay un aviso con cuántas quedan pendientes, con
              un botón que deja el filtro puesto.
            </P>
            <H>Detalles</H>
            <Lista>
              <li>
                <strong>Todos los filtros son del servidor</strong> —estado, profesor, institución,
                fechas y búsqueda— y por eso están en un panel, no en cada columna.
              </li>
              <li>
                <strong>Quién recibió la solicitud no se carga:</strong> lo registra el sistema con
                el usuario que la gestionó, la primera vez. Después no se pisa — corregir una
                observación seis meses más tarde no mueve esa fecha.
              </li>
              <li>
                El <strong>archivo adjunto</strong> se ofrece sólo si es un enlace seguro. Si
                adjuntó algo que no se puede abrir, se avisa en vez de esconderlo.
              </li>
            </Lista>
          </>
        ),
      },
      {
        nombre: "Ficha de traspaso de clase",
        entrada: "O",
        ruta: null,
        resumen: "Qué tiene que hacer el suplente. Se abre desde la justificación.",
        buscable: "suplente traspaso grados horarios materiales acceso imprimir",
        ficha: (
          <>
            <Aviso titulo="No tiene pantalla propia ni entrada en el menú">
              Se abre <strong>desde la justificación de ausencia</strong>, con su botón. Una ficha
              existe por y para una ausencia concreta, así que se entra por la solicitud que la
              motivó. Al cerrarla volvés a resolver la solicitud, que es lo que estabas haciendo.
            </Aviso>
            <H>Qué lleva</H>
            <P>
              Lo que necesita el suplente: por dónde entra, con quién se presenta, qué materiales
              lleva, y grado por grado qué tema toca y a qué hora.
            </P>
            <H>Reglas</H>
            <Lista>
              <li>
                Hay <strong>una ficha por ausencia</strong>. Una de varios días lleva una sola,
                fechada el primer día.
              </li>
              <li>
                Se puede guardar <strong>sin los grados cargados</strong>, para completar los
                horarios después. El sistema avisa que así todavía no le sirve al suplente.
              </li>
              <li>
                Se puede preparar <strong>sin suplente asignado</strong> — se avisa, pero no se
                impide.
              </li>
              <li>
                <strong>Imprimir se ofrece sólo con la ficha guardada:</strong> imprimir un
                formulario a medio llenar sacaría un papel que no es el que se va a entregar.
              </li>
            </Lista>
          </>
        ),
      },
      {
        nombre: "Manuales",
        entrada: "D",
        ruta: "/manuales",
        resumen: "Los manuales en PDF, por institución y grado.",
        buscable: "manual pdf grado institucion archivo subir reemplazar",
        ficha: (
          <>
            <H>Cómo se usa</H>
            <P>
              <strong>El alta no lleva el PDF.</strong> Primero se crea la fila con su institución y
              grado, y después se sube el archivo desde la misma fila.
            </P>
            <Aviso titulo="Un manual sin archivo es un estado normal, no un error">
              La fila lo muestra con su cartel y un aviso arriba cuenta cuántos hay pendientes. El
              enlace al PDF aparece <strong>sólo si el archivo está subido</strong>: mandarte a una
              pestaña con un error sería peor que no ofrecerlo.
            </Aviso>
            <H>Detalles</H>
            <Lista>
              <li>
                <strong>No hay baja lógica:</strong> se elimina o no existe. Y al eliminarlo{" "}
                <strong>se va también el PDF</strong>.
              </li>
              <li>Sólo se aceptan archivos PDF, de hasta 20 MB.</li>
              <li>El PDF se abre en el visor del navegador, desde donde se imprime.</li>
            </Lista>
          </>
        ),
      },
    ],
  },

  /* ─────────────────────────────── BASE ─────────────────────────────── */
  {
    id: "base",
    nombre: "Base",
    icono: Database,
    descripcion: "Los catálogos que alimentan al resto del sistema.",
    pantallas: [
      {
        nombre: "Empresas",
        entrada: "D",
        ruta: "/empresas",
        resumen: "Las empresas del sistema, con su logo.",
        buscable: "empresa razon social ruc logo",
        ficha: (
          <>
            <P>
              Las empresas con las que opera el sistema. La que está activa se elige al iniciar
              sesión y se cambia desde la barra superior.
            </P>
            <P>
              El <strong>logo</strong> se sube desde la fila y aparece en los PDF que se exportan.
            </P>
          </>
        ),
      },
      {
        nombre: "Sucursales",
        entrada: "D",
        ruta: "/sucursales",
        resumen: "Las sucursales de la empresa activa.",
        buscable: "sucursal local deposito",
        ficha: (
          <>
            <P>
              Las sucursales de la empresa activa. La sucursal elegida en la barra superior es la
              que filtra el stock, el punto de venta y los conteos.
            </P>
            <Aviso titulo="No hay selector de empresa acá">
              El alta va siempre a la empresa activa.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Personas",
        entrada: "D",
        ruta: "/personas",
        resumen: "Clientes y proveedores.",
        buscable: "cliente proveedor persona ruc documento contacto",
        ficha: (
          <P>
            El padrón de clientes y proveedores. Son los que se eligen al facturar una venta o
            cargar una compra.
          </P>
        ),
      },
      {
        nombre: "Categorías",
        entrada: "D",
        ruta: "/categorias",
        resumen: "Categorías de artículos.",
        buscable: "categoria rubro clasificacion articulo",
        ficha: <P>Clasifican los artículos. Se filtran desde el encabezado de su columna.</P>,
      },
      {
        nombre: "Marcas",
        entrada: "D",
        ruta: "/marcas",
        resumen: "Marcas de artículos.",
        buscable: "marca fabricante heredadas",
        ficha: (
          <>
            <P>Las marcas de los artículos.</P>
            <Aviso titulo="Marcas heredadas">
              Puede haber filas marcadas como heredadas: son anteriores a que la tabla distinguiera
              por empresa, y las ve toda empresa.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Unidades de medida",
        entrada: "D",
        ruta: "/unidades-medida",
        resumen: "Unidad, kilo, caja, litro…",
        buscable: "unidad medida kilo caja litro metro",
        ficha: <P>Las unidades en que se venden y compran los artículos.</P>,
      },
      {
        nombre: "IVA",
        entrada: "D",
        ruta: "/iva",
        resumen: "Las tasas de IVA.",
        buscable: "iva impuesto tasa gravado exenta 10 5 por ciento",
        ficha: (
          <>
            <P>Las tasas con las que se calcula el impuesto: 10%, 5% y exenta.</P>
            <Aviso titulo="Los precios ya incluyen el IVA">
              El sistema lo desglosa, no lo suma. Si la etiqueta dice 11.000, el cliente paga 11.000
              — de los cuales 10.000 son gravados y 1.000 es IVA.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Talonarios",
        entrada: "D",
        ruta: "/talonarios",
        resumen: "Numeración de comprobantes.",
        buscable: "talonario numeracion timbrado comprobante factura numero",
        ficha: <P>La numeración de los comprobantes que emite el sistema.</P>,
      },
      {
        nombre: "Países, Departamentos, Ciudades",
        entrada: "D",
        ruta: "/paises",
        resumen: "Los domicilios, en cascada.",
        buscable: "pais departamento ciudad domicilio direccion cascada",
        ficha: (
          <>
            <P>
              Tres pantallas encadenadas: un departamento pertenece a un país, y una ciudad a un
              departamento. Se cargan en ese orden.
            </P>
            <P>
              Son las que después ofrecen los combos de domicilio en personas, empresas e
              instituciones.
            </P>
          </>
        ),
      },
      {
        nombre: "Códigos equivalentes",
        entrada: "D",
        ruta: null,
        resumen: "Otros códigos con los que se conoce un artículo.",
        buscable: "codigo equivalente barra proveedor alternativo",
        ficha: (
          <>
            <Aviso titulo="Se abre desde la ficha del artículo">
              No tiene pantalla propia: los códigos equivalentes pertenecen a un artículo concreto.
            </Aviso>
            <P>
              Sirven para encontrar un artículo por el código que usa el proveedor o por su código
              de barras, además del propio.
            </P>
          </>
        ),
      },
    ],
  },

  /* ──────────────────────────── ADMINISTRACIÓN ──────────────────────── */
  {
    id: "administracion",
    nombre: "Administración",
    icono: Cog,
    descripcion: "Quién entra al sistema y qué puede ver. Sólo para administradores.",
    pantallas: [
      {
        nombre: "Usuarios",
        entrada: "D",
        ruta: null,
        resumen: "Las cuentas: alta, baja y contraseñas.",
        buscable:
          "usuario cuenta alta contraseña resetear establecer enviar correo inactivar eliminar admin",
        ficha: (
          <>
            <Aviso titulo="Se abre desde Administración o Configuración">
              Es un diálogo, no una pantalla propia.
            </Aviso>
            <H>El alta</H>
            <P>
              El correo es <strong>obligatorio</strong> y la contraseña no se escribe: la genera el
              sistema y se la manda por mail. Si el correo no sale, la respuesta muestra la clave en
              pantalla — es el único respaldo, porque nadie más la conoce.{" "}
              <strong>Anotala antes de cerrar.</strong>
            </P>
            <H>Reglas</H>
            <Lista>
              <li>
                <strong>El nombre de usuario no se puede cambiar.</strong> Es la identidad de login;
                para cambiarlo hay que crear una cuenta nueva.
              </li>
              <li>
                <strong>Nadie puede eliminarse ni inactivarse a sí mismo.</strong> Evita quedarse
                afuera a mitad de una operación.
              </li>
            </Lista>
            <H>Las dos formas de resetear una contraseña</H>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Botón</TableHead>
                  <TableHead>Qué hace</TableHead>
                  <TableHead>Cuándo usarlo</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                <TableRow>
                  <TableCell className="font-medium">Enviar contraseña</TableCell>
                  <TableCell className="text-muted-foreground">
                    Genera una clave al azar y la manda por correo. Vos no la conocés.
                  </TableCell>
                  <TableCell className="text-muted-foreground">
                    Uso normal, con correo cargado y andando
                  </TableCell>
                </TableRow>
                <TableRow>
                  <TableCell className="font-medium">Establecer contraseña</TableCell>
                  <TableCell className="text-muted-foreground">
                    Vos escribís la clave y se la dictás.
                  </TableCell>
                  <TableCell className="text-muted-foreground">
                    La cuenta no tiene correo, el correo no llega, o necesita entrar ahora
                  </TableCell>
                </TableRow>
              </TableBody>
            </Table>
            <Aviso titulo="«Enviar contraseña» se deshabilita sin correo cargado">
              También si la cuenta está inactiva. El sistema te lo dice al pasar el mouse por
              encima. Para esos casos está el otro botón.
            </Aviso>
            <P>
              <strong>Las dos opciones cierran todas las sesiones abiertas</strong> de esa persona.
              Si la clave se cambia porque la cuenta está comprometida, dejar sesiones vivas
              anularía el motivo del cambio.
            </P>
            <Atencion titulo="Al establecer una contraseña, vos pasás a conocerla">
              Pedile a la persona que la cambie desde Configuración apenas entre.
              <br />
              <br />
              Si te la establecés a vos mismo, tu propia sesión se cierra y volvés al login. Es
              esperado, no un error.
            </Atencion>
            <Aviso titulo="Un usuario con movimientos no se puede eliminar">
              Cargó ventas, compras o inventarios, y borrarlo se llevaría ese historial. La salida
              es <strong>inactivarlo</strong>: le corta el acceso al instante y conserva quién hizo
              cada cosa.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Módulos y Páginas",
        entrada: "D",
        ruta: null,
        resumen: "Los grupos del menú y las pantallas de cada uno.",
        buscable: "modulo pagina menu ruta alta orden entrada definiciones operaciones reportes",
        ficha: (
          <>
            <Aviso titulo="Se abren desde Administración o Configuración">
              Son diálogos, no pantallas propias.
            </Aviso>
            <H>Cómo se usa</H>
            <P>
              <strong>Módulos</strong> son los grupos del menú; <strong>Páginas</strong>, las
              pantallas dentro de cada módulo. Una pantalla nueva no aparece sola: hay que darla de
              alta acá, con su ruta.
            </P>
            <P>
              El orden importa — <strong>primero el módulo, después la página</strong>. La ruta no
              se escribe a mano: se elige de una lista que el sistema arma solo.
            </P>
            <H>Las secciones</H>
            <P>Cada página va en una de tres: Definiciones, Operaciones o Reportes.</P>
            <Aviso titulo="La misma ruta puede estar en dos módulos distintos">
              Dos entradas al mismo destino, para dos perfiles. Lo que no se puede es repetirla
              dentro del mismo módulo; si pasa, el sistema lo avisa mientras completás el
              formulario.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Permisos",
        entrada: "D",
        ruta: null,
        resumen: "Qué páginas ve cada usuario.",
        buscable: "permiso acceso asignar pagina usuario menu",
        ficha: (
          <>
            <Aviso titulo="Se abre desde Administración o Configuración">
              Es un diálogo, no una pantalla propia.
            </Aviso>
            <P>
              Se elige un usuario y se le marcan las páginas que puede ver. Eso es exactamente lo
              que arma su menú: una página sin permiso no aparece.
            </P>
            <Aviso titulo="Dashboard, Ayuda y Configuración no se asignan">
              Están fijas en el menú de todos.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Notificaciones",
        entrada: "O",
        ruta: "/notificaciones",
        resumen: "Los avisos del sistema.",
        buscable: "notificacion aviso alerta mensaje",
        ficha: <P>Los avisos que el sistema genera y su historial.</P>,
      },
    ],
  },

  /* ──────────────────────────── CONFIGURACIÓN ───────────────────────── */
  {
    id: "configuracion",
    nombre: "Configuración",
    icono: Settings,
    descripcion: "Tus preferencias y esta ayuda. Fijas en el menú de todos.",
    pantallas: [
      {
        nombre: "Dashboard",
        entrada: "R",
        ruta: "/home",
        resumen: "Los indicadores de la empresa y sucursal activas.",
        buscable: "home inicio kpi indicadores movimientos stock critico accesos rapidos",
        ficha: (
          <>
            <H>Qué muestra</H>
            <Lista>
              <li>
                <strong>Montos del mes</strong>, comparados con el mes anterior.
              </li>
              <li>
                <strong>Unidades en depósito</strong>, artículos bajo mínimo y stock crítico.
              </li>
              <li>
                <strong>Últimos movimientos</strong>: ventas, compras e inventarios mezclados.
              </li>
              <li>
                <strong>Cuotas por vencer.</strong>
              </li>
            </Lista>
            <P>
              Arriba están los <strong>accesos rápidos</strong>, ordenados por lo que más usás.
            </P>
            <Aviso titulo="El valor del stock aparece en cero">
              El sistema guarda la cantidad, pero todavía no a qué costo entró cada artículo.
              Mostrar unidades como si fueran guaraníes sería peor que un cero.
            </Aviso>
          </>
        ),
      },
      {
        nombre: "Configuración",
        entrada: "D",
        ruta: "/configuracion",
        resumen: "Tema, color y tu contraseña.",
        buscable: "tema claro oscuro color acento cambiar contraseña preferencias",
        ficha: (
          <>
            <H>Preferencias</H>
            <Lista>
              <li>
                <strong>Tema:</strong> claro, oscuro o el del sistema.
              </li>
              <li>
                <strong>Color de acento:</strong> 10 paletas.
              </li>
            </Lista>
            <H>Cambiar mi contraseña</H>
            <P>
              Pide la actual, y al cambiarla <strong>se cierran todas tus sesiones</strong>,
              incluida ésta. Vas a tener que entrar de nuevo.
            </P>
          </>
        ),
      },
      {
        nombre: "Ayuda",
        entrada: "D",
        ruta: "/ayuda",
        resumen: "Este manual.",
        buscable: "ayuda manual instrucciones guia como se usa",
        ficha: (
          <>
            <Aviso titulo="Está en el menú de todos, sin permisos">
              Igual que Dashboard y Configuración, es una entrada fija: no se da de alta en
              Administración → Páginas ni se asigna a nadie. Un manual de uso lo necesita sobre todo
              quien todavía no sabe usar el sistema, y ponerlo detrás de un permiso dejaría a esa
              persona sin la pantalla que le explica cómo pedirlo.
            </Aviso>
            <P>
              Hay además una versión pública y resumida en <strong>/manual.html</strong>, enlazada
              desde el login, para quien no puede entrar.
            </P>
          </>
        ),
      },
    ],
  },
];

/* ══════════════════════════ Secciones generales ══════════════════════ */

const GENERALES: { id: string; titulo: string; buscable: string; contenido: ReactNode }[] = [
  {
    id: "primeros-pasos",
    titulo: "Primeros pasos",
    buscable:
      "entrar login sesion contraseña olvide recuperar correo instalar pwa celular 8 horas vence empresa sucursal",
    contenido: (
      <>
        <H>Entrar al sistema</H>
        <P>
          Se entra con usuario y contraseña, y además hay que elegir la empresa con la que se va a
          trabajar. La empresa es obligatoria: casi todo lo que se ve después depende de ella.
        </P>
        <P>
          Si los datos están mal, el sistema dice sólo <em>"Usuario o contraseña incorrectos"</em>,
          sin aclarar cuál de los dos falló. Es a propósito: si dijera "ese usuario no existe",
          cualquiera podría ir probando nombres para averiguar qué cuentas son válidas.
        </P>
        <Aviso titulo="La sesión dura 8 horas">
          Pasado ese tiempo el sistema te devuelve al login, aunque estés trabajando. No es un
          error: guardá antes de irte a almorzar.
        </Aviso>

        <H>Si olvidaste tu contraseña</H>
        <P>
          En el login hay un enlace de recuperación. Pide tu usuario y tu correo, y los dos tienen
          que coincidir con los cargados en tu cuenta. Si coinciden, te llega una contraseña
          provisoria por mail: entrá con ella y cambiala enseguida desde Configuración.
        </P>
        <Aviso titulo="El sistema siempre responde lo mismo">
          Coincidan o no los datos, la respuesta es{" "}
          <em>"Si los datos son correctos, vas a recibir un correo"</em>. No te confirma si
          acertaste — es la misma protección que en el login.
          <br />
          <br />
          Por eso, si no te llega nada, puede ser por cuatro motivos que se ven igual: escribiste
          mal el usuario, escribiste mal el correo, tu cuenta no tiene correo cargado, o está
          inactiva. En cualquiera de esos casos, pedile a un administrador que te{" "}
          <strong>establezca</strong> una contraseña.
        </Aviso>

        <H>Empresa y sucursal activas</H>
        <P>
          Arriba, en la barra superior, están la empresa y la sucursal activas. No son un adorno:{" "}
          <strong>filtran todo lo que ves</strong>. La empresa se cambia desde la barra; la sucursal
          importa sobre todo en stock.
        </P>
        <Aviso titulo="¿Una pantalla aparece vacía y no debería?">
          Esto es lo primero a revisar. El caso típico: cargaste algo en la sucursal Central y lo
          estás buscando parado en Depósito.
        </Aviso>

        <H>Instalar como aplicación</H>
        <P>
          El sistema se puede instalar en el celular o la computadora y queda con su ícono, como
          cualquier app. Al entrar aparece solo el aviso que lo ofrece.
        </P>
      </>
    ),
  },
  {
    id: "preguntas",
    titulo: "Preguntas frecuentes",
    buscable:
      "problema error no funciona vacia no veo no puedo borrar guarani pdf bloqueador sesion stock no baja",
    contenido: (
      <>
        {[
          [
            "Pedí recuperar mi contraseña y no me llegó nada.",
            "Revisá spam. Si no está, puede ser que tu usuario o tu correo no coincidan con los cargados, que tu cuenta no tenga correo, o que esté inactiva — el sistema no distingue esos casos a propósito. Pedile a un administrador que te establezca una contraseña.",
          ],
          [
            "Una pantalla me aparece vacía.",
            "Mirá la empresa y la sucursal activas arriba. Es la causa más común.",
          ],
          [
            "Cargué algo y no lo veo en el listado.",
            "Puede estar filtrado. Revisá el buscador, los filtros de las columnas y —en las pantallas que lo tienen— el filtro de activo/inactivo.",
          ],
          [
            "Vendí y el stock no bajó.",
            "Es el comportamiento actual, no una falla. Ver el módulo Stock.",
          ],
          [
            "No puedo borrar una venta o una factura.",
            "Tiene cobros o pagos registrados. Borrá primero esos movimientos.",
          ],
          [
            "No puedo borrar un usuario.",
            "Tiene movimientos registrados. Inactivalo: le corta el acceso igual y conserva el historial.",
          ],
          [
            "Me saca al login mientras trabajo.",
            "La sesión dura 8 horas. También pasa si un administrador te cambió la contraseña o te inactivó la cuenta.",
          ],
          [
            "El PDF no muestra el símbolo del guaraní.",
            "Es esperado: en los PDF la columna dice «Gs.» en el título y el número va sin símbolo, porque la fuente del generador no tiene ese carácter.",
          ],
          [
            "El PDF no se abre.",
            "Puede ser el bloqueador de ventanas emergentes. Si lo bloquea, el archivo se descarga igual.",
          ],
        ].map(([pregunta, respuesta]) => (
          <div key={pregunta} className="border-b py-3 last:border-b-0">
            <p className="text-sm font-medium">{pregunta}</p>
            <p className="mt-1 text-sm leading-relaxed text-muted-foreground">{respuesta}</p>
          </div>
        ))}
      </>
    ),
  },
];

/* ═════════════════════════════ La pantalla ═══════════════════════════ */

/** Texto en el que busca una pantalla: nombre, ruta, resumen y extras. */
function textoDe(p: Pantalla): string {
  return `${p.nombre} ${p.ruta ?? ""} ${p.resumen} ${p.buscable ?? ""}`.toLowerCase();
}

function AyudaPage() {
  const [busqueda, setBusqueda] = useState("");
  const termino = busqueda.trim().toLowerCase();

  // Al buscar se filtran las PANTALLAS, no los módulos: un módulo se muestra si
  // alguna de las suyas matchea, y sólo con ésas adentro. Filtrar por módulo
  // dejaría "Ventas" entero por una coincidencia en Cobros.
  const modulosFiltrados =
    termino === ""
      ? MODULOS
      : MODULOS.map((m) => ({
          ...m,
          pantallas: m.pantallas.filter(
            (p) => textoDe(p).includes(termino) || m.nombre.toLowerCase().includes(termino),
          ),
        })).filter((m) => m.pantallas.length > 0);

  const generalesFiltradas =
    termino === ""
      ? GENERALES
      : GENERALES.filter(
          (s) =>
            s.titulo.toLowerCase().includes(termino) || s.buscable.toLowerCase().includes(termino),
        );

  const sinResultados = modulosFiltrados.length === 0 && generalesFiltradas.length === 0;

  return (
    <AppLayout active="Ayuda" title="Manual de uso">
      <div className="mx-auto max-w-4xl space-y-6">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <BookOpen className="size-5" />
              Manual de uso
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <P>
              Ordenado igual que el menú: <strong>módulo</strong> › <strong>sección</strong> ›{" "}
              <strong>pantalla</strong>. Tocá una pantalla para ver su ficha, o buscá por palabra.
            </P>
            <div className="flex flex-wrap gap-x-5 gap-y-1.5">
              {ENTRADAS.map((e) => (
                <span key={e.codigo} className="flex items-center gap-1.5 text-xs">
                  <e.icono className="size-3.5 text-muted-foreground" />
                  <strong className="font-medium">{e.label}:</strong>
                  <span className="text-muted-foreground">{e.explica}</span>
                </span>
              ))}
            </div>
            <Input
              placeholder="Buscar: «contraseña», «conteo», «planilla», «suplente»…"
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
            />
            {termino === "" && (
              <div className="flex flex-wrap gap-2">
                {MODULOS.map((m) => (
                  <Button key={m.id} variant="outline" size="sm" asChild>
                    <a href={`#${m.id}`}>
                      <m.icono className="size-4" />
                      {m.nombre}
                    </a>
                  </Button>
                ))}
              </div>
            )}
          </CardContent>
        </Card>

        {sinResultados && (
          <Card>
            <CardContent className="py-10 text-center">
              <p className="text-sm text-muted-foreground">
                No hay ninguna pantalla que hable de «{busqueda}».
              </p>
              <Button variant="link" onClick={() => setBusqueda("")}>
                Ver el manual completo
              </Button>
            </CardContent>
          </Card>
        )}

        {generalesFiltradas.map((s) => (
          <Card key={s.id} id={s.id} className="scroll-mt-20">
            <CardHeader>
              <CardTitle>{s.titulo}</CardTitle>
            </CardHeader>
            <CardContent>{s.contenido}</CardContent>
          </Card>
        ))}

        {modulosFiltrados.map((modulo) => (
          <Card key={modulo.id} id={modulo.id} className="scroll-mt-20">
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <modulo.icono className="size-5" />
                {modulo.nombre}
                <Badge variant="secondary" className="ml-auto font-normal">
                  {modulo.pantallas.length}{" "}
                  {modulo.pantallas.length === 1 ? "pantalla" : "pantallas"}
                </Badge>
              </CardTitle>
              <p className="text-sm text-muted-foreground">{modulo.descripcion}</p>
            </CardHeader>
            <CardContent className="space-y-5">
              {/* El nivel intermedio: dentro del módulo, las pantallas van
                  agrupadas por su sección del menú (Definiciones, Operaciones,
                  Reportes), en el mismo orden en que las despliega el sidebar.
                  Sin esto, alguien que en el menú abre Ventas › Operaciones ›
                  Cobros tendría que buscar Cobros en una lista plana. */}
              {porEntrada(modulo.pantallas).map((seccion) => (
                <div key={seccion.codigo}>
                  <div className="mb-1 flex items-center gap-2">
                    <seccion.icono className="size-4 text-muted-foreground" />
                    <h3 className="text-sm font-semibold">{seccion.label}</h3>
                    <Badge variant="outline" className="font-normal">
                      {seccion.pantallas.length}
                    </Badge>
                  </div>
                  <p className="mb-2 text-xs text-muted-foreground">{seccion.explica}</p>

                  {/* Al buscar se abren todas: si alguien buscó "suplente",
                      esconder la ficha que lo menciona detrás de un click sería
                      devolverle un resultado que todavía no responde nada.

                      Va como `defaultValue` NO controlado, con una `key` que
                      cambia con el término: así el acordeón se remonta con las
                      fichas ya abiertas, pero el usuario puede cerrarlas.
                      Controlarlo con `value` se lo impediría —volverían a
                      abrirse en cada render— y además `exactOptionalPropertyTypes`
                      no acepta el `undefined` que haría falta para alternar
                      entre controlado y no. */}
                  <Accordion
                    key={termino === "" ? "plegado" : "buscando"}
                    type="multiple"
                    className="w-full"
                    defaultValue={termino === "" ? [] : seccion.pantallas.map((p) => p.nombre)}
                  >
                    {seccion.pantallas.map((pantalla) => (
                      <AccordionItem key={pantalla.nombre} value={pantalla.nombre}>
                        <AccordionTrigger className="text-left hover:no-underline">
                          <div className="flex flex-1 flex-col gap-0.5 pr-2">
                            <div className="flex flex-wrap items-center gap-2">
                              <span className="font-medium">{pantalla.nombre}</span>
                              {pantalla.ruta ? (
                                <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-[0.7rem] text-muted-foreground">
                                  {pantalla.ruta}
                                </code>
                              ) : (
                                <Badge variant="outline" className="text-[0.65rem] font-normal">
                                  se abre desde otra pantalla
                                </Badge>
                              )}
                            </div>
                            <span className="text-sm font-normal text-muted-foreground">
                              {pantalla.resumen}
                            </span>
                          </div>
                        </AccordionTrigger>
                        <AccordionContent>{pantalla.ficha}</AccordionContent>
                      </AccordionItem>
                    ))}
                  </Accordion>
                </div>
              ))}
            </CardContent>
          </Card>
        ))}

        <Separator />
        <p className="pb-6 text-center text-xs text-muted-foreground">
          El menú de cada persona depende de sus permisos: puede que no veas todas las pantallas de
          este manual. ¿Falta algo o algo cambió? Avisale a quien administra el sistema.
        </p>
      </div>
    </AppLayout>
  );
}

export const Route = createFileRoute("/_auth/ayuda")({
  head: () => ({
    meta: [
      { title: tituloPagina("Ayuda") },
      {
        name: "description",
        content: "Manual de uso del sistema, módulo por módulo y pantalla por pantalla.",
      },
    ],
  }),
  component: AyudaPage,
});
