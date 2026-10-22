/**
 * El asistente con IA: un chat en un botón flotante, en todas las pantallas con
 * sesión. Contrato del backend: `db/asistente.sql`.
 *
 * La IA corre en Oracle (`PKG_ASISTENTE`, que llama a la API de Claude): acá
 * sólo se manda la pregunta con lo que el backend no sabe —la conversación, la
 * pantalla abierta, la empresa y la sucursal activas y el manual— y se muestra
 * la respuesta.
 *
 * - **Quién lo ve:** todos los que entran (Jose, 22/10/2026). No es una página
 *   del menú ni depende de los permisos; el gasto lo frena el límite de
 *   preguntas por día del backend.
 * - **La conversación vive sólo en memoria** y va atada al token: salir o
 *   entrar con otro usuario la borra, y recargar también. Puede traer datos de
 *   cualquier pantalla, así que no se escribe en el disco.
 * - **El manual es `docs/MANUAL-DE-USO.md`**, importado como texto: la IA sabe
 *   de cada pantalla nueva con el deploy, sin volver a correr el `.sql`. Se
 *   descarga recién al abrir el chat.
 */

import { useSyncExternalStore } from "react";

import { api, getEmpresaSeleccionada, getSucursalSeleccionada, getToken } from "@/lib/api";

/*
 * El backend no devuelve el SQL que corrió la IA ni le deja nombrar tablas en
 * la respuesta: la estructura de la base es secreta para el usuario (Jose,
 * 22/10/2026). Lo que corrió queda en IA_CONSULTAS.CONSULTAS.
 */
export type MensajeIA = {
  id: string;
  rol: "usuario" | "asistente";
  texto: string;
  /** Un fallo (sin respuesta): no se le manda a la IA como historial. */
  error?: boolean;
};

type Estado = {
  /** De qué sesión es: el token, que cambia en cada login. */
  sesion: string;
  mensajes: MensajeIA[];
  /** Esperando la respuesta (puede tardar: la IA corre consultas). */
  pendiente: boolean;
  usadasHoy: number | null;
  limite: number | null;
  /**
   * El panel abierto. Acá y no en el componente: cada pantalla monta su
   * `AppLayout`, y en la computadora el panel sigue abierto al navegar (para
   * preguntar por la pantalla nueva).
   */
  abierto: boolean;
};

const VACIO: Omit<Estado, "sesion"> = {
  mensajes: [],
  pendiente: false,
  usadasHoy: null,
  limite: null,
  abierto: false,
};

/* -------------------------------------------------------------------------- */
/* La conversación: un store de módulo                                         */
/* -------------------------------------------------------------------------- */

/*
 * De módulo y no en un componente: el chat sobrevive a la navegación (cada
 * pantalla monta su propio AppLayout) y una respuesta que llega con el panel
 * cerrado no se pierde.
 */
let estado: Estado = { sesion: "", ...VACIO };
const oyentes = new Set<() => void>();

function fijar(parcial: Partial<Estado>) {
  estado = { ...estado, ...parcial };
  oyentes.forEach((f) => f());
}

const tokenActual = () => getToken() ?? "";

/** La conversación de esta sesión (la de una anterior, si quedó, se descarta). */
function actual(): Estado {
  const sesion = tokenActual();
  if (estado.sesion !== sesion) estado = { sesion, ...VACIO };
  return estado;
}

function suscribir(f: () => void) {
  oyentes.add(f);
  return () => {
    oyentes.delete(f);
  };
}

export function useAsistente() {
  return useSyncExternalStore(suscribir, actual, actual);
}

export function abrirAsistente(abierto: boolean) {
  actual();
  fijar({ abierto });
}

export function nuevaConversacion() {
  if (actual().pendiente) return;
  fijar({ mensajes: [] });
}

let secuencia = 0;
const nuevoId = () => `m${Date.now()}-${++secuencia}`;

/** Cuántos mensajes previos viajan como contexto (el backend corta en 12). */
const HISTORIAL = 12;

/**
 * Manda una pregunta y agrega la respuesta (o el error) a la conversación.
 * `pantalla`: la que está abierta, para "¿cómo uso esta pantalla?".
 */
