#!/usr/bin/env bash
# shellcheck shell=bash
#
# OpenHost bootstrap for Paperless-ngx.
#
# Runs once per boot, before any of Paperless's own init oneshots.
# Responsibilities:
#
#   1. Move (via symlink) the four state directories that the upstream
#      image expects under /usr/src/paperless/{data,media,consume,export}
#      to live under $OPENHOST_APP_DATA_DIR instead, so they survive
#      container re-creation. Paperless's `init-folders` oneshot will
#      then mkdir/chown the *targets* (which is fine — chown follows
#      symlinks).
#
#   2. On first boot only, generate a random password for the
#      `operator` superuser, write it to
#      $OPENHOST_APP_DATA_DIR/admin-password.txt mode 0600, and stamp
#      PAPERLESS_ADMIN_USER / PAPERLESS_ADMIN_PASSWORD into
#      /run/s6/container_environment so the upstream `init-superuser`
#      oneshot (which is idempotent) creates the account. A sentinel
#      `.admin_bootstrapped` makes this a no-op on later boots so an
#      admin password change through the UI is not silently reverted.
#
#   3. Stamp PAPERLESS_URL / PAPERLESS_ALLOWED_HOSTS /
#      PAPERLESS_CSRF_TRUSTED_ORIGINS into the contenv from
#      $OPENHOST_ZONE_DOMAIN. Paperless's Django frontend will reject
#      requests with a Host: paperless-ngx.<zone> header otherwise.
#
# We deliberately keep all OpenHost-specific knowledge in this one
# script; everything else in the image is stock paperless-ngx.

set -euo pipefail

log() { echo "[init-openhost-bootstrap] $*"; }

# ---------------------------------------------------------------------------
# 0. Preconditions
# ---------------------------------------------------------------------------

# OpenHost always sets OPENHOST_APP_DATA_DIR when app_data=true. If it
# is unset we are probably running in a plain-Docker test harness;
# fall back to /data so the rest of the script still works.
DATA_ROOT="${OPENHOST_APP_DATA_DIR:-/data}"
mkdir -p "${DATA_ROOT}"

# The contenv directory is where s6 writes per-container env vars. Any
# file we drop here is exported into the environment of every later
# service via /command/with-contenv. This is the s6-overlay v3 way of
# passing values from a oneshot to a longrun.
#
# Reference: https://github.com/just-containers/s6-overlay#container-environment
CONTENV_DIR="/run/s6/container_environment"
mkdir -p "${CONTENV_DIR}"

# Helper: write a single env var into the contenv. The file name is
# the var name; the file contents are the value with no trailing
# newline. We use printf %s rather than echo so embedded "\n" or "-n"
# in a password don't get interpreted.
contenv_set() {
    local name="$1"
    local value="$2"
    printf '%s' "${value}" > "${CONTENV_DIR}/${name}"
}

# ---------------------------------------------------------------------------
# 1. Relocate paperless's state dirs into $OPENHOST_APP_DATA_DIR.
#
# The upstream image's init-folders / init-migrations / search-index
# oneshots all key off PAPERLESS_DATA_DIR / PAPERLESS_MEDIA_ROOT /
# PAPERLESS_CONSUMPTION_DIR for their target directories. We could
# just set those env vars and have paperless write directly under
# $DATA_ROOT, but the *defaults* compiled into Paperless's settings
# point at /usr/src/paperless/{data,media,consume,export}; setting
# the env vars only rewires Paperless's own code, not, e.g., the
# nltk_data fallback or any third-party tool that hardcoded a path.
#
# Symlinking the paths is the conservative choice: every reference
# to /usr/src/paperless/<name> — whether by env-aware code or by a
# hard-coded path — transparently lands in $DATA_ROOT/<name>.
# ---------------------------------------------------------------------------

