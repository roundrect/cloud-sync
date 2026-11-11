# The self-hosted sync server as one container: the Cloudflare Worker, run by celld (https://github.com/denoland/celld)
# in `celld dev` mode. Be clear about what that is: ONE node, with D1 and the Durable Objects kept in celld's local
# SQLite store under /app/.celld (the volume). It is a good home for a handful of Macs on a box you look after. It is
# not a fleet: a fleet of celld nodes needs a qualified bucket (R2, S3, Tigris) and `celld deploy` (README.md,
# "Self-host with celld"); we have not tested that path.
#
#   docker build -t cloud-sync-server server/
#   docker run -d --name sync --restart unless-stopped -p 127.0.0.1:8787:8787 -v sync-data:/app/.celld \
#     -e TOKEN_PEPPER=... -e INVITE_SECRET=... cloud-sync-server
#
# TOKEN_PEPPER and INVITE_SECRET are required (the entrypoint refuses to start without them); HISTORY_LIMIT,
# ENFORCE_ENTITLEMENT and MIN_CLIENT are optional. HTTPS is not this image's job: put a proxy in front (README.md).

# esbuild is what celld compiles the Worker with; the native binary comes out of the npm install.
FROM node:22-bookworm-slim AS esbuild
WORKDIR /build
COPY package.json package-lock.json ./
RUN npm ci
RUN cp node_modules/@esbuild/*/bin/esbuild /esbuild && /esbuild --version

# The pinned celld for this architecture, checksum-verified by the same script `make server-install` runs.
FROM debian:bookworm-slim AS celld
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY scripts/install-celld.sh /install-celld.sh
RUN case "$TARGETARCH" in \
      amd64) export CELLD_TARGET=x86_64-unknown-linux-gnu ;; \
      arm64) export CELLD_TARGET=aarch64-unknown-linux-gnu ;; \
      *) echo "no pinned celld for $TARGETARCH" >&2; exit 1 ;; \
    esac \
 && CELLD_DEST=/out /install-celld.sh

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/* \
 && useradd --system --create-home --shell /usr/sbin/nologin cloudsync
COPY --from=celld /out/celld /usr/local/bin/celld
COPY --from=esbuild /esbuild /usr/local/bin/esbuild
ENV CELLD_ESBUILD=/usr/local/bin/esbuild
WORKDIR /app
COPY src ./src
COPY migrations ./migrations
COPY celld.jsonc ./celld.jsonc
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
# /app is writable by `cloudsync` (the entrypoint writes .dev.vars; celld keeps its store in .celld). Created before VOLUME
# so a fresh volume takes this ownership.
RUN mkdir -p /app/.celld && chown cloudsync:cloudsync /app /app/.celld
USER cloudsync
VOLUME /app/.celld
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD curl -fs http://127.0.0.1:8787/v1/meta >/dev/null || exit 1
ENTRYPOINT ["docker-entrypoint.sh"]
