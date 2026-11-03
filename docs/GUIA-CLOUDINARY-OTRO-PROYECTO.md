# Guía: imágenes y PDF en Cloudinary para la app del profesor

> **Para quién es esto:** para la IA o el desarrollador que trabaja en la **app
> del profesor** (la APK), que usa **la misma base Oracle APEX** que Ctell Admin
> Hub.
>
> **Qué cambió:** el hub dejó de guardar archivos en la base. Las **fotos de
> profesores** y los **PDF de manuales** ahora van a Cloudinary, y en Oracle
> queda sólo la URL. Las **evidencias de reportes** ya iban a Cloudinary; ahora
> además se achican antes de subir.
>
> **Regla número uno: leer primero la URL y, si no hay, el BLOB.** Los archivos
> viejos siguen en la base hasta que alguien los vuelva a subir. Una app que lea
> sólo el BLOB deja de ver todo lo nuevo, y una que lea sólo la URL deja de ver
> todo lo viejo.

### Resumen por tipo de archivo

| Archivo | Tipo | Antes | Ahora | Qué tiene que cambiar la app |
| ------- | ---- | ----- | ----- | ---------------------------- |
| Foto de profesor | Imagen | BLOB en `PROFESORES.FOTO` | URL en `PROFESORES.FOTO_URL` | Leer la URL primero (§4). Si la sube: Cloudinary (§4–6) |
| Manual | **PDF** | BLOB en `MANUALES.ARCHIVO_PDF` | URL en `MANUALES.ARCHIVO_URL` | Leer la URL primero (§3) |
| Evidencia de reporte | Imagen | URL en `REPORTES_MULTIMEDIA.URL_ARCHIVO` | Igual | Nada obligatorio. Opcional: achicar (§5) y borrar al eliminar (§7) |
| Evidencia de reporte | **PDF** o video | URL en `REPORTES_MULTIMEDIA.URL_ARCHIVO` | Igual | Nada. Se suben como vienen |

---

## 1. Por qué

El esquema tiene **25 MB de cuota compartida** entre los dos proyectos, y los
BLOB ya la llenaron una vez: todo `INSERT` de cualquier tabla fallaba con
`ORA-01536`. Tres manuales escaneados alcanzan para trabar las dos apps.

Lo único que sigue en la base son el **logo de empresa** y la **foto de cada
denominación de moneda**.

---

## 2. Qué cambió en la base

| Tabla | Columna nueva | Qué guarda | La vieja (sigue existiendo) |
| ----- | ------------- | ---------- | --------------------------- |
| `PROFESORES` | `FOTO_URL VARCHAR2(500)` | URL https de Cloudinary | `FOTO` (BLOB), `FOTO_MIME` |
| `MANUALES` | `ARCHIVO_URL VARCHAR2(500)` | URL https de Cloudinary | `ARCHIVO_PDF` (BLOB), `ARCHIVO_MIME` |
| `MANUALES` | `ARCHIVO_BYTES NUMBER` | Peso del PDF | — |
| `REPORTES_MULTIMEDIA` | (sin cambios) | Ya guardaba `URL_ARCHIVO` | — |

Las columnas las agregan `db/profesores.sql` y `db/manuales.sql` del hub.
**La app no ejecuta esos archivos ni crea las columnas**: las crea el hub. Si la
app compila contra ellas antes de que existan, su paquete queda `INVALID`.

**Cómo conviven lo viejo y lo nuevo, fila por fila:**

| `*_URL` | BLOB | Qué significa | Qué mostrar |
| ------- | ---- | ------------- | ----------- |
| con valor | `NULL` | Subido después del cambio | La URL |
| `NULL` | con datos | Subido antes del cambio | El BLOB, como hasta hoy |
| `NULL` | `NULL` | No tiene archivo | El estado "sin foto" o "sin PDF" |

Cuando el hub guarda una URL, **vacía el BLOB en la misma operación**, así que
nunca quedan las dos con datos.

---

## 3. Leer los manuales (lo que la app consume)

### Si la app lee la tabla con su propio paquete

Hay que devolver la URL además del indicador de siempre. El mismo criterio del
hub (`db/manuales.sql`, `LISTAR`):

