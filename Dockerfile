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
# We deliberately do NOT add an auth-proxy sidecar. Paperless's auth
# model is cookie- and CSRF-based and does not trust an upstream
# header (without a separate plugin). An OpenHost SSO sidecar would
# require either patching Paperless's middleware or running an
# additional gate process; until then, the operator logs in with the
# generated `operator` credentials, and the public_paths = ["/"] in
# openhost.toml lets the login form be reached unauthenticated.

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
             /etc/s6-overlay/s6-rc.d/init-openhost-bootstrap/run \
             /usr/local/bin/openhost-bootstrap.sh

# Tell paperless to use SQLite + the bundled local Redis. Operator-
# overridable; if an operator wants to point at an external Postgres
# they can set PAPERLESS_DBENGINE / PAPERLESS_DBHOST / etc. via
# OpenHost's app env machinery and we'll honour it.
ENV PAPERLESS_DBENGINE=sqlite \
    PAPERLESS_REDIS=redis://127.0.0.1:6379 \
    PAPERLESS_OCR_LANGUAGE=eng \
    PAPERLESS_TIME_ZONE=UTC \
    PAPERLESS_TASK_WORKERS=1 \
    PAPERLESS_THREADS_PER_WORKER=1 \
    PAPERLESS_ADMIN_MAIL=operator@localhost \
    PAPERLESS_PORT=8000 \
    # Trust the X-Forwarded-Host / X-Forwarded-Proto headers set by
    # the OpenHost router. Without these, Django's CSRF middleware
    # sees request.scheme == 'http' (the in-pod connection) but the
    # Origin/Referer headers say 'https' (the user-facing scheme),
    # rejects the mismatch, and returns 403 on every POST including
    # the login form. The PAPERLESS_PROXY_SSL_HEADER value is a JSON
    # array that maps to Django's SECURE_PROXY_SSL_HEADER tuple
    # (header name, expected value) — when X-Forwarded-Proto is
    # 'https', Django treats the request as secure.
    PAPERLESS_USE_X_FORWARD_HOST=true \
    PAPERLESS_PROXY_SSL_HEADER='["HTTP_X_FORWARDED_PROTO","https"]'

# Re-declare EXPOSE for clarity (already declared upstream); the
# OpenHost router proxies to this port over loopback inside the pod.
EXPOSE 8000

# ENTRYPOINT ["/init"] is inherited from the upstream image; s6 will
# run our bootstrap before init-complete and start svc-redis alongside
# the existing services.
