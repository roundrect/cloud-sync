import type { DocInput, DocRecord, HistoryPage, PutResult, RevertResult, RevisionKind, RevisionStore, Writer } from "./ports";

// The rules of one document's revision log: If-Match, which kind a revision is, revert, retention and history paging.
// It is synchronous and knows nothing about where the rows live, so it works wherever the Durable Object's storage does.

export interface DocLog {
  rev(): number;
  /** The current document, or null for an empty one (rev 0). */
  getDoc(): DocRecord | null;
  /** Appends a revision if `ifMatch` is the current revision; otherwise reports the current document. */
  put(ifMatch: number, doc: DocInput, writer: Writer): PutResult;
  revert(rev: number, ifMatch: number, summary: string | null, writer: Writer): RevertResult;
  /** Newest first, metadata only. `before` is exclusive. */
  history(before: number | null, limit: number): HistoryPage;
  revision(rev: number): DocRecord | null;
}

export function createDocLog(store: RevisionStore): DocLog {
  const getDoc = (): DocRecord | null => store.get(store.currentRev());

  function append(ifMatch: number, doc: DocInput, writer: Writer, requested: "put" | "revert", revertedTo: number | null): PutResult {
    const record = store.transaction((): DocRecord | null => {
      const current = store.currentRev();
      if (current !== ifMatch) return null;
      const rev = current + 1;
      const kind: RevisionKind = requested === "put" && rev === 1 ? "bootstrap" : requested;
      const written: DocRecord = {
        rev,
        format: doc.format,
        schema: doc.schema,
        body: doc.body,
        sha256: doc.sha256,
        summary: doc.summary,
        updatedAt: new Date().toISOString(),
        deviceId: writer.deviceId,
        deviceName: writer.deviceName,
        kind,
        revertedTo,
      };
      store.insert(written);
      // Retention: keep the newest `historyLimit` revisions, pruned in the same transaction as the write.
      store.prune(rev - Math.max(1, writer.historyLimit));
      return written;
    });
    return record ? { ok: true, record } : { ok: false, current: getDoc() };
  }

  return {
    rev: () => store.currentRev(),
    getDoc,
    put: (ifMatch, doc, writer) => append(ifMatch, doc, writer, "put", null),

    revert(rev, ifMatch, summary, writer) {
      const target = store.get(rev);
      if (!target) {
        // A stale caller deserves the 409 (and the current document) before it learns the target is gone.
        if (ifMatch !== store.currentRev()) return { ok: false, current: getDoc() };
        return { ok: false, missing: true };
      }
      const doc: DocInput = {
        format: target.format,
        schema: target.schema,
        body: target.body,
        sha256: target.sha256,
        summary: summary && summary.length > 0 ? summary : `Revert to revision ${rev}`,
      };
      return append(ifMatch, doc, writer, "revert", rev);
    },

    history(before, limit) {
      const rows = store.list(before ?? Number.MAX_SAFE_INTEGER, limit + 1);
      const revisions = rows.slice(0, limit);
      const last = revisions[revisions.length - 1];
      return { revisions, nextBefore: rows.length > limit && last ? last.rev : null };
    },

    revision: (rev) => store.get(rev),
  };
}

/** The frame sent to every socket of a document after a write. */
export function docMessage(record: DocRecord): string {
  return JSON.stringify({
    type: "doc",
    rev: record.rev,
    format: record.format,
    schema: record.schema,
    body: record.body,
    sha256: record.sha256,
    deviceId: record.deviceId,
    deviceName: record.deviceName,
    summary: record.summary,
    kind: record.kind,
    updatedAt: record.updatedAt,
    ...(record.revertedTo !== null ? { revertedTo: record.revertedTo } : {}),
  });
}

export const helloMessage = (rev: number): string => JSON.stringify({ type: "hello", rev });

/** The text a client sends to keep a connection alive, and the reply. */
export const PING = '{"type":"ping"}';
export const PONG = '{"type":"pong"}';