for name in data media consume export; do
    src_path="/usr/src/paperless/${name}"
    dest_path="${DATA_ROOT}/${name}"

    mkdir -p "${dest_path}"
    # Make sure paperless (uid 1000) can write there. The OPENHOST_APP_DATA_DIR
    # mount itself is owned by container-root under rootless podman; the
    # subdirs we create are inheriting that, so we explicitly chown.
    chown -R paperless:paperless "${dest_path}"

    if [ -L "${src_path}" ]; then
        # Already symlinked from a previous boot — just verify the
        # target. If $OPENHOST_APP_DATA_DIR ever changes (it shouldn't,
        # but defense in depth) we re-link.
        current_target=$(readlink "${src_path}")
        if [ "${current_target}" != "${dest_path}" ]; then
            log "Re-pointing symlink ${src_path} -> ${dest_path} (was ${current_target})"
            rm -f "${src_path}"
            ln -s "${dest_path}" "${src_path}"
        fi
    else
        # First boot: directory exists from the image build with
        # placeholder contents. Move any pre-existing files into the
        # persistent dir (typically empty, but be defensive) and
        # replace with a symlink.
        if [ -d "${src_path}" ]; then
            # Use cp -a + rm to handle the cross-filesystem case (the
            # OPENHOST_APP_DATA_DIR mount is on a different fs than
            # the container's overlay, so `mv` would fall back to
            # cp+rm anyway and we'd rather be explicit).
            shopt -s dotglob nullglob
            existing=("${src_path}"/*)
            shopt -u dotglob nullglob
            if [ "${#existing[@]}" -gt 0 ]; then
                log "Migrating contents of ${src_path} into ${dest_path}"
                cp -a "${existing[@]}" "${dest_path}/" 2>/dev/null || true
            fi
            rm -rf "${src_path}"
        fi
        ln -s "${dest_path}" "${src_path}"
        log "Linked ${src_path} -> ${dest_path}"
    fi
done

# ---------------------------------------------------------------------------
# 2. URL / Host / CSRF config from $OPENHOST_ZONE_DOMAIN.
#
# OpenHost routes https://paperless-ngx.<zone>/* into our container.
# Django's ALLOWED_HOSTS check rejects a Host header it doesn't
# recognise, and Django's CSRF middleware rejects POSTs whose Origin
# isn't in CSRF_TRUSTED_ORIGINS. We feed those settings from the env
# OpenHost gives us.
# ---------------------------------------------------------------------------

ZONE_DOMAIN="${OPENHOST_ZONE_DOMAIN:-}"
APP_NAME="${OPENHOST_APP_NAME:-paperless-ngx}"

if [ -n "${ZONE_DOMAIN}" ]; then
    HOSTNAME="${APP_NAME}.${ZONE_DOMAIN}"

    case "${ZONE_DOMAIN}" in
        lvh.me|*.lvh.me|localhost|*.localhost)
            # Dev environment — router runs on a non-standard port,
            # extract it from $OPENHOST_ROUTER_URL and use http.
            ROUTER_PORT=""
            if [ -n "${OPENHOST_ROUTER_URL:-}" ]; then
                ROUTER_PORT=$(printf '%s' "${OPENHOST_ROUTER_URL}" | sed -n 's/.*:\([0-9]*\).*/\1/p')
            fi
            BASE_URL="http://${HOSTNAME}${ROUTER_PORT:+:$ROUTER_PORT}"
            ;;
        *)
            BASE_URL="https://${HOSTNAME}"
            ;;
    esac

    # PAPERLESS_URL is the canonical absolute base URL the frontend
    # uses for redirects, password-reset emails, etc. PAPERLESS_ALLOWED_HOSTS
    # must include the bare hostname (no scheme). PAPERLESS_CSRF_TRUSTED_ORIGINS
    # *must* include scheme. See:
    #   https://docs.paperless-ngx.com/configuration/#hosting-and-security
    contenv_set PAPERLESS_URL "${BASE_URL}"
    # Allow both the apex hostname (production) and "localhost" (so the
    # router's internal health check by IP+Host: paperless-ngx still
    # passes if it ever sets Host explicitly — Granian binds 0.0.0.0
    # so by default it accepts whatever Host the router forwards).
    contenv_set PAPERLESS_ALLOWED_HOSTS "${HOSTNAME},localhost,127.0.0.1"
    contenv_set PAPERLESS_CSRF_TRUSTED_ORIGINS "${BASE_URL}"

    log "Configured PAPERLESS_URL=${BASE_URL}"
else
    log "WARN: OPENHOST_ZONE_DOMAIN unset — Paperless will use Django defaults for ALLOWED_HOSTS"
fi

# ---------------------------------------------------------------------------
# 3. Admin user bootstrap.
#
# We create a single `operator` superuser on first boot only. The
# upstream `init-superuser` oneshot (which we depend on running after
# us) reads PAPERLESS_ADMIN_USER / PAPERLESS_ADMIN_PASSWORD from the
# env and runs `manage.py manage_superuser`, which is idempotent —
# it won't change the password of an existing user, so leaving the
# env vars set across boots would be safe, but we also drop a sentinel
# so a future operator can rotate the password from the UI without
# us silently reverting it on restart.
# ---------------------------------------------------------------------------

ADMIN_PASSWORD_FILE="${DATA_ROOT}/admin-password.txt"
SENTINEL="${DATA_ROOT}/.admin_bootstrapped"
ADMIN_USER="operator"

if [ ! -f "${SENTINEL}" ]; then
    log "First boot: generating ${ADMIN_USER} password"

    # 24 random bytes -> ~32 chars of base64url (no padding, no
    # ambiguous chars). /dev/urandom is the cryptographically secure
    # source on Linux. We avoid `head -c` on /dev/urandom + base64
    # piping issues by reading exactly the bytes we want with dd.
    ADMIN_PASSWORD=$(dd if=/dev/urandom bs=24 count=1 status=none \
        | base64 \
        | tr -d '\n=+/' \
        | cut -c1-32)

    # Write the password file *before* exporting the env vars. If the
    # write fails (e.g. disk full), we'd rather refuse to start than
    # have an admin account whose password is known only to the
    # in-memory environment of this boot.
    umask 077
    printf '%s\n' "${ADMIN_PASSWORD}" > "${ADMIN_PASSWORD_FILE}"
    chmod 0600 "${ADMIN_PASSWORD_FILE}"

    contenv_set PAPERLESS_ADMIN_USER "${ADMIN_USER}"
    contenv_set PAPERLESS_ADMIN_PASSWORD "${ADMIN_PASSWORD}"
    # PAPERLESS_ADMIN_MAIL has a default in the Dockerfile; the contenv
    # value will override the Dockerfile's ENV value if anything later
    # reads it from the contenv dir.

    # Drop the sentinel last, so a crash mid-bootstrap on first boot
    # leaves us re-trying on the next boot rather than silently never
    # creating the admin.
    touch "${SENTINEL}"
    log "Wrote admin credentials to ${ADMIN_PASSWORD_FILE}"
else
    log "Admin already bootstrapped (sentinel ${SENTINEL} exists); skipping"
fi

log "Bootstrap complete"
