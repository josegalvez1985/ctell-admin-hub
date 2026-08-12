# Implementación: Columna RUTA en PAGINAS

## Resumen
Se agregó la columna `RUTA` a la tabla `PAGINAS` para identificar qué componente/página del frontend debe cargarse. Esto permite que cada página tenga un path asociado (ej: `/compras/ordenes`) que se use en el menú dinámico.

## Pasos de implementación

### 1. Crear/Alterar la tabla PAGINAS (DDL)
Ejecutar en APEX → SQL Workshop → SQL Commands:

```sql
-- Si la tabla ya existe, agregar la columna
ALTER TABLE PAGINAS ADD (RUTA VARCHAR2(200) NOT NULL);

-- Si es la primera vez, crear la tabla completa:
CREATE TABLE PAGINAS (
  ID_PAGINA   NUMBER PRIMARY KEY,
  ID_MODULO   NUMBER NOT NULL REFERENCES MODULOS(ID_MODULO),
  NOMBRE      VARCHAR2(100) NOT NULL,
  RUTA        VARCHAR2(200) NOT NULL,
  ORDEN       NUMBER DEFAULT 0,
  ACTIVO      VARCHAR2(1) DEFAULT 'A' CHECK (ACTIVO IN ('A', 'I')),
  FECHA_CREACION TIMESTAMP DEFAULT SYSTIMESTAMP,
  CONSTRAINT FK_PAGINA_MODULO FOREIGN KEY (ID_MODULO) REFERENCES MODULOS(ID_MODULO)
);

CREATE SEQUENCE SEQ_PAGINAS START WITH 1 INCREMENT BY 1;

CREATE OR REPLACE TRIGGER PAGINAS_ID_BI
BEFORE INSERT ON PAGINAS
FOR EACH ROW
BEGIN
  IF :NEW.ID_PAGINA IS NULL THEN
    SELECT SEQ_PAGINAS.NEXTVAL INTO :NEW.ID_PAGINA FROM DUAL;
  END IF;
END;
/
```

### 2. Ejecutar db/paginas.sql
En APEX → SQL Workshop → SQL Commands, pegar y ejecutar el archivo:
```
c:\Users\josej\OneDrive\Desktop\Proyectos\ctell-admin-hub\db\paginas.sql
```

**IMPORTANTE:** Frenar `npm run dev` primero (ver CLAUDE.md punto "Reejecutar un archivo `db/`").

Este archivo contiene:
- `PKG_PAGINAS` actualizado con `p_ruta` en INSERTAR y ACTUALIZAR
- Los 4 endpoints ORDS actualizados:
  - `POST /paginas/crear` → espera `ruta` obligatorio
  - `PUT /paginas/actualizar/:id` → acepta `ruta` opcional
  - `GET /paginas/listar` → devuelve `ruta` en cada página
  - `DELETE /paginas/eliminar/:id` → sin cambios

### 3. Frontend ya está listo
Los cambios ya están implementados en:
- `src/lib/api.ts` → tipo `Pagina` incluye `ruta`, métodos actualizados
- `src/components/ctell/PaginasDialog.tsx` → formulario con campo `ruta`

No necesita rebuild especial; `npm run dev` ya lo detecta.

## Formato esperado para RUTA
Ejemplos válidos:
- `/compras/ordenes`
- `/ventas/facturas`
- `/stock/movimientos`
- `/tesoreria/caja`
- `/rrhh/empleados`
- `/reportes/ventas-diarias`

Nota: no incluir protocolo ni dominio, solo el path relativo desde la app.

## Verificación
1. Ejecutar en APEX:
   ```sql
   SELECT ID_PAGINA, NOMBRE, RUTA FROM PAGINAS;
   ```
   Debe devolver todas las páginas con su RUTA.

2. En el frontend, crear una página nueva desde `/administracion`:
   - Módulo: "Compras"
   - Nombre: "Órdenes"
   - Ruta: "/compras/ordenes"
   - Orden: 1
   
   Debe guardar sin error.

3. Asignar permisos desde `/administracion` → Permisos:
   - Usuario: admin
   - Página: Órdenes (bajo Compras)
   
   Verá la página con su RUTA en el listado de permisos.

## Rollback (si es necesario)
```sql
ALTER TABLE PAGINAS DROP COLUMN RUTA;
```

Luego ejecutar nuevamente `db/paginas.sql` con la versión anterior.
