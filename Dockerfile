# Paperless-ngx — single-container OpenHost packaging.
#
# Strategy
# --------
# The upstream image (ghcr.io/paperless-ngx/paperless-ngx) is *already*
# built on s6-overlay v3 with longruns for the webserver, two celery
# workers, the scheduler, and the consume watcher, plus oneshot inits
# (init-folders, init-migrations, init-superuser, init-search-index, …)
# wired into the `init-complete` bundle.
#
# We do not rebuild any of that. We layer two extras on top:
#
#   1. `redis-server` (Debian package) plus an s6 longrun service
#      `svc-redis` that runs it on 127.0.0.1:6379. Paperless's existing
#      `init-wait-for-redis` will then succeed against our local Redis
#      and the rest of the app will start as it does in the standard
#      docker-compose deployment.
#
#   2. `init-openhost-bootstrap`, a oneshot ordered before
#      `init-folders` and (transitively) before everything else. It:
#        * sets PAPERLESS_DATA_DIR / PAPERLESS_MEDIA_ROOT /
#          PAPERLESS_CONSUMPTION_DIR in the s6 container_environment
#          to point at $OPENHOST_APP_DATA_DIR/{data,media,consume}
#          so all persistent state lives in OpenHost's backed-up
#          storage. (We can't symlink /usr/src/paperless/{data,...}
#          because the upstream Dockerfile declares those paths as
#          VOLUMEs and they become live mountpoints in the running
#          container.)
#        * on first boot only, generates a 32-character random
#          password for the `operator` superuser (sourced from
#          /dev/urandom and stripped of base64 padding/special chars
#          to keep it ASCII-alphanumeric for easy copy/paste),
#          writes it to
#          $OPENHOST_APP_DATA_DIR/admin-password.txt with mode 0600,
#          and exports PAPERLESS_ADMIN_USER / PAPERLESS_ADMIN_PASSWORD
#          into the contenv so the upstream `init-superuser` oneshot
#          (idempotent: only creates the user if it doesn't already
#          exist) creates the account. A sentinel
#          `$OPENHOST_APP_DATA_DIR/.admin_bootstrapped` makes this a
#          no-op on subsequent boots, so an operator who later
#          changes the password through the Paperless UI does not
#          have it overwritten.
#        * derives PAPERLESS_URL / PAPERLESS_ALLOWED_HOSTS /
#          PAPERLESS_CSRF_TRUSTED_ORIGINS from $OPENHOST_ZONE_DOMAIN
#          so Django accepts requests routed through the OpenHost
#          router (which arrive with a Host header of
#          paperless-ngx.<zone>).
#
# OpenHost SSO via Pattern A (trusted-header injection).
# ------------------------------------------------------
# A small auth-proxy sidecar (`svc-auth-proxy`) listens on the
# OpenHost-routed port 8080, forwards to paperless on 127.0.0.1:8000,
# and stamps `Remote-User: operator` on owner requests (those that
# arrived with `X-OpenHost-Is-Owner: true` from the OpenHost router).
# Paperless's `PAPERLESS_ENABLE_HTTP_REMOTE_USER=true` reads
# HTTP_REMOTE_USER from the WSGI env and treats the named user as
# authenticated, auto-creating the account on first sight. The
# bootstrap ensures the `operator` superuser exists before the
# webserver starts.
#
# Security: the proxy strips client-supplied `Remote-User` /
# `X-OpenHost-*` headers before processing, so the trusted-header
# auth is only as trustworthy as the proxy itself. The OpenHost
# router also strips these inbound; this is defense in depth.
#
# /admin/ is exempt from header stamping (Django built-in admin uses
# session auth, not REMOTE_USER); the operator falls back to the
# admin password persisted to $OPENHOST_APP_DATA_DIR/admin-password.txt.

FROM ghcr.io/paperless-ngx/paperless-ngx:latest

ARG DEBIAN_FRONTEND=noninteractive

