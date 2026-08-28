# CLAUDE.md — Ctell Admin Hub

## Resumen del proyecto

**Ctell Admin Hub** es un sistema administrativo web y PWA para CTELL que gestiona compras, ventas, stock, tesorería y recursos humanos, con login de usuarios. Frontend en React + TanStack; backend en Oracle APEX con ORDS (PL/SQL).

### Stack técnico

| Capa        | Tecnología                               |
| ----------- | ---------------------------------------- |
| Frontend    | TanStack Start (React 19 + SSR disabled) |
| Ruteo       | TanStack Router (file-based routing)     |
| Datos       | TanStack Query                           |
| Estilos     | Tailwind CSS v4 + shadcn/ui              |
| Formularios | react-hook-form + zod                    |
| Build       | Vite 8 (SPA estática)                    |
| Backend     | Oracle APEX + ORDS (REST sobre PL/SQL)   |
| Hosting     | GitHub Pages → www.ctell.online          |

## Estructura del proyecto

```
ctell-admin-hub/
├── db/                        Backend: PL/SQL + ORDS
│   ├── auth.sql              PKG_AUTH: autenticación y sesiones
│   ├── usuarios.sql          PKG_USUARIOS: ABM de usuarios
│   ├── ventas.sql            PKG_VENTAS: punto de venta (cabecera+detalle+cuotas)
│   ├── ventas-cobros.sql     PKG_VENTAS_COBROS: cobros contra ventas
│   ├── facturas-compras.sql  PKG_FACTURAS_COMPRAS: compras (crea lotes)
│   ├── facturas-compras-pagos.sql  PKG_FACTURAS_COMPRAS_PAGOS: pagos a proveedores
│   ├── dashboard.sql         PKG_DASHBOARD: los indicadores de la home
│   ├── verificar.sql         Sólo lectura: chequea que el backend quedó consistente
│   └── [table].sql           Cada tabla nueva va aquí
├── src/
│   ├── routes/               Rutas por archivo (TanStack Router)
│   │   ├── __root.tsx        Layout raíz: <html>, providers, meta
│   │   ├── index.tsx         "/" → login
│   │   ├── _auth.tsx         Layout autenticado (requiere token)
│   │   ├── _auth.home.tsx    "/home" → dashboard
│   │   └── _auth.configuracion.tsx "/configuracion" → preferencias
│   ├── components/
│   │   ├── ctell/            Componentes propios del proyecto
│   │   │   ├── AppLayout.tsx
│   │   │   ├── AccesosRapidos.tsx   Botonera de la home, ordenada por uso
│   │   │   ├── InputMoneda.tsx      Campo de monto con separador en vivo
│   │   │   ├── UsuariosDialog.tsx
│   │   │   ├── ThemeToggle.tsx
│   │   │   ├── Logo.tsx
│   │   │   └── theme-provider.tsx
│   │   └── ui/               shadcn/ui componentes (no editar manualmente)
│   ├── hooks/
│   │   ├── use-usuario-actual.ts   Hook para auth del usuario logueado
│   │   └── use-cerrar-sesion-al-vencer.ts
│   ├── lib/
│   │   ├── api.ts            Cliente HTTP contra ORDS
│   │   ├── moneda.ts         Formato y parseo es-PY, en un solo lugar
│   │   ├── exportar.ts       Excel y PDF de un listado, con las mismas columnas
│   │   └── uso-paginas.ts    Conteo de uso por página (localStorage)
│   ├── router.tsx            Configuración del router
│   └── styles.css            Design system: variables de color en oklch
├── docs/
│   └── GUIA-IMPLEMENTACION.md Cómo agregar una tabla nueva de punta a punta
└── public/
    └── CNAME                 www.ctell.online (crítico para el deploy)
```

## Backend: Paquetes PL/SQL en `db/`

**Regla fundamental:** cada tabla tiene su propio archivo `.sql` en `db/`, nombrado como la tabla, con todo su CRUD adentro.

### Convención de archivos

