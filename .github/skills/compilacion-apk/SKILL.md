---
name: compilacion-apk
description: 'Diagnostica, compila, firma y verifica APK o AAB de Android. Usar cuando se necesite generar un APK, resolver fallos de Gradle, Android SDK, JDK, Capacitor, React Native o Flutter, configurar keystores o preparar una entrega de Android.'
argument-hint: 'Describe el proyecto, el artefacto requerido (debug, release APK o AAB) y cualquier error de compilacion'
---

# Compilacion y Generacion de APK

## Objetivo

Producir un APK o AAB instalable y verificable, sin exponer secretos ni modificar configuracion ajena al problema. Soporta Android nativo con Gradle y proyectos que empaquetan Android mediante Capacitor, React Native o Flutter.

## Cuando Usar

- Generar un APK de depuracion o de lanzamiento.
- Generar un AAB para Google Play.
- Diagnosticar errores de Gradle, JDK, Android SDK, Kotlin, manifest o dependencias.
- Configurar o reparar firmado de release, `keystore` o variables de entorno.
- Sincronizar un frontend web antes de compilar con Capacitor.

## Procedimiento

1. Determinar el stack y el resultado pedido.
   - Identificar archivos ancla: `gradlew`, `build.gradle`, `build.gradle.kts`, `settings.gradle`, `capacitor.config.*`, `android/`, `pubspec.yaml` o `package.json`.
   - Confirmar variante: `debug` para pruebas locales; `release` para distribucion; AAB cuando Google Play lo requiera.
   - No asumir que una PWA ya contiene un proyecto Android. Si no existe una plataforma Android, explicar el paso de inicializacion apropiado antes de compilar.

2. Inspeccionar el fallo o los prerrequisitos de forma acotada.
   - Revisar las versiones declaradas de Gradle, Android Gradle Plugin, Kotlin, JDK y SDK antes de cambiarlas.
   - Verificar que `JAVA_HOME`, Android SDK y licencias requeridas estan disponibles cuando el error lo sugiera.
   - Usar el wrapper incluido (`gradlew` o `gradlew.bat`); no instalar Gradle global para reemplazarlo.
   - Elegir una sola hipotesis comprobable a partir del primer error y ejecutar el comando mas pequeno que pueda refutarla.

3. Preparar la aplicacion segun su stack.
   - **Gradle nativo:** compilar desde el directorio que contiene `gradlew`.
   - **Capacitor:** ejecutar primero el build web definido por el proyecto, luego `npx cap sync android`; no editar archivos generados bajo `android/` salvo que el cambio sea Android-especifico.
   - **React Native:** usar los scripts del proyecto y compilar el modulo `android` con Gradle; confirmar si las dependencias JavaScript ya estan instaladas.
   - **Flutter:** usar `flutter pub get` y `flutter build apk` o `flutter build appbundle`; conservar los flags de flavor y dart-define existentes.

4. Compilar el artefacto minimo requerido.
   - APK debug Gradle: `./gradlew assembleDebug` en PowerShell, usar `./gradlew.bat assembleDebug` si corresponde.
   - APK release Gradle: `./gradlew assembleRelease` solo cuando el firmado este resuelto.
   - AAB release Gradle: `./gradlew bundleRelease`.
   - Flutter: `flutter build apk --debug`, `flutter build apk --release` o `flutter build appbundle` segun el pedido.
   - Ejecutar primero la variante mas acotada que detecte el problema; no publicar ni instalar en dispositivos sin que se solicite.

5. Tratar errores en su causa inmediata.
   - Leer el primer bloque `FAILURE` y su primera causa concreta antes de modificar configuracion.
   - Para incompatibilidades de version, alinear las herramientas con las restricciones declaradas por el proyecto, no con la ultima version disponible.
   - Para dependencias, reparar el repositorio, version o cache solo si el mensaje identifica esa causa.
   - Para problemas de manifest, permisos o recursos, modificar la fuente propietaria y volver a ejecutar el mismo comando.
   - Despues de cada cambio, repetir la misma compilacion focalizada antes de explorar otra causa.

6. Firmar releases de manera segura.
   - Nunca pedir, mostrar, registrar ni incluir contrasenas, claves privadas, tokens o archivos `.jks` en el repositorio.
   - Preferir propiedades locales ignoradas por Git, variables de entorno o el mecanismo de CI ya existente.
   - Confirmar alias, ruta del keystore y configuracion de `signingConfig` sin revelar valores sensibles.
   - Si no hay material de firma, producir solo debug o detenerse indicando que la firma release requiere que el responsable la configure localmente.

7. Verificar y comunicar el resultado.
   - Informar la ruta exacta del APK/AAB, variante, version de aplicacion y comando que lo genero.
   - Verificar que el artefacto existe y tiene tamano mayor que cero.
   - Cuando esten disponibles, usar `apksigner verify --verbose`, `bundletool validate` o una instalacion de prueba solicitada para confirmar integridad.
   - Distinguir un APK universal de APKs divididos por ABI; no presentar un split como si fuera universal.

## Criterios de Finalizacion

- La variante solicitada termina con codigo de salida cero.
- El APK o AAB existe en la ruta comunicada y no esta vacio.
- Un release no se declara listo sin firmado verificable.
- Los secretos no aparecen en archivos versionados, comandos registrados ni respuestas.
- Los cambios realizados son minimos, pertenecen a la causa del error y la compilacion se repitio despues de aplicarlos.

## Reglas de Decision

- Si el usuario pide distribuir por Google Play, priorizar AAB release firmado.
- Si pide instalar o probar rapidamente, priorizar APK debug salvo que especifique release.
- Si el proyecto es web sin directorio Android, detectar el empaquetador antes de proponer comandos de Gradle.
- Si falta SDK, JDK o licencia, describir el requisito y validar de nuevo; no alterar versiones de proyecto como sustituto.
- Si el error afecta una herramienta externa no instalada, detener la compilacion y ofrecer el comando de instalacion adecuado al entorno.