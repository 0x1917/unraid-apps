#!/usr/bin/env bash
# Check for newer upstream releases, and apply the pin update, for images/opengym.
#
#   scripts/upstream-check.sh check               # report only (default)
#   scripts/upstream-check.sh apply <app> <s6>    # rewrite the pin(s)
#
# Two upstreams are tracked:
#   * OpenGym's published images (ghcr.io/duartesantos8/opengym-api): the
#     release ARG UPSTREAM_VERSION carries
#   * s6-overlay (github.com/just-containers/s6-overlay): ARG
#     S6_OVERLAY_VERSION plus the four sha256 values for the tarballs this
#     image downloads
#
# `check` reports only a NEWER release; a pin ahead of upstream, a missing
# asset or a half-published release is reported, never "corrected".
#
# `check` writes KEY=VALUE lines to stdout, and to $GITHUB_OUTPUT when set:
# app_current, app_latest, s6_current, s6_latest, update_available, reason.
# Network only; no Docker, no writes.
set -euo pipefail

# The script lives in images/opengym/scripts/, one level under the Dockerfile it
# edits, so the image is found relative to the script, not the caller's cwd.
IMAGES=$(cd "$(dirname "$0")/.." && pwd)
DOCKERFILE="$IMAGES/Dockerfile"
UPSTREAM=duartesantos8
S6_REPO=just-containers/s6-overlay

emit() {  # emit KEY VALUE
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
  printf '%s=%s\n' "$1" "$2"
}

arg_value() { sed -n "s/^ARG $1=//p" "$DOCKERFILE" | head -1; }

ghcr_token() { curl -fsS "https://ghcr.io/token?scope=repository:$1:pull" | jq -r .token; }

ghcr_tags() {
  local tok
  tok=$(ghcr_token "$1")
  curl -fsS -H "Authorization: Bearer $tok" \
    "https://ghcr.io/v2/$1/tags/list?n=1000" | jq -r '.tags[]'
}

# Highest clean x.y.z tag. Pre-releases, `latest`, `edge` and `1.4` are ignored:
# the Dockerfile pins an exact release.
app_latest() {
  ghcr_tags "$UPSTREAM/opengym-api" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}

newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# Upstream builds api and web from one tag; during a release window one image can
# exist before the other. Never propose a version that cannot be built.
app_buildable() {
  local ver=$1
  ghcr_tags "$UPSTREAM/opengym-web" | grep -qx "$ver"
}

s6_latest() {
  curl -fsS "https://api.github.com/repos/$S6_REPO/releases/latest" \
    | jq -r .tag_name | sed 's/^v//'
}

s6_sha() {  # s6_sha <version> <asset-basename> -> sha256 hex
  local ver=$1 name=$2 sha
  sha=$(curl -fsSL "https://github.com/$S6_REPO/releases/download/v$ver/$name.tar.xz.sha256" \
        | awk '{print $1}' | head -1)
  case "$sha" in
    *[!0-9a-f]*|"") echo "not a sha256 for $name at v$ver: '$sha'" >&2; return 1 ;;
  esac
  [ ${#sha} -eq 64 ] || { echo "wrong length for $name at v$ver" >&2; return 1; }
  printf '%s' "$sha"
}

cmd_apply() {
  local app=$1 s6=$2 sha tmpnotice names=() shas=()
  # Fetch and validate EVERYTHING before touching the tree: a failed download
  # must leave the checkout clean, not half-updated.
  tmpnotice=$(mktemp)
  curl -fsSL "https://raw.githubusercontent.com/DuarteSantos8/openGym/v$app/NOTICE.md" -o "$tmpnotice"
  grep -q "Gym visual" "$tmpnotice" \
    || { echo "NOTICE.md at v$app does not carry the media terms" >&2; rm -f "$tmpnotice"; exit 1; }
  curl -fsSL "https://raw.githubusercontent.com/DuarteSantos8/openGym/v$app/LICENSE" -o "$tmpnotice.lic"
  grep -q "GNU AFFERO GENERAL PUBLIC LICENSE" "$tmpnotice.lic" \
    || { echo "upstream LICENSE at v$app is no longer AGPL-3.0 — review by hand" >&2
         rm -f "$tmpnotice" "$tmpnotice.lic"; exit 1; }
  rm -f "$tmpnotice.lic"

  if [ "$s6" != "$(arg_value S6_OVERLAY_VERSION)" ]; then
    for pair in "S6_NOARCH_SHA256:noarch" "S6_OVERLAY_SHA256:x86_64" \
                "S6_SYMLINKS_ARCH_SHA256:symlinks-arch" \
                "S6_SYMLINKS_NOARCH_SHA256:symlinks-noarch"; do
      sha=$(s6_sha "$s6" "s6-overlay-${pair#*:}") \
        || { echo "cannot pin s6-overlay $s6 — release assets incomplete?" >&2; rm -f "$tmpnotice"; exit 1; }
      names+=("${pair%%:*}"); shas+=("$sha")
    done
  fi

  # All inputs are in hand; write them.
  sed -i "s|^ARG UPSTREAM_VERSION=.*|ARG UPSTREAM_VERSION=$app|" "$DOCKERFILE"
  if [ ${#names[@]} -gt 0 ]; then
    sed -i "s|^ARG S6_OVERLAY_VERSION=.*|ARG S6_OVERLAY_VERSION=$s6|" "$DOCKERFILE"
    local i
    for i in "${!names[@]}"; do
      sed -i "s|^ARG ${names[$i]}=.*|ARG ${names[$i]}=${shas[$i]}|" "$DOCKERFILE"
    done
    echo "s6-overlay -> $s6 with refreshed checksums"
  fi
  mv "$tmpnotice" "$IMAGES/NOTICE.md"
  echo "opengym -> $app (published as $app)"
}

cmd_check() {
  local app_cur s6_cur app_new s6_new reason="" update=false
  app_cur=$(arg_value UPSTREAM_VERSION)
  s6_cur=$(arg_value S6_OVERLAY_VERSION)
  app_new=$(app_latest)
  s6_new=$(s6_latest)

  if ! app_buildable "$app_new"; then
    reason="opengym-web:$app_new not published yet (upstream mid-release)"
    app_new=$app_cur
  fi
  # Only a NEWER release counts. A pin ahead of upstream (a parked or yanked
  # release) is not an update and must not be silently rewritten.
  if newer "$app_new" "$app_cur"; then
    update=true
    reason="${reason:+$reason; }opengym $app_cur -> $app_new"
  elif [ "$app_new" != "$app_cur" ]; then
    reason="pinned $app_cur is newer than upstream $app_new — not an update"
  fi
  if newer "$s6_new" "$s6_cur"; then
    update=true
    reason="${reason:+$reason; }s6-overlay $s6_cur -> $s6_new"
  fi
  [ "$update" = true ] || reason=${reason:-"no newer release"}

  emit app_current "$app_cur"
  emit app_latest "$app_new"
  emit s6_current "$s6_cur"
  emit s6_latest "$s6_new"
  emit update_available "$update"
  emit reason "$reason"
}

case "${1:-check}" in
  check)  cmd_check ;;
  apply)  cmd_apply "${2:?apply needs <app-version>}" "${3:?apply needs <s6-version>}" ;;
  *) echo "usage: $0 [check|apply <app> <s6>]" >&2; exit 2 ;;
esac