- **`auth.sql` es la excepción:** gestiona autenticación y sesiones con el paquete **`PKG_AUTH`** (toca `USUARIOS` y `TOKENS`), no es una tabla. Debe ejecutarse **primero** — `PKG_USUARIOS` llama a `PKG_AUTH` para hashear contraseñas y revocar sesiones.
- **`PKG_TOKENS`** fue eliminado — era un duplicado innecesario sin implementación. Toda la lógica de tokens está en `PKG_AUTH`.
- Cada archivo se ejecuta **de una sola vez y por separado** en APEX — modificar empresas no obliga a reejecutar usuarios.
- Los archivos son **idiopotentes** (pueden reejecutarse sin error) y **no crean tablas**: el DDL se administra aparte.

### Endpoints publicados

#### Autenticación — `/auth`

| Método | Ruta                     | Auth  | Devuelve                                                   |
| ------ | ------------------------ | ----- | ---------------------------------------------------------- |
| `POST` | `/auth/login`            | —     | `{ token, expira, usuario }`                               |
| `POST` | `/auth/logout`           | token | `{ ok: true }`                                             |
| `GET`  | `/auth/me`               | token | `{ id, usuario, nombreApellido, correo, activo, esAdmin }` |
| `POST` | `/auth/recuperar`        | —     | mensaje neutro (siempre 200) + clave provisoria por mail   |
| `POST` | `/auth/cambiar-password` | token | `{ ok: true }` + revoca **todas** las sesiones             |

**Detalles de seguridad:**

- Token en header: `Authorization: Bearer <token>` (case-insensitive per RFC).
- Token vence a las 8 horas.
- `/auth/login` devuelve **401 con un único mensaje** —"Usuario o contraseña incorrectos"— sin distinguir si el usuario no existe, la clave está mal o la cuenta está inactiva. Esto evita enumerar cuentas válidas.
- Validar token comprueba: vigencia, vencimiento, **y que la cuenta siga activa**. Inactivar un usuario corta acceso al instante.

#### ABM de usuarios — `/usuarios`

Todos requieren token autenticado.

| Método   | Ruta                      | Qué hace                          |
| -------- | ------------------------- | --------------------------------- |
| `GET`    | `/usuarios/`              | Listado paginado                  |
| `POST`   | `/usuarios/`              | Alta → 201                        |
| `GET`    | `/usuarios/:id`           | Detalle                           |
| `PUT`    | `/usuarios/:id`           | Modificación                      |
| `DELETE` | `/usuarios/:id`           | Baja física                       |
| `POST`   | `/usuarios/:id/inactivar` | Baja lógica + revoca sesiones     |
| `POST`   | `/usuarios/:id/activar`   | Alta lógica                       |
| `POST`   | `/usuarios/:id/password`  | Cambio de clave + revoca sesiones |

**Parámetros del listado:**

- `?busqueda=` — filtro por nombre/usuario
- `?activo=A|I` — activos o inactivos
- `?pagina=` — número de página
- `?tamanio=` — cantidad por página (25 por defecto, **200 como techo máximo**)

**Decisiones importantes:**

- **`USUARIO` no se modifica.** Es la identidad de login; para cambiarlo hay que crear uno nuevo.
- **Nadie puede eliminarse ni inactivarse a sí mismo** (400) — evita perder acceso a mitad de la operación.
- **Cambiar contraseña revoca todas las sesiones**, incluida la propia. Es lo esperado si se cambia por sospecha de robo.

### Correo (APEX_MAIL)

El alta de usuarios y `/auth/recuperar` mandan la contraseña por mail vía
`PKG_AUTH.ENVIAR_PASSWORD_INICIAL`.

- **Fijar el workspace antes de `SEND`.** Un handler de ORDS no corre dentro de
  ninguno: llamar a `PKG_AUTH.ESTABLECER_WORKSPACE_MAIL` primero, que usa
  `APEX_UTIL.SET_SECURITY_GROUP_ID` resolviendo el id por nombre. Sin eso,
  `ORA-20987`.
