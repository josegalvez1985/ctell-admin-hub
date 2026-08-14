import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { Combobox } from "@/components/ctell/Combobox";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { api, ApiError, esActivo, type Pagina } from "@/lib/api";
import { cn } from "@/lib/utils";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";

const MENSAJE_ERROR = (error: unknown, fallback: string) =>
  error instanceof ApiError ? error.message : fallback;

export function PermisosDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const [idUsuario, setIdUsuario] = useState<string>("");

  // Cada apertura arranca sin usuario elegido: mostrar los permisos de quien
  // se miró la vez anterior invita a tildar sobre la persona equivocada.
  useEffect(() => {
    if (open) setIdUsuario("");
  }, [open]);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85vh] max-w-3xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Permisos</DialogTitle>
          <DialogDescription>
            Elegí un usuario y tildá las páginas a las que puede entrar. Los cambios se guardan al
            instante.
          </DialogDescription>
        </DialogHeader>

        <SelectorUsuario value={idUsuario} onChange={setIdUsuario} />

        {idUsuario === "" ? (
          <p className="px-3 py-10 text-center text-sm text-muted-foreground">
            Elegí un usuario para ver y editar sus permisos.
          </p>
        ) : (
          <PanelPermisos idUsuario={Number(idUsuario)} />
        )}
      </DialogContent>
    </Dialog>
  );
}

/* -------------------------------------------------------------------------- */
/* Selector de usuario                                                         */
/* -------------------------------------------------------------------------- */

