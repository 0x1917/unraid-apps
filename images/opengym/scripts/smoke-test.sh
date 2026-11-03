#!/usr/bin/env bash
# Smoke test for the opengym image: boot it and walk the paths Unraid users
# depend on. Everything runs against disposable containers and a throwaway
# data dir; the only host state touched is that dir, removed on exit.
#
#   ./smoke-test.sh [image]        (default: opengym:test)
#
# Requires: docker, curl, jq, openssl, bash. ~40 s.
set -euo pipefail

IMAGE=${1:-opengym:test}
NAME=opengym-smoke
DATA=$(mktemp -d)
CJ=$(mktemp)
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # The container chowns /data to 99:100, so a non-root runner (CI) cannot unlink
  # its contents. Cleanup must never decide the gate's verdict — an EXIT trap that
  # fails turns a green run into exit 1.
  rm -rf "$DATA" "$CJ" 2>/dev/null || echo "note: left $DATA behind (owned by 99:100)" >&2
}
trap cleanup EXIT
pass() { printf 'PASS  %s\n' "$1"; }
die()  { printf 'FAIL  %s\n' "$1" >&2; docker logs "$NAME" 2>&1 | tail -25 >&2 || true; exit 1; }

free_port() {
  local p
  for p in $(shuf -i 20000-30000 -n 40); do
    ss -ltn 2>/dev/null | grep -q ":$p " || { echo "$p"; return; }
  done
  echo "no free port" >&2; exit 1
}
PORT=$(free_port)
ORIGIN="http://127.0.0.1:$PORT"

start() {  # $1 = BASE_PATH
  local prefix=${1:-}
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" -p "127.0.0.1:$PORT:80" -v "$DATA":/data \
    -e ORIGIN="$ORIGIN" -e RP_ID=127.0.0.1 -e BASE_PATH="$prefix" \
    -e PASSWORD_LOGIN=true -e FIRST_USER_ADMIN=true "$IMAGE" >/dev/null
  for _ in $(seq 1 45); do
    curl -fsS -o /dev/null "$ORIGIN$prefix/api/health" 2>/dev/null && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ] \
      || die "container exited during startup (BASE_PATH='$prefix')"
    sleep 1
  done
  die "API did not become ready (BASE_PATH='$prefix')"
}

req() {  # method path [json] -> body on stdout, -f on HTTP error
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -fsS -b "$CJ" -c "$CJ" -X "$method" -H "Origin: $ORIGIN" \
         -H 'Content-Type: application/json' -d "$body" "$ORIGIN$path"
  else
    curl -fsS -b "$CJ" -c "$CJ" -X "$method" -H "Origin: $ORIGIN" "$ORIGIN$path"
  fi
}

# --- first boot -------------------------------------------------------------
start ""
req GET /api/health | grep -q '"ok":true' || die "health payload"
pass "boots, /api/health ok through nginx"

curl -fsSI "$ORIGIN/" | grep -qi '^content-security-policy:.*script-src' \
  || die "CSP header missing"
pass "SPA responds with a CSP header"

MEDIA=$(docker exec "$NAME" sh -c 'ls /usr/share/nginx/html/exercise-media/still | head -1')
[ "$(curl -fsS -o /dev/null -w '%{http_code}' "$ORIGIN/exercise-media/still/$MEDIA")" = 200 ] \
  || die "exercise media"
pass "exercise media served ($MEDIA)"

if docker exec "$NAME" test -e /usr/local/bin/npm; then die "npm is present in the image"; fi
pass "npm absent from the image"

if docker top "$NAME" | grep 'node server.js' | grep -q '^root'; then die "API runs as root"; fi
pass "API does not run as root"

# Licence texts must travel with the image: a dropped COPY builds and boots
# fine, so nothing else in this gate would notice their absence.
# Liveness first: a container that died mid-gate makes every later exec fail,
# which then reads like a content failure. Say which it was.
[ "$(docker inspect --format '{{.State.Running}}' "$NAME" 2>/dev/null)" = "true" ] \
  || die "container stopped during the gate (docker logs above)"
docker exec "$NAME" sh -c 'test -s /usr/share/opengym/LICENSE && test -s /usr/share/opengym/NOTICE.md' \
  || die "licence files missing from the image"
# Capture then match, never pipe: with pipefail a failing exec is
# indistinguishable from a non-matching grep.
LIC=$(docker exec "$NAME" sh -c 'head -c 200 /usr/share/opengym/LICENSE') \
  || die "could not read LICENSE from the image (exec failed)"
case "$LIC" in
  *"GNU AFFERO GENERAL PUBLIC LICENSE"*) ;;
  *) die "LICENSE is not the AGPL text (first bytes: ${LIC:0:80})" ;;
esac
docker exec "$NAME" grep -q 'Gym visual' /usr/share/opengym/NOTICE.md \
  || die "NOTICE.md lacks the media terms"
pass "licence texts ship in the image (AGPL + third-party notice)"

req GET /api/config | grep -q '"password_login":true' || die "password_login flag"
pass "PASSWORD_LOGIN reaches the config endpoint"

# --- account, admin, data ---------------------------------------------------
PW=$(openssl rand -hex 16)
UID_=$(req POST /api/register/password "{\"name\":\"ci-smoke\",\"password\":\"$PW\"}" | jq -r '.user.id')
[ -n "$UID_" ] && [ "$UID_" != null ] || die "password signup"
req GET /api/me | jq -e --arg u "$UID_" '.user.id == $u' >/dev/null || die "/api/me after signup"
pass "password signup + session cookie"

req GET /api/admin/users >/dev/null || die "first user is not admin"
pass "first user is administrator"

req PUT /api/data '{"state":{"workouts":[],"routines":[],"settings":{"smoke":"marker"}},"baseRev":0}' >/dev/null
req GET /api/data | jq -e '.state.settings.smoke == "marker"' >/dev/null || die "data write"
pass "state written through the proxy"

[ "$(stat -c %u:%g "$DATA")" = "99:100" ] || die "appdata owned $(stat -c %u:%g "$DATA")"
pass "/data owned 99:100 (Unraid appdata ownership)"

# --- replacement: only /data survives --------------------------------------
docker stop -t 10 "$NAME" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")" = 0 ] || die "non-zero exit on docker stop"
pass "docker stop exits 0 (clean shutdown)"

start "/gym"
req GET /gym/api/me | jq -e --arg u "$UID_" '.user.id == $u' >/dev/null \
  || die "session lost across container replacement"
req GET /gym/api/data | jq -e '.state.settings.smoke == "marker"' >/dev/null \
  || die "data lost across container replacement"
[ "$(curl -fsS -o /dev/null -w '%{http_code}' "$ORIGIN/gym/")" = 200 ] || die "SPA under BASE_PATH"
pass "replacement keeps session + data; BASE_PATH=/gym serves"

# --- bad config is refused at boot ----------------------------------------
set +e
OUT=$(docker run --rm -e BASE_PATH=gym "$IMAGE" 2>&1); RC=$?
set -e
[ "$RC" -ne 0 ] || die "invalid BASE_PATH exited 0"
printf '%s' "$OUT" | grep -q 'does not start with' || die "invalid BASE_PATH message"
pass "invalid BASE_PATH refused at boot (exit $RC)"

printf '\nsmoke test: %s OK\n' "$IMAGE"