- **Nunca `APEX_SESSION.CREATE_SESSION`:** exige una aplicación APEX y este
  workspace no tiene ninguna (el frontend es React). Un `p_app_id` inventado fue
  la causa de que ningún correo se enviara nunca.
- **Un fallo de correo no deshace la operación:** avisa por `p_enviado`
  (`'A'`/`'I'`), y el alta devuelve `passwordInicial` sólo si el envío falló.
- **Diagnóstico:** `SELECT PKG_AUTH.PROBAR_CORREO('x@y.com') FROM DUAL;` —
  devuelve el error en texto en vez de tragárselo como los envíos de producción.

#### Punto de venta y cobros — `/ventas`, `/ventas-cobros`

| Método   | Ruta                                     | Qué hace                              |
| -------- | ---------------------------------------- | ------------------------------------- |
| `GET`    | `/ventas/listar`                         | Listado con totales y saldo derivados |
| `GET`    | `/ventas/obtener/:id/:idEmpresa`         | Cabecera, detalle con lote, cuotas    |
| `POST`   | `/ventas/crear`                          | Venta completa en una transacción     |
| `DELETE` | `/ventas/eliminar/:id/:idEmpresa`        | Borra y **repone el stock**           |
| `GET`    | `/ventas-cobros/listar/:idVenta/:idEmp`  | Historial de cobros                   |
| `POST`   | `/ventas-cobros/crear`                   | Cobro, validado contra el saldo       |
| `DELETE` | `/ventas-cobros/eliminar/:id/:idEmpresa` | Borra y devuelve el saldo             |

#### Compras y pagos — `/facturas-compras`, `/compras-pagos`

Misma forma que ventas, en espejo. `/compras-pagos` es idéntico a `/ventas-cobros` con la plata saliendo.

#### Dashboard — `/dashboard/resumen?idEmpresa=&idSucursal=`

Los indicadores de la home en una consulta: montos del mes con su mes anterior, valor de stock, artículos bajo mínimo, últimos movimientos (ventas + compras + inventarios unidos), stock crítico y cuotas de compra por vencer.

Un endpoint propio y no sumar en el frontend porque los listados están paginados: sumarlos en el cliente daría el total de la página, no del mes.

### Los totales no se guardan: se calculan

`VENTAS_CABECERAS` y `FACTURAS_COMPRAS_CAB` **no tienen** columnas de monto. Total, descuento, gravado, IVA, cobrado/pagado y saldo se derivan sumando el detalle en cada consulta.

Guardarlos además permitiría que la cabecera diga 500.000 mientras sus líneas suman 480.000 — una inconsistencia que nadie detecta hasta que alguien cuadra la caja. Es el mismo criterio del stock de un artículo (`SUM` sobre sus lotes) y de la diferencia de un inventario: **si se puede derivar, se deriva.**

### Los precios incluyen IVA: el impuesto se desglosa, no se suma

Es como se factura en Paraguay. El precio que carga el cajero es el de la etiqueta: 11.000 la unidad, no 10.000 + IVA.

```
MONTO_GRAVADO = ROUND(neto / GRAVADA_DIVISION, 2)   (1,1 al 10%; 1,05 al 5%)
MONTO_IVA     = neto - MONTO_GRAVADO
```

donde `neto = cantidad * precio - descuento`. Con una línea de 110.000 al 10%: gravado 100.000, IVA 10.000, y el cliente paga **110.000**.

- **El IVA sale por resta**, no por su propia división: dos divisiones redondean por separado y su suma no tiene por qué dar el neto. Con una división y una resta, `gravado + iva = neto` siempre, exacto.
- **Nunca `neto * porcentaje / 100`** — eso cobraría impuesto sobre impuesto.
- Toda división va con `NULLIF(..., 0)`: la exenta tiene `IVA_DIVISION = 0`. Ojo que en `GRAVADA_DIVISION` la exenta va en **1**, no en 0 — los dos divisores usan criterios opuestos.
- **La columna virtual `TOTAL` no debe sumar `MONTO_IVA`.** El DDL original lo hacía y no se notaba porque `MONTO_IVA` se guardaba siempre en 0.

