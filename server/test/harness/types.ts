import type { Sql } from "../../src/core/ports";

// What the contract tests (test/contract/) need from an adapter. test/harness/workers.ts and celld.ts implement it;
// the `@harness` alias picks one per vitest project, so every contract test runs against both hosts.

/** Settings a single request can run under. The other host-specific ones (secrets) are fixed. */
export interface Vars {
  historyLimit?: string;
  enforceEntitlement?: string;
  minClient?: string;
  /** "refuse": the pairing rate limit says no. "absent": there is no limiter at all. */
  pairLimiter?: "refuse" | "absent";
}

export interface RawSocket {
  send(text: string): void;
  close(code?: number): void;
  onMessage(callback: (text: string) => void): void;
  onClose(callback: (code: number, reason: string) => void): void;
}

export interface UpgradeResult {
  status: number;
  /** The body of a refusal. */
  text?: string;
  /** Present when the upgrade succeeded (status 101). */
  socket?: RawSocket;
}

export interface Harness {
  readonly kind: "workers" | "celld";
  /** The bootstrap passphrase for POST /accounts. */
  readonly invite: string;
  /** Direct access to the relational tables, for the tests that need to seed or inspect a row. */
  readonly sql: Sql;
  request(method: string, path: string, init: { headers?: Record<string, string>; body?: string; vars?: Vars }): Promise<Response>;
  /** Attempts a WebSocket upgrade. */
  upgrade(path: string, token?: string): Promise<UpgradeResult>;
  /** Revisions held for a document, by its name (`<account>:<namespace>`). */
  revisionCount(docName: string): Promise<number>;
}
