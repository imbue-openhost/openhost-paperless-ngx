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
# 1b. Bind paperless's webserver to loopback so the auth-proxy is the
#     only thing on the OpenHost-routed port.
#
# The auth-proxy listens on 0.0.0.0:8080 (the OpenHost manifest's
# `port`) and forwards to 127.0.0.1:8000 (paperless). Without binding
# paperless to loopback, the upstream gunicorn/granian listens on
# 0.0.0.0:8000 and only the manifest's port routing prevents direct
# external access — defence in depth says we should also force the
# kernel to refuse non-loopback connections to paperless.
# ---------------------------------------------------------------------------
contenv_set PAPERLESS_BIND_ADDR       "127.0.0.1"
contenv_set PAPERLESS_PORT            "8000"

# ---------------------------------------------------------------------------
# 1c. Trusted-header SSO (Pattern A).
#
# When the OpenHost router stamps X-OpenHost-Is-Owner: true on an
# owner request, the auth-proxy forwards `Remote-User: operator` to
# paperless. Paperless reads HTTP_REMOTE_USER from the WSGI env
# (Django normalises request header `Remote-User` -> HTTP_REMOTE_USER)
# and treats the named user as authenticated.
#
# `_API=true` extends the same trust to /api/* routes so the
# paperless mobile/desktop apps work behind the OpenHost router.
# Without it, the dashboard works but the SPA's XHRs fail with 401
# because allauth's session-only API auth backend doesn't honour
# REMOTE_USER.
#
# IMPORTANT: this is safe ONLY because the auth-proxy strips any
# client-supplied Remote-User header before any other processing
# (see auth_proxy.py:ALWAYS_STRIP_HEADERS). Exposing
# PAPERLESS_ENABLE_HTTP_REMOTE_USER without a header-stripping reverse
# proxy in front would let any caller authenticate as any user.
# ---------------------------------------------------------------------------
contenv_set PAPERLESS_ENABLE_HTTP_REMOTE_USER     "true"
contenv_set PAPERLESS_ENABLE_HTTP_REMOTE_USER_API "true"
contenv_set PAPERLESS_HTTP_REMOTE_USER_HEADER_NAME "HTTP_REMOTE_USER"

# ---------------------------------------------------------------------------
# 1d. Django SECRET_KEY.
#
# Recent paperless-ngx releases refuse to start unless
# PAPERLESS_SECRET_KEY is set to a non-default value (settings.py raises
# ImproperlyConfigured when it is unset or equal to the seeded
# "change-me"). The key must be *stable across reboots* — Django uses it
# to sign sessions and (with the encrypted-fields feature) to protect
# stored secrets, so re-rolling it on every boot would log everyone out
# and could corrupt encrypted data. So we generate it once on first boot,
# persist it under $OPENHOST_APP_DATA_DIR mode 0600, and re-export the
# same value on every subsequent boot.
#
# The file lives outside the DB so it survives a DB reset and is trivial
# to inspect. Anyone who can read it can forge sessions, so it is
# mode 0600 and treated as a secret (same threat model as
# admin-password.txt: an operator who mounts this app's data via
# file-browser can read it).
# ---------------------------------------------------------------------------

SECRET_KEY_FILE="${DATA_ROOT}/secret-key.txt"

if [ -f "${SECRET_KEY_FILE}" ]; then
    SECRET_KEY=$(head -1 "${SECRET_KEY_FILE}")
    if [ -z "${SECRET_KEY}" ]; then
        log "ERROR: ${SECRET_KEY_FILE} exists but is empty; aborting bootstrap"
        exit 1
    fi
    log "Loaded existing PAPERLESS_SECRET_KEY from ${SECRET_KEY_FILE}"
else
    log "First boot: generating PAPERLESS_SECRET_KEY"
    # 64 random bytes -> URL-safe base64. We strip newlines only; the
    # URL-safe alphabet (A-Za-z0-9-_) plus '=' padding is all accepted
    # by Django's SECRET_KEY (it is treated as opaque bytes), so unlike
    # the admin password we do not need to strip '+'/'/'.
    SECRET_KEY=$(dd if=/dev/urandom bs=64 count=1 status=none | base64 | tr -d '\n')
    if [ "${#SECRET_KEY}" -lt 43 ]; then
        log "ERROR: generated secret key is only ${#SECRET_KEY} chars; aborting"
        exit 1
    fi
    # Atomic write: temp file -> fsync -> rename, so a crash never leaves
    # a partial key that a later boot would load as the real one.
    umask 077
    TMP_SECRET_KEY_FILE="${SECRET_KEY_FILE}.tmp"
    printf '%s\n' "${SECRET_KEY}" > "${TMP_SECRET_KEY_FILE}"
    chmod 0600 "${TMP_SECRET_KEY_FILE}"
    sync "${TMP_SECRET_KEY_FILE}"
    mv "${TMP_SECRET_KEY_FILE}" "${SECRET_KEY_FILE}"
    log "Wrote PAPERLESS_SECRET_KEY to ${SECRET_KEY_FILE}"
fi