### El stock se mueve con las transacciones

- **Comprar hace entrar stock:** cada línea de una factura de compra crea **su propio lote**, con la cantidad y el precio unitario como costo. Uno por línea y no acumulado: cada compra entró a un precio distinto.
- **Vender lo saca:** cada línea de venta descuenta de **un solo lote**, el que elige el cajero. `VENTAS_DETALLES.ID_LOTE` guarda cuál — sin esa columna, borrar la venta no sabría dónde reponer.
- **Borrar revierte:** eliminar una venta devuelve las unidades a su lote; eliminar una compra saca del stock lo que trajo.
- **Se bloquea lo que no se puede revertir** (409): una venta con cobros, una factura con pagos, y una factura cuya mercadería ya se vendió (`CANTIDAD_DISPON < CANTIDAD`).

`FACTURAS_COMPRAS_DET.ID_LOTE` es el espejo de `VENTAS_DETALLES.ID_LOTE`, en el otro sentido.

### Estado: `'A'` (activo) / `'I'` (inactivo)

Las columnas `ACTIVO` son `VARCHAR2(1)` con valores `'A'` o `'I'`. **Este código viaja en el JSON sin traducción**. No hacía falta traducir a 1/0 (generaba `ORA-01722` en conversiones fallidas) y la presente unificación vale para **todas** las tablas.

- Helper para comparar: `esActivo(x.activo)` en lugar de literales.
- Nota histórica: `TOKENS.ACTIVO` era `NUMBER(1,0)` con 1/0; se unificó a `VARCHAR2(1)` con `'A'`/`'I'`.

### Reejecutar un archivo `db/`

1. **Frená `npm run dev`** antes — la sesión dev mantiene tomadas filas de metadatos que `DELETE_MODULE` necesita. Sin frenarla: `ORA-00060` y el endpoint viejo sigue publicado.
2. El código corregido en el repo **no cambia nada por sí solo** — ORDS solo conoce lo ejecutado en APEX. Revisa siempre el resultado de cada paso.

## Frontend: Rutas y componentes

### Rutas (TanStack Router — `src/routes/`)

- **`__root.tsx`:** Layout raíz con `<html>`, providers globales, meta global.
- **`index.tsx`:** "/" → Login (público).
- **`_auth.tsx`:** Layout protegido (requiere token). Las rutas bajo `_auth` heredan este layout.
- **`_auth.home.tsx`:** "/home" → Dashboard. Los KPIs, movimientos y stock crítico salen de `/dashboard/resumen`; arriba va `<AccesosRapidos />`.
- **`_auth.punto-venta.tsx`:** "/punto-venta" → Caja. Carrito con IVA y lote por línea; al guardar abre el modal de cobro.
- **`_auth.ventas.tsx`:** "/ventas" → Comprobantes emitidos: ver detalle y eliminar. **No** se editan.
- **`_auth.cobros.tsx`:** "/cobros" → Cobros de ventas, historial y baja.
- **`_auth.pagos.tsx`:** "/pagos" → Pagos a proveedores. Espejo de cobros.
- **`_auth.existencias.tsx`:** "/existencias" → Consulta de existencia de artículos, con exportación a Excel y PDF. Es una CONSULTA: no da de alta ni edita nada.
- **`_auth.configuracion.tsx`:** "/configuracion" → Preferencias (tema, acento).

> Las páginas nuevas hay que **darlas de alta en administración** con su ruta: `PAGINAS` es data, no hay seed en SQL. El ícono se resuelve por nombre normalizado contra `menu-iconos.ts`.
>
> `PAGINAS` tiene `UNIQUE (ID_MODULO, RUTA, ENTRADA)`: la misma ruta **sí** puede estar en dos módulos —dos entradas al mismo destino para dos perfiles—, lo que no se puede es repetirla en el mismo módulo y sección. El backend normaliza la ruta antes de guardar (minúsculas, barra inicial, sin barra final) porque si no el `UNIQUE` compara strings y no aplica; el choque sale como 409, y el alta lo avisa mientras se completa el formulario.

