import worker, { AccountDoc } from "../cloudflare/index";
import { migrate } from "./migrate";

// The self-host entry: the Cloudflare Worker, run under celld (see celld.jsonc). It differs in one thing: celld has no
// migration step, so the first request in each isolate applies any pending D1 migrations before the Worker sees it.
export { AccountDoc };

let ready: Promise<unknown> | undefined;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // Remembered once it succeeds; forgotten on failure, so the next request tries again.
    ready ??= migrate(env.DB).catch((error) => {
      ready = undefined;
      throw error;
    });
    await ready;
    return worker.fetch(request, env);
  },
} satisfies ExportedHandler<Env>;
