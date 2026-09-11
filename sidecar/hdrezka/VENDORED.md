# Vendored: HdRezkaApi

This directory is a **copy** of [SuperZombi/HdRezkaApi](https://github.com/SuperZombi/HdRezkaApi),
vendored so we can maintain/patch the scraping logic ourselves when HDRezka changes.

- Upstream commit: `d686a2d48ba530ad9034e44eb554d095bd8da82f`
- Upstream version: `11.2.3`
- License: MIT (Super_Zombi)

When upstream fixes a scraping break, diff their package against this folder and port the change.
Our own additions (catalogue/top-ranked browsing) live in `sidecar/browse.py`, **not** here, to keep
this copy a clean mirror of upstream.

## Our patches on top of upstream

Search for `VENDOR PATCH` in this folder. Current patches:

- **api.py `getStreamMovie`** — send `is_camrip`/`is_ads`/`is_director` flags (parsed from the
  page's `initCDNMoviesEvents` call). HDRezka started requiring them; without them the movie CDN
  request returns `success:true` but `url:false`.
- **api.py `favs` + `makeRequest`** — parse the per-page `#ctrl_favs` UUID token and send it as
  `favs` on every get_stream/get_movie CDN call, plus the `X-Requested-With`/`Referer` headers a
  browser sends. HDRezka added `favs` as anti-scraping; without it the CDN returns
  `success:true, url:false`. `makeRequest` also now raises a descriptive `FetchFailed` message
  (geo-restriction / login / premium hints) instead of a bare "Failed to fetch stream!".
- **errors.py `FetchFailed`** — accepts an optional message (for the diagnostics above).
- **api.py `getStream` (series)** — when given a numeric translator the title offers, go straight
  to the `get_stream` CDN call instead of first validating it against `episodesInfo`, which fetches
  *every* translator's episode list (one `get_cdn_series` POST each — 8 for a long-running series,
  ~3 s) on every stream request. The CDN call itself reports a translator that lacks the episode.
  `server.py` also never lets a series request reach the translator-priority path unless the page's
  default translator fails, so `seriesInfo` is normally never fetched.
- **api.py `translators` auto-detect** — the no-`#translators-list` fallback (`getTranslationID`)
  blindly split the whole page on the `sof.tv.initCDNMoviesEvents`/`initCDNSeriesEvents` marker and
  `int()`'d the result. On titles with **no player at all** (e.g. an upcoming/not-yet-released film
  that only shows a release date) the marker is absent, so it int()'d the leading HTML garbage and
  raised `invalid literal for int() with base 10: 'follow' ...` — sinking `/info` entirely
  ("Couldn't load title"). Now it returns `None` (→ empty translators) when the marker is missing or
  the parse fails, so such titles load with metadata and simply no streams.
- **api.py `translators`** — HDRezka moved the translator attributes (`data-translator_id`,
  `class`) off the `#translators-list` `<li>` and onto a nested `<a class="b-translator__item">`.
  Resolve the node that actually carries `data-translator_id` (supporting both the old `<li>` layout
  and the new nested `<a>` layout) and skip children without it, instead of blindly reading
  `child.attrs['data-translator_id']` — which raised `KeyError` and broke `/info` entirely for such
  titles (surfaced in-app as "Couldn't load title — missing field: 'data-translator_id'").
