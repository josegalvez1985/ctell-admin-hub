/*
 * Service worker mínimo.
 *
 * Existe por un solo motivo: Chrome no ofrece instalar una PWA —no dispara
 * `beforeinstallprompt`— si el sitio no registra un service worker con un
 * handler de `fetch`. El manifest y el HTTPS por sí solos no alcanzan.
 *
 * NO CACHEA NADA a propósito. Los datos de esta app viven en ORDS detrás de un
 * token de 8 horas: una respuesta cacheada sería un listado viejo o un 401
 * servido desde el disco. El `fetch` es un passthrough deliberado — está para
 * cumplir el requisito de instalabilidad, no para acelerar nada.
 *
 * Si alguna vez se quiere soporte offline real, el camino es vite-plugin-pwa
 * con precache del bundle, no agregar caché a mano acá.
 */

// skipWaiting + clients.claim: un SW nuevo toma el control en la misma visita
// en vez de esperar a que se cierren todas las pestañas. Sin esto, un deploy
// puede dejar activo el SW anterior por días.
self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

// Passthrough explícito. El handler tiene que existir para que el navegador
// considere instalable al sitio, pero no intercepta ni altera la respuesta.
self.addEventListener("fetch", () => {
  // Sin event.respondWith(): el navegador resuelve la petición como si el
  // service worker no estuviera.
});
