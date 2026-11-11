// The seams between the portable core and a host (the Cloudflare Worker, which runs on Cloudflare or under celld).
// Nothing here imports from a runtime: a host implements these and hands them to `createApp`.

// ── configuration ────────────────────────────────────────────────────────

/** The deployment's settings, exactly as the host read them (strings, unparsed). `config.ts` parses and validates. */
export interface Config {
  /** Mixed into every stored token hash. Changing it signs every device out. */
  tokenPepper: string;
  /** The bootstrap passphrase for `POST /accounts`. Empty means nobody can create an account. */
  inviteSecret: string;
  /** Revisions kept per document, as a decimal string. */
  historyLimit: string;
  /** "1" turns the billing seam on. */
  enforceEntitlement: string;
  /** A JSON object: `{"<namespace>":"<version>"}`. */
  minClient: string;
}

// ── relational data (accounts, devices, pairings) ────────────────────────

export interface Statement {
  sql: string;
  params: readonly unknown[];
}

/** SQLite's dialect, async because D1 is. Parameters are positional `?`. */
export interface Sql {
  first<T>(sql: string, ...params: unknown[]): Promise<T | null>;
  all<T>(sql: string, ...params: unknown[]): Promise<T[]>;
  run(sql: string, ...params: unknown[]): Promise<{ changes: number }>;
  /** All statements or none. */
  batch(statements: Statement[]): Promise<void>;
}

// ── documents ────────────────────────────────────────────────────────────

export interface DocInput {
  format: string;
  schema: number;
  body: string;
  sha256: string;
  summary: string;
}

export type RevisionKind = "put" | "revert" | "bootstrap";

export interface DocRecord extends DocInput {
  rev: number;
  updatedAt: string;
  deviceId: string;
  deviceName: string;
  kind: RevisionKind;
  revertedTo: number | null;
}

export interface RevisionMeta {
  rev: number;
  createdAt: string;
  deviceId: string;
  deviceName: string;
  kind: RevisionKind;
  revertedTo?: number;
  summary: string;
}

export interface HistoryPage {
  revisions: RevisionMeta[];
  nextBefore: number | null;
}

export interface Writer {
  deviceId: string;
  deviceName: string;
  historyLimit: number;
}

export type PutResult = { ok: true; record: DocRecord } | { ok: false; current: DocRecord | null };
export type RevertResult = PutResult | { ok: false; missing: true };

/**
 * One document's revision log, synchronous so a host can run it inside a transaction.
 * The Durable Object keeps it in `meta` and `revisions` (keyed by `rev`).
 */
export interface RevisionStore {
  /** 0 for an empty document. Never goes backwards, even when old revisions are pruned. */
  currentRev(): number;
  get(rev: number): DocRecord | null;
  /** Metadata only, newest first, for revisions strictly below `before`. */
  list(before: number, limit: number): RevisionMeta[];
  /** Stores the revision and makes it current. */
  insert(record: DocRecord): void;
  /** Deletes every revision numbered `rev` or lower. */
  prune(rev: number): void;
  transaction<T>(fn: () => T): T;
}

/** A document as the app sees it, wherever it lives. */
export interface DocHandle {
  getDoc(): Promise<DocRecord | null>;
  put(ifMatch: number, doc: DocInput, writer: Writer): Promise<PutResult>;
  revert(rev: number, ifMatch: number, summary: string | null, writer: Writer): Promise<RevertResult>;
  history(before: number | null, limit: number): Promise<HistoryPage>;
  revision(rev: number): Promise<DocRecord | null>;
  /** Closes every socket the device holds on this document (revoke / unlink). */
  disconnect(deviceId: string): Promise<number>;
  /**
   * Answers an authenticated WebSocket upgrade for `deviceId`: the host returns the upgrade response
   * (the Durable Object's 101 with its client socket).
   */
  connect(request: Request, deviceId: string): Promise<Response>;
}

export interface Platform {
  sql: Sql;
  config: Config;
  /** `name` is `<account>:<namespace>`. */
  doc(name: string): DocHandle;
  /** Throws a 429 `HttpError` when the client behind `request` is over the unauthenticated pairing limit. */
  limitPairing(route: string, request: Request): Promise<void>;
}
