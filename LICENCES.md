# Licences

`cloud-sync` itself is MIT — see [`LICENSE`](LICENSE).

The Swift package has no third-party dependencies and vendors nothing. The server's dependencies are
development tools only (`wrangler`, `vitest`, `typescript`, `@cloudflare/*`); none is bundled into the
Worker, which uses only the Workers runtime.
