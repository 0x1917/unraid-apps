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

## How the image is built

The application is **not** compiled here. The Dockerfile starts from upstream's
published images — `ghcr.io/duartesantos8/opengym-api` and `opengym-web`, both at
the release named by `ARG UPSTREAM_VERSION` — and adds only the supervision
layer: s6-overlay, uid-99 ownership, an unprivileged nginx master, and the
boot-time config rendering those need.

Consequences worth knowing:

- No `git clone` and no `npm ci`. A build is layer copies, one `apk add`
  (nginx, gettext, tzdata) and the sha256-verified s6-overlay tarballs.
- The upstream **web** image supplies the built SPA, nginx site template, the
  `BASE_PATH` guard, the exercise media and the CSP string.
- ~431 MB. The exercise media alone is ~215 MB; the API runtime is ~11 MB.
- Seconds on a host that already has the upstream layers; a couple of minutes
  cold (~290 MB compressed to pull).

### Build

Runs on any Docker host:

```sh
# VCS_REF/BUILD_DATE stamp the OCI provenance labels (BUILD_DATE is this repo's
# commit date, deterministic per source state). BASE_DIGEST is resolved on the
# build host from the release pinned in the Dockerfile, and only feeds the base
# digest label. Skip them and the labels read dev/unknown.
VCS_REF=$(git rev-parse HEAD)
BUILD_DATE=$(git log -1 --format=%cI)
tar -C images/opengym -cf - . | ssh root@<docker-host> "
  rm -rf /tmp/opengym && mkdir -p /tmp/opengym && tar -C /tmp/opengym -xf - &&       \
  UP=\$(grep -m1 '^ARG UPSTREAM_VERSION=' /tmp/opengym/Dockerfile | cut -d= -f2) &&  \
  BASE_DIGEST=\$(docker buildx imagetools inspect                                    \
      ghcr.io/duartesantos8/opengym-api:\$UP --format '{{.Manifest.Digest}}') &&     \
  docker build -t opengym:latest                                                     \
    --build-arg VCS_REF=$VCS_REF                                                     \
    --build-arg BUILD_DATE=$BUILD_DATE                                               \
    --build-arg BASE_DIGEST=\$BASE_DIGEST                                            \
    /tmp/opengym"
```

Building on the same machine: `cd images/opengym && docker build -t opengym:test .`

### Trying another upstream release without editing the file

```sh
docker build -t opengym:try                                              \
  --build-arg OPENGYM_API_IMAGE=ghcr.io/duartesantos8/opengym-api:<ver>  \
  --build-arg OPENGYM_WEB_IMAGE=ghcr.io/duartesantos8/opengym-web:<ver>  \
  images/opengym
```

`<ver>` is the upstream release tag, no leading `v`, matching upstream's own
image tags. Override **both** refs together: nothing in the Dockerfile
cross-checks that the API and web tags are the same release. For a real update,
edit the ARG instead — see Version management.

## Test

`images/opengym/scripts/smoke-test.sh <image>` is the gate CI runs, and it runs
anywhere Docker does. It boots the image on a free loopback port with a throwaway
data dir, and fails on the first broken expectation. ~40s; needs `docker`,
`curl`, `jq`, `openssl`.

```sh
bash images/opengym/scripts/smoke-test.sh opengym:test
```

What it proves:

| Check                                              | Why it is there                                                      |
| -------------------------------------------------- | -------------------------------------------------------------------- |
| boots, `/api/health` ok through nginx              | both supervised services came up and the proxy chain works           |
| SPA responds with a CSP header                     | the web tier is serving, with the policy taken from upstream         |
| exercise media served                              | the media copy from the web image landed at the served path          |
| npm absent from the image                          | the runtime-free upstream target actually shipped, no npm tree       |
| API not running as root                            | the uid-99 privilege drop in `s6-api-run`                            |
| licence texts ship (AGPL + notice)                 | a dropped `COPY` builds and boots fine, so nothing else would notice |
| `PASSWORD_LOGIN` reaches the config endpoint       | the image's env surface and template rows agree                      |
| password signup + session cookie                   | the API can create a user and issue a session through the proxy      |
| first user is administrator                        | `FIRST_USER_ADMIN` behaves as the template claims                    |
| state written through the proxy                    | a real write path, not just a read                                   |
| `/data` owned `99:100`                             | the Unraid appdata ownership contract                                |
| `docker stop` exits 0                              | no orphaned nginx, no swallowed signal                               |
| replacement keeps session + data, `BASE_PATH=/gym` | an image upgrade does not lose data, and the subpath mode serves     |
| invalid `BASE_PATH` refused at boot                | misconfiguration fails loudly instead of 404-ing                     |

