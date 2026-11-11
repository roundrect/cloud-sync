import type { Services } from "./config";
import { unauthorized } from "./errors";
import type { Statement } from "./ports";
import { base64url, nowISO, randomBytes, randomHex, safeEqual, sha256Hex } from "./util";

// Token format: shk1_<deviceId>_<32 random bytes, base64url>. deviceId = "dev_" + 16 hex.
// Only SHA-256(pepper || secret) is stored; the token is shown once, when the device is minted.
// The shk1 prefix is part of the format, not a brand: changing it would sign out every linked device.

const TOKEN_RE = /^shk1_(dev_[0-9a-f]{16})_([A-Za-z0-9_-]{43})$/;
const LAST_SEEN_GRANULARITY_MS = 5 * 60 * 1000;

export interface AuthedDevice {
  deviceId: string;
  deviceName: string;
  accountId: string;
  /** The namespace the device belongs to. */
  namespace: string;
  entitledUntil: string | null;
}

export function hashSecret(pepper: string, secret: string): Promise<string> {
  return sha256Hex(pepper + secret);
}

export interface MintedDevice {
  id: string;
  name: string;
  token: string;
}

/** The statement that inserts the device row, plus the one-time token. Callers run it (usually in a batch). */
export async function prepareDevice(
  svc: Services,
  accountId: string,
  name: string,
  namespace: string,
): Promise<{ statement: Statement; device: MintedDevice }> {
  const id = `dev_${randomHex(8)}`;
  const secret = base64url(randomBytes(32));
  const tokenHash = await hashSecret(svc.settings.tokenPepper, secret);
  const statement: Statement = {
    sql: "INSERT INTO devices (id, account_id, name, token_hash, created_at, namespace) VALUES (?, ?, ?, ?, ?, ?)",
    params: [id, accountId, name, tokenHash, nowISO(), namespace],
  };
  return { statement, device: { id, name, token: `shk1_${id}_${secret}` } };
}

export function newAccountId(): string {
  return `acc_${randomHex(8)}`;
}

/** Resolves `Authorization: Bearer <token>` to a live device, or throws 401. */
export async function authenticate(request: Request, svc: Services): Promise<AuthedDevice> {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer (.+)$/i.exec(header);
  const parts = match ? TOKEN_RE.exec(match[1]!.trim()) : null;
  if (!parts) throw unauthorized();
  const [, deviceId, secret] = parts as unknown as [string, string, string];

  const row = await svc.platform.sql.first<{
    id: string;
    name: string;
    account_id: string;
    namespace: string;
    token_hash: string;
    revoked_at: string | null;
    last_seen_at: string | null;
    entitled_until: string | null;
  }>(
    `SELECT d.id, d.name, d.account_id, d.namespace, d.token_hash, d.revoked_at, d.last_seen_at, a.entitled_until
       FROM devices d JOIN accounts a ON a.id = d.account_id WHERE d.id = ?`,
    deviceId,
  );
  if (!row) throw unauthorized();

  const ok = await safeEqual(row.token_hash, await hashSecret(svc.settings.tokenPepper, secret));
  if (!ok || row.revoked_at !== null) throw unauthorized();

  // Keep last_seen_at roughly current without a write on every request.
  const last = row.last_seen_at ? Date.parse(row.last_seen_at) : 0;
  if (Date.now() - last > LAST_SEEN_GRANULARITY_MS) {
    await svc.platform.sql.run("UPDATE devices SET last_seen_at = ? WHERE id = ?", nowISO(), row.id);
  }
  return { deviceId: row.id, deviceName: row.name, accountId: row.account_id, namespace: row.namespace, entitledUntil: row.entitled_until };
}
