import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Two projects. The contract tests (test/contract) run in both: against the Worker in Miniflare, and against the same
// Worker run by a real `celld dev` over HTTP; the `@harness` alias is what picks the host. Tests that can only mean one
// host live in test/workers or test/celld.
export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  const harness = (name: string) => path.join(import.meta.dirname, "test/harness", `${name}.ts`);
  return {
    test: {
      projects: [
        {
          plugins: [
            cloudflareTest({
              wrangler: { configPath: "./wrangler.jsonc" },
              miniflare: {
                // Test-only values: nothing here is a real secret, and no test reaches the network.
                bindings: { TOKEN_PEPPER: "test-pepper", INVITE_SECRET: "test-invite", TEST_MIGRATIONS: migrations },
              },
            }),
          ],
          resolve: { alias: { "@harness": harness("workers") } },
          test: {
            name: "workers",
            include: ["test/contract/**/*.test.ts", "test/workers/**/*.test.ts"],
            setupFiles: ["./test/workers/apply-migrations.ts"],
          },
        },
        {
          resolve: { alias: { "@harness": harness("celld") } },
          test: {
            name: "celld",
            environment: "node",
            include: ["test/contract/**/*.test.ts", "test/celld/**/*.test.ts"],
            // Each file starts a celld (about half a second) and builds the Worker into it.
            testTimeout: 30_000,
            hookTimeout: 60_000,
          },
        },
      ],
    },
  };
});
