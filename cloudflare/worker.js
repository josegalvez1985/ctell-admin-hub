/**
 * Proxy de ORDS para la versión web.
 *
 * PROBLEMA: ORDS no manda `Access-Control-Allow-Origin`, así que el navegador
 * bloquea cualquier llamada de www.ctell.online a oracleapex.com por ser otro
 * origen. GitHub Pages no puede resolverlo: sirve archivos estáticos y no hay
 * servidor que reenvíe nada.
 *
 * SOLUCIÓN: este Worker se pone delante del dominio. Las peticiones a
 * /ords/* las reenvía él a APEX —servidor contra servidor, donde la política
 * de mismo origen no aplica porque es cosa del navegador— y devuelve la
 * respuesta como si viniera de www.ctell.online. Para el navegador nunca hubo
 * un cruce de orígenes.
 *
 * Todo lo demás pasa de largo hacia GitHub Pages.
 *
 * Es el equivalente en producción del `server.proxy` de Vite, que hace lo
 * mismo en desarrollo. Ver src/lib/api.ts.
 *
 * Desplegar:
 *   npx wrangler deploy --config cloudflare/wrangler.toml
 */

const APEX = "https://oracleapex.com";

export default {
  async fetch(request) {
    const url = new URL(request.url);

    // Solo /ords/* se intercepta; el resto lo sirve Pages.
    if (!url.pathname.startsWith("/ords/")) {
      return fetch(request);
    }

    const destino = new URL(url.pathname + url.search, APEX);

    // `redirect: manual` para no seguir redirecciones de ORDS hacia
    // oracleapex.com: si las siguiéramos, la respuesta final vendría de otro
    // origen y volveríamos al problema que este Worker existe para evitar.
    const proxied = new Request(destino, {
      method: request.method,
      headers: request.headers,
      body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
      redirect: "manual",
    });

    // El Host tiene que ser el de APEX o ORDS no resuelve el workspace.
    proxied.headers.set("Host", "oracleapex.com");
    // Sin esto ORDS ve el origen del navegador y algunas configuraciones
    // responden distinto.
    proxied.headers.delete("Origin");
    proxied.headers.delete("Referer");

    const respuesta = await fetch(proxied);

    // La respuesta se devuelve tal cual: como sale del Worker con el mismo
    // origen que la página, no necesita cabeceras CORS. Se clona porque los
    // headers de una Response de fetch son inmutables.
    return new Response(respuesta.body, {
      status: respuesta.status,
      statusText: respuesta.statusText,
      headers: respuesta.headers,
    });
  },
};
