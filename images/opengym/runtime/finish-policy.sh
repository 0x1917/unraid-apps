#!/bin/sh
# Shared crash policy for the longrun services, invoked by <service>/finish with:
#   $1 = service name, $2 = exit code of the run process, $3 = signal that killed it
# (s6-supervise passes the exit code and signal to finish; see README.md).
#
# Policy:
#   - a deliberate stop (SIGTERM — what s6 sends on container shutdown) is not a
#     crash: no counting, no sleep, let the shutdown be quick;
#   - any other death counts, per service;
#   - restart with a small backoff (the sleep at the end) so a fast-crashing service
#     cannot burn CPU in a tight loop;
#   - >= 5 deaths of the same service within 60 s is a crash loop that will not fix
#     itself: terminate s6 (s6-svscanctl -t) so the CONTAINER exits and Docker's
#     restart policy (which sees the container as failed and can back off or alert)
#     takes over. Restarting forever inside the container would hide the failure.
#
# The counter lives in /run: a fresh container starts with a clean record, so an
# old crash history can never escalate a healthy boot.

name="$1"
code="${2:-0}"
sig="${3:-0}"

case "$sig" in
  15|SIGTERM) exit 0 ;;
esac
case "$code" in
  143) exit 0 ;;  # died of TERM reported through the exit code
esac

dir=/run/opengym-crash/$name
mkdir -p "$dir"
now=$(date +%s)
echo "$now" >> "$dir/stamps"
# keep only deaths within the last 60 s
recent="$dir/stamps.new"
: > "$recent"
while read -r t; do
  [ $((now - t)) -le 60 ] && echo "$t" >> "$recent"
done < "$dir/stamps"
mv "$recent" "$dir/stamps"
n=$(wc -l < "$dir/stamps" | tr -d ' ')

echo "opengym-finish[$name]: service died (exit=$code signal=$sig) — $n death(s) in the last 60 s" >&2

if [ "$n" -ge 5 ]; then
  echo "opengym-finish[$name]: crash loop — terminating the container so the Docker restart policy can act" >&2
  # Escalate: end the CMD (s6-pause). s6-overlay's /init keeps the container alive
  # exactly as long as the CMD runs, and a CMD that exits is its documented shutdown
  # trigger: /init runs stage 3, brings every supervised service down in order and
  # pid 1 exits. Because the CMD is TERMed, the container exits 143 — a failed
  # container, which is what Docker's restart policy (on-failure included) acts on.
  #
  # Why not s6-svscanctl -t first: svscan supervises shutdownd, and taking svscan
  # down first kills the socket the shutdown path needs, leaving the container
  # half-dead ("unable to talk to shutdownd: Operation not permitted" — observed).
  # svscanctl therefore stays only as a last-resort fallback.
  for p in $(pidof s6-pause); do
    kill -TERM "$p" 2>/dev/null || true
  done
  ( sleep 10; s6-svscanctl -t /run/service ) >/dev/null 2>&1 &
  exit 0
fi

sleep 1
exit 0
