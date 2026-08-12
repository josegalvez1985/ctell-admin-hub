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
│   │   │   ├── UsuariosDialog.tsx
│   │   │   ├── ThemeToggle.tsx
│   │   │   ├── Logo.tsx
│   │   │   └── theme-provider.tsx
│   │   └── ui/               shadcn/ui componentes (no editar manualmente)
│   ├── hooks/
│   │   ├── use-usuario-actual.ts   Hook para auth del usuario logueado
│   │   └── use-cerrar-sesion-al-vencer.ts
│   ├── lib/
│   │   └── api.ts            Cliente HTTP contra ORDS
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

| Método | Ruta           | Auth  | Devuelve                                                   |
| ------ | -------------- | ----- | ---------------------------------------------------------- |
| `POST` | `/auth/login`  | —     | `{ token, expira, usuario }`                               |
| `POST` | `/auth/logout` | token | `{ ok: true }`                                             |
| `GET`  | `/auth/me`     | token | `{ id, usuario, nombreApellido, correo, activo, esAdmin }` |

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
- **`_auth.home.tsx`:** "/home" → Dashboard.
- **`_auth.configuracion.tsx`:** "/configuracion" → Preferencias (tema, acento).

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
