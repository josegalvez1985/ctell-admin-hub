# Guía: backup por correo de Ctell

Genera todos los días una copia del esquema de Ctell en scripts SQL comprimidos (estructura, endpoints,
datos y archivos) y la manda por correo. El código está en [db/backup-ddl.sql](db/backup-ddl.sql) y
[db/backup.sql](db/backup.sql).

> **Estado al 06/11/2026: todavía no está probado.** El código no se compiló ni se ejecutó en Oracle.
> Tampoco están probados el envío de adjuntos, la exportación de ORDS ni una restauración. Hacer las
> pruebas de las secciones 4 y 5 antes de confiar en la copia.

## 0. Cómo funciona

```
JOB_BACKUP_CTELL (todos los días, 03:00 de Paraguay)
   │
   ▼
ejecutar ─ anota la corrida en CTELL_BACKUP_LOG
   │       arma la lista de lo que hay que copiar en CTELL_BACKUP_TAREA
   ▼
tramo ──── hace tareas hasta usar el 60 % de CPU_PER_CALL
   │       cierra la parte: .sql → .zip → correo (APEX_MAIL)
   ▼
¿Faltan tareas?
   ├─ sí → crea un job BACKUP_TRAMO_* → continuar(id) → otro tramo
   └─ no → registra OK o CON ERRORES → correo de resumen
```

- **Partes numeradas, en orden de restauración:** `estructura`, `ords`, `datos` y `archivos`. Se llaman
  `ctell_2026-11-07_01_estructura.zip`.
- **El resumen es la señal:** si no llegó, la corrida no terminó. Si dice `CON ERRORES`, la copia no
  está completa. Un `AVISO` en el detalle no la invalida.
- **Por qué en tramos:** una instancia puede limitar la CPU por llamada y un job entero cuenta como una
  sola llamada.

## 1. Antes de empezar

Ejecutar en SQL Commands, como dueño del esquema:

```sql
-- Hacen falta CREATE TABLE, CREATE PROCEDURE y CREATE JOB
SELECT privilege FROM session_privs
 WHERE privilege IN ('CREATE TABLE', 'CREATE PROCEDURE', 'CREATE JOB');

-- El límite de CPU, en centésimas de segundo (120000 = 20 minutos)
SELECT resource_name, "LIMIT" FROM user_resource_limits
 WHERE resource_name IN ('CPU_PER_CALL', 'CPU_PER_SESSION', 'LOGICAL_READS_PER_CALL');

-- Cuánto ocupa el esquema. La cuota son 25 MB: si está lleno, crear las tablas falla con ORA-01536
SELECT ROUND(SUM(bytes) / 1048576, 1) AS mb FROM user_segments;
```

- **`CPU_PER_CALL`:** si es un número, cada tramo usa el 60 %. Si dice `UNLIMITED` o `DEFAULT`, usa 5
  minutos de CPU. Si fuera necesario, se fija a mano con `CPU_SEG`.
- **`CPU_PER_SESSION` o `LOGICAL_READS_PER_CALL` con número:** el paquete no los controla. Si cortan la
  corrida, hay que bajar `CPU_SEG` o revisarlo.
- **Casilla:** usar una solo del dueño, con verificación en dos pasos. Los adjuntos van **sin cifrar**,
  con todos los datos del negocio.

## 2. Qué se copia y qué no

| Qué | Cómo viaja | Dónde se ajusta |
|---|---|---|
| Datos de `IA_*`, `TOKENS`, `CLOUDINARY_CONFIG` y `CTELL_BACKUP_*` | Solo la estructura, sin datos | `c_sin_datos` |
| `USUARIOS.CONTRASENA_HASH` y `SALT` | Con el valor `X`, que no coincide con ningún hash | `c_col_secreta` |
| Otras columnas con `PASSWORD`, `PASSWD`, `API_KEY`, `APIKEY`, `TOKEN` o `SECRET` en el nombre | Vacías, o con `X` si son `NOT NULL` | `c_col_secreta` |
| BLOB: logos, fotos de denominación y lo anterior a Cloudinary | En hexadecimal, en las partes `archivos` | Tarea `ARCHIVO` en `armar_tareas` |
| Fotos de artículos y profesores, evidencias y manuales en Cloudinary | **Solo la URL, no el archivo** | No lo cubre esta copia |

- **Una tabla nueva con secretos va en dos listas:** `c_sin_datos` de `db/backup.sql` y `ES_PRIVADA` de
  `db/asistente.sql`.
- **Una clave en una columna con otro nombre viaja por correo.** Revisarlo al instalar y cada tanto. La
  app del profesor escribe en este mismo esquema, así que puede haber columnas que `db/` no muestra:
  ```sql
  SELECT table_name, column_name FROM user_tab_cols
   WHERE REGEXP_LIKE(column_name, 'CLAVE|PASS|KEY|TOKEN|SECRET|CREDENCIAL|HASH|SALT|PIN', 'i')
   ORDER BY 1, 2;
  ```
- **Una clave escrita en el código de un paquete también viaja**, porque la estructura copia el código
  fuente. En este proyecto las claves viven en `IA_CONFIG` y `CLOUDINARY_CONFIG`, y así tiene que seguir.
- **Un BLOB necesita una clave primaria numérica.** Si su tabla no la tiene, no se copia y el resumen
  queda `CON ERRORES`. Para ver qué columnas son:
  ```sql
  SELECT table_name, column_name FROM user_tab_cols WHERE data_type = 'BLOB' ORDER BY 1, 2;
  ```

## 3. Instalar

Frenar `npm run dev` y ejecutar en SQL Workshop → SQL Scripts, en este orden. `auth.sql` ya tiene que
estar ejecutado.

1. `db/backup-ddl.sql`, una sola vez. Crea las tablas.
2. `db/backup.sql`, completo. Se puede volver a ejecutar.
3. `db/asistente.sql`, para que las tablas `CTELL_BACKUP_*` queden privadas para la IA.
4. Revisar la salida de `db/backup.sql`: el paquete tiene que estar `VALID` y `USER_ERRORS` sin filas.
5. Cargar la casilla. **No escribirla en el archivo, porque se sube al repositorio:**
   ```sql
   BEGIN PKG_BACKUP_CTELL.fijar_destino('la casilla'); END;
   ```

El remitente queda vacío a propósito: lo resuelve APEX, porque el free tier solo acepta como origen la
casilla del dueño del workspace (ver `db/auth.sql`).

El script deja el job encendido y arranca a las 03:00 siguientes (si se instala entre medianoche y las
03:00, a las de la madrugada siguiente). Hay que terminar las pruebas de la sección 4 antes de esa hora o
dejarlo apagado mientras tanto:

```sql
BEGIN DBMS_SCHEDULER.DISABLE('JOB_BACKUP_CTELL'); END;
-- y al terminar las pruebas:
BEGIN DBMS_SCHEDULER.ENABLE('JOB_BACKUP_CTELL'); END;
```

Volver a ejecutar `db/backup.sql` crea el job de nuevo y lo deja encendido.

## 4. Probar la corrida

Hacerlo en este orden.

```sql
-- 1. ¿Llega un correo con adjunto? Tiene que traer prueba.zip
BEGIN PKG_BACKUP_CTELL.probar_correo; END;

-- 2. ¿Termina? Genera todo y no manda nada: mide cuánto tarda y pesa, y no deja archivos
BEGIN PKG_BACKUP_CTELL.lanzar(p_enviar => FALSE); END;

-- 3. Ver el avance. PASO_EN tiene que seguir cambiando
SELECT estado, paso, paso_en, partes, tablas, filas, errores, bytes_zip, detalle
  FROM ctell_backup_log ORDER BY id DESC;

-- 4. Recién con lo anterior bien, una copia real con sus correos
BEGIN PKG_BACKUP_CTELL.lanzar; END;
```

Si el correo no llega, usar `db/diagnostico-correo.sql` y mirar la cola:

```sql
SELECT id, mail_subj, mail_send_count, mail_send_error FROM apex_mail_queue;
SELECT * FROM apex_mail_log;
```

## 5. Comprobar la copia

Solo el último nivel prueba que sirve. Hacer la prueba sin nadie cargando datos: las tablas no se leen
todas en el mismo instante.

**Nivel 1: terminó bien.** `estado = OK` y `errores = 0` en `ctell_backup_log`.

**Nivel 2: llegó completa.**

1. Tienen que llegar el resumen y tantas partes como diga `partes`, con los números seguidos. Abrir cada
   `.zip`.
