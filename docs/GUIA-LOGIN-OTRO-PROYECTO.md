# Guía: implementar el login de CTELL en otro proyecto

> **Para quién es esto:** para la IA/desarrollador que trabaja en el **proyecto nuevo**.
> El proyecto nuevo se conecta a **la misma base Oracle APEX** que Ctell Admin Hub,
> así que **usa los mismos usuarios, las mismas contraseñas y los mismos tokens**.
>
> **Regla número uno: NO se toca el backend de autenticación.** El paquete
> `PKG_AUTH` y el módulo ORDS `/auth/` ya existen, ya están publicados y ya
> funcionan. Reescribirlos, "mejorarlos" o volver a ejecutarlos desde el proyecto
> nuevo puede romper el login del sistema que ya está en producción.
>
> Lo único que hay que hacer en la base es **agregar el origen (dominio) del
> proyecto nuevo a la lista de CORS** — una única llamada, explicada en la Parte 1.

---

## Índice

- [Parte 0 — Cómo funciona la autenticación](#parte-0--cómo-funciona-la-autenticación)
- [Parte 1 — Backend: lo único que hay que ejecutar](#parte-1--backend-lo-único-que-hay-que-ejecutar)
- [Parte 2 — Referencia completa de endpoints](#parte-2--referencia-completa-de-endpoints)
- [Parte 3 — Configuración del proyecto (Vite / proxy / CORS)](#parte-3--configuración-del-proyecto-vite--proxy--cors)
- [Parte 4 — Cliente HTTP `src/lib/api.ts`](#parte-4--cliente-http-srclibapits)
- [Parte 5 — Layout protegido y expulsión al vencer la sesión](#parte-5--layout-protegido-y-expulsión-al-vencer-la-sesión)
- [Parte 6 — Pantalla de login](#parte-6--pantalla-de-login)
- [Parte 7 — "Olvidé mi contraseña"](#parte-7--olvidé-mi-contraseña)
- [Parte 8 — "Cambiar contraseña"](#parte-8--cambiar-contraseña)
- [Parte 9 — Hook del usuario actual y logout](#parte-9--hook-del-usuario-actual-y-logout)
- [Parte 10 — Checklist de verificación](#parte-10--checklist-de-verificación)
- [Parte 11 — Errores conocidos y cómo se diagnostican](#parte-11--errores-conocidos-y-cómo-se-diagnostican)

---

## Parte 0 — Cómo funciona la autenticación

### Modelo

- **Token opaco de 64 caracteres hexadecimales**, generado con dos `SYS_GUID()`
  concatenados. **No es un JWT**: no lleva datos adentro, se valida **siempre**
  contra la tabla `TOKENS`. Ventaja: revocar una sesión tiene efecto inmediato.
- **Vigencia: 8 horas.** Al vencer, cualquier endpoint protegido devuelve `401`.
- Se manda en cada petición como header `Authorization: Bearer <token>`
  (el backend acepta `bearer`/`Bearer`, case-insensitive por RFC).
- **Validar un token comprueba tres cosas:** que esté vigente (`ACTIVO = 'A'`),
  que no haya vencido (`FECHA_EXPIRACION > SYSTIMESTAMP`) **y que la cuenta del
  usuario siga activa** (`USUARIOS.ACTIVO = 'A'`). Inactivar un usuario le corta
  el acceso al instante, aunque su token todavía no haya vencido.

### Tablas involucradas (YA EXISTEN — no crear, no alterar)

```
USUARIOS  ID_USUARIO, USUARIO, NOMBRE_APELLIDO, CORREO, CONTRASENA_HASH,
          SALT, ACTIVO, ES_ADMIN, FECHA_CREACION, FECHA_ACTUALIZACION

TOKENS    ID_TOKEN, ID_USUARIO, TOKEN, FECHA_CREACION, FECHA_EXPIRACION, ACTIVO
```

### Hash de contraseñas

`STANDARD_HASH(SALT || password, 'SHA256')`, con un salt aleatorio de 32 hex por
usuario derivado de `SYS_GUID()`. El salt va **adelante** de la clave.

**No lo cambies.** Cambiar el algoritmo invalidaría todas las contraseñas
existentes del sistema que ya está en producción. El proyecto nuevo nunca
calcula hashes: solo manda usuario y contraseña en texto por HTTPS y el backend
verifica.

### Convención de estados: `'A'` / `'I'` — sin traducción

`USUARIOS.ACTIVO` y `TOKENS.ACTIVO` son **`VARCHAR2(1)`** con `'A'` (activo) o
`'I'` (inactivo). **Ese mismo código viaja en el JSON y llega tal cual al
frontend.** No se traduce a `1`/`0` ni a booleano en ningún punto.

Igual para el rol: `USUARIOS.ES_ADMIN` es `'S'`/`'N'` y viaja así.

> **Por qué importa:** cualquier comparación tipo `WHERE ACTIVO = 1` hace que
> Oracle intente convertir la columna a número y mata la consulta con
> `ORA-01722`, que llega al frontend como un `500` genérico sin ninguna pista.
> En el frontend, usar siempre los helpers `esActivo(x)` / `esAdmin(x)` en vez
> de literales sueltos.

### Reglas de seguridad que el frontend nuevo DEBE respetar

1. **El login devuelve un único mensaje de error.** `401` con
   `"Usuario o contrasena incorrectos"` cubre tres casos distintos: el usuario no
   existe, la clave está mal, o la cuenta está inactiva. Es deliberado —
   distinguirlos convertiría el login en un enumerador de cuentas válidas. **No
   inventar mensajes más específicos en el frontend.**
2. **`/auth/recuperar` siempre responde 200**, coincidan o no los datos. La UI
   muestra el mismo mensaje neutro en los dos casos. Nunca decir "ese usuario no
   existe" ni "ese no es tu correo".
3. **`/auth/cambiar-password` con éxito revoca TODAS las sesiones, incluida la
   propia.** Después de un 200 hay que limpiar el estado local y volver al login.
   Conservar el token daría 401 en la siguiente petición.
4. **Un 401 en una petición autenticada = sesión caída** → limpiar estado local y
   expulsar al login. **Un 401 en el login (petición sin token) = credenciales
   incorrectas** → NO expulsar, mostrar el error en el formulario. Confundir los
   dos casos rompe el acceso: cada intento fallido de login dispararía el aviso de
   "sesión vencida" y sacaría de la pantalla a quien está tratando de entrar.

---

## Parte 1 — Backend: lo único que hay que ejecutar

### Qué NO hacer

- ❌ No copiar ni volver a ejecutar `db/auth.sql`.
- ❌ No crear un `PKG_AUTH_2` ni un módulo ORDS `/auth2/`. El módulo `/auth/` es
  compartido: los dos proyectos le pegan al mismo.
- ❌ No crear ni alterar las tablas `USUARIOS` ni `TOKENS`.
- ❌ No cambiar el algoritmo de hash.

### Qué SÍ hacer: habilitar CORS para el dominio nuevo

**`ORIGINS_ALLOWED` es POR MÓDULO, no a nivel de workspace.** La pantalla de
APEX (_Administración del Workspace → RESTful Services → orígenes permitidos_)
sugiere que es global — **no lo es**. Sin el origen del proyecto nuevo en la
lista, ORDS rechaza la petición **antes de llegar al handler**, con un
`Service Unavailable` genérico que ningún `WHEN OTHERS` puede capturar, porque el
PL/SQL nunca llega a ejecutarse.

**Paso 1 — ver qué orígenes hay hoy** (para no pisarlos):

```sql
SELECT NAME, ORIGINS_ALLOWED FROM USER_ORDS_MODULES WHERE NAME = 'auth';
```

**Paso 2 — reescribir la lista COMPLETA agregando el dominio nuevo:**

```sql
BEGIN
  ORDS.SET_MODULE_ORIGINS_ALLOWED(
    p_module_name     => 'auth',
    p_origins_allowed => 'https://www.ctell.online,'   || -- producción del hub (NO borrar)
                         'http://localhost:8080,'      || -- dev del hub       (NO borrar)
                         'https://TU-DOMINIO-NUEVO,'   || -- ← producción del proyecto nuevo
                         'http://localhost:5173'          -- ← dev del proyecto nuevo
  );
  COMMIT;
END;
/

-- Verificación
SELECT NAME, ORIGINS_ALLOWED FROM USER_ORDS_MODULES WHERE NAME = 'auth';
```

> ⚠️ **La llamada REEMPLAZA la lista entera, no agrega.** Hay que incluir los
> orígenes que ya estaban o se rompe el login de Ctell Admin Hub en producción.

> ⚠️ **`p_origins_allowed` NO es un parámetro de `ORDS.DEFINE_MODULE`** en esta
> versión de ORDS — pasarlo ahí falla con `PLS-00306`. Va siempre en su propia
> llamada a `SET_MODULE_ORIGINS_ALLOWED`.

> ℹ️ El `localhost` de desarrollo solo hace falta en la lista si le vas a pegar
> **directo** a ORDS desde el navegador. Con el proxy de Vite (Parte 3) en dev
> nunca hay CORS — pero dejarlo en la lista no molesta.

**Si el proyecto nuevo va a consumir otros módulos** (`/usuarios/`, `/empresas/`,
etc.), hay que repetir el `SET_MODULE_ORIGINS_ALLOWED` **para cada módulo**.
Habilitarlo en `auth` no lo propaga a ninguno.

### Si alguna vez reejecutás un archivo `db/` en APEX

1. **Frená el `npm run dev`** antes. La sesión de dev mantiene tomadas filas de
   metadatos de ORDS que `DELETE_MODULE` necesita; sin frenarla vas a ver
   `ORA-00060` (interbloqueo) y el endpoint viejo va a seguir publicado.
2. El código corregido en el repo **no cambia nada por sí solo**: ORDS solo
   conoce lo que se ejecutó en APEX. Revisá siempre el resultado de cada paso.

---

## Parte 2 — Referencia completa de endpoints

**Base URL de producción:** `https://oracleapex.com/ords/ctell`
**Base URL en desarrollo (con proxy de Vite):** `/ords/ctell`

Los cinco endpoints del módulo `auth` están **ya publicados**. Esta es su
especificación exacta, tal como responde el backend hoy.

---

### 1. `POST /auth/login` — iniciar sesión

**Público** (sin token).

**Request**

```http
POST /ords/ctell/auth/login
Content-Type: application/json

{ "usuario": "joseg", "password": "miClave123" }
```

- `usuario`: el backend lo busca con `LOWER(TRIM(...))`. Conviene mandarlo ya en
  minúscula y sin espacios desde el frontend.
- `password`: texto plano sobre HTTPS. El hash lo calcula el backend.

**200 — credenciales correctas**

```json
{
  "token": "A1B2C3…(64 hex)…",
  "expira": "2026-08-21T18:30:00",
  "usuario": {
    "id": 1,
    "usuario": "joseg",
    "nombreApellido": "Jose Galvez",
    "correo": "jose@ejemplo.com",
    "esAdmin": "S"
  }
}
```

- `expira`: ISO 8601 **sin zona horaria**. El frontend solo lo muestra o compara.
- `usuario.esAdmin`: `'S'` o `'N'`, tal cual la columna. Sin traducir a booleano.
- **No trae `activo`** a propósito: para haber llegado hasta acá la cuenta tiene
  que estar activa, así que el dato no aportaría nada.
- **Nunca devuelve `CONTRASENA_HASH` ni `SALT`.** No tienen por qué salir de la
  base.

**401 — credenciales incorrectas**

```json
{ "error": "Usuario o contrasena incorrectos" }
```

Un único mensaje para "no existe", "clave incorrecta" y "cuenta inactiva".

**500 — error interno**

```json
{ "error": "Error al iniciar sesion" }
```

El detalle real va a `APEX_DEBUG`, no a la respuesta.

---

### 2. `POST /auth/logout` — cerrar sesión

**Requiere token.**

**Request**

```http
POST /ords/ctell/auth/logout
Authorization: Bearer <token>
```

Sin body. **Importante:** no mandar header `Content-Type` en un POST sin cuerpo —
ORDS intenta parsear un JSON inexistente y responde 400 sin llegar al handler.

**200 — siempre**

```json
{ "ok": true }
```

Revocar es **idempotente**: que el token ya estuviera revocado, vencido o no
existiera no es un error. El cliente quería quedarse sin sesión y se queda sin
sesión.

**Regla de frontend:** el logout local **nunca debe fallar**. Si la llamada al
servidor da error, se ignora y se limpia el estado igual. Si el servidor no pudo
revocarlo, el token vence solo a las 8 h.

---

### 3. `GET /auth/me` — usuario de la sesión actual

**Requiere token.** Sirve para rehidratar el estado al recargar la página y para
comprobar que el token sigue vivo.

**Request**

```http
GET /ords/ctell/auth/me
Authorization: Bearer <token>
```

**200**

```json
{
  "id": 1,
  "usuario": "joseg",
  "nombreApellido": "Jose Galvez",
  "correo": "jose@ejemplo.com",
  "activo": "A",
  "esAdmin": "S"
}
```

**401 — token ausente, inválido, vencido, revocado o de una cuenta inactivada**

```json
{ "error": "Sesion invalida o vencida" }
```

---

### 4. `POST /auth/recuperar` — "olvidé mi contraseña"

**Público** (sin token): quien lo usa es justamente alguien que no puede entrar.

**Request**

```http
POST /ords/ctell/auth/recuperar
Content-Type: application/json

{ "usuario": "joseg", "correo": "jose@ejemplo.com" }
```

**200 — SIEMPRE, coincidan o no los datos**

```json
{
  "ok": true,
  "mensaje": "Si los datos son correctos, vas a recibir un correo con una contrasena provisoria."
}
```

**Qué hace el backend cuando los datos SÍ coinciden** (usuario + correo en la
misma fila, cuenta activa):

1. Genera una contraseña aleatoria de 12 caracteres (alfabeto sin `I/l/1/O/0`,
   porque se lee de un correo y se tipea a mano).
2. Reemplaza `CONTRASENA_HASH` y `SALT` — **la contraseña anterior deja de
   servir en el acto**.
3. **Revoca todas las sesiones del usuario**: quien pidió recuperar la clave
   perdió el control de la anterior.
4. Manda la clave provisoria por correo con `APEX_MAIL`.

**Cuando no coinciden:** no hace nada y responde exactamente lo mismo. Incluso si
el envío de correo falla, la respuesta no cambia — decir "no se pudo enviar"
confirmaría que la cuenta existe.

**Regla de frontend:** el estado final del modal es un **mensaje neutro**, nunca
un "listo, te lo mandamos". Un error en esta llamada solo puede ser de red o del
servidor; el "no coincide" no llega como error, llega como el mismo 200.

---

### 5. `POST /auth/cambiar-password` — cambio de clave del usuario logueado

**Requiere token.**

**Request**

```http
POST /ords/ctell/auth/cambiar-password
Authorization: Bearer <token>
Content-Type: application/json

{ "passwordActual": "claveVieja", "passwordNueva": "claveNueva123" }
```

**200 — cambiada**

```json
{ "ok": true }
```

⚠️ **Un 200 revoca TODAS las sesiones, incluida la que hizo el cambio.** El
token que se usó para llamar acá ya está muerto en el servidor. El frontend
tiene que limpiar su estado local y volver al login.

**400 — la contraseña actual no coincide**

```json
{ "error": "La contrasena actual no es correcta" }
```

**400 — la nueva no cumple el mínimo**

```json
{ "error": "La contrasena nueva debe tener al menos 8 caracteres" }
```

El backend valida **mínimo 8 caracteres**. El formulario del frontend tiene que
validar lo mismo para que el error aparezca antes de la ida y vuelta.

**401 — token ausente, inválido o vencido**

```json
{ "error": "Sesion invalida o vencida" }
```

**Por qué exige la contraseña actual:** sin eso, una pantalla desatendida o una
sesión robada alcanzarían para quedarse con la cuenta para siempre.

---

### Nota sobre el formato de respuesta: el envoltorio `resultado`

Algunos handlers de ORDS devuelven el JSON envuelto:

```json
{ "resultado": "{\"id\":1,\"usuario\":\"joseg\"}" }
```

Es decir, el JSON real viene como **string** dentro de una propiedad
`resultado`. El cliente HTTP tiene que **desempaquetarlo**: si la respuesta es un
objeto con `resultado` de tipo string, parsearlo y devolver eso. El código de la
Parte 4 ya lo hace.

### Endpoints de otros módulos

Si el proyecto nuevo necesita el ABM de usuarios (`/usuarios/`), la lista de
empresas (`/empresas/`) u otros, están documentados en el `CLAUDE.md` del hub.
Recordá: **cada módulo necesita su propio `SET_MODULE_ORIGINS_ALLOWED`**.

---

## Parte 3 — Configuración del proyecto (Vite / proxy / CORS)

CORS se resuelve **distinto en cada entorno**:

| Entorno       | Cómo evita el bloqueo                                                                  | Dónde se configura                       |
| ------------- | -------------------------------------------------------------------------------------- | ---------------------------------------- |
| `npm run dev` | Proxy de Vite: la app pide a la ruta relativa `/ords/ctell` y Vite reenvía a APEX        | `server.proxy` en `vite.config.ts`       |
| Producción    | CORS habilitado en ORDS: la app pega con URL absoluta a `oracleapex.com`                | `ORDS.SET_MODULE_ORIGINS_ALLOWED` (Parte 1) |

En dev, la petición sale al **mismo origen** que la página, así que el navegador
ni evalúa CORS; es Vite quien reenvía a APEX servidor contra servidor, donde la
política de mismo origen no aplica.

### `vite.config.ts`

```ts
export default defineConfig({
  server: {
    port: 5173, // el que uses; anotalo en ORIGINS_ALLOWED si vas sin proxy
    proxy: {
      "/ords": {
        target: "https://oracleapex.com",
        changeOrigin: true,
        secure: true,
      },
    },
  },
});
```

> Si el proyecto nuevo usa un preset de configuración (como el hub, que usa
> `@lovable.dev/vite-tanstack-config`), agregá el `proxy` dentro de la clave
> `vite: { server: { proxy: ... } }` del preset, sin duplicar plugins.

> Si el proyecto nuevo se despliega en un hosting estático (GitHub Pages,
> Netlify, Vercel estático), **no puede haber proxy en producción**: la única
> forma de esquivar CORS ahí es el `ORIGINS_ALLOWED` de la Parte 1.

---

## Parte 4 — Cliente HTTP `src/lib/api.ts`

Este archivo es el corazón de la integración. Copiar tal cual y adaptar solo los
nombres de las claves de storage (el prefijo `ctell-`).

```ts
/**
 * Cliente HTTP contra ORDS.
 *
 * El token de sesión se guarda en sessionStorage: se borra al cerrar la pestaña
 * y no viaja a otros orígenes. No es la opción más robusta —una cookie httpOnly
 * lo sería—, pero ORDS no puede fijar cookies para este dominio, así que el
 * token tiene que quedar en el cliente.
 */

/**
 * En desarrollo, ruta relativa contra el proxy de Vite: la app pide a /ords/...
 * (mismo origen que la página, así que no hay chequeo de CORS) y es Vite quien
 * reenvía a APEX servidor contra servidor.
 *
 * En producción se pega directo a oracleapex.com. Eso requiere que el módulo
 * ORDS tenga el dominio en ORIGINS_ALLOWED (ver Parte 1 de la guía).
 */
const BASE_URL = import.meta.env.DEV ? "/ords/ctell" : "https://oracleapex.com/ords/ctell";

const TOKEN_KEY = "app-token";
const USUARIO_KEY = "app-usuario";
const USUARIO_RECORDADO_KEY = "app-usuario-recordado";

/** Estado de un registro, tal como lo guarda la base: "A" activo, "I" inactivo. */
export type Estado = "A" | "I";

/** `true` si el registro está activo. Evita repetir la comparación literal. */
export function esActivo(estado: Estado | undefined): boolean {
  return estado === "A";
}

/** Rol del usuario, con el mismo código que guarda ES_ADMIN: "S" / "N". */
export type Rol = "S" | "N";

/** `true` si el usuario es administrador. */
export function esAdmin(rol: Rol | undefined): boolean {
  return rol === "S";
}

export type Usuario = {
  id: number;
  usuario: string;
  nombreApellido: string;
  correo: string | null;
  /** Código 'A'/'I' tal cual la base. No es 1/0 ni booleano. */
  activo: Estado;
  esAdmin: Rol;
  fechaCreacion?: string;
  fechaActualizacion?: string;
};

export type LoginResponse = {
  token: string;
  expira: string;
  /** El login devuelve el rol pero no el estado: llegar acá ya implica activo. */
  usuario: Pick<Usuario, "id" | "usuario" | "nombreApellido" | "correo" | "esAdmin">;
};

/* ────────────────────────────────────────────────────────────────────────────
   Aviso de sesión caída
   ──────────────────────────────────────────────────────────────────────────── */

/**
 * Aviso de que la sesión dejó de valer, para que la app lleve al login.
 *
 * Lo dispara cualquier 401 de una petición autenticada: token vencido, revocado
 * al cambiar la contraseña, cuenta inactivada, o simplemente inválido.
 *
 * Este módulo no puede navegar por su cuenta —importar el router desde acá
 * crearía un ciclo, y `request()` no es un componente—, así que avisa y quien
 * sepa navegar reacciona. Ver `useCerrarSesionAlVencer`.
 *
 * Es un `Set` y no un solo callback porque el hook se monta una vez por layout:
 * si un día hay dos, los dos tienen que enterarse.
 */
type OyenteSesion = () => void;
const oyentesSesion = new Set<OyenteSesion>();

/** Suscribe un callback al cierre de sesión. Devuelve cómo desuscribirse. */
export function alCerrarseSesion(oyente: OyenteSesion): () => void {
  oyentesSesion.add(oyente);
  return () => oyentesSesion.delete(oyente);
}

function notificarSesionCerrada() {
  for (const oyente of oyentesSesion) oyente();
}

/** Error con el status HTTP, para distinguir 401 de un fallo real. */
export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

/* ────────────────────────────────────────────────────────────────────────────
   Estado local de la sesión
   ──────────────────────────────────────────────────────────────────────────── */

export function getToken(): string | null {
  if (typeof window === "undefined") return null;
  return sessionStorage.getItem(TOKEN_KEY);
}

export function setToken(token: string | null) {
  if (typeof window === "undefined") return;
  if (token) sessionStorage.setItem(TOKEN_KEY, token);
  else sessionStorage.removeItem(TOKEN_KEY);
}

/** Datos del usuario que `POST /auth/login` ya devuelve junto al token. */
export type UsuarioSesion = LoginResponse["usuario"];

/**
 * Usuario de la sesión, cacheado en sessionStorage.
 *
 * El login ya devuelve nombreApellido, así que guardarlo evita un GET /auth/me
 * extra en cada carga: el saludo del panel aparece de inmediato en vez de
 * esperar un viaje a la red. Vive junto al token y muere con él.
 */
export function getUsuarioSesion(): UsuarioSesion | null {
  if (typeof window === "undefined") return null;
  const crudo = sessionStorage.getItem(USUARIO_KEY);
  if (!crudo) return null;
  try {
    return JSON.parse(crudo) as UsuarioSesion;
  } catch {
    // Si el JSON quedó corrupto se descarta: /auth/me lo repone.
    sessionStorage.removeItem(USUARIO_KEY);
    return null;
  }
}

export function setUsuarioSesion(usuario: UsuarioSesion | null) {
  if (typeof window === "undefined") return;
  if (usuario) sessionStorage.setItem(USUARIO_KEY, JSON.stringify(usuario));
  else sessionStorage.removeItem(USUARIO_KEY);
}

/** Credenciales que "Recordarme" deja precargadas en el login. */
export type CredencialesRecordadas = { usuario: string; password: string };

/**
 * "Recordarme": usuario y contraseña para precargar el formulario de login.
 *
 * ATENCIÓN — esto guarda la contraseña EN TEXTO PLANO en localStorage. Queda en
 * disco, la lee cualquiera que abra F12 → Application → Local Storage, y a
 * diferencia del token (8 h) no vence nunca. En una PC compartida, quien se
 * siente después tiene la clave de quien la usó antes.
 *
 * Es una decisión explícita, no un descuido. La alternativa sin ese riesgo es
 * dejar que el gestor de contraseñas del navegador la guarde cifrada por el SO.
 * Si el proyecto nuevo NO quiere ese riesgo: guardar solo el `usuario`.
 */
export function getCredencialesRecordadas(): CredencialesRecordadas | null {
  if (typeof window === "undefined") return null;
  const crudo = localStorage.getItem(USUARIO_RECORDADO_KEY);
  if (!crudo) return null;
  try {
    const datos = JSON.parse(crudo) as Partial<CredencialesRecordadas>;
    if (!datos.usuario) return null;
    return { usuario: datos.usuario, password: datos.password ?? "" };
  } catch {
    localStorage.removeItem(USUARIO_RECORDADO_KEY);
    return null;
  }
}

export function setCredencialesRecordadas(credenciales: CredencialesRecordadas | null) {
  if (typeof window === "undefined") return;
  if (credenciales) localStorage.setItem(USUARIO_RECORDADO_KEY, JSON.stringify(credenciales));
  else localStorage.removeItem(USUARIO_RECORDADO_KEY);
}

/**
 * Limpia todo el estado local de la sesión.
 *
 * Existe como función aparte porque hay TRES caminos que tienen que dejar el
 * mismo estado: logout, un 401 en cualquier petición, y un cambio de contraseña
 * exitoso. Si el proyecto nuevo agrega estado ligado a la sesión (empresa
 * activa, sucursal, filtros), se limpia acá y los tres caminos lo heredan.
 */
function limpiarSesionLocal() {
  setToken(null);
  setUsuarioSesion(null);
  // setEmpresaSeleccionada(null);  ← agregar acá lo que sume el proyecto nuevo
}

/* ────────────────────────────────────────────────────────────────────────────
   request()
   ──────────────────────────────────────────────────────────────────────────── */

/**
 * Traduce un código HTTP a un mensaje que le sirva a quien usa el sistema.
 *
 * Es el último recurso: solo se usa cuando el backend no mandó su propio
 * mensaje, que siempre es más preciso. Pasa cuando la respuesta no es JSON —un
 * error de ORDS anterior al handler llega como HTML— y ahí lo único que se sabe
 * es el número.
 *
 * Los mensajes dicen qué hacer, no qué falló.
 */
function mensajeSegunEstado(status: number): string {
  switch (status) {
    case 400:
      return "Los datos enviados no son válidos. Revisá el formulario e intentá de nuevo.";
    case 401:
      // Genérico a propósito: acá no se sabe si el 401 vino del login o de un
      // token vencido. El login lo reemplaza por uno específico.
      return "Tu sesión no es válida o expiró. Iniciá sesión de nuevo.";
    case 403:
      return "No tenés permisos para hacer esto. Consultá con un administrador.";
    case 404:
      return "No se encontró lo que buscabas. Puede que se haya eliminado.";
    case 409:
      return "Ese registro ya existe.";
    case 500:
      return "Hubo un problema en el servidor. Si sigue pasando, avisá al administrador.";
    case 502:
    case 503:
    case 504:
      return "El servidor no está respondiendo. Probá de nuevo en unos minutos.";
    default:
      return "No se pudo completar la operación. Intentá de nuevo.";
  }
}

async function request<T>(
  path: string,
  options: RequestInit & { auth?: boolean } = {},
): Promise<T> {
  const { auth = true, headers, ...rest } = options;

  const finalHeaders: Record<string, string> = {
    ...((headers as Record<string, string>) ?? {}),
  };

  // Content-Type SOLO cuando hay cuerpo que describir. Declararlo en un POST
  // vacío (logout) hace que ORDS intente parsear un JSON inexistente y responda
  // 400 sin llegar a ejecutar el handler.
  if (rest.body !== undefined && finalHeaders["Content-Type"] === undefined) {
    finalHeaders["Content-Type"] = "application/json";
  }

  if (auth) {
    const token = getToken();
    if (token) finalHeaders["Authorization"] = `Bearer ${token}`;
  }

  const res = await fetch(`${BASE_URL}${path}`, { ...rest, headers: finalHeaders });

  // 204 y respuestas sin cuerpo no traen JSON. Los errores de ORDS previos al
  // handler tampoco: llegan como HTML, y un JSON.parse a secas fallaría con
  // "Unexpected token <", ocultando el status que sí explica el problema.
  const texto = await res.text();
  let data: { error?: string; resultado?: string } | null = null;
  try {
    data = texto ? JSON.parse(texto) : null;
  } catch {
    data = null;
  }

  if (!res.ok) {
    // Un 401 solo significa "la sesión se cayó" en una petición autenticada.
    // En el login (`auth: false`) significa "credenciales incorrectas": ahí no
    // hay ninguna sesión que perder, y tratarlo igual rompería el acceso.
    if (res.status === 401 && auth) {
      limpiarSesionLocal();
      // …y hay que sacarlo de la pantalla protegida donde quedó. Limpiar el
      // token no alcanza: sin esto seguiría viendo el panel con un error que no
      // explica nada.
      notificarSesionCerrada();
    }
    // El mensaje del backend es siempre el mejor: explica el caso concreto.
    // Solo cuando no llega se traduce el código.
    throw new ApiError(data?.error ?? mensajeSegunEstado(res.status), res.status);
  }

  // Si la respuesta viene empaquetada en { resultado: "..." }, desempaquetarla.
  if (data && typeof data === "object" && "resultado" in data && typeof data.resultado === "string") {
    try {
      return JSON.parse(data.resultado) as T;
    } catch {
      return data as T;
    }
  }

  return data as T;
}

/* ────────────────────────────────────────────────────────────────────────────
   API pública
   ──────────────────────────────────────────────────────────────────────────── */

export const api = {
  /** POST /auth/login — guarda token y usuario en sessionStorage. */
  async login(usuario: string, password: string): Promise<LoginResponse> {
    const data = await request<LoginResponse>("/auth/login", {
      method: "POST",
      auth: false, // sin token: todavía no hay sesión
      body: JSON.stringify({ usuario, password }),
    });
    setToken(data.token);
    // El login ya trae nombreApellido: se guarda para que el panel lo muestre
    // sin tener que pedirlo de nuevo con /auth/me.
    setUsuarioSesion(data.usuario);
    return data;
  },

  /**
   * POST /auth/logout — cierra la sesión. NUNCA lanza: revocar el token en el
   * servidor es "mejor esfuerzo", pero la sesión del navegador se cierra siempre.
   *
   * Un `finally` solo no alcanza —limpia el estado pero deja la promesa
   * rechazada, y el error llega a la consola como "Uncaught (in promise)"—, así
   * que el fallo se captura de verdad. Si el servidor no pudo revocarlo, el
   * token igual vence a las 8 h.
   *
   * OJO: sin body y SIN Content-Type (ver `request`).
   */
  async logout(): Promise<void> {
    try {
      await request("/auth/logout", { method: "POST" });
    } catch {
      // Sin re-lanzar: el usuario pidió salir y va a salir.
    } finally {
      limpiarSesionLocal();
    }
  },

  /**
   * POST /auth/recuperar — "olvidé mi contraseña".
   *
   * No lleva token —quien la usa es justamente alguien que no puede entrar— y
   * SIEMPRE responde 200, coincidan o no los datos. La UI muestra el mismo
   * mensaje en los dos casos.
   */
  recuperarPassword: (datos: { usuario: string; correo: string }) =>
    request<{ ok: boolean; mensaje: string }>("/auth/recuperar", {
      method: "POST",
      auth: false,
      body: JSON.stringify(datos),
    }),

  /**
   * POST /auth/cambiar-password — cambia la contraseña del usuario logueado.
   *
   * Exige la actual: sin eso, una pantalla desatendida alcanzaría para quedarse
   * con la cuenta. UN 200 REVOCA TODAS LAS SESIONES, INCLUIDA LA PROPIA, así que
   * después de esto hay que volver al login — por eso limpia el estado local.
   */
  async cambiarPassword(datos: {
    passwordActual: string;
    passwordNueva: string;
  }): Promise<{ ok: boolean }> {
    const data = await request<{ ok: boolean }>("/auth/cambiar-password", {
      method: "POST",
      body: JSON.stringify(datos),
    });

    // El token que se usó para llamar acá ya está revocado en el servidor:
    // conservarlo daría 401 en la siguiente petición.
    limpiarSesionLocal();

    return data;
  },

  /** GET /auth/me — usuario de la sesión actual. */
  async me(): Promise<Usuario> {
    const raw = await request<{ resultado?: string } | Usuario>("/auth/me");
    if (!raw) return raw as Usuario;

    if ("resultado" in raw && typeof raw.resultado === "string") {
      return JSON.parse(raw.resultado) as Usuario;
    }
    if ("id" in raw && "usuario" in raw) {
      return raw as Usuario;
    }
    return raw as Usuario;
  },
};
```

---

## Parte 5 — Layout protegido y expulsión al vencer la sesión

Hay **tres defensas** y las tres hacen falta, porque cada una cubre un hueco que
las otras dejan:

| Defensa                  | Qué cubre                                       | Qué NO cubre                                          |
| ------------------------ | ----------------------------------------------- | ----------------------------------------------------- |
| `beforeLoad` del layout  | Entrar a una URL protegida sin token            | Un token que existe pero ya no sirve                  |
| `useUsuarioActual`       | El 401 de `/auth/me`                            | Los 401 de cualquier otra petición                    |
| `useCerrarSesionAlVencer`| **Cualquier** 401, de cualquier petición        | —                                                     |

### `src/hooks/use-cerrar-sesion-al-vencer.ts`

```ts
import { useNavigate } from "@tanstack/react-router";
import { useEffect } from "react";
import { toast } from "sonner";

import { alCerrarseSesion } from "@/lib/api";

/**
 * Lleva al login cuando la sesión deja de valer.
 *
 * Escucha el aviso que `api.ts` emite ante cualquier 401, sin importar qué
 * petición lo provocó: el token venció (dura 8 h), se revocó al cambiarse la
 * contraseña, la cuenta se inactivó, o el valor guardado quedó inservible.
 *
 * Cubre el hueco que dejan las otras dos defensas: si la sesión se cae mientras
 * alguien guarda un formulario, el token se limpia pero la persona se queda en
 * la pantalla viendo un error que no explica nada.
 *
 * Se monta UNA SOLA VEZ, en el layout protegido.
 */
export function useCerrarSesionAlVencer() {
  const navigate = useNavigate();

  useEffect(() => {
    return alCerrarseSesion(() => {
      // Sin el aviso, volver al login de golpe parece un cierre de sesión
      // espontáneo. Decir por qué evita que se lea como una falla del sistema.
      toast.info("Tu sesión expiró. Iniciá sesión de nuevo.");
      navigate({ to: "/" });
    });
  }, [navigate]);
}
```

### `src/routes/_auth.tsx` — layout de las páginas que exigen sesión

```tsx
import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";

import { useCerrarSesionAlVencer } from "@/hooks/use-cerrar-sesion-al-vencer";
import { getToken } from "@/lib/api";

/**
 * Layout de las páginas que exigen sesión.
 *
 * El guion bajo lo marca como ruta "pathless": no agrega nada a la URL, solo
 * envuelve a sus hijas. `_auth.home.tsx` sigue siendo `/home`.
 */
export const Route = createFileRoute("/_auth")({
  beforeLoad: () => {
    // En el servidor no hay sessionStorage y getToken() devuelve null siempre.
    // Sin esta guarda, el SSR/prerender redirigiría al login a todo el mundo,
    // incluso con la sesión abierta. La verificación real corre en el cliente,
    // que es donde el token existe.
    if (typeof window === "undefined") return;

    if (getToken() === null) {
      throw redirect({ to: "/" });
    }
  },
  component: LayoutProtegido,
});

function LayoutProtegido() {
  // Un 401 en cualquier petición de las páginas de adentro devuelve al login.
  useCerrarSesionAlVencer();

  return <Outlet />;
}
```

> **Si el proyecto nuevo NO usa TanStack Router:** el equivalente en React Router
> es un componente `<RutaProtegida>` que hace `if (!getToken()) return <Navigate to="/" />`
> y que monta `useCerrarSesionAlVencer()`. La lógica es idéntica; solo cambia la
> forma de declarar la redirección.

> ⚠️ Hace falta un `<Toaster />` montado en el layout raíz (el hub usa `sonner`)
> para que el aviso de sesión vencida se vea.

---

## Parte 6 — Pantalla de login

Ruta pública `/`. Lo esencial, sin el maquetado:

```tsx
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";

import { RecuperarPasswordDialog } from "@/components/RecuperarPasswordDialog";
import { api, ApiError, getCredencialesRecordadas, setCredencialesRecordadas } from "@/lib/api";

export const Route = createFileRoute("/")({ component: LoginPage });

function LoginPage() {
  const navigate = useNavigate();
  const [usuario, setUsuario] = useState("");
  const [password, setPassword] = useState("");
  const [recordar, setRecordar] = useState(false);
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [recuperando, setRecuperando] = useState(false);
  const passwordRef = useRef<HTMLInputElement>(null);

  // A propósito NO se redirige al panel cuando ya hay un token guardado.
  //
  // Tenerlo no prueba que sirva: puede estar vencido, revocado o ser de una
  // sesión que el servidor ya no reconoce. Mandar al panel por su sola
  // presencia deja atrapado a quien viene justamente a iniciar sesión de nuevo.
  //
  // Si el token es válido, /auth/me lo confirma dentro del panel; si no lo es,
  // useCerrarSesionAlVencer devuelve acá.

  // localStorage no existe en el servidor: leerlo durante el render rompe la
  // hidratación. Por eso la precarga ocurre después de montar.
  useEffect(() => {
    const recordado = getCredencialesRecordadas();
    if (!recordado) return;
    setUsuario(recordado.usuario);
    setPassword(recordado.password);
    setRecordar(true);
    // Si quedó guardado el usuario sin la clave, el foco va donde falta escribir.
    if (!recordado.password) passwordRef.current?.focus();
  }, []);

  /**
   * Mensaje de error del login.
   *
   * El 401 se traduce ACÁ y no en api.ts porque el significado depende del
   * contexto: en el resto de la app un 401 es una sesión vencida, pero en el
   * login —donde todavía no hay sesión— solo puede ser credenciales que no
   * coinciden. Decirle "tu sesión expiró" a alguien que recién intenta entrar lo
   * mandaría a buscar un problema que no existe.
   */
  function mensajeDeLogin(err: unknown): string {
    if (err instanceof ApiError) {
      return err.status === 401 ? "Usuario o contraseña incorrectos." : err.message;
    }
    // No es ApiError: la petición no llegó a completarse (sin conexión, DNS,
    // servidor caído). No hay status que traducir.
    return "No se pudo conectar con el servidor. Revisá tu conexión e intentá de nuevo.";
  }

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setLoading(true);

    try {
      await api.login(usuario.trim().toLowerCase(), password);

      // Se guarda recién con el login exitoso: recordar credenciales que no
      // sirven solo serviría para volver a fallar igual.
      setCredencialesRecordadas(recordar ? { usuario: usuario.trim().toLowerCase(), password } : null);

      await navigate({ to: "/home" });
      // `navigate` es asíncrono: sin el await, el botón queda en "Verificando…"
      // mientras la ruta todavía se resuelve, y si la navegación no llega a
      // completarse se queda así para siempre.
      setLoading(false);
    } catch (err) {
      // Si las credenciales guardadas dejaron de servir (cambio de clave, cuenta
      // inactivada), se descartan: precargarlas de nuevo repetiría el error en
      // cada intento.
      if (err instanceof ApiError && err.status === 401) {
        setCredencialesRecordadas(null);
      }
      setError(mensajeDeLogin(err));
      setLoading(false);
    }
  }

  return (
    <main>
      <form onSubmit={handleSubmit}>
        <label htmlFor="usuario">Usuario</label>
        <input
          id="usuario"
          name="usuario"
          autoComplete="username"
          required
          value={usuario}
          onChange={(e) => setUsuario(e.target.value)}
        />

        <label htmlFor="password">Contraseña</label>
        <input
          ref={passwordRef}
          id="password"
          name="password"
          type={showPassword ? "text" : "password"}
          autoComplete="current-password"
          required
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        <button
          type="button"
          onClick={() => setShowPassword((v) => !v)}
          aria-label={showPassword ? "Ocultar contraseña" : "Mostrar contraseña"}
        >
          {showPassword ? "Ocultar" : "Mostrar"}
        </button>

        <label htmlFor="recordar">
          <input
            id="recordar"
            type="checkbox"
            checked={recordar}
            onChange={(e) => {
              const activo = e.target.checked;
              setRecordar(activo);
              // Destildar borra lo guardado EN EL ACTO. Esperar al próximo login
              // exitoso dejaría la contraseña en disco justo cuando el usuario
              // pidió lo contrario.
              if (!activo) setCredencialesRecordadas(null);
            }}
          />
          Recordarme
        </label>

        <button type="button" onClick={() => setRecuperando(true)}>
          ¿Olvidaste tu clave?
        </button>

        {/* role="alert" para que el lector de pantalla anuncie el error */}
        {error && <p role="alert">{error}</p>}

        <button type="submit" disabled={loading}>
          {loading ? "Verificando…" : "Ingresar"}
        </button>
      </form>

      <RecuperarPasswordDialog
        open={recuperando}
        onOpenChange={setRecuperando}
        usuarioInicial={usuario}
      />
    </main>
  );
}
```

### Detalles que parecen menores y no lo son

- **`autoComplete="username"` / `"current-password"`**: sin esto el gestor de
  contraseñas del navegador no ofrece guardar ni completar.
- **`usuario` en minúscula y sin espacios**: el backend busca con
  `LOWER(TRIM(...))`. Mandarlo ya normalizado evita sorpresas.
- **No redirigir al panel por la sola presencia del token** (ver el comentario en
  el código). Es un error frecuente y deja atrapado a quien quiere volver a
  entrar.

---

## Parte 7 — "Olvidé mi contraseña"

Modal público. La regla que gobierna todo el componente: **el backend responde
lo mismo coincidan o no los datos, así que esta pantalla nunca dice si la cuenta
existe.**

```tsx
import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { z } from "zod";

import { api, ApiError } from "@/lib/api";

const schema = z.object({
  usuario: z.string().trim().min(1, "Obligatorio").max(50, "Máximo 50 caracteres"),
  correo: z.string().trim().min(1, "Obligatorio").email("Correo inválido"),
});

type FormValues = z.infer<typeof schema>;

/**
 * "Olvidé mi contraseña": pide usuario + correo y manda una clave provisoria.
 *
 * El backend responde lo mismo coincidan o no los datos, así que esta pantalla
 * NUNCA dice si la cuenta existe. Confirmarlo convertiría el modal en un
 * verificador de usuarios y de sus direcciones. Por eso el estado final es un
 * mensaje neutro y no un "listo, te lo mandamos".
 */
export function RecuperarPasswordDialog({
  open,
  onOpenChange,
  /** Se precarga con lo que ya haya tipeado en el login: un campo menos. */
  usuarioInicial = "",
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  usuarioInicial?: string;
}) {
  const [enviado, setEnviado] = useState(false);

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { usuario: usuarioInicial, correo: "" },
  });

  // Cada apertura arranca limpia: reabrir y encontrar la confirmación de la vez
  // anterior haría creer que el correo se mandó de nuevo.
  useEffect(() => {
    if (open) {
      setEnviado(false);
      form.reset({ usuario: usuarioInicial, correo: "" });
    }
  }, [open, usuarioInicial, form]);

  const recuperar = useMutation({
    mutationFn: (v: FormValues) =>
      api.recuperarPassword({ usuario: v.usuario.toLowerCase(), correo: v.correo }),
    onSuccess: () => setEnviado(true),
    // Un error acá es de red o del servidor: el "no coincide" NO llega como
    // error, llega como el mismo 200 de siempre.
    onError: (e) =>
      form.setError("root", {
        message: e instanceof ApiError ? e.message : "No se pudo procesar el pedido. Probá de nuevo.",
      }),
  });

  // … render: si `enviado`, mensaje NEUTRO; si no, el formulario.
}
```

### Textos del estado final (copiar tal cual — están calibrados)

> **Título:** Revisá tu correo
> **Descripción:** Si los datos son correctos, vas a recibir una contraseña provisoria.
>
> Si el usuario y el correo corresponden a una cuenta activa, el mensaje ya está
> en camino.
> Puede tardar unos minutos. Revisá también la carpeta de correo no deseado.
>
> Tu contraseña anterior dejó de funcionar. Cuando entres, cambiala desde
> Configuración.

Ninguno afirma que la cuenta exista. El último aviso importa: al pedir la
recuperación, **la clave anterior deja de servir en el acto**, aunque el usuario
nunca llegue a usar la provisoria.

### Un detalle de autocompletado que muerde

En los dos campos poner `autoComplete="off"` (más `autoCorrect="off"`,
`autoCapitalize="none"`, `spellCheck={false}`):

```tsx
<input {...field} autoComplete="off" autoCorrect="off" autoCapitalize="none" spellCheck={false} />
```

**El usuario NO es el correo.** Con `autoComplete="username"` el navegador ofrece
en el campo de usuario la dirección guardada (y el nombre de usuario en el campo
de correo), porque trata a ambos como la misma identidad. `"off"` corta ese cruce.

---

## Parte 8 — "Cambiar contraseña"

Modal del usuario logueado. **Un cambio exitoso cierra la sesión** — el backend
revoca todos los tokens, incluido el de esta pestaña.

```tsx
import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { api, ApiError } from "@/lib/api";

const schema = z
  .object({
    passwordActual: z.string().min(1, "Obligatorio"),
    // Mismas reglas que valida PKG_AUTH: si acá pasa, allá también.
    passwordNueva: z.string().min(8, "Mínimo 8 caracteres").max(128, "Máximo 128 caracteres"),
    confirmacion: z.string().min(1, "Obligatorio"),
  })
  // La confirmación es SOLO del formulario: el backend no la recibe. Existe
  // porque un error de tipeo en una clave que no se ve dejaría al usuario
  // afuera, y sin sesión para arreglarlo.
  .refine((v) => v.passwordNueva === v.confirmacion, {
    message: "Las contraseñas no coinciden",
    path: ["confirmacion"],
  })
  .refine((v) => v.passwordNueva !== v.passwordActual, {
    message: "La nueva tiene que ser distinta de la actual",
    path: ["passwordNueva"],
  });

type FormValues = z.infer<typeof schema>;

/**
 * Cambio de contraseña del usuario logueado.
 *
 * UN CAMBIO EXITOSO CIERRA LA SESIÓN: el backend revoca todos los tokens,
 * incluido el de esta pestaña. Es deliberado —si se cambia por sospecha de robo,
 * dejar viva cualquier sesión anterior anularía el motivo— así que al terminar
 * se vuelve al login.
 */
export function CambiarPasswordDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const navigate = useNavigate();

  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { passwordActual: "", passwordNueva: "", confirmacion: "" },
  });

  // Reabrir no debe mostrar lo tipeado la vez anterior: son credenciales.
  useEffect(() => {
    if (open) form.reset({ passwordActual: "", passwordNueva: "", confirmacion: "" });
  }, [open, form]);

  const cambiar = useMutation({
    mutationFn: (v: FormValues) =>
      api.cambiarPassword({ passwordActual: v.passwordActual, passwordNueva: v.passwordNueva }),
    onSuccess: () => {
      // `api.cambiarPassword` ya limpió token y usuario: el token con el que se
      // llamó quedó revocado en el servidor.
      toast.success("Contraseña cambiada. Volvé a entrar con la nueva.");
      onOpenChange(false);
      navigate({ to: "/" });
    },
    onError: (e) =>
      form.setError("root", {
        message: e instanceof ApiError ? e.message : "No se pudo cambiar la contraseña. Probá de nuevo.",
      }),
  });

  // … render: tres campos de contraseña + aviso de que se cierran las sesiones.
}
```

### Texto de la descripción del modal (importante)

> Al cambiarla se cierran todas tus sesiones, incluida esta: vas a tener que
> entrar de nuevo.

Decirlo **antes** evita que el usuario crea que el sistema se rompió cuando lo
saque al login.

### Campos con ojo de mostrar/ocultar

Cada campo maneja su propio estado de visibilidad — mostrar la actual no tiene
por qué destapar la nueva:

```tsx
function PasswordInput({ autoComplete, ...props }: React.ComponentProps<"input"> & { autoComplete: string }) {
  const [visible, setVisible] = useState(false);
  return (
    <div className="relative">
      <input {...props} type={visible ? "text" : "password"} autoComplete={autoComplete} />
      <button
        type="button"
        onClick={() => setVisible((v) => !v)}
        aria-label={visible ? "Ocultar contraseña" : "Mostrar contraseña"}
      >
        {visible ? "Ocultar" : "Mostrar"}
      </button>
    </div>
  );
}
```

`autoComplete`: `"current-password"` en el campo de la actual, `"new-password"`
en la nueva y en la confirmación.

---

## Parte 9 — Hook del usuario actual y logout

### `src/hooks/use-usuario-actual.ts`

```ts
import { useQuery } from "@tanstack/react-query";

import { api, ApiError, getToken, getUsuarioSesion } from "@/lib/api";

/**
 * Usuario de la sesión actual.
 *
 * El login ya devuelve los datos del usuario, así que se usan como valor
 * inicial: el nombre aparece apenas carga el panel, sin esperar la red.
 * `GET /auth/me` corre igual en segundo plano para refrescarlos — si alguien
 * cambió el nombre desde otra sesión, se actualiza solo.
 *
 * De la sesión vencida se encarga `useCerrarSesionAlVencer`, montado en el
 * layout protegido: escucha los 401 de cualquier petición, no solo los de acá.
 */
export function useUsuarioActual() {
  return useQuery({
    queryKey: ["usuario-actual"],
    queryFn: () => api.me(),
    // Sin token no hay nada que pedir: en el login la petición daría 401.
    enabled: getToken() !== null,
    // Lo que trajo el login. Al ser un subconjunto de Usuario, las páginas que
    // solo muestran el nombre ya tienen todo lo que necesitan.
    placeholderData: () => {
      const sesion = getUsuarioSesion();
      // "A": si hay sesión, la cuenta está activa — el login rechaza a los
      // inactivos, así que un token válido implica una cuenta habilitada.
      return sesion ? ({ ...sesion, activo: "A" } as Awaited<ReturnType<typeof api.me>>) : undefined;
    },
    // El token dura 8 h y los datos del usuario no cambian entre pantallas.
    staleTime: 5 * 60 * 1000,
    // Un 401 significa sesión vencida, no un fallo temporal: reintentar solo
    // repite el mismo error.
    retry: (fallos, error) => !(error instanceof ApiError && error.status === 401) && fallos < 2,
  });
}

/** Iniciales para el avatar: "Jose Galvez" -> "JG". */
export function iniciales(nombreApellido: string | undefined): string {
  if (!nombreApellido) return "";
  return nombreApellido
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .map((parte) => parte[0]?.toUpperCase() ?? "")
    .join("");
}

/** Primer nombre, para saludar sin sonar formal: "Jose Galvez" -> "Jose". */
export function primerNombre(nombreApellido: string | undefined): string {
  if (!nombreApellido) return "";
  return nombreApellido.trim().split(/\s+/)[0] ?? "";
}
```

### Botón de cerrar sesión

```tsx
import { useNavigate } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { api } from "@/lib/api";

function BotonSalir() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  async function salir() {
    await api.logout(); // nunca lanza
    // Sin esto, el caché de TanStack Query conserva los datos del usuario
    // anterior y el siguiente que entre en esta PC los ve por un instante.
    queryClient.clear();
    await navigate({ to: "/" });
  }

  return <button onClick={salir}>Cerrar sesión</button>;
}
```

---

## Parte 10 — Checklist de verificación

Probar **en este orden**. Cada punto falla distinto y el orden ahorra tiempo.

### Backend / conectividad

- [ ] `SELECT NAME, ORIGINS_ALLOWED FROM USER_ORDS_MODULES WHERE NAME = 'auth';`
      lista el dominio nuevo **y** los que ya estaban.
- [ ] `npm run dev` → login funciona (va por el proxy de Vite, sin CORS).
- [ ] Build de producción desplegado → login funciona (va directo a
      `oracleapex.com`, con CORS). **Este es el que suele fallar**, y el síntoma
      es un `Service Unavailable` genérico.
- [ ] El login de **Ctell Admin Hub** sigue funcionando (no se pisó la lista de
      orígenes).

### Login

- [ ] Credenciales correctas → entra y navega al panel.
- [ ] Credenciales incorrectas → **"Usuario o contraseña incorrectos"** en el
      formulario, y **NO** el toast de "sesión expiró" ni una expulsión.
- [ ] Usuario inactivo → mismo mensaje que credenciales incorrectas.
- [ ] Servidor caído / sin red → "No se pudo conectar con el servidor…".
- [ ] "Recordarme" tildado → al reabrir, usuario y clave precargados.
- [ ] "Recordarme" destildado → se borra lo guardado en el acto.
- [ ] Login fallido con 401 → se descartan las credenciales recordadas.

### Sesión

- [ ] `sessionStorage` tiene el token y el usuario después del login.
- [ ] Recargar (F5) en una página protegida → sigue adentro, y `/auth/me`
      repuebla los datos.
- [ ] Abrir una URL protegida en pestaña nueva (sin token, porque
      `sessionStorage` no se comparte) → redirige al login.
- [ ] Borrar el token a mano en DevTools y hacer cualquier petición → toast
      "Tu sesión expiró" + vuelta al login.
- [ ] Cerrar sesión → token limpio, caché de queries limpio, vuelve al login.
- [ ] Logout con el servidor caído → **igual sale** (no lanza error).

### Recuperar contraseña

- [ ] Datos correctos → mensaje neutro + llega el correo con la clave provisoria.
- [ ] Datos incorrectos → **exactamente el mismo mensaje neutro**, sin pista de
      que la cuenta no existe.
- [ ] Entrar con la clave provisoria funciona; la anterior **ya no**.
- [ ] Reabrir el modal después de enviar → arranca limpio, no muestra la
      confirmación anterior.

### Cambiar contraseña

- [ ] Contraseña actual incorrecta → "La contraseña actual no es correcta".
- [ ] Nueva de menos de 8 caracteres → el formulario lo bloquea antes de enviar.
- [ ] Confirmación distinta → "Las contraseñas no coinciden".
- [ ] Nueva igual a la actual → "La nueva tiene que ser distinta de la actual".
- [ ] Cambio exitoso → toast + vuelta al login + **el token viejo ya no sirve**.
- [ ] Después del cambio, **la otra pestaña / el otro sistema (Ctell Admin Hub)
      también queda sin sesión.** Es lo esperado: se revocan todas.

> ⚠️ **Consecuencia de compartir la base entre dos proyectos:** cambiar la
> contraseña en el proyecto nuevo también cierra la sesión del hub, y viceversa.
> No es un bug — `REVOCAR_TOKENS_USUARIO` no distingue de qué app vino el token.
> Si conviene, avisalo en el texto del modal.

---

## Parte 11 — Errores conocidos y cómo se diagnostican

| Síntoma                                                             | Causa                                                                    | Solución                                                                                            |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| `Service Unavailable` genérico, solo en producción                   | El dominio nuevo no está en `ORIGINS_ALLOWED` del módulo                 | Parte 1. ORDS rechaza **antes** del handler: ningún log de PL/SQL lo va a mostrar                     |
| CORS bloqueado en `/usuarios/` pero `/auth/` anda                    | `ORIGINS_ALLOWED` es **por módulo**                                      | Repetir `SET_MODULE_ORIGINS_ALLOWED` en cada módulo que se consuma                                   |
| `400` en el logout sin llegar al handler                             | Se mandó `Content-Type: application/json` en un POST sin body            | Mandar el header **solo** cuando hay body (ya resuelto en `request`)                                 |
| `Unexpected token <` al parsear la respuesta                         | ORDS devolvió HTML (error previo al handler)                             | `request` ya lo tolera: cae a `mensajeSegunEstado(status)`                                           |
| El toast de "sesión expiró" salta en cada intento de login fallido   | El 401 del login se trató como sesión caída                              | El aviso solo se dispara con `auth: true` (ver `request`)                                            |
| `500` con `"Error al iniciar sesion"` y nada más                     | Suele ser `ORA-01722`: se comparó `ACTIVO` contra un número              | Estados como texto `'A'`/`'I'` siempre. El detalle real está en `APEX_DEBUG`                          |
| El correo de recuperación nunca llega                                | Configuración de `APEX_MAIL` en el workspace                             | `SELECT PKG_AUTH.PROBAR_CORREO('destino@ejemplo.com') FROM DUAL;` devuelve el error en texto          |
| El usuario entra pero `/auth/me` da 401                              | Cuenta inactivada, o token revocado por un cambio de contraseña          | Es correcto: `VALIDAR_TOKEN` exige que la cuenta siga activa                                          |
| Todo el mundo va al login en el build, aunque tenga sesión           | El `beforeLoad` corrió en el servidor, donde `sessionStorage` no existe  | La guarda `if (typeof window === "undefined") return;` (Parte 5)                                      |
| `ORA-00060` al reejecutar un archivo `db/`                           | El `npm run dev` mantiene tomadas filas de metadatos de ORDS             | Frenar dev **antes** de ejecutar                                                                      |
| `PLS-00306` al definir un módulo                                     | Se pasó `p_origins_allowed` a `ORDS.DEFINE_MODULE`                       | Va en su propia llamada a `SET_MODULE_ORIGINS_ALLOWED`                                                |

### Diagnóstico del lado del servidor

```sql
-- ¿Existe y está válido el paquete?
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS FROM USER_OBJECTS WHERE OBJECT_NAME = 'PKG_AUTH';

-- Si está INVALID, acá está el motivo
SELECT NAME, LINE, POSITION, TEXT FROM USER_ERRORS WHERE NAME = 'PKG_AUTH' ORDER BY SEQUENCE;

-- ¿Qué rutas hay publicadas en el módulo auth?
SELECT t.URI_TEMPLATE, h.METHOD
  FROM USER_ORDS_TEMPLATES t
  JOIN USER_ORDS_HANDLERS  h ON h.TEMPLATE_ID = t.ID
  JOIN USER_ORDS_MODULES   m ON m.ID = t.MODULE_ID
 WHERE m.NAME = 'auth'
 ORDER BY t.URI_TEMPLATE, h.METHOD;
-- Debe listar: cambiar-password POST, login POST, logout POST, me GET, recuperar POST

-- Orígenes CORS habilitados
SELECT NAME, ORIGINS_ALLOWED FROM USER_ORDS_MODULES;

-- Sesiones vigentes de un usuario
SELECT t.ID_TOKEN, t.FECHA_CREACION, t.FECHA_EXPIRACION, t.ACTIVO
  FROM TOKENS t JOIN USUARIOS u ON u.ID_USUARIO = t.ID_USUARIO
 WHERE u.USUARIO = 'joseg' ORDER BY t.FECHA_CREACION DESC;
```

### Probar los endpoints sin frontend

```sh
# Login
curl -X POST https://oracleapex.com/ords/ctell/auth/login \
  -H "Content-Type: application/json" \
  -d '{"usuario":"joseg","password":"miClave"}'

# Sesión actual
curl https://oracleapex.com/ords/ctell/auth/me \
  -H "Authorization: Bearer EL_TOKEN"

# Logout (sin Content-Type: no hay body)
curl -X POST https://oracleapex.com/ords/ctell/auth/logout \
  -H "Authorization: Bearer EL_TOKEN"

# Recuperar
curl -X POST https://oracleapex.com/ords/ctell/auth/recuperar \
  -H "Content-Type: application/json" \
  -d '{"usuario":"joseg","correo":"jose@ejemplo.com"}'

# Cambiar contraseña
curl -X POST https://oracleapex.com/ords/ctell/auth/cambiar-password \
  -H "Authorization: Bearer EL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"passwordActual":"vieja","passwordNueva":"nuevaSegura123"}'
```

> `curl` no aplica CORS (es cosa del navegador). Si `curl` anda y el navegador
> no, el problema es **siempre** `ORIGINS_ALLOWED`.

---

## Resumen en 10 líneas

1. El backend de auth **ya existe**: `PKG_AUTH` + módulo ORDS `/auth/`. No se toca.
2. Lo único que se ejecuta en la base: agregar el dominio nuevo a
   `ORDS.SET_MODULE_ORIGINS_ALLOWED('auth', …)`, **sin borrar los existentes**.
3. Cinco endpoints: `login`, `logout`, `me`, `recuperar`, `cambiar-password`.
4. Token opaco de 64 hex, 8 h de vigencia, en `Authorization: Bearer <token>`.
5. `sessionStorage` para el token y el usuario; `localStorage` solo para
   "Recordarme".
6. Estados `'A'`/`'I'` y rol `'S'`/`'N'` **sin traducir** en ningún punto.
7. Un 401 **con** token = sesión caída → limpiar y expulsar. Un 401 **sin** token
   = credenciales incorrectas → mostrar en el formulario.
8. `recuperar` siempre responde 200: la UI nunca revela si la cuenta existe.
9. `cambiar-password` revoca **todas** las sesiones: después del 200, al login.
10. En dev, proxy de Vite; en producción, CORS en ORDS. Nunca las dos cosas.