Deliberate gaps: passkey ceremonies (needs a real browser), Coach provider
jobs, TLS/reverse-proxy behaviour, and anything that needs real user data.

## CI

`.github/workflows/opengym.yml`.

| Event                                                         | What runs                             |
| ------------------------------------------------------------- | ------------------------------------- |
| push to `master` touching `images/opengym/**` or the workflow | build, smoke, publish                 |
| pull request touching the same paths                          | build and smoke only, never publishes |
| manual dispatch                                               | same as a push                        |

Pipeline order: resolve the version from the Dockerfile → build once with
`load: true` → `smoke-test.sh` → retag and push → verify both tags carry the
same digest → tag the source commit.

Properties that matter:

- **The published image is the tested image.** CI builds once, tests that image,
  then `docker tag` + `docker push` it. There is no second build, so published
  layers cannot differ from verified ones.
- **Two tags per release:** `0x1917/opengym:<ver>` and `:latest`.
- `timeout-minutes: 25` — a hung build fails the job instead of burning the 6h
  default.
- `concurrency: opengym-<ref>` with `cancel-in-progress: false` — two quick
  pushes cannot race `:latest` or the source tag.
- Dependabot (`.github/dependabot.yml`) opens weekly PRs for major-version updates
  of the four actions the workflow uses. Patch/minor arrive through the major
  tags already.

### Upstream releases

