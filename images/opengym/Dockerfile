# opengym
#
# The whole OpenGym app (API + web) in ONE image, supervised by s6-overlay
# with a crash-loop finish policy.
#
# Upstream references (at the pinned OPENGYM_VERSION tag — keep the links in step
# with the ARG on every version bump):
#   https://github.com/DuarteSantos8/openGym/blob/v1.4.3/api/Dockerfile
#   https://github.com/DuarteSantos8/openGym/blob/v1.4.3/web/Dockerfile
#   https://github.com/DuarteSantos8/openGym/blob/v1.4.3/docker-compose.yml

# Version pin for the upstream checkout. Rebuilds are reproducible against this tag.
ARG OPENGYM_VERSION=v1.4.3
# The node version upstream's own Dockerfiles (header links) build and test against.
ARG NODE_IMAGE=node:22.23.4-alpine

# -- SRC --------------------------------------------------------------------
FROM alpine:3.22 AS src
ARG OPENGYM_VERSION
RUN apk add --no-cache git
# --depth 1 --branch <tag> checks the tag out detached; the assertion below makes a
# renamed/moved tag a build failure instead of a silently different app.
RUN git clone --depth 1 --branch "${OPENGYM_VERSION}" https://github.com/DuarteSantos8/openGym.git /src \
 && test -f /src/api/server.js                                                                          \
 && test -f /src/web/nginx.conf.template                                                                \
 && test -f /src/web/05-check-base-path.sh                                                              \
 && test -f /src/catalogue/media/NOTICE.md                                                              \
 && test -d /src/catalogue/media/still                                                                  \
 && test -d /src/catalogue/media/clip

# -- WEB-BUILD --------------------------------------------------------------
# The build stage of upstream's web/Dockerfile, run against the cloned tree
# (same --platform trade, same /app/frontend + api/coach/core layout, same
# --ignore-scripts install — the header link carries the reasons).
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS web-build
ARG OPENGYM_VERSION
ARG APP_BUILD=""
WORKDIR /app/frontend
COPY --from=src /src/frontend/package.json /src/frontend/package-lock.json* ./
RUN npm ci --ignore-scripts
COPY --from=src /src/api/coach/core/ /app/api/coach/core/
COPY --from=src /src/frontend/ ./
# APP_BUILD is shown in the app next to the package.json version. A build made from
# a pinned tag IS identified by that tag, so pass it through by default.
RUN APP_BUILD="${APP_BUILD:-$OPENGYM_VERSION}" npm run build \
 && test -f dist/index.html

# -- API-BUILD --------------------------------------------------------------
# The default target of upstream's api/Dockerfile, run against the cloned tree
# (header link): same `npm ci --omit=dev --omit=optional`, so no AI runtime and no
# AI dependency. No --platform pin on purpose: node_modules must match the TARGET
# platform (the runtime stage runs them natively; the deps here are pure JS but
# this stays true if upstream ever adds a native one).
FROM ${NODE_IMAGE} AS api-build
WORKDIR /app/api
COPY --from=src /src/api/package.json /src/api/package-lock.json* ./
RUN npm ci --omit=dev --omit=optional && npm cache clean --force
# The module list below mirrors upstream's COPY line. Upstream's
# api/test/dockerfile-copy.test.js guards ITS line, not this one: a root-level
# module added upstream shows here only at boot, as ERR_MODULE_NOT_FOUND. Diff the
# two lists at every version bump.
COPY --from=src /src/api/server.js /src/api/push-messages.js /src/api/nudge.js          \
     /src/api/nudge-copy.js /src/api/verify-error.js /src/api/password.js               \
     /src/api/rate-limit.js /src/api/passkeys-store.js /src/api/device-link.js          \
     /src/api/media.js /src/api/queue.js /src/api/sync-stamps.js /src/api/durable.js    \
     /src/api/admin-socket.js /src/api/recover.js ./
COPY --from=src /src/api/coach/ ./coach/

