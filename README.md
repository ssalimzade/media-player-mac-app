# Rezka Player (macOS)

A native macOS app for browsing, streaming, and downloading from HDRezka — built for personal use.

Built on top of [SuperZombi/HdRezkaApi](https://github.com/SuperZombi/HdRezkaApi), which is
**vendored and self-maintained** under `sidecar/hdrezka/` so the scraping logic can be patched
in-tree when HDRezka changes.

## Features

**Browse & discover**
- Catalogue by category — Films, Series, Cartoons, Anime — plus a "Now Watching" home feed.
- **Sort** (Top-ranked / Latest / Popular / Watching) and filter by **genre** and **year**.
- **Search** HDRezka by title (poster-grid results).
- **Similar titles** row on every detail page.

**Watch**
- **Stream in-app** with a native AVKit player — pick the **translation** (dub/voiceover/subs) and
  **resolution** (360p–1080p Ultra). Series get season/episode pickers.
- **Continue Watching** row + **resume from where you left off**.
- **Next episode** — a toolbar button in the player, plus auto-advance when an episode ends. Works
  for streamed series *and* downloaded ones (downloads chain through the episodes you have).
- **AirPlay to a TV** — streams *and* downloaded files, served to the TV from your Mac over its LAN
  IP, so playback keeps working even when the title is geo-blocked / behind your Mac's VPN. Pick an
  AirPlay route in the player (this is real AirPlay, not screen mirroring — your Mac stays free).
- Remembers your **preferred resolution** and **per-title translation**.

**Library**
- **Watch Later** bookmarks and a **History** of watched titles.
- **Mark as watched** (auto on finish) + a **Hide-watched** toggle and a watched badge on posters.
- **Download** any title/resolution; **pause/resume**; watch **offline** from the Downloads tab;
  **download a whole season** at once; "Show in Finder".

**Account & network**
- **Log in to HDRezka** (cookies stored in the macOS Keychain) for premium translations / higher
  resolutions.
- **Configurable mirror** domain and an optional **proxy** (for geo-blocked regions — see below).

**System**
- **Menu-bar mini-controller** (helper status + active downloads) and **download-finished
  notifications**.
- **Auto-update** — the app checks GitHub releases and installs new versions in place (Sparkle,
  EdDSA-signed). *RezkaPlayer → Check for Updates…*, or toggle automatic checks in Settings.

## Architecture

```
┌──────────────────────────────┐
│  RezkaPlayer.app (SwiftUI)    │   Native UI · AVKit player · downloads · offline library
│  - browse / search / filter   │
│  - stream / download / resume │
└───────────────┬──────────────┘
        local HTTP (127.0.0.1, token-guarded)
┌───────────────┴──────────────┐
│  Python sidecar (server.py)   │   stdlib http.server + vendored HdRezkaApi + our browse module
│  search/browse/info/stream/   │   …login + a Range-aware video relay for proxying
│  config/login/relay           │
└──────────────────────────────┘
```

- **`app/`** — SwiftUI macOS app. The Xcode project is generated from `app/project.yml` via
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) (the `.xcodeproj` is gitignored). App data
  (Watch Later, History, resume positions, downloads, login) persists as JSON / Keychain under
  `~/Library/Application Support/RezkaPlayer/`.
- **`sidecar/`** — Python helper the app spawns on a local port and talks to over JSON/HTTP.
  - **`sidecar/hdrezka/`** — vendored HdRezkaApi (mirror of upstream; only `VENDOR PATCH`-marked
    edits, documented in `VENDORED.md`).
  - **`sidecar/browse.py`** — our catalogue browsing, genre/year/sort paths, and similar-title parsing.
  - **`sidecar/server.py`** — the local JSON server.
- **`scripts/`** — `package.sh` (build a shareable DMG) and `build-sidecar.sh` (freeze the sidecar).

See **`CLAUDE.md`** for architecture details, conventions, and the full endpoint reference.

## Getting started (development)

Needs **Xcode 26**, **xcodegen** (`brew install xcodegen`) and **Python 3.9+**. The `Makefile`
wraps the whole loop — `make` on its own lists every target:

