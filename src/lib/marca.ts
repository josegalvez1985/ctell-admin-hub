/**
 * Identidad del PRODUCTO, no de las empresas que lo usan.
 *
 * El sistema pasó a operar con varias empresas, así que "CTELL" dejó de servir
 * como nombre de la aplicación: era el nombre de una de ellas. Todo lo que
 * identifica al software —título de la pestaña, logo, textos del login— sale de
 * acá; el nombre de la empresa con la que se está trabajando sale del provider
 * de empresa activa (`useEmpresa()`), que sólo existe después de iniciar sesión.
 *
 * La distinción importa en el login: ahí todavía no hay empresa elegida, así
 * que sus textos NO pueden nombrar una razón social. Usan estas constantes.
 */

/** Nombre del sistema. Va en títulos de pestaña, el logo y los meta tags. */
export const NOMBRE_SISTEMA = "Sistema Administrativo";

/**
 * Bajada del logo, debajo del nombre.
 *
 * Vacía porque el nombre del sistema ya ocupa las dos líneas del logo. Si más
 * adelante hace falta una bajada, poner el texto acá y el componente la muestra
 * sola — no hay que tocar el JSX.
 */
export const LEMA_SISTEMA = "";

/** Título de pestaña de una página interna: "Monedas | Sistema Administrativo". */
export function tituloPagina(seccion: string): string {
  return `${seccion} | ${NOMBRE_SISTEMA}`;
}