# -- IMAGE ------------------------------------------------------------------
FROM ${NODE_IMAGE}
ARG OPENGYM_VERSION
ARG NODE_IMAGE
# Set at build time to stamp the OCI labels below: --build-arg VCS_REF=$(git rev-parse HEAD)
# BUILD_DATE=$(git log -1 --format=%cI) (the source commit's date — deterministic per source
# state) BASE_DIGEST=$(docker buildx imagetools inspect <base> --format '{{.Manifest.Digest}}').
ARG VCS_REF=dev
ARG BUILD_DATE=unknown
ARG BASE_DIGEST=unknown
# s6-overlay v3.2.3.2. The sha256 constants below are the contents of the official
# release .sha256 assets (see README.md); every tarball is re-verified against them
# at build time, so a tampered or replaced download fails the build instead of
# becoming pid 1. x86_64 only: that is the only platform this repo builds for, and
# multi-arch would need one verified checksum per arch (ARGs let a future arch be
# added without editing the recipe's logic).
ARG S6_OVERLAY_VERSION=3.2.3.2
ARG S6_NOARCH_SHA256=5379750ed30a84bbd2e2dd74847ba6b5bd29cd0b2e3ea2ec58049b57eb2eda12
ARG S6_OVERLAY_SHA256=e6befcc96a437a3831386ecfc51808c5d3e939dc5fe3c02ae9284599e8aa2408
ARG S6_SYMLINKS_ARCH_SHA256=6251226709efc0c88800a8c140404d93b391e1b4051ef50fa0e8aac1fdcf738c
ARG S6_SYMLINKS_NOARCH_SHA256=a215675c375aca9efecde3065df22b19fb8dcdc1362566931c6b5e778099a0fb

LABEL org.opencontainers.image.authors="0x1917 (https://github.com/0x1917)"                                                             \
      org.opencontainers.image.title="opengym"                                                                                          \
      org.opencontainers.image.description="Self-hosted gym & body-weight tracker in a single container with s6-overlay supervision."   \
      org.opencontainers.image.source="https://github.com/0x1917/unraid-apps"                                                           \
      org.opencontainers.image.url="https://opengym.ch"                                                                                 \
      org.opencontainers.image.documentation="https://github.com/DuarteSantos8/openGym#readme"                                          \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"                                                                             \
      org.opencontainers.image.version="${OPENGYM_VERSION}"                                                                             \
      org.opencontainers.image.revision="${VCS_REF}"                                                                                    \
      org.opencontainers.image.created="${BUILD_DATE}"                                                                                  \
      org.opencontainers.image.base.name="docker.io/library/${NODE_IMAGE}"                                                              \
      org.opencontainers.image.base.digest="${BASE_DIGEST}"

# apk upgrade first, as upstream's Dockerfiles do; the header links carry the reason.
# nginx: serves the SPA and proxies /api (alpine package, master runs unprivileged).
# gettext: envsubst renders the nginx site config at boot from upstream's template.
# tzdata: the TZ knob must actually work — without zoneinfo, TZ is ignored by libc
# and the API's log timestamps and scheduled nudges drift to UTC.
RUN apk upgrade --no-cache                  \
 && apk add --no-cache nginx gettext tzdata \
 && rm -f /etc/nginx/http.d/default.conf

# s6-overlay: pid 1 and process supervisor. The overlay ships as a noarch tarball
# (the scripts, /init among them) plus one binaries tarball per architecture; both
# are needed. The two tiny symlinks tarballs additionally put the s6 binaries on
# /usr/bin so run/finish scripts (and anyone docker exec-ing in) can call
# s6-setuidgid / s6-svscanctl without knowing the /command layout.
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/s6-overlay-noarch.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz /tmp/s6-overlay-x86_64.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-symlinks-arch.tar.xz /tmp/s6-overlay-symlinks-arch.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-symlinks-noarch.tar.xz /tmp/s6-overlay-symlinks-noarch.tar.xz
RUN echo "${S6_NOARCH_SHA256}  /tmp/s6-overlay-noarch.tar.xz" | sha256sum -c -                   \
 && echo "${S6_OVERLAY_SHA256}  /tmp/s6-overlay-x86_64.tar.xz" | sha256sum -c -                  \
 && echo "${S6_SYMLINKS_ARCH_SHA256}  /tmp/s6-overlay-symlinks-arch.tar.xz" | sha256sum -c -     \
 && echo "${S6_SYMLINKS_NOARCH_SHA256}  /tmp/s6-overlay-symlinks-noarch.tar.xz" | sha256sum -c - \
 && tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz                                                 \
 && tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz                                                 \
 && tar -C / -Jxpf /tmp/s6-overlay-symlinks-arch.tar.xz                                          \
 && tar -C / -Jxpf /tmp/s6-overlay-symlinks-noarch.tar.xz                                        \
 && rm -f /tmp/s6-overlay-*.tar.xz

