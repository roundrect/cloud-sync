import { authenticate, newAccountId, prepareDevice, type AuthedDevice } from "./auth";
import { NO_MINIMUM, parseConfig, type Services, type Settings } from "./config";
import { listDevices, renameDevice, revokeDevice } from "./devices";
import { checkEntitlement } from "./entitlement";
import { HttpError, badRequest, errorResponse, json, namespaceMismatch, notFound } from "./errors";
import { docName, isSlug } from "./namespace";
import { pairApprove, pairPoll, pairStart } from "./pairing";
import type { DocHandle, DocInput, DocRecord, Platform } from "./ports";
import { match, type Route } from "./router";
import { byteLength, cleanDeviceName, compareVersions, readJson, safeEqual, sha256Hex } from "./util";

// The sync API. Every route is under /v1; changes within v1 are additive only.
// Every route is /v1/ns/:namespace/<route>; the /ns/ segment keeps a slug from colliding with a route name.
// The one exception is GET /v1/meta, a namespace-free, unauthenticated probe that answers just {api}.

const API_VERSION = 1;
const MAX_BODY_BYTES = 512 * 1024;
/** Every well-formed format is accepted; what a format means is between the apps that write and read it. */
const FORMAT_RE = /^[a-z0-9][a-z0-9.+-]{0,63}$/;

interface Ctx {
  request: Request;
  url: URL;
  params: Record<string, string>;
  svc: Services;
  /** The namespace the route names. Empty only for the namespace-free /v1/meta. */
  ns: string;
  /** Set for routes with auth: "token" or "doc". */
  auth: AuthedDevice;
  /** The namespace's document; set only for routes with auth: "doc". */
  doc: DocHandle;
}
type Handler = { auth: "none" | "token" | "doc"; run: (c: Ctx) => Promise<Response> };

const base: Route<Handler>[] = [
  { method: "GET", path: "/meta", handler: { auth: "none", run: namespaceMeta } },
  { method: "POST", path: "/accounts", handler: { auth: "none", run: createAccount } },
  { method: "POST", path: "/pair/start", handler: { auth: "none", run: (c) => pairStart(c.request, c.svc, c.ns) } },
  { method: "POST", path: "/pair/poll", handler: { auth: "none", run: (c) => pairPoll(c.request, c.svc, c.ns) } },
  { method: "POST", path: "/pair/approve", handler: { auth: "token", run: (c) => pairApprove(c.request, c.svc, c.auth) } },
  { method: "GET", path: "/doc", handler: { auth: "doc", run: getDoc } },
  { method: "PUT", path: "/doc", handler: { auth: "doc", run: putDoc } },
  { method: "GET", path: "/history", handler: { auth: "doc", run: history } },
  { method: "GET", path: "/history/:rev", handler: { auth: "doc", run: revision } },
  { method: "POST", path: "/revert", handler: { auth: "doc", run: revert } },
  { method: "GET", path: "/devices", handler: { auth: "token", run: (c) => listDevices(c.svc, c.auth) } },
  { method: "PATCH", path: "/devices/:id", handler: { auth: "token", run: (c) => renameDevice(c.request, c.svc, c.auth, c.params.id!) } },
  { method: "DELETE", path: "/devices/:id", handler: { auth: "token", run: (c) => revokeDevice(c.svc, c.auth, c.params.id!) } },
  { method: "GET", path: "/ws", handler: { auth: "doc", run: websocket } },
];

const routes: Route<Handler>[] = [
  { method: "GET", path: "/v1/meta", handler: { auth: "none", run: probe } },
  ...base.map((r) => ({ ...r, path: `/v1/ns/:namespace${r.path}` })),
];

/** The whole API as one function: a Request in, a Response out. Hosts supply the Platform. */
export function createApp(platform: Platform): (request: Request) => Promise<Response> {
  return async (request) => {
    try {
      return await dispatch(request, platform);
    } catch (error) {
      if (error instanceof HttpError) return errorResponse(error.status, error.code, error.message, error.headers);
      console.error("unhandled error", error);
      return errorResponse(500, "internal", "Internal error.");
    }
  };
}

