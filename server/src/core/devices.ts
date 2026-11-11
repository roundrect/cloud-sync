import type { AuthedDevice } from "./auth";
import type { Services } from "./config";
import { badRequest, json, notFound } from "./errors";
import { docName } from "./namespace";
import { cleanDeviceName, nowISO, readJson } from "./util";

interface DeviceRow {
  id: string;
  name: string;
  namespace: string;
  created_at: string;
  last_seen_at: string | null;
}

const COLUMNS = "id, name, namespace, created_at, last_seen_at";

function view(row: DeviceRow, currentId: string) {
  return {
    id: row.id,
    name: row.name,
    namespace: row.namespace,
    createdAt: row.created_at,
    lastSeenAt: row.last_seen_at,
    current: row.id === currentId,
  };
}

/** Lists the whole account: a Mac shows once per app it has linked. */
export async function listDevices(svc: Services, auth: AuthedDevice): Promise<Response> {
  const rows = await svc.platform.sql.all<DeviceRow>(
    `SELECT ${COLUMNS} FROM devices WHERE account_id = ? AND revoked_at IS NULL ORDER BY created_at, id`,
    auth.accountId,
  );
  return json({ devices: rows.map((r) => view(r, auth.deviceId)) });
}

// Rename and revoke work only within the caller's namespace, so a leaked token can't sign another app out.

export async function renameDevice(request: Request, svc: Services, auth: AuthedDevice, id: string): Promise<Response> {
  const body = await readJson(request, 4096);
  if (body.name === undefined) throw badRequest("name is required.");
  const name = cleanDeviceName(body.name);
  const row = await svc.platform.sql.first<DeviceRow>(
    `UPDATE devices SET name = ? WHERE id = ? AND account_id = ? AND revoked_at IS NULL AND namespace = ? RETURNING ${COLUMNS}`,
    name,
    id,
    auth.accountId,
    auth.namespace,
  );
  if (!row) throw notFound("No such device.");
  return json(view(row, auth.deviceId));
}

/** Revokes a device of the caller's account and namespace (including the caller itself: that is "unlink"). */
export async function revokeDevice(svc: Services, auth: AuthedDevice, id: string): Promise<Response> {
  const row = await svc.platform.sql.first<{ id: string }>(
    `UPDATE devices SET revoked_at = ? WHERE id = ? AND account_id = ? AND revoked_at IS NULL AND namespace = ? RETURNING id`,
    nowISO(),
    id,
    auth.accountId,
    auth.namespace,
  );
  if (!row) throw notFound("No such device.");
  // Close its live sockets, so it learns immediately rather than at its next request.
  await svc.platform.doc(docName(auth.accountId, auth.namespace)).disconnect(id);
  return json({ revoked: true, id });
}
