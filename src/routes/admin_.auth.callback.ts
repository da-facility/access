import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/admin_/auth/callback")({
  server: { handlers: { GET: async ({ request }) => (await import("../server/oidc")).finishLogin(request) } },
});