export async function preguntar(texto: string, pantalla: string) {
  const pregunta = texto.trim();
  const previo = actual();
  if (!pregunta || previo.pendiente) return;

  const historial = previo.mensajes
    .filter((m) => !m.error)
    .slice(-HISTORIAL)
    .map((m) => ({ rol: m.rol, texto: m.texto }));

  fijar({
    mensajes: [...previo.mensajes, { id: nuevoId(), rol: "usuario", texto: pregunta }],
    pendiente: true,
  });

  try {
    // Se leen al preguntar y no al abrir el chat: la sucursal se puede cambiar
    // con el panel abierto.
    const empresa = getEmpresaSeleccionada();
    if (!empresa) throw new Error("Elegí una empresa para poder preguntar.");
    const sucursal = getSucursalSeleccionada();

    const r = await api.asistente.preguntar({
      pregunta,
      historial,
      manual: await cargarManual(),
      pantalla,
      idEmpresa: empresa.id,
      // Una sucursal de otra empresa es de la sesión anterior: no va.
      idSucursal: sucursal && sucursal.idEmpresa === empresa.id ? sucursal.id : null,
    });
    agregar({ id: nuevoId(), rol: "asistente", texto: String(r.respuesta ?? "") });
    fijar({ usadasHoy: r.usadasHoy ?? null, limite: r.limite ?? null });
  } catch (e) {
    agregar({
      id: nuevoId(),
      rol: "asistente",
      texto: e instanceof Error ? e.message : "No se pudo obtener la respuesta.",
      error: true,
    });
  } finally {
    fijar({ pendiente: false });
  }
}

/** Agrega al final, salvo que la sesión haya cambiado mientras se esperaba. */
function agregar(m: MensajeIA) {
  if (estado.sesion !== tokenActual()) return;
  fijar({ mensajes: [...estado.mensajes, m] });
}

/** Vuelve a mandar la última pregunta que falló. */
export function reintentar(pantalla: string) {
  const { mensajes, pendiente } = actual();
  const ultimo = mensajes[mensajes.length - 1];
  const pregunta = mensajes[mensajes.length - 2];
  if (pendiente || !ultimo?.error || pregunta?.rol !== "usuario") return;
  fijar({ mensajes: mensajes.slice(0, -2) });
  void preguntar(pregunta.texto, pantalla);
}

/* -------------------------------------------------------------------------- */
/* El manual                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * Lo que el manual no dice porque es del propio asistente. Va antes del
 * manual.
 */
const GUIA_BASICA = `## El asistente

- Se abre con el botón redondo con destellos, abajo a la derecha. En el celular está arriba del botón del menú.
- Responde cómo se usa cada pantalla y preguntas sobre los datos de la empresa activa (y, para el stock, de la sucursal activa). Para preguntar por otra empresa, primero hay que cambiarla en la barra de arriba.
- Sólo consulta: no carga, modifica ni borra nada.
- Recuerda la conversación hasta que se recarga la página o se cierra la sesión. El lápiz de arriba empieza una conversación nueva.
- Cada usuario tiene un límite de preguntas por día; las que fallan no cuentan.`;

/** Desde el título `desde` hasta antes de `hasta` (o el final). */
function seccion(md: string, desde: string, hasta?: string) {
  const i = md.indexOf(desde);
  if (i < 0) return "";
  const j = hasta ? md.indexOf(hasta, i + desde.length) : -1;
  return md.slice(i, j < 0 ? undefined : j).trim();
}

/**
 * El manual sin lo que no es para el usuario: la introducción habla de los
 * archivos del proyecto, y el anexo final es para quien administra el sistema
 * (paquetes, scripts, consultas al diccionario). Con eso adentro, la IA tendría
 * a mano justo lo que no puede contar. Si cambian estos dos títulos, revisar acá.
 */
function armarManual(md: string) {
  return [GUIA_BASICA, seccion(md, "## Primeros pasos", "## Anexo")].filter(Boolean).join("\n\n");
}

let manual: Promise<string> | null = null;

/**
 * El manual, una vez por carga del sitio. Import dinámico: el archivo (unos
 * 33 KB) no pesa en el bundle de nadie que no abra el chat.
 */
export function cargarManual(): Promise<string> {
  manual ??= import("../../docs/MANUAL-DE-USO.md?raw")
    .then((m) => armarManual(m.default))
    .catch(() => GUIA_BASICA);
  return manual;
}
