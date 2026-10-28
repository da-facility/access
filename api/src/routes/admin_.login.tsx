import { createFileRoute, redirect } from "@tanstack/react-router";
import { LoginPocketId } from "@da-facility/ui";
import { Monitor } from "lucide-react";
import { getAdmin } from "../lib/rpc";

export const Route = createFileRoute("/admin_/login")({
  validateSearch: (search: Record<string, unknown>) => ({ next: typeof search.next === "string" ? search.next : undefined }),
  beforeLoad: async () => {
    if (await getAdmin()) throw redirect({ to: "/admin" });
  },
  component: Login,
});

function Login() {
  const { next } = Route.useSearch();
  return (
    <LoginPocketId
      href={`/admin/auth/login${next ? `?next=${encodeURIComponent(next)}` : ""}`}
      brand={
        <span style={{ display: "inline-flex", alignItems: "center", gap: 8, fontWeight: 600 }}>
          <Monitor size={20} aria-hidden /> RustDesk
        </span>
      }
      title="RustDesk console"
      description="Manage devices, users, access and policies for rd.dafacility.io. Sign in with your Da Facility account; only admins can enter."
      buttonLabel="Sign in with Da Facility SSO"
      autoFocus
    />
  );
}
