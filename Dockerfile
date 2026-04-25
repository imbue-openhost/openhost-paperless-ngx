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
#   2. `init-openhost-bootstrap`, a oneshot ordered before any other
#      init (and before `init-complete`). It:
#        * relocates Paperless's data/media/consume/export dirs to
#          $OPENHOST_APP_DATA_DIR via symlinks so all state survives
#          container re-creation;
#        * on first boot only, generates a 24-byte url-safe random
#          password for the `operator` superuser, writes it to
#          $OPENHOST_APP_DATA_DIR/admin-password.txt with mode 0600,
#          and exports PAPERLESS_ADMIN_USER / PAPERLESS_ADMIN_PASSWORD
#          / PAPERLESS_ADMIN_MAIL into the s6 contenv so that the
#          upstream `init-superuser` oneshot (which is idempotent —
#          it only creates the user if it doesn't already exist) does
#          the right thing. A sentinel file
#          `$OPENHOST_APP_DATA_DIR/.admin_bootstrapped` makes this a
#          no-op on subsequent boots, so an operator who later
#          changes the admin password through the Paperless UI will
#          not have it overwritten.
#        * derives PAPERLESS_URL / PAPERLESS_ALLOWED_HOSTS /
#          PAPERLESS_CSRF_TRUSTED_ORIGINS from $OPENHOST_ZONE_DOMAIN
#          so Django accepts requests routed through the OpenHost
#          router (which arrives with a Host header of
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
# `gosu` already exists in the upstream image, so `s6-setuidgid` (used
# elsewhere for dropping to the `paperless` user) keeps working.
RUN set -eux \
    && apt-get update \
    && apt-get install --yes --no-install-recommends redis-server \
    && apt-get clean --yes \
    && rm -rf /var/lib/apt/lists/*

# Make sure the redis user can write to its runtime/data dirs from
# inside our s6 service. The `redis` user (uid 100ish) is created by
# the redis-server postinst. We keep it.
RUN mkdir -p /var/run/redis /var/lib/redis /var/log/redis \
    && chown -R redis:redis /var/run/redis /var/lib/redis /var/log/redis

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
    PAPERLESS_PORT=8000

# Re-declare EXPOSE for clarity (already declared upstream); the
# OpenHost router proxies to this port over loopback inside the pod.
EXPOSE 8000

# ENTRYPOINT ["/init"] is inherited from the upstream image; s6 will
# run our bootstrap before init-complete and start svc-redis alongside
# the existing services.
