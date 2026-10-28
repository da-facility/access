import { createServerFn } from "@tanstack/react-start";
import { getRequest, setResponseHeader } from "@tanstack/react-start/server";
import { redirect } from "@tanstack/react-router";
import type { OperationName, Operations } from "../server/console";

/** The signed-in console admin, or nothing. */
export const getAdmin = createServerFn({ method: "GET" }).handler(async () => {
  setResponseHeader("Cache-Control", "private, no-store");
  const { consoleUser } = await import("../server/oidc");
  return consoleUser(getRequest()) ?? null;
});

const consoleRpc = createServerFn({ method: "POST" })
  .validator((data: { op: string; input?: unknown }) => {
    if (!data || typeof data.op !== "string") throw new Error("Invalid request.");
    return data;
  })
  .handler(async ({ data }) => {
    setResponseHeader("Cache-Control", "private, no-store");
    const request = getRequest();
    const { consoleUser, clientIp, publicUrl } = await import("../server/oidc");
    // Calls from a browser must come from this site.
    const origin = request.headers.get("origin");
    if (origin && origin !== new URL(publicUrl()).origin && origin !== new URL(request.url).origin) throw new Error("Cross-site request refused.");
    const admin = consoleUser(request);
    if (!admin) throw redirect({ to: "/admin/login", search: { next: undefined } });
    const { perform } = await import("../server/console");
    const { ApiError } = await import("../server/http");
    try {
      return JSON.parse(JSON.stringify((await perform({ admin, ip: clientIp(request) }, data.op, data.input)) ?? null));
    } catch (error) {
      if (error instanceof ApiError) throw new Error(error.message);
      throw error;
    }
  });

type Input<K extends OperationName> = Parameters<Operations[K]>[1];
type Output<K extends OperationName> = Awaited<ReturnType<Operations[K]>>;

/** Calls a console operation (src/server/console.ts) as the signed-in admin. */
export function call<K extends OperationName>(op: K, ...input: Input<K> extends undefined ? [] : [Input<K>]): Promise<Output<K>> {
  return consoleRpc({ data: { op, input: input[0] } }) as Promise<Output<K>>;
}
