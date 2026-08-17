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
├── auth.sql             PKG_AUTH + módulo ORDS /auth/  (ejecutar PRIMERO)
├── usuarios.sql         ABM de usuarios
├── modulos.sql          Módulos del menú
├── paginas.sql          Páginas del menú
├── usuario-paginas.sql  Permisos: qué página ve cada usuario, por empresa
├── paises.sql           ─┐
├── departamentos.sql     │ Jerarquía geográfica
├── ciudades.sql         ─┘
├── empresas.sql         Empresas + logo (BLOB) + listado público del login
├── sucursales.sql       Sucursales de cada empresa
├── monedas.sql          ─┐
├── unidades-medida.sql   │ Definiciones POR EMPRESA
├── categorias.sql       ─┘
├── detalle-monedas.sql  Denominaciones de cada moneda + foto (BLOB)
└── articulos.sql        Artículos + imagen (BLOB)

src/
├── routes/              Rutas (el archivo define la URL)
│   ├── __root.tsx       Layout raíz: <html>, providers, meta global
│   ├── index.tsx        "/" → login (elegir empresa + credenciales)
│   ├── _auth.tsx        Layout protegido (requiere token)
│   ├── _auth.home.tsx           "/home"          → panel general
│   ├── _auth.configuracion.tsx  "/configuracion" → preferencias
│   └── _auth.<tabla>.tsx        una por cada ABM
├── components/
│   ├── ctell/           Componentes propios del proyecto
│   │   ├── empresa-provider.tsx  Empresa activa de la sesión
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
│   └── api.ts           Cliente HTTP contra ORDS
└── styles.css           Design system (variables de color en oklch)
```

## Backend

> **Regla: cada tabla tiene su propio archivo en `db/`, nombrado como la tabla,
> con todo su CRUD adentro.**

Cada archivo define `PKG_<TABLA>` con sus 4 procedimientos —`LISTAR`,
`INSERTAR`, `ACTUALIZAR`, `ELIMINAR`— y publica su módulo ORDS. Los endpoints
siguen siempre la misma forma:

| Método   | Ruta                      |
| -------- | ------------------------- |
| `GET`    | `/<tabla>/listar`         |
| `POST`   | `/<tabla>/crear`          |
| `PUT`    | `/<tabla>/actualizar/:id` |
| `DELETE` | `/<tabla>/eliminar/:id`   |

`auth.sql` es la única excepción a la regla: no corresponde a una tabla sino a
una responsabilidad —verificar credenciales y manejar sesiones— que cruza
`USUARIOS` y `TOKENS`. El ABM de usuarios va aparte, en `usuarios.sql`.

### Tablas por empresa

`MONEDAS`, `UNIDADES_MEDIDA`, `CATEGORIAS` y `ARTICULOS` **cuelgan de
`EMPRESAS`**: cada empresa tiene su propio juego. El `idEmpresa` no sale de un
combobox del formulario sino de la **empresa activa de la sesión**, que se elige
al iniciar sesión (ver [Empresa activa](#empresa-activa)).

Consecuencia en el listado: **no hacen JOIN contra `EMPRESAS`**. Como ya vienen
filtradas por una sola empresa, su nombre sería la misma constante repetida en
cada fila, y el frontend ya lo tiene.

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

**El orden importa: `auth.sql` primero.** `PKG_USUARIOS` llama a `PKG_AUTH`
para hashear contraseñas y revocar sesiones, y además reutiliza el
procedimiento `BORRAR_MODULO_ORDS` que ese archivo define. Al revés no
compila.

Cada archivo se ejecuta **de una sola vez y por separado** en la hoja de trabajo
SQL de APEX, y contiene el paquete PL/SQL, el módulo ORDS con sus endpoints y
las consultas de verificación. Tocar empresas no obliga a reejecutar usuarios.

Los archivos son **idempotentes** (se pueden reejecutar) y **no crean ni alteran
tablas**: el DDL se administra aparte.

### Endpoints publicados

| Método | Ruta                      | Auth  | Devuelve                                                         |
| ------ | ------------------------- | ----- | ---------------------------------------------------------------- |
| `POST` | `/auth/login`             | —     | `token`, `expira`, `usuario`                                     |
| `POST` | `/auth/logout`            | token | `{ ok: true }`                                                   |
| `GET`  | `/auth/me`                | token | `id`, `usuario`, `nombreApellido`, `correo`, `activo`, `esAdmin` |
| `POST` | `/auth/recuperar`         | —     | mensaje neutro (siempre 200) + clave provisoria por mail         |
| `POST` | `/auth/cambiar-password`  | token | `{ ok: true }` + revoca **todas** las sesiones                   |

El token se envía como `Authorization: Bearer <token>` y vence a las 8 horas.
El header se parsea con `PKG_AUTH.TOKEN_DE_HEADER`, que acepta el prefijo en
cualquier capitalización (`Bearer`/`bearer`), como pide la RFC.

`/auth/login` responde **401 con un único mensaje** —"Usuario o contrasena
incorrectos"— tanto si el usuario no existe, como si la clave está mal o la
cuenta está inactiva. Distinguir los casos permitiría enumerar cuentas válidas.

Validar un token comprueba tres cosas, no una: que el token esté vigente, que
no haya vencido, y que **la cuenta siga activa**. Por eso inactivar un usuario
le corta el acceso al instante, aunque su token todavía no hubiera expirado.

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

### Permisos y menú

`USUARIO_PAGINAS` define qué páginas ve cada usuario, y desde esta versión
**también en qué empresa**: el menú solo muestra las páginas cuyo permiso
corresponde a la empresa activa. Sin permisos en esa empresa, el menú queda
vacío.

Dos límites que vienen del DDL y conviene tener presentes:

- **`ID_EMPRESA` no está en la PK**, que sigue siendo `(ID_USUARIO, ID_PAGINA)`.
  Por eso una página se asigna a **una sola empresa por usuario**: dársela en
  dos da 409. Para levantar ese límite hay que llevar la PK a
  `(ID_USUARIO, ID_PAGINA, ID_EMPRESA)`.
- **La columna es nullable**, y los permisos cargados antes de que existiera
  **no aparecen en ningún menú**. Hay que reasignarlos desde el ABM de permisos.
  `db/usuario-paginas.sql` trae al final una consulta que los lista y, comentado,
  el `UPDATE` para migrarlos de una si el sistema venía usándose con una sola
  empresa.

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