async function dispatch(request: Request, platform: Platform): Promise<Response> {
  const url = new URL(request.url);
  const { handler, params } = match(routes, request.method, url.pathname);
  const svc: Services = { platform, settings: parseConfig(platform.config) };

  if (handler.run === probe) return handler.run({ request, url, params, svc, ns: "" } as Ctx);
  const ns = params.namespace!;
  if (!isSlug(ns)) throw new HttpError(400, "bad_namespace", "A namespace is lowercase letters, digits and hyphens, starting with a letter.");

  if (handler.auth === "none") {
    if (handler.run !== namespaceMeta) checkClientVersion(request, svc.settings, ns);
    return handler.run({ request, url, params, svc, ns } as Ctx);
  }

  checkClientVersion(request, svc.settings, ns);
  const auth = await authenticate(request, svc);
  // Before entitlement and before any document is touched: a token belongs to one namespace.
  if (auth.namespace !== ns) throw namespaceMismatch();
  const ctx = { request, url, params, svc, ns, auth } as Ctx;
  if (handler.auth === "doc") {
    // The one place the billing seam is consulted, before any document is touched.
    const refused = checkEntitlement(svc.settings, auth);
    if (refused) return refused;
    ctx.doc = platform.doc(docName(auth.accountId, ns));
  }
  return handler.run(ctx);
}

/** 426 when `Sync-Client` names a version below the namespace's minimum. A missing header (curl, scripts) is allowed. */
function checkClientVersion(request: Request, settings: Settings, ns: string): void {
  const client = request.headers.get("sync-client");
  const minimum = settings.minimums[ns];
  if (client && minimum && compareVersions(client, minimum) < 0) {
    throw new HttpError(426, "upgrade_required", `Update the app to keep syncing (need ${minimum} or newer).`);
  }
}

// ── handlers ─────────────────────────────────────────────────────────────

/** GET /v1/meta: a probe that needs no namespace and publishes nothing else. */
async function probe(): Promise<Response> {
  return json({ api: API_VERSION });
}

async function namespaceMeta(c: Ctx): Promise<Response> {
  return json({ api: API_VERSION, minClient: c.svc.settings.minimums[c.ns] ?? NO_MINIMUM });
}

async function createAccount(c: Ctx): Promise<Response> {
  checkClientVersion(c.request, c.svc.settings, c.ns);
  const body = await readJson(c.request, 4096);
  const deviceName = cleanDeviceName(body.deviceName);
  const invite = typeof body.invite === "string" ? body.invite : "";
  const secret = c.svc.settings.inviteSecret;
  // Fail closed: with no INVITE_SECRET configured nobody can create an account.
  if (!secret || !invite || !(await safeEqual(invite, secret))) {
    throw new HttpError(401, "invalid_invite", "That invite is not valid.");
  }
  const accountId = newAccountId();
  const { statement, device } = await prepareDevice(c.svc, accountId, deviceName, c.ns);
  await c.svc.platform.sql.batch([
    { sql: "INSERT INTO accounts (id, created_at) VALUES (?, ?)", params: [accountId, new Date().toISOString()] },
    statement,
  ]);
  return json({ accountId, device: { id: device.id, name: device.name }, token: device.token }, 201);
}

/** The wire shape of a document (`GET /v1/doc`, a 409 body). An empty account is just {rev: 0}. */
function docBody(record: DocRecord | null): Record<string, unknown> {
  if (!record) return { rev: 0 };
  const { kind: _kind, revertedTo: _revertedTo, ...doc } = record;
  return doc;
}

const etag = (rev: number) => ({ etag: `"${rev}"` });

async function getDoc(c: Ctx): Promise<Response> {
  const record = await c.doc.getDoc();
  return json(docBody(record), 200, etag(record?.rev ?? 0));
}

/** `If-Match: 3`, `"3"` or `W/"3"` → 3. */
function parseIfMatch(value: string): number | null {
  const m = /^(?:W\/)?"?(\d{1,15})"?$/.exec(value.trim());
  return m ? Number(m[1]) : null;
}

