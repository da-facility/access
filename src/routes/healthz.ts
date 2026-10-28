import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/healthz")({
  server: {
    handlers: {
      GET: async () => {
        const { one } = await import("../server/db");
        one("SELECT 1");
        return Response.json({ status: "ok" }, { headers: { "Cache-Control": "no-store" } });
      },
    },
  },
});
