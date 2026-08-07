# Ctell Admin Hub

Sistema administrativo web y PWA para CTELL: compras, ventas, stock, tesorería
y recursos humanos, con login de usuarios.

## Stack

| Capa        | Tecnología                          |
| ----------- | ----------------------------------- |
| Framework   | TanStack Start (React 19 + SSR)     |
| Ruteo       | TanStack Router (rutas por archivo) |
| Datos       | TanStack Query                      |
| Estilos     | Tailwind CSS v4 + shadcn/ui         |
| Formularios | react-hook-form + zod               |
| Build       | Vite 8 (SPA estática)               |
| Hosting     | GitHub Pages                        |
| **Backend** | **Oracle APEX + ORDS (PL/SQL)**     |

El backend es independiente del frontend: son paquetes PL/SQL publicados como
REST por ORDS, en `https://oracleapex.com/ords/ctell/`. El frontend sólo los
consume por HTTP — no hay server functions ni acceso directo a la base desde el
Worker.

## Desarrollo

Requiere Node.js 22 o superior.

```sh
npm install
npm run dev
```

Vite imprime la URL local al arrancar (normalmente `http://localhost:5173`).

### Comandos

| Comando            | Qué hace                             |
| ------------------ | ------------------------------------ |
| `npm run dev`      | Servidor de desarrollo con HMR       |
| `npm run build`    | Build de producción en `dist/client/` |
| `npm run preview`  | Sirve el build ya generado           |
| `npm run lint`     | ESLint + Prettier                    |
| `npm run format`   | Aplica formato a todo el proyecto    |
| `npx tsc --noEmit` | Verificación de tipos                |

## Estructura

```
db/                      Backend: un archivo SQL por tabla
└── usuarios.sql         PKG_USUARIOS + PKG_TOKENS + /auth/ + /usuarios/

src/
├── routes/              Rutas (el archivo define la URL)
│   ├── __root.tsx       Layout raíz: <html>, providers, meta global
│   ├── index.tsx        "/"              → login
│   ├── home.tsx         "/home"          → panel general
│   └── configuracion.tsx "/configuracion" → preferencias
├── components/
│   ├── ctell/           Componentes propios del proyecto
│   └── ui/              shadcn/ui (no editar a mano)
├── lib/
│   └── api.ts           Cliente HTTP contra ORDS
└── styles.css           Design system (variables de color en oklch)
```

## Backend

> **Regla: cada tabla tiene su propio archivo en `db/`, nombrado como la tabla,
> con todo su CRUD adentro.**

```
db/
├── usuarios.sql     ya existe
├── empresas.sql     PKG_EMPRESAS + módulo ORDS /empresas/
├── clientes.sql     PKG_CLIENTES + módulo ORDS /clientes/
└── articulos.sql    PKG_ARTICULOS + módulo ORDS /articulos/
```

Cada archivo se ejecuta **de una sola vez y por separado** en la hoja de trabajo
SQL de APEX, y contiene el paquete PL/SQL, el módulo ORDS con sus endpoints y
las consultas de verificación. Tocar empresas no obliga a reejecutar usuarios.

Los archivos son **idempotentes** (se pueden reejecutar) y **no crean ni alteran
tablas**: el DDL se administra aparte.

### Endpoints publicados

| Método   | Ruta                          | Auth  |
| -------- | ----------------------------- | ----- |
| `POST`   | `/auth/login`                 | —     |
| `POST`   | `/auth/logout`                | token |
| `GET`    | `/auth/me`                    | token |
| `GET`    | `/usuarios/`                  | token |
| `POST`   | `/usuarios/`                  | token |
| `GET`    | `/usuarios/:id`               | token |
| `PUT`    | `/usuarios/:id`               | token |
| `DELETE` | `/usuarios/:id`               | token |
| `POST`   | `/usuarios/:id/inactivar`     | token |
| `POST`   | `/usuarios/:id/activar`       | token |
| `POST`   | `/usuarios/:id/password`      | token |

El token se envía como `Authorization: Bearer <token>` y vence a las 8 horas.

> **Hash de contraseñas:** hoy usa `STANDARD_HASH` SHA-256 con salt, porque
> `DBMS_CRYPTO` no está concedido en el workspace. SHA-256 no tiene factor de
> trabajo y es débil frente a fuerza bruta. Si conseguís
> `GRANT EXECUTE ON SYS.DBMS_CRYPTO`, migrá a PBKDF2 — la versión está lista en
> un comentario dentro de `HASH_PASSWORD`. Migrar invalida los hashes
> existentes: hay que resetear las contraseñas.

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

Automático a **GitHub Pages** en cada push a `main`:
<https://josegalvez1985.github.io/ctell-admin-hub/>

### Configuración inicial (una sola vez)

Repo → _Settings_ → _Pages_ → en **Source** elegí **GitHub Actions**.

No hacen falta secrets ni tokens: el workflow publica con el `GITHUB_TOKEN` que
Actions provee solo.

### Cómo funciona

Pages sirve **archivos estáticos**: no puede ejecutar un servidor. Por eso el
build es una SPA y no usa SSR.

- `spa: { enabled: true }` en [vite.config.ts](vite.config.ts) genera
  `dist/client/_shell.html` en vez de un servidor nitro.
- El workflow copia ese shell a `index.html` y a **`404.html`**. Ese 404 es lo
  que hace funcionar el ruteo: Pages lo devuelve ante cualquier URL que no sea
  un archivo, y el router del cliente resuelve la ruta.
- `.nojekyll` evita que Pages ignore los archivos que empiezan con `_`.

El sitio vive en `/ctell-admin-hub/`, no en la raíz del dominio, así que:

- `base` de Vite se activa con `GITHUB_PAGES=true` (en local queda `/`).
- El router recibe `basepath` en [src/router.tsx](src/router.tsx) — sin eso,
  `base` sólo arregla los assets y las rutas darían 404.
- Los assets de `public/` no pasan por el bundler: sus rutas llevan
  `import.meta.env.BASE_URL` a mano.

> Perder el SSR no cuesta nada acá: el backend es ORDS y los datos van detrás
> de un token que en el servidor no existe, así que el SSR sólo aportaba el
> primer render.

### Workflows

| Archivo                                                | Cuándo corre           | Qué hace                 |
| ------------------------------------------------------ | ---------------------- | ------------------------ |
| [ci.yml](.github/workflows/ci.yml)                     | push y PR a `main`     | typecheck + lint + build |
| [deploy-pages.yml](.github/workflows/deploy-pages.yml) | push a `main` o manual | build SPA + publica      |

También podés desplegar a mano desde la pestaña **Actions** →
_Deploy to GitHub Pages_ → _Run workflow_.

### Probar el build de Pages en local

```sh
GITHUB_PAGES=true npm run build
npx serve dist/client
```

## Convenciones

Antes de escribir código nuevo, leé la
[Guía de implementación](docs/GUIA-IMPLEMENTACION.md): explica cómo agregar una
tabla nueva de punta a punta — paquete PL/SQL, endpoints ORDS, cliente HTTP,
página y formulario — siguiendo los patrones del proyecto.
