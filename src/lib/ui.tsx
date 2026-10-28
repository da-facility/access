import type { ReactNode } from "react";
import { useRouteContext, useRouter } from "@tanstack/react-router";
import { toast } from "@da-facility/ui";
import { Timestamp } from "@astryxdesign/core/Timestamp";
import { StatusDot } from "@astryxdesign/core/StatusDot";
import { AdminShell } from "../features/shell/AdminShell";
import styles from "./ui.module.css";

/** A console page inside the sidebar, for the signed-in admin. */
export function Page({ title, description, actions, children }: { title: string; description?: ReactNode; actions?: ReactNode; children: ReactNode }) {
  const { admin } = useRouteContext({ from: "/admin" });
  return (
    <AdminShell admin={admin} title={title}>
      <header className={styles.header}>
        <div>
          <h1>{title}</h1>
          {description && <p>{description}</p>}
        </div>
        {actions && <div className={styles.actions}>{actions}</div>}
      </header>
      {children}
    </AdminShell>
  );
}

export function Section({ title, description, actions, children }: { title: string; description?: ReactNode; actions?: ReactNode; children: ReactNode }) {
  return (
    <section className={styles.section}>
      <div className={styles.sectionHeader}>
        <div>
          <h2>{title}</h2>
          {description && <p>{description}</p>}
        </div>
        {actions}
      </div>
      {children}
    </section>
  );
}

/** Runs a change, reports it, and reloads the page's data. */
export function useAction() {
  const router = useRouter();
  /** Resolves true when the change went through. */
  return async function act(work: () => Promise<unknown>, success?: string): Promise<boolean> {
    try {
      await work();
      if (success) toast.success(success);
      await router.invalidate();
      return true;
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Something went wrong.");
      return false;
    }
  };
}

export function Ago({ at }: { at: number | null | undefined }) {
  if (!at) return <span className={styles.muted}>never</span>;
  return <Timestamp value={at * 1000} format="relative" size="sm" />;
}

export function Online({ online, label }: { online: boolean; label?: string }) {
  return <StatusDot variant={online ? "success" : "neutral"} label={label ?? (online ? "Online" : "Offline")} />;
}

export function Muted({ children }: { children: ReactNode }) {
  return <span className={styles.muted}>{children}</span>;
}

export function Mono({ children }: { children: ReactNode }) {
  return <code className={styles.mono}>{children}</code>;
}

export function Stack({ children, gap = 12 }: { children: ReactNode; gap?: number }) {
  return <div style={{ display: "flex", flexDirection: "column", gap }}>{children}</div>;
}

export function Row({ children, gap = 8, wrap = true }: { children: ReactNode; gap?: number; wrap?: boolean }) {
  return <div style={{ display: "flex", alignItems: "center", gap, flexWrap: wrap ? "wrap" : "nowrap" }}>{children}</div>;
}

export function DialogBody({ children }: { children: ReactNode }) {
  return <div className={styles.dialogBody}>{children}</div>;
}

export function DialogActions({ children }: { children: ReactNode }) {
  return <div className={styles.dialogActions}>{children}</div>;
}

export function Grid({ children, min = 220 }: { children: ReactNode; min?: number }) {
  return <div style={{ display: "grid", gap: 12, gridTemplateColumns: `repeat(auto-fill, minmax(${min}px, 1fr))` }}>{children}</div>;
}

export function Stat({ label, value, hint }: { label: string; value: ReactNode; hint?: ReactNode }) {
  return (
    <div className={styles.stat}>
      <span>{label}</span>
      <strong>{value}</strong>
      {hint && <small>{hint}</small>}
    </div>
  );
}

export const deviceLabel = (d: { alias?: string; hostname?: string; id: string }) => d.alias || d.hostname || d.id;