function SelectorUsuario({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const { data, isPending } = useQuery({
    queryKey: ["usuarios"],
    queryFn: () => api.usuarios.listar(),
  });

  return (
    <div className="space-y-2">
      <Label>Usuario</Label>
      <Combobox
        opciones={(data?.items ?? []).map((u) => ({
          valor: String(u.id),
          etiqueta: u.nombreApellido,
          descripcion: u.usuario,
        }))}
        value={value}
        onChange={onChange}
        placeholder="Elegí un usuario"
        buscarPlaceholder="Buscar usuario…"
        cargando={isPending}
      />
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Checkboxes de páginas, agrupadas por módulo                                 */
/* -------------------------------------------------------------------------- */

function PanelPermisos({ idUsuario }: { idUsuario: number }) {
  const queryClient = useQueryClient();

  const paginasQuery = useQuery({
    queryKey: ["paginas"],
    queryFn: () => api.paginas.listar(),
  });

  const permisosQuery = useQuery({
    queryKey: ["usuario-paginas", idUsuario],
    queryFn: () => api.usuarioPaginas.listar({ idUsuario }),
  });

  // Los permisos se otorgan PARA LA EMPRESA ACTIVA: el menú solo muestra las
  // páginas cuyo permiso es de la empresa con la que se inició sesión (ver
  // use-menu-usuario.ts). Para dar accesos en otra empresa hay que entrar con
  // ella.
  const { empresa } = useEmpresa();

  // Un Set para preguntar "¿tiene permiso?" en O(1) por cada checkbox, en vez
  // de recorrer el array entero una vez por página.
  //
  // Se filtra por empresa: el endpoint devuelve los permisos del usuario en
  // TODAS las empresas, y sin este recorte los checkboxes aparecerían tildados
  // por accesos de otra empresa que en esta no funcionan.
  const asignadas = new Set(
    (permisosQuery.data?.items ?? [])
      .filter((p) => empresa !== null && p.idEmpresa === empresa.id)
      .map((p) => p.idPagina),
  );

  const invalidar = () =>
    queryClient.invalidateQueries({ queryKey: ["usuario-paginas", idUsuario] });

  const cambiar = useMutation({
    mutationFn: ({ idPagina, dar }: { idPagina: number; dar: boolean }) => {
      if (dar) {
        // Sin empresa el permiso se guardaría con ID_EMPRESA en NULL, y esas
        // filas no las muestra ningún menú: quedaría creado pero inservible,
        // sin ningún aviso. Mejor no dejar asignar que dejar un permiso mudo.
        if (!empresa) {
          throw new ApiError("No hay una empresa activa: volvé a iniciar sesión eligiendo una.", 0);
        }
        return api.usuarioPaginas.asignar(idUsuario, idPagina, empresa.id);
      }
      return api.usuarioPaginas.quitar(idUsuario, idPagina);
    },
    onSuccess: () => invalidar(),
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo cambiar el permiso"));
      // El checkbox se pinta desde el servidor: si falló, hay que volver a
      // leer para que no quede mostrando un estado que no se guardó.
      invalidar();
    },
  });

  if (paginasQuery.isPending || permisosQuery.isPending) {
    return (
      <div className="space-y-2">
        {[0, 1, 2].map((i) => (
          <Skeleton key={i} className="h-16 w-full" />
        ))}
      </div>
    );
  }

  if (paginasQuery.isError || permisosQuery.isError) {
    return (
      <p className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-6 text-center text-sm text-destructive">
        {MENSAJE_ERROR(
          paginasQuery.error ?? permisosQuery.error,
          "No se pudieron cargar los datos",
        )}
      </p>
    );
  }

  // Solo las páginas activas: dar permiso sobre una inactiva no serviría de
  // nada y ensucia la lista.
  const paginas = (paginasQuery.data?.items ?? []).filter((p) => esActivo(p.activo));

  if (paginas.length === 0) {
    return (
      <p className="px-3 py-10 text-center text-sm text-muted-foreground">
        No hay páginas activas para asignar.
      </p>
    );
  }

  // Agrupadas por módulo para que la lista se lea como el menú real.
  const porModulo = new Map<string, Pagina[]>();
  for (const pagina of paginas) {
    const grupo = porModulo.get(pagina.modulo) ?? [];
    grupo.push(pagina);
    porModulo.set(pagina.modulo, grupo);
  }

  // Dentro de cada módulo, primero las que el usuario NO tiene.
  //
  // A esta pantalla se entra a DAR permisos, no a mirar los que ya están: lo
  // que falta es lo que se viene a buscar, y dejarlo mezclado obliga a
  // escanear checkboxes tildados para encontrarlo. Las asignadas quedan abajo,
  // visibles para poder quitarlas.
  //
  // El orden se recalcula en cada render: al tildar una, la fila baja al grupo
  // de asignadas. Es deliberado —refleja el estado nuevo— y no molesta porque
  // el cambio ocurre después de hacer clic, no mientras se busca.
  for (const grupo of porModulo.values()) {
    grupo.sort((a, b) => {
      const faltaA = asignadas.has(a.id) ? 1 : 0;
      const faltaB = asignadas.has(b.id) ? 1 : 0;
      // A igual condición, el orden del menú: primero ORDEN, después el nombre.
      return faltaA - faltaB || a.orden - b.orden || a.nombre.localeCompare(b.nombre, "es");
    });
  }

  return (
    <div className="space-y-4">
      {[...porModulo.entries()].map(([modulo, susPaginas]) => (
        <div key={modulo} className="rounded-lg border border-border">
          <p className="border-b border-border bg-muted/50 px-3 py-2 text-sm font-semibold text-foreground">
            {modulo}
          </p>
          <ul className="divide-y divide-border">
            {susPaginas.map((pagina, i) => {
              const tiene = asignadas.has(pagina.id);
              // Primera asignada del grupo, habiendo alguna sin asignar antes:
              // ahí es donde termina "lo que falta" y empieza "lo que ya
              // tiene". Sin esa marca el reordenamiento parece arbitrario.
              const abreAsignadas = tiene && i > 0 && !asignadas.has(susPaginas[i - 1]!.id);

              return (
                <li
                  key={pagina.id}
                  className={cn("px-3 py-2.5", abreAsignadas && "border-t-2 border-t-border")}
                >
                  <Label className="flex cursor-pointer items-center gap-3 text-sm font-normal">
                    <Checkbox
                      checked={tiene}
                      disabled={cambiar.isPending}
                      onCheckedChange={(v) =>
                        cambiar.mutate({ idPagina: pagina.id, dar: v === true })
                      }
                    />
                    {/* Las ya asignadas se atenúan: lo que se viene a buscar
                        acá es lo que falta. */}
                    <span className={tiene ? "text-muted-foreground" : "text-foreground"}>
                      {pagina.nombre}
                    </span>
                  </Label>
                </li>
              );
            })}
          </ul>
        </div>
      ))}

      <p className="text-xs text-muted-foreground">
        {asignadas.size} de {paginas.length} página{paginas.length === 1 ? "" : "s"} asignada
        {asignadas.size === 1 ? "" : "s"}
      </p>
    </div>
  );
}
