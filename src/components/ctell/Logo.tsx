import { cn } from "@/lib/utils";

export function Logo({
  className,
  tone = "light",
}: {
  className?: string;
  tone?: "light" | "dark";
}) {
  return (
    <div className={cn("flex items-center gap-2.5", className)}>
      <span className="gradient-primary flex size-9 items-center justify-center rounded-xl font-display text-lg font-bold text-primary-foreground shadow-card">
        C
      </span>
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
          Sistema ERP
        </span>
      </span>
    </div>
  );
}
