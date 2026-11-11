import type { AuthedDevice } from "./auth";
import type { Settings } from "./config";
import { errorResponse } from "./errors";

/**
 * The billing seam (030, D5). Returns null when the account may use sync, or a 402 Response.
 *
 * Today ENFORCE_ENTITLEMENT is "0" and this always returns null. With ENFORCE_ENTITLEMENT="1" an
 * account whose `entitled_until` is missing or in the past is refused. (A NULL value fails closed:
 * once enforcement is on, an account has to be granted an entitlement.) Called in exactly one
 * place, after the namespace check and before any document is touched: see `dispatch` in app.ts.
 */
export function checkEntitlement(settings: Settings, account: Pick<AuthedDevice, "entitledUntil">): Response | null {
  if (!settings.enforceEntitlement) return null;
  const until = account.entitledUntil ? Date.parse(account.entitledUntil) : NaN;
  if (Number.isFinite(until) && until > Date.now()) return null;
  return errorResponse(402, "payment_required", "Sync needs a subscription.");
}
