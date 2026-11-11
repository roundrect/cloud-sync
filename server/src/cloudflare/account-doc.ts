import { DurableObject } from "cloudflare:workers";
import { createDocLog, docMessage, helloMessage, PING, PONG, type DocLog } from "../core/doc-log";
import type { DocInput, DocRecord, HistoryPage, PutResult, RevertResult, RevisionMeta, RevisionStore, Writer } from "../core/ports";

// One SQLite-backed Durable Object per document (030, D2): the revision log, the current revision
// number and the hibernated WebSockets of the devices on it. `body` is opaque to this class.
// The class keeps the name AccountDoc, which the Durable Object migration tag refers to; its objects are named
// `<account>:<namespace>`.

export type { DocInput, DocRecord, PutResult, RevertResult, RevisionMeta, Writer };

interface RevisionRow extends Record<string, SqlStorageValue> {
  rev: number;
  created_at: string;
  device_id: string;
  device_name: string;
  kind: DocRecord["kind"];
  reverted_to: number | null;
  summary: string;
  format: string;
  schema: number;
  body: string;
  sha256: string;
}

function toRecord(row: RevisionRow): DocRecord {
  return {
    rev: row.rev,
    format: row.format,
    schema: row.schema,
    body: row.body,
    sha256: row.sha256,
    summary: row.summary,
    updatedAt: row.created_at,
    deviceId: row.device_id,
    deviceName: row.device_name,
    kind: row.kind,
    revertedTo: row.reverted_to,
  };
}

/** The Durable Object's own tables, `meta` and `revisions` (keyed by `rev`), exactly as deployed. */
class DurableRevisionStore implements RevisionStore {
  constructor(private readonly storage: DurableObjectStorage) {}

  currentRev(): number {
    return this.storage.sql.exec<{ current_rev: number }>("SELECT current_rev FROM meta WHERE id = 1").one().current_rev;
  }

  get(rev: number): DocRecord | null {
    const row = this.storage.sql.exec<RevisionRow>("SELECT * FROM revisions WHERE rev = ?", rev).toArray()[0];
    return row ? toRecord(row) : null;
  }

  list(before: number, limit: number): RevisionMeta[] {
    return this.storage.sql
      .exec<RevisionRow>(
        "SELECT rev, created_at, device_id, device_name, kind, reverted_to, summary FROM revisions WHERE rev < ? ORDER BY rev DESC LIMIT ?",
        before,
        limit,
      )
      .toArray()
      .map((r): RevisionMeta => {
        const meta: RevisionMeta = { rev: r.rev, createdAt: r.created_at, deviceId: r.device_id, deviceName: r.device_name, kind: r.kind, summary: r.summary };
        if (r.reverted_to !== null) meta.revertedTo = r.reverted_to;
        return meta;
      });
  }

  insert(r: DocRecord): void {
    const sql = this.storage.sql;
    sql.exec(
      `INSERT INTO revisions (rev, created_at, device_id, device_name, kind, reverted_to, summary, format, schema, body, sha256)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      r.rev, r.updatedAt, r.deviceId, r.deviceName, r.kind, r.revertedTo, r.summary, r.format, r.schema, r.body, r.sha256,
    );
    sql.exec("UPDATE meta SET current_rev = ? WHERE id = 1", r.rev);
  }

  prune(rev: number): void {
    this.storage.sql.exec("DELETE FROM revisions WHERE rev <= ?", rev);
  }

  transaction<T>(fn: () => T): T {
    return this.storage.transactionSync(fn);
  }
}

export class AccountDoc extends DurableObject<Env> {
  private readonly log: DocLog;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS meta (
          id          INTEGER PRIMARY KEY CHECK (id = 1),
          current_rev INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO meta (id, current_rev) VALUES (1, 0);
        CREATE TABLE IF NOT EXISTS revisions (
          rev         INTEGER PRIMARY KEY,
          created_at  TEXT NOT NULL,
          device_id   TEXT NOT NULL,
          device_name TEXT NOT NULL,
          kind        TEXT NOT NULL CHECK (kind IN ('put', 'revert', 'bootstrap')),
          reverted_to INTEGER,
          summary     TEXT NOT NULL,
          format      TEXT NOT NULL,
          schema      INTEGER NOT NULL,
          body        TEXT NOT NULL,
          sha256      TEXT NOT NULL
        );
      `);
    });
    this.log = createDocLog(new DurableRevisionStore(ctx.storage));
    // Answered by the runtime without waking the object (the client's protocol pings are free anyway).
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
  }

  // ── RPC ────────────────────────────────────────────────────────────────

  /** The current document, or null for an empty one (rev 0). */
  getDoc(): DocRecord | null {
    return this.log.getDoc();
  }

  rev(): number {
    return this.log.rev();
  }

  put(ifMatch: number, doc: DocInput, writer: Writer): PutResult {
    const result = this.log.put(ifMatch, doc, writer);
    if (result.ok) this.broadcast(result.record);
    return result;
  }

  revert(rev: number, ifMatch: number, summary: string | null, writer: Writer): RevertResult {
    const result = this.log.revert(rev, ifMatch, summary, writer);
    if (result.ok) this.broadcast(result.record);
    return result;
  }

  history(before: number | null, limit: number): HistoryPage {
    return this.log.history(before, limit);
  }

  revision(rev: number): DocRecord | null {
    return this.log.revision(rev);
  }

  /** Closes every socket the device holds (revoke / unlink). Returns how many were closed. */
  disconnect(deviceId: string): number {
    const sockets = this.ctx.getWebSockets(deviceId);
    for (const ws of sockets) {
      try {
        ws.close(4401, "revoked");
      } catch {
        // already closing
      }
    }
    return sockets.length;
  }

  // ── WebSocket (Hibernation API) ────────────────────────────────────────

  /** The Worker forwards an authenticated upgrade here with the device in headers. */
  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket upgrade.", { status: 426 });
    }
    const deviceId = request.headers.get("x-sync-device-id");
    if (!deviceId) return new Response("Missing device.", { status: 400 });

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.ctx.acceptWebSocket(server, [deviceId]);
    server.send(helloMessage(this.log.rev()));
    return new Response(null, { status: 101, webSocket: client });
  }

  // The only message a client sends is the ping, which the auto-response answers. Anything else is ignored:
  // writes go over HTTPS so that If-Match and the status codes stay simple.
  override webSocketMessage(_ws: WebSocket, _message: string | ArrayBuffer): void {}

  override webSocketClose(ws: WebSocket, code: number, _reason: string, _wasClean: boolean): void {
    try {
      // 1005/1006/1015 are reserved and can't be sent in a close frame.
      ws.close(code >= 1000 && code <= 4999 && ![1005, 1006, 1015].includes(code) ? code : 1000, "closing");
    } catch {
      // already closed
    }
  }

  override webSocketError(ws: WebSocket, _error: unknown): void {
    try {
      ws.close(1011, "error");
    } catch {
      // already closed
    }
  }

  // ── internals ──────────────────────────────────────────────────────────

  private broadcast(record: DocRecord): void {
    const message = docMessage(record);
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(message);
      } catch {
        // a dead socket is cleaned up by webSocketClose / webSocketError
      }
    }
  }
}