```bash
make doctor      # check the toolchain before you start
make run         # venv + xcodegen + build (Debug) + launch
```

Or by hand:

```bash
# 1. Sidecar deps. The app launches the sidecar itself; this is just the venv it uses.
cd sidecar
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt          # requests, beautifulsoup4, PySocks

# 2. App
cd ../app
xcodegen generate
open RezkaPlayer.xcodeproj                # ⌘R to run
```

Other useful targets: `make xcode` (open in Xcode), `make sidecar` / `make health` (run and probe
the sidecar standalone on `PORT`, default 8777), `make dmg` (packaged build), `make clean`.

On first run, open **Settings** and set the HDRezka mirror domain (and a proxy if needed).

## Streaming from a geo-blocked region (proxy)

HDRezka's **video CDN** is geo-blocked in some regions (e.g. the UK): the site loads, but stream
URLs come back empty (`success:true, url:false`). Because the video bytes are fetched by AVPlayer /
URLSession — which can't use a SOCKS proxy directly — the app routes **all** geo-sensitive traffic
(scraping **and** playback **and** downloads) through the Python sidecar:

- Set a **Proxy URL** in Settings, e.g. `socks5://user:pass@host:1080` (HTTP proxies work too).
- The sidecar uses it for scraping and exposes a local `/relay` endpoint that streams the video
  through the proxy with HTTP Range support, so playback and downloads egress via the proxy while
  the rest of your Mac stays on its normal connection.

Easiest option: just run a **system-wide VPN** to a permitted region and leave the Proxy field
empty. For app-only proxying, some providers expose a standalone **SOCKS5 endpoint** (e.g. Private
Internet Access). Note: HDRezka also blocklists many **datacenter/hosting** IPs, so a cheap VPS may
be refused regardless of country — a consumer VPN's IP usually works.

## Build a shareable app (.dmg)

Produce a self-contained, double-clickable app — no Python/Xcode needed on the recipient's Mac
(Apple Silicon):

```bash
./scripts/package.sh        # -> build/RezkaPlayer.dmg  (~13 MB)
```

This freezes the sidecar with PyInstaller (bundled into the app), builds the app in Release,
ad-hoc signs it, and wraps it in a DMG with an `INSTALL` note. The app launches its **bundled**
sidecar, so there's no venv dependency.

**Automated releases:** pushing a `v*` tag runs `.github/workflows/release.yml`, which builds the
DMG on a macOS runner and publishes it as a GitHub Release:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

**Installing (recipient):** download `RezkaPlayer.dmg` from the
[latest release](https://github.com/rmaltsev1/media-player-mac-app/releases/latest), drag to
Applications, then **first launch only** right-click → **Open** (it's ad-hoc signed, not notarized).
If macOS still blocks it: `xattr -dr com.apple.quarantine /Applications/RezkaPlayer.app`.

**Auto-update:** once installed, the app keeps itself current via
[Sparkle](https://sparkle-project.org) — it reads an `appcast.xml` published with each release and
verifies the new DMG against an embedded EdDSA key before installing. CI signs each build with the
`SPARKLE_ED_PRIVATE_KEY` secret (the public key is in the app's Info.plist). Because the build isn't
Apple-notarized, an update may re-show the right-click → Open prompt once; see `BACKLOG.md` for the
notarization follow-up.

## Notes & limitations

- **Streaming is IP-gated.** HDRezka's CDN won't generate stream URLs for blocked/datacenter IPs
  (`success:true, url:false`). Browsing and metadata still work; streaming needs a permitted region
  — see the proxy section. This is not an app bug.
- **Pause/resume is in-session** — a download paused, then resumed after relaunching the app,
  restarts from scratch (resume data isn't persisted yet).
- **Dev build runs unsandboxed** and (in Debug) points at this repo's `sidecar/` venv; the packaged
  Release build is self-contained.

## Legal

Personal-use tool. HDRezka hosts third-party content; you are responsible for complying with the
laws and terms applicable in your jurisdiction.