```sql
SELECT JSON_OBJECT(
         'id'           VALUE m.ID_MANUAL,
         'grado'        VALUE TRIM(m.GRADO),
         -- La de Cloudinary, sólo si es https: termina en un <a href>.
         'archivoUrl'   VALUE CASE
                                WHEN LOWER(SUBSTR(m.ARCHIVO_URL, 1, 8)) = 'https://'
                                THEN m.ARCHIVO_URL
                              END,
         -- True con cualquiera de las dos.
         'tieneArchivo' VALUE CASE
                                WHEN LOWER(SUBSTR(m.ARCHIVO_URL, 1, 8)) = 'https://' THEN 'true'
                                WHEN m.ARCHIVO_PDF IS NOT NULL
                                 AND DBMS_LOB.GETLENGTH(m.ARCHIVO_PDF) > 0 THEN 'true'
                                ELSE 'false'
                              END FORMAT JSON,
         'bytesArchivo' VALUE CASE
                                WHEN m.ARCHIVO_URL IS NOT NULL THEN NVL(m.ARCHIVO_BYTES, 0)
                                ELSE NVL(DBMS_LOB.GETLENGTH(m.ARCHIVO_PDF), 0)
                              END
         RETURNING CLOB)
  FROM MANUALES m ...
```

**Ojo con el filtro "tiene PDF":** si la app hoy filtra con
`WHERE ARCHIVO_PDF IS NOT NULL`, los manuales nuevos desaparecen de la lista
sin ningún error. Tiene que ser:

```sql
WHERE (m.ARCHIVO_URL IS NOT NULL
       OR (m.ARCHIVO_PDF IS NOT NULL AND DBMS_LOB.GETLENGTH(m.ARCHIVO_PDF) > 0))
```

### Si la app abre el PDF con la URL del hub

`GET https://oracleapex.com/ords/ctell/manuales/archivo/:id` **sigue
publicado, pero sólo sirve los PDF viejos**. Para uno nuevo devuelve **404**.

Para abrir un manual:

```ts
const url = manual.archivoUrl ?? `${BASE_URL}/manuales/archivo/${manual.id}`;
```

Las dos URL son públicas y no llevan token. Se abren igual: en el visor del
sistema, en un navegador o en una WebView.

### Si los PDF de Cloudinary no abren (401)

El plan gratuito de Cloudinary **bloquea la entrega de PDF por defecto**. Se
habilita una vez, en el panel: **Settings → Security → Allow delivery of PDF
and ZIP files**. No es un cambio de la app.

---

## 4. Fotos de profesores

### Mostrarlas

Mismo criterio: primero la URL, después el BLOB.

```sql
'fotoUrl'   VALUE CASE WHEN LOWER(SUBSTR(p.FOTO_URL, 1, 8)) = 'https://' THEN p.FOTO_URL END,
'tieneFoto' VALUE CASE
                    WHEN LOWER(SUBSTR(p.FOTO_URL, 1, 8)) = 'https://' THEN 'true'
                    WHEN p.FOTO IS NOT NULL AND DBMS_LOB.GETLENGTH(p.FOTO) > 0 THEN 'true'
                    ELSE 'false'
                  END FORMAT JSON
```

```ts
const src = profesor.fotoUrl
  ? miniatura(profesor.fotoUrl, 80) // ver sección 6
  : profesor.tieneFoto
    ? `${BASE_URL}/profesores/foto/${profesor.id}` // la vieja, en la base
    : null; // sin foto: iniciales o ícono
```

### Subirlas (sólo si la app permite cambiar la foto)

**El endpoint viejo `PUT /profesores/foto/:id` ya no existe** y devuelve 404:
se retiró a propósito para que nadie vuelva a meter binarios en la base. Si la
app lo usaba, hay que cambiarlo así:

1. Achicar la foto en el teléfono (sección 5).
2. Subirla a Cloudinary (sección 6), en la carpeta `profesores`.
3. Anotar la URL en la base, con una de estas dos opciones:

**Opción A: con el paquete propio de la app (recomendada).** Es como la app ya
hace el resto de sus escrituras, y no depende de que el módulo `profesores` del
hub tenga habilitado el origen de la app en CORS.

