# bottled-paperless-ngx

[Paperless-ngx][upstream] document management with OCR, packaged as a single-container Cloud in a Bottle app.

[upstream]: https://github.com/paperless-ngx/paperless-ngx

## What you get

A self-hosted document archive: drop PDFs (or scans, photos, office files) into the consume folder or upload through the web UI, paperless OCRs them with Tesseract, extracts metadata, and lets you tag, search, and download. See [docs.paperless-ngx.com](https://docs.paperless-ngx.com/) for full feature docs.

This packaging targets a small personal archive (a few thousand documents). Heavy-throughput multi-user deployments should use the [upstream docker-compose stack](https://github.com/paperless-ngx/paperless-ngx#docker) with external Postgres + Redis instead.

## Single-container approach

Upstream Paperless ships as a docker-compose stack of 4–6 services (paperless app, Redis, optionally Postgres, Tika, Gotenberg). Cloud in a Bottle runs one image per app, so this repo bundles the minimum necessary stack into a single container:

| Service                         | How it's run                                                       |
|---------------------------------|--------------------------------------------------------------------|
| Paperless web (Granian + Django) | upstream s6 longrun `svc-webserver` (bound to `127.0.0.1:8000`)   |
| Celery worker (OCR/ingest)      | upstream s6 longrun `svc-worker`                                   |
| Celery beat (scheduler)         | upstream s6 longrun `svc-scheduler`                                |
| Document consumer (inotify)     | upstream s6 longrun `svc-consumer`                                 |
| Redis (Celery broker)           | **bundled** s6 longrun `svc-redis` on `127.0.0.1:6379`             |
| Cloud in a Bottle SSO auth-proxy         | **bundled** s6 longrun `svc-auth-proxy` on `0.0.0.0:8080`          |
| Database                        | **SQLite** at `$OPENHOST_APP_DATA_DIR/data/db.sqlite3`             |

Optional sidecars from the upstream compose (Tika for office docs, Gotenberg for HTML/email) are *not* included to keep the image small. The image already supports OCR for PDFs, images, and plain text — the bulk of personal-archive use cases.

## Persistent state layout

Everything writeable lives under `$OPENHOST_APP_DATA_DIR` (mounted because `app_data = true` in the manifest):

```
$OPENHOST_APP_DATA_DIR/
├── data/                  # SQLite DB, search index (Whoosh), classifier model
├── media/                 # Original PDFs + thumbnails (the bulk of disk use)
├── consume/               # Drop-zone for new docs (paperless watches via inotify)
├── admin-password.txt     # Generated on first boot, mode 0600
└── .admin_bootstrapped    # Sentinel — presence skips admin re-creation
```

The Cloud in a Bottle backup system covers this whole tree.

The bootstrap wires Paperless to these locations by setting `PAPERLESS_DATA_DIR`, `PAPERLESS_MEDIA_ROOT`, and `PAPERLESS_CONSUMPTION_DIR` at runtime; the upstream `/usr/src/paperless/{data,media,consume,export}` paths (declared as `VOLUME` by the upstream image) are left as anonymous volumes and unused. Export staging continues to live in the anonymous volume since Paperless doesn't expose an env override for it; that's fine because export output is throwaway data the operator copies elsewhere.

## Logging in

On first boot the bootstrap script generates a random 32-character password for the `operator` superuser and writes it to `$OPENHOST_APP_DATA_DIR/admin-password.txt`. To retrieve it from the host, ssh into the Cloud in a Bottle VM and `cat ~/.openhost/local_compute_space/persistent_data/app_data/paperless-ngx/admin-password.txt` (the exact path varies with your Cloud in a Bottle installation; the dashboard's "App data" link points at the right directory).

If you run the image outside Cloud in a Bottle (e.g. `docker run` for testing) without setting `OPENHOST_APP_DATA_DIR`, the bootstrap falls back to `/data/admin-password.txt` inside the container, so mount a volume there to retrieve the password.

You can change the password through Paperless's UI (Settings → Users → operator) afterwards. The bootstrap will not overwrite it on later boots — it's gated by the `.admin_bootstrapped` sentinel.

If you ever lose the password, the simplest recovery is to reset it through Paperless's own management command. Connect to the host's terminal and:

```bash
# From the OpenHost host (replace the container ID with the running paperless-ngx container's):
podman exec -it $(podman ps --filter name=paperless-ngx --format '{{.ID}}') \
    python3 /usr/src/paperless/src/manage.py changepassword operator
```

The command will prompt twice for a new password and update the database in place. (Note: re-running our bootstrap by deleting the sentinel will *not* reset an existing user's password — paperless's `manage_superuser` is create-only by design and skips the user if the username already exists. Our sentinel only suppresses re-entering the env vars on later boots; it does not authoritatively manage the database state.)

## Authentication and SSO

This packaging integrates with Cloud in a Bottle's zone-wide SSO via **Pattern A — trusted-header injection** (the same pattern used by `bottled-mediawiki` and `bottled-dokuwiki`).

How it works:

1. The Cloud in a Bottle router verifies the visitor's `zone_auth` JWT and stamps `X-OpenHost-Is-Owner: true` on owner requests before they reach the container.
2. A small Python auth-proxy sidecar (`svc-auth-proxy`) listens on the Cloud in a Bottle-routed port (`8080`), strips any client-supplied `Remote-User` / `X-OpenHost-*` headers (defense in depth), and on owner requests forwards `Remote-User: operator` to paperless on `127.0.0.1:8000`.
3. Paperless's `PAPERLESS_ENABLE_HTTP_REMOTE_USER=true` reads `HTTP_REMOTE_USER` from the WSGI environment (Django sources this from the request header `Remote-User`) and treats the named user as authenticated, auto-creating the account on first sight if missing. The bootstrap ensures the `operator` superuser already exists.

The result: the Cloud in a Bottle owner clicks paperless's tile in the dashboard, the auth-proxy stamps the trusted header, and they land directly on paperless's document list — no login form.

`PAPERLESS_ENABLE_HTTP_REMOTE_USER_API=true` extends the same trust to `/api/*` so the paperless mobile/desktop apps work behind the Cloud in a Bottle router too (same JWT-gated routing applies).

### Security

Pattern A is only as secure as the proxy in front of it. We strip every variant of the trust header on every inbound request, regardless of source, before any other processing. Anyone bypassing the Cloud in a Bottle router and reaching the container directly would still be unable to inject a `Remote-User` header without first compromising the auth-proxy itself.

**`/admin/` is exempt** from header stamping. Django's built-in admin uses session auth (it doesn't honour `REMOTE_USER`), so stamping there would surface a logged-out form anyway. The `operator` password persisted to `$OPENHOST_APP_DATA_DIR/admin-password.txt` lets you reach `/admin/` if you ever need it.

### Break-glass

If for some reason the auth-proxy refuses to log you in (header stripped, malformed JWT, paperless DB out of sync), you can still reach paperless's native login form at `/accounts/login/` via the auth-proxy and sign in manually with the `operator` password from `admin-password.txt`. Paperless's `PAPERLESS_ENABLE_HTTP_REMOTE_USER` adds REMOTE_USER as an authentication backend without removing the username/password backend.

## Configuration

All [Paperless env vars](https://docs.paperless-ngx.com/configuration/) work as documented upstream. Defaults set by this image:

| Var                              | Default                                          | Notes                                            |
|----------------------------------|--------------------------------------------------|--------------------------------------------------|
| `PAPERLESS_DBENGINE`             | `sqlite`                                         | Override to `postgresql` if pointing at external DB |
| `PAPERLESS_REDIS`                | `redis://127.0.0.1:6379`                         | The bundled Redis                                |
| `PAPERLESS_OCR_LANGUAGE`         | `eng`                                            | Add more with `eng+deu` etc; the upstream image bundles English/German/French/Italian/Spanish |
| `PAPERLESS_TIME_ZONE`            | `UTC`                                            | Set to your local IANA TZ for correct timestamps |
| `PAPERLESS_TASK_WORKERS`         | `1`                                              | Number of celery worker processes; raise alongside `cpu_millicores` |
| `PAPERLESS_THREADS_PER_WORKER`   | `1`                                              | OCR threads per worker                           |
| `PAPERLESS_ADMIN_MAIL`           | `operator@localhost`                             | Email for the auto-created `operator` superuser  |
| `PAPERLESS_PORT`                 | `8000`                                           | Granian loopback port (auth-proxy forwards here) |
| `PAPERLESS_BIND_ADDR`            | `127.0.0.1`                                      | Paperless listens on loopback only; auth-proxy on 8080 is the only external port |
| `PAPERLESS_USE_X_FORWARD_HOST`   | `true`                                           | Trust `X-Forwarded-Host` from the Cloud in a Bottle router |
| `PAPERLESS_PROXY_SSL_HEADER`     | `["HTTP_X_FORWARDED_PROTO","https"]`             | Tell Django the request was HTTPS so CSRF passes |
| `PAPERLESS_ENABLE_HTTP_REMOTE_USER` | `true`                                        | Trust `Remote-User` header from the auth-proxy (Pattern A SSO) |
| `PAPERLESS_ENABLE_HTTP_REMOTE_USER_API` | `true`                                    | Same trust for `/api/*` (mobile/desktop apps) |
| `PAPERLESS_HTTP_REMOTE_USER_HEADER_NAME` | `HTTP_REMOTE_USER`                       | WSGI form of `Remote-User` request header        |

`PAPERLESS_URL`, `PAPERLESS_ALLOWED_HOSTS`, and `PAPERLESS_CSRF_TRUSTED_ORIGINS` are derived automatically from `$OPENHOST_ZONE_DOMAIN` at boot.

## Caveats

- **First-boot is slow.** Paperless runs Django migrations, builds the Whoosh index, downloads NLTK data (already baked into the image), and provisions the admin user before the webserver starts. Expect 60–120 s before `/` returns 200, sometimes longer on a small VM. The Cloud in a Bottle deploy poll loop should account for this.
- **OCR is CPU-heavy.** A single 20-page scanned PDF can pin 1 core for 30+ seconds. The manifest reserves 1 core (`cpu_millicores = 1000`); if you have a fast multi-core host, raising both the manifest reservation and `PAPERLESS_TASK_WORKERS` / `PAPERLESS_THREADS_PER_WORKER` will speed up bulk imports.
- **RAM footprint is ~600 MiB idle.** Granian + four celery processes + Redis. Consumes more during indexing. The 1 GiB manifest reservation is comfortable for personal use.
- **No PostgreSQL/Tika/Gotenberg.** SQLite is fine up to a few thousand docs; office-format ingestion (.docx, .xlsx, .eml) won't work without Tika. If you need those, add the upstream services as sidecars or run upstream's docker-compose stack on a non-Cloud in a Bottle host.

## Layout of this repo

```
openhost.toml                                                       # OpenHost manifest (port=8080 → auth-proxy)
Dockerfile                                                          # Builds on ghcr.io/paperless-ngx/paperless-ngx:latest
rootfs/                                                             # COPY'd into the image
├── etc/s6-overlay/s6-rc.d/svc-redis/                               # Redis longrun service
├── etc/s6-overlay/s6-rc.d/svc-auth-proxy/                          # OpenHost SSO auth-proxy longrun (Pattern A trusted-header)
├── etc/s6-overlay/s6-rc.d/init-openhost-bootstrap/                 # Per-boot bootstrap (point data dirs at OPENHOST_APP_DATA_DIR via PAPERLESS_*_DIR env vars, mint admin password, set Django host config, enable HTTP_REMOTE_USER auth)
├── etc/s6-overlay/s6-rc.d/init-folders/dependencies.d/init-openhost-bootstrap   # Order bootstrap before paperless dir-prep so PAPERLESS_DATA_DIR is set when init-folders mkdirs
├── etc/s6-overlay/s6-rc.d/init-wait-for-redis/dependencies.d/svc-redis          # Make paperless's Redis-readiness wait for ours to come up
├── etc/s6-overlay/s6-rc.d/user/contents.d/svc-redis                # Enable in default bundle
├── etc/s6-overlay/s6-rc.d/user/contents.d/svc-auth-proxy           # Enable auth-proxy in default bundle
├── etc/s6-overlay/s6-rc.d/user/contents.d/init-openhost-bootstrap  # Enable in default bundle
├── usr/local/bin/openhost-bootstrap.sh                             # Bootstrap implementation
└── usr/local/bin/auth_proxy.py                                     # Pattern A auth-proxy (HTTP forwarder + Remote-User stamping)
```
