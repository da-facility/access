import { createRouter, Link } from "@tanstack/react-router";
import { routeTree } from "./routeTree.gen";

function NotFound() {
  return (
    <main style={{ padding: 32, fontFamily: "system-ui, sans-serif" }}>
      <h1 style={{ fontSize: 18, margin: "0 0 8px" }}>Page not found</h1>
      <Link to="/admin">Back to the console</Link>
    </main>
  );
}

export function getRouter() {
  return createRouter({ routeTree, scrollRestoration: true, defaultNotFoundComponent: NotFound });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof getRouter>;
  }
}
