# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repository.

## What this is

**RezkaPlayer** — a native macOS media player for browsing, streaming, and downloading from
HDRezka. Personal-use tool. Two parts:

- **`app/`** — SwiftUI macOS app (UI, AVKit player, downloads, library, menu-bar, notifications).
- **`sidecar/`** — a Python helper the app spawns on `127.0.0.1`; it does *all* HDRezka scraping.

The app talks to the sidecar over local HTTP (JSON). The scraping library
[SuperZombi/HdRezkaApi](https://github.com/SuperZombi/HdRezkaApi) is **vendored** under
`sidecar/hdrezka/` and maintained here (so we can patch when HDRezka changes).

## Build & run

```bash
# Sidecar (Python 3.9+). The app launches it automatically; this is just for manual testing.
cd sidecar
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt          # requests, beautifulsoup4, PySocks
python server.py --port 8777             # prints "SIDECAR_READY ... port=N"

# App (needs Xcode 26 + xcodegen: `brew install xcodegen`)
cd app
xcodegen generate                        # regenerates RezkaPlayer.xcodeproj from project.yml
xcodebuild -project RezkaPlayer.xcodeproj -scheme RezkaPlayer -configuration Debug \
  -destination 'platform=macOS' build
```

Built app: `~/Library/Developer/Xcode/DerivedData/RezkaPlayer-*/Build/Products/Debug/RezkaPlayer.app`.
Packaged DMG: `./scripts/package.sh` → `build/RezkaPlayer.dmg` (see Packaging below).

## Architecture & conventions

- **`app/project.yml` is the source of truth** for the Xcode project. The `.xcodeproj` is
  **gitignored and regenerated** — never hand-edit it; edit `project.yml` and run `xcodegen generate`.
  Version lives in `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` (Info.plist references them).
- **Sidecar process management** (`Sidecar.swift`): the app prefers a **bundled** frozen sidecar
  (`Resources/sidecar/rezka-sidecar/rezka-sidecar`, present in packaged builds) and falls back to the
  dev venv/`server.py` otherwise. It launches with `--host 0.0.0.0 --port 0` (OS-assigned port),
  parses the `SIDECAR_READY host=.. port=N` stdout line, and sends a per-launch `X-Auth-Token` on
  every request. It binds on `0.0.0.0` (not just loopback) so an AirPlay receiver can reach the
  `/relay` over the LAN (see AirPlay below); every endpoint stays token-gated, so LAN exposure is
  closed except `GET /health`. The app's own control traffic still uses `127.0.0.1`.
- **Sidecar cleanup is belt-and-suspenders:** the app calls `stop()` on `willTerminate`, *and*
  `server.py` runs a stdin-EOF watchdog so it self-terminates if the app crashes. Both prevent
  orphaned Python. The watchdog only runs when `REZKA_SIDECAR_MANAGED=1` (set by the app) — else a
  manual/CI `python server.py` would exit instantly on already-EOF stdin.
- **All scraping lives in the sidecar.** Swift never parses HTML. To add a capability: add a
  `server.py` endpoint (register in `ROUTES`) + a method on `APIClient.swift` + a model in
  `Models.swift`.
- **Every sidecar request carries `origin` and (when logged in) `cookies`, plus an optional
  `proxy`.** `APIClient` injects `origin`/`cookies` automatically via providers wired in `AppState`.
- **Vendored code hygiene:** `sidecar/hdrezka/` stays a clean upstream mirror *except* `VENDOR
  PATCH`-marked edits (documented in `sidecar/hdrezka/VENDORED.md` — currently: movie CDN flags, the
  `favs` token, a richer `FetchFailed`, and a direct `getStream` for a known translator). Our own
  features go in `sidecar/browse.py` /
  `server.py`, never inside `hdrezka/`.
- **Episode navigation:** `PlayerView.jump(to:)` serves previous/next, the episode list, the
  credits countdown and end-of-playback auto-advance (resuming part-watched episodes). Streams walk
  the whole series across seasons (`PlayerTarget.allEpisodes`, built by `DetailView`); local
  playback walks completed downloads (`DownloadManager.downloadedEpisodes(ofPage:)`, numeric
  season/episode order). A Next button also sits in the window toolbar.
- **On-video controls live in `AVPlayerView.contentOverlayView`** (`PlayerOverlay.swift`), not a
  SwiftUI overlay: AVKit moves the whole player view — content overlay included — into its own
  full-screen window, so a SwiftUI overlay would be left behind. Each control is a content-sized
  `NSHostingView` on a click-transparent `PointerTrackingView` (reveals the bar on pointer
  movement), so the rest of the video stays AVKit's to click. The top-centre bar keeps clear of
  AVKit's corners (volume/PiP/full-screen); the skip countdown sits bottom-right above its control bar.
  The bar also has a quality menu for streams (movies get just that): `PlayerView.switchQuality`
  swaps the item in place — paused, then seeked back to the same moment — and makes it the
  preferred quality, so later episodes follow.
- **Local playback carries page context.** A local `PlayerTarget` sets `pageURL`, `season`/`episode`
  and `downloadID`, not just the file path. Progress is keyed on the page URL, so without it
  Continue Watching stored a *media file path* as the page URL and then 404'd trying to load the
  title; carrying it also means a downloaded episode shares progress/watched/Trakt state with the
  streamed one. `ProgressStore.repairLocalFilePathEntries` migrates entries written by older builds.
- **Player:** uses AppKit `AVPlayerView` via `NSViewRepresentable` (`PlayerView.swift`). **Do not use
  SwiftUI `VideoPlayer`** — it crashes during view-metadata instantiation on macOS 26.

### App data stores (all `@MainActor ObservableObject`, owned by `AppState`)

Persist JSON to `~/Library/Application Support/RezkaPlayer/` (login cookies go to the Keychain):

| Store | File | What |
|-------|------|------|
| `DownloadManager` | `library.json` + `Media/` | downloads (+ pause/resume, notifications) |
| `BookmarkStore` | `watchlater.json` | Watch Later |
| `WatchedStore` | `watched.json` | watched/History |
| `ProgressStore` | `progress.json` | resume positions / Continue Watching |
| `PreferenceStore` | `lasttranslator.json` | per-title last translator |
| `SkipStore` | `skipmarkers.json` (+ `Fingerprints/` cache) | detected intro/credits per episode |
| `Keychain.swift` | macOS Keychain | HDRezka session cookies |

`AppState` re-publishes each store's `objectWillChange` (sinks in `init()`), holds `@AppStorage`
prefs (`hdrezkaOrigin`, `proxyURL`, `preferredQuality`, `hideWatched`, `autoSkipIntroCredits`, `phoneRemoteEnabled`, `hdrezkaEmail`), and exposes
`login/logout`, `pushProxyConfig`, and `playbackURLString(for:)` (relay rewriting). Sidebar sections
are an enum in `RootView.swift` (`sectionRoot` switch). The menu bar + notification auth live in
`RezkaPlayerApp.swift` / `DownloadManager.swift`.

## Sidecar endpoints

POST + JSON (except `GET /health`, `GET /relay`, `GET /media`; all three also answer `HEAD`).
Body includes `origin`; may include `cookies`,
`proxy`, `headers`.

| Endpoint   | Body                                                        | Returns |
|------------|-------------------------------------------------------------|---------|
| `GET /health` | —                                                        | `{ok, version, categories, collections, genres, sorts, proxy}` |
| `/config`  | `proxy` (`"socks5://.."` or `""`)                           | `{ok, proxy}` — process-wide proxy for all traffic |
| `/search`  | `query`, `find_all?`, `page?`                               | `{results: [CatalogueItem]}` |
| `/browse`  | `collection`, `category`, `page?`, `genre?`, `year?`, `sort?` | `{results: [CatalogueItem]}` |
| `/info`    | `url`, `translation?`                                       | `TitleInfo` (metadata, translators, **one translator's** episodes + `episodesTranslator`, **similar**) |
| `/stream`  | `url`, `translation?`, `season?`, `episode?`               | `{videos: {quality:[urls]}, subtitles, ...}` |
| `/login`   | `email`, `password` (+ `origin`)                           | `{ok, cookies?, message?}` |
| `GET /relay` | query: `u`=b64url(cdn), `t`=token, `r`=b64url(origin)     | streams the video (Range-aware) through the configured proxy |
| `GET /media` | query: `f`=b64url(base name), `t`=token                   | streams a completed download from `Media/` (Range-aware) — lets an AirPlay receiver fetch it |

`browse` paths: genre → `/{cat}/{genre}/`; `sort=best` → `/{cat}/best/[{year}/]`;
`last/popular/soon/watching` → `?filter=…`. Genre slugs + sort options come from `browse.GENRES`/
`SORTS` (also surfaced in `/health`; the Swift `CatalogueGenres` enum mirrors them — keep in sync).

### Proxy / relay (geo-restriction)

HDRezka's video CDN is geo-blocked in some regions; AVPlayer/URLSession can't use a SOCKS proxy
directly, so geo-sensitive traffic is funneled through the sidecar. Set a proxy via `/config`; the
app rewrites stream/download URLs to `GET /relay?u=…` (`AppState.playbackURLString`). The relay
fetches CDN bytes through the proxy and forwards Range requests for seeking. `u`/`r` are URL-safe
base64 (`AppState.b64url` ↔ `server._b64url_decode`). SOCKS needs `PySocks` (`socks5://` → `socks5h://`
so DNS resolves at the proxy).

### AirPlay (LAN relay)

AVPlayer's **external-playback** (AirPlay) mode hands the *video URL to the TV* and the TV fetches it
itself. Three things follow, and all three are required — miss one and the TV just sits on its idle
AirPlay screen while the Mac reports "playing on TV":

1. **Never give the receiver a loopback URL.** Remote items always play through
   `AppState.lanRelayURLString` — a `/relay` URL on the **Mac's LAN IP**
   (`LANAddress.primaryIPv4()`), used for local playback *and* AirPlay. Beyond the TV being unable
   to reach `127.0.0.1`, AVFoundation won't even offer a *video* AirPlay route for a loopback item
   (you get an audio-only route, and `isExternalPlaybackActive` never flips). No source swap is
   needed on engage, since the same URL serves both. Needs the `0.0.0.0` bind above.
2. **The sidecar must answer `HEAD`.** AirPlay receivers probe the media URL with `HEAD` before
   fetching it. `BaseHTTPRequestHandler` answers `501 Unsupported method` for anything without a
   `do_*`, so the receiver gave up before ever issuing a `GET` — hence `do_HEAD` in `server.py`
   (same routes, headers only).
3. **Downloaded files need an HTTP URL too.** A `file://` path is meaningless to the TV, so when
   external playback engages on a local item, `PlayerView` swaps in `AppState.localMediaURLString`
   → `GET /media?f=<b64 basename>&t=…`, which serves the file out of `Media/` (Range-aware,
   token-gated, base-name only). It swaps back to the local file when AirPlay disengages; position
   is preserved both ways. Plain local playback stays a direct `file://` read.

4. **One player for the app.** macOS keeps the AirPlay choice on the `AVPlayer`, so a fresh
   player per title (or per visit to the player) started back on the Mac every time.
   `AppState.player` is shared by every `PlayerView`, so a TV picked once stays picked. There's no
   public API to *pick* a route in code (the private `AVOutputDeviceDiscoverySession` returns no
   devices to us), so the first pick is always the player's AirPlay button; after that the phone
   remote's "Play on Mac / Play on TV" toggles `allowsExternalPlayback`, and each new player
   visit turns it back on.

Verified against a Samsung Tizen receiver, which fetches the URL with a `SMART-TV; LINUX; Tizen`
user-agent. Note this is *AirPlay*, not screen mirroring — mirroring never flips
`isExternalPlaybackActive`, so none of the above applies to it.

### Intro / credits skipping

HDRezka publishes no intro/credits markers, so `SkipDetector` (an `actor`) finds them the way
Plex/Jellyfin do: the opening theme is the same recording in every episode, so the longest stretch
of audio two neighbouring episodes share in their first quarter (≤7 min) is the intro, and in their
last fifth (≤4 min) the credits. Fingerprints are a Philips/Haitsma–Kalker sub-band hash built with
Accelerate (~8 frames/s, 32 bits each); matching is XOR+popcount over every time offset, a run
tolerating ~1.5 s gaps (voice-over across the theme). No ffmpeg/chromaprint to bundle.

- **`AVAssetReader` refuses non-local URLs** (`-11838`). For streams, `Media.sparse` fetches the
  moov (head, else tail) into a same-size **sparse** temp file, then uses the sample table
  (`AVSampleCursor.currentChunkStorageRange`) to Range-fetch only the bytes holding each analysed
  window. Audio comes from the **lowest** quality (`AppState.skipAnalysisURL`, relay-routed when
  proxied). Downloads are read in place.
- The player calls `prepare(current:neighbours:)` on every episode change: the current episode is
  paired with its next (else previous) neighbour, then the *next* episode is pre-analysed so
  auto-advance has markers ready. One pair comparison yields markers for both episodes.
  Fingerprints cache per episode + translation in `Fingerprints/`; "checked, nothing found" is
  stored too so it isn't redone (network failures aren't).
- `PlayerView.checkSkips` (0.25 s ticks) shows a Netflix-style "Skip Intro" / "Next Episode"
  button that fills up over a 5 s countdown in media time (pausing pauses it; ✕ cancels for that
  episode), then **cuts**: picture (a `FadeView` in the content overlay) and volume ease out
  (~0.35 s) and back in (~0.6 s) around the seek — or, for credits, around the switch to the next episode, revealed when
  its item is ready (8 s failsafe). The seek is on the `AVPlayer`, so it works over AirPlay — but
  the button and fade are drawn on the Mac only. `autoSkipIntroCredits` off = no
  detection/fetching at all (a plain Skip button still shows where markers exist).

### Speed (pooled connections, caches, prefetch)

HDRezka round trips are the app's latency. What keeps a title page + Play under ~1 s (measured:
cold title ~0.4–0.5 s, a stream ~0.15 s, anything cached ~1 ms):

