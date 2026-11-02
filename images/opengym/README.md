# opengym

Single-container build of [openGym](https://github.com/DuarteSantos8/openGym):
Node API, nginx-served SPA and exercise media in one image, supervised by
s6-overlay. Built for Unraid; `templates/my-opengym.xml` deploys it there.

## Run

Prebuilt on Docker Hub: `docker pull 0x1917/opengym:latest`.

```sh
docker run -d --name opengym --restart unless-stopped   \
  -p 8310:80                                            \
  -e ORIGIN=https://gym.example.com                     \
  -v /mnt/user/appdata/opengym:/data                    \
  0x1917/opengym:latest
```

Only port 80 is published. nginx fronts everything and proxies `/api` to the
loopback API, so the app stays on a single origin (a passkey requirement).

## How the image is built

Nothing is compiled here. The Dockerfile starts from upstream's published images
(`ghcr.io/duartesantos8/opengym-api` and `opengym-web`), both at the release named
by `ARG UPSTREAM_VERSION`, and adds the supervision layer:
s6-overlay, uid-99 ownership, an unprivileged nginx master, and the boot-time
config rendering they need.

- No `git clone`, no `npm ci`. A build is layer copies, one `apk add` (nginx,
  gettext, tzdata) and the sha256-verified s6-overlay tarballs.
- The upstream **web** image supplies the built SPA, the nginx site template,
  the `BASE_PATH` guard, the exercise media and the CSP string.

### Build

Runs on any Docker host:

```sh
# VCS_REF and BUILD_DATE stamp the OCI provenance labels (BUILD_DATE is this
# repo's commit date, so it is deterministic per source state). BASE_DIGEST is
# resolved on the build host from the release pinned in the Dockerfile and only
# feeds the base digest label. Skip all three and the labels read dev/unknown.
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

On the same machine: `cd images/opengym && docker build -t opengym:test .`

### Try another upstream release without editing the file

```sh
docker build -t opengym:try                                              \
  --build-arg OPENGYM_API_IMAGE=ghcr.io/duartesantos8/opengym-api:<ver>  \
  --build-arg OPENGYM_WEB_IMAGE=ghcr.io/duartesantos8/opengym-web:<ver>  \
  images/opengym
```

`<ver>` is an upstream release tag with no leading `v`, matching upstream's own
image tags. Override **both** refs together: nothing in the Dockerfile
cross-checks that the API and web tags come from the same release. For a real
update, edit the ARG instead (see Version management).

## Test

`images/opengym/scripts/smoke-test.sh <image>` is the gate CI runs, and it runs
anywhere Docker does. It boots the image on a free loopback port with a throwaway
data dir and fails on the first broken expectation. Needs `docker`, `curl`, `jq`, 
and `openssl`.

```sh
bash images/opengym/scripts/smoke-test.sh opengym:test
```

| Check                                              | Proves                                                          |
| -------------------------------------------------- | --------------------------------------------------------------- |
| boots, `/api/health` ok through nginx              | both supervised services came up, proxy chain intact            |
| SPA responds with a CSP header                     | the web tier serves, with upstream's policy                     |
| exercise media served                              | the media copy from the web image landed at the served path     |
| npm absent from the image                          | the runtime-free upstream target shipped, no npm tree           |
| API not running as root                            | the uid-99 drop in `s6-api-run`                                 |
| licence texts ship (AGPL + notice)                 | a dropped `COPY` builds and boots fine, so nothing else notices |
| `PASSWORD_LOGIN` reaches the config endpoint       | image env surface and template rows agree                       |
| password signup + session cookie                   | the API can create a user and issue a session through the proxy |
| first user is administrator                        | `FIRST_USER_ADMIN` behaves as the template claims               |
| state written through the proxy                    | a real write path, not only a read                              |
| `/data` owned `99:100`                             | the Unraid appdata ownership contract                           |
| `docker stop` exits 0                              | no orphaned nginx, no swallowed signal                          |
| replacement keeps session + data, `BASE_PATH=/gym` | an upgrade does not lose data, and subpath mode serves          |
| invalid `BASE_PATH` refused at boot                | misconfiguration fails loudly instead of 404-ing                |

Deliberate gaps: passkey ceremonies (need a real browser), Coach provider jobs,
TLS and reverse-proxy behaviour, and anything requiring real user data.

## CI

`.github/workflows/opengym.yml`.

| Event                                                         | Runs                                  |
| ------------------------------------------------------------- | ------------------------------------- |
| push to `master` touching `images/opengym/**` or the workflow | build, smoke, publish                 |
| pull request touching the same paths                          | build and smoke, never publishes      |
| manual dispatch                                               | same as a push                        |

Order: resolve the version from the Dockerfile, build once with `load: true`,
run `smoke-test.sh`, retag and push, verify both tags carry one digest, then 
tag the source commit.

What matters:

- **The published image is the tested image.** One build, then `docker tag` and
  `docker push`. No second build, so published layers cannot differ from the
  verified ones.
- **Two tags per release:** `0x1917/opengym:<ver>` and `:latest`.
- **Publishing is gated on the image inputs.** A workflow-only push still builds
  and smokes but publishes nothing. Everything under `images/opengym/` counts as
  a build input except the CI scripts and this README, so a new file defaults to
  publishing rather than silently skipping.
- `timeout-minutes: 25`: a hung build fails instead of burning the 6 h default.
- `concurrency: opengym-<ref>` with `cancel-in-progress: false`: two quick pushes
  cannot race `:latest` or the source tag.
- Dependabot opens weekly PRs for new action majors; patch and minor updates
  arrive through the major tags.

### Upstream releases

`.github/workflows/upstream-check.yml` runs daily and on demand against two
upstreams: OpenGym's images (`ARG UPSTREAM_VERSION`) and s6-overlay
(`ARG S6_OVERLAY_VERSION` plus four tarball checksums, re-read from the release's
own `.sha256` assets). The logic is
`images/opengym/scripts/upstream-check.sh` (`check` and `apply`), which needs
only `curl` and `jq` and therefore also runs by hand. When something newer
exists it updates the ARGs, re-vendors `NOTICE.md`, builds, runs the smoke gate,
and only then opens a PR. Nothing publishes until that PR is merged.

- A PR opened with the built-in `GITHUB_TOKEN` starts no other workflow runs, so
  the `opengym` CI does not appear on it. Build and smoke evidence lives in the
  check run's log and the PR body.
- The branch name carries the date and both versions, so a re-run on the same day
  is a no-op while the PR is open. Close it unmerged and the next run proposes it
  again.

## Version management

`ARG UPSTREAM_VERSION` is the single source of truth. Both image refs derive from
it, so one edit cannot leave the pair mismatched.

`<ver>` below is an upstream release tag such as `X.Y.Z`: a placeholder for the
form, not a default. The published version is whatever the ARG says.

| Thing                                 | Form                                            | Example                |
| ------------------------------------- | ----------------------------------------------- | ---------------------- |
| upstream image tag                    | bare semver (upstream's own convention)         | `opengym-api:<ver>`    |
| this repo's Hub tag                   | bare semver, same as upstream                   | `0x1917/opengym:<ver>` |
| OCI `image.version` label             | bare semver                                     | `<ver>`                |
| git tag (CI)                          | `opengym-` + `v` + version; rebuilds get `-<n>` | `opengym-v<ver>`       |

### Update checklist

The daily check does steps 1 to 4 and opens a PR, merging that PR is step 5. By
hand:

1. Read upstream's release notes and confirm both image tags exist:
   `docker buildx imagetools inspect ghcr.io/duartesantos8/opengym-web:<ver>`.
2. Edit `ARG UPSTREAM_VERSION`.
3. Re-vendor `NOTICE.md` from the new tag
   (`git -C <upstream clone> show v<ver>:NOTICE.md > images/opengym/NOTICE.md`);
   re-copy `LICENSE` if upstream changed it.
4. Build and run `smoke-test.sh` locally.
5. Commit and push to `master`; CI publishes `<ver>` + `latest`.
6. Recreate the container on Unraid (Docker tab, Edit, Apply, or `docker pull`
   followed by `docker stop/rm/run`).

### Caveats

- **A rebuild reuses the Hub tag.** `<ver>` is overwritten, because Hub tags are
  mutable. The git side records every build: the first publish of a release gets
  `opengym-v<ver>`, and each rebuild gets `opengym-v<ver>-<n>`, numbered from the
  remote's tags. Inside the registry, `image.created` and `image.revision` still
  separate two builds of one release.
- **Rollback** is a previous release tag (`0x1917/opengym:<ver>`) or a local
  image. Old tags are not deleted.
- **The media is not AGPL.** Upstream's notice permits a non-commercial openGym
  fork to carry the unmodified 180 px media with the notice, which is why
  `NOTICE.md` ships inside the image and is re-vendored on every release update.

## Environment

Deploy-time variables, the same fields the Unraid template exposes:

| Variable           | Default       | Meaning                                                                                                                                                  |
| ------------------ | ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ORIGIN`           | *(required)*  | Exact address users type, scheme included. A mismatch refuses sign-in with `origin-mismatch`.                                                            |
| `RP_ID`            | *(empty)*     | Hostname from `ORIGIN`, no scheme or port. Required for passkeys; changing it invalidates them. Passkeys need HTTPS; on plain HTTP use `PASSWORD_LOGIN`. |
| `PASSWORD_LOGIN`   | `true`        | Adds name and password sign-in (upstream default: off). Registration stays a passkey ceremony.                                                           |
| `FIRST_USER_ADMIN` | `true`        | First profile on an empty instance becomes admin (upstream default: off).                                                                                |
| `ALLOW_GUEST`      | `true`        | `false` removes "Continue without account".                                                                                                              |
| `INVITE_ONLY`      | `false`       | `true` gates sign-ups behind an invite code. Create an admin profile first.                                                                              |
| `TRUST_PROXY`      | `true`        | Honour `X-Forwarded-For` and `X-Real-IP`; set when a reverse proxy fronts the container.                                                                 |
| `ADMIN_UIDS`       | *(empty)*     | Comma-separated account IDs (Settings, Account, Account ID) with admin dashboard access.                                                                 |
| `BASE_PATH`        | *(empty)*     | Subpath deployments (`/gym`, no trailing slash). Empty means site root.                                                                                  |
| `CF_CONNECTING_IP` | *(empty)*     | `$http_cf_connecting_ip`, only when Cloudflare is really in front; empty drops the header.                                                               |
| `TZ`               | `Etc/UTC`     | Container timezone for logs and the audit log. Reminders fire in each user's own zone regardless.                                                        |

## First boot

1. Map a host path to `/data` (chowned to uid 99 at boot).
2. Set `ORIGIN`, plus `RP_ID` for passkeys, to the address people will use.
3. Open the WebUI and create a profile.
4. Healthy once nginx answers and `/api/health` comes back through the proxy.

## Design notes

- **One image, two supervised processes.** Upstream's compose runs `api` and
  `web` as separate containers; merging them removes container-to-container DNS
  from the request path and leaves one artifact to build, back up and roll back.
- **s6-overlay, sha256-verified at build.** pid-1 signal handling, privilege
  dropping, ordered one-shot init.
- **Crash policy.** A crashed service restarts after 1s; five deaths in 60s end
  the CMD so Docker's restart policy owns the failure. A failed stage 2 stops the
  boot (`S6_BEHAVIOUR_IF_STAGE2_FAILS=2`).
- **Both services unprivileged.** API as uid 99 (group `users`, Unraid's appdata
  convention), nginx as the distro `nginx` account. Only the API can read
  `/data`.
- **Licence texts ship in the image** at `/usr/share/opengym/`: the AGPL text
  (`LICENSE`) and upstream's third-party notice (`NOTICE.md`). The image
  redistributes upstream's build and the separately licensed exercise media, so
  the notice is a condition of carrying that media, not a formality.