contenv_set PAPERLESS_SECRET_KEY "${SECRET_KEY}"

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
    # Use APP_HOSTNAME, not HOSTNAME — bash auto-sets $HOSTNAME to
    # the machine's hostname, and shadowing that variable would
    # confuse anyone reading this script later.
    APP_HOSTNAME="${APP_NAME}.${ZONE_DOMAIN}"

    case "${ZONE_DOMAIN}" in
        lvh.me|*.lvh.me|localhost|*.localhost)
            # Dev environment — router runs on a non-standard port,
            # extract it from $OPENHOST_ROUTER_URL and use http.
            ROUTER_PORT=""
            if [ -n "${OPENHOST_ROUTER_URL:-}" ]; then
                ROUTER_PORT=$(printf '%s' "${OPENHOST_ROUTER_URL}" | sed -n 's/.*:\([0-9]*\).*/\1/p')
            fi
            BASE_URL="http://${APP_HOSTNAME}${ROUTER_PORT:+:$ROUTER_PORT}"
            ;;
        *)
            BASE_URL="https://${APP_HOSTNAME}"
            ;;
    esac

    # PAPERLESS_URL is the canonical absolute base URL the frontend
    # uses for redirects, password-reset emails, etc.
    # PAPERLESS_ALLOWED_HOSTS must include the bare hostname (no
    # scheme). PAPERLESS_CSRF_TRUSTED_ORIGINS *must* include scheme.
    # See: https://docs.paperless-ngx.com/configuration/#hosting-and-security
    contenv_set PAPERLESS_URL "${BASE_URL}"
    contenv_set PAPERLESS_ALLOWED_HOSTS "${APP_HOSTNAME},localhost,127.0.0.1"
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

if [ -f "${SENTINEL}" ]; then
    log "Admin already bootstrapped (sentinel ${SENTINEL} exists); skipping"
elif [ -f "${ADMIN_PASSWORD_FILE}" ]; then
    # Defence in depth: if the password file already exists but the
    # sentinel does not, a previous boot crashed *between* writing
    # the password file and writing the sentinel. The DB may or may
    # not contain the operator account at this point. Either way, we
    # do NOT want to overwrite the existing password file with a new
    # random string — paperless's manage_superuser is create-only,
    # so a re-rolled password would NOT update the operator account
    # in the DB and we'd silently lock the operator out. Instead,
    # re-export the existing password to the contenv (so init-superuser
    # can finish creating the account if it didn't on the previous
    # boot) and stamp the sentinel.
    log "Recovering from interrupted previous bootstrap (password file present, sentinel missing)"
    EXISTING_PASSWORD=$(head -1 "${ADMIN_PASSWORD_FILE}")
    if [ -z "${EXISTING_PASSWORD}" ]; then
        log "ERROR: ${ADMIN_PASSWORD_FILE} exists but is empty; aborting bootstrap"
        exit 1
    fi
    contenv_set PAPERLESS_ADMIN_USER "${ADMIN_USER}"
    contenv_set PAPERLESS_ADMIN_PASSWORD "${EXISTING_PASSWORD}"
    touch "${SENTINEL}"
    log "Recovered: re-exported existing admin credentials and stamped sentinel"
else
    log "First boot: generating ${ADMIN_USER} password"

    # We want a stable 32-character ASCII-letter-and-digit password.
    # Naïve base64 of 24 random bytes is exactly 32 chars but contains
    # `+` and `/`, which we strip — and after stripping, the result is
    # typically shorter than 32. Read enough source entropy (96 random
    # bytes -> 128 base64 chars; on average about 122 survive the strip)
    # that the post-strip output is overwhelmingly likely to be at
    # least 32 chars, then `cut -c1-32` gives a stable-length string.
    # We additionally validate the length and refuse to start if
    # something goes wrong (would only happen if /dev/urandom or
    # base64 is broken, but better to fail loudly than silently mint
    # a short-and-weak admin password).
    ADMIN_PASSWORD=$(dd if=/dev/urandom bs=96 count=1 status=none \
        | base64 \
        | tr -d '\n=+/' \
        | cut -c1-32)
    if [ "${#ADMIN_PASSWORD}" -lt 32 ]; then
        log "ERROR: generated password is only ${#ADMIN_PASSWORD} chars (expected 32)"
        exit 1
    fi

    # Write the password file atomically: write to a temp file under
    # the same directory, fsync to disk, then rename into place. This
    # rules out the failure mode where a partial-write password file
    # exists and the sentinel does not — the password file either
    # appears fully-formed under its final name or does not appear
    # at all. We then write the sentinel atomically too (touch is
    # already atomic).
    umask 077
    TMP_PASSWORD_FILE="${ADMIN_PASSWORD_FILE}.tmp"
    printf '%s\n' "${ADMIN_PASSWORD}" > "${TMP_PASSWORD_FILE}"
    chmod 0600 "${TMP_PASSWORD_FILE}"
    # fsync the temp file before the rename, so a crash between the
    # write and the rename never produces a partial password file.
    # On crash before sync completes: no $ADMIN_PASSWORD_FILE at all
    # (the .tmp file may exist but is never read by us), so the next
    # boot takes the first-boot path and writes a fresh password.
    # On crash after rename: $ADMIN_PASSWORD_FILE exists, sentinel
    # absent — the recovery branch above picks up the existing
    # password.
    #
    # We deliberately do NOT silence sync failures with `|| true`:
    # if the kernel reports an I/O error on this file, we want the
    # bootstrap to fail loudly rather than continue to the rename
    # and end up with a password file that is not actually durable.
    # `set -e` is in effect.
    sync "${TMP_PASSWORD_FILE}"
    mv "${TMP_PASSWORD_FILE}" "${ADMIN_PASSWORD_FILE}"

    contenv_set PAPERLESS_ADMIN_USER "${ADMIN_USER}"
    contenv_set PAPERLESS_ADMIN_PASSWORD "${ADMIN_PASSWORD}"

    # Stamp the sentinel last. If we crash here, the password file
    # exists on disk but no sentinel does — the recovery branch
    # above will re-use the existing password on the next boot.
    touch "${SENTINEL}"
    log "Wrote admin credentials to ${ADMIN_PASSWORD_FILE}"
fi

log "Bootstrap complete"