```sql
DECLARE
  l_anterior PROFESORES.FOTO_URL%TYPE;
BEGIN
  -- FOR UPDATE: dos subidas a la vez leerían la misma anterior y una quedaría
  -- huérfana en Cloudinary.
  SELECT FOTO_URL INTO l_anterior
    FROM PROFESORES
   WHERE ID_PROFESOR = l_id_profesor
     FOR UPDATE;

  UPDATE PROFESORES
     SET FOTO_URL            = l_url,   -- validada: empieza con https:// y <= 500
         FOTO                = NULL,    -- libera el BLOB viejo
         FOTO_MIME           = NULL,
         FECHA_ACTUALIZACION = SYSTIMESTAMP
   WHERE ID_PROFESOR = l_id_profesor;

  COMMIT;

  -- Recién después del COMMIT. Nunca lanza: si Cloudinary falla, el archivo
  -- viejo queda huérfano pero la operación ya está hecha.
  IF l_anterior IS NOT NULL AND l_anterior != l_url THEN
    PKG_CLOUDINARY.BORRAR(l_anterior);
  END IF;
END;
```

**Opción B: con el endpoint del hub.**
`PUT /profesores/foto-url/:id` con el body `{ "idEmpresa": n, "fotoUrl": "https://…" }`
y `Authorization: Bearer <token>`. Hace lo mismo que la opción A. Necesita que
el origen de la app esté en `ORIGINS_ALLOWED` del módulo `profesores`, que
cambia cada vez que el hub vuelve a ejecutar `db/profesores.sql`.

**Validar siempre que la URL empiece con `https://`** antes de guardarla:
termina en un `<img src>`, y sin esa comprobación un `javascript:…` se guarda
igual.

---

## 5. Achicar las fotos antes de subir

Una foto de celular pesa entre 4 y 8 MB, y en pantalla nadie ve esos píxeles.
Estos son los valores del hub:

| Qué | Recorte | Lado mayor | Peso objetivo |
| --- | ------- | ---------- | ------------- |
| Foto de profesor | Cuadrada, del centro | 800 px | ≤ 300 KB |
| Evidencia de reporte | **Sin recortar** | 1600 px | ≤ 500 KB |

Salida en JPEG, bajando la calidad de a pasos (0,9 → 0,82 → 0,74 → 0,66) hasta
entrar en el peso. Si la app es web (React, Capacitor, una WebView), se puede
copiar tal cual `src/lib/imagen.ts` del hub (`optimizarImagen`):

```ts
// Profesor
await optimizarImagen(archivo, { maxLado: 800, maxBytes: 300 * 1024, cuadrada: true });

// Evidencia de reporte: sólo JPEG, PNG y WebP. Un GIF perdería la animación y
// HEIC no siempre se puede decodificar. Si falla, se sube la original: mejor
// una evidencia pesada que ninguna.
async function prepararEvidencia(archivo: File): Promise<File> {
  if (!/^image\/(jpeg|png|webp)$/.test(archivo.type)) return archivo;
  try {
    return await optimizarImagen(archivo, { maxLado: 1600, maxBytes: 500 * 1024 });
  } catch {
    return archivo;
  }
}
```

Si la app es nativa (Kotlin o Flutter), el equivalente es redimensionar el
bitmap y comprimirlo a JPEG con esos mismos valores. **Respetar la orientación
EXIF**: sin eso, las fotos de cámara salen giradas.

**Videos y PDF no se tocan:** un PDF no se recomprime sin destruirlo.

---

## 6. Subir a Cloudinary

Misma cuenta y mismo preset que el hub. **Los dos valores son públicos por
diseño** y van en la app:

| Dato | Valor |
| ---- | ----- |
| Cloud name | `cayve9bx` |
| Upload preset (unsigned) | `reportes_ctell` |

**La `api_secret` NUNCA va en la app.** Una APK se descompila. Borrar archivos
lo hace Oracle con `PKG_CLOUDINARY.BORRAR`, que lee la clave de
`CLOUDINARY_CONFIG`.

