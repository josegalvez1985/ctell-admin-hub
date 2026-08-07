import { cn } from "@/lib/utils";

export function Logo({
  className,
  tone = "light",
  showWordmark = true,
}: {
  className?: string;
  tone?: "light" | "dark";
  /** En espacios reducidos se puede mostrar sólo el isotipo. */
  showWordmark?: boolean;
}) {
  return (
    <div className={cn("flex items-center gap-2.5", className)}>
      <img
        src={`${import.meta.env.BASE_URL}icons/ctell-192.png`}
        alt="CTELL"
        width={36}
        height={36}
        className="size-9 shrink-0 rounded-xl object-cover shadow-card"
      />
      {showWordmark && (
        <span className="flex flex-col leading-none">
          <span
            className={cn(
              "font-display text-lg font-bold tracking-tight",
              tone === "light" ? "text-foreground" : "text-navy-foreground",
            )}
          >
            CTELL
          </span>
          <span
            className={cn(
              "text-[10px] font-medium uppercase tracking-[0.22em]",
              tone === "light" ? "text-muted-foreground" : "text-navy-foreground/60",
            )}
          >
            Human Tech
          </span>
        </span>
      )}
    </div>
  );
}
