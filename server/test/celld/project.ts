import { type ChildProcess, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

// A throwaway celld project for the tests: symlinks into server/ for the code, a config whose `main` is the test entry,
// test-only secrets, and a `celld dev` process on a free loopback port. Its state (.celld/dev) lives in the project dir.

const SERVER = join(import.meta.dirname, "../..");
const BIN = process.env.CELLD_BIN ?? join(SERVER, ".celld-bin/celld");
const ESBUILD = join(SERVER, "node_modules/.bin/esbuild");

export const INVITE = "test-invite";

export interface RunningCelld {
  readonly dir: string;
  readonly url: string;
  /** Stops the process (this one only) and waits for it to exit. The project dir and its state stay. */
  stop(): Promise<void>;
}

/** A new project dir. Pass it to `startCelld` to run it, to `startCelld` again to restart it on the same state, then `removeProject`. */
export function makeProject(): string {
  const dir = mkdtempSync(join(tmpdir(), "cloud-sync-celld-"));
  for (const name of ["src", "migrations", "test"]) symlinkSync(join(SERVER, name), join(dir, name));
  const config = readFileSync(join(SERVER, "celld.jsonc"), "utf8");
  const swapped = config.replace('"main": "src/celld/index.ts"', '"main": "test/celld/entry.ts"');
  if (swapped === config) throw new Error("celld.jsonc no longer has the main entry the test project rewrites");
  writeFileSync(join(dir, "celld.jsonc"), swapped);
  writeFileSync(join(dir, ".dev.vars"), `TOKEN_PEPPER=test-pepper\nINVITE_SECRET=${INVITE}\n`);
  return dir;
}

export function removeProject(dir: string): void {
  rmSync(dir, { recursive: true, force: true });
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address() as { port: number };
      probe.close(() => resolve(port));
    });
  });
}

export async function startCelld(dir: string): Promise<RunningCelld> {
  if (!existsSync(BIN)) throw new Error(`celld is not installed at ${BIN}. Run \`make server-install\` (it runs scripts/install-celld.sh).`);
  const port = await freePort();
  const url = `http://127.0.0.1:${port}`;
  let log = "";
  const child: ChildProcess = spawn(BIN, ["dev", join(dir, "celld.jsonc"), "--host", "127.0.0.1", "--port", String(port), "--no-watch"], {
    env: { ...process.env, CELLD_ESBUILD: ESBUILD },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
  let died = false;
  void exited.then(() => (died = true));
  child.stdout?.on("data", (chunk) => (log += chunk));
  child.stderr?.on("data", (chunk) => (log += chunk));

  const stop = async () => {
    if (!died) child.kill("SIGTERM");
    await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 5000))]);
    if (!died) child.kill("SIGKILL");
    await exited;
  };

  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (died) throw new Error(`celld exited before it was ready:\n${log}`);
    try {
      if ((await fetch(`${url}/v1/meta`)).ok) return { dir, url, stop };
    } catch {
      // not listening yet
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  await stop();
  throw new Error(`celld was not ready within 30 s:\n${log}`);
}
