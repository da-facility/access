import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/admin_/auth/login")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const next = new URL(request.url).searchParams.get("next") ?? "/admin";
        return (await import("../server/oidc")).beginLogin(next);
      },
    },
  },
});
