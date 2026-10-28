import { resolve } from "node:path";
const { default: app } = await import("./dist/server/server.js" as string);
const base = resolve(import.meta.dir, "dist/client");
const server = Bun.serve({
  hostname: process.env.HOST || "0.0.0.0",
  port: Number(process.env.PORT || 3000),
  idleTimeout: 120,
  async fetch(request) {
    const url = new URL(request.url);
    let pathname: string;
    try {
      pathname = decodeURIComponent(url.pathname);
    } catch {
      return new Response("Bad request", { status: 400 });
    }
    // RustDesk's API lives under /api; only static assets are served from disk.
    if (!pathname.startsWith("/api/") && pathname !== "/" && /\.[a-z0-9]+$/i.test(pathname)) {
      const path = resolve(base, `.${pathname}`);
      if (path.startsWith(base + "/")) {
        const file = Bun.file(path);
        if (await file.exists())
          return new Response(file, {
            headers: {
              "Cache-Control": pathname.startsWith("/assets/") ? "public, max-age=31536000, immutable" : "no-cache",
              "X-Content-Type-Options": "nosniff",
            },
          });
      }
      return new Response("Not found", { status: 404 });
    }
    return app.fetch(request);
  },
});
console.log(`RustDesk console listening on http://${server.hostname}:${server.port}`);
for (const signal of ["SIGTERM", "SIGINT"] as const)
  process.on(signal, async () => {
    await server.stop();
    process.exit(0);
  });