- **`net.py`** (installed next to `anubis.install()`) routes every bare `requests.get/post` — the
  vendored library, `browse.py`, the `/relay` pull — through one shared keep-alive pool (a fresh
  TLS handshake per call cost ~200 ms), adds a default timeout, and remembers permanent
  cross-host redirects: `hdrezka.ag` 301s every page to `hdrezka-home.tv`, so later GETs go
  straight there. Only GET/HEAD are rewritten; `.ag` answers the AJAX POSTs itself.
- **Title cache** (`server.title_for`): a page is fetched once per 15 min per (url, cookies,
  proxy) and shared by `/info` and `/stream`; concurrent requests wait for that one fetch. The
  parsed soup is dropped after loading (it's MBs; the raw page re-parses on demand). Resolved
  streams are memoised for 30 min (CDN links expire ~20 h out).
- **One translator's episodes at a time.** Upstream's `episodesInfo` fetched *every* translator's
  episode list (a `get_cdn_series` call each, ~3 s for 8) on every `/info` and `/stream`. `/info`
  now lists the `translation` asked for (the app sends its remembered one), else the page's
  default translator — whose list the page inlines, so it's free — and names it in
  `episodesTranslator`; `DetailView.switchTranslator` re-asks when another is picked. `/stream`
  without a translation uses the page default (upstream's priority pick only if that fails).
- **The app prefetches** (`AppState.prefetchTitle`): a poster the pointer rests on (250 ms), the
  top Continue Watching titles once the sidecar is up (plus the stream their page opens on), and
  the player's next episode (`PlayerView.prefetchNextStream`).
- **Don't publish per tick.** Every store re-publishes through `AppState`, so any store change
  re-renders the whole app: download progress is throttled to 2/s (and not written to disk per
  tick), and `ProgressStore` keeps indexes rather than scanning ≤2000 entries per poster.

### Phone remote

For watching on a TV over HDMI (a Mac has no HDMI-CEC, so the TV remote can't reach it):
`PhoneRemote` + `RemoteServer` + `RemotePage` serve a self-contained web page from **the app
itself** (Network.framework `NWListener`, port 47821, or the next free one) to a phone on the
same Wi-Fi. It's in Swift rather than the sidecar because every command needs the live player.

- **Pairing:** every request except `/icon.png` must carry `?k=<key>` (`phoneRemoteKey` in
  UserDefaults). Settings → Phone remote shows the link as a QR code, plus a Bonjour-name variant,
  and "New link" rotates the key. Toggle: `phoneRemoteEnabled`.
- **API:** the page polls `GET /api/state` (Now Playing + Continue Watching) every second and
  sends `POST /api/cmd {cmd, value?|on?|url?}`: toggle, seek, seekTo, previous, next, skip,
  cancelSkip, volume, autoSkip, quality, airplay, fullScreen, close, open.
- **Player:** the `PlayerView` on screen registers a snapshot/command handle
  (`attachRemote`/`detach`); commands act on its `AVPlayer`, so they work over AirPlay too.
  Full screen uses AVPlayerView's `enterFullScreen:`/`exitFullScreen:` (not in the public
  headers, so guarded by `responds(to:)`, falling back to the window) and tracks the state via
  `AVPlayerViewDelegate`. Close leaves full screen first, then `dismiss()`es.
- **Open from the phone:** `AppState.playFromRemote` resets the navigation path, pushes the title
  (`pendingItem`) and sets `autoplayPage`; once that `DetailView` has its stream it pushes the
  player through `pendingPlayer`.

## Anubis anti-bot gateway

HDRezka's mirrors sit behind [Anubis](https://github.com/TecharoHQ/anubis) (`hdrezka.ag` now
301s to `hdrezka-home.tv`). Every page/AJAX request first returns a **200-OK proof-of-work
challenge page** (title "Проверяем, что вы не бот!") instead of real HTML — so parsers see no
`.b-content__inline_item` and the app shows a misleading **"Nothing here yet"** empty state
(not "Couldn't load", since no exception is raised). `sidecar/anubis.py` handles this
transparently: `install()` (called at the top of `server.py`, before any request)
monkeypatches `requests.Session.request` so *all* sidecar traffic — our `browse` module **and**
the vendored `hdrezka` library, with no edits to either — detects a challenge, solves the
"fast" SHA-256 PoW (`sha256(randomData + nonce)` with `difficulty` leading zero nibbles),
GETs `…/api/pass-challenge`, caches the `techaro.lol-anubis-auth` cookie per host, and retries
once. Streamed requests (the `/relay` CDN pull, `stream=True`) are passed through untouched.
The cache self-heals: an expired cookie just yields a fresh challenge that gets re-solved. If
HDRezka bumps Anubis to a GPU/non-`fast` algorithm, `_solve_pow` needs updating.

## Known gotcha — streaming is IP-gated

HDRezka's CDN returns `success:true` but `url:false` for **every** translation from a
datacenter/blocked IP (and even 403s the whole site on some hosting ASNs like Hetzner). `/browse`
and `/info` work from the same IP — only stream generation/delivery is geo-gated. So a `/stream`
`FetchFailed` in a sandbox/CI is usually **not** a code bug; verify from a residential connection or
via the in-app proxy.

## Packaging & distribution

- `scripts/build-sidecar.sh` — PyInstaller **onedir** freeze of the sidecar (onefile was ~7s
  startup; onedir ~1s). Includes requests/bs4/PySocks + vendored `hdrezka`.
- `scripts/package.sh` — Release build → bundle the frozen sidecar into `Resources/` → ad-hoc sign
  inside-out (including **Sparkle's** nested Updater.app/XPC services/Autoupdate) → `build/RezkaPlayer.dmg`
  (Apple Silicon, hardened runtime OFF — not notarized).
- `.github/workflows/release.yml` — on a `v*` tag, runs `package.sh`, then **EdDSA-signs the DMG**
  (`sign_update -f` with the `SPARKLE_ED_PRIVATE_KEY` repo secret), generates `appcast.xml`, and
  publishes both as a GitHub Release.
- First launch on a recipient's Mac needs right-click → Open or
  `xattr -dr com.apple.quarantine /Applications/RezkaPlayer.app`.

### Auto-update (Sparkle)

Sparkle (SPM dep in `project.yml`) keeps the app current. Config is in Info.plist via `project.yml`:
`SUFeedURL` → `https://github.com/rmaltsev1/media-player-mac-app/releases/latest/download/appcast.xml`
(GitHub's stable "latest release" URL), `SUPublicEDKey` → the EdDSA public key. `Updater.swift` owns
an `SPUStandardUpdaterController`; the "Check for Updates…" menu item (`RezkaPlayerApp`) and the
Settings → Updates toggle drive it. **The signing keypair:** private key lives in the maintainer's
login Keychain *and* the `SPARKLE_ED_PRIVATE_KEY` GitHub Actions secret; public key is embedded.
Verification is EdDSA-only (independent of Apple notarization). **Rollout is two-release:** the
version that *adds* Sparkle can't be auto-pulled by older builds — the first auto-update a user sees
is the release *after* the one they installed.

## Decisions made (don't re-litigate without reason)

- Architecture: **SwiftUI app + bundled Python sidecar** (not pure Python; a pure-Swift/iOS port is
  in `BACKLOG.md`).
- Domain configurable in Settings (default `https://hdrezka.ag`); HDRezka geo-blocks the CDN.
- Login implemented (Keychain cookies). Downloads are direct `.mp4` per resolution via `URLSession`.
- Distribution: free **ad-hoc DMG** (right-click-Open) + **Sparkle auto-update** (EdDSA-signed,
  shipped v0.4.0). Apple notarization is still deferred in `BACKLOG.md`.

## Backlog

See `BACKLOG.md`: Apple notarization (removes Gatekeeper friction on updates), follow-series +
new-episode notifications, iOS port (pure-Swift core).
