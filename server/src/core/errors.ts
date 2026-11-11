// One JSON error shape for the whole API: {"error": "<machine_code>", "message": "<human text>"}.

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
  }
}

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

export function errorResponse(status: number, code: string, message: string, headers: Record<string, string> = {}): Response {
  return json({ error: code, message }, status, headers);
}

export const unauthorized = (message = "Missing, invalid or revoked token.") => new HttpError(401, "unauthorized", message);
export const badRequest = (message: string) => new HttpError(400, "bad_request", message);
export const notFound = (message = "Not found.") => new HttpError(404, "not_found", message);
export const namespaceMismatch = () =>
  new HttpError(403, "namespace_mismatch", "This token belongs to a different namespace.");

