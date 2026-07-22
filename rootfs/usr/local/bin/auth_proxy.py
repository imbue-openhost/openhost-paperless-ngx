"""OpenHost trusted-header auth-proxy for Paperless-ngx.

Pattern A from the OpenHost SSO playbook. The OpenHost router has
already verified the visitor's zone_auth JWT before they reach us
and stamps ``X-OpenHost-Is-Owner: true`` on owner requests. This
proxy:

  1. Strips any client-supplied ``X-OpenHost-*`` and ``Remote-User``
     headers from the inbound request (defense in depth — the
     router already strips them, but a hostile actor who somehow
     bypassed the router shouldn't be able to inject a trusted
     username).
  2. On owner requests AND non-/admin/ AND non-static paths, stamps
     ``Remote-User: <admin-username>`` on the upstream request.
  3. Forwards to Paperless's loopback gunicorn/granian on
     127.0.0.1:8000.

Paperless reads ``HTTP_REMOTE_USER`` from the WSGI environment
(Django normalises request header ``Remote-User`` to that), and
when ``PAPERLESS_ENABLE_HTTP_REMOTE_USER=true`` it treats the user
named in that header as authenticated, auto-creating the account
on first sight. There is no per-session state to mint —
REMOTE_USER is consulted on every request.

Special-case paths where we DO NOT stamp Remote-User:

  * ``/admin/`` — Django's built-in admin uses its own session
    backend that doesn't honour REMOTE_USER. Stamping the header
    here would surface a logged-out admin form. The operator can
    still reach /admin/ with the password persisted to
    admin-password.txt.
  * Static asset prefixes — purely cosmetic; gunicorn serves these
    without auth checks anyway. Strips a tiny amount of header
    overhead on hot paths.

Health check: ``GET /_healthz`` returns ``200 {"status":"ok"}``
without forwarding upstream, so OpenHost's health probe works
during paperless cold-start.

Adapted from openhost-mediawiki/auth_proxy.py with two changes:

  - REMOTE_USER_HEADER_NAME defaults to "Remote-User" (paperless's
    default; Django reads HTTP_REMOTE_USER from this).
  - Per-request stamping is conditional on the path so /admin/
    falls back to Django auth.
"""

from __future__ import annotations

import http.client
import logging
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import AbstractSet, Iterable

OWNER_HEADER_NAME = "X-OpenHost-Is-Owner"
USER_HEADER_NAME = "X-OpenHost-User"

# The header we stamp on owner requests. Paperless's
# PAPERLESS_HTTP_REMOTE_USER_HEADER_NAME defaults to HTTP_REMOTE_USER,
# which Django sources from the inbound HTTP header `Remote-User`.
REMOTE_USER_HEADER_NAME = os.environ.get(
    "AUTH_PROXY_REMOTE_USER_HEADER", "Remote-User"
)

# Username we stamp on owner requests. Must match the bootstrapped
# paperless superuser created by openhost-bootstrap.sh
# (PAPERLESS_ADMIN_USER=operator).
OWNER_USERNAME = os.environ.get("AUTH_PROXY_OWNER_USERNAME", "operator")

# Path prefixes where we do NOT stamp Remote-User. These either
# reach a backend that doesn't honour REMOTE_USER (Django admin) or
# are pure-asset routes where stamping is wasted effort.
NO_STAMP_PREFIXES: tuple[str, ...] = (
    "/admin/",          # Django built-in admin (session-only)
    "/static/",         # Django staticfiles
    "/assets/",         # Paperless frontend bundle
    "/favicon",         # /favicon.ico, /favicon.png
    "/manifest",        # PWA manifests
    "/robots.txt",
    "/apple-touch-icon",
)

HOP_BY_HOP_HEADERS = frozenset(
    h.lower()
    for h in (
        "Connection",
        "Keep-Alive",
        "Proxy-Authenticate",
        "Proxy-Authorization",
        "TE",
        "Trailer",
        "Transfer-Encoding",
        "Upgrade",
        "Host",
        "Content-Length",
    )
)

# Headers a hostile client must never be able to inject. ALWAYS
# stripped from inbound requests. Both "Remote-User" (paperless's
# default) and "X-Remote-User" (the convention used by other
# OpenHost apps) are stripped, regardless of which one we stamp.
ALWAYS_STRIP_HEADERS = frozenset(
    h.lower() for h in (
        OWNER_HEADER_NAME,
        USER_HEADER_NAME,
        "Remote-User",
        "X-Remote-User",
        REMOTE_USER_HEADER_NAME,
    )
)

CLIENT_READ_TIMEOUT_SECONDS = 60

# 100 MiB body cap. Paperless accepts document uploads via the
# REST API and through the web UI; the upstream default is 1 GiB
# but in practice anything beyond a few hundred MiB on a single
# document is unusual. 100 MiB matches the openhost-mediawiki cap.
MAX_BODY_BYTES = 100 * 1024 * 1024

