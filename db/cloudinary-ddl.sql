--------------------------------------------------------------------------------
-- CTELL · CLOUDINARY_CONFIG
--
-- La tabla donde PKG_CLOUDINARY (db/cloudinary.sql) lee la cuenta de
-- Cloudinary: CLOUD_NAME, API_KEY y API_SECRET. Se ejecuta UNA VEZ, antes que
-- db/cloudinary.sql, y es idempotente: si la tabla ya existe no hace nada.
--
-- POR QUÉ UNA TABLA Y NO EL CÓDIGO: la API_SECRET firma el borrado de
-- cualquier archivo de la cuenta. En el repo la leería cualquiera con acceso,
-- y en el frontend cualquiera que abra el sitio. Se carga a mano con
-- PKG_CLOUDINARY.FIJAR_CREDENCIALES y no sale nunca de la base — igual que la
-- clave de la API de Claude en IA_CONFIG.
--
-- ES PRIVADA PARA EL ASISTENTE: figura en ES_PRIVADA de db/asistente.sql, así
-- la IA no la describe ni la puede consultar.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON

DECLARE
  l_existe PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_existe FROM USER_TABLES WHERE TABLE_NAME = 'CLOUDINARY_CONFIG';

  IF l_existe > 0 THEN
    DBMS_OUTPUT.PUT_LINE('[SKIP] La tabla CLOUDINARY_CONFIG ya existia.');
    RETURN;
  END IF;

  EXECUTE IMMEDIATE q'~
    CREATE TABLE CLOUDINARY_CONFIG (
      CLAVE         VARCHAR2(30)  NOT NULL,
      VALOR         VARCHAR2(200),
      MODIFICADO_EL DATE DEFAULT SYSDATE NOT NULL,
      CONSTRAINT PK_CLOUDINARY_CONFIG PRIMARY KEY (CLAVE)
    )~';
  EXECUTE IMMEDIATE q'~COMMENT ON TABLE CLOUDINARY_CONFIG IS 'Cuenta de Cloudinary (CLOUD_NAME, API_KEY, API_SECRET) para borrar archivos. Privada: la IA no la puede consultar'~';
  DBMS_OUTPUT.PUT_LINE('[OK]   Tabla CLOUDINARY_CONFIG creada.');
END;
/

SELECT TABLE_NAME FROM USER_TABLES WHERE TABLE_NAME = 'CLOUDINARY_CONFIG';
