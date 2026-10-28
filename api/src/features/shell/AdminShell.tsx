import type { ReactNode } from "react";
import { useRouterState } from "@tanstack/react-router";
import { SidebarLayout, Toaster, UserMenu } from "@da-facility/ui";
import { SideNavItem, SideNavSection } from "@astryxdesign/core/SideNav";
import { BookUser, Gauge, KeyRound, LogOut, Monitor, ScrollText, ShieldCheck, Users } from "lucide-react";
import styles from "./shell.module.css";

const sections = [
  { href: "/admin", label: "Overview", icon: <Gauge size={18} />, exact: true },
  { href: "/admin/devices", label: "Devices", icon: <Monitor size={18} /> },
  { href: "/admin/users", label: "Users", icon: <Users size={18} /> },
  { href: "/admin/access", label: "Access", icon: <KeyRound size={18} /> },
  { href: "/admin/address-books", label: "Address books", icon: <BookUser size={18} /> },
  { href: "/admin/policies", label: "Policies", icon: <ShieldCheck size={18} /> },
  { href: "/admin/audit", label: "Audit log", icon: <ScrollText size={18} /> },
];

/** The sidebar around every console page. */
export function AdminShell({ admin, title, actions, children }: { admin: { name: string; email: string }; title?: string; actions?: ReactNode; children: ReactNode }) {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  return (
    <div className={styles.app}>
      <SidebarLayout
        title={title}
        headerActions={actions}
        navigationLabel="Navigation"
        navigationKey={pathname}
        navigationHeader={
          <div className={styles.brand}>
            <Monitor size={20} aria-hidden />
            <div>
              <strong>RustDesk</strong>
              <span>rd.dafacility.io</span>
            </div>
          </div>
        }
        navigation={
          <SideNavSection title="Console" isHeaderHidden>
            {sections.map((s) => (
              <SideNavItem
                key={s.href}
                label={s.label}
                icon={s.icon}
                href={s.href}
                isSelected={s.exact ? pathname === s.href || pathname === s.href + "/" : pathname === s.href || pathname.startsWith(s.href + "/")}
              />
            ))}
          </SideNavSection>
        }
        navigationFooter={
          <div className={styles.footer}>
            <UserMenu
              user={{ name: admin.name, description: admin.email }}
              items={[{ id: "sign-out", label: "Sign out", icon: <LogOut size={16} />, onClick: () => (window.location.href = "/admin/auth/logout") }]}
              isFullWidth
              placement="above"
              alignment="start"
            />
          </div>
        }
      >
        <main className={styles.workspace}>{children}</main>
        <Toaster position="bottom-right" />
      </SidebarLayout>
    </div>
  );
}
