import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { Settings, Users, Map, Lock } from "lucide-react";

import { useUsuarioActual } from "@/hooks/use-usuario-actual";
import { AppLayout } from "@/components/ctell/AppLayout";
import { UsuariosDialog } from "@/components/ctell/UsuariosDialog";
import { ModulosDialog } from "@/components/ctell/ModulosDialog";
import { PaginasDialog } from "@/components/ctell/PaginasDialog";
import { PermisosDialog } from "@/components/ctell/PermisosDialog";
import { tituloPagina } from "@/lib/marca";

/**
 * Las cuatro herramientas, repartidas en los dos oficios que las usan.
 *
 * NO SON DOS PERMISOS SINO DOS TAREAS. Las cuatro siguen pidiendo `esAdmin`, y
 * el guard de abajo no cambió: la división es de organización, no de acceso.
 * Separarlas de verdad necesitaría un rol propio en `USUARIOS` — hoy sólo existe
 * administrador o no.
 *
 * La utilidad de agruparlas es que son tareas de ritmo distinto. **Cuentas y
 * permisos** se tocan seguido y con una persona concreta en la cabeza: entra
 * alguien, se va alguien, hay que darle acceso a una pantalla. **Módulos y
 * páginas** se tocan cuando el sistema crece —una pantalla nueva que hay que dar
 * de alta— y una equivocación ahí le cambia el menú a todos, no a uno.
 *
 * Cuentas primero dentro de su grupo, y páginas después de módulos: es el orden
 * en que se hacen las cosas. Una página necesita su módulo ya creado, y un
 * permiso necesita la página y el usuario.
 */
const GRUPOS = [
  {
    id: "administrador",
    titulo: "Administrador",
    descripcion: "Quién entra al sistema y qué puede ver cada uno",
    secciones: [
      {
        id: "usuarios",
        titulo: "Cuentas",
        descripcion: "Gestión de usuarios del sistema",
        icono: Users,
      },
      {
        id: "permisos",
        titulo: "Permisos",
        descripcion: "Asignar acceso a páginas por usuario",
        icono: Lock,
      },
    ],
  },
  {
    id: "sistemas",
    titulo: "Analista de sistemas",
    descripcion: "La estructura del menú: qué módulos y páginas existen",
    secciones: [
      {
        id: "modulos",
        titulo: "Módulos",
        descripcion: "Estructura del menú principal",
        icono: Map,
      },
      {
        id: "paginas",
        titulo: "Páginas",
        descripcion: "Páginas dentro de cada módulo",
        icono: Settings,
      },
    ],
  },
] as const;

type SeccionId = (typeof GRUPOS)[number]["secciones"][number]["id"];

function AdministracionPage() {
  const navigate = useNavigate();
  // useUsuarioActual devuelve el resultado de useQuery, no el usuario: sin
  // desestructurar `data`, esAdmin quedaba undefined y la página no se
  // renderizaba nunca.
  const { data: usuario, isPending } = useUsuarioActual();
  const [seccionAbierta, setSeccionAbierta] = useState<SeccionId | null>(null);

  useEffect(() => {
    // Guard: solo admins pueden entrar. Se espera a que cargue para no expulsar
    // a un admin mientras la petición está en vuelo.
    if (!isPending && usuario && usuario.esAdmin !== "S") {
      navigate({ to: "/home" });
    }
  }, [usuario, isPending, navigate]);

  // Mientras carga `/auth/me` o mientras el efecto de arriba redirige, no se
  // dibuja nada: mostrar el panel un instante antes de expulsar a quien no
  // corresponde sería peor que una pantalla en blanco breve.
  //
  // El acceso normal a esta pantalla ya está oculto para los no-admin (la
  // tarjeta de Configuración sólo se dibuja si `esAdmin`), así que acá se llega
  // escribiendo la URL a mano. El guard queda igual: es la red de seguridad de
  // ese caso, y del enlace compartido o el favorito guardado.
  if (!usuario || usuario.esAdmin !== "S") {
    return null;
  }

  return (
    <AppLayout active="Administración" title="Administración">
      <div className="space-y-6 p-6">
        <div>
          <h1 className="text-3xl font-bold text-foreground">Administración</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Cuentas y permisos de acceso, y la estructura del menú.
          </p>
        </div>

        {/* Un bloque por oficio, con su rótulo arriba. Las tarjetas no cambian:
            lo único que se agrega es el encabezado que dice de quién es cada
            par, y el espacio entre los dos grupos. */}
        {GRUPOS.map((grupo) => (
          <section key={grupo.id} className="space-y-3">
            <div>
              <h2 className="text-lg font-semibold text-foreground">{grupo.titulo}</h2>
              <p className="text-sm text-muted-foreground">{grupo.descripcion}</p>
            </div>

            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              {grupo.secciones.map((seccion) => {
                const Icon = seccion.icono;
                return (
                  <button
                    key={seccion.id}
                    onClick={() => setSeccionAbierta(seccion.id)}
                    className="rounded-lg border border-border p-4 text-left transition-all hover:bg-accent hover:border-primary/50"
                  >
                    <div className="flex items-start gap-3">
                      <Icon className="size-6 text-primary shrink-0 mt-1" />
                      <div className="flex-1 min-w-0">
                        <p className="font-semibold text-foreground">{seccion.titulo}</p>
                        <p className="text-sm text-muted-foreground">{seccion.descripcion}</p>
                      </div>
                    </div>
                  </button>
                );
              })}
            </div>
          </section>
        ))}

        <UsuariosDialog
          open={seccionAbierta === "usuarios"}
          onOpenChange={(open) => !open && setSeccionAbierta(null)}
        />

        <ModulosDialog
          open={seccionAbierta === "modulos"}
          onOpenChange={(open) => !open && setSeccionAbierta(null)}
        />

        <PaginasDialog
          open={seccionAbierta === "paginas"}
          onOpenChange={(open) => !open && setSeccionAbierta(null)}
        />

        <PermisosDialog
          open={seccionAbierta === "permisos"}
          onOpenChange={(open) => !open && setSeccionAbierta(null)}
        />
      </div>
    </AppLayout>
  );
}

export const Route = createFileRoute("/_auth/administracion")({
  head: () => ({
    meta: [
      { title: tituloPagina("Administración") },
      {
        name: "description",
        content: "Administración del sistema: usuarios, menú, páginas y permisos.",
      },
    ],
  }),
  component: AdministracionPage,
});