# Service accounts. Both processes run unprivileged; s6 itself is root as pid 1 and
# drops privileges per service via s6-setuidgid.
#
# opengym: uid 99, gid users(100) — Unraid's conventional nobody:users ownership for
# /mnt/user/appdata, so the /data bind mount is writable without chown games.
# nginx: the account the alpine nginx package creates; keeping it distinct from
# opengym means a compromised web tier cannot read /data (users, passkeys, session
# secret). Only the api account touches /data.
RUN addgroup -g 100 users 2>/dev/null || true             \
 && adduser -D -H -u 99 -G users -s /sbin/nologin opengym \
 && getent passwd nginx >/dev/null

# The api runtime (node_modules + the exact module set server.js imports).
COPY --from=api-build /app/api /app/api
# The built SPA. The exercise stills and animations ship with upstream in
# catalogue/media and are baked in here too (see README.md for why they are baked
# rather than seeded at first boot): nothing is downloaded at start-up.
COPY --from=web-build /app/frontend/dist /usr/share/nginx/html
COPY --from=src /src/catalogue/media/ /usr/share/nginx/html/exercise-media/
# Upstream's nginx site template and BASE_PATH guard, used unchanged at boot.
COPY --from=src /src/web/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=src /src/web/05-check-base-path.sh /usr/libexec/opengym/05-check-base-path.sh

# Our own files. RUN cannot read the build context — it executes in the image's
# filesystem — so the files are staged in with COPY first, then installed at
# their target paths (the recipe stays the single place that says where each
# one lands) and the staging dir is removed in the same layer. The s6-rc
# plumbing (one-word `type` files, the empty dependency/bundle markers) is
# generated here rather than carried as near-empty files. nginx.conf is ours
# from scratch: alpine's would run a root master with a `user` directive and a
# pid under /var/run; this one is written for an unprivileged master with all
# writable state under /run/nginx.
COPY runtime/ /tmp/opengym-runtime/
RUN install -D -m 644 /tmp/opengym-runtime/nginx.conf         /etc/nginx/nginx.conf                  \
 && install -D -m 755 /tmp/opengym-runtime/s6-api-run        /etc/s6-overlay/s6-rc.d/api/run         \
 && install -D -m 755 /tmp/opengym-runtime/s6-api-finish     /etc/s6-overlay/s6-rc.d/api/finish      \
 && install -D -m 755 /tmp/opengym-runtime/s6-nginx-run      /etc/s6-overlay/s6-rc.d/nginx/run       \
 && install -D -m 755 /tmp/opengym-runtime/s6-nginx-finish   /etc/s6-overlay/s6-rc.d/nginx/finish    \
 && install -D -m 755 /tmp/opengym-runtime/s6-init-config-up /etc/s6-overlay/s6-rc.d/init-config/up  \
 && install -D -m 755 /tmp/opengym-runtime/init-config.sh    /usr/libexec/opengym/init-config.sh     \
 && install -D -m 755 /tmp/opengym-runtime/finish-policy.sh  /usr/libexec/opengym/finish-policy.sh   \
 && rm -rf /tmp/opengym-runtime                                                                      \
 && chmod 755 /usr/libexec/opengym/05-check-base-path.sh                              \
 && printf 'longrun\n' > /etc/s6-overlay/s6-rc.d/api/type                             \
 && printf 'longrun\n' > /etc/s6-overlay/s6-rc.d/nginx/type                           \
 && printf 'oneshot\n' > /etc/s6-overlay/s6-rc.d/init-config/type                     \
 && install -d /etc/s6-overlay/s6-rc.d/api/dependencies.d                             \
              /etc/s6-overlay/s6-rc.d/nginx/dependencies.d                            \
              /etc/s6-overlay/user-bundles.d/user/contents.d                          \
 && touch /etc/s6-overlay/s6-rc.d/api/dependencies.d/init-config                      \
          /etc/s6-overlay/s6-rc.d/nginx/dependencies.d/init-config                    \
          /etc/s6-overlay/user-bundles.d/user/contents.d/api                          \
          /etc/s6-overlay/user-bundles.d/user/contents.d/nginx

