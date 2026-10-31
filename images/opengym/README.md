# opengym

Single-container build of [openGym](https://github.com/DuarteSantos8/openGym): 
Node API, nginx-served SPA and exercise media in **one** image, supervised by
s6-overlay. Made for Unraid, not tied to it: `templates/my-opengym.xml` deploys
it there.

## Run

Prebuilt on Docker Hub: `docker pull 0x1917/opengym:latest`.

```sh
docker run -d --name opengym --restart unless-stopped   \
  -p 8310:80                                            \
  -e ORIGIN=https://gym.example.com                     \
  -v /mnt/user/appdata/opengym:/data                    \
  0x1917/opengym:latest
```

Only port 80 is published: nginx fronts everything and proxies `/api` to the
loopback API, which keeps the app on a single origin (a passkey requirement).

## Build

Runs on any Docker host:

```sh
# VCS_REF/BUILD_DATE stamp the OCI provenance labels (BUILD_DATE is the source
# commit's date, deterministic per source state); BASE_DIGEST resolves on the
# build host. Skip them and the labels read dev/unknown.
VCS_REF=$(git rev-parse HEAD)
BUILD_DATE=$(git log -1 --format=%cI)
tar -C images/opengym -cf - . | ssh root@<docker-host> "
  rm -rf /tmp/opengym && mkdir -p /tmp/opengym && tar -C /tmp/opengym -xf - &&                            \
  BASE_DIGEST=\$(docker buildx imagetools inspect node:22.23.4-alpine --format '{{.Manifest.Digest}}') && \
  docker build -t opengym:latest                                                                          \
    --build-arg VCS_REF=$VCS_REF                                                                          \
    --build-arg BUILD_DATE=$BUILD_DATE                                                                    \
    --build-arg BASE_DIGEST=\$BASE_DIGEST                                                                 \
    /tmp/opengym"
```

## Environment

The deploy-time variables — the same fields the Unraid template exposes:

| Variable           | Default      | Meaning                                                                                                                                                    |
| ------------------ | ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ORIGIN`           | *(required)* | Exact address users type, scheme included. Mismatch refuses sign-in with `origin-mismatch`.                                                                |
| `RP_ID`            | *(empty)*    | Hostname part of `ORIGIN` (no scheme/port). Required for passkeys; changing it invalidates them. Passkeys need HTTPS. On plain HTTP use `PASSWORD_LOGIN`.  |
| `PASSWORD_LOGIN`   | `true`       | Adds name+password sign-in (upstream default: off). Registration stays a passkey ceremony.                                                                 |
| `FIRST_USER_ADMIN` | `true`       | First profile on an empty instance becomes admin (upstream default: off).                                                                                  |
| `ALLOW_GUEST`      | `true`       | `false` removes "Continue without account".                                                                                                                |
| `INVITE_ONLY`      | `false`      | `true` gates sign-ups behind an invite code. Create an admin profile first.                                                                                |
| `TRUST_PROXY`      | `true`       | Honor `X-Forwarded-For`/`X-Real-IP` — set when a reverse proxy fronts the container.                                                                       |
| `ADMIN_UIDS`       | *(empty)*    | Comma-separated account IDs (Settings → Account → Account ID) with admin dashboard access.                                                                 |
| `BASE_PATH`        | *(empty)*    | Subpath deployments (`/gym`, no trailing slash). Empty = site root.                                                                                        |
| `CF_CONNECTING_IP` | *(empty)*    | `$http_cf_connecting_ip` only when Cloudflare is really in front; empty drops the header.                                                                  |
| `TZ`               | `Etc/UTC`    | Container timezone (logs, audit log). Reminders fire in each user's own zone regardless.                                                                   |

Booleans: `1`/`true`/`yes`/`on` (case-insensitive) is on, anything else is off
except `ALLOW_GUEST` and `AUDIT_LOG`, which default `on` and take
`0`/`false`/`no`/`off` to disable.

## First boot

1. Map a host path to `/data` (chowned to uid 99 at boot).
2. Set `ORIGIN`, and `RP_ID` for passkeys, to the address people will use.
3. Open the WebUI and create a profile.
4. Healthy once nginx answers and `/api/health` comes back through the proxy.

## Design notes

- **One image, two supervised processes.** Upstream's compose runs `api` + `web`
  as two containers; merging them drops container-to-container DNS from the
  request path and gives one artifact to build and back up.
- **s6-overlay, sha256-verified at build**. pid-1 signal handling, privilege
  dropping, ordered one-shot init.
- **Crash policy.** A crashed service restarts after 1s; 5 deaths in 60s ends
  the CMD so Docker's restart policy owns the failure. Init failures stop the
  boot outright (`S6_BEHAVIOUR_IF_STAGE2_FAILS=2`).
- **Both services unprivileged.** API as uid 99 (group `users`, Unraid's
  appdata convention), nginx as the distro `nginx` account — only the API can
  read `/data`.
- **Source cloned at the pinned tag** (`OPENGYM_VERSION`). The API module COPY
  list mirrors upstream's Dockerfile by hand — diff it on every version bump.
