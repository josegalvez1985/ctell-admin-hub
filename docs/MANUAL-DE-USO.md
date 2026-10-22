# Manual de uso — Ctell Admin Hub

Guía para quien **usa** el sistema, no para quien lo programa.

Está ordenada con **la misma jerarquía que el menú**, en tres niveles:

```
Módulo          →  Ventas
  Sección       →    Operaciones
    Pantalla    →      Cobros
```

Así, quien busca ayuda de una pantalla la encuentra donde la abre. Las tres
secciones son siempre las mismas:

| Sección          | Qué agrupa                                                          |
| ---------------- | ------------------------------------------------------------------- |
| **Definiciones** | Lo que se carga una vez y después se elige desde otras pantallas.   |
| **Operaciones**  | El trabajo de todos los días: lo que se registra a medida que pasa. |
| **Reportes**     | Consultas que no modifican nada. Se miran y se exportan.            |

Si buscás cómo agregar una tabla o una pantalla nueva, eso está en
[GUIA-IMPLEMENTACION.md](GUIA-IMPLEMENTACION.md) y [GUIA-FRONTEND.md](GUIA-FRONTEND.md).

**Dirección del sistema:** https://www.ctell.online

> ### ⚠️ Este contenido vive en tres lugares
>
> | Dónde                                                         | Qué es                        | Quién lo ve                    |
> | ------------------------------------------------------------- | ----------------------------- | ------------------------------ |
> | Este archivo                                                  | La fuente completa            | Quien mantiene el sistema      |
> | [`src/routes/_auth.ayuda.tsx`](../src/routes/_auth.ayuda.tsx) | La pantalla **Ayuda**, en JSX | Cualquier usuario con sesión   |
> | [`public/manual.html`](../public/manual.html)                 | Versión pública **resumida**  | Cualquiera, sin iniciar sesión |
>
> Son copias deliberadas: renderizar este markdown en la app pediría sumar
> `react-markdown` al bundle para una pantalla que se abre poco, y el HTML
> suelto no puede importar nada del proyecto.
>
> **Si cambia una regla del sistema, hay que actualizar los tres.** El HTML
> público es un resumen, así que sólo cambia si lo afectado está ahí.
>
> **El asistente con IA lee este mismo archivo** (`src/lib/asistente.ts`, desde
> "Primeros pasos" hasta antes del anexo), así que lo que se documente acá lo
> sabe con el deploy. Por eso, fuera del anexo, **ni nombres de tablas ni de
> archivos**: el asistente tiene prohibido contarlos, y tenerlos a mano sólo le
> complica cumplirlo.

> **El menú de cada persona depende de sus permisos.** Este manual describe
> todas las pantallas; puede que un usuario no vea algunas.

---

## Índice

**Generales**

