import { createFileRoute } from "@tanstack/react-router";

const handle = async ({ request }: { request: Request }) => (await import("../../server/rustdesk")).handleRustDesk(request);

export const Route = createFileRoute("/api/$")({
  server: { handlers: { GET: handle, POST: handle, PUT: handle, DELETE: handle } },
});