# npm and npx are build-time tools only and are deleted for the reason upstream's
# api/Dockerfile default target gives (header link; same removal, same lines).
RUN rm -rf /usr/local/lib/node_modules/npm  \
           /usr/local/bin/npm               \
           /usr/local/bin/npx

# PORT: the api's listen port, read by both services (upstream's web template proxies
# to http://${BACKEND}:${PORT}, and the api listens on it). BACKEND is 127.0.0.1
# because the api lives in this same container — no DNS name to re-resolve.
# RESOLVER: kept configurable for parity with upstream's template (the /api blocks
# carry a `resolver` directive); on Docker the embedded DNS answers.
# PASSWORD_LOGIN and FIRST_USER_ADMIN are deliberately NOT defaulted here: both
# are template rows (default true), so the choice belongs to the deployer's
# config, not the image. A plain `docker run` without them gets upstream's off.
ENV NODE_ENV=production    \
    PORT=3000              \
    DATA_DIR=/data         \
    NGINX_PORT=80          \
    BACKEND=127.0.0.1      \
    RESOLVER=127.0.0.11    \
    CF_CONNECTING_IP=      \
    BASE_PATH=             \
    MEDIA_UPLOAD_MAX=48m   \
    TZ=Etc/UTC             \
    CONTENT_SECURITY_POLICY="default-src 'self'; script-src 'self' 'sha256-xUZtZS1nWJaAyUqA7ZKgkLhjdEisnY0MiRmax16aGFg='; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https:; media-src 'self' blob: https:; font-src 'self' data:; connect-src 'self' https: http:; worker-src 'self'; manifest-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"

# S6_BEHAVIOUR_IF_STAGE2_FAILS=2: a failed one-shot init (bad BASE_PATH, unwritable
# /data, nginx refusing the rendered config) must stop the container instead of
# limping on with a service that can never work.
# S6_KEEP_ENV=1: s6-overlay resets the environment for everything it starts;
# with-contenv would fix that per script, but every service here IS configured by
# container env (node: RP_ID/ORIGIN/PORT/DATA_DIR/...; init: envsubst; the CMD
# too), so the whole supervision tree should see it. with-contenv becomes a nop.
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_KEEP_ENV=1

WORKDIR /app/api
EXPOSE 80

# Probes through nginx into the api: healthy only if the SPA server answers AND the
# /api proxy chain reaches node. ${NGINX_PORT} is expanded by the shell at probe
# time, so it tracks the configured port.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD wget --spider -q "http://127.0.0.1:${NGINX_PORT}/api/health" || exit 1

# s6-overlay as pid 1, with s6-pause as the CMD: the container's work is entirely
# its supervised services, and s6-overlay keeps the container alive exactly as long
# as this CMD runs — so the CMD is also the lever the crash-loop escalation pulls
# (see finish-policy.sh), and ending it is what lets /init run its shutdown stage.
# It is s6-pause rather than an empty CMD on purpose: killing it makes the container
# exit NON-ZERO (143), so a crash loop looks like a failure to Docker's restart
# policy (on-failure included), while `docker stop` still exits 0 through the normal
# signal path. The base image's own CMD (node) is replaced either way.
ENTRYPOINT ["/init"]
CMD ["s6-pause"]
