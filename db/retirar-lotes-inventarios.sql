--------------------------------------------------------------------------------
-- CTELL · RETIRAR LOTES E INVENTARIOS
--
-- Limpieza posterior al DROP de la tabla LOTES. Se ejecuta UNA vez en la hoja de
-- trabajo SQL de APEX y despues este archivo se puede borrar del repo.
--
-- QUE PASO. El stock por lotes se discontinuo: no se puede hacer un conteo
-- fisico por partida —en el estante las unidades son identicas— y el punto de
-- venta obligaba a elegir de que lote salia cada linea. La tabla LOTES se
-- elimino, y con ella quedaron colgando cuatro cosas que el DROP no se lleva.
--
-- QUE HAY QUE LIMPIAR, Y POR QUE CADA UNA:
--
--   1. LOS MODULOS ORDS 'lotes' e 'inventarios'. Siguen PUBLICADOS y apuntando a
--      PKG_LOTES y PKG_INVENTARIOS. Un handler que llama a un paquete que ya no
--      existe responde 500, no 404: para el cliente parece un servidor roto.
--
--   2. LOS PAQUETES PKG_LOTES y PKG_INVENTARIOS. Sus archivos se fueron del
--      repo, pero en la base siguen compilados —INVALID, porque consultan una
--      tabla que ya no esta—.
--
--   3. LOS TRIGGERS DE INVENTARIOS. Es el mas urgente de los cuatro:
--      TRG_INVENTARIOS_AU ajusta LOTES al procesar un conteo, asi que quedo
--      INVALID, y UN TRIGGER INVALID BLOQUEA TODO INSERT Y UPDATE de su tabla.
--      Mientras siga ahi, INVENTARIOS no acepta ni una fila — ni siquiera para
--      corregirla o anularla.
--
--   4. LAS PAGINAS del menu (/lotes y /inventarios). Son DATOS, no DDL: viven en
--      la tabla PAGINAS y hay que borrarlas a mano. Ojo con el orden — desde el
--      ultimo cambio, PKG_PAGINAS.ELIMINAR se niega a borrar una pagina que
--      algun usuario tenga asignada, asi que primero se quitan los permisos.
--
-- LA TABLA INVENTARIOS NO SE TOCA ACA. El DDL se administra aparte y borrar
-- conteos historicos es una decision, no una consecuencia: su columna ID_LOTE ya
-- apunta a una tabla que no existe, y las filas que haya son evidencia de
-- conteos que alguien hizo. Si se decide eliminarla, va con su propio DROP.
--
-- QUE VIENE DESPUES. Una cantidad unica por articulo y sucursal (EXISTENCIAS)
-- con costo promedio ponderado movil, mas su libro de movimientos. Hasta
-- entonces NADA mueve stock: comprar no ingresa, vender no descuenta,
-- /articulos/listar devuelve cantidadStock en 0 y el dashboard muestra el valor
-- de stock en cero con el stock critico vacio.
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. Los modulos ORDS
--
-- Con SELECT previo y no capturando el error de "no existe": asi el EXCEPTION
-- queda libre para los fallos que si importan. Es el mismo BORRAR_MODULO que
-- usan todos los paquetes del proyecto, sin los reintentos —aca no hay un
-- DEFINE_MODULE despues que pueda chocar—.
--
-- FRENA `npm run dev` ANTES DE EJECUTAR: la sesion de desarrollo mantiene
-- tomadas filas de metadatos que DELETE_MODULE necesita, y sin eso sale
-- ORA-00060 y el modulo viejo sigue publicado.
--------------------------------------------------------------------------------

DECLARE
  l_existe PLS_INTEGER;
BEGIN
  FOR modulo IN (SELECT COLUMN_VALUE AS nombre
                   FROM TABLE(SYS.ODCIVARCHAR2LIST('lotes', 'inventarios'))) LOOP
    SELECT COUNT(*) INTO l_existe
      FROM USER_ORDS_MODULES
     WHERE NAME = modulo.nombre;

    IF l_existe > 0 THEN
      ORDS.DELETE_MODULE(p_module_name => modulo.nombre);
      DBMS_OUTPUT.PUT_LINE('Modulo ORDS eliminado: ' || modulo.nombre);
    ELSE
      DBMS_OUTPUT.PUT_LINE('No existia el modulo: ' || modulo.nombre);
    END IF;
  END LOOP;
  COMMIT;
END;
/

--------------------------------------------------------------------------------
-- 2. Los paquetes
--
-- El EXCEPTION mira ORA-04043 ("objeto no existe") y sigue: reejecutar este
-- archivo no tiene que fallar por algo que ya se limpio.
--------------------------------------------------------------------------------

BEGIN
  FOR paquete IN (SELECT COLUMN_VALUE AS nombre
                    FROM TABLE(SYS.ODCIVARCHAR2LIST('PKG_LOTES', 'PKG_INVENTARIOS'))) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP PACKAGE ' || paquete.nombre;
      DBMS_OUTPUT.PUT_LINE('Paquete eliminado: ' || paquete.nombre);
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE = -4043 THEN
          DBMS_OUTPUT.PUT_LINE('No existia el paquete: ' || paquete.nombre);
        ELSE
          RAISE;
        END IF;
    END;
  END LOOP;
