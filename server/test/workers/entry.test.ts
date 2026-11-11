import { describe, expect, it } from "vitest";
import * as entry from "../../src/cloudflare/index";

describe("the Worker entry", () => {
  it("exports only the handler and the Durable Object class (workerd refuses anything else at startup)", () => {
    expect(Object.keys(entry).sort()).toEqual(["AccountDoc", "default"]);
  });
});
