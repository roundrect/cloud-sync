import { HttpError, badRequest } from "./errors";

const encoder = new TextEncoder();

export function toHex(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let out = "";
  for (const b of view) out += b.toString(16).padStart(2, "0");
  return out;
}

export function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function randomBytes(n: number): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(n));
}

export function randomHex(n: number): string {
  return toHex(randomBytes(n));
}

export async function sha256Hex(text: string): Promise<string> {
  return toHex(await crypto.subtle.digest("SHA-256", encoder.encode(text)));
}

/**
 * Constant-time equality of two strings. Both are hashed first, so lengths never leak, and the digests are
 * compared with an XOR loop (`crypto.subtle.timingSafeEqual` is a Workers extension, not part of Web Crypto).
 */
export async function safeEqual(a: string, b: string): Promise<boolean> {
  const [da, db] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(a)),
    crypto.subtle.digest("SHA-256", encoder.encode(b)),
  ]);
  const x = new Uint8Array(da);
  const y = new Uint8Array(db);
  let diff = x.length ^ y.length;
  for (let i = 0; i < x.length; i++) diff |= x[i]! ^ (y[i] ?? 0);
  return diff === 0;
}

export function byteLength(text: string): number {
  return encoder.encode(text).byteLength;
}

export const nowISO = () => new Date().toISOString();

/** Reads a JSON object body, refusing anything over `maxBytes` before parsing. */
export async function readJson(request: Request, maxBytes = 1024 * 1024): Promise<Record<string, unknown>> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > maxBytes) throw new HttpError(413, "too_large", "Request body is too large.");
  const text = await request.text();
  if (byteLength(text) > maxBytes) throw new HttpError(413, "too_large", "Request body is too large.");
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw badRequest("Body must be valid JSON.");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw badRequest("Body must be a JSON object.");
  return value as Record<string, unknown>;
}

/** A device name: trimmed, no control characters, 1–80 characters. */
export function cleanDeviceName(value: unknown): string {
  if (typeof value !== "string") throw badRequest("deviceName must be a string.");
  const name = value.replace(/[\u0000-\u001f\u007f]/g, "").trim();
  if (name.length < 1 || name.length > 80) throw badRequest("deviceName must be 1–80 characters.");
  return name;
}

/** Compares dotted numeric versions ("0.2.30" < "0.3.0"). Non-numeric parts count as 0. */
export function compareVersions(a: string, b: string): number {
  const pa = a.split(".").map((p) => parseInt(p, 10) || 0);
  const pb = b.split(".").map((p) => parseInt(p, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d < 0 ? -1 : 1;
  }
  return 0;
}
