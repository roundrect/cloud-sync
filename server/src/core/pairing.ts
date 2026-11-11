import { prepareDevice, type AuthedDevice } from "./auth";
import type { Services } from "./config";
import { HttpError, badRequest, json, namespaceMismatch } from "./errors";
import { base64url, cleanDeviceName, nowISO, randomBytes, randomHex, readJson, safeEqual, sha256Hex } from "./util";

// Pairing (030, D5): the new Mac asks for a code, an already-linked Mac approves it, and the new Mac's
// poll mints its device + token at that moment. The code is 8 Crockford base32 characters, stored hashed.
// A pairing belongs to the namespace of the route that started it, and its device is minted into that namespace.

export const PAIRING_TTL_SECONDS = 600;
export const APPROVE_FAILURE_LIMIT = 5;
export const APPROVE_FAILURE_WINDOW_MS = 10 * 60 * 1000;

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford: no I, L, O, U

function newCode(): string {
  let code = "";
  for (const b of randomBytes(8)) code += ALPHABET[b & 31]; // 256 % 32 == 0, so no modulo bias
  return code;
}

export function formatCode(code: string): string {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

/** Accepts "k7qf-m2xd", "K7QF M2XD", Crockford look-alikes (O→0, I/L→1); returns null if not 8 valid characters. */
export function normalizeCode(input: unknown): string | null {
  if (typeof input !== "string") return null;
  const code = input.toUpperCase().replace(/[\s-]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
  return code.length === 8 && [...code].every((c) => ALPHABET.includes(c)) ? code : null;
}

const codeHash = (svc: Services, code: string) => sha256Hex(`pair-code:${svc.settings.tokenPepper}:${code}`);
const secretHash = (svc: Services, secret: string) => sha256Hex(`pair-poll:${svc.settings.tokenPepper}:${secret}`);

export async function pairStart(request: Request, svc: Services, namespace: string): Promise<Response> {
  await svc.platform.limitPairing("start", request);
  const body = await readJson(request, 4096);
  const deviceName = cleanDeviceName(body.deviceName);
  const sql = svc.platform.sql;

  const now = new Date();
  await sql.run("DELETE FROM pairings WHERE expires_at < ?", now.toISOString());

  const pairingId = `pair_${randomHex(8)}`;
  const pollSecret = base64url(randomBytes(32));
  const expiresAt = new Date(now.getTime() + PAIRING_TTL_SECONDS * 1000).toISOString();

  for (let attempt = 0; attempt < 5; attempt++) {
    const code = newCode();
    try {
      await sql.run(
        "INSERT INTO pairings (id, code_hash, poll_secret_hash, device_name, created_at, expires_at, namespace) VALUES (?, ?, ?, ?, ?, ?, ?)",
        pairingId,
        await codeHash(svc, code),
        await secretHash(svc, pollSecret),
        deviceName,
        now.toISOString(),
        expiresAt,
        namespace,
      );
      return json({ pairingId, code: formatCode(code), pollSecret, expiresIn: PAIRING_TTL_SECONDS }, 201);
    } catch (error) {
      if (!String(error).includes("UNIQUE")) throw error; // a code collision: draw another
    }
  }
  throw new HttpError(500, "internal", "Could not allocate a pairing code.");
}

export async function pairPoll(request: Request, svc: Services, namespace: string): Promise<Response> {
  await svc.platform.limitPairing("poll", request);
  const body = await readJson(request, 4096);
  if (typeof body.pairingId !== "string" || typeof body.pollSecret !== "string") throw badRequest("pairingId and pollSecret are required.");
  const sql = svc.platform.sql;

  const row = await sql.first<{
    id: string;
    poll_secret_hash: string;
    device_name: string;
    account_id: string | null;
    approved_by: string | null;
    namespace: string;
    expires_at: string;
  }>("SELECT id, poll_secret_hash, device_name, account_id, approved_by, namespace, expires_at FROM pairings WHERE id = ?", body.pairingId);
  // An unknown id, a wrong secret, a consumed pairing and a pairing from another namespace all look the same.
  if (!row || !(await safeEqual(row.poll_secret_hash, await secretHash(svc, body.pollSecret)))) return json({ status: "expired" });
  if (row.namespace !== namespace) return json({ status: "expired" });

  if (row.expires_at < nowISO()) {
    await sql.run("DELETE FROM pairings WHERE id = ?", row.id);
    return json({ status: "expired" });
  }
  if (row.account_id === null) return json({ status: "pending" });

  // Consume atomically: only the poll that deletes the row gets to mint the device.
  const consumed = await sql.first<{ account_id: string }>("DELETE FROM pairings WHERE id = ? AND account_id IS NOT NULL RETURNING account_id", row.id);
  if (!consumed) return json({ status: "expired" });
  if (!(await approvalStillHolds(svc, consumed.account_id, namespace, row.approved_by))) return json({ status: "expired" });

  const { statement, device } = await prepareDevice(svc, consumed.account_id, row.device_name, namespace);
  await sql.run(statement.sql, ...statement.params);
  return json({ status: "approved", accountId: consumed.account_id, device: { id: device.id, name: device.name }, token: device.token });
}

/**
 * A device may approve a pairing for its own namespace, or for a namespace in which the account has no device at all
 * (revoked ones count): there is nothing there to read. Anything else could let a leaked token in one app mint a token
 * for another, so it is refused, and before the preview so the device name isn't disclosed.
 */
async function checkApproverMayJoin(svc: Services, auth: AuthedDevice, target: string): Promise<void> {
  if (target !== auth.namespace && (await namespaceHasDevice(svc, auth.accountId, target))) throw namespaceMismatch();
}

async function namespaceHasDevice(svc: Services, accountId: string, namespace: string): Promise<boolean> {
  const row = await svc.platform.sql.first<{ n: number }>("SELECT 1 AS n FROM devices WHERE account_id = ? AND namespace = ? LIMIT 1", accountId, namespace);
  return row !== null;
}

/**
 * The device is minted at the poll, up to PAIRING_TTL_SECONDS after the approval. An approval from another namespace
 * was only safe while the target was empty, so it lapses if the target has gained a device: otherwise a leaked token
 * could approve a pairing into an empty namespace and collect it once an app had moved in.
 */
async function approvalStillHolds(svc: Services, accountId: string, namespace: string, approvedBy: string | null): Promise<boolean> {
  const approver = approvedBy ? await svc.platform.sql.first<{ namespace: string }>("SELECT namespace FROM devices WHERE id = ?", approvedBy) : null;
  if (approver && approver.namespace === namespace) return true;
  return !(await namespaceHasDevice(svc, accountId, namespace));
}

export async function pairApprove(request: Request, svc: Services, auth: AuthedDevice): Promise<Response> {
  const sql = svc.platform.sql;
  const now = new Date();
  const since = new Date(now.getTime() - APPROVE_FAILURE_WINDOW_MS).toISOString();
  const failures = await sql.first<{ n: number }>("SELECT COUNT(*) AS n FROM approve_failures WHERE device_id = ? AND at >= ?", auth.deviceId, since);
  if ((failures?.n ?? 0) >= APPROVE_FAILURE_LIMIT) {
    throw new HttpError(429, "rate_limited", "Too many wrong codes. Try again in a few minutes.", { "retry-after": "600" });
  }

  const body = await readJson(request, 4096);
  const code = normalizeCode(body.code);
  const row = code
    ? await sql.first<{ id: string; device_name: string; account_id: string | null; namespace: string }>(
        "SELECT id, device_name, account_id, namespace FROM pairings WHERE code_hash = ? AND expires_at >= ?",
        await codeHash(svc, code),
        now.toISOString(),
      )
    : null;

  const invalid = () => new HttpError(404, "invalid_code", "That code is wrong or has expired.");
  if (!row || row.account_id !== null) {
    await sql.batch([
      { sql: "DELETE FROM approve_failures WHERE at < ?", params: [since] },
      { sql: "INSERT INTO approve_failures (device_id, at) VALUES (?, ?)", params: [auth.deviceId, now.toISOString()] },
    ]);
    throw invalid();
  }

  const target = row.namespace;
  await checkApproverMayJoin(svc, auth, target);

  if (body.confirm !== true) return json({ deviceName: row.device_name, namespace: target });

  const result = await sql.run(
    "UPDATE pairings SET account_id = ?, approved_by = ? WHERE id = ? AND account_id IS NULL AND expires_at >= ?",
    auth.accountId,
    auth.deviceId,
    row.id,
    now.toISOString(),
  );
  if (result.changes !== 1) throw invalid();
  return json({ approved: true, deviceName: row.device_name });
}