`.github/workflows/upstream-check.yml` runs daily (and on demand) against two
upstreams: openGym's published images (`ARG UPSTREAM_VERSION`) and s6-overlay
(`ARG S6_OVERLAY_VERSION` plus the four tarball checksums, re-read from the
release's own `.sha256` assets). The logic lives in
`images/opengym/scripts/upstream-check.sh` (`check` / `apply`), which also runs
by hand — it needs only `curl` and `jq`. When something newer exists, it updates
the ARGs, re-vendors `NOTICE.md`, **builds and runs the smoke gate**, and only
then opens a PR. Nothing publishes until that PR is merged.

Two things worth knowing:

- A PR opened with the built-in `GITHUB_TOKEN` does not trigger other workflow
  runs, so the `opengym` CI will not appear on it. The build and smoke evidence
  is in the check run's log and in the PR body.
- The branch name carries the date and both versions, so a re-run on the same
  day is a no-op while the PR is open. Close it unmerged and the next run
  proposes it again.

## Version management

`ARG UPSTREAM_VERSION` in the Dockerfile is the single source of truth. Both
image refs derive from it, so an update is one edit that cannot leave the pair
mismatched.

`<ver>` below stands for an upstream release tag such as `X.Y.Z` — a
placeholder for the form, not a default: the published version is whatever
`ARG UPSTREAM_VERSION` says.

| Thing                                 | Form                                      | Example                 |
| ------------------------------------- | ----------------------------------------- | ----------------------- |
| upstream image tag                | bare semver (upstream's own convention)     | `opengym-api:<ver>`     |
| this repo's Hub tag               | bare semver, same as upstream               | `0x1917/opengym:<ver>`  |
| OCI `image.version` label         | bare semver                                 | `<ver>`                 |
| git tag (CI)                      | `opengym-` + `v` + version; rebuilds get `-<n>` | `opengym-v<ver>`    |

### Update checklist

The daily release check does steps 1 to 4 for you and opens a PR; merging that
PR is step 5. By hand:

1. Read upstream's release notes; confirm both image tags exist:
   `docker buildx imagetools inspect ghcr.io/duartesantos8/opengym-web:<ver>`.
2. Edit `ARG UPSTREAM_VERSION`.
3. Re-vendor `NOTICE.md` from the new tag
   (`git -C <upstream clone> show v<ver>:NOTICE.md > images/opengym/NOTICE.md`);
   re-copy `LICENSE` if upstream changed it.
4. Build and run `smoke-test.sh` locally.
5. Commit and push to `master` → CI publishes `<ver>` + `latest`.
6. Recreate the container on Unraid (Docker tab → Edit → Apply, or
   `docker pull && docker stop/rm/run`).

### Caveats

- **A rebuild reuses the release tag on Docker Hub** (`<ver>` is overwritten;
  Hub tags are mutable), but the git side no longer lies: the first publish of a
  release gets `opengym-v<ver>` and every rebuild gets `opengym-v<ver>-<n>`
  (numbered from the remote's tags), so each published image has its own commit
  tag. The image labels (`image.created`, `image.revision`) still tell two
  builds of one release apart inside the registry.
- **Rollback** is a previous release tag (`0x1917/opengym:<ver>`) or a local
  image; old tags are not deleted.
- **The media is not AGPL.** Upstream's notice permits a non-commercial openGym
  fork to carry the unmodified 180 px exercise media *with the notice*, which is
  why `NOTICE.md` ships inside the image and is re-vendored on every release update.

## Environment

The deploy-time variables — the same fields the Unraid template exposes:

| Variable           | Default      | Meaning                                                                                                                                                   |
| ------------------ | ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ORIGIN`           | *(required)* | Exact address users type, scheme included. Mismatch refuses sign-in with `origin-mismatch`.                                                               |
| `RP_ID`            | *(empty)*    | Hostname part of `ORIGIN` (no scheme/port). Required for passkeys; changing it invalidates them. Passkeys need HTTPS. On plain HTTP use `PASSWORD_LOGIN`. |
| `PASSWORD_LOGIN`   | `true`       | Adds name+password sign-in (upstream default: off). Registration stays a passkey ceremony.                                                                |
| `FIRST_USER_ADMIN` | `true`       | First profile on an empty instance becomes admin (upstream default: off).                                                                                 |
| `ALLOW_GUEST`      | `true`       | `false` removes "Continue without account".                                                                                                               |
| `INVITE_ONLY`      | `false`      | `true` gates sign-ups behind an invite code. Create an admin profile first.                                                                               |
| `TRUST_PROXY`      | `true`       | Honor `X-Forwarded-For`/`X-Real-IP` — set when a reverse proxy fronts the container.                                                                      |
| `ADMIN_UIDS`       | *(empty)*    | Comma-separated account IDs (Settings → Account → Account ID) with admin dashboard access.                                                                |
| `BASE_PATH`        | *(empty)*    | Subpath deployments (`/gym`, no trailing slash). Empty = site root.                                                                                       |
| `CF_CONNECTING_IP` | *(empty)*    | `$http_cf_connecting_ip` only when Cloudflare is really in front; empty drops the header.                                                                 |
| `TZ`               | `Etc/UTC`    | Container timezone (logs, audit log). Reminders fire in each user's own zone regardless.                                                                  |

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
- **Licence texts ship inside the image** at `/usr/share/opengym/`: the AGPL
  text (`LICENSE`, byte-identical to the repo root) and upstream's third-party
  notice (`NOTICE.md`). The image redistributes upstream's build *and* the Gym
  visual exercise media, which upstream licenses separately from the AGPL, so
  the notice is a condition of carrying that media, not a formality.
- **Built from upstream's published images**, one `UPSTREAM_VERSION` variable
  driving both refs. The app is upstream's byte for byte; the CSP is taken from
  the web image at build time, so the inline-script hash never needs
  hand-syncing, and `NOTICE.md` is re-vendored on every release update (see Version
  management).
