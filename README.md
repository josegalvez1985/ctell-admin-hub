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
| Build       | Vite 8 + nitro                      |
| Hosting     | Cloudflare Workers                  |
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

> `npm run preview` no funciona en este proyecto: busca `dist/server/` pero el
> build genera `.output/` vía nitro. Para probar el build de producción usá
> `npx wrangler dev` dentro de `.output/server`.

### Comandos

| Comando            | Qué hace                          |
| ------------------ | --------------------------------- |
| `npm run dev`      | Servidor de desarrollo con HMR    |
| `npm run build`    | Build de producción en `.output/` |
| `npm run lint`     | ESLint + Prettier                 |
| `npm run format`   | Aplica formato a todo el proyecto |
| `npx tsc --noEmit` | Verificación de tipos             |

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

Automático a Cloudflare Workers en cada push a `main`.

### Configuración inicial (una sola vez)

1. **Crear el API token en Cloudflare**
   [Dashboard](https://dash.cloudflare.com/profile/api-tokens) → _Create Token_ →
   plantilla **Edit Cloudflare Workers**.

2. **Copiar el Account ID**
   Está en la barra lateral de Workers & Pages, o en la URL del dashboard.

3. **Cargar los secrets en GitHub**
   Repo → _Settings_ → _Secrets and variables_ → _Actions_ → _New repository secret_:

   | Secret                  | Valor                    |
   | ----------------------- | ------------------------ |
   | `CLOUDFLARE_API_TOKEN`  | El token del paso 1      |
   | `CLOUDFLARE_ACCOUNT_ID` | El Account ID del paso 2 |

Con eso, el próximo push a `main` despliega solo.

### Workflows

| Archivo                                    | Cuándo corre           | Qué hace                    |
| ------------------------------------------ | ---------------------- | --------------------------- |
| [ci.yml](.github/workflows/ci.yml)         | push y PR a `main`     | typecheck + lint + build    |
| [deploy.yml](.github/workflows/deploy.yml) | push a `main` o manual | build + deploy a Cloudflare |

También podés desplegar a mano desde la pestaña **Actions** → _Deploy_ →
_Run workflow_.

### Desplegar desde tu máquina

```sh
npm run build
npx wrangler deploy -c .output/server/wrangler.json
```

> Requiere **wrangler 4** (fijado en `devDependencies`). La v3 no entiende el
> formato de configuración que genera nitro 3 y falla con exit code 1.

## Convenciones

Antes de escribir código nuevo, leé la
[Guía de implementación](docs/GUIA-IMPLEMENTACION.md): explica cómo agregar una
tabla nueva de punta a punta — paquete PL/SQL, endpoints ORDS, cliente HTTP,
página y formulario — siguiendo los patrones del proyecto.
