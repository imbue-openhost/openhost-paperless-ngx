#!/usr/bin/env bash
# shellcheck shell=bash
#
# OpenHost bootstrap for Paperless-ngx.
#
# Runs once per boot, before any of Paperless's own init oneshots.
# Responsibilities:
#
#   1. Point Paperless's data dirs at $OPENHOST_APP_DATA_DIR by
#      exporting PAPERLESS_DATA_DIR / PAPERLESS_MEDIA_ROOT /
#      PAPERLESS_CONSUMPTION_DIR into the s6 container_environment.
#      The upstream image declares /usr/src/paperless/{data,media,
#      consume,export} as VOLUMEs, so we *cannot* symlink those paths
#      away — they're mountpoints. Setting the env vars makes
#      Paperless's Django settings module read the persistent paths
#      directly, leaving the (anonymous) VOLUME mountpoints
#      unreferenced.
#
#      The export dir is left at its volume default (/usr/src/paperless/
#      export) because Paperless does not expose an env var override
#      for it. Export staging is throwaway data, so this is fine; an
#      operator who runs `manage.py document_exporter` from the
#      paperless shell will get output in the anonymous volume and
#      can copy it elsewhere.
#
#   2. On first boot only, generate a 32-character random password
#      for the `operator` superuser, write it to
#      $OPENHOST_APP_DATA_DIR/admin-password.txt mode 0600, and
#      export PAPERLESS_ADMIN_USER / PAPERLESS_ADMIN_PASSWORD into
#      the container_environment so that the upstream `init-superuser`
#      oneshot (idempotent — `manage.py manage_superuser` only creates
#      the account if it doesn't already exist) creates the account.
#      A sentinel `.admin_bootstrapped` makes this a no-op on later
#      boots so an operator who later changes the admin password
#      through the Paperless UI does not have it silently reverted.
#
#   3. Stamp PAPERLESS_URL / PAPERLESS_ALLOWED_HOSTS /
#      PAPERLESS_CSRF_TRUSTED_ORIGINS into the container_environment
#      from $OPENHOST_ZONE_DOMAIN so Django accepts the incoming
#      Host: paperless-ngx.<zone> header.
#
# All OpenHost-specific knowledge lives in this one script.
# Everything else in the image is stock paperless-ngx (modulo our
# Redis sidecar service).

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

# The contenv directory is where s6 records per-container env vars.
# Any file we drop here is exported into the environment of every
# later service started via /command/with-contenv. This is the
# s6-overlay v3 way of passing values from a oneshot to a longrun.
#
# Reference: https://github.com/just-containers/s6-overlay#container-environment
CONTENV_DIR="/run/s6/container_environment"
mkdir -p "${CONTENV_DIR}"

# Helper: write a single env var into the contenv. The file name is
# the var name; the file contents are the value with no trailing
# newline. We use printf %s rather than echo so embedded "-n" or
# escape sequences in a generated password don't get interpreted.
contenv_set() {
    local name="$1"
    local value="$2"
    printf '%s' "${value}" > "${CONTENV_DIR}/${name}"
}

# ---------------------------------------------------------------------------
# 1. Persistent storage layout under $OPENHOST_APP_DATA_DIR.
# ---------------------------------------------------------------------------

PERSIST_DATA="${DATA_ROOT}/data"
PERSIST_MEDIA="${DATA_ROOT}/media"
PERSIST_CONSUME="${DATA_ROOT}/consume"

mkdir -p "${PERSIST_DATA}" "${PERSIST_MEDIA}" "${PERSIST_CONSUME}"

# Make sure the paperless user (uid 1000 inside the container) can
# write to these dirs. The OPENHOST_APP_DATA_DIR mount is owned by
# container-root under rootless podman; we delegate ownership to the
# paperless account which runs the actual webserver / celery / consumer
# processes.
#
# On rootless podman, chown of a userns-mapped subdir to uid 1000
# remaps to host (subuid_offset + 1000). Because we are
# in-container-root we are allowed to perform this remap.
chown -R paperless:paperless "${PERSIST_DATA}" "${PERSIST_MEDIA}" "${PERSIST_CONSUME}"

# Wire Paperless to read from these paths. Paperless's Django
# settings.py respects all three of these env vars at startup
# (settings.py: __get_path("PAPERLESS_DATA_DIR", ...) etc).
contenv_set PAPERLESS_DATA_DIR        "${PERSIST_DATA}"
contenv_set PAPERLESS_MEDIA_ROOT      "${PERSIST_MEDIA}"
contenv_set PAPERLESS_CONSUMPTION_DIR "${PERSIST_CONSUME}"

