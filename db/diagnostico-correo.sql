--------------------------------------------------------------------------------
-- CTELL · DIAGNOSTICO DE CORREO
--
-- Para cuando "no llega el mail" de /auth/recuperar o del alta de usuarios.
--
-- NO crea ni modifica nada: son consultas. Se ejecuta en la hoja de trabajo SQL
-- de APEX, con el esquema del workspace, y se lee la salida de arriba a abajo.
-- El primer paso que falle es la causa; los siguientes ya no importan.
--
-- Por que hace falta un script aparte: /auth/recuperar responde 200 SIEMPRE
-- --coincidan o no los datos, salga o no el correo-- para no delatar que
-- cuentas existen. Esa decision es correcta, pero deja al que administra sin
-- ninguna senal: el error real va a APEX_DEBUG.ERROR, que no esta activo por
-- defecto. Desde afuera, "el correo no llego" y "el usuario escribio mal su
-- correo" se ven exactamente igual.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET VERIFY OFF

-- LO UNICO QUE HAY QUE EDITAR: el usuario que reporto el problema y una casilla
-- propia donde probar el envio. Se definen aca arriba para no tener que
-- buscarlos entre los pasos.
DEFINE usuario_a_revisar = 'admin'
DEFINE correo_de_prueba  = 'jose.jgalvez@gmail.com'

PROMPT
PROMPT ==============================================================
PROMPT  PASO 1 - El paquete compila
PROMPT ==============================================================
PROMPT  Un PKG_AUTH INVALID no manda correos y ademas tumba el login.
PROMPT  Se espera: PACKAGE y PACKAGE BODY en VALID.

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS
  FROM USER_OBJECTS
 WHERE OBJECT_NAME = 'PKG_AUTH'
 ORDER BY OBJECT_TYPE;

SELECT LINE, POSITION, TEXT
  FROM USER_ERRORS
 WHERE NAME = 'PKG_AUTH'
 ORDER BY SEQUENCE;

PROMPT
PROMPT ==============================================================
PROMPT  PASO 2 - El nombre del workspace es el correcto
PROMPT ==============================================================
PROMPT  PKG_AUTH tiene C_WORKSPACE_MAIL := 'CTELL' y resuelve el
PROMPT  security group id por ese nombre. Si no figura abajo tal cual
PROMPT  --en mayusculas--, ESTABLECER_WORKSPACE_MAIL corta con
PROMPT  "No existe el workspace CTELL" y ningun correo sale.

SELECT WORKSPACE_ID, WORKSPACE
  FROM APEX_WORKSPACES
 ORDER BY WORKSPACE;

PROMPT
PROMPT ==============================================================
PROMPT  PASO 3 - APEX tiene remitente configurado (EMAIL_FROM)
PROMPT ==============================================================
PROMPT  Los envios pasan p_from => NULL a proposito y dejan que APEX
PROMPT  resuelva el origen con este parametro de instancia. Si sale
PROMPT  vacio o sin filas, APEX_MAIL.SEND falla y ese es el motivo.
PROMPT  Se arregla en: Administracion de Instancia -> Configuracion
PROMPT  de Correo Electronico -> "Direccion del remitente".
PROMPT  En el APEX gratuito solo se acepta el correo de la cuenta.

SELECT NAME, VALUE
  FROM APEX_INSTANCE_PARAMETERS
 WHERE NAME IN ('EMAIL_FROM', 'SMTP_HOST_ADDRESS', 'SMTP_HOST_PORT',
                'SMTP_TLS_MODE', 'SMTP_USERNAME')
 ORDER BY NAME;

PROMPT
PROMPT ==============================================================
PROMPT  PASO 4 - Que paso con los ultimos envios
PROMPT ==============================================================
PROMPT  APEX_MAIL_QUEUE  = pendientes. Con filas viejas acumuladas, el
PROMPT                     PUSH_QUEUE no sale (mirar MAIL_SEND_ERROR).
PROMPT  APEX_MAIL_LOG    = enviados de verdad.
PROMPT  LAS DOS VACIAS   = el mensaje nunca se encolo: el SEND fallo
PROMPT                     antes, y la causa esta en el paso 2 o 3.

SELECT MAIL_ID, MAIL_TO, MAIL_SUBJECT, MAIL_SEND_ERROR
  FROM APEX_MAIL_QUEUE
 ORDER BY MAIL_ID DESC
 FETCH FIRST 10 ROWS ONLY;

SELECT MAIL_ID, MAIL_TO, MAIL_SUBJECT, MAIL_SEND_TIMESTAMP
  FROM APEX_MAIL_LOG
 ORDER BY MAIL_SEND_TIMESTAMP DESC
 FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT ==============================================================
