#!/bin/sh
# One-shot init — runs as root, once, before any longrun starts. Everything here is
# first-boot/config-bootstrap work; the exercise media is baked into the image and
# needs no seeding (see README.md).
set -eu

# 1. BASE_PATH sanity, upstream's web/05-check-base-path.sh copied unchanged:
# https://github.com/DuarteSantos8/openGym/blob/v1.4.3/web/05-check-base-path.sh
/usr/libexec/opengym/05-check-base-path.sh

# 2. /data is the one bind-mounted path (users, passkeys, session secret, uploads).
# chown is on the directory itself only — never recursive, so a large existing data
# set is not walked on every boot. 99:users is Unraid's appdata ownership
# convention, which is why the service account is that uid/gid.
mkdir -p /data /data/uploads
chown opengym:users /data /data/uploads
s6-setuidgid opengym sh -c 'touch /data/.write-probe && rm -f /data/.write-probe' || {
  echo "init-config: /data is not writable by uid 99 (opengym). Check the ownership of the host path mapped to /data." >&2
  exit 1
}

# 3. nginx runtime state: everything writable lives under /run/nginx, owned by the
# account nginx runs as, so an unprivileged master has a pid file and temp paths it
# can actually write. The log fifo (mode 0666 — nginx must be able to open it for
# writing) exists because an unprivileged process cannot re-open this runtime's
# /dev/stdout|/dev/stderr; see nginx/run and the main nginx.conf.
install -d -o nginx -g nginx /run/nginx /run/nginx/client_temp /run/nginx/proxy_temp \
                             /run/nginx/fastcgi_temp /run/nginx/uwsgi_temp /run/nginx/scgi_temp
rm -f /run/nginx/log.pipe
mkfifo -m 0666 /run/nginx/log.pipe
chmod 0666 /run/nginx/log.pipe

# 4. Render the site config from upstream's template. The variable list is
# explicit: envsubst replaces every \${VAR} it is given, and blindly substituting
# all environment variables would also eat nginx's own runtime variables ($host,
# $request_uri, ...) that the template needs intact.
#
# The CSP is not a container ENV: it ships as a file baked from upstream's web
# image (the policy hash must track the frontend), so default the variable from
# it here, where a deployer's explicit override still wins.
CONTENT_SECURITY_POLICY=${CONTENT_SECURITY_POLICY:-$(cat /etc/opengym/content-security-policy)}
export CONTENT_SECURITY_POLICY
envsubst '${NGINX_PORT} ${BASE_PATH} ${BACKEND} ${PORT} ${RESOLVER} ${CF_CONNECTING_IP} ${MEDIA_UPLOAD_MAX} ${CONTENT_SECURITY_POLICY}' \
  < /etc/nginx/templates/default.conf.template > /run/nginx/site.conf
chown nginx:nginx /run/nginx/site.conf

# 5. Fail the boot NOW on a config nginx would refuse, with nginx's own error — not
# on the first request, or in a finish-script restart loop. `nginx -t` runs as ROOT
# (it only has to validate the rendered template); the log fifo is drained by a
# throwaway reader meanwhile, because opening a fifo for writing blocks until a
# reader exists and nginx -t opens the configured logs.
cat /run/nginx/log.pipe >/dev/null &
probe_reader=$!
rc=0
nginx -t -c /etc/nginx/nginx.conf || rc=$?
kill "$probe_reader" 2>/dev/null || true
[ "$rc" -eq 0 ] || exit "$rc"
# The test run creates the pid file as root; the service must create its own as the
# nginx account, or it fails with EACCES on a root-owned file.
rm -f /run/nginx/nginx.pid
# Same class of trap on nginx's built-in default error log: nginx opens that log
# BEFORE it parses -c, so this root test creates /var/log/nginx/error.log
# root-owned and the unprivileged service can then only print
#   [alert] could not open error log file ... (13: Permission denied)
# and carry on via stderr. Hand the file to the service account; once the config is
# parsed, the configured error_log (the /run/nginx/log.pipe fifo) takes over.
chown nginx:nginx /var/log/nginx/error.log 2>/dev/null || true