# ---------------------------------------------------------------------------
# 2. URL / Host / CSRF config from $OPENHOST_ZONE_DOMAIN.
#
# OpenHost routes https://paperless-ngx.<zone>/* into our container.
# Django's ALLOWED_HOSTS check rejects a Host header it doesn't
# recognise (returns 400), and Django's CSRF middleware rejects
# POSTs whose Origin isn't in CSRF_TRUSTED_ORIGINS (returns 403).
# Set both from the env OpenHost gives us.
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
    # uses for redirects, password-reset emails, etc.
    # PAPERLESS_ALLOWED_HOSTS must include the bare hostname (no
    # scheme). PAPERLESS_CSRF_TRUSTED_ORIGINS *must* include scheme.
    # See: https://docs.paperless-ngx.com/configuration/#hosting-and-security
    contenv_set PAPERLESS_URL "${BASE_URL}"
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
# upstream `init-superuser` oneshot (which transitively runs after us
# via the init-folders → init-migrations → init-superuser dep chain)
# reads PAPERLESS_ADMIN_USER / PAPERLESS_ADMIN_PASSWORD from the env
# and runs `manage.py manage_superuser`, which is *create-only* —
# the upstream command explicitly returns early if the username is
# taken or any superuser already exists (see paperless-ngx
# src/documents/management/commands/manage_superuser.py). That means:
#
#   - The sentinel-based "skip on later boots" behaviour matches the
#     upstream command's actual semantics: even if we did re-export
#     PAPERLESS_ADMIN_PASSWORD with a new value, it would be ignored.
#   - Recovery from a lost admin password is *not* "delete the
#     sentinel and reload". An operator has to use
#     `manage.py changepassword operator` (run via `podman exec` on
#     the host or through Paperless's UI). The README documents this.
#
# The sentinel still serves as a defence-in-depth marker — if a
# future paperless-ngx release made manage_superuser update the
# password for an existing user (it doesn't today), we would *not*
# want to silently re-roll the operator password on every boot.
# ---------------------------------------------------------------------------

ADMIN_PASSWORD_FILE="${DATA_ROOT}/admin-password.txt"
SENTINEL="${DATA_ROOT}/.admin_bootstrapped"
ADMIN_USER="operator"

if [ ! -f "${SENTINEL}" ]; then
    log "First boot: generating ${ADMIN_USER} password"

    # We want a stable 32-character ASCII-letter-and-digit password.
    # Naïve base64 of 24 random bytes is exactly 32 chars but contains
    # `+` and `/`, which we strip — and after stripping, the result is
    # typically shorter than 32. Read enough source entropy (96 random
    # bytes -> 128 base64 chars; on average about 122 survive the strip)
    # that the post-strip output is overwhelmingly likely to be at least
    # 32 chars, then `cut -c1-32` gives a stable-length string. We
    # additionally validate the length and refuse to start the container
    # if anything goes wrong (would only happen if /dev/urandom or
    # base64 is broken, but better to fail loudly than silently mint a
    # short-and-weak admin password).
    ADMIN_PASSWORD=$(dd if=/dev/urandom bs=96 count=1 status=none \
        | base64 \
        | tr -d '\n=+/' \
        | cut -c1-32)
    if [ "${#ADMIN_PASSWORD}" -lt 32 ]; then
        log "ERROR: generated password is only ${#ADMIN_PASSWORD} chars (expected 32)"
        exit 1
    fi

    # Write the password file *before* exporting the env vars. If the
    # write fails (e.g. disk full), we'd rather refuse to start than
    # have an admin account whose password is known only to the
    # in-memory environment of this boot.
    umask 077
    printf '%s\n' "${ADMIN_PASSWORD}" > "${ADMIN_PASSWORD_FILE}"
    chmod 0600 "${ADMIN_PASSWORD_FILE}"

    contenv_set PAPERLESS_ADMIN_USER "${ADMIN_USER}"
    contenv_set PAPERLESS_ADMIN_PASSWORD "${ADMIN_PASSWORD}"

    # Drop the sentinel last, so a crash mid-bootstrap on first boot
    # leaves us re-trying on the next boot rather than silently never
    # creating the admin.
    touch "${SENTINEL}"
    log "Wrote admin credentials to ${ADMIN_PASSWORD_FILE}"
else
    log "Admin already bootstrapped (sentinel ${SENTINEL} exists); skipping"
fi

log "Bootstrap complete"
