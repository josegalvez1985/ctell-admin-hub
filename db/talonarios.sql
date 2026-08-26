--------------------------------------------------------------------------------
-- CTELL · TALONARIOS
-- Requiere ejecutar antes el DDL de TALONARIOS y db/auth.sql.
-- Endpoints: /talonarios/listar, /crear, /actualizar/:id, /eliminar/:id/:idEmpresa
--------------------------------------------------------------------------------

SET DEFINE OFF
SET SERVEROUTPUT ON

CREATE OR REPLACE PACKAGE PKG_TALONARIOS AS
  PROCEDURE LISTAR(p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_sucursal IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE INSERTAR(p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_sucursal IN VARCHAR2, p_tipo IN VARCHAR2, p_timbrado IN VARCHAR2, p_establecimiento IN VARCHAR2, p_punto IN VARCHAR2, p_inicial IN VARCHAR2, p_final IN VARCHAR2, p_actual IN VARCHAR2, p_fecha_inicio IN VARCHAR2, p_fecha_vencimiento IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE ACTUALIZAR(p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_tipo IN VARCHAR2, p_timbrado IN VARCHAR2, p_establecimiento IN VARCHAR2, p_punto IN VARCHAR2, p_inicial IN VARCHAR2, p_final IN VARCHAR2, p_actual IN VARCHAR2, p_fecha_inicio IN VARCHAR2, p_fecha_vencimiento IN VARCHAR2, p_activo IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE ELIMINAR(p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB);
  PROCEDURE PUBLICAR_ENDPOINTS;
END PKG_TALONARIOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_TALONARIOS AS
  PROCEDURE BORRAR_MODULO IS
    l_existe NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_existe FROM USER_ORDS_MODULES WHERE NAME = 'talonarios';
    IF l_existe > 0 THEN ORDS.DELETE_MODULE(p_module_name => 'talonarios'); COMMIT; END IF;
  END BORRAR_MODULO;

  FUNCTION SESION(p_auth VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN PKG_AUTH.VALIDAR_TOKEN(PKG_AUTH.TOKEN_DE_HEADER(p_auth));
  END SESION;

  FUNCTION SUCURSAL_VALIDA(p_sucursal NUMBER, p_empresa NUMBER) RETURN BOOLEAN IS
    l_count NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_count FROM SUCURSALES WHERE ID_SUCURSAL = p_sucursal AND ID_EMPRESA = p_empresa;
    RETURN l_count > 0;
  END SUCURSAL_VALIDA;

  FUNCTION FECHA(p_valor VARCHAR2) RETURN DATE IS
  BEGIN
    IF NULLIF(TRIM(p_valor), '') IS NULL THEN RETURN NULL; END IF;
    RETURN TO_DATE(p_valor, 'YYYY-MM-DD');
  EXCEPTION WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20001, 'Las fechas deben tener formato YYYY-MM-DD');
  END FECHA;

  PROCEDURE LISTAR(p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_sucursal IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion NUMBER; l_empresa NUMBER; l_sucursal NUMBER; l_items CLOB; l_total NUMBER;
  BEGIN
    l_sesion := SESION(p_authorization);
    IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, '')); l_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, ''));
    SELECT COUNT(*) INTO l_total FROM TALONARIOS WHERE (l_empresa IS NULL OR ID_EMPRESA = l_empresa) AND (l_sucursal IS NULL OR ID_SUCURSAL = l_sucursal);
    SELECT JSON_ARRAYAGG(fila ORDER BY tipo, timbrado RETURNING CLOB) INTO l_items FROM (
      SELECT JSON_OBJECT('id' VALUE ID_TALONARIO, 'idEmpresa' VALUE ID_EMPRESA, 'idSucursal' VALUE ID_SUCURSAL, 'tipoComprobante' VALUE TIPO_COMPROBANTE, 'nroTimbrado' VALUE NRO_TIMBRADO, 'establecimiento' VALUE ESTABLECIMIENTO, 'puntoExpedicion' VALUE PUNTO_EXPEDICION, 'nroInicial' VALUE NRO_INICIAL, 'nroFinal' VALUE NRO_FINAL, 'nroActual' VALUE NRO_ACTUAL, 'fechaInicio' VALUE TO_CHAR(FECHA_INICIO, 'YYYY-MM-DD'), 'fechaVencimiento' VALUE TO_CHAR(FECHA_VENCIMIENTO, 'YYYY-MM-DD'), 'activo' VALUE ACTIVO) fila, TIPO_COMPROBANTE tipo, NRO_TIMBRADO timbrado
      FROM TALONARIOS WHERE (l_empresa IS NULL OR ID_EMPRESA = l_empresa) AND (l_sucursal IS NULL OR ID_SUCURSAL = l_sucursal));
    SELECT JSON_OBJECT('items' VALUE NVL(l_items, TO_CLOB('[]')) FORMAT JSON, 'total' VALUE l_total RETURNING CLOB) INTO p_resultado FROM DUAL;
    p_status_code := 200;
  EXCEPTION WHEN OTHERS THEN p_status_code := 400; p_resultado := JSON_OBJECT('error' VALUE SQLERRM); END LISTAR;

  PROCEDURE INSERTAR(p_authorization IN VARCHAR2, p_id_empresa IN VARCHAR2, p_id_sucursal IN VARCHAR2, p_tipo IN VARCHAR2, p_timbrado IN VARCHAR2, p_establecimiento IN VARCHAR2, p_punto IN VARCHAR2, p_inicial IN VARCHAR2, p_final IN VARCHAR2, p_actual IN VARCHAR2, p_fecha_inicio IN VARCHAR2, p_fecha_vencimiento IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion NUMBER; l_empresa NUMBER; l_sucursal NUMBER; l_inicial NUMBER; l_final NUMBER; l_actual NUMBER; l_id NUMBER; l_inicio DATE; l_vencimiento DATE;
  BEGIN
    l_sesion := SESION(p_authorization); IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    l_empresa := TO_NUMBER(NULLIF(p_id_empresa, '')); l_sucursal := TO_NUMBER(NULLIF(p_id_sucursal, '')); l_inicial := TO_NUMBER(NULLIF(p_inicial, '')); l_final := TO_NUMBER(NULLIF(p_final, '')); l_actual := NVL(TO_NUMBER(NULLIF(p_actual, '')), l_inicial); l_inicio := FECHA(p_fecha_inicio); l_vencimiento := FECHA(p_fecha_vencimiento);
    IF NOT SUCURSAL_VALIDA(l_sucursal, l_empresa) THEN RAISE_APPLICATION_ERROR(-20002, 'La sucursal no pertenece a la empresa'); END IF;
    IF UPPER(TRIM(p_tipo)) NOT IN ('FCO','FCR','NCR') OR l_inicial IS NULL OR l_final IS NULL OR l_final < l_inicial OR l_actual NOT BETWEEN l_inicial AND l_final THEN RAISE_APPLICATION_ERROR(-20003, 'Tipo o rango de numeracion invalido'); END IF;
    IF l_vencimiento IS NOT NULL AND l_inicio IS NOT NULL AND l_vencimiento < l_inicio THEN RAISE_APPLICATION_ERROR(-20004, 'La fecha de vencimiento no puede ser anterior al inicio'); END IF;
    INSERT INTO TALONARIOS(ID_EMPRESA, ID_SUCURSAL, TIPO_COMPROBANTE, NRO_TIMBRADO, ESTABLECIMIENTO, PUNTO_EXPEDICION, NRO_INICIAL, NRO_FINAL, NRO_ACTUAL, FECHA_INICIO, FECHA_VENCIMIENTO) VALUES(l_empresa, l_sucursal, UPPER(TRIM(p_tipo)), TRIM(p_timbrado), TRIM(p_establecimiento), TRIM(p_punto), l_inicial, l_final, l_actual, l_inicio, l_vencimiento) RETURNING ID_TALONARIO INTO l_id;
    COMMIT; p_status_code := 201; p_resultado := JSON_OBJECT('id' VALUE l_id, 'ok' VALUE 'true' FORMAT JSON);
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN ROLLBACK; p_status_code := 409; p_resultado := '{"error":"Ya existe un talonario con ese timbrado en la sucursal"}'; WHEN OTHERS THEN ROLLBACK; p_status_code := 400; p_resultado := JSON_OBJECT('error' VALUE SQLERRM); END INSERTAR;

  PROCEDURE ACTUALIZAR(p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_tipo IN VARCHAR2, p_timbrado IN VARCHAR2, p_establecimiento IN VARCHAR2, p_punto IN VARCHAR2, p_inicial IN VARCHAR2, p_final IN VARCHAR2, p_actual IN VARCHAR2, p_fecha_inicio IN VARCHAR2, p_fecha_vencimiento IN VARCHAR2, p_activo IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
    l_sesion NUMBER; l_id NUMBER; l_empresa NUMBER; l_actual NUMBER; l_inicial NUMBER; l_final NUMBER; l_inicio DATE; l_vencimiento DATE; l_old TALONARIOS%ROWTYPE;
  BEGIN
    l_sesion := SESION(p_authorization); IF l_sesion IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    l_id := TO_NUMBER(p_id); l_empresa := TO_NUMBER(NULLIF(p_id_empresa, '')); SELECT * INTO l_old FROM TALONARIOS WHERE ID_TALONARIO = l_id AND ID_EMPRESA = l_empresa FOR UPDATE;
    l_inicial := NVL(TO_NUMBER(NULLIF(p_inicial, '')), l_old.NRO_INICIAL); l_final := NVL(TO_NUMBER(NULLIF(p_final, '')), l_old.NRO_FINAL); l_actual := NVL(TO_NUMBER(NULLIF(p_actual, '')), l_old.NRO_ACTUAL); l_inicio := NVL(FECHA(p_fecha_inicio), l_old.FECHA_INICIO); l_vencimiento := NVL(FECHA(p_fecha_vencimiento), l_old.FECHA_VENCIMIENTO);
    IF l_final < l_inicial OR l_actual NOT BETWEEN l_inicial AND l_final THEN RAISE_APPLICATION_ERROR(-20003, 'Rango o numero actual invalido'); END IF;
    IF l_vencimiento IS NOT NULL AND l_inicio IS NOT NULL AND l_vencimiento < l_inicio THEN RAISE_APPLICATION_ERROR(-20004, 'La fecha de vencimiento no puede ser anterior al inicio'); END IF;
    UPDATE TALONARIOS SET TIPO_COMPROBANTE = NVL(UPPER(TRIM(NULLIF(p_tipo,''))), TIPO_COMPROBANTE), NRO_TIMBRADO = NVL(TRIM(NULLIF(p_timbrado,'')), NRO_TIMBRADO), ESTABLECIMIENTO = NVL(TRIM(NULLIF(p_establecimiento,'')), ESTABLECIMIENTO), PUNTO_EXPEDICION = NVL(TRIM(NULLIF(p_punto,'')), PUNTO_EXPEDICION), NRO_INICIAL = l_inicial, NRO_FINAL = l_final, NRO_ACTUAL = l_actual, FECHA_INICIO = l_inicio, FECHA_VENCIMIENTO = l_vencimiento, ACTIVO = NVL(UPPER(TRIM(NULLIF(p_activo,''))), ACTIVO), FECHA_ACTUALIZACION = SYSTIMESTAMP WHERE ID_TALONARIO = l_id AND ID_EMPRESA = l_empresa;
    COMMIT; p_status_code := 200; p_resultado := '{"ok":true}';
  EXCEPTION WHEN NO_DATA_FOUND THEN ROLLBACK; p_status_code := 404; p_resultado := '{"error":"Talonario no encontrado"}'; WHEN DUP_VAL_ON_INDEX THEN ROLLBACK; p_status_code := 409; p_resultado := '{"error":"Ya existe un talonario con ese timbrado en la sucursal"}'; WHEN OTHERS THEN ROLLBACK; p_status_code := 400; p_resultado := JSON_OBJECT('error' VALUE SQLERRM); END ACTUALIZAR;

  PROCEDURE ELIMINAR(p_authorization IN VARCHAR2, p_id IN VARCHAR2, p_id_empresa IN VARCHAR2, p_status_code OUT NUMBER, p_resultado OUT CLOB) IS
  BEGIN
    IF SESION(p_authorization) IS NULL THEN p_status_code := 401; p_resultado := '{"error":"Sesion invalida o vencida"}'; RETURN; END IF;
    DELETE FROM TALONARIOS WHERE ID_TALONARIO = TO_NUMBER(p_id) AND ID_EMPRESA = TO_NUMBER(p_id_empresa); IF SQL%ROWCOUNT = 0 THEN p_status_code := 404; p_resultado := '{"error":"Talonario no encontrado"}'; RETURN; END IF; COMMIT; p_status_code := 200; p_resultado := '{"ok":true}';
  EXCEPTION WHEN OTHERS THEN ROLLBACK; p_status_code := 400; p_resultado := JSON_OBJECT('error' VALUE SQLERRM); END ELIMINAR;

  PROCEDURE PUBLICAR_ENDPOINTS IS
  BEGIN
    BORRAR_MODULO;
    ORDS.DEFINE_MODULE(p_module_name=>'talonarios', p_base_path=>'/talonarios/', p_items_per_page=>0, p_status=>'PUBLISHED', p_comments=>'Talonarios de comprobantes por empresa y sucursal');
    ORDS.SET_MODULE_ORIGINS_ALLOWED(p_module_name=>'talonarios', p_origins_allowed=>'https://www.ctell.online,http://localhost:8080');
    ORDS.DEFINE_TEMPLATE(p_module_name=>'talonarios', p_pattern=>'listar'); ORDS.DEFINE_HANDLER(p_module_name=>'talonarios', p_pattern=>'listar', p_method=>'GET', p_source_type=>ORDS.source_type_plsql, p_source=>'BEGIN PKG_TALONARIOS.LISTAR(:authorization,:idEmpresa,:idSucursal,:status_code,:resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name=>'talonarios', p_pattern=>'listar', p_method=>'GET', p_name=>'authorization', p_bind_variable_name=>'authorization', p_source_type=>'HEADER', p_param_type=>'STRING', p_access_method=>'IN'); ORDS.DEFINE_PARAMETER(p_module_name=>'talonarios', p_pattern=>'listar', p_method=>'GET', p_name=>'resultado', p_bind_variable_name=>'resultado', p_source_type=>'RESPONSE', p_param_type=>'STRING', p_access_method=>'OUT'); ORDS.DEFINE_PARAMETER(p_module_name=>'talonarios', p_pattern=>'listar', p_method=>'GET', p_name=>'X-APEX-STATUS-CODE', p_bind_variable_name=>'status_code', p_source_type=>'HEADER', p_param_type=>'INT', p_access_method=>'OUT');
    ORDS.DEFINE_TEMPLATE(p_module_name=>'talonarios', p_pattern=>'crear'); ORDS.DEFINE_HANDLER(p_module_name=>'talonarios', p_pattern=>'crear', p_method=>'POST', p_source_type=>ORDS.source_type_plsql, p_source=>'BEGIN PKG_TALONARIOS.INSERTAR(:authorization,:idEmpresa,:idSucursal,:tipoComprobante,:nroTimbrado,:establecimiento,:puntoExpedicion,:nroInicial,:nroFinal,:nroActual,:fechaInicio,:fechaVencimiento,:status_code,:resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name=>'talonarios', p_pattern=>'crear', p_method=>'POST', p_name=>'authorization', p_bind_variable_name=>'authorization', p_source_type=>'HEADER', p_param_type=>'STRING', p_access_method=>'IN'); ORDS.DEFINE_PARAMETER(p_module_name=>'talonarios', p_pattern=>'crear', p_method=>'POST', p_name=>'resultado', p_bind_variable_name=>'resultado', p_source_type=>'RESPONSE', p_param_type=>'STRING', p_access_method=>'OUT'); ORDS.DEFINE_PARAMETER(p_module_name=>'talonarios', p_pattern=>'crear', p_method=>'POST', p_name=>'X-APEX-STATUS-CODE', p_bind_variable_name=>'status_code', p_source_type=>'HEADER', p_param_type=>'INT', p_access_method=>'OUT');
    ORDS.DEFINE_TEMPLATE(p_module_name=>'talonarios', p_pattern=>'actualizar/:id'); ORDS.DEFINE_HANDLER(p_module_name=>'talonarios', p_pattern=>'actualizar/:id', p_method=>'PUT', p_source_type=>ORDS.source_type_plsql, p_source=>'BEGIN PKG_TALONARIOS.ACTUALIZAR(:authorization,:id,:idEmpresa,:tipoComprobante,:nroTimbrado,:establecimiento,:puntoExpedicion,:nroInicial,:nroFinal,:nroActual,:fechaInicio,:fechaVencimiento,:activo,:status_code,:resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name=>'talonarios', p_pattern=>'actualizar/:id', p_method=>'PUT', p_name=>'authorization', p_bind_variable_name=>'authorization', p_source_type=>'HEADER', p_param_type=>'STRING', p_access_method=>'IN'); ORDS.DEFINE_PARAMETER(p_module_name=>'talonarios', p_pattern=>'actualizar/:id', p_method=>'PUT', p_name=>'resultado', p_bind_variable_name=>'resultado', p_source_type=>'RESPONSE', p_param_type=>'STRING', p_access_method=>'OUT'); ORDS.DEFINE_PARAMETER(p_module_name=>'talonarios', p_pattern=>'actualizar/:id', p_method=>'PUT', p_name=>'X-APEX-STATUS-CODE', p_bind_variable_name=>'status_code', p_source_type=>'HEADER', p_param_type=>'INT', p_access_method=>'OUT');
    ORDS.DEFINE_TEMPLATE(p_module_name=>'talonarios', p_pattern=>'eliminar/:id/:idEmpresa'); ORDS.DEFINE_HANDLER(p_module_name=>'talonarios', p_pattern=>'eliminar/:id/:idEmpresa', p_method=>'DELETE', p_source_type=>ORDS.source_type_plsql, p_source=>'BEGIN PKG_TALONARIOS.ELIMINAR(:authorization,:id,:idEmpresa,:status_code,:resultado); END;');
    ORDS.DEFINE_PARAMETER(p_module_name=>'talonarios', p_pattern=>'eliminar/:id/:idEmpresa', p_method=>'DELETE', p_name=>'authorization', p_bind_variable_name=>'authorization', p_source_type=>'HEADER', p_param_type=>'STRING', p_access_method=>'IN'); ORDS.DEFINE_PARAMETER(p_module_name=>'talonarios', p_pattern=>'eliminar/:id/:idEmpresa', p_method=>'DELETE', p_name=>'resultado', p_bind_variable_name=>'resultado', p_source_type=>'RESPONSE', p_param_type=>'STRING', p_access_method=>'OUT'); ORDS.DEFINE_PARAMETER(p_module_name=>'talonarios', p_pattern=>'eliminar/:id/:idEmpresa', p_method=>'DELETE', p_name=>'X-APEX-STATUS-CODE', p_bind_variable_name=>'status_code', p_source_type=>'HEADER', p_param_type=>'INT', p_access_method=>'OUT');
    COMMIT;
  END PUBLICAR_ENDPOINTS;
END PKG_TALONARIOS;
/

BEGIN PKG_TALONARIOS.PUBLICAR_ENDPOINTS; END;
/

SELECT OBJECT_NAME, OBJECT_TYPE, STATUS FROM USER_OBJECTS WHERE OBJECT_NAME = 'PKG_TALONARIOS';
