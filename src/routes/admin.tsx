import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";
import { getAdmin } from "../lib/rpc";

export const Route = createFileRoute("/admin")({
  beforeLoad: async ({ location }) => {
    const admin = await getAdmin();
    if (!admin) throw redirect({ to: "/admin/login", search: { next: location.href === "/admin" ? undefined : location.href } });
    return { admin };
  },
  component: Outlet,
});