END;
/

--------------------------------------------------------------------------------
-- 3. Los triggers de INVENTARIOS
--
-- LOS TRES, no solo el que toca LOTES:
--
--   TRG_INVENTARIOS_AU  ajustaba LOTES.CANTIDAD_DISPON al procesar. Es el que
--                       quedo INVALID y bloquea la tabla entera.
--   TRG_INVENTARIOS_BIU forzaba ESTADO='ABIERTO' e imponia la maquina de
--                       estados. Sin modulo que la use, no protege nada.
--   TRG_INVENTARIOS_BD  prohibia el DELETE ("use ANULAR"). Con el modulo
--                       retirado, deja la tabla sin forma de limpiarse.
--
-- Se buscan por nombre en USER_TRIGGERS: si el DDL los llamo distinto, esta
-- consulta los lista y hay que ajustar la lista de arriba.
--------------------------------------------------------------------------------

BEGIN
  FOR trg IN (SELECT TRIGGER_NAME
                FROM USER_TRIGGERS
               WHERE TABLE_NAME = 'INVENTARIOS') LOOP
    EXECUTE IMMEDIATE 'DROP TRIGGER ' || trg.TRIGGER_NAME;
    DBMS_OUTPUT.PUT_LINE('Trigger eliminado: ' || trg.TRIGGER_NAME);
  END LOOP;
END;
/

--------------------------------------------------------------------------------
-- 4. Las paginas del menu
--
-- PRIMERO LOS PERMISOS Y DESPUES LA PAGINA. USUARIO_PAGINAS tiene FK contra
-- PAGINAS, asi que al reves da ORA-02292 — y ademas PKG_PAGINAS.ELIMINAR se
-- niega, con un 409, a borrar una pagina que alguien tenga asignada.
--
-- La ruta se compara normalizada (minusculas, barra inicial, sin barra final),
-- que es como la guarda PKG_PAGINAS.
--------------------------------------------------------------------------------

DECLARE
  l_permisos PLS_INTEGER;
  l_paginas  PLS_INTEGER;
BEGIN
  DELETE FROM USUARIO_PAGINAS
   WHERE ID_PAGINA IN (SELECT ID_PAGINA FROM PAGINAS
                        WHERE LOWER(RUTA) IN ('/lotes', '/inventarios'));
  l_permisos := SQL%ROWCOUNT;

  DELETE FROM PAGINAS
   WHERE LOWER(RUTA) IN ('/lotes', '/inventarios');
  l_paginas := SQL%ROWCOUNT;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Permisos borrados: ' || l_permisos ||
                       ' | Paginas borradas: ' || l_paginas);
END;
/

--------------------------------------------------------------------------------
-- 5. Verificacion
--------------------------------------------------------------------------------

-- Nada de esto tiene que devolver filas.
SELECT NAME AS MODULO_ORDS_QUE_QUEDO
  FROM USER_ORDS_MODULES
 WHERE NAME IN ('lotes', 'inventarios');

SELECT OBJECT_NAME, OBJECT_TYPE
  FROM USER_OBJECTS
 WHERE OBJECT_NAME IN ('PKG_LOTES', 'PKG_INVENTARIOS');

SELECT TRIGGER_NAME, STATUS
  FROM USER_TRIGGERS
 WHERE TABLE_NAME = 'INVENTARIOS';

SELECT ID_PAGINA, NOMBRE, RUTA
  FROM PAGINAS
 WHERE LOWER(RUTA) IN ('/lotes', '/inventarios');

-- Y NINGUN OBJETO INVALID. Es la consulta que de verdad importa: un paquete
-- INVALID da un 500 mudo —el WHEN OTHERS no captura errores de compilacion— asi
-- que si aparece algo aca, ese modulo esta caido y todavia no se sabe.
--
-- Los que pueden aparecer por este cambio son PKG_ARTICULOS y PKG_DASHBOARD, que
-- consultaban LOTES: se corrigieron en db/articulos.sql y db/dashboard.sql, pero
-- hay que REEJECUTAR esos dos archivos para que la base lo sepa.
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE STATUS = 'INVALID'
 ORDER BY OBJECT_TYPE, OBJECT_NAME;

-- La tabla LOTES ya no tiene que estar. Cero filas.
SELECT TABLE_NAME FROM USER_TABLES WHERE TABLE_NAME = 'LOTES';

-- Y las columnas ID_LOTE de las tablas que sobreviven: en VENTAS_DETALLES y
-- FACTURAS_COMPRAS_DET no tienen que existir (el DDL nuevo no las declara).
-- INVENTARIOS.ID_LOTE puede seguir ahi —esa tabla no se toco— y es esperable.
SELECT TABLE_NAME, COLUMN_NAME, NULLABLE
  FROM USER_TAB_COLUMNS
 WHERE COLUMN_NAME = 'ID_LOTE'
 ORDER BY TABLE_NAME;
