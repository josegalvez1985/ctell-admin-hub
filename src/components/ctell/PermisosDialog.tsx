import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Copy, Loader2 } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { Combobox } from "@/components/ctell/Combobox";
import { useEmpresa } from "@/components/ctell/empresa-provider";
import { api, ApiError, esActivo, type Pagina, type Usuario } from "@/lib/api";
import { cn } from "@/lib/utils";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
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
      {/* `flex flex-col` + `overflow-hidden`: el diálogo NO scrollea como un
          todo. El selector de usuario y el encabezado quedan fijos, y el que
          scrollea es el panel de páginas — que es lo único que puede crecer.
          Antes, con el scroll en el contenedor, elegir un usuario y bajar a
          tildar dejaba el combobox fuera de vista y no se sabía sobre quién se
          estaba trabajando. */}
      <DialogContent className="flex max-h-[90vh] max-w-4xl flex-col overflow-hidden">
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
  const [copiando, setCopiando] = useState(false);

  const { data, isPending } = useQuery({
    queryKey: ["usuarios"],
    queryFn: () => api.usuarios.listar(),
  });

  const usuarios = data?.items ?? [];
  const destino = usuarios.find((u) => String(u.id) === value) ?? null;

  return (
    <div className="space-y-2">
      <Label>Usuario</Label>
      <div className="flex flex-wrap items-center gap-2">
        <div className="min-w-48 flex-1">
          <Combobox
            opciones={usuarios.map((u) => ({
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

        {/* Siempre habilitado: el diálogo pide los DOS usuarios, así que no
            hace falta haber elegido uno antes. Si hay uno seleccionado se
            propone como destino, que es el caso habitual —"estoy viendo a esta
            persona y le quiero copiar lo de otra"— pero se puede cambiar. */}
        <Button variant="outline" onClick={() => setCopiando(true)}>
          <Copy className="size-4" />
          Copiar permisos
        </Button>
      </div>

      <CopiarPermisosDialog
        open={copiando}
        usuarioActual={destino}
        usuarios={usuarios}
        onClose={() => setCopiando(false)}
      />
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Copiar permisos de un usuario a otro                                        */
/* -------------------------------------------------------------------------- */

/**
 * Copia los permisos de un usuario ORIGEN al usuario que se está editando.
 *
 * **Agrega, no reemplaza.** Los permisos que el destino ya tenía se conservan;
 * sólo se suman los del origen que le faltan. Es la opción segura: nadie pierde
 * accesos por un clic, y lo que sobre se destilda a mano. Para dejar a alguien
 * exactamente igual que otro hay que quitarle lo demás a propósito.
 *
 * No hay endpoint de copia masiva: se resuelve con una llamada a `asignar` por
 * página. Son pocas —las páginas del sistema entran en una pantalla— y evita
 * sumar un procedimiento PL/SQL para algo que el cliente ya puede hacer.
 */
function CopiarPermisosDialog({
  open,
  usuarioActual,
  usuarios,
  onClose,
}: {
  open: boolean;
  /** El del selector de afuera: se propone como destino, pero se puede cambiar. */
  usuarioActual: Usuario | null;
  usuarios: Usuario[];
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const { empresa } = useEmpresa();
  const [idOrigen, setIdOrigen] = useState("");
  const [idDestino, setIdDestino] = useState("");

  // Cada apertura arranca con el destino propuesto —el usuario que se estaba
  // viendo— y sin origen. El origen de la vez anterior, copiado sin querer
  // sobre otro destino, sería difícil de deshacer.
  useEffect(() => {
    if (open) {
      setIdOrigen("");
      setIdDestino(usuarioActual ? String(usuarioActual.id) : "");
    }
  }, [open, usuarioActual]);

  // TODOS los permisos de TODOS los usuarios, en una sola consulta.
  //
  // El endpoint admite `listar()` sin idUsuario. Se pide así —y no uno por
  // usuario— porque hace falta saber cuántas páginas tiene CADA UNO para
  // excluir del destino a los que ya las tienen todas. Con una consulta por
  // usuario serían N peticiones sólo para armar un desplegable.
  const todosQuery = useQuery({
    queryKey: ["usuario-paginas"],
    queryFn: () => api.usuarioPaginas.listar(),
  });

  // Las páginas activas: el universo contra el que se mide "los tiene todos".
  // Sin esto no habría con qué comparar — un usuario con 5 permisos puede
  // tenerlos todos o faltarle la mitad, según cuántas páginas existan.
  const paginasQuery = useQuery({
    queryKey: ["paginas"],
    queryFn: () => api.paginas.listar(),
  });

  const totalPaginas = (paginasQuery.data?.items ?? []).filter((p) => esActivo(p.activo)).length;

  /**
   * Los permisos **de la empresa activa**, de todos los usuarios.
   *
   * El filtro es necesario porque los permisos son POR EMPRESA: la PK incluye
   * `ID_EMPRESA`, así que el mismo usuario tiene juegos de accesos distintos
   * según la empresa. Copiar sin filtrar mezclaría los de una con los de otra.
   *
   * Todo lo que se cuenta y se copia acá —los totales de cada usuario, quién
   * "tiene todo"— vale **para esta empresa**, no en general.
   */
  const permisos = (todosQuery.data?.items ?? []).filter(
    (p) => empresa !== null && p.idEmpresa === empresa.id,
  );

  /** Las páginas que tiene cada usuario, indexadas por id. */
  const porUsuario = new Map<number, Set<number>>();
  for (const permiso of permisos) {
    const suyas = porUsuario.get(permiso.idUsuario) ?? new Set<number>();
    suyas.add(permiso.idPagina);
    porUsuario.set(permiso.idUsuario, suyas);
  }

  const cargandoDatos = todosQuery.isPending || paginasQuery.isPending;

  const origen = usuarios.find((u) => String(u.id) === idOrigen) ?? null;
  const destino = usuarios.find((u) => String(u.id) === idDestino) ?? null;

  const delOrigen = origen ? permisos.filter((p) => p.idUsuario === origen.id) : [];
  const yaTiene = destino ? (porUsuario.get(destino.id) ?? new Set<number>()) : new Set<number>();
  const aCopiar = delOrigen.filter((p) => !yaTiene.has(p.idPagina));

  const copiar = useMutation({
    mutationFn: async () => {
      if (!empresa) {
        throw new ApiError("No hay una empresa activa: volvé a iniciar sesión eligiendo una.", 0);
      }
      if (!destino) {
        throw new ApiError("Elegí a qué usuario copiar los permisos.", 0);
      }

      // Secuencial y no Promise.all: son peticiones de escritura contra la
      // misma tabla, y dispararlas todas juntas puede trabar filas entre sí.
      // Con pocas páginas la diferencia de tiempo es imperceptible.
      let copiadas = 0;
      const fallidas: string[] = [];

      for (const permiso of aCopiar) {
        try {
          await api.usuarioPaginas.asignar(destino.id, permiso.idPagina, empresa.id);
          copiadas++;
        } catch {
          // Una página que falla no aborta el resto: es preferible copiar 9 de
          // 10 y decir cuál faltó, que dejar todo a medias sin avisar.
          fallidas.push(permiso.pagina);
        }
      }

      return { copiadas, fallidas };
    },
    onSuccess: ({ copiadas, fallidas }) => {
      // Se invalida la clave entera: cambió el detalle del destino y también el
      // listado completo con el que este diálogo arma los desplegables.
      queryClient.invalidateQueries({ queryKey: ["usuario-paginas"] });

      if (copiadas > 0) {
        toast.success(`${copiadas} ${copiadas === 1 ? "página copiada" : "páginas copiadas"}`);
      }
      if (fallidas.length > 0) {
        toast.error(`No se pudieron copiar: ${fallidas.join(", ")}`);
      }
      onClose();
    },
    onError: (e) => toast.error(MENSAJE_ERROR(e, "No se pudieron copiar los permisos")),
  });

  const opcionParaUsuario = (u: Usuario) => {
    const cuantas = porUsuario.get(u.id)?.size ?? 0;
    return {
      valor: String(u.id),
      etiqueta: u.nombreApellido,
      // Cuántas páginas tiene: es el dato que hace falta para elegir de quién
      // copiar, y sin él hay que adivinar cuál es el perfil "completo".
      descripcion: `${u.usuario} · ${cuantas} de ${totalPaginas}`,
    };
  };

  // ORIGEN: se excluye a los que no tienen NINGÚN permiso —no habría nada que
  // copiar— y al destino elegido, porque copiarse a sí mismo no hace nada.
  const opcionesOrigen = usuarios
    .filter((u) => String(u.id) !== idDestino && (porUsuario.get(u.id)?.size ?? 0) > 0)
    .map(opcionParaUsuario);

  // DESTINO: se excluye a los que YA TIENEN TODAS las páginas activas. No hay
  // nada que copiarles venga de donde venga, así que ofrecerlos sólo lleva a un
  // "ya tiene todo" después de dos clics.
  //
  // El origen elegido tampoco se ofrece como destino.
  const opcionesDestino = usuarios
    .filter((u) => String(u.id) !== idOrigen && (porUsuario.get(u.id)?.size ?? 0) < totalPaginas)
    .map(opcionParaUsuario);

  // El destino propuesto puede quedar fuera de la lista justamente por tenerlo
  // todo: se avisa, en vez de mostrar un combobox misteriosamente vacío.
  const destinoQuedoExcluido =
    idDestino !== "" && !opcionesDestino.some((o) => o.valor === idDestino);

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>Copiar permisos</DialogTitle>
          <DialogDescription>
            Los accesos del primer usuario se agregan al segundo. No se le quita ninguno de los que
            ya tenga.
            {/* Los permisos son por empresa: sin este aviso, copiar parecería
                dar acceso en todas y no en la que está activa. */}
            {empresa && ` Sólo dentro de ${empresa.nombreEmpresa}.`}
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label>Copiar desde</Label>
            <Combobox
              opciones={opcionesOrigen}
              value={idOrigen}
              onChange={setIdOrigen}
              placeholder={cargandoDatos ? "Cargando…" : "Elegí un usuario"}
              buscarPlaceholder="Buscar usuario…"
              cargando={cargandoDatos}
            />
          </div>

          <div className="space-y-2">
            <Label>Copiar hacia</Label>
            <Combobox
              opciones={opcionesDestino}
              value={destinoQuedoExcluido ? "" : idDestino}
              onChange={setIdDestino}
              placeholder={cargandoDatos ? "Cargando…" : "Elegí un usuario"}
              buscarPlaceholder="Buscar usuario…"
              cargando={cargandoDatos}
            />
          </div>
        </div>

        {/* Qué va a pasar, ANTES de confirmar: copiar permisos a ciegas sobre
            la persona equivocada es difícil de revertir a mano. */}
        {!cargandoDatos && (destinoQuedoExcluido || (origen !== null && destino !== null)) && (
          <p className="rounded-lg border border-border bg-muted px-3 py-2 text-sm text-muted-foreground">
            {destinoQuedoExcluido
              ? `${usuarioActual?.nombreApellido ?? "Ese usuario"} ya tiene todas las páginas: elegí otro destino.`
              : aCopiar.length === 0
                ? `${destino!.nombreApellido} ya tiene todas las páginas de ${origen!.nombreApellido}.`
                : `Se van a agregar ${aCopiar.length} ${aCopiar.length === 1 ? "página" : "páginas"} a ${destino!.nombreApellido}.`}
          </p>
        )}

        <DialogFooter className="gap-2 sm:gap-2">
          <Button variant="outline" onClick={onClose}>
            Cancelar
          </Button>
          <Button
            onClick={() => copiar.mutate()}
            disabled={aCopiar.length === 0 || cargandoDatos || copiar.isPending}
          >
            {copiar.isPending && <Loader2 className="size-4 animate-spin" />}
            Copiar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
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

  // La empresa activa se registra al asignar (`ID_EMPRESA` queda como
  // auditoría: desde dónde se otorgó el permiso).
  const { empresa } = useEmpresa();

  /**
   * Un Set para preguntar "¿tiene permiso?" en O(1) por cada checkbox, en vez
   * de recorrer el array entero una vez por página.
   *
   * **Filtrado por la empresa activa**, porque los permisos son POR EMPRESA: la
   * PK es `(ID_EMPRESA, ID_USUARIO, ID_PAGINA)`, así que el mismo usuario puede
   * tener accesos distintos según con qué empresa entre. El endpoint devuelve
   * los de todas, y sin este recorte los checkboxes mostrarían tildadas páginas
   * que en esta empresa no están habilitadas.
   */
  const asignadas = new Set(
    (permisosQuery.data?.items ?? [])
      .filter((p) => empresa !== null && p.idEmpresa === empresa.id)
      .map((p) => p.idPagina),
  );

  // Sin el id: invalida por PREFIJO, así que alcanza tanto al detalle de este
  // usuario como al listado completo —["usuario-paginas"]— con el que el
  // diálogo de copia cuenta las páginas de cada uno. Invalidando sólo el
  // detalle, ese diálogo mostraría conteos viejos después de tildar acá.
  const invalidar = () => queryClient.invalidateQueries({ queryKey: ["usuario-paginas"] });

  const cambiar = useMutation({
    mutationFn: ({ idPagina, dar }: { idPagina: number; dar: boolean }) => {
      // La empresa hace falta para las DOS operaciones: integra la PK, así que
      // identifica en qué empresa se da o se quita el permiso. Sin ella, quitar
      // borraría el acceso en todas.
      if (!empresa) {
        throw new ApiError("No hay una empresa activa: volvé a iniciar sesión eligiendo una.", 0);
      }
      return dar
        ? api.usuarioPaginas.asignar(idUsuario, idPagina, empresa.id)
        : api.usuarioPaginas.quitar(idUsuario, idPagina, empresa.id);
    },
    onSuccess: () => invalidar(),
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo cambiar el permiso"));
      // El checkbox se pinta desde el servidor: si falló, hay que volver a
      // leer para que no quede mostrando un estado que no se guardó.
      invalidar();
    },
  });

  /**
   * Da o quita de una vez todas las páginas de un módulo.
   *
   * Sólo toca las que hagan falta: al marcar, saltea las que el usuario ya
   * tiene; al desmarcar, las que no tiene. Sin ese filtro cada clic dispararía
   * una petición por página del módulo, la mayoría para no cambiar nada.
   *
   * Secuencial y no `Promise.all`: son escrituras sobre la misma tabla, y
   * lanzarlas todas juntas puede trabar filas entre sí. Son pocas páginas por
   * módulo, así que la diferencia no se percibe.
   */
  const cambiarModulo = useMutation({
    mutationFn: async ({ paginas, dar }: { paginas: Pagina[]; dar: boolean }) => {
      // Igual que en `cambiar`: la empresa hace falta para dar Y para quitar.
      if (!empresa) {
        throw new ApiError("No hay una empresa activa: volvé a iniciar sesión eligiendo una.", 0);
      }

      let hechas = 0;
      const fallidas: string[] = [];

      for (const pagina of paginas) {
        try {
          if (dar) {
            await api.usuarioPaginas.asignar(idUsuario, pagina.id, empresa.id);
          } else {
            await api.usuarioPaginas.quitar(idUsuario, pagina.id, empresa.id);
          }
          hechas++;
        } catch {
          // Una página que falla no aborta el resto: es preferible cambiar 9 de
          // 10 y decir cuál faltó, que dejar el módulo a medias sin avisar.
          fallidas.push(pagina.nombre);
        }
      }

      return { hechas, fallidas, dar };
    },
    onSuccess: ({ hechas, fallidas, dar }) => {
      if (hechas > 0) {
        const q = `${hechas} ${hechas === 1 ? "página" : "páginas"}`;
        toast.success(
          dar
            ? `${q} asignada${hechas === 1 ? "" : "s"}`
            : `${q} quitada${hechas === 1 ? "" : "s"}`,
        );
      }
      if (fallidas.length > 0) {
        toast.error(`No se pudieron cambiar: ${fallidas.join(", ")}`);
      }
      invalidar();
    },
    onError: (e) => {
      toast.error(MENSAJE_ERROR(e, "No se pudo cambiar el módulo"));
      invalidar();
    },
  });

  // Un solo `disabled` para los dos: mientras una operación está en vuelo, no
  // se aceptan más clics en ningún checkbox.
  const guardando = cambiar.isPending || cambiarModulo.isPending;

  if (paginasQuery.isPending || permisosQuery.isPending) {
    return (
      // `min-h-0` para que el esqueleto no estire el diálogo mientras carga.
      <div className="min-h-0 flex-1 space-y-2 overflow-hidden">
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
    // `min-h-0` es imprescindible: sin él, un hijo flex no se deja encoger por
    // debajo de su contenido y el área de scroll crece hasta desbordar el
    // diálogo, que es justo lo que se quiere evitar.
    <div className="flex min-h-0 flex-1 flex-col gap-3">
      {/* Los módulos en COLUMNAS y no apilados: a una columna, con seis módulos
          había que rodar la rueda del mouse para llegar al último. En dos o tres
          columnas entran casi todos de una sola mirada.

          `items-start` evita que las tarjetas de una fila se estiren a la altura
          de la más alta; `[column-fill:balance]` reparte parejo. */}
      <div className="scrollbar-fino min-h-0 flex-1 gap-3 space-y-3 overflow-y-auto pr-1 [column-fill:balance] sm:columns-2 lg:columns-3">
        {[...porModulo.entries()].map(([modulo, susPaginas]) => {
          const conPermiso = susPaginas.filter((p) => asignadas.has(p.id)).length;
          const todas = conPermiso === susPaginas.length;
          // Estado del checkbox del módulo: marcado si están todas, guion si
          // hay algunas ("indeterminate" de Radix), vacío si ninguna. Sin el
          // intermedio, un módulo con 3 de 5 se vería igual que uno con 0.
          const estadoModulo = todas ? true : conPermiso > 0 ? "indeterminate" : false;

          return (
            <div key={modulo} className="mb-3 break-inside-avoid rounded-lg border border-border">
              {/* La cabecera del módulo es un checkbox: marca o desmarca todas
                  sus páginas de una vez. Con módulos de ocho o diez páginas,
                  darlas una por una son diez peticiones y diez clics.

                  Al estar TODAS marcadas el clic las quita; en cualquier otro
                  caso las da. Es lo que espera quien ve el guion del estado
                  parcial: el primer clic completa, no vacía. */}
              <Label className="flex cursor-pointer items-center gap-3 border-b border-border bg-muted/50 px-3 py-2 text-sm font-semibold text-foreground">
                <Checkbox
                  checked={estadoModulo}
                  disabled={guardando}
                  aria-label={`${todas ? "Quitar" : "Asignar"} todas las páginas de ${modulo}`}
                  onCheckedChange={() =>
                    cambiarModulo.mutate({
                      // Sólo las que cambian: al marcar, las que faltan; al
                      // desmarcar, las que tiene.
                      paginas: susPaginas.filter((p) => asignadas.has(p.id) === todas),
                      dar: !todas,
                    })
                  }
                />
                <span className="min-w-0 flex-1 truncate">{modulo}</span>
                {/* El contador dice de un vistazo cuánto falta del módulo, sin
                    tener que contar checkboxes. */}
                <span className="shrink-0 text-xs font-normal tabular-nums text-muted-foreground">
                  {conPermiso}/{susPaginas.length}
                </span>
              </Label>
              <ul className="divide-y divide-border">
                {susPaginas.map((pagina, i) => {
                  const tiene = asignadas.has(pagina.id);
                  // Primera asignada del grupo, habiendo alguna sin asignar
                  // antes: ahí es donde termina "lo que falta" y empieza "lo que
                  // ya tiene". Sin esa marca el reordenamiento parece arbitrario.
                  const abreAsignadas = tiene && i > 0 && !asignadas.has(susPaginas[i - 1]!.id);

                  return (
                    <li
                      key={pagina.id}
                      className={cn("px-3 py-2", abreAsignadas && "border-t-2 border-t-border")}
                    >
                      <Label className="flex cursor-pointer items-center gap-3 text-sm font-normal">
                        <Checkbox
                          checked={tiene}
                          disabled={guardando}
                          onCheckedChange={(v) =>
                            cambiar.mutate({ idPagina: pagina.id, dar: v === true })
                          }
                        />
                        {/* Las ya asignadas se atenúan: lo que se viene a
                            buscar acá es lo que falta. */}
                        <span
                          className={cn(
                            "min-w-0 flex-1 truncate",
                            tiene ? "text-muted-foreground" : "text-foreground",
                          )}
                        >
                          {pagina.nombre}
                        </span>
                      </Label>
                    </li>
                  );
                })}
              </ul>
            </div>
          );
        })}
      </div>

      {/* Fuera del área con scroll: el contador queda siempre a la vista. */}
      <p className="shrink-0 text-xs text-muted-foreground">
        {asignadas.size} de {paginas.length} página{paginas.length === 1 ? "" : "s"} asignada
        {asignadas.size === 1 ? "" : "s"}
      </p>
    </div>
  );
}
