import { HttpError } from "./errors";
import { isSlug } from "./namespace";
import type { Config, Platform } from "./ports";

export const DEFAULT_HISTORY_LIMIT = 1000;
export const NO_MINIMUM = "0.0.0";

export interface Settings {
  tokenPepper: string;
  inviteSecret: string;
  historyLimit: number;
  enforceEntitlement: boolean;
  /** Namespace -> minimum client version. A namespace with no entry has no minimum. */
  minimums: Record<string, string>;
}

/** What a handler needs besides the request. */
export interface Services {
  platform: Platform;
  settings: Settings;
}

const misconfigured = (message: string) => new HttpError(500, "misconfigured", message);

/**
 * Parses the host's configuration. A missing secret or a bad value throws a 500 rather than being guessed at, so a
 * typo in MIN_CLIENT can't quietly turn the minimum off: the Worker fails the request.
 */
export function parseConfig(config: Config): Settings {
  // Unset secrets fail every request: a Worker deployed before `wrangler secret put` must not mint a token.
  if (!config.tokenPepper) throw misconfigured("TOKEN_PEPPER is not set.");
  if (!config.inviteSecret) throw misconfigured("INVITE_SECRET is not set.");
  let parsed: unknown;
  try {
    parsed = JSON.parse(config.minClient || "{}");
  } catch {
    throw misconfigured('MIN_CLIENT must be a JSON object such as {"<namespace>":"1.2.0"}.');
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw misconfigured('MIN_CLIENT must be a JSON object such as {"<namespace>":"1.2.0"}.');
  }
  const minimums: Record<string, string> = Object.create(null); // no inherited keys: "constructor" is a valid slug
  for (const [namespace, version] of Object.entries(parsed)) {
    if (!isSlug(namespace)) throw misconfigured(`MIN_CLIENT names '${namespace}', which is not a valid namespace.`);
    if (typeof version !== "string" || !/^\d+(\.\d+){0,3}$/.test(version)) {
      throw misconfigured(`MIN_CLIENT's version for '${namespace}' must be a dotted number such as "1.2.0".`);
    }
    minimums[namespace] = version;
  }

  const limit = parseInt(config.historyLimit, 10);
  return {
    tokenPepper: config.tokenPepper,
    inviteSecret: config.inviteSecret,
    historyLimit: Number.isFinite(limit) && limit > 0 ? limit : DEFAULT_HISTORY_LIMIT,
    enforceEntitlement: config.enforceEntitlement === "1",
    minimums,
  };
}