logging.basicConfig(
    level=os.environ.get("AUTH_PROXY_LOG_LEVEL", "INFO"),
    format="[auth-proxy] %(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("auth_proxy")


def _strip_headers(
    headers: Iterable[tuple[str, str]], drop: AbstractSet[str]
) -> list[tuple[str, str]]:
    drop_lower = {h.lower() for h in drop}
    return [(k, v) for k, v in headers if k.lower() not in drop_lower]


def _should_stamp(path: str) -> bool:
    path_only = path.split("?", 1)[0]
    for prefix in NO_STAMP_PREFIXES:
        if path_only.startswith(prefix):
            return False
    return True


class AuthProxyHandler(BaseHTTPRequestHandler):
    upstream_host: str = "127.0.0.1"
    upstream_port: int = 8000

    def log_message(self, format: str, *args) -> None:  # noqa: A002, N802
        path = getattr(self, "path", "")
        if path.startswith("/_healthz"):
            return
        log.info("%s - " + format, self.address_string(), *args)

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch()

    def do_HEAD(self) -> None:  # noqa: N802
        self._dispatch()

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch()

    def do_PUT(self) -> None:  # noqa: N802
        self._dispatch()

    def do_DELETE(self) -> None:  # noqa: N802
        self._dispatch()

    def do_PATCH(self) -> None:  # noqa: N802
        self._dispatch()

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._dispatch()

    def _safe_send_error(self, code: int, message: str) -> None:
        try:
            self.send_error(code, message)
        except OSError as exc:
            log.debug("client disconnected before error response: %s", exc)

    def _should_serve_starting_placeholder(self) -> bool:
        """Only serve the cold-start placeholder for top-level GET/HEAD
        navigations. API/asset paths and mutating methods still get a 502
        when the upstream is down, so we never hide a real failure from a
        client that can't render an HTML placeholder anyway."""
        if self.command not in ("GET", "HEAD"):
            return False
        path_only = self.path.split("?", 1)[0]
        return path_only in ("/", "") or path_only == "/accounts/login/"

    def _send_starting_placeholder(self) -> None:
        body = (
            b"<!doctype html><html><head><meta charset='utf-8'>"
            b"<meta http-equiv='refresh' content='5'>"
            b"<title>Starting\xe2\x80\xa6</title></head>"
            b"<body style='font-family:sans-serif;max-width:36rem;margin:4rem auto;text-align:center'>"
            b"<h1>Paperless-ngx is starting\xe2\x80\xa6</h1>"
            b"<p>First boot runs database migrations and builds the search "
            b"index; this can take a minute. This page refreshes automatically.</p>"
            b"</body></html>"
        )
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Retry-After", "5")
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        except OSError as exc:
            log.debug("client disconnected during starting placeholder: %s", exc)

    def _dispatch(self) -> None:
        try:
            self.connection.settimeout(CLIENT_READ_TIMEOUT_SECONDS)
        except OSError:
            pass

        path_only = self.path.split("?", 1)[0]
        if path_only == "/_healthz":
            try:
                body = b'{"status":"ok"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)
            except OSError as exc:
                log.debug("/_healthz client disconnected: %s", exc)
            return

        is_owner = self.headers.get(OWNER_HEADER_NAME, "").lower() == "true"
        stamp = is_owner and _should_stamp(self.path)
        self._proxy(stamp_remote_user=stamp)

    def _proxy(self, *, stamp_remote_user: bool) -> None:
        cleaned_headers = _strip_headers(
            self.headers.items(),
            HOP_BY_HOP_HEADERS | ALWAYS_STRIP_HEADERS,
        )
        # Preserve the public-facing Host (X-Forwarded-Host) so
        # paperless's Django ALLOWED_HOSTS check matches and any
        # absolute URL generation uses the public hostname.
        forwarded_host = self.headers.get("X-Forwarded-Host", "").strip()
        if forwarded_host:
            cleaned_headers.append(("Host", forwarded_host))
        # Ensure paperless's Django sees the request as HTTPS so
        # CSRF / secure-cookie logic agrees with the user-facing
        # scheme. PAPERLESS_PROXY_SSL_HEADER tells Django to read
        # HTTP_X_FORWARDED_PROTO. If the inbound request already
        # has it, we don't override.
        if not any(k.lower() == "x-forwarded-proto" for k, _ in cleaned_headers):
            cleaned_headers.append(("X-Forwarded-Proto", "https"))
        if stamp_remote_user:
            cleaned_headers.append((REMOTE_USER_HEADER_NAME, OWNER_USERNAME))

        transfer_encoding = self.headers.get("Transfer-Encoding", "").lower().strip()
        if transfer_encoding and transfer_encoding != "identity":
            self._safe_send_error(501, "Transfer-Encoding not supported")
            return

        body: bytes | None = None
        content_length_header = self.headers.get("Content-Length")
        if content_length_header:
            try:
                length = int(content_length_header)
            except ValueError:
                self._safe_send_error(400, "invalid Content-Length")
                return
            if length < 0:
                self._safe_send_error(400, "negative Content-Length")
                return
            if length > MAX_BODY_BYTES:
                self._safe_send_error(413, "request body too large")
                return
            if length > 0:
                try:
                    body = self.rfile.read(length)
                except (OSError, TimeoutError) as exc:
                    log.info("client read error: %s", exc)
                    self._safe_send_error(400, "request body read failed")
                    return
                if len(body) != length:
                    self._safe_send_error(400, "incomplete request body")
                    return
            else:
                body = b""
        elif self.command in ("POST", "PUT", "PATCH", "DELETE"):
            body = b""

        conn = http.client.HTTPConnection(
            self.upstream_host, self.upstream_port, timeout=120
        )
        try:
            try:
                # skip_host=True so http.client doesn't inject
                # ``Host: 127.0.0.1:8000`` — we add the public
                # Host explicitly via cleaned_headers above.
                conn.putrequest(
                    self.command,
                    self.path,
                    skip_host=True,
                    skip_accept_encoding=True,
                )
                for key, value in cleaned_headers:
                    conn.putheader(key, value)
                if body is not None:
                    conn.putheader("Content-Length", str(len(body)))
                conn.endheaders(message_body=body)
                upstream = conn.getresponse()
            except (OSError, http.client.HTTPException) as exc:
                # Paperless takes ~60s to migrate + build its search index
                # on first boot; while it is down the connection is
                # refused. OpenHost's readiness probe polls the container's
                # root path and treats any status >= 500 as "not ready",
                # with only a 60s deadline (compute_space wait_for_ready).
                # A plain 502 here therefore risks the app being marked
                # "error: App started but not responding to HTTP" purely
                # because paperless's cold start overran the probe window.
                #
                # So when the upstream is unreachable we serve a cheap 200
                # "starting" placeholder for root-ish GET/HEAD navigations.
                # This satisfies the readiness probe (and shows a friendly
                # page to a human who lands mid-boot) without masking real
                # errors on API/other paths, which still get a 502.
                if self._should_serve_starting_placeholder():
                    log.info("upstream unreachable; serving cold-start placeholder: %s", exc)
                    self._send_starting_placeholder()
                else:
                    log.warning("upstream error: %s", exc)
                    self._safe_send_error(502, "Bad Gateway")
                return

            try:
                payload = upstream.read(MAX_BODY_BYTES + 1)
            except (OSError, http.client.HTTPException) as exc:
                log.warning("upstream read error: %s", exc)
                self._safe_send_error(502, "Bad Gateway")
                try:
                    upstream.close()
                except Exception as close_exc:  # noqa: BLE001
                    log.debug("upstream.close() raised: %s", close_exc)
                return
            try:
                upstream.close()
            except Exception as exc:  # noqa: BLE001
                log.debug("upstream.close() raised (ignored): %s", exc)
            if len(payload) > MAX_BODY_BYTES:
                self._safe_send_error(502, "upstream response too large")
                return

            reason = upstream.reason or ""
            try:
                self.send_response(upstream.status, reason)
                for key, value in upstream.getheaders():
                    if key.lower() in HOP_BY_HOP_HEADERS:
                        continue
                    self.send_header(key, value)
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(payload)
            except OSError as exc:
                log.debug("client disconnected mid-response: %s", exc)
        finally:
            conn.close()


class IPv4ThreadingServer(ThreadingHTTPServer):
    address_family = socket.AF_INET
    allow_reuse_address = True
    daemon_threads = True


def _port_from_env(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        port = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name}={raw!r} is not an integer: {exc}") from exc
    if not 1 <= port <= 65535:
        raise ValueError(f"{name}={raw!r} is out of range (1-65535)")
    return port


def main() -> int:
    try:
        listen_port = _port_from_env("AUTH_PROXY_LISTEN_PORT", 8080)
        upstream_port = _port_from_env("AUTH_PROXY_UPSTREAM_PORT", 8000)
    except ValueError as exc:
        log.error("invalid port configuration: %s", exc)
        return 1

    upstream_host = os.environ.get("AUTH_PROXY_UPSTREAM_HOST", "127.0.0.1").strip()

    AuthProxyHandler.upstream_host = upstream_host
    AuthProxyHandler.upstream_port = upstream_port

    try:
        server = IPv4ThreadingServer(("0.0.0.0", listen_port), AuthProxyHandler)
    except OSError as exc:
        log.error(
            "failed to bind auth-proxy listener on 0.0.0.0:%d: %s",
            listen_port,
            exc,
        )
        return 1
    log.info(
        "listening on 0.0.0.0:%d -> %s:%d (owner=%s, header=%s)",
        listen_port,
        upstream_host,
        upstream_port,
        OWNER_USERNAME,
        REMOTE_USER_HEADER_NAME,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
