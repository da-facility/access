import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/admin_/auth/logout")({
  server: { handlers: { GET: async ({ request }) => (await import("../server/oidc")).logout(request) } },
});