2. Este total tiene que ser igual a `filas`:
   ```sql
   SELECT SUM(TO_NUMBER(EXTRACTVALUE(XMLTYPE(DBMS_XMLGEN.GETXML(
            'SELECT COUNT(*) c FROM "' || table_name || '"')), '/ROWSET/ROW/C'))) AS filas
     FROM user_tables
    WHERE temporary = 'N' AND table_name NOT LIKE '%$%'
      AND NOT REGEXP_LIKE(table_name, '^(CTELL_BACKUP_|IA_|TOKENS$|CLOUDINARY_CONFIG$)');
   ```
3. Con todo descomprimido en una carpeta, en PowerShell:
   ```powershell
   # Tiene que dar lo mismo que "filas"
   (Select-String -Path *_datos.sql -Pattern '^INSERT INTO').Count
   # Solo puede mostrar la línea de ORDS, si esa exportación falló
   Select-String -Path *.sql -Pattern '^-- (ERROR en|NO SE PUDO)'
   ```
4. El detalle del resumen dice cuántos archivos salieron de cada columna (`Archivos de EMPRESAS.LOGO: 2`,
   por ejemplo). Tiene que coincidir con las filas que tienen archivo en esa tabla.

**Nivel 3: se puede restaurar.** Seguir la sección 6 en una base aparte, **nunca en producción**, y
comparar las dos bases con la consulta de filas de arriba y con esta:

```sql
SELECT object_type, status, COUNT(*) FROM user_objects
 WHERE generated = 'N' AND object_name NOT LIKE '%$%'
   AND object_name NOT LIKE 'BACKUP_MANUAL%' AND object_name NOT LIKE 'BACKUP_TRAMO%'
 GROUP BY object_type, status ORDER BY 1, 2;
```

Oracle Database Free en una PC alcanza para probar tablas, datos, paquetes y archivos. Para probar
también los endpoints hace falta una base con APEX y ORDS.

## 6. Restaurar

1. Crear el esquema en una base con APEX y ORDS, o sin ellos si solo interesan los datos.
2. Descomprimir los `.zip` de **un mismo día** y correr los `.sql` en orden de número, con SQLcl o
   SQL*Plus. Guardar la salida, porque los scripts siguen aunque haya errores:
   ```sql
   SPOOL restauracion.log
   @ctell_2026-11-07_01_estructura.sql
   -- ...y las demás partes, en orden
   SPOOL OFF
   ```
3. Buscar `ORA-` en `restauracion.log`. La primera parte de `datos` apaga FK y triggers, y la última de
   `archivos` los vuelve a prender y ajusta los identity. Sin esto, cargar un conteo cerrado volvería a
   ajustar `EXISTENCIAS`.
4. Si faltan endpoints, porque la exportación de ORDS no vino o falló, volver a correr los `db/` del repo.
5. Volver a cargar lo que no viaja:
   ```sql
   BEGIN PKG_ASISTENTE.FIJAR_CLAVE('sk-ant-...'); END;
   -- PKG_CLOUDINARY.FIJAR_CREDENCIALES, con los datos de la cuenta
   BEGIN PKG_BACKUP_CTELL.fijar_destino('la casilla'); END;
   ```
   También los GRANT y los permisos de red.
6. **Nadie puede entrar hasta recuperar su clave.** `POST /auth/recuperar` la manda por correo, así que
   `APEX_MAIL` tiene que estar funcionando en la base nueva (`PKG_AUTH.PROBAR_CORREO`).
7. Publicar el frontend desde el repo. Si cambió la URL de ORDS, ajustar `BASE_URL` en `src/lib/api.ts` y
   los orígenes permitidos de cada módulo.

## 7. Operación

**Configuración**, en `CTELL_BACKUP_CONFIG`, con `UPDATE` + `COMMIT` y sin ejecutar el script:

| Clave | Qué es |
|---|---|
| `DESTINO` | La casilla (con `fijar_destino`) |
| `REMITENTE` | El "De:" del correo. Vacío, lo resuelve APEX |
| `PARTE_MB` | Tamaño de cada `.sql` antes de comprimir (20). Bajarlo si rechazan los adjuntos |
| `CPU_SEG` | Opcional: segundos de CPU por tramo. Sin esto, el 60 % de `CPU_PER_CALL` |