### Montos: siempre `InputMoneda` y `lib/moneda.ts`

Todo campo de dinero usa `<InputMoneda>`, que **separa los miles mientras se escribe** y preserva la posición del cursor. Para parsear lo que devuelve, `numeroMoneda()`; para mostrar un número, `formatearMoneda()`.

Nunca `Number(texto)` sobre un monto: `Number("34.200")` da **34,2** y guarda un importe mil veces menor sin ningún error a la vista. Fue exactamente el bug que había en compras, inventarios, lotes y cuentas bancarias.

Al precargar un campo desde un número va `formatearMoneda(n)`, no `String(n)`: `String(34200.5)` da `"34200.5"` con punto decimal de JS, que el componente leería como separador de miles.

### Exportar un listado: `lib/exportar.ts`

Un listado que se baja a Excel y a PDF declara sus columnas **una sola vez**
(`ColumnaExport<T>`) y de ahí salen los dos archivos. Declararlas por separado
garantiza que tarde o temprano el Excel tenga una columna que el PDF no.

- **`descargarExcel`** hace un `.xlsx` de verdad, no un CSV renombrado: las
  cantidades entran como número y se pueden sumar en la planilla.
- **`abrirPdf`** abre el PDF en una pestaña nueva. **La pestaña se abre en la
  primera línea, antes de cualquier `await`**: los bloqueadores de ventanas
  emergentes sólo dejan pasar el `window.open` que ocurre dentro del click, así
  que el handler que la llama tampoco puede ser `async`. Si igual la bloquean,
  el archivo se descarga.
- **El guaraní (`₲`) no existe en las fuentes de fábrica de jsPDF** y sale como
  un cuadrito: en un PDF, poné "Gs." en el título de la columna y mandá el
  número pelado.
- Las dos librerías entran con `import()` dinámico y quedan en su propio chunk:
  no las paga quien nunca exporta.

La primera pantalla que lo usa es `/existencias`, que además trae el catálogo
entero paginando de a 200 en vez de ofrecer "Mostrar más" — en una consulta que
se exporta, **lo que sale en el archivo tiene que ser exactamente lo que se ve**.

### Canal de pago: `IND_BANCO`, no el nombre

`requiereCuentaBancaria(canal)` lee `CANALES_PAGOS.IND_BANCO` (`'S'`/`'N'`) para saber si al cobrar hay que pedir la cuenta receptora. Antes era un `idCanalPago !== "1"` escrito a mano, y después una heurística sobre el nombre; las dos se rompían solas. Un canal sin el indicador cargado se trata como efectivo.

### Temas y colores (`src/styles.css` + `src/components/ctell/color-themes.ts`)

El sistema anclado al azul del logo (`#1362c0` → `oklch(0.506 0.164 256.5)`).

**Preferencias del usuario:**

- **Modo:** claro, oscuro o sistema.
- **Acento:** 10 paletas predefinidas.

Ambas se guardan en `localStorage` y se aplican antes del primer render (script inline en `<head>`) para evitar parpadeo.

**Nota:** Colores semánticos (`--success`, `--warning`, `--destructive`) son fijos a propósito — si cambiaran con el acento, un tema rojo haría que los errores no parecieran errores.

## Cliente HTTP: `src/lib/api.ts`

El cliente HTTP maneja:

- Rutas relativas en desarrollo (`/ords/ctell` → proxy Vite → ORDS).
- Rutas absolutas en producción (`https://oracleapex.com/ords/ctell/` → directo a ORDS, sin proxy).
- Token en `Authorization: Bearer <token>`.
- Gestión de errores y parseo de respuestas.

`BASE_URL` elige entre las dos según `import.meta.env.DEV` — ver `src/lib/api.ts`.

Detalle importante: **Content-Type se envía solo cuando es POST/PUT** y hay body. En GET no se envía (previene headers innecesarios).

## CORS

### Problema

