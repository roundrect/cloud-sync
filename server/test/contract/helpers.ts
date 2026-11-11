import { harness } from "@harness";
import { expect } from "vitest";
import type { RawSocket, Vars } from "../harness/types";

export { harness };

export interface Account {
  accountId: string;
  deviceId: string;
  token: string;
  /** The namespace the account was created in. */
  ns: string;
}

export interface Envelope {
  format: string;
  schema: number;
  body: string;
  sha256: string;
  summary: string;
}

export async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function envelope(body: string, summary = "test", format = "app-text"): Promise<Envelope> {
  return { format, schema: 1, body, sha256: await sha256(body), summary };
}

/** The namespace the tests use when they don't care which. */
export const NS = "app";

/** The path of a route in a namespace: `/v1/ns/<ns>/<route>`. */
export const route = (ns: string, path: string) => `/v1/ns/${ns}${path}`;

export interface CallOptions {
  token?: string;
  body?: unknown;
  headers?: Record<string, string>;
  /** Run this one request with these settings changed. */
  vars?: Vars;
}

export async function call(method: string, path: string, options: CallOptions = {}): Promise<Response> {
  const headers: Record<string, string> = { ...options.headers };
  if (options.token) headers.authorization = `Bearer ${options.token}`;
  let body: string | undefined;
  if (options.body !== undefined) {
    body = typeof options.body === "string" ? options.body : JSON.stringify(options.body);
    headers["content-type"] = "application/json";
  }
  return harness.request(method, path, { headers, body, vars: options.vars });
}

export async function jsonOf<T = Record<string, any>>(response: Response): Promise<T> {
  return (await response.json()) as T;
}

/** Creates a fresh account through the real bootstrap route, in a namespace (by default NS). */
export async function bootstrap(deviceName = "Mac mini", ns: string = NS): Promise<Account> {
  const response = await call("POST", route(ns, "/accounts"), { body: { invite: harness.invite, deviceName } });
  if (response.status !== 201) throw new Error(`bootstrap failed: ${response.status} ${await response.text()}`);
  const data = await jsonOf(response);
  return { accountId: data.accountId, deviceId: data.device.id, token: data.token, ns };
}

/**
 * Pairs a new device into `approver`'s account via the real pairing routes. The new device starts in `ns`
 * (default: the approver's namespace), so a different one is a cross-namespace approval.
 */
export async function pairDevice(approver: Account, deviceName: string, ns: string = approver.ns): Promise<Account> {
  const start = await jsonOf(await call("POST", route(ns, "/pair/start"), { body: { deviceName } }));
  const approve = await call("POST", route(approver.ns, "/pair/approve"), { token: approver.token, body: { code: start.code, confirm: true } });
  if (approve.status !== 200) throw new Error(`approve failed: ${approve.status} ${await approve.text()}`);
  const poll = await jsonOf(await call("POST", route(ns, "/pair/poll"), { body: { pairingId: start.pairingId, pollSecret: start.pollSecret } }));
  return { accountId: poll.accountId, deviceId: poll.device.id, token: poll.token, ns };
}

export async function putDoc(account: Account, ifMatch: number | string, body: string, summary = "test"): Promise<Response> {
  return call("PUT", route(account.ns, "/doc"), { token: account.token, headers: { "if-match": String(ifMatch) }, body: await envelope(body, summary) });
}

// ── sockets ──────────────────────────────────────────────────────────────

export interface Socket {
  raw: RawSocket;
  messages: any[];
  closed: Promise<{ code: number; reason: string }>;
  next(predicate?: (m: any) => boolean): Promise<any>;
}

export function wrap(raw: RawSocket): Socket {
  const messages: any[] = [];
  const waiters: Array<{ predicate: (m: any) => boolean; resolve: (m: any) => void }> = [];
  raw.onMessage((text) => {
    const message = JSON.parse(text);
    messages.push(message);
    for (const w of [...waiters]) {
      if (w.predicate(message)) {
        waiters.splice(waiters.indexOf(w), 1);
        w.resolve(message);
      }
    }
  });
  const closed = new Promise<{ code: number; reason: string }>((resolve) => raw.onClose((code, reason) => resolve({ code, reason })));
  const next = (predicate: (m: any) => boolean = () => true) =>
    new Promise<any>((resolve, reject) => {
      const existing = messages.find(predicate);
      if (existing) return resolve(existing);
      const timer = setTimeout(() => reject(new Error("timed out waiting for a WebSocket message")), 5000);
      waiters.push({ predicate, resolve: (m) => (clearTimeout(timer), resolve(m)) });
    });
  return { raw, messages, closed, next };
}

/** Opens the account's socket, expecting the upgrade to succeed. */
export async function connect(account: Account, path = route(account.ns, "/ws")): Promise<Socket> {
  const result = await harness.upgrade(path, account.token);
  expect(result.status).toBe(101);
  return wrap(result.socket!);
}
