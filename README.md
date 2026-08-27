# Ctell Admin Hub

Sistema administrativo web y PWA para CTELL: compras, ventas, stock, tesorería
y recursos humanos, con login de usuarios.

## Stack

| Capa        | Tecnología                               |
| ----------- | ---------------------------------------- |
| Framework   | TanStack Start (React 19 + SSR disabled) |
| Ruteo       | TanStack Router (rutas por archivo)      |
| Datos       | TanStack Query                           |
| Estilos     | Tailwind CSS v4 + shadcn/ui              |
| Formularios | react-hook-form + zod                    |
| Build       | Vite 8 (SPA estática)                    |
| Hosting     | GitHub Pages                             |
| **Backend** | **Oracle APEX + ORDS (PL/SQL)**          |

El backend es independiente del frontend: son paquetes PL/SQL publicados como
REST por ORDS, en `https://oracleapex.com/ords/ctell/`. El frontend sólo los
consume por HTTP — no hay server functions ni acceso directo a la base.

## Desarrollo

Requiere Node.js 22 o superior.

```sh
npm install
npm run dev
```

Vite imprime la URL local al arrancar (normalmente `http://localhost:5173`).

### Comandos

| Comando            | Qué hace                              |
| ------------------ | ------------------------------------- |
| `npm run dev`      | Servidor de desarrollo con HMR        |
| `npm run build`    | Build de producción en `dist/client/` |
| `npm run preview`  | Sirve el build ya generado            |
| `npm run lint`     | ESLint + Prettier                     |
| `npm run format`   | Aplica formato a todo el proyecto     |
| `npx tsc --noEmit` | Verificación de tipos                 |

## Estructura

```
db/                      Backend: un archivo SQL por tabla
│                        (el orden de la lista es el ORDEN DE EJECUCIÓN)
├── auth.sql             PKG_AUTH + módulo ORDS /auth/  (ejecutar PRIMERO)
├── usuarios.sql         ABM de usuarios          ─┐
├── modulos.sql          Módulos del menú          │ Sólo administradores
├── paginas.sql          Páginas del menú          │ (ES_ADMIN = 'S')
├── usuario-paginas.sql  Permisos por empresa     ─┘
├── paises.sql           ─┐
├── departamentos.sql     │ Jerarquía geográfica (catálogos globales)
├── ciudades.sql         ─┘
├── personas.sql         Padrón de físicas y jurídicas (catálogo GLOBAL)
├── iva.sql              Tasas de IVA (catálogo global)
├── condiciones-pago.sql Contado, plazos y cuotas (catálogo global)
├── empresas.sql         Empresas + logo (BLOB) + listado público del login
├── sucursales.sql       Sucursales de cada empresa
├── bancos.sql           Entidades bancarias (catálogo GLOBAL)
├── cuentas-bancarias.sql Cuentas bancarias, POR EMPRESA, con banco y moneda
├── talonarios.sql        Numeración fiscal POR EMPRESA Y SUCURSAL
├── ventas.sql            Punto de venta: cabecera, detalle y cuotas
├── ventas-cobros.sql     Cobros de ventas y cuenta bancaria destino
├── monedas.sql          ─┐
├── detalle-monedas.sql   │ Denominaciones de cada moneda + foto (BLOB)
├── unidades-medida.sql   │ Definiciones POR EMPRESA
├── categorias.sql       ─┘
├── ubicaciones.sql      Zona/estante/nivel del depósito, POR EMPRESA Y SUCURSAL
├── lotes.sql            Partidas: cantidad, costo y vencimiento  ← ANTES que articulos
├── articulos.sql        Artículos + imagen (BLOB). Su stock SUMA los lotes
├── articulos-ubicaciones.sql  Cruce: en qué ubicaciones está cada artículo
├── inventarios-triggers-ddl.sql  DDL aparte: corrige los triggers de INVENTARIOS
├── inventarios.sql      Conteos físicos con máquina de estados
├── facturas-compras.sql Cabecera + detalle. La primera TRANSACCIÓN del proyecto
│                        Cada línea CREA UN LOTE: comprar hace entrar el stock
├── facturas-compras-pagos.sql  Pagos a proveedores. Espejo de ventas-cobros
├── dashboard.sql        PKG_DASHBOARD: los indicadores de la home, en 1 consulta
└── verificar.sql        Sólo lectura: dice si el backend quedó consistente

src/
├── routes/              Rutas (el archivo define la URL)
│   ├── __root.tsx       Layout raíz: <html>, providers, meta global
│   ├── index.tsx        "/" → login (elegir empresa + credenciales)
│   ├── _auth.tsx        Layout protegido (requiere token)
│   ├── _auth.home.tsx           "/home"          → panel general
│   ├── _auth.punto-venta.tsx    "/punto-venta"   → caja: carrito y cobro
│   ├── _auth.ventas.tsx         "/ventas"        → comprobantes: ver y eliminar
│   ├── _auth.cobros.tsx         "/cobros"        → cobros de ventas
│   ├── _auth.pagos.tsx          "/pagos"         → pagos a proveedores
│   ├── _auth.configuracion.tsx  "/configuracion" → preferencias
│   └── _auth.<tabla>.tsx        una por cada ABM
├── components/
│   ├── ctell/           Componentes propios del proyecto
│   │   ├── empresa-provider.tsx  Empresa activa de la sesión
│   │   ├── AccesosRapidos.tsx    Botonera de la home, ordenada por uso
│   │   ├── InputMoneda.tsx       Campo de monto: separa miles al escribir
│   │   ├── LogoEmpresa.tsx       Logo con iniciales de respaldo
│   │   ├── ImagenArticulo.tsx    Imagen con ícono de respaldo
│   │   ├── TableHeadFiltrable.tsx / TableHeadOrdenable.tsx
│   │   ├── Combobox.tsx          Selector con buscador
│   │   └── menu-iconos.ts        Íconos del menú, por nombre
│   └── ui/              shadcn/ui (no editar a mano)
├── hooks/
│   ├── use-usuario-actual.ts        Auth del usuario logueado
│   ├── use-menu-usuario.ts          Menú según permisos + empresa activa
│   ├── use-tabla-listado.ts         Búsqueda y orden de los listados
│   └── use-cerrar-sesion-al-vencer.ts
├── lib/
│   ├── api.ts           Cliente HTTP contra ORDS
│   ├── moneda.ts        Formato y parseo es-PY: el ÚNICO lugar donde se hace
│   └── uso-paginas.ts   Cuántas veces se abrió cada página (localStorage)
└── styles.css           Design system (variables de color en oklch)
```

## Backend

> **Regla: cada tabla tiene su propio archivo en `db/`, nombrado como la tabla,
> con todo su CRUD adentro.** Y cada uno de esos archivos termina en una página
> `src/routes/_auth.<tabla>.tsx` con su entrada de menú — incluidas las tablas de
> detalle y las de cruce, que no se resuelven como diálogo dentro de otra
> pantalla.

Cada archivo define `PKG_<TABLA>` con sus 4 procedimientos —`LISTAR`,
`INSERTAR`, `ACTUALIZAR`, `ELIMINAR`— y publica su módulo ORDS. Los endpoints
siguen siempre la misma forma:

| Método   | Ruta                                 |
| -------- | ------------------------------------ |
| `GET`    | `/<tabla>/listar`                    |
| `POST`   | `/<tabla>/crear`                     |
| `PUT`    | `/<tabla>/actualizar/:id`            |
| `DELETE` | `/<tabla>/eliminar/:id/:idEmpresa`\* |