**Si queda `EN CURSO` mucho tiempo:** ese estado no prueba que siga corriendo.

```sql
-- Si sale una fila, hay un tramo corriendo o por arrancar. Si no sale nada, la corrida murió
SELECT job_name, state FROM user_scheduler_jobs
 WHERE job_name LIKE 'BACKUP_MANUAL%' OR job_name LIKE 'BACKUP_TRAMO%';

-- Por qué terminó cada job
SELECT job_name, status, actual_start_date, run_duration, errors
  FROM user_scheduler_job_run_details
 WHERE job_name = 'JOB_BACKUP_CTELL' OR job_name LIKE 'BACKUP_MANUAL%' OR job_name LIKE 'BACKUP_TRAMO%'
 ORDER BY actual_start_date DESC;

-- Detener una corrida, con el JOB_NAME de la primera consulta
BEGIN DBMS_SCHEDULER.STOP_JOB('<job_name>'); END;
```

- **Antes de volver a ejecutar `db/backup.sql`, detener la corrida:** reemplazar el paquete mientras se
  usa deja el script esperando. Y frenar `npm run dev`, como con cualquier archivo de `db/`.
- **Una corrida muerta** queda `INTERRUMPIDA` cuando arranca la siguiente.
- **El registro se purga solo:** las corridas de más de 90 días se borran, por la cuota de 25 MB.
- **Cambiar el horario:** cambiar `BYHOUR` con `DBMS_SCHEDULER.SET_ATTRIBUTE` y dejarlo también en
  `db/backup.sql`, o la próxima ejecución lo pisa.
- **Revisar los correos cada tanto:** un día sin resumen es un día sin copia, y nada más avisa.

## 8. Lo que ya falló

Esto pasó en otro proyecto con esta misma copia, en `oracleapex.com`, y el código ya lo contempla:

- **`ORA-02393` (límite de CPU por llamada):** `CPU_PER_CALL` es de 20 minutos y `DBMS_METADATA` consume
  mucho. Un solo job se cortó a los 22 minutos, sin terminar la estructura.
- **Una corrida muerta no registra nada:** pasado el límite, en esa llamada también fallan el registro y
  los `EXCEPTION`. Por eso el avance se anota mientras corre y se para antes de llegar al límite.
- **`SUBSTR(x, 1, 3900)` en un `VARCHAR2(3900)`:** corta caracteres y la variable mide bytes. Con acentos
  da `ORA-06502` y tapa el error real. Usar `SUBSTRB`.
- **`WHEN OTHERS` en un bucle:** si se traga la cancelación o el límite, cada objeto siguiente falla igual
  y el detalle se llena. `ORA-01013`, `ORA-00040`, `ORA-00028` y `ORA-02393` se vuelven a lanzar.
- **`ORA-00942` al crear la tabla:** una tabla creada en un bloque no se puede usar con SQL estático en
  ese mismo bloque, y Oracle no crea nada. Usar `EXECUTE IMMEDIATE`.
- **`PLS-00231`:** una función privada del paquete no se puede usar dentro de SQL. Pasarla antes a una
  variable.

## 9. Límites conocidos

- **No cubre Cloudinary:** perder esa cuenta pierde las fotos, las evidencias y los manuales, aunque la
  base esté restaurada.
- **No es una foto única:** una transacción de solo lectura no cruza de un job a otro. Si alguien carga
  datos durante la copia, una venta puede quedar sin su detalle. Por eso corre de madrugada.
- **Copia solo el esquema propio:** no lleva los GRANT sobre objetos ni objetos de otros esquemas.
- **No exporta APEX:** este workspace no tiene aplicaciones (el frontend es React), y el export del
  workspace lleva hashes y solo lo importa un administrador de instancia.
- **Tipos no soportados:** `LONG`, `XMLTYPE`, `JSON` y otros no se copian. El resumen los lista y queda
  `CON ERRORES`.
- **Tamaño del correo:** una parte de más de 18 MB comprimidos se avisa en el resumen, porque puede
  rebotar. Oracle y la casilla pueden tener topes propios, y no están comprobados.
- **Un objeto que supere él solo el margen del tramo corta la corrida:** queda sin resumen y el motivo
  aparece en `user_scheduler_job_run_details`.
