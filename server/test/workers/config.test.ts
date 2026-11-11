import { describe, expect, it } from "vitest";
import { parseConfig } from "../../src/core/config";
import { HttpError } from "../../src/core/errors";

// The configuration check in core. Here rather than in test/contract because neither harness can unset a secret.

const good = { tokenPepper: "p", inviteSecret: "i", historyLimit: "1000", enforceEntitlement: "0", minClient: "{}" };

describe("parseConfig", () => {
  it("accepts a complete configuration", () => {
    expect(parseConfig(good).tokenPepper).toBe("p");
  });

  it.each(["tokenPepper", "inviteSecret"] as const)("fails closed with a 500 when %s is unset or empty", (key) => {
    for (const value of [undefined, ""]) {
      const attempt = () => parseConfig({ ...good, [key]: value as unknown as string });
      expect(attempt).toThrow(HttpError);
      try {
        attempt();
      } catch (error) {
        expect((error as HttpError).status).toBe(500);
        expect((error as HttpError).code).toBe("misconfigured");
      }
    }
  });
});