- [Primeros pasos](#primeros-pasos)
- [Preguntas frecuentes](#preguntas-frecuentes)

**Módulos**

| Módulo                                       | Definiciones                                                                                                         | Operaciones                                                               | Reportes                             |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------ |
| [Ventas](#módulo-ventas)                     | —                                                                                                                    | Punto de venta · Ventas · Cobros                                          | —                                    |
| [Compras](#módulo-compras)                   | —                                                                                                                    | Facturas de compras · Pagos                                               | —                                    |
| [Stock](#módulo-stock)                       | Artículos · Ubicaciones de artículos · Ubicaciones                                                                   | Inventarios                                                               | Existencias · Reporte de inventarios |
| [Tesorería](#módulo-tesorería)               | Bancos · Cuentas bancarias · Canales de pago · Condiciones de pago · Monedas · Listas de descuentos                  | —                                                                         | —                                    |
| [Recursos humanos](#módulo-recursos-humanos) | Profesores · Instituciones · Manuales                                                                                | Reportes de actividades · Justificaciones de ausencia · Ficha de traspaso | Asistencias                          |
| [Base](#módulo-base)                         | Empresas · Sucursales · Personas · Categorías · Marcas · Unidades · IVA · Talonarios · Países · Códigos equivalentes | —                                                                         | —                                    |
| [Administración](#módulo-administración)     | Usuarios · Módulos y Páginas · Permisos                                                                              | Notificaciones                                                            | —                                    |
| [Configuración](#módulo-configuración)       | Configuración · Ayuda                                                                                                | —                                                                         | Dashboard                            |

---

## Primeros pasos

### Entrar al sistema

Se entra con **usuario y contraseña**, y además hay que **elegir la empresa** con
la que se va a trabajar. La empresa es obligatoria: casi todo lo que se ve
después depende de ella.

Si los datos están mal, el sistema dice sólo _"Usuario o contraseña
incorrectos"_, sin aclarar cuál de los dos falló. Es a propósito: si dijera "ese
usuario no existe", cualquiera podría ir probando nombres para averiguar qué
cuentas son válidas.

> **La sesión dura 8 horas.** Pasado ese tiempo el sistema te devuelve al login,
> aunque estés trabajando. No es un error: guardá antes de irte a almorzar.

### Si olvidaste tu contraseña

En el login hay un enlace de recuperación. Pide **tu usuario y tu correo**, y los
dos tienen que coincidir con los cargados en tu cuenta. Si coinciden, te llega
una contraseña provisoria por mail: entrá con ella y cambiala enseguida.

> **El sistema siempre responde lo mismo**, coincidan o no los datos. No te
> confirma si acertaste — es la misma protección que en el login.
>
> Por eso, **si no te llega nada**, puede ser por cuatro motivos que se ven
> igual: escribiste mal el usuario, escribiste mal el correo, tu cuenta no tiene
> correo cargado, o está inactiva. En cualquiera de esos casos, pedile a un
> administrador que te **establezca** una contraseña.

### Empresa y sucursal activas

Arriba, en la barra superior. No son un adorno: **filtran todo lo que ves**. La
empresa se cambia desde la barra; la sucursal importa sobre todo en stock.

> **Si una pantalla aparece vacía y no debería**, esto es lo primero a revisar.
> El caso típico: cargaste algo en la sucursal Central y lo estás buscando parado
> en Depósito.

### Instalar como aplicación

El sistema se puede instalar en el celular o la computadora y queda con su ícono,
como cualquier app. Al entrar aparece solo el aviso que lo ofrece.

---

# Módulo: Ventas

La caja, los comprobantes emitidos y la plata que entra.

## Operaciones

_El trabajo de todos los días: lo que se registra a medida que pasa._

### Punto de venta

`/punto-venta` — la caja: se arma el carrito y se cobra.

**Cómo se usa.** Se buscan los artículos, se arma el carrito y se guarda. Al
guardar se abre el modal de cobro, donde se registra cómo paga el cliente.

> **El precio que cargás ya incluye el IVA**, como se factura en Paraguay. Si la
> etiqueta dice 11.000, ponés 11.000 — no 10.000 más impuesto. El sistema
> desglosa solo cuánto es gravado y cuánto es IVA.

**Detalles:**

- **La lista de descuentos es opcional.** Sin lista se usa el precio de etiqueta
  y 0% de descuento.
- Según el **canal de pago**, se pide la cuenta bancaria receptora. Eso depende
  de cómo esté configurado el canal, no de su nombre.
- La venta se registra en la **sucursal activa**.

> **Hoy se puede vender sin existencia.** El sistema no te frena si el artículo
> está en cero. Ver [Stock](#módulo-stock).

### Ventas

`/ventas` — los comprobantes ya emitidos: se consultan y se eliminan.

**Cómo se usa.** Se consulta el detalle de cada venta emitida y, si hace falta,
se elimina. **No se edita**: una venta emitida no se corrige. Si está mal, se
elimina y se hace de nuevo.

> **Una venta con cobros registrados no se puede borrar.** Primero hay que
> eliminar sus cobros. El sistema lo avisa en vez de dejar plata cobrada contra
> una venta que ya no existe.

> **Borrar una venta no repone stock.** Ver [Stock](#módulo-stock).

### Cobros

`/cobros` — la plata que entra por cada venta, con su historial.

**Cómo se usa.** Se elige la venta, se registra el cobro y queda el historial. Se
puede cobrar en varias veces.

**Reglas:**

- **El monto se valida contra el saldo:** no se puede cobrar más de lo que se
  debe.
- Según el canal de pago, el sistema **pide la cuenta receptora**. Un canal sin
  el indicador de banco se trata como efectivo.
- **Borrar un cobro devuelve el saldo** a la venta.

---

---

# Módulo: Compras

Las facturas de proveedores y lo que se les paga.

## Operaciones

_El trabajo de todos los días: lo que se registra a medida que pasa._

### Facturas de compras

`/facturas-compras` — las facturas que emiten los proveedores.

**Cómo se usa.** Se carga la factura con su detalle de artículos. Funciona igual
que una venta, pero al revés: el IVA se desglosa del mismo modo y los totales se
calculan del detalle.

> **Una factura con pagos no se elimina.** Primero hay que borrar sus pagos.

> **Hoy una compra no ingresa stock.** Ver [Stock](#módulo-stock).

### Pagos

`/pagos` — lo que se le paga a cada proveedor. Espejo de Cobros.

**Cómo se usa.** Es el espejo exacto de Cobros, con la plata saliendo: se elige
la factura, se registra el pago y queda el historial.

**Reglas:**

- El monto se valida contra el saldo pendiente.
- Según el canal, se pide la cuenta desde la que sale la plata.
- Borrar un pago devuelve el saldo a la factura.

---

---

# Módulo: Stock

Qué hay en cada depósito, y el conteo físico que lo corrige.

> ### ⚠️ El stock está en transición
>
> Hoy **ninguna venta ni compra mueve el stock**: vender no descuenta, comprar no
> ingresa, y borrar una venta no repone nada. El único que escribe las
> existencias es el **cierre de un conteo físico**.
>
> Es un estado intermedio, conocido y en curso de resolución. Mientras tanto, la
> cantidad confiable es la del último conteo.

## Definiciones

_Lo que se carga una vez y después se elige desde otras pantallas._

### Artículos

`/articulos` — el catálogo de productos.

**Cómo se usa.** Alta, edición y baja de los productos, con su precio, categoría,
marca y unidad.

**Filtrar.** Categoría y marca se filtran desde el **encabezado de su columna**.
La ubicación no, y hay una razón: un artículo puede estar en varios estantes a la
vez, así que no hay una columna que la muestre. Se filtra con el selector que
está al lado del buscador.

> **El selector de ubicación sólo ofrece estantes con artículos**, y de la
> sucursal activa. En un depósito con la grilla entera cargada la mayoría están
> vacíos, y ofrecerlos sería ofrecer búsquedas que ya se sabe que no devuelven
> nada.

### Ubicaciones de artículos

`/articulos-ubicaciones` — en qué estante está cada artículo.

Es un cruce entre artículos y estantes: **un artículo puede estar en varios
lugares** a la vez, y por eso no es un campo de la ficha del artículo sino una
pantalla propia.

### Ubicaciones

`/ubicaciones` — los estantes del depósito.

Alta y baja de los estantes o lugares del depósito. Son los que después se
asignan a los artículos y los que ofrece el filtro por estante al contar.

---

## Operaciones

_El trabajo de todos los días: lo que se registra a medida que pasa._

### Inventarios

`/inventarios` — la carga del conteo físico de la sucursal activa.

**Cómo se usa.** Se cuenta lo que hay en el depósito y se anota, artículo por
artículo. El diálogo de alta ofrece completar la ficha del artículo si le falta
marca, categoría o ubicación, y hay un filtro por estante para contar mientras se
recorre el depósito.

**Los estados:**

| Estado      | Qué se puede hacer                   |
| ----------- | ------------------------------------ |
| **Abierto** | Editarlo, anularlo o eliminarlo      |
| **Cerrado** | Sólo mirarlo — ya se aplicó al stock |
| **Anulado** | Sólo mirarlo — se descartó           |

> **Desde esta pantalla no se cierra un conteo, y es a propósito.** Contar y
> aplicar son dos actos distintos: el conteo se corrige las veces que haga falta,
> pero **aplicarlo cambia el stock y no se deshace**. Una acción así no va como
> un ícono más en la fila, al lado de editar y borrar, donde se toca de paso.
> Anular sí está, porque no toca el stock.

**Eliminar y anular no son lo mismo:**

- **Eliminar** es para el borrador que se cargó por error.
- **Anular** es para el conteo que se hizo de verdad y se decide no aplicar. Deja
  la constancia de que alguien fue al depósito.

## Reportes

_Consultas que no modifican nada. Se miran y se exportan._

### Existencias

`/existencias` — cuánto hay de cada artículo, por sucursal. Sólo consulta.

**Cómo se usa.** Es una **consulta**: no se da de alta ni se edita nada. Se
exporta a Excel y PDF, y lo que sale en el archivo es exactamente lo que ves en
pantalla — trae el catálogo entero, no sólo la página visible.

### Reporte de inventarios

`/inventarios-reporte` — los conteos por período, con exportación. Sólo consulta.

**Cómo se usa.** Los conteos de la sucursal activa por período. No da de alta, no
edita, no cierra.

**Filtros:** fechas (desde/hasta, con atajos), estado y diferencia (con o sin).

Se exporta a Excel y PDF, con exactamente lo que se ve en pantalla.

---

# Módulo: Tesorería

Dónde entra y sale la plata, y con qué medios.

## Definiciones

_Lo que se carga una vez y después se elige desde otras pantallas._

### Bancos

`/bancos` — los bancos con los que se opera.

Alta y baja de los bancos. Son los que después se eligen al crear una cuenta
bancaria.

### Cuentas bancarias

`/cuentas-bancarias` — las cuentas donde entra y sale la plata.

Las cuentas de la empresa, con su banco y su moneda. Son las que el sistema
ofrece al cobrar o pagar con un canal que requiere banco.

> **Los montos se escriben con separador de miles.** El campo lo va formateando
> mientras escribís: no hace falta poner los puntos.

### Canales de pago

`/canales-pagos` — efectivo, transferencia, tarjeta…

Los medios con los que se cobra y se paga.

> **El indicador de banco es el que decide si se pide la cuenta.** Al cobrar con
> un canal que lo tenga marcado, el sistema pide la cuenta receptora. Un canal
> **sin** ese indicador se trata como efectivo. No depende del nombre del canal:
> hay que marcarlo.

### Condiciones de pago

`/condiciones-pago` — contado, crédito a 30 días…

Las formas de pago acordadas, que después se eligen en una venta o compra.

### Monedas

`/monedas` — las monedas y su detalle de billetes.

Las monedas con las que se opera. Cada una lleva su detalle de billetes y
monedas, que se carga desde la misma fila.

### Listas de descuentos

`/listas-descuentos` — listas de precios con descuento.

Las listas que se pueden elegir en el punto de venta. Son opcionales: sin lista,
se usa el precio de etiqueta y 0% de descuento.

---

---

# Módulo: Recursos humanos

Profesores, sus marcaciones, sus reportes de clase y sus ausencias.

> **Este módulo trabaja junto con la app del profesor**, que es un sistema
> aparte. Algunas cosas se cargan allá y acá sólo se resuelven.

## Definiciones

_Lo que se carga una vez y después se elige desde otras pantallas._

### Profesores

`/profesores` — el padrón de profesores, con su foto.

Alta, edición y baja de los profesores. Cada uno lleva su foto y su cédula.

> **La cédula es única en todo el sistema.** Un profesor pertenece a una sola
> empresa, y eso es lo que define en qué empresa se ven sus marcaciones y sus
> ausencias.

### Instituciones

`/instituciones` — los colegios donde dan clase.

Alta y baja de las instituciones, con sus datos de contacto.

### Manuales

`/manuales` — los manuales en PDF, por institución y grado.

**Cómo se usa.** **El alta no lleva el PDF.** Primero se crea la fila con su
institución y grado, y después se sube el archivo desde la misma fila.

> **Un manual sin archivo es un estado normal, no un error.** La fila lo muestra
> con su cartel y un aviso arriba cuenta cuántos hay pendientes. El enlace al PDF
> aparece **sólo si el archivo está subido**: mandarte a una pestaña con un error
> sería peor que no ofrecerlo.

**Detalles:**

- **No hay baja lógica:** se elimina o no existe. Y al eliminarlo **se va también
  el PDF**.
- Sólo se aceptan archivos PDF, de hasta 20 MB.
- El PDF se abre en el visor del navegador, desde donde se imprime.

---

## Operaciones

_El trabajo de todos los días: lo que se registra a medida que pasa._

### Reportes de actividades

`/reportes-actividades` — la bitácora de clases: qué se hizo cada día, con fotos.

**Cómo se usa.** Se ve como una **línea de tiempo por mes**, no como una tabla.
Cada día con clase muestra su reporte, y se le cargan fotos.

> **Un reporte se escribe sobre una marcación.** No se elige profesor,
> institución ni fecha: salen de la marcación. Por eso **no se puede reportar un
> día que no se marcó** — si falta la marcación, primero se carga en Asistencias.
>
> Los días marcados **sin reporte** aparecen en la misma línea de tiempo, como
> tarjetas punteadas, con el botón para escribirlo. Así el hueco se ve donde
> está.

**Las fotos:**

- El **pie de foto se escribe en el visor**, con la foto a la vista — se pueden
  subir cinco de una y describirlas después.
- Cada foto se descarga con un **nombre que la explica** (fecha, hora, profesor,
  institución y posición), porque fuera del sistema una `IMG_0001.jpg` en
  Descargas no le dice nada a nadie.
- El combo de institución **depende del profesor elegido**: ofrece sólo donde ese
  profesor marcó ese mes.

> **Borrar una foto no la borra del servidor de imágenes.** La referencia
> desaparece de la galería, pero el archivo queda allá.

### Justificaciones de ausencia

`/justificaciones-ausencia` — la bandeja de solicitudes que mandaron los
profesores.

> **Acá no se dan de alta ni se borran, y no es un olvido.** Las cargan los
> profesores desde su app. Una justificación es un documento que mandó una
> persona: poder crearla acá dejaría cargar una ausencia a nombre de quien nunca
> la pidió, y poder borrarla eliminaría la única constancia de una que sí.

**Cómo se usa.** Lo que se hace acá es **resolverlas**: poner el estado, asignar
un suplente y dejar observaciones. Arriba hay un aviso con cuántas quedan
pendientes, con un botón que deja el filtro puesto.

**Detalles:**

- **Todos los filtros son del servidor** —estado, profesor, institución, fechas y
  búsqueda— y por eso están en un panel, no en cada columna.
- **Quién recibió la solicitud no se carga:** lo registra el sistema con el
  usuario que la gestionó, la primera vez. Después no se pisa — corregir una
  observación seis meses más tarde no mueve esa fecha.
- El **archivo adjunto** se ofrece sólo si es un enlace seguro. Si adjuntó algo
  que no se puede abrir, se avisa en vez de esconderlo.

### Ficha de traspaso de clase

**Se abre desde la justificación de ausencia**, con su botón. No tiene pantalla
propia ni entrada en el menú: una ficha existe por y para una ausencia concreta,
así que se entra por la solicitud que la motivó. Al cerrarla volvés a resolver la
solicitud, que es lo que estabas haciendo.

**Qué lleva.** Lo que necesita el suplente: por dónde entra, con quién se
presenta, qué materiales lleva, y grado por grado qué tema toca y a qué hora.

**Reglas:**

- Hay **una ficha por ausencia**. Una de varios días lleva una sola, fechada el
  primer día.
- Se puede guardar **sin los grados cargados**, para completar los horarios
  después. El sistema avisa que así todavía no le sirve al suplente.
- Se puede preparar **sin suplente asignado** — se avisa, pero no se impide.
- **Imprimir se ofrece sólo con la ficha guardada:** imprimir un formulario a
  medio llenar sacaría un papel que no es el que se va a entregar.

## Reportes

_Consultas que no modifican nada. Se miran y se exportan._

### Asistencias

`/asistencias` — las marcaciones de entrada y salida, con su planilla para
firmar.

**Las dos vistas:**

- **Planilla** — la que se imprime y se firma.
- **Detalle** — para revisar y corregir.

Tocando un día se abre el detalle de sus marcaciones, donde se editan, se borran
o se agrega una a mano. Los combos de año y mes ofrecen sólo períodos con datos.

> **Una planilla es de UNA persona.** Si en la institución marcaron tres
> profesores, vas a ver tres grillas apiladas, no una sola mezclada. En un papel
> que se firma, un día con dos entradas no puede dejar la duda de si fue alguien
> que entró y salió dos veces o dos personas distintas.

**La hora cátedra y el precio** se cargan **por profesor**, en el encabezado de
cada planilla: no todos dan cátedras de la misma duración —45 minutos en un
colegio, 60 en otro— ni cobran lo mismo. **Estos valores no se guardan**: se
escriben cada vez que se genera la planilla.

Al pie va **Actividad extra**, en blanco para completar a mano, y el resumen con
el desglose del IVA. Con varios profesores hay un cuadro consolidado al final.

> **Se exporta sólo a Excel.** El PDF se retiró.

---

# Módulo: Base

Los catálogos que alimentan al resto del sistema.

## Definiciones

_Lo que se carga una vez y después se elige desde otras pantallas._

### Empresas

`/empresas` — las empresas del sistema, con su logo.

La que está activa se elige al iniciar sesión y se cambia desde la barra
superior. El **logo** se sube desde la fila y aparece en los PDF que se exportan.

### Sucursales

`/sucursales` — las sucursales de la empresa activa.

La sucursal elegida en la barra superior es la que filtra el stock, el punto de
venta y los conteos.

> **No hay selector de empresa acá:** el alta va siempre a la empresa activa.

### Personas

`/personas` — clientes y proveedores.

El padrón de clientes y proveedores. Son los que se eligen al facturar una venta
o cargar una compra.

### Categorías

`/categorias` — categorías de artículos.

Clasifican los artículos. Se filtran desde el encabezado de su columna.

### Marcas

`/marcas` — marcas de artículos.

> **Marcas heredadas.** Puede haber filas marcadas así: son anteriores a que la
> tabla distinguiera por empresa, y las ve toda empresa.

### Unidades de medida

`/unidades-medida` — unidad, kilo, caja, litro…

Las unidades en que se venden y compran los artículos.

### IVA

`/iva` — las tasas de IVA.

Las tasas con las que se calcula el impuesto: 10%, 5% y exenta.

> **Los precios ya incluyen el IVA.** El sistema lo desglosa, no lo suma. Si la
> etiqueta dice 11.000, el cliente paga 11.000 — de los cuales 10.000 son
> gravados y 1.000 es IVA.

### Talonarios

`/talonarios` — numeración de comprobantes.

La numeración de los comprobantes que emite el sistema.

### Países, Departamentos, Ciudades

`/paises`, `/departamentos`, `/ciudades` — los domicilios, en cascada.

Tres pantallas encadenadas: un departamento pertenece a un país, y una ciudad a
un departamento. Se cargan en ese orden. Son las que después ofrecen los combos
de domicilio en personas, empresas e instituciones.

### Códigos equivalentes

**Se abre desde la ficha del artículo.** No tiene pantalla propia: los códigos
equivalentes pertenecen a un artículo concreto.

Sirven para encontrar un artículo por el código que usa el proveedor o por su
código de barras, además del propio.

---

---

# Módulo: Administración

Quién entra al sistema y qué puede ver. **Sólo para administradores.**

## Definiciones

_Lo que se carga una vez y después se elige desde otras pantallas._

### Usuarios

**Se abre desde Administración o Configuración.** Es un diálogo, no una pantalla
propia.

**El alta.** El correo es **obligatorio** y la contraseña no se escribe: la
genera el sistema y se la manda por mail. Si el correo no sale, la respuesta
muestra la clave en pantalla — es el único respaldo, porque nadie más la conoce.
**Anotala antes de cerrar.**

**Reglas:**

- **El nombre de usuario no se puede cambiar.** Es la identidad de login; para
  cambiarlo hay que crear una cuenta nueva.
- **Nadie puede eliminarse ni inactivarse a sí mismo.** Evita quedarse afuera a
  mitad de una operación.

#### Las dos formas de resetear una contraseña

| Botón                     | Qué hace                                                           | Cuándo usarlo                                                          |
| ------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------------------- |
| **Enviar contraseña**     | Genera una clave al azar y la manda por correo. Vos no la conocés. | Uso normal, con correo cargado y andando                               |
| **Establecer contraseña** | Vos escribís la clave y se la dictás.                              | La cuenta no tiene correo, el correo no llega, o necesita entrar ahora |

> **"Enviar contraseña" se deshabilita sin correo cargado**, y también si la
> cuenta está inactiva. El sistema te lo dice al pasar el mouse por encima. Para
> esos casos está el otro botón.

**Las dos opciones cierran todas las sesiones abiertas** de esa persona. Si la
clave se cambia porque la cuenta está comprometida, dejar sesiones vivas anularía
el motivo del cambio.

> ### ⚠️ Al establecer una contraseña, vos pasás a conocerla
>
> Pedile a la persona que la cambie desde Configuración apenas entre.
>
> **Si te la establecés a vos mismo, tu propia sesión se cierra** y volvés al
> login. Es esperado, no un error.

> **Un usuario con movimientos no se puede eliminar.** Cargó ventas, compras o
> inventarios, y borrarlo se llevaría ese historial. La salida es
> **inactivarlo**: le corta el acceso al instante y conserva quién hizo cada cosa.

### Módulos y Páginas

**Se abren desde Administración o Configuración.** Son diálogos, no pantallas
propias.

**Módulos** son los grupos del menú; **Páginas**, las pantallas dentro de cada
módulo. Una pantalla nueva no aparece sola: hay que darla de alta acá, con su
ruta.

El orden importa — **primero el módulo, después la página**. La ruta no se
escribe a mano: se elige de una lista que el sistema arma solo.

**Las secciones.** Cada página va en una de tres: Definiciones, Operaciones o
Reportes.

> **La misma ruta puede estar en dos módulos distintos** — dos entradas al mismo
> destino, para dos perfiles. Lo que no se puede es repetirla dentro del mismo
> módulo; si pasa, el sistema lo avisa mientras completás el formulario.

### Permisos

**Se abre desde Administración o Configuración.**

Se elige un usuario y se le marcan las páginas que puede ver. Eso es exactamente
lo que arma su menú: una página sin permiso no aparece.

> **Dashboard, Ayuda y Configuración no se asignan:** están fijas en el menú de
> todos.

## Operaciones

_El trabajo de todos los días: lo que se registra a medida que pasa._

### Notificaciones

`/notificaciones` — los avisos del sistema.

Los avisos que el sistema genera y su historial.

---

---

# Módulo: Configuración

Tus preferencias y esta ayuda. **Fijas en el menú de todos**, sin permisos.

## Definiciones

_Lo que se carga una vez y después se elige desde otras pantallas._

### Configuración

`/configuracion` — tema, color y tu contraseña.

**Preferencias:**

- **Tema:** claro, oscuro o el del sistema.
- **Color de acento:** 10 paletas.

**Cambiar mi contraseña.** Pide la actual, y al cambiarla **se cierran todas tus
sesiones**, incluida ésta. Vas a tener que entrar de nuevo.

### Ayuda

`/ayuda` — este manual.

> **Está en el menú de todos, sin permisos.** Igual que Dashboard y
> Configuración, es una entrada fija: no se da de alta en Administración →
> Páginas ni se asigna a nadie. Un manual de uso lo necesita sobre todo quien
> todavía no sabe usar el sistema, y ponerlo detrás de un permiso dejaría a esa
> persona sin la pantalla que le explica cómo pedirlo.

Hay además una **versión pública y resumida** en
[www.ctell.online/manual.html](https://www.ctell.online/manual.html), enlazada
desde el login, para quien no puede entrar.

---

## Reportes

_Consultas que no modifican nada. Se miran y se exportan._

### Dashboard

`/home` — los indicadores de la empresa y sucursal activas.

**Qué muestra:**

- **Montos del mes**, comparados con el mes anterior.
- **Unidades en depósito**, artículos bajo mínimo y stock crítico.
- **Últimos movimientos**: ventas, compras e inventarios mezclados.
- **Cuotas por vencer.**

Arriba están los **accesos rápidos**, ordenados por lo que más usás.

> **El valor del stock aparece en cero.** El sistema guarda la cantidad, pero
> todavía no a qué costo entró cada artículo. Mostrar unidades como si fueran
> guaraníes sería peor que un cero.

---

## Preguntas frecuentes

**Pedí recuperar mi contraseña y no me llegó nada.**
Revisá spam. Si no está, puede ser que tu usuario o tu correo no coincidan con
los cargados, que tu cuenta no tenga correo, o que esté inactiva — el sistema no
distingue esos casos a propósito. Pedile a un administrador que te **establezca**
una contraseña.

**Una pantalla me aparece vacía.**
Mirá la **empresa y la sucursal** activas arriba. Es la causa más común.

**Cargué algo y no lo veo en el listado.**
Puede estar filtrado. Revisá el buscador, los filtros de las columnas y —en las
pantallas que lo tienen— el filtro de activo/inactivo.

**Vendí y el stock no bajó.**
Es el comportamiento actual, no una falla. Ver [Stock](#módulo-stock).

**No puedo borrar una venta / una factura.**
Tiene cobros o pagos registrados. Borrá primero esos movimientos.

**No puedo borrar un usuario.**
Tiene movimientos registrados. **Inactivalo**: le corta el acceso igual y
conserva el historial.

**Me saca al login mientras trabajo.**
La sesión dura 8 horas. También pasa si un administrador te cambió la contraseña
o te inactivó la cuenta.

**El PDF que exporté no muestra el símbolo del guaraní.**
Es esperado: en los PDF la columna dice "Gs." en el título y el número va sin
símbolo, porque la fuente del generador no tiene ese carácter.

**El PDF no se abre.**
Puede ser el bloqueador de ventanas emergentes. Si lo bloquea, el archivo se
descarga igual.

---

## Anexo — Notas para quien administra el sistema

### Desplegar el cambio de "Establecer contraseña"

El backend está en [`db/usuarios.sql`](../db/usuarios.sql) y **se ejecuta entero,
una sola vez**, en la hoja de trabajo SQL de APEX.

1. **Frená `npm run dev` antes.** La sesión de desarrollo mantiene tomadas filas
   de metadatos que la republicación del módulo necesita; sin eso da `ORA-00060`
   y el endpoint viejo queda publicado.
2. No hace falta reejecutar `auth.sql`.
3. **Mirá la salida del final.** Tiene que aparecer `PKG_USUARIOS` en `VALID`,
   `USER_ERRORS` sin filas, y **cinco** endpoints, incluido `password/:id` con
   método `POST`. Si falta, el módulo quedó a medio publicar: reejecutá.

Contrato del endpoint:

| Código | Cuándo                                                                         |
| ------ | ------------------------------------------------------------------------------ |
| `200`  | `{ ok: true, esPropia: true\|false }` + revoca todas las sesiones de la cuenta |
| `400`  | contraseña de menos de 8 caracteres                                            |
| `403`  | quien llama no es administrador                                                |
| `404`  | el usuario no existe                                                           |

`esPropia` le dice al frontend si la sesión que hizo el pedido acaba de quedar
revocada, para mandar al login en vez de fallar con un 401 confuso.

### Cuando no llega un correo

Está documentado paso a paso en
[`db/diagnostico-correo.sql`](../db/diagnostico-correo.sql).

Lo primero a mirar, porque es la causa más frecuente y la más invisible: **una
cuenta activa sin correo cargado**. Para ella la recuperación responde que todo
salió bien y no manda nada.

---

_Estado de este manual: la pantalla del botón "Establecer contraseña" está en
desarrollo. El resto describe el sistema tal como funciona hoy._