```ts
async function subirACloudinary(archivo: File, carpeta: string, prefijo: string) {
  const datos = new FormData();
  datos.append("file", archivo);
  datos.append("upload_preset", "reportes_ctell");
  // El public_id lo manda la app, SIEMPRE único. Si dos celulares suben
  // "IMG_0001.jpg" con el mismo id, Cloudinary responde 200 con la URL de la
  // primera foto, sin subir la segunda y sin ningún error.
  datos.append("public_id", `${sanear(prefijo)}-${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`);
  datos.append("folder", carpeta); // "profesores", "manuales" o "reportes-actividades"

  const r = await fetch("https://api.cloudinary.com/v1_1/cayve9bx/auto/upload", {
    method: "POST",
    body: datos,
  });
  if (!r.ok) {
    const e = await r.json().catch(() => null);
    throw new Error(e?.error?.message ?? "No se pudo subir el archivo");
  }
  const subido = await r.json();
  return { url: subido.secure_url as string, bytes: subido.bytes as number };
}

/** Sin tildes, sin espacios, sin "/" ni ",": rompen la URL de Cloudinary. */
const sanear = (t: string) =>
  t.normalize("NFD").replace(/\p{Diacritic}/gu, "").replace(/[^a-zA-Z0-9]+/g, "-")
   .replace(/^-+|-+$/g, "").slice(0, 60);
```

- **`secure_url`, no `url`**: la otra viene en http, y el backend exige https.
- **Primero se sube, después se guarda la fila.** Si la subida anda y el
  guardado falla, el archivo queda huérfano en Cloudinary, que es preferible a
  una fila con una URL que no existe.
- **Miniaturas:** se piden transformando la URL, sin subir otra copia.
  `…/upload/c_fill,w_80,h_80,q_auto,f_auto/…` (igual que `miniatura()` en
  `src/lib/cloudinary.ts` del hub).
- **Límite del plan gratuito: 10 MB por archivo.** Un PDF más pesado lo
  rechaza Cloudinary con un mensaje que conviene mostrar tal cual.

---

## 7. Evidencias de reportes

`REPORTES_MULTIMEDIA` no cambió: sigue guardando la URL. Hay dos mejoras
opcionales que no rompen nada:

1. **Achicar las fotos** antes de subir (sección 5). Las que ya están subidas
   quedan como están.
2. **Borrar el archivo al borrar la fila.** Hoy la app borra la fila y deja el
   archivo en Cloudinary. Ahora puede hacer lo mismo que el hub:

   ```sql
   DELETE FROM REPORTES_MULTIMEDIA WHERE ID_MULTIMEDIA = l_id
   RETURNING URL_ARCHIVO INTO l_url;
   COMMIT;
   PKG_CLOUDINARY.BORRAR(l_url);   -- después del COMMIT; nunca lanza
   ```

`PKG_CLOUDINARY.BORRAR` sólo toca URL de la cuenta `cayve9bx`: una URL de otro
lado (o `NULL`) se ignora sin error.

---

## 8. Orden para no romper nada

1. **El hub ejecuta** `db/cloudinary.sql`, `db/profesores.sql` y
   `db/manuales.sql`. Eso crea las columnas. Las filas viejas no cambian.
2. **La app pasa a leer URL y después BLOB** (secciones 3 y 4). Este cambio es
   compatible hacia atrás: con datos viejos se comporta exactamente igual que hoy.
3. **Publicar la versión nueva de la APK.**
4. Recién entonces, si la app sube fotos de profesores, cambiar la subida
   (sección 4).

**El riesgo real son las APK viejas instaladas en los teléfonos.** No ven los
manuales que se suban desde el hub después del cambio, y si suben la foto del
profesor reciben un 404. Mientras no se actualicen todas, conviene avisar a los
profesores que actualicen la app.

---

## 9. Checklist

- [ ] Ninguna consulta de la app filtra sólo por `ARCHIVO_PDF IS NOT NULL` o `FOTO IS NOT NULL`.
- [ ] El listado de manuales devuelve `archivoUrl` y la app la usa primero.
- [ ] Un manual viejo (con BLOB) y uno nuevo (con URL) abren los dos.
- [ ] La foto de un profesor viejo y la de uno nuevo se ven las dos.
- [ ] La app no llama a `PUT /profesores/foto/:id` ni a `PUT /manuales/archivo/:id`.
- [ ] Toda URL que se guarda empieza con `https://`.
- [ ] Cada subida manda un `public_id` único.
- [ ] La `api_secret` no aparece en ningún archivo de la app.
- [ ] Las fotos se achican antes de subir y salen derechas (EXIF).
- [ ] El paquete de la app compila `VALID` después de que el hub agregó las columnas:

```sql
SELECT OBJECT_NAME, STATUS FROM USER_OBJECTS WHERE STATUS = 'INVALID';
```
