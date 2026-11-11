import { HttpError } from "./errors";

export type Method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

export interface Route<H> {
  method: Method;
  /** e.g. "/v1/history/:rev" — `:name` segments match one path segment. */
  path: string;
  handler: H;
}

export interface Match<H> {
  handler: H;
  params: Record<string, string>;
}

/** A tiny hand router: exact segment matching with `:param` captures. 404 for no path, 405 for a wrong method. */
export function match<H>(routes: Route<H>[], method: string, pathname: string): Match<H> {
  const segments = pathname.replace(/\/+$/, "").split("/");
  let pathMatched = false;
  for (const route of routes) {
    const pattern = route.path.split("/");
    if (pattern.length !== segments.length) continue;
    const params: Record<string, string> = {};
    let ok = true;
    for (let i = 0; i < pattern.length; i++) {
      const p = pattern[i]!;
      const s = segments[i]!;
      if (p.startsWith(":")) params[p.slice(1)] = decodeURIComponent(s);
      else if (p !== s) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    pathMatched = true;
    if (route.method === method) return { handler: route.handler, params };
  }
  if (pathMatched) throw new HttpError(405, "method_not_allowed", "Method not allowed.");
  throw new HttpError(404, "not_found", "Not found.");
}