\* En las tablas por empresa el borrado lleva **también el `idEmpresa`** — ver
[Aislamiento por empresa](#aislamiento-por-empresa). En los catálogos globales
(países, departamentos, ciudades, módulos, páginas, personas, IVA, condiciones de
pago) sigue siendo `/eliminar/:id`.

> **El `PUT` también lo exige, en el body.** No es un dato más a guardar: acota
> **a cuál fila** se aplica el cambio, igual que en el `DELETE`. Sin él la
> respuesta es `400 {"error":"idEmpresa es obligatorio"}`.
>
> Es fácil de olvidar porque no es un campo del formulario y el alta funciona
> igual —ahí el `idEmpresa` ya se manda—, así que el 400 aparece sólo al
> modificar. Pasó en siete pantallas a la vez: se copió el mismo formulario y se
> arrastró el mismo olvido. Los tipos de `api.ts` ahora lo declaran
> **obligatorio** en cada `actualizar`, para que el compilador lo atrape en vez
> de descubrirlo en producción.

**Los listados de tablas que crecen sin techo van paginados** (`?pagina=`,
`?tamanio=`, con búsqueda y filtros en SQL). No es una optimización: devolver el
catálogo entero en un solo JSON hace fallar al endpoint con 500 a partir de
cierta cantidad de filas — le pasó a `/articulos/listar` al cargar el catálogo
real. Ver el detalle en
[GUIA-IMPLEMENTACION.md](docs/GUIA-IMPLEMENTACION.md). Los catálogos acotados
(monedas, unidades, países) no lo necesitan.

`auth.sql` es la única excepción a la regla: no corresponde a una tabla sino a
una responsabilidad —verificar credenciales y manejar sesiones— que cruza
`USUARIOS` y `TOKENS`. El ABM de usuarios va aparte, en `usuarios.sql`.

#### Los que se salen del patrón

Cuatro módulos publican endpoints que no son los cuatro de arriba, y en todos los
casos porque la tabla no se comporta como una ficha:

| Endpoint                                       | Por qué existe                                                                                                                                       |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /facturas-compras/obtener/:id/:idEmpresa` | La factura **con su detalle**. El listado no lo trae: cien facturas con todas sus líneas serían un CLOB enorme para dibujar una tabla de encabezados |
| `POST /inventarios/procesar/:id/:idEmpresa`    | `ABIERTO → PROCESADO`. Dispara una acción con efectos sobre `LOTES`, no reemplaza un recurso — por eso `POST` y no `PUT`                             |
| `POST /inventarios/anular/:id/:idEmpresa`      | `ABIERTO → ANULADO`. **Ocupa el lugar del `/eliminar`**: un trigger prohíbe el `DELETE`                                                              |
| `GET /empresas/publicas`                       | El único endpoint **sin token**: alimenta el selector de empresa del login, donde todavía no hay sesión                                              |
| `GET /<tabla>/<imagen>/:id`                    | Los BLOB, también públicos: los consume un `<img>`, que no manda el header `Authorization`                                                           |

E `INVENTARIOS` **no tiene `/eliminar`** en absoluto — ver
[Máquina de estados](#máquina-de-estados-inventarios).

### Tablas por empresa

`SUCURSALES`, `CUENTAS_BANCARIAS`, `MONEDAS`, `UNIDADES_MEDIDA`, `CATEGORIAS`, `ARTICULOS`,
`UBICACIONES`, `LOTES`, `INVENTARIOS` y `FACTURAS_COMPRAS_CAB` **cuelgan de
`EMPRESAS`**: cada empresa tiene su propio juego. El `idEmpresa` no sale de un
combobox del formulario sino de la **empresa activa de la sesión**, que se elige
al iniciar sesión (ver [Empresa activa](#empresa-activa)).

Consecuencia en el listado: **no hacen JOIN contra `EMPRESAS`**. Como ya vienen
filtradas por una sola empresa, su nombre sería la misma constante repetida en
cada fila, y el frontend ya lo tiene.

`CUENTAS_BANCARIAS` se filtra por la empresa activa. `ID_BANCO` es obligatorio;
`ID_MONEDA` es opcional y, si se informa, debe pertenecer a la misma empresa.
Su `PUT` y su `DELETE` reciben `idEmpresa` y lo usan para aislar la operación.

`BANCOS` es un catálogo global referenciado por las cuentas. Sus endpoints no
reciben `idEmpresa`.

### Punto de venta

`/punto-venta` usa una vista operativa de una sola pantalla: catálogo buscable a
la izquierda y carrito sticky a la derecha. El precio se carga manualmente por
línea. La lista de descuentos seleccionada aplica su porcentaje en el servidor.

`VENTAS_CABECERAS` y `VENTAS_DETALLES` se guardan en una sola transacción. Al
confirmar, el backend consume el stock disponible de `LOTES` por vencimiento
más próximo. `VENTAS_CUOTAS` se genera usando vencimientos acumulados: una
condición de 30 días y 3 cuotas produce días 30, 60 y 90.

El POS exige un talonario activo de la sucursal. `PKG_VENTAS` lo bloquea, toma
de allí el tipo de comprobante, timbrado, establecimiento, punto de expedición
y número actual, y avanza `TALONARIOS.NRO_ACTUAL` en la misma transacción. El
frontend no genera ni envía un número fiscal manual.

`VENTAS_COBROS` se registra después de la venta y puede apuntar a una cuota,
canal, moneda y cuenta bancaria. `ventas-cobros.sql` agrega idempotentemente
`ID_CUENTA_BANCARIA`, que no estaba en el DDL original.

Endpoints agregados:

- `GET/POST /bancos/listar` y `/bancos/crear`, más `PUT/DELETE` sobre
  `/bancos/actualizar/:id` y `/bancos/eliminar/:id`.
- `GET /cuentas-bancarias/listar?idEmpresa=...`, `POST
  /cuentas-bancarias/crear`, `PUT /cuentas-bancarias/actualizar/:id` y
  `DELETE /cuentas-bancarias/eliminar/:id/:idEmpresa`.

### Aislamiento por empresa

> **Regla: ninguna operación puede tocar una fila de otra empresa. Filtrar el
> listado no alcanza — eso es la pantalla, no el endpoint.**

Cada `ACTUALIZAR` y cada `ELIMINAR` de una tabla por empresa **exige
`idEmpresa`** y lo lleva en el `WHERE`, no sólo en los campos a modificar:

```sql
UPDATE MONEDAS
   SET NOMBRE_MONEDA = NVL(TRIM(p_nombre_moneda), NOMBRE_MONEDA), …
 WHERE ID_MONEDA  = l_id
   AND ID_EMPRESA = l_id_empresa;   -- ← esto es el aislamiento
```

Sin ese `AND`, un `PUT /articulos/actualizar/57` modificaba el artículo 57
**aunque fuera de otra empresa**. No pasa usando la interfaz —la pantalla sólo
muestra los de tu empresa— pero sí llamando al endpoint directamente. El guard
del cliente evita el acceso accidental; sólo el del backend evita el
deliberado.

Tres detalles que hacen que el control no tenga puerta trasera:

- **`ID_EMPRESA` NO es modificable.** Salió del `SET` de todos los `UPDATE`:
  poder cambiarla permitiría **mover una fila a otra empresa**, que es
  exactamente lo que el `WHERE` impide. En `SUCURSALES` era lo más grave —
  arrastraría con ella sus ubicaciones y lotes.
- **La respuesta es 404, no 403.** Decir "existe pero no es tuya" confirma que
  el id existe, que es justamente lo que no debería poder averiguarse.
- **Las FK de destino también se validan.** Reasignar una denominación a una
  moneda ajena, o un lote a un artículo de otra empresa, es la misma fuga por
  otro camino.

Las tablas **sin** columna `ID_EMPRESA` heredan la empresa de su padre y se
validan con un `JOIN` antes de escribir:

| Tabla                   | Se valida contra         |
| ----------------------- | ------------------------ |
| `DETALLE_MONEDAS`       | su `MONEDA`              |
| `ARTICULOS_UBICACIONES` | su `ARTICULO`            |
| `USUARIO_PAGINAS`       | la empresa está en la PK |

> Los catálogos globales —`PAISES`, `DEPARTAMENTOS`, `CIUDADES`, `MODULOS`,
> `PAGINAS`, `USUARIOS`, `PERSONAS`, `IVA`, `CONDICIONES_PAGO`— **no** llevan
> este control: no cuelgan de ninguna empresa. `EMPRESAS` tampoco, porque ahí
> `ID_EMPRESA` es la PK.
>
> Ojo con los tres últimos, que son los más recientes: un proveedor, una tasa de
> IVA o una condición de pago **se comparten entre todas las empresas**. La misma
> persona puede ser cliente de una y proveedor de otra sin cargarse dos veces, y
> por eso sus endpoints no reciben `idEmpresa` ni acotan por ella.

`UBICACIONES` va un paso más: cuelga de la empresa **y** de la sucursal, y los dos
ids salen de los providers globales (ver
[Sucursal activa](#sucursal-activa)).

> **Dos FK no garantizan coherencia entre sí.** `UBICACIONES` tiene una FK a
> `EMPRESAS` y otra a `SUCURSALES`, y cada una valida sólo contra su tabla: la
> base acepta una fila con la empresa A y una sucursal de la empresa B, y el
> UNIQUE tampoco lo detecta. `PKG_UBICACIONES` lo verifica a mano antes de
> escribir y devuelve 400 — con una vuelta extra en el `ACTUALIZAR`, donde hay que
> resolver **cómo va a quedar la fila** (un `PUT` que cambia sólo la sucursal
> también puede romperla). El `.sql` cierra con una consulta de auditoría que debe
> devolver cero filas.

### Tablas de cruce: `ARTICULOS_UBICACIONES`

Un artículo puede estar en varias ubicaciones y una ubicación tener varios
artículos. La tabla que los une **no tiene datos propios** (tuvo una
`CANTIDAD_UBICADA` que se quitó del DDL), y eso cambia la forma del ABM:

- **No hay `actualizar`, sólo `crear` y `eliminar`.** Cambiar cualquiera de los
  dos ids es en la práctica otra asignación, así que reasignar es quitar y volver
  a asignar. Un `PUT` que cambiara ambos ids sería indistinguible de un
  `DELETE` + `POST`, con el riesgo extra de pisar una fila existente.
- **El listado SÍ hace `JOIN`**, al revés que las tablas por empresa: cada fila
  cruza un artículo distinto con una ubicación distinta, así que sus nombres no
  son una constante repetida. Sin el JOIN el frontend tendría que traerse las dos
  tablas enteras para mostrar una lista legible.
- **El `:id` del `DELETE` es el de la asignación**, no el del artículo ni el de la
  ubicación.

> **La coherencia de empresa tampoco está en el DDL, y acá cruza dos tablas.**
> `ARTICULOS` cuelga de `EMPRESAS` y `UBICACIONES` también, pero las FK de la
> tabla de cruce apuntan a sus propias tablas sin mirar la empresa: se puede
> asignar un artículo de la empresa A a una ubicación de la B. `ASIGNAR` compara
> las dos empresas y devuelve 400. El `.sql` cierra con la consulta de auditoría
> correspondiente.

En el frontend va como diálogo sobre el ABM de artículos (botón de ubicación en
cada fila), no como página propia: siempre se mira "dónde está **este**
artículo". El selector ofrece sólo las ubicaciones **no** asignadas todavía —
ofrecer una ya asignada daría 409 — y **no** se filtra por la sucursal activa, porque
un artículo puede estar en depósitos de varias sucursales.

### Imágenes (BLOB)

`EMPRESAS.LOGO`, `ARTICULOS.IMAGEN` y `DETALLE_MONEDAS.FOTO` son BLOB y **no
viajan en el JSON** — un binario no entra en un `JSON_OBJECT`. Cada uno tiene dos
endpoints propios:

| Método | Ruta                        | Auth  | Qué hace                   |
| ------ | --------------------------- | ----- | -------------------------- |
| `GET`  | `/empresas/logo/:id`        | —     | Devuelve la imagen cruda   |
| `PUT`  | `/empresas/logo/:id`        | token | Guarda el binario del body |
| `GET`  | `/articulos/imagen/:id`     | —     | Devuelve la imagen cruda   |
| `PUT`  | `/articulos/imagen/:id`     | token | Guarda el binario del body |
| `GET`  | `/detalle-monedas/foto/:id` | —     | Devuelve la imagen cruda   |
| `PUT`  | `/detalle-monedas/foto/:id` | token | Guarda el binario del body |

Los `GET` son **públicos** porque los consume un `<img>`, y el navegador no
manda el header `Authorization` al descargar una imagen. Los `PUT` sí piden
token: escribir nunca es público.

El listado devuelve `tieneLogo` / `tieneImagen` (booleano) en vez del binario,
así el frontend sabe si pedir la imagen o dibujar el respaldo —las iniciales de
la empresa, un ícono en el artículo— sin traerse todos los BLOB.

> **El `GET` de imagen NO se publica como los demás endpoints.** Lo natural
> sería un procedimiento con un `OUT BLOB` como parámetro `RESPONSE`, y **no
> funciona**: `DEFINE_PARAMETER` valida `p_param_type` contra
> `REST_PARAMS_PARAM_TYPE_CK`, y ni `'BLOB'` ni `'RESOURCE'` pasan esa
> restricción. El `ORA-02290` aborta la publicación a la mitad y deja el módulo
> **sin ningún endpoint**, no solo sin el que falló.
>
> La forma que sí funciona es `ORDS.source_type_media`: una consulta que
> devuelve dos columnas —content-type y BLOB— sin declarar parámetros de
> salida. De yapa, el 404 sale gratis: si la consulta no devuelve filas, ORDS
> responde 404 solo.

El content-type se guarda junto al binario en `LOGO_MIME` / `IMAGEN_MIME` /
`FOTO_MIME`. Esas columnas son la **única excepción** a la regla de no tocar el
DDL: los archivos las agregan en un paso 0 idempotente, que consulta
`USER_TAB_COLUMNS` antes del `ALTER`.

### Transacciones: cabecera y detalle

`FACTURAS_COMPRAS_CAB` + `FACTURAS_COMPRA_DET` es la **primera transacción** del
proyecto, y se comporta distinto de todas las tablas anteriores. Hasta acá cada
fila era una ficha independiente; una factura es una cabecera con sus líneas, y
las dos partes sólo tienen sentido juntas. Eso obliga a tres decisiones:

- **El detalle viaja como array JSON en el mismo request.** Guardar la cabecera y
  después las líneas de a una permitiría que la red se corte en el medio y quede
  una factura sin detalle —que no es una factura—. Con el array, `INSERTAR` hace
  todo en una transacción: o entra completa o no entra nada. Se parsea con
  `JSON_TABLE`.
- **`ACTUALIZAR` reemplaza el detalle entero**: borra las líneas y las reinserta.
  Comparar línea por línea sería mucho más código para el mismo resultado en
  facturas de cinco o diez líneas. Consecuencia: los `ID_DETALLE` cambian en cada
  edición.
- **`ELIMINAR` borra las dos tablas, detalle primero.** El DDL no declara
  `ON DELETE CASCADE`, así que al revés da `ORA-02292`.

`SUBTOTAL` es una **columna virtual** (`GENERATED ALWAYS AS`): la calcula Oracle
y mencionarla en un `INSERT` da `ORA-54013`. Está bien que sea así — no hay forma
de que quede desincronizada de sus factores.

Los totales **no se guardan**: se suman del detalle en cada consulta. Es el mismo
criterio que el stock de un artículo (`SUM` sobre lotes) y que el vencimiento de
una factura (`FECHA_FACTURA + DIAS_PAGO`). Si se puede derivar, se deriva.

### IVA: los precios lo incluyen, así que se divide

Es como se factura en Paraguay, y es la razón de que la tabla `IVA` tenga **dos
divisores** además del porcentaje:

| Columna            | Ejemplo (10%) | Para qué                      |
| ------------------ | ------------- | ----------------------------- |
| `PORCENTAJE`       | 10            | La tasa nominal, para mostrar |
| `IVA_DIVISION`     | 11            | Saca el impuesto contenido    |
| `GRAVADA_DIVISION` | 1,1           | Saca la base imponible        |

El método actual es **gravado por división, IVA por resta**:

```sql
GRAVADO = ROUND(SUBTOTAL / GRAVADA_DIVISION, 2)
IVA     = SUBTOTAL - GRAVADO
```

Con 110.000 al 10%: gravado 100.000, IVA 10.000. Y nunca
`SUBTOTAL * PORCENTAJE / 100`, que daría 11.000 — cobra impuesto sobre impuesto.

> **Por qué el IVA se resta en vez de dividirse por `IVA_DIVISION`:** las dos
> divisiones redondean por separado y sus redondeos son independientes, así que
> su suma no tiene por qué dar el subtotal. Con una división y una resta,
> `gravado + iva = total` siempre, exacto. En un libro de compras una diferencia
> de un guaraní por línea se acumula y no cuadra contra el papel.

**`GRAVADA_DIVISION` es NULLABLE** y las tasas cargadas antes de que existiera la
tienen vacía. Ahí el cálculo cae al método anterior —IVA por división, gravado
por resta— para que las facturas viejas sigan mostrando lo mismo. La elección es
**por fila**, con un `CASE`, no global.

> **La exenta usa criterios opuestos en los dos divisores**, y es lo más fácil de
> equivocar: `IVA_DIVISION` va en **0** ("no divide nada") y `GRAVADA_DIVISION`
> en **1** ("el monto entero es gravado"). Con `IVA_DIVISION` en 1 el desglose
> diría que todo el monto es impuesto; con `GRAVADA_DIVISION` en 0 sería división
> por cero. Ninguno de los dos falla visiblemente: dan cifras mal.
>
> Toda división va protegida con `NULLIF(..., 0)`.

### Máquina de estados: `INVENTARIOS`

Los conteos físicos son la única tabla con estados y transiciones:

```
ABIERTO ──> PROCESADO   (aplica el conteo al lote)
        └─> ANULADO     (lo descarta sin tocar nada)
```

Desde un estado terminal no se sale, y un conteo que ya no está `ABIERTO` no deja
tocar su `CANTIDAD_FISICA`. **Eso lo imponen los triggers**, no el paquete: vale
aunque alguien toque la tabla por fuera de la API. Lo que hace `PKG_INVENTARIOS`
es chequear antes para devolver un 409 legible en vez de dejar salir un
`ORA-20002` crudo como error 500.

> **El módulo no tiene `/eliminar`.** `TRG_INVENTARIOS_BD` prohíbe el `DELETE`, y
> es la decisión correcta: un conteo físico es evidencia de que alguien fue al
> depósito y contó. Borrarlo hace desaparecer esa evidencia; anularlo la deja
> asentada. `/anular` ocupa el lugar del `/eliminar` de las demás tablas.

**Los triggers originales tenían dos errores** que corrige
`db/inventarios-triggers-ddl.sql` —el único archivo de `db/` que administra DDL:

1. `TRG_INVENTARIOS_AU` ajustaba `LOTES.CANTIDAD` al procesar, pero **el stock de
   un artículo suma `CANTIDAD_DISPON`**. Procesar un conteo no movía el stock que
   se ve en pantalla, y no fallaba — simplemente no hacía efecto.
2. `TRG_INVENTARIOS_BIU` escribía `USUARIO_PROCESA`, columna que el DDL nuevo
   reemplazó por `ID_USUARIO` (FK a `USUARIOS`). El trigger no compilaba, y un
   trigger inválido bloquea todo `INSERT` y `UPDATE` de la tabla.

`ID_USUARIO` lo escribe el paquete, resolviéndolo del token: `USER` dentro de un
handler de ORDS devuelve el esquema del workspace, igual para todo el mundo.

### `PERSONAS`: físicas y jurídicas en una tabla

El DDL declara `NOMBRE` y `APELLIDO` como `NOT NULL` pero `RAZON_SOCIAL` como
nullable — y una persona jurídica es exactamente al revés. Se resuelve sin tocar
el DDL:

| Tipo           | Qué se pide       | Qué guarda el backend                                  |
| -------------- | ----------------- | ------------------------------------------------------ |
| `'F'` física   | Nombre y apellido | Tal cual. `RAZON_SOCIAL` en null                       |
| `'J'` jurídica | Razón social      | Copia la razón social en `NOMBRE`, `'-'` en `APELLIDO` |

El guión de relleno **no viaja al frontend**: el listado lo traduce a null, así
que la pantalla nunca ve la convención. Y para mostrar está el campo calculado
`nombreCompleto`, que resuelve cuál de los dos nombres corresponde — el frontend
usa ese y no repite la regla.

> `ACTUALIZAR` valida **cómo va a quedar la fila**, no lo que llegó: un PUT que
> cambia el tipo a `'J'` sin mandar razón social puede ser válido (si ya la tenía)
> o inválido. Por eso lee la fila actual antes de decidir.

### Orden de ejecución

Hay **seis dependencias reales**; el resto del orden es indistinto.

Todas siguen la misma regla: **un paquete que consulta una tabla necesita que esa
tabla exista al compilarse**, o queda `INVALID`. No alcanza con que el otro
archivo se ejecute después.

1. **`auth.sql` primero, sin excepción.** Todos los demás llaman a
   `PKG_AUTH` —`VALIDAR_TOKEN`, `VALIDAR_TOKEN_ADMIN`, el hasheo de
   contraseñas—, así que sin él ninguno compila. Si sale `INVALID`, frená ahí.
2. **`lotes.sql` antes que `articulos.sql`.** El listado de artículos hace un
   `SUM()` sobre `LOTES` para calcular el stock.
3. **`inventarios-triggers-ddl.sql` antes que `inventarios.sql`.** Los triggers
   que vinieron con el DDL original ajustaban la columna equivocada de `LOTES` y
   escribían una columna que ya no existe. Con los viejos, `PKG_INVENTARIOS`
   compila igual pero **procesar un conteo no mueve el stock**.
4. **`iva.sql`, `personas.sql` y `condiciones-pago.sql` antes que
   `facturas-compras.sql`.** El listado de facturas hace JOIN contra las tres.
5. **La tabla `FACTURAS_COMPRA_DET` antes que `iva.sql`**, y
   **`FACTURAS_COMPRAS_CAB` antes que `condiciones-pago.sql`**: los dos paquetes
   cuentan cuántas facturas usan cada fila para poder explicar por qué no se
   puede borrar. Es sólo el DDL de esas tablas, no el paquete.

```
1.  db/auth.sql                  13. db/monedas.sql
2.  db/usuarios.sql              14. db/detalle-monedas.sql
3.  db/modulos.sql               15. db/categorias.sql
4.  db/paginas.sql               16. db/unidades-medida.sql
5.  db/usuario-paginas.sql       17. db/ubicaciones.sql
6.  db/paises.sql                18. db/lotes.sql
7.  db/departamentos.sql         19. db/articulos.sql
8.  db/ciudades.sql              20. db/articulos-ubicaciones.sql
9.  db/empresas.sql              21. db/inventarios-triggers-ddl.sql
10. db/sucursales.sql            22. db/inventarios.sql
11. db/bancos.sql                23. db/personas.sql
12. db/cuentas-bancarias.sql     24. db/iva.sql
                                 25. db/condiciones-pago.sql
                                 26. db/talonarios.sql       después del DDL de TALONARIOS
                                 27. db/ventas.sql
                                 28. db/facturas-compras.sql
```

Los tres catálogos globales del final —personas, IVA y condiciones— van juntos
antes de ventas y facturas porque son dependencias de esas operaciones. `TALONARIOS`
debe existir antes de ejecutar `db/talonarios.sql`; y `db/talonarios.sql` antes de
`db/ventas.sql`, porque Ventas consulta y actualiza la numeración fiscal.

Después de cada uno: el paquete tiene que quedar `VALID` y la consulta de
`USER_ERRORS` sin filas. Al terminar, conviene verificar las dos cosas que
dejan el sistema inutilizable si salieron mal:

```sql
-- Ningún paquete inválido.
SELECT OBJECT_NAME, STATUS FROM USER_OBJECTS
 WHERE OBJECT_NAME LIKE 'PKG%' AND STATUS != 'VALID';

-- Al menos un administrador activo, o nadie entra a Administración.
SELECT ID_USUARIO, USUARIO FROM USUARIOS
 WHERE ES_ADMIN = 'S' AND ACTIVO = 'A';
```

Cada archivo se ejecuta **de una sola vez y por separado** en la hoja de trabajo
SQL de APEX, y contiene el paquete PL/SQL, el módulo ORDS con sus endpoints y
las consultas de verificación. Tocar empresas no obliga a reejecutar usuarios.

Los archivos son **idempotentes** (se pueden reejecutar) y **no crean ni alteran
tablas**: el DDL se administra aparte.

### Endpoints publicados

| Método | Ruta                     | Auth  | Devuelve                                                         |
| ------ | ------------------------ | ----- | ---------------------------------------------------------------- |
| `POST` | `/auth/login`            | —     | `token`, `expira`, `usuario`                                     |
| `POST` | `/auth/logout`           | token | `{ ok: true }`                                                   |
| `GET`  | `/auth/me`               | token | `id`, `usuario`, `nombreApellido`, `correo`, `activo`, `esAdmin` |
| `POST` | `/auth/recuperar`        | —     | mensaje neutro (siempre 200) + clave provisoria por mail         |
| `POST` | `/auth/cambiar-password` | token | `{ ok: true }` + revoca **todas** las sesiones                   |

El token se envía como `Authorization: Bearer <token>` y vence a las 8 horas.
El header se parsea con `PKG_AUTH.TOKEN_DE_HEADER`, que acepta el prefijo en
cualquier capitalización (`Bearer`/`bearer`), como pide la RFC.

`/auth/login` responde **401 con un único mensaje** —"Usuario o contrasena
incorrectos"— tanto si el usuario no existe, como si la clave está mal o la
cuenta está inactiva. Distinguir los casos permitiría enumerar cuentas válidas.

Validar un token comprueba tres cosas, no una: que el token esté vigente, que
no haya vencido, y que **la cuenta siga activa**. Por eso inactivar un usuario
le corta el acceso al instante, aunque su token todavía no hubiera expirado.

#### Autenticar no es autorizar

`VALIDAR_TOKEN` responde "¿quién sos?", no "¿podés hacer esto?". Para lo
segundo está **`PKG_AUTH.VALIDAR_TOKEN_ADMIN`**, que además exige
`ES_ADMIN = 'S'` y responde **403** — no 401, que el cliente interpreta como
sesión vencida y deslogueaba a alguien con la sesión sana.

Lo usan los cuatro módulos administrativos: `usuarios`, `modulos`, `paginas` y
`usuario-paginas` (en este último, `ASIGNAR` y `QUITAR`).

> **Esconder la pantalla no es seguridad.** La página de Administración ya
> redirigía a `/home` a quien no fuera admin, y aun así cualquier usuario con
> sesión podía hacer `GET /usuarios/listar` con su propio token y recibir la
> lista completa de cuentas —nombres, correos y quién es administrador—. Peor:
> `POST /usuario-paginas/asignar` le permitía **darse a sí mismo cualquier
> página, incluida Administración**, escalando privilegios con una petición.

**El caso mixto:** `usuario-paginas/listar` alimenta el menú de _todos_ los
usuarios —cada uno pidiendo los suyos— y también el ABM de permisos.
Restringirlo a admins dejaría sin menú a todo el mundo, así que el control va
sobre el parámetro: **cada uno ve los suyos, y sólo un admin ve los de otro**.

#### ABM de usuarios — `db/usuarios.sql`

Todos requieren token.

| Método   | Ruta                      | Qué hace                          |
| -------- | ------------------------- | --------------------------------- |
| `GET`    | `/usuarios/`              | listado paginado                  |
| `POST`   | `/usuarios/`              | alta → 201                        |
| `GET`    | `/usuarios/:id`           | detalle                           |
| `PUT`    | `/usuarios/:id`           | modificación                      |
| `DELETE` | `/usuarios/:id`           | baja física                       |
| `POST`   | `/usuarios/:id/inactivar` | baja lógica + revoca sus sesiones |
| `POST`   | `/usuarios/:id/activar`   | alta lógica                       |
| `POST`   | `/usuarios/:id/password`  | cambio de clave + revoca sesiones |

El listado acepta `?busqueda=`, `?activo=A|I`, `?pagina=` y `?tamanio=`
(25 por defecto, **200 como techo** — sin tope, un `?tamanio=999999` arma un
CLOB enorme y el request muere por timeout).

Tres decisiones que conviene conocer antes de tocarlo:

- **`USUARIO` no se modifica.** Es la identidad con la que se inicia sesión;
  para cambiarla se da de baja y se crea otro. El `PUT` lo ignora.
- **Nadie puede eliminarse ni inactivarse a sí mismo** (400). Se quedaría sin
  sesión a mitad de la operación, y si era el último administrador el sistema
  queda inaccesible.
- **Cambiar la contraseña revoca todas las sesiones**, incluida la propia. Es
  lo que se espera cuando se cambia por sospecha de robo.

El alta crea un **administrador inicial** (`admin`) sólo si la tabla está
vacía. La contraseña se genera al azar en cada corrida y se imprime una única
vez por `DBMS_OUTPUT` al ejecutar el script — no queda escrita en el
repositorio. Copiala de ahí y cambiala apenas entres.

> **Hash de contraseñas:** hoy usa `STANDARD_HASH` SHA-256 con salt, porque
> `DBMS_CRYPTO` no está concedido en el workspace. SHA-256 no tiene factor de
> trabajo y es débil frente a fuerza bruta. Si conseguís
> `GRANT EXECUTE ON SYS.DBMS_CRYPTO`, migrá a PBKDF2 — la versión está lista en
> un comentario dentro de `HASH_PASSWORD`. Migrar invalida los hashes
> existentes: hay que resetear las contraseñas.

### Correo: contraseñas por mail

El sistema manda la contraseña por correo en dos momentos, los dos vía
`PKG_AUTH.ENVIAR_PASSWORD_INICIAL` con `APEX_MAIL`:

- **Alta de usuario** (`POST /usuarios/`) — la clave inicial.
- **Recuperar acceso** (`POST /auth/recuperar`) — una clave provisoria que
  reemplaza la anterior y revoca todas las sesiones.

`/auth/recuperar` es **público** —quien lo usa es justamente alguien que no puede
entrar— y **siempre responde 200 con el mismo mensaje**, coincidan o no el
usuario y el correo. Distinguir los casos convertiría el endpoint en un
verificador de qué cuentas existen y con qué dirección, que es exactamente lo
que `/auth/login` evita con su mensaje único.

> **Un handler de ORDS no está parado en ningún workspace**, y `APEX_MAIL`
> necesita saber en cuál corre. Se fija con `APEX_UTIL.SET_SECURITY_GROUP_ID`
> resolviendo el id **por nombre** de workspace — encapsulado en
> `PKG_AUTH.ESTABLECER_WORKSPACE_MAIL`, que todo envío llama primero. Sin eso:
> `ORA-20987` ("el identificador de grupo de seguridad no es válido").
>
> **No sirve `APEX_SESSION.CREATE_SESSION`**: crear sesión exige una aplicación
> APEX y este workspace **no tiene ninguna** (el frontend es React). El código
> llamaba a `CREATE_SESSION` con un `p_app_id => 100` inventado, esa app nunca
> existió, y **ningún correo se envió jamás** — ni en el alta ni en la
> recuperación.

**Un fallo de correo nunca deshace la operación.** Cuando el envío corre, el
usuario ya está creado: `ENVIAR_PASSWORD_INICIAL` no propaga excepciones, avisa
por `p_enviado` (`'A'`/`'I'`). El alta lo aprovecha para devolver
`passwordInicial` en la respuesta **sólo si el correo no salió** — es el único
respaldo, porque nadie más conoce esa clave. Si salió, no viaja en el JSON.

> **Cuando el correo no llega, el sistema es mudo.** Los envíos se tragan el
> error a propósito y lo mandan a `APEX_DEBUG`, que no está activo por defecto:
> el síntoma es siempre "no llegó nada", sin causa visible. Para ver el error de
> verdad hay una función de diagnóstico que corre el mismo camino pero **lo
> devuelve** en texto:
>
> ```sql
> SELECT PKG_AUTH.PROBAR_CORREO('destino@ejemplo.com') FROM DUAL;
> ```
>
> Si devuelve `OK…` y aun así no llega, el problema es de entrega: revisá
> `APEX_MAIL_QUEUE` (con `MAIL_SEND_ERROR`) y `APEX_MAIL_LOG`.

Dos límites del **APEX free tier** que conviene tener presentes: el remitente lo
resuelve APEX con su parámetro de instancia `EMAIL_FROM` (se pasa
`p_from => NULL`) y sólo acepta como origen el correo de la cuenta; y el envío a
direcciones arbitrarias puede estar restringido. Si mandar claves a correos de
usuarios nuevos falla por eso, el respaldo es `passwordInicial`.

## Empresa activa

El login pide **dos cosas**: credenciales y **a qué empresa conectarse**. El
selector muestra las empresas como botones con su logo, alimentados por
`GET /empresas/publicas` — el **único endpoint del proyecto sin token**, porque
en esa pantalla todavía no hay sesión.

> Ese endpoint devuelve **solo `id` y `nombreEmpresa`** de las empresas activas.
> No reutiliza la consulta de `/empresas/listar` a propósito: si mañana alguien
> agrega una columna allá, no queremos que aparezca sola en una URL abierta a
> internet. RUC, correo, teléfono y dirección siguen detrás del token.

Elegir empresa es **obligatorio**: sin ella el botón de ingresar queda
deshabilitado. La empresa queda disponible en toda la app:

```tsx
import { useEmpresa } from "@/components/ctell/empresa-provider";

const { empresa } = useEmpresa(); // { id, nombreEmpresa, tieneLogo } | null
```

**Ciclo de vida:** vive en `localStorage` para que el login la deje
preseleccionada la próxima vez, pero **se borra al cerrar sesión y ante un
401**. Elegir empresa es parte de iniciar sesión, así que no sobrevive a
cerrarla — si no, el siguiente que entre en esa PC arrancaría conectado a la
empresa del anterior.

Dos detalles que hay que respetar en cada página por empresa:

```tsx
const { data } = useQuery({
  // El id va en la queryKey: al cambiar de empresa, TanStack Query trata el
  // listado como otra consulta en vez de mostrar en caché el de la anterior.
  queryKey: ["monedas", empresa?.id ?? null],
  queryFn: () => api.monedas.listar({ idEmpresa: empresa!.id }),
  // El provider hidrata desde localStorage DESPUÉS de montar: sin esto, la
  // primera petición saldría sin idEmpresa y traería las de todas las empresas.
  enabled: empresa !== null,
});
```

### Sucursal activa

Algunas tablas cuelgan de la empresa **y** de la sucursal (`UBICACIONES` es la
primera). La sucursal tiene su propio provider global:

```tsx
import { useSucursal } from "@/components/ctell/sucursal-provider";

const { sucursal, sucursales, cargando, setSucursal } = useSucursal();
// { id, idEmpresa, nombreSucursal } | null
```

A diferencia de la empresa, **no se elige en el login sino en el home**, y se
elige sola cuando no hay ambigüedad: con una sola sucursal queda esa, con varias
se toma la primera hasta que el usuario cambie. Un desplegable de una sola opción
sugiere que hay algo que decidir cuando no lo hay, así que ahí se muestra un
rótulo.

En una página por empresa y sucursal van **las dos** en la `queryKey` y en el
`enabled`:

```tsx
queryKey: ["ubicaciones", empresa?.id ?? null, sucursal?.id ?? null],
enabled: empresa !== null && sucursal !== null,
```

Y hay un estado que no existe con la empresa: **la empresa puede no tener ninguna
sucursal activa**, y ahí `sucursal` queda en null para siempre. Hay que
distinguirlo de "todavía cargando" (`!cargando && sucursal === null`) o el usuario
ve una tabla vacía que parece un depósito sin cargar.

> **Cambiar de empresa invalida la sucursal.** Se guarda junto a su `idEmpresa` y
> se descarta si no coincide con la empresa activa, o si la sucursal fue borrada o
> inactivada. Se limpia en el logout y ante un 401, igual que la empresa.

### Permisos y menú

`USUARIO_PAGINAS` define qué páginas ve cada usuario **en cada empresa**: el
menú solo muestra las páginas cuyo permiso corresponde a la empresa activa. Sin
permisos en esa empresa, el menú queda vacío, y eso es lo esperado.

**La PK es `(ID_EMPRESA, ID_USUARIO, ID_PAGINA)`.** Los permisos son por empresa
de verdad: el mismo usuario puede ser vendedor en la empresa A y sólo consultar
en la B. La contrapartida es que hay que asignarle las páginas **en cada
empresa**, entrando con esa empresa.

> **Las tres claves viajan en todas las operaciones**, y es el error más fácil
> de cometer acá: `quitar` filtrando sólo por `(idUsuario, idPagina)` borraría
> el permiso **en todas las empresas**, no sólo en la que se está editando. Por
> eso la ruta es `DELETE /usuario-paginas/quitar/:idUsuario/:idPagina/:idEmpresa`.

El ABM de permisos (Configuración → Permisos, sólo administradores) trae dos
atajos para no tildar de a una:

- **Checkbox por módulo**: marca o desmarca todas sus páginas de una vez, con
  estado intermedio cuando hay algunas. Sólo pide las que cambian.
- **Copiar permisos**: replica los accesos de un usuario a otro dentro de la
  empresa activa. **Agrega, no reemplaza** — nadie pierde accesos por un clic.
  El desplegable de destino excluye a quienes ya tienen todo.

#### Una página nueva no aparece sola: dos pasos

Crear `src/routes/_auth.<tabla>.tsx` **no la hace visible**. Hacen falta:

1. **Administración → Páginas**: módulo, nombre, la ruta del desplegable y la
   entrada (`D` definiciones, `O` operaciones, `R` reportes).
2. **Administración → Permisos**: asignarla al usuario **y a la empresa**. Sin la
   empresa el permiso no se ve en ningún menú, como dice el punto anterior.

> **La ruta aparece sola en el desplegable.** Las opciones se derivan del
> `routeTree` que genera el build ([rutas-app.ts](src/lib/rutas-app.ts)), así que
> alcanza con crear el archivo. Antes era una lista escrita a mano que había que
> actualizar en cada tabla nueva, y olvidarla dejaba la página sin ruta válida:
> el ítem aparecía en el menú y no navegaba.

> El nombre de la página también conviene sumarlo a `ICONOS_PAGINA` en
> [menu-iconos.ts](src/components/ctell/menu-iconos.ts), o el ítem sale con el
> ícono genérico.
>
> Y en la página, `<AppLayout active="/la-ruta" title="Nombre">` lleva **la ruta**
> en `active` — con el nombre, el ítem del menú no queda resaltado.

### El estado es `'A'`/`'I'`

Las columnas `ACTIVO` son `VARCHAR2(1)` con `'A'` (activo) o `'I'` (inactivo).
**Ese mismo código viaja en el JSON y lo consume el frontend** —
`Estado = "A" | "I"` en [src/lib/api.ts](src/lib/api.ts) — sin traducirse a
1/0 en ningún punto.

Hubo una versión que sí traducía, y cada conversión de ida y vuelta era una
oportunidad de `ORA-01722`: un `TO_NUMBER` sobre un valor de texto mataba el
listado entero con un 500 sin mensaje. La traducción no aportaba nada.

Para preguntar si algo está activo, usá el helper `esActivo(x.activo)` en vez
de comparar contra el literal.

Esto vale para **todas** las tablas, sin excepciones. `TOKENS.ACTIVO` era
`NUMBER(1,0)` con 1/0 y se unificó: hoy es `VARCHAR2(1)` con `'A'` (vigente) e
`'I'` (revocado), igual que el resto. Tener dos columnas con el mismo nombre y
distinto tipo obligaba a recordar cuál era cuál en cada comparación, y
equivocarse costaba un `ORA-01722`.

> El cambio se aplicó a mano sobre el DDL, vaciando `TOKENS` en el proceso.
> Cuando agregues una tabla con estado, usá `VARCHAR2(1)` con `'A'`/`'I'`.

### Reejecutar un archivo de `db/`

**Frená `npm run dev` antes.** El servidor de desarrollo le pega a ORDS y esa
sesión mantiene tomadas las filas de metadatos que `DELETE_MODULE` necesita:
con el dev levantado, la reejecución muere con `ORA-00060` y el módulo viejo
queda publicado.

Y tenelo presente: **el código corregido en el repo no cambia nada por sí
solo.** ORDS solo conoce lo que se ejecutó en la hoja SQL de APEX. Si el script
falló a mitad, el endpoint viejo sigue sirviendo por más que el archivo esté
bien — revisá siempre el resultado de cada paso.

## Temas y colores

El sistema de diseño está anclado al azul del logo
(`#1362c0` → `oklch(0.506 0.164 256.5)`). Todas las variables viven en
[src/styles.css](src/styles.css) y **deben** usar formato oklch.

El usuario puede elegir en Configuración:

- **Modo**: claro, oscuro o seguir el sistema.
- **Acento**: 10 paletas definidas en
  [src/components/ctell/color-themes.ts](src/components/ctell/color-themes.ts).

Ambas preferencias se guardan en `localStorage` y se aplican antes del primer
render mediante un script inline en `<head>`, para evitar el parpadeo.

> Los colores semánticos (`--success`, `--warning`, `--destructive`) son fijos a
> propósito: si cambiaran con el acento, un tema rojo haría que los errores
> dejaran de leerse como errores.

## Despliegue

Automático a **GitHub Pages** en cada push a `main`, sobre el dominio propio:
<https://www.ctell.online>

### Configuración inicial (una sola vez)

1. Repo → _Settings_ → _Pages_ → en **Source** elegí **GitHub Actions**.
2. En esa misma pantalla, **Custom domain** = `www.ctell.online`.
3. Una vez que GitHub emita el certificado (puede tardar hasta 24 h), tildá
   **Enforce HTTPS**.
4. En el DNS de Hostinger, ver [Dominio](#dominio) más abajo.

No hacen falta secrets ni tokens: el workflow publica con el `GITHUB_TOKEN` que
Actions provee solo.

### Dominio

El dominio se declara en [public/CNAME](public/CNAME). Ese archivo **no es
decorativo**: cada deploy reemplaza el sitio entero, y si el CNAME no viaja
dentro del artefacto, Pages pierde el dominio y vuelve a la URL de
`github.io`. Por eso el workflow corta el deploy si el archivo no está.

En el panel DNS de Hostinger:

| Tipo    | Nombre | Valor                      |
| ------- | ------ | -------------------------- |
| `CNAME` | `www`  | `josegalvez1985.github.io` |
| `A`     | `@`    | `185.199.108.153`          |
| `A`     | `@`    | `185.199.109.153`          |
| `A`     | `@`    | `185.199.110.153`          |
| `A`     | `@`    | `185.199.111.153`          |

Los cuatro registros `A` son los que hacen que `ctell.online` sin `www`
redirija al dominio con `www`. Hay que borrar los registros `A` que Hostinger
crea solos apuntando a su propio hosting, o el dominio seguiría resolviendo ahí.

### Cómo funciona

Pages sirve **archivos estáticos**: no puede ejecutar un servidor. Por eso el
build es una SPA y no usa SSR.

- `spa: { enabled: true }` en [vite.config.ts](vite.config.ts) genera
  `dist/client/_shell.html` en vez de un servidor nitro.
- El workflow copia ese shell a `index.html` y a **`404.html`**. Ese 404 es lo
  que hace funcionar el ruteo: Pages lo devuelve ante cualquier URL que no sea
  un archivo, y el router del cliente resuelve la ruta.
- `.nojekyll` evita que Pages ignore los archivos que empiezan con `_`.

Con el dominio propio el sitio vive en la **raíz**, así que `base` es `/` fijo
en [vite.config.ts](vite.config.ts). Si alguna vez volviera a servirse desde un
subdirectorio, hay que cambiar `base` **y** nada más: el router toma su
`basepath` de `import.meta.env.BASE_URL` ([src/router.tsx](src/router.tsx)) y
los assets de `public/` —que no pasan por el bundler— ya llevan ese prefijo a
mano.

> Perder el SSR no cuesta nada acá: el backend es ORDS y los datos van detrás
> de un token que en el servidor no existe, así que el SSR sólo aportaba el
> primer render.

### CORS contra ORDS

Por defecto ORDS **no manda `Access-Control-Allow-Origin`**, así que el
navegador bloquea cualquier llamada directa a `oracleapex.com` desde otro
origen. Este proyecto lo resuelve distinto en cada entorno:

| Entorno       | Cómo evita el bloqueo                                                                                                                                                                                                            |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `npm run dev` | Proxy de Vite: la app pide a la ruta relativa `/ords/ctell` (mismo origen que la página, sin chequeo de CORS) y Vite reenvía a APEX servidor contra servidor. Configurado en `server.proxy` de [vite.config.ts](vite.config.ts). |
| Producción    | CORS habilitado directo en ORDS: la app pega con URL absoluta a `https://oracleapex.com/ords/ctell`, y es ORDS quien manda `Access-Control-Allow-Origin` para `https://www.ctell.online`.                                        |

[src/lib/api.ts](src/lib/api.ts) elige entre las dos según
`import.meta.env.DEV`: relativa en dev, absoluta en producción.

> **`ORIGINS_ALLOWED` es POR MÓDULO, no a nivel de workspace.** La pantalla de
> APEX —_Administración del Workspace → RESTful Services → orígenes
> permitidos_— sugiere que es un ajuste global, y **no lo es**: habilitarlo en
> `auth` no lo propaga a `usuarios` ni a ningún módulo nuevo.
>
> Cada `db/<tabla>.sql` llama a `ORDS.SET_MODULE_ORIGINS_ALLOWED` dentro de su
> `PUBLICAR_ENDPOINTS`, como sentencia aparte del `DEFINE_MODULE` (pasarlo como
> parámetro de esa llamada falla con `PLS-00306`).
>
> Sin eso, ORDS rechaza la petición cross-origin **antes** de llegar al handler,
> con un "Service Unavailable" genérico que ni el `WHEN OTHERS` con `SQLERRM`
> captura — porque el PL/SQL nunca llega a ejecutarse. Costó varias vueltas
> diagnosticarlo la primera vez.

> **Un 500 se ve como un error de CORS.** Cuando un handler revienta, ORDS
> responde con una página de error que **no lleva** el header
> `Access-Control-Allow-Origin`, y el navegador reporta el bloqueo CORS
> ocultando la causa real. Si en la consola aparecen las dos cosas juntas —500 y
> "blocked by CORS policy"— el problema es el 500, no el CORS.
>
> Para ver el error de verdad hay que ejecutar el procedimiento a mano en APEX:
> el `WHEN OTHERS` manda el `SQLERRM` a `APEX_DEBUG`, que no se ve desde el
> navegador. Cada archivo de `db/` trae el bloque `DECLARE ... BEGIN` listo para
> eso en su encabezado.

> No hay proxy en producción. GitHub Pages sirve archivos estáticos sin
> servidor que reenvíe nada, así que la única forma de esquivar CORS ahí es
> que el propio ORDS lo habilite. Sin ese origen cargado en APEX, el navegador
> bloquea la respuesta igual que bloquearía cualquier otra llamada cross-origin.

> El proyecto usó antes un Worker de Cloudflare como proxy delante del
> dominio, pero requería que `ctell.online` estuviera administrado por
> Cloudflare (nameservers apuntados desde Hostinger) — una dependencia externa
> de más. Se reemplazó por CORS directo en ORDS, que no depende de terceros.

### Workflows

| Archivo                                                | Cuándo corre           | Qué hace                 |
| ------------------------------------------------------ | ---------------------- | ------------------------ |
| [ci.yml](.github/workflows/ci.yml)                     | push y PR a `main`     | typecheck + lint + build |
| [deploy-pages.yml](.github/workflows/deploy-pages.yml) | push a `main` o manual | build SPA + publica      |

También podés desplegar a mano desde la pestaña **Actions** →
_Deploy to GitHub Pages_ → _Run workflow_.

### Probar el build de Pages en local

```sh
npm run build
npx serve dist/client
```

## Convenciones

Antes de escribir código nuevo, leé la
[Guía de implementación](docs/GUIA-IMPLEMENTACION.md): explica cómo agregar una
tabla nueva de punta a punta — paquete PL/SQL, endpoints ORDS, cliente HTTP,
página y formulario — siguiendo los patrones del proyecto.

Las cuatro que más se olvidan:

**Los totales se derivan, no se guardan.** Ni `VENTAS_CABECERAS` ni
`FACTURAS_COMPRAS_CAB` tienen columnas de monto: total, IVA, cobrado y saldo
salen de sumar el detalle en cada consulta. Guardarlos permitiría que la cabecera
diga 500.000 mientras sus líneas suman 480.000.

**El precio incluye IVA.** Se desglosa (`gravado = neto / 1,1`, `iva = neto −
gravado`), nunca se suma. Sumarlo cobra el impuesto dos veces.
Ver [Columnas calculadas](docs/GUIA-IMPLEMENTACION.md#34-columnas-calculadas-lo-que-no-se-guarda).

**Todo monto pasa por `lib/moneda.ts`.** `<InputMoneda>` para cargar,
`numeroMoneda()` para parsear, `formatearMoneda()` para mostrar. Nunca
`Number(texto)`: `Number("34.200")` da **34,2** y guarda un importe mil veces
menor sin ningún error a la vista.
Ver [Montos](docs/GUIA-FRONTEND.md#721-montos-inputmoneda-y-libmonedats).

**Lo que una operación movió, su baja lo revierte — o se rechaza con 409.**
Comprar crea lotes, vender los descuenta, borrar repone. Una venta con cobros o
una compra ya vendida no se borran.
Ver [Transacciones que mueven stock o plata](docs/GUIA-IMPLEMENTACION.md#36-transacciones-que-mueven-stock-o-plata).

### Tres errores de PL/SQL que ya se cometieron

`PLS-00231` (helper privado del body usado dentro de un `INSERT`/`UPDATE`),
`PLS-00684` (`RETURNING CLOB` en una asignación suelta) y `ORA-00932` (una
función aplicada a una columna `LONG`). Salen del estilo normal del código de
acá, así que conviene reconocerlos:
[Trampas de PL/SQL](docs/GUIA-IMPLEMENTACION.md#37-trampas-de-plsql-que-se-repiten).

### Después de tocar `db/`

Correr [db/verificar.sql](db/verificar.sql) entero en APEX. No modifica nada:
chequea que los paquetes estén `VALID`, que existan las columnas que el código da
por hechas, que los módulos ORDS tengan CORS, y ocho controles de datos donde
**cero filas es lo correcto** (lotes en negativo, desgloses de IVA que no cuadran,
ventas cobradas de más, cuotas cuyo pagado no coincide con sus movimientos).
