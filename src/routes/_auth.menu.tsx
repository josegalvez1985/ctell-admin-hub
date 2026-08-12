import { createFileRoute } from "@tanstack/react-router";
import { AppLayout } from "@/components/ctell/AppLayout";
import { MenuDinamico } from "@/components/ctell/MenuDinamico";
import { primerNombre, useUsuarioActual } from "@/hooks/use-usuario-actual";
import { Skeleton } from "@/components/ui/skeleton";

export const Route = createFileRoute("/_auth/menu")({
  head: () => ({
    meta: [
      { title: "Menú | CTELL" },
      {
        name: "description",
        content: "Menú de navegación personalizado según permisos del usuario.",
      },
    ],
  }),
  component: MenuPage,
});

function MenuPage() {
  const { data: usuario } = useUsuarioActual();
  const nombre = primerNombre(usuario?.nombreApellido);
  const esperandoNombre = !usuario;

  return (
    <AppLayout active="Menú">
      <main className="space-y-6 px-4 pb-28 pt-6 sm:px-6 lg:pb-10">
        <div>
          {esperandoNombre ? (
            <Skeleton className="h-8 w-56 sm:h-9" />
          ) : (
            <h1 className="text-2xl font-bold text-foreground sm:text-3xl">
              {nombre ? `Bienvenido, ${nombre}` : "Bienvenido"}
            </h1>
          )}
          <p className="mt-1 text-sm text-muted-foreground">
            Accedé a las secciones según tus permisos.
          </p>
        </div>

        <div className="max-w-2xl">
          <MenuDinamico />
        </div>
      </main>
    </AppLayout>
  );
}
