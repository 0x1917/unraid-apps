# opengym
#
# The whole OpenGym app (API + web) in ONE image, supervised by s6-overlay
# with a crash-loop finish policy.
#
# The application is NOT built here. It comes from upstream's published
# images, pinned by tag.
#
# What this file adds on top of upstream: s6-overlay supervision (upstream
# ships two containers with one process each), uid-99 ownership for Unraid
# appdata, an unprivileged nginx master that cannot reach /data, and the
# boot-time config rendering those need. Runtime files: runtime/.

# The upstream release this image is built from. Upstream publishes semver
# image tags without a `v` (1.4.3, 1.4, latest, edge); the git release of the
# same version is v1.4.3, which is what the links above use. Our own image tag
# is the same bare release; only the git tag carries the `v`.
ARG UPSTREAM_VERSION=1.4.4

# The two images this build starts from. Both refs derive from UPSTREAM_VERSION:
# moving the release is one edit and the pair cannot drift apart. `--build-arg`
# can still override either ref for a one-off build of a specific digest.
ARG OPENGYM_API_IMAGE=ghcr.io/duartesantos8/opengym-api:${UPSTREAM_VERSION}
ARG OPENGYM_WEB_IMAGE=ghcr.io/duartesantos8/opengym-web:${UPSTREAM_VERSION}

# -- WEB --------------------------------------------------------------------
# Two things come out of upstream's web image: the built SPA (the exercise
# media it bakes in land under exercise-media/ and come along with it) and the
# CSP it carries as ENV. An ENV value cannot be read from a file at runtime, so
# the policy is materialised here and installed below; init-config.sh falls
# back to it when CONTENT_SECURITY_POLICY is not set, which keeps the
# inline-script hash in step with the frontend on every release move instead of
# by hand.
FROM ${OPENGYM_WEB_IMAGE} AS web
RUN printf '%s\n' "$CONTENT_SECURITY_POLICY" > /tmp/opengym-csp

# -- IMAGE ------------------------------------------------------------------
# Upstream's API image: node runtime plus the app at /app (server.js, the root
# modules, coach/ and node_modules from `npm ci --omit=dev --omit=optional`; the
# image's own WORKDIR is /app, which the end of this file repeats). It is the
# `default` target of upstream's api/Dockerfile, so npm and the AI runtime are
# already absent; the deletion further down is a guard, not the source of that.
FROM ${OPENGYM_API_IMAGE}
ARG UPSTREAM_VERSION
# Our own version label: the upstream release, bare, matching upstream's image
# tags and the container-tag convention (semver without a `v`). The git tag is
# the one place a `v` appears (opengym-v<release>).
ARG OPENGYM_VERSION=${UPSTREAM_VERSION}
ARG OPENGYM_API_IMAGE
ARG OPENGYM_WEB_IMAGE
# Set at build time to stamp the OCI labels below: --build-arg VCS_REF=$(git rev-parse HEAD)
# BUILD_DATE=$(git log -1 --format=%cI) (this repo's commit date — deterministic per source
# state). BASE_DIGEST is the manifest digest of the api image ref, resolved by the workflow
# (or the README recipe) with `docker buildx imagetools inspect`; left unset it reads unknown.
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

LABEL org.opencontainers.image.authors="0x1917 (https://github.com/0x1917)"                                                  \
      org.opencontainers.image.title="opengym"                                                                               \
      org.opencontainers.image.description="Open-source workout & body-weight tracker."                                      \
      org.opencontainers.image.source="https://github.com/0x1917/unraid-apps"                                                \
      org.opencontainers.image.url="https://opengym.ch"                                                                      \
      org.opencontainers.image.documentation="https://github.com/0x1917/unraid-apps/blob/master/images/opengym/README.md"    \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"                                                                  \
      org.opencontainers.image.version="${OPENGYM_VERSION}"                                                                  \
      org.opencontainers.image.revision="${VCS_REF}"                                                                         \
      org.opencontainers.image.created="${BUILD_DATE}"                                                                       \
      org.opencontainers.image.base.name="ghcr.io/duartesantos8/opengym-api"                                                 \
      org.opencontainers.image.base.digest="${BASE_DIGEST}"                                                                  \
      io.opengym.upstream.version="${UPSTREAM_VERSION}"                                                                      \
      io.opengym.upstream.api="${OPENGYM_API_IMAGE}"                                                                         \
      io.opengym.upstream.web="${OPENGYM_WEB_IMAGE}"

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
RUN addgroup -g 100 users 2>/dev/null || true              \
 && adduser -D -H -u 99 -G users -s /sbin/nologin opengym  \
 && getent passwd nginx >/dev/null

# The built SPA and the exercise media, both already at their final paths inside
# upstream's web image (media under exercise-media/): nothing is downloaded at
# start-up. The site template and the BASE_PATH guard are upstream's, unchanged.
COPY --from=web /usr/share/nginx/html/ /usr/share/nginx/html/
COPY --from=web /etc/nginx/templates/default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=web /docker-entrypoint.d/05-check-base-path.sh /usr/libexec/opengym/05-check-base-path.sh
COPY --from=web /tmp/opengym-csp /etc/opengym/content-security-policy

