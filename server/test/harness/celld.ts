import { WebSocket } from "ws";
import { afterAll } from "vitest";
import type { Sql } from "../../src/core/ports";
import { INVITE, makeProject, removeProject, startCelld } from "../celld/project";
import { bufferedSocket } from "./socket";
import type { Harness } from "./types";

// The Worker as `celld dev` runs it: a real celld process per test file (as Miniflare gives each file its own storage),
// over HTTP and real sockets, running test/celld/entry.ts, which is src/celld/index.ts plus the /__test hooks below.

const dir = makeProject();
const celld = await startCelld(dir).catch((error) => {
  removeProject(dir);
  throw error;
});
afterAll(async () => {
  await celld.stop();
  removeProject(dir);
});

async function test<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`${celld.url}/__test/${path}`, init);
  if (!response.ok) throw new Error(`/__test/${path}: ${response.status} ${await response.text()}`);
  return (await response.json()) as T;
}

const call = <T>(body: unknown) => test<T>("sql", { method: "POST", body: JSON.stringify(body) });

/** The `Sql` port, served by the test entry's D1. */
const sql: Sql = {
  first: <T>(statement: string, ...params: unknown[]) => call<T | null>({ op: "first", sql: statement, params }),
  all: <T>(statement: string, ...params: unknown[]) => call<T[]>({ op: "all", sql: statement, params }),
  run: (statement, ...params) => call<{ changes: number }>({ op: "run", sql: statement, params }),
  batch: async (statements) => {
    await call({ op: "batch", statements });
  },
};

export const harness: Harness = {
  kind: "celld",
  invite: INVITE,
  sql,

  request(method, path, { headers, body, vars }) {
    const all = { ...headers, ...(vars ? { "x-test-vars": JSON.stringify(vars) } : {}) };
    return fetch(`${celld.url}${path}`, { method, headers: all, body });
  },

  upgrade(path, token) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(`${celld.url.replace("http", "ws")}${path}`, { headers: token ? { authorization: `Bearer ${token}` } : {} });
      const buffered = bufferedSocket((text) => ws.send(text), (code) => ws.close(code));
      ws.on("message", (data) => buffered.deliver(data.toString()));
      ws.on("close", (code, reason) => buffered.closed(code, reason.toString()));
      ws.on("open", () => resolve({ status: 101, socket: buffered.socket }));
      ws.on("unexpected-response", (_request, response) => {
        const chunks: Buffer[] = [];
        response.on("data", (chunk: Buffer) => chunks.push(chunk));
        response.on("end", () => {
          resolve({ status: response.statusCode ?? 0, text: Buffer.concat(chunks).toString() });
          ws.terminate();
        });
      });
      ws.on("error", reject);
    });
  },

  async revisionCount(docName) {
    return (await test<{ n: number }>(`revisions?doc=${encodeURIComponent(docName)}`)).n;
  },
};