# redis-server for the bundled Redis sidecar. We pin --no-install-recommends
# to avoid pulling redis-tools / redis-sentinel which we don't use.
# We don't drop to the `redis` user inside the container — the whole
# container runs under rootless podman, so "root" is already an
# unprivileged userns-mapped uid on the host.
RUN set -eux \
    && apt-get update \
    && apt-get install --yes --no-install-recommends redis-server \
    && apt-get clean --yes \
    && rm -rf /var/lib/apt/lists/*

# Drop in our Redis service + OpenHost bootstrap oneshot.
#
# Layout under rootfs/:
#   etc/s6-overlay/s6-rc.d/svc-redis/             — longrun
#   etc/s6-overlay/s6-rc.d/init-openhost-bootstrap/ — oneshot, runs first
#   etc/s6-overlay/s6-rc.d/user/contents.d/svc-redis        — enable longrun
#   etc/s6-overlay/s6-rc.d/init-wait-for-redis/dependencies.d/svc-redis  — wait_for_redis depends on svc-redis
#   etc/s6-overlay/s6-rc.d/init-folders/dependencies.d/init-openhost-bootstrap
#       — every init that touches dirs (folders, migrations, ...) waits
#         for our bootstrap, which has already moved the dirs aside.
COPY rootfs/ /

# Make our scripts executable. (`COPY` preserves the +x bit if the file
# was executable on the host, but we belt-and-braces it here so a
# checkout on a vfat mount or via a Windows host doesn't silently break
# the build.)
RUN chmod +x /etc/s6-overlay/s6-rc.d/svc-redis/run \
             /etc/s6-overlay/s6-rc.d/svc-auth-proxy/run \
             /etc/s6-overlay/s6-rc.d/init-openhost-bootstrap/run \
             /usr/local/bin/openhost-bootstrap.sh \
             /usr/local/bin/auth_proxy.py

# Tell paperless to use SQLite + the bundled local Redis. Operator-
# overridable; if an operator wants to point at an external Postgres
# they can set PAPERLESS_DBENGINE / PAPERLESS_DBHOST / etc. via
# OpenHost's app env machinery and we'll honour it.
# Trust the X-Forwarded-Host / X-Forwarded-Proto headers set by the
# OpenHost router (Caddy). Without these, Django's CSRF middleware
# sees request.scheme == 'http' (the in-pod TCP connection from
# Caddy to our container) but the Origin/Referer headers say 'https'
# (the user-facing scheme that survived TLS termination), rejects
# the mismatch, and returns 403 on every POST including the login
# form. PAPERLESS_PROXY_SSL_HEADER is a JSON array that maps to
# Django's SECURE_PROXY_SSL_HEADER tuple (header name, expected
# value) — when X-Forwarded-Proto is 'https', Django treats the
# request as secure.
ENV PAPERLESS_DBENGINE=sqlite \
    PAPERLESS_REDIS=redis://127.0.0.1:6379 \
    PAPERLESS_OCR_LANGUAGE=eng \
    PAPERLESS_TIME_ZONE=UTC \
    PAPERLESS_TASK_WORKERS=1 \
    PAPERLESS_THREADS_PER_WORKER=1 \
    PAPERLESS_ADMIN_MAIL=operator@localhost \
    PAPERLESS_PORT=8000 \
    PAPERLESS_BIND_ADDR=127.0.0.1 \
    PAPERLESS_USE_X_FORWARD_HOST=true \
    PAPERLESS_PROXY_SSL_HEADER='["HTTP_X_FORWARDED_PROTO","https"]'

# Auth-proxy listens on 8080 (the OpenHost-routed port from the
# manifest). Paperless listens on 127.0.0.1:8000 internally; the
# proxy is the only thing reachable from outside the container.
EXPOSE 8080

# ENTRYPOINT ["/init"] is inherited from the upstream image; s6 will
# run our bootstrap before init-complete and start svc-redis alongside
# the existing services.