# Licence texts travel WITH the image: it redistributes upstream's AGPL build and
# the Gym visual exercise media, which upstream licenses separately from the AGPL
# ("provided strictly for use within the openGym application"). Both files are
# vendored into this build context: LICENSE is byte-identical to the repo root,
# NOTICE.md is upstream's third-party notice at the pinned release — because the
# build context is images/opengym/, not the repo root.
COPY LICENSE NOTICE.md /usr/share/opengym/

# Our own files. RUN cannot read the build context; it executes in the image's
# filesystem. So the files are staged in with COPY first, then installed at
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
 && chmod 755 /usr/libexec/opengym/05-check-base-path.sh                                             \
 && printf 'longrun\n' > /etc/s6-overlay/s6-rc.d/api/type                                            \
 && printf 'longrun\n' > /etc/s6-overlay/s6-rc.d/nginx/type                                          \
 && printf 'oneshot\n' > /etc/s6-overlay/s6-rc.d/init-config/type                                    \
 && install -d /etc/s6-overlay/s6-rc.d/api/dependencies.d                                            \
              /etc/s6-overlay/s6-rc.d/nginx/dependencies.d                                           \
              /etc/s6-overlay/user-bundles.d/user/contents.d                                         \
 && touch /etc/s6-overlay/s6-rc.d/api/dependencies.d/init-config                                     \
          /etc/s6-overlay/s6-rc.d/nginx/dependencies.d/init-config                                   \
          /etc/s6-overlay/user-bundles.d/user/contents.d/api                                         \
          /etc/s6-overlay/user-bundles.d/user/contents.d/nginx

# npm and npx are build-time tools only. Upstream's published image is its
# `default` target and already lacks them; repeating the removal here means a
# pin to an image built from a different upstream target cannot silently ship
# npm plus the AI runtime dependency tree. The smoke test asserts the invariant.
RUN rm -rf /usr/local/lib/node_modules/npm  \
           /usr/local/bin/npm               \
           /usr/local/bin/npx

# PORT: the api's listen port, read by both services (upstream's web template proxies
# to http://${BACKEND}:${PORT}, and the api listens on it). BACKEND is 127.0.0.1
# because the api lives in this same container, so no DNS name needs re-resolving.
# RESOLVER: kept configurable for parity with upstream's template (the /api blocks
# carry a `resolver` directive); on Docker the embedded DNS answers.
# PASSWORD_LOGIN and FIRST_USER_ADMIN are deliberately NOT defaulted here: both
# are template rows (default true), so the choice belongs to the deployer's
# config, not the image. A plain `docker run` without them gets upstream's off.
# CONTENT_SECURITY_POLICY is not set here: the web tier's policy is baked from
# upstream's web image at /etc/opengym/content-security-policy, and
# init-config.sh exports it unless the deployer overrides it.
ENV NODE_ENV=production    \
    PORT=3000              \
    DATA_DIR=/data         \
    NGINX_PORT=80          \
    BACKEND=127.0.0.1      \
    RESOLVER=127.0.0.11    \
    CF_CONNECTING_IP=      \
    BASE_PATH=             \
    MEDIA_UPLOAD_MAX=48m   \
    TZ=Etc/UTC

# S6_BEHAVIOUR_IF_STAGE2_FAILS=2: a failed one-shot init (bad BASE_PATH, unwritable
# /data, nginx refusing the rendered config) must stop the container instead of
# limping on with a service that can never work.
# S6_KEEP_ENV=1: s6-overlay resets the environment for everything it starts;
# with-contenv would fix that per script, but every service here IS configured by
# container env (node: RP_ID/ORIGIN/PORT/DATA_DIR/...; init: envsubst; the CMD
# too), so the whole supervision tree should see it. with-contenv becomes a nop.
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_KEEP_ENV=1

WORKDIR /app
EXPOSE 80

# Probes through nginx into the api: healthy only if the SPA server answers AND the
# /api proxy chain reaches node. ${NGINX_PORT} is expanded by the shell at probe
# time, so it tracks the configured port.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD wget --spider -q "http://127.0.0.1:${NGINX_PORT}/api/health" || exit 1

# s6-overlay as pid 1, with s6-pause as the CMD: the container's work is entirely
# its supervised services, and s6-overlay keeps the container alive exactly as long
# as this CMD runs, so the CMD is also the lever the crash-loop escalation pulls
# (see finish-policy.sh), and ending it is what lets /init run its shutdown stage.
# It is s6-pause rather than an empty CMD on purpose: killing it makes the container
# exit NON-ZERO (143), so a crash loop looks like a failure to Docker's restart
# policy (on-failure included), while `docker stop` still exits 0 through the normal
# signal path. Upstream's own CMD (node server.js) is replaced either way.
ENTRYPOINT ["/init"]
CMD ["s6-pause"]
