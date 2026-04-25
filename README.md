# openhost-paperless-ngx

[Paperless-ngx][upstream] document management with OCR, packaged as a single-container OpenHost app.

[upstream]: https://github.com/paperless-ngx/paperless-ngx

## What you get

A self-hosted document archive: drop PDFs (or scans, photos, office files) into the consume folder or upload through the web UI, paperless OCRs them with Tesseract, extracts metadata, and lets you tag, search, and download. See [docs.paperless-ngx.com](https://docs.paperless-ngx.com/) for full feature docs.

This packaging targets a small personal archive (a few thousand documents). Heavy-throughput multi-user deployments should use the [upstream docker-compose stack](https://github.com/paperless-ngx/paperless-ngx#docker) with external Postgres + Redis instead.

## Single-container approach

Upstream Paperless ships as a docker-compose stack of 4–6 services (paperless app, Redis, optionally Postgres, Tika, Gotenberg). OpenHost runs one image per app, so this repo bundles the minimum necessary stack into a single container:

| Service                         | How it's run                                                       |
|---------------------------------|--------------------------------------------------------------------|
| Paperless web (Granian + Django) | upstream s6 longrun `svc-webserver`                                |
| Celery worker (OCR/ingest)      | upstream s6 longrun `svc-worker`                                   |
| Celery beat (scheduler)         | upstream s6 longrun `svc-scheduler`                                |
| Document consumer (inotify)     | upstream s6 longrun `svc-consumer`                                 |
| Redis (Celery broker)           | **bundled** s6 longrun `svc-redis` on `127.0.0.1:6379`             |
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

The OpenHost backup system covers this whole tree.

The bootstrap wires Paperless to these locations by setting `PAPERLESS_DATA_DIR`, `PAPERLESS_MEDIA_ROOT`, and `PAPERLESS_CONSUMPTION_DIR` at runtime; the upstream `/usr/src/paperless/{data,media,consume,export}` paths (declared as `VOLUME` by the upstream image) are left as anonymous volumes and unused. Export staging continues to live in the anonymous volume since Paperless doesn't expose an env override for it; that's fine because export output is throwaway data the operator copies elsewhere.

## Logging in

On first boot the bootstrap script generates a random 32-character password for the `operator` superuser and writes it to `$OPENHOST_APP_DATA_DIR/admin-password.txt`. To retrieve it from the host, ssh into the OpenHost VM and `cat /data/app_data/paperless-ngx/admin-password.txt` (the path may differ if your OpenHost data root has been remapped).

You can change the password through Paperless's UI (Settings → Users → operator) afterwards. The bootstrap will not overwrite it on later boots — it's gated by the `.admin_bootstrapped` sentinel.

If you ever lose the password, delete the sentinel + password file and reload the app:

```bash
oh app reload paperless-ngx
```

A new random password will be generated and the existing user's password updated to match (paperless's `manage_superuser` updates passwords for existing users).

## Authentication and SSO

This packaging does **not** integrate with OpenHost's zone-wide SSO. Paperless's auth model is cookie- and CSRF-based and does not natively trust an upstream `X-Openhost-User` header — wiring it in would require either patching paperless's middleware or running a custom proxy that fakes a Django session. As a result:

- `public_paths = ["/"]` in the manifest exposes the whole app over HTTPS (TLS terminated by the OpenHost router).
- Anyone with the URL can reach the login form, but cannot do anything without the `operator` password.
- Paperless's own user system (Settings → Users) is the source of truth for authentication.

Future work: write a small auth-proxy sidecar (à la openhost-forgejo) that sets a Django session cookie when the OpenHost owner JWT is present.

## Configuration

All [Paperless env vars](https://docs.paperless-ngx.com/configuration/) work as documented upstream. Defaults set by this image:

| Var                      | Default                          | Notes                                            |
|--------------------------|----------------------------------|--------------------------------------------------|
| `PAPERLESS_DBENGINE`     | `sqlite`                         | Override to `postgresql` if pointing at external DB |
| `PAPERLESS_REDIS`        | `redis://127.0.0.1:6379`         | The bundled Redis                                |
| `PAPERLESS_OCR_LANGUAGE` | `eng`                            | Add more with `eng+deu` etc; the upstream image bundles English/German/French/Italian/Spanish |
| `PAPERLESS_TIME_ZONE`    | `UTC`                            | Set to your local IANA TZ for correct timestamps |
| `PAPERLESS_TASK_WORKERS` | `1`                              | Bumping needs a corresponding `cpu_millicores` increase |

`PAPERLESS_URL`, `PAPERLESS_ALLOWED_HOSTS`, and `PAPERLESS_CSRF_TRUSTED_ORIGINS` are derived automatically from `$OPENHOST_ZONE_DOMAIN` at boot.

## Caveats

- **First-boot is slow.** Paperless runs Django migrations, builds the Whoosh index, downloads NLTK data (already baked into the image), and provisions the admin user before the webserver starts. Expect 60–120 s before `/` returns 200, sometimes longer on a small VM. The OpenHost deploy poll loop should account for this.
- **OCR is CPU-heavy.** A single 20-page scanned PDF can pin 1 core for 30+ seconds. The manifest reserves 1 core (`cpu_millicores = 1000`); if you have a fast multi-core host, raising both the manifest reservation and `PAPERLESS_TASK_WORKERS` / `PAPERLESS_THREADS_PER_WORKER` will speed up bulk imports.
- **RAM footprint is ~600 MiB idle.** Granian + four celery processes + Redis. Consumes more during indexing. The 1 GiB manifest reservation is comfortable for personal use.
- **No PostgreSQL/Tika/Gotenberg.** SQLite is fine up to a few thousand docs; office-format ingestion (.docx, .xlsx, .eml) won't work without Tika. If you need those, add the upstream services as sidecars or run upstream's docker-compose stack on a non-OpenHost host.

## Layout of this repo

```
openhost.toml                                                       # OpenHost manifest
Dockerfile                                                          # Builds on ghcr.io/paperless-ngx/paperless-ngx:latest
rootfs/                                                             # COPY'd into the image
├── etc/s6-overlay/s6-rc.d/svc-redis/                               # Redis longrun service
├── etc/s6-overlay/s6-rc.d/init-openhost-bootstrap/                 # Per-boot bootstrap (point data dirs at OPENHOST_APP_DATA_DIR via PAPERLESS_*_DIR env vars, mint admin password, set Django host config)
├── etc/s6-overlay/s6-rc.d/init-folders/dependencies.d/init-openhost-bootstrap   # Order bootstrap before paperless dir-prep so PAPERLESS_DATA_DIR is set when init-folders mkdirs
├── etc/s6-overlay/s6-rc.d/init-wait-for-redis/dependencies.d/svc-redis          # Make paperless's Redis-readiness wait for ours to come up
├── etc/s6-overlay/s6-rc.d/user/contents.d/svc-redis                # Enable in default bundle
├── etc/s6-overlay/s6-rc.d/user/contents.d/init-openhost-bootstrap  # Enable in default bundle
└── usr/local/bin/openhost-bootstrap.sh                             # Bootstrap implementation
```