Por defecto ORDS no manda `Access-Control-Allow-Origin`, así que el navegador bloquea llamadas directas a `oracleapex.com` desde otro origen.

### Solución

Cada entorno lo resuelve distinto:

| Entorno       | Cómo evita el bloqueo                                                                                      | Config                                        |
| ------------- | ---------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| `npm run dev` | Proxy de Vite: la app pide a la ruta relativa `/ords/ctell` (mismo origen, sin CORS) y Vite reenvía a APEX | `server.proxy` en `vite.config.ts`            |
| Producción    | CORS habilitado directo en ORDS: la app pega con URL absoluta a `oracleapex.com`                           | `ORDS.SET_MODULE_ORIGINS_ALLOWED` — ver abajo |

**GitHub Pages** no puede hacer de proxy (sirve archivos estáticos), así que en producción no hay intermediario: la única forma de esquivar CORS ahí es que el propio ORDS lo habilite.

**ORIGINS_ALLOWED es POR MÓDULO, no a nivel de workspace.** La pantalla de APEX se llama "Administración del Workspace → RESTful Services → orígenes permitidos", lo que sugiere un ajuste global — no lo es. Habilitarlo en `auth` no lo propaga a `usuarios` ni a ningún módulo nuevo. Cada `db/<tabla>.sql` tiene que llamar a `ORDS.SET_MODULE_ORIGINS_ALLOWED(p_module_name, p_origins_allowed)` aparte de su `DEFINE_MODULE` (no es un parámetro de esa llamada — pasarlo ahí falla con `PLS-00306`). Sin esto, ORDS rechaza la petición cross-origin _antes_ de llegar al handler, con un "Service Unavailable" genérico — ni el `WHEN OTHERS` con `SQLERRM` lo captura, porque el PL/SQL nunca llega a ejecutarse. Costó varias vueltas diagnosticarlo la primera vez que pasó.

> El proyecto usó antes un Worker de Cloudflare como proxy delante del dominio. Se reemplazó por CORS directo en ORDS porque requería que `ctell.online` estuviera administrado por Cloudflare (nameservers desde Hostinger) — una dependencia externa de más.

## Deploy: GitHub Pages → www.ctell.online

### Automático

Cada push a `main` triggerea el workflow `deploy-pages.yml`, que:

1. Build SPA en `dist/client/`.
2. Publica en GitHub Pages.
3. Dominio: `www.ctell.online` (vía `public/CNAME`).

### Manual

Pestaña **Actions** → _Deploy to GitHub Pages_ → _Run workflow_.

### Configuración inicial (una sola vez)

1. Repo → _Settings_ → _Pages_ → **Source** = GitHub Actions.
2. **Custom domain** = `www.ctell.online`.
3. Esperar certificado HTTPS (hasta 24h), tildar **Enforce HTTPS**.
4. DNS en Hostinger (ver sección siguiente).

### DNS — Hostinger

| Tipo    | Nombre | Valor                      |
| ------- | ------ | -------------------------- |
| `CNAME` | `www`  | `josegalvez1985.github.io` |
| `A`     | `@`    | `185.199.108.153`          |
| `A`     | `@`    | `185.199.109.153`          |
| `A`     | `@`    | `185.199.110.153`          |
| `A`     | `@`    | `185.199.111.153`          |

Los cuatro registros `A` hacen que `ctell.online` sin `www` redirija con `www`. Borra los registros `A` que Hostinger crea solos (apuntarían a su hosting).

### Cómo funciona

Pages sirve **archivos estáticos** → build es SPA (sin SSR). Detalles:

- `spa: { enabled: true }` en `vite.config.ts` → `dist/client/_shell.html` (no servidor nitro).
- Workflow copia shell a `index.html` y `404.html`. El 404 es lo que hace funcionar el ruteo: Pages lo devuelve ante URLs que no sean archivos, el router del cliente resuelve.
- `.nojekyll` previene que Pages ignore archivos que empiezan con `_`.

**SPA + GitHub Pages = sin SSR.** No cuesta nada aquí: backend es ORDS (datos detrás de token), SSR solo aportaba el primer render.

