# cloud-sync — sovereign package (workspace template, trimmed: no upstream library, macOS only).
#
# `swift build && swift test` at the root is the whole story for the client; these targets add the
# audit and the sync server in server/ (one Worker, run on Cloudflare or self-hosted under celld, locally or in Docker).

NCPU := $(shell sysctl -n hw.logicalcpu 2>/dev/null || nproc)

.PHONY: help build test audit server-install server-check server-test server-docker server-local server-dev

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | expand -t 22

build: ## Build the client
	swift build -j $(NCPU)

test: ## Run the client test suite
	swift test -j $(NCPU)

audit: ## App-neutrality + de-branding audit
	@Scripts/audit.sh

server-install: ## npm ci from the lockfile + the pinned celld (server/.celld-bin/celld)
	cd server && npm ci && scripts/install-celld.sh

server-test: ## contract tests against the Worker (Miniflare) and against celld, plus each one's own (never the network)
	cd server && npm test

server-check: ## tsc for the Worker and the Node-side test harness, + generated-types freshness
	cd server && npm run check

server-docker: ## build the self-hosting image (cloud-sync-server)
	docker build -t cloud-sync-server server

server-local: ## self-hosted: the Worker under celld on http://127.0.0.1:8787, state in server/.celld/dev (needs server/.dev.vars)
	cd server && CELLD_ESBUILD="$$PWD/node_modules/.bin/esbuild" .celld-bin/celld dev celld.jsonc --host 127.0.0.1 --port 8787 --no-watch

server-dev: ## local Worker + D1 + Durable Objects under wrangler on http://localhost:8787 (needs server/.dev.vars)
	cd server && npm run dev