PROMPT  PASO 5 - Cuota diaria de la instancia
PROMPT ==============================================================
PROMPT  El APEX gratuito limita los correos por dia. Agotada la cuota,
PROMPT  el envio falla sin que nada del codigo este mal: se espera al
PROMPT  dia siguiente. La vista no existe en todas las versiones y sus
PROMPT  columnas cambian de nombre entre ellas, asi que se pregunta
PROMPT  antes: un SELECT contra una vista ausente abortaria el script
PROMPT  y esconderia los pasos que siguen.

DECLARE
  l_hay   PLS_INTEGER;
  l_texto VARCHAR2(4000);
BEGIN
  SELECT COUNT(*) INTO l_hay
    FROM ALL_VIEWS
   WHERE VIEW_NAME = 'APEX_WORKSPACE_EMAIL_QUOTA';

  IF l_hay = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Esta version de APEX no expone la vista de cuota. Paso omitido.');
  ELSE
    EXECUTE IMMEDIATE q'[SELECT TO_CHAR(EMAILS_SENT) || ' enviados de ' ||
                                TO_CHAR(QUOTA_DAILY) || ' permitidos hoy'
                           FROM APEX_WORKSPACE_EMAIL_QUOTA
                          WHERE ROWNUM = 1]'
      INTO l_texto;
    DBMS_OUTPUT.PUT_LINE('Cuota: ' || l_texto);
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('No se pudo leer la cuota (' || SQLERRM ||
                         '). Paso omitido: no es un problema de correo.');
END;
/

PROMPT
PROMPT ==============================================================
PROMPT  PASO 6 - Envio real, con el error a la vista
PROMPT ==============================================================
PROMPT  Recorre el MISMO camino que /auth/recuperar (mismo workspace,
PROMPT  mismo p_from NULL, mismo PUSH_QUEUE) pero DEVUELVE el error de
PROMPT  Oracle en texto en vez de tragarselo.
PROMPT  Destinatario: el definido arriba como correo_de_prueba.

SELECT PKG_AUTH.PROBAR_CORREO('&correo_de_prueba') AS RESULTADO FROM DUAL;

PROMPT
PROMPT ==============================================================
PROMPT  PASO 7 - El usuario que pidio recuperar existe y califica
PROMPT ==============================================================
PROMPT  RECUPERAR_PASSWORD exige las tres cosas en la MISMA fila:
PROMPT  usuario exacto, correo igual (sin distinguir mayusculas) y
PROMPT  cuenta ACTIVA. Si falla cualquiera, sale en silencio con el
PROMPT  mismo 200 de siempre y NO se manda nada: no es un problema de
PROMPT  correo, es que no encontro a quien mandarselo.
PROMPT  Usuario revisado: el definido arriba como usuario_a_revisar.

SELECT ID_USUARIO,
       USUARIO,
       CORREO,
       ACTIVO,
       CASE
         WHEN CORREO IS NULL             THEN 'SIN CORREO CARGADO -> nunca recibe nada'
         WHEN UPPER(TRIM(ACTIVO)) <> 'A' THEN 'CUENTA INACTIVA -> no recupera por aca'
         ELSE 'OK: puede recuperar, escribiendo este correo exacto'
       END AS DIAGNOSTICO
  FROM USUARIOS
 WHERE USUARIO = LOWER(TRIM('&usuario_a_revisar'));

PROMPT
PROMPT ==============================================================
PROMPT  PASO 8 - Cuentas que no podrian recuperar aunque quisieran
PROMPT ==============================================================
PROMPT  Activas y sin correo: para estas, /auth/recuperar responde 200
PROMPT  y no manda nada. Se les carga el correo desde /usuarios.

SELECT ID_USUARIO, USUARIO, NOMBRE_APELLIDO
  FROM USUARIOS
 WHERE UPPER(TRIM(ACTIVO)) = 'A'
   AND (CORREO IS NULL OR TRIM(CORREO) IS NULL)
 ORDER BY USUARIO;

PROMPT
PROMPT ==============================================================
PROMPT  COMO LEER ESTO
PROMPT ==============================================================
PROMPT  Paso 1 INVALID ............ recompilar auth.sql (y despues usuarios.sql)
PROMPT  Paso 2 sin 'CTELL' ........ corregir C_WORKSPACE_MAIL en db/auth.sql
PROMPT  Paso 3 EMAIL_FROM vacio ... configurarlo en Administracion de Instancia
PROMPT  Paso 4 todo vacio ......... el SEND fallo: la causa esta en 2 o 3
PROMPT  Paso 4 cola con error ..... leer MAIL_SEND_ERROR, es el motivo textual
PROMPT  Paso 5 cuota agotada ...... esperar al dia siguiente, el codigo esta bien
PROMPT  Paso 6 ERROR .............. ese es el error real, sin filtros
PROMPT  Paso 6 OK y no llega ...... revisar spam; si tampoco, el destino rebota
PROMPT  Paso 7 no devuelve fila ... el usuario escribio mal usuario o correo
PROMPT ==============================================================
