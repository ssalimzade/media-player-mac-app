"""
Connection reuse + a shortcut past mirror redirects, for every HTTP request the sidecar makes.

The vendored `hdrezka` library and `browse.py` call bare `requests.get/post`, and each of those
builds a throwaway Session: a fresh TCP + TLS handshake to HDRezka on every call (~200 ms each,
and a title page plus its AJAX calls is several of them). `install()` routes those calls through
one shared, thread-safe connection pool instead, so they ride warm keep-alive connections — the
`/relay` CDN pulls included, which makes player start-up and seeks quicker too.

It also remembers permanent redirects between hosts. `hdrezka.ag` (the app's default mirror)
now 301s every page to `hdrezka-home.tv`, costing a second round trip + handshake on every page
load. After the first 301/308, later GETs for the old host go straight to the new one. Only
GET/HEAD are rewritten; AJAX POSTs are answered by the old host directly.

Like `anubis.install()`, this patches `requests` itself, so neither module needs editing.
"""

import threading
import time
from urllib.parse import urlsplit

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# One pool for everything. `max_retries` covers the rare race where HDRezka closes an idle
# keep-alive connection just as we reuse it (one retry, any method — the AJAX calls are reads).
_ADAPTER = HTTPAdapter(pool_connections=16, pool_maxsize=16,
                       max_retries=Retry(total=1, connect=1, read=1, status=0, other=0,
                                         allowed_methods=None, raise_on_status=False))
# Bare requests had no timeout at all, so a stalled mirror could hang a request forever.
_DEFAULT_TIMEOUT = (10, 30)

_ALIAS_TTL = 3600
_alias = {}                 # "https://hdrezka.ag" -> ("https://hdrezka-home.tv", learned_at)
_lock = threading.Lock()
_installed = False


def _origin(url):
    p = urlsplit(url)
    return f"{p.scheme}://{p.netloc}"


def _rewrite(url):
    o = _origin(url)
    with _lock:
        hit = _alias.get(o)
    if hit and time.monotonic() - hit[1] < _ALIAS_TTL:
        return hit[0] + url[len(o):]
    return url


def _learn(resp):
    """Remember a permanent same-path redirect to another host (a mirror move)."""
    if not resp.history or resp.history[0].status_code not in (301, 308):
        return
    src, dst = resp.history[0].url, resp.url
    if _origin(src) != _origin(dst) and urlsplit(src).path == urlsplit(dst).path:
        with _lock:
            _alias[_origin(src)] = (_origin(dst), time.monotonic())


def _pooled_request(method, url, **kwargs):
    streamed = bool(kwargs.get("stream"))
    if method.upper() in ("GET", "HEAD") and not streamed:
        url = _rewrite(url)
    kwargs.setdefault("timeout", _DEFAULT_TIMEOUT)
    s = requests.Session()
    s.mount("https://", _ADAPTER)
    s.mount("http://", _ADAPTER)
    # Deliberately not closed: Session.close() would close the shared adapter's pool.
    resp = s.request(method=method, url=url, **kwargs)
    if not streamed:
        _learn(resp)
    return resp


def install():
    """Idempotently route `requests.get/post/...` through the shared pool."""
    global _installed
    if _installed:
        return
    _installed = True
    # requests.get & co. call the module-global `request` in requests.api at call time.
    requests.api.request = _pooled_request
    requests.request = _pooled_request