async function putDoc(c: Ctx): Promise<Response> {
  const header = c.request.headers.get("if-match");
  if (header === null) throw new HttpError(428, "precondition_required", "If-Match: <rev> is required (0 for an empty account).");
  const ifMatch = parseIfMatch(header);
  if (ifMatch === null) throw badRequest("If-Match must be a revision number.");

  const body = await readJson(c.request, MAX_BODY_BYTES + 64 * 1024);
  const { format, schema, body: text, sha256, summary } = body;
  if (typeof text !== "string" || typeof sha256 !== "string" || typeof format !== "string") {
    throw badRequest("format, schema, body and sha256 are required strings/numbers.");
  }
  if (!Number.isInteger(schema) || (schema as number) < 1 || (schema as number) > 1000) throw badRequest("schema must be a positive integer.");
  if (byteLength(text) > MAX_BODY_BYTES) throw new HttpError(413, "too_large", "The document is over 512 KB.");
  if (!FORMAT_RE.test(format)) throw new HttpError(422, "unsupported_format", "format must be lowercase letters, digits and . + - (up to 64 characters).");
  if ((await sha256Hex(text)) !== sha256.toLowerCase()) throw new HttpError(422, "checksum_mismatch", "sha256 does not match the body.");

  const doc: DocInput = {
    format,
    schema: schema as number,
    body: text,
    sha256: sha256.toLowerCase(),
    summary: typeof summary === "string" ? summary.slice(0, 2000) : "",
  };
  const result = await c.doc.put(ifMatch, doc, writer(c));
  if (!result.ok) return conflict(result.current);
  return json({ rev: result.record.rev }, 200, etag(result.record.rev));
}

function writer(c: Ctx) {
  return { deviceId: c.auth.deviceId, deviceName: c.auth.deviceName, historyLimit: c.svc.settings.historyLimit };
}

/** 409 carrying the current document, so the client can merge without another round trip. */
function conflict(current: DocRecord | null): Response {
  const rev = current?.rev ?? 0;
  return json({ ...docBody(current), error: "conflict", message: "The document changed; merge and retry with the new revision." }, 409, etag(rev));
}

function intParam(value: string | null, name: string, min: number, max: number): number | null {
  if (value === null) return null;
  if (!/^\d{1,15}$/.test(value)) throw badRequest(`${name} must be an integer.`);
  const n = Number(value);
  if (n < min || n > max) throw badRequest(`${name} must be between ${min} and ${max}.`);
  return n;
}

async function history(c: Ctx): Promise<Response> {
  const before = intParam(c.url.searchParams.get("before"), "before", 1, Number.MAX_SAFE_INTEGER);
  const limit = intParam(c.url.searchParams.get("limit"), "limit", 1, 200) ?? 50;
  return json(await c.doc.history(before, limit));
}

async function revision(c: Ctx): Promise<Response> {
  const rev = intParam(c.params.rev ?? null, "rev", 1, Number.MAX_SAFE_INTEGER);
  const record = rev === null ? null : await c.doc.revision(rev);
  if (!record) throw notFound("No such revision (it may have been pruned).");
  const { revertedTo, ...rest } = record;
  return json(revertedTo === null ? rest : { ...rest, revertedTo });
}

async function revert(c: Ctx): Promise<Response> {
  const body = await readJson(c.request, 16 * 1024);
  const { rev, ifMatch, summary } = body;
  if (!Number.isInteger(rev) || (rev as number) < 1) throw badRequest("rev must be a positive integer.");
  if (!Number.isInteger(ifMatch) || (ifMatch as number) < 0) throw badRequest("ifMatch must be a revision number.");
  const text = typeof summary === "string" ? summary.slice(0, 2000) : null;
  const result = await c.doc.revert(rev as number, ifMatch as number, text, writer(c));
  if (result.ok) return json({ rev: result.record.rev }, 200, etag(result.record.rev));
  if ("missing" in result) throw notFound("No such revision (it may have been pruned).");
  return conflict(result.current);
}

async function websocket(c: Ctx): Promise<Response> {
  if (c.request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    throw new HttpError(400, "websocket_required", "This endpoint needs a WebSocket upgrade.");
  }
  return c.doc.connect(c.request, c.auth.deviceId);
}