### Probar build en local

```sh
npm run build
npx serve dist/client
```

## Convenciones de código

### Para agregar una tabla nueva

Ver [docs/GUIA-IMPLEMENTACION.md](docs/GUIA-IMPLEMENTACION.md) — explica cómo hacerlo de punta a punta:

1. Paquete PL/SQL + endpoints ORDS (`db/[tabla].sql`).
2. Cliente HTTP (`src/lib/api.ts`).
3. Página y formulario (`src/routes/` + `src/components/`).

### Convenciones generales

- **Estados uniforme:** `'A'`/`'I'` en todas las tablas (no 1/0).
- **Comparar estado:** usar `esActivo(x.activo)` en lugar de literales.
- **Montos:** `<InputMoneda>` para cargar, `numeroMoneda()` para parsear, `formatearMoneda()` para mostrar. Nunca `Number()` sobre un monto.
- **Totales:** derivarlos del detalle, no guardarlos en la cabecera.
- **Toda baja que movió stock o plata tiene que revertirlo**, o rechazarse con 409 si no puede.
- **Los helpers privados del _body_ de un paquete no se pueden llamar desde SQL** (`PLS-00231`): calcular en una variable PL/SQL y usar la variable en el `INSERT`/`UPDATE`. Este error se cometió dos veces — si vas a llamar un helper dentro de una sentencia SQL, mirá primero dónde está declarado.
- **`RETURNING CLOB` no va en una asignación PL/SQL suelta** (`PLS-00684`): usar `SELECT ... INTO x FROM DUAL`.
- **Un `UNIQUE` sobre texto necesita el texto normalizado**, o no aplica: para Oracle `/Ventas` y `/ventas` son distintos. Normalizar en una función privada antes de guardar, y traducir el `DUP_VAL_ON_INDEX` a un 409 que diga qué hacer.

Las tres están explicadas con ejemplos en [GUIA-IMPLEMENTACION.md](docs/GUIA-IMPLEMENTACION.md#37-trampas-de-plsql-que-se-repiten).

- **Hash de contraseñas:** `STANDARD_HASH` SHA-256 hoy (débil frente a fuerza bruta). Si conseguís `GRANT EXECUTE ON SYS.DBMS_CRYPTO`, migra a PBKDF2 (versión lista en comentario dentro de `HASH_PASSWORD`). Migrar invalida hashes existentes.

## Comandos

| Comando            | Qué hace                                   |
| ------------------ | ------------------------------------------ |
| `npm run dev`      | Servidor dev con HMR (proxy CORS incluido) |
| `npm run build`    | Build de producción en `dist/client/`      |
| `npm run preview`  | Sirve build ya generado                    |
| `npm run lint`     | ESLint + Prettier                          |
| `npm run format`   | Aplica formato a todo                      |
| `npx tsc --noEmit` | Type checking                              |

## Puntos clave para recordar

1. **`auth.sql` primero:** `PKG_USUARIOS` depende de `PKG_AUTH`.
2. **No hacen falta secrets:** workflow GitHub Actions usa `GITHUB_TOKEN` provisto.
3. **`public/CNAME` es crítico:** cada deploy reemplaza el sitio, si falta el archivo Pages pierde el dominio.
4. **SPA en Pages:** no hay servidor, todo se resuelve en el cliente.
5. **CORS por entorno:** proxy de Vite en dev, CORS directo en ORDS en producción (sin proxy ni Worker).
6. **Estado uniforme:** `'A'`/`'I'` en todas las tablas, sin traducción.
7. **Reejecutar `db/`:** frena dev primero (evita `ORA-00060`).
8. **Los totales se derivan**, no se guardan en la cabecera.
9. **El precio incluye IVA:** se desglosa, nunca se suma.
10. **Comprar crea lotes, vender los descuenta, borrar revierte** — o se rechaza con 409.
11. **`db/verificar.sql`** corre entero, no modifica nada y dice si el backend quedó consistente. Es lo primero después de ejecutar cambios en APEX.
