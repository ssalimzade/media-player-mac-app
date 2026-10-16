"""
Transparent solver for the Anubis proof-of-work anti-bot gateway.

HDRezka's mirrors (e.g. `hdrezka.ag` now 301s to `hdrezka-home.tv`) sit behind
[Anubis](https://github.com/TecharoHQ/anubis). Every page/AJAX request first gets a
200-OK *challenge* page (title "Проверяем, что вы не бот!") instead of real content, so
our parsers silently return nothing. A normal browser solves a small proof-of-work in JS,
POSTs it back, and receives a `techaro.lol-anubis-auth` cookie that unlocks the site.

`install()` monkeypatches `requests.Session.request` so that ANY request the sidecar makes
(our `browse` module *and* the vendored `hdrezka` library — without editing either) will,
on hitting a challenge, solve it, cache the auth cookie per host, and transparently retry.
Streamed requests (the `/relay` CDN pull) are passed straight through untouched.

The "fast" algorithm, mirrored from Anubis' client `main.mjs` / `sha256-*.mjs`:
  find the smallest integer `nonce` such that SHA-256(`randomData` + str(nonce)) has
  `difficulty` leading zero hex nibbles, then GET
  `/.within.website/x/cmd/anubis/api/pass-challenge?id=&response=<hexhash>&nonce=&redir=&elapsedTime=`.
"""

import hashlib
import json
import re
import threading
import time
from urllib.parse import urlparse

import requests

# Marker present in every Anubis challenge page (the embedded challenge JSON blob).
_CHALLENGE_MARKER = b"anubis_challenge"
_CHALLENGE_RE = re.compile(
    r'id="anubis_challenge"[^>]*>(.*?)</script>', re.S)
_PASS_PATH = "/.within.website/x/cmd/anubis/api/pass-challenge"
# Older Anubis named the cookie exactly this; newer releases (seen on v1.27) add a per-site
# suffix, e.g. `techaro.lol-anubis-auth-d82da6a5`. Match both, or a correct solve goes unnoticed
# and the challenge page is handed to the parser as if it were the title.
_AUTH_COOKIE = "techaro.lol-anubis-auth"


def _is_auth_cookie(name):
    return name == _AUTH_COOKIE or name.startswith(_AUTH_COOKIE + "-")

# Per-host cache of solved auth cookies: host -> list[(name, value, domain)].
_cache = {}
_lock = threading.Lock()

_orig_request = None


def _solve_pow(random_data, difficulty):
    """Return (hex_digest, nonce) for the smallest nonce whose SHA-256 has `difficulty`
    leading zero hex nibbles. `difficulty` counts nibbles: N//2 zero bytes plus, if odd,
    a zero high-nibble in the next byte — exactly the check in Anubis' worker."""
    full_bytes = difficulty // 2
    odd = difficulty % 2
    nonce = 0
    while True:
        h = hashlib.sha256((random_data + str(nonce)).encode()).digest()
        if all(h[i] == 0 for i in range(full_bytes)) and not (odd and h[full_bytes] >> 4):
            return h.hex(), nonce
        nonce += 1


def _looks_like_challenge(resp):
    """True if `resp` is an Anubis challenge page rather than real content."""
    if resp.request and _PASS_PATH in (resp.request.url or ""):
        return False
    ctype = resp.headers.get("content-type", "")
    if "html" not in ctype and ctype:
        return False
    try:
        body = resp.content
    except Exception:
        return False
    return _CHALLENGE_MARKER in body and b"within.website" in body


def _store_auth(session, host):
    """Snapshot any Anubis auth cookies the session just received, keyed by `host`."""
    cookies = [
        (c.name, c.value, c.domain)
        for c in session.cookies
        if _is_auth_cookie(c.name) and c.value
    ]
    if cookies:
        with _lock:
            _cache[host] = cookies


def _attach_auth(session):
    """Replay every cached Anubis auth cookie into the session jar (with its domain) so
    it rides along the request — including across the `.ag` -> `-home.tv` redirect."""
    with _lock:
        entries = [ck for cks in _cache.values() for ck in cks]
    for name, value, domain in entries:
        session.cookies.set(name, value, domain=domain)


def _solve_challenge(session, resp, headers, proxies):
    """Given a challenge response, solve the PoW and submit it. Returns True on success
    (auth cookie now in the session jar + cache), False if the challenge couldn't be read."""
    m = _CHALLENGE_RE.search(resp.text)
    if not m:
        return False
    try:
        chal = json.loads(m.group(1))
        rules = chal["rules"]
        c = chal["challenge"]
        random_data = c["randomData"]
        difficulty = int(rules["difficulty"])
        cid = c["id"]
    except (ValueError, KeyError, TypeError):
        return False

    if rules.get("algorithm") not in (None, "fast", "slow"):
        return False  # unknown/GPU algorithm we don't implement

    t0 = time.time()
    hex_digest, nonce = _solve_pow(random_data, difficulty)
    elapsed = max(1, int((time.time() - t0) * 1000))

    origin = "{u.scheme}://{u.netloc}".format(u=urlparse(resp.url))
    pass_resp = _orig_request(
        session, "GET", origin + _PASS_PATH,
        params={"id": cid, "response": hex_digest, "nonce": nonce,
                "redir": resp.url, "elapsedTime": elapsed},
        headers=headers, proxies=proxies, allow_redirects=True, timeout=(15, 60),
    )
    _store_auth(session, urlparse(pass_resp.url).hostname or "")
    return any(_is_auth_cookie(c.name) and c.value for c in session.cookies)


def _patched_request(self, method, url, **kwargs):
    # Streamed pulls (the CDN video relay) must never be buffered/inspected here.
    if kwargs.get("stream"):
        return _orig_request(self, method, url, **kwargs)

    _attach_auth(self)
    resp = _orig_request(self, method, url, **kwargs)

    # Don't recurse on our own pass-challenge submissions.
    if _PASS_PATH in url or not _looks_like_challenge(resp):
        return resp

    if _solve_challenge(self, resp, kwargs.get("headers"), kwargs.get("proxies")):
        _attach_auth(self)
        return _orig_request(self, method, url, **kwargs)   # retry once, now authenticated
    return resp


def install():
    """Idempotently patch requests so all sidecar traffic clears Anubis transparently."""
    global _orig_request
    if _orig_request is not None:
        return
    _orig_request = requests.sessions.Session.request
    requests.sessions.Session.request = _patched_request
