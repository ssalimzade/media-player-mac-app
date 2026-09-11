/// The phone remote's page, served by `PhoneRemote` at `/`. Self-contained (no external scripts
/// or fonts): it polls `/api/state` once a second and posts button presses to `/api/cmd`.
enum RemotePage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Rezka Remote">
<meta name="theme-color" content="#101114">
<link rel="apple-touch-icon" href="/icon.png">
<title>Rezka Remote</title>
<style>
  :root { --bg:#101114; --card:#1b1c20; --raise:#26282e; --text:#f3f3f5; --dim:#9b9ea6; --accent:#3d6bff; }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
  [hidden] { display:none !important; }
  html, body { margin:0; background:var(--bg); color:var(--text);
    font:16px/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
  body { max-width:520px; margin:0 auto; -webkit-user-select:none; user-select:none;
    padding:calc(env(safe-area-inset-top) + 18px) 18px calc(env(safe-area-inset-bottom) + 28px); }
  button { font:inherit; color:inherit; border:0; background:none; padding:0; cursor:pointer; }
  button:disabled { opacity:.3; }
  svg { width:100%; height:100%; fill:currentColor; display:block; }
  .banner { background:#5a2a1e; color:#ffd9cf; border-radius:12px; padding:10px 14px; margin-bottom:14px; font-size:14px; }
  .now { background:var(--card); border-radius:22px; padding:18px; }
  .head { display:flex; gap:14px; align-items:center; min-height:78px; }
  .head img { width:54px; height:78px; border-radius:8px; object-fit:cover; background:var(--raise); flex:none; }
  .title { font-weight:700; font-size:19px; }
  .sub { color:var(--dim); font-size:14px; margin-top:2px; }
  .scrub { margin:20px 0 6px; }
  .times { display:flex; justify-content:space-between; color:var(--dim); font-size:13px;
    font-variant-numeric:tabular-nums; margin-top:4px; }
  input[type=range] { -webkit-appearance:none; appearance:none; width:100%; height:30px; background:transparent; margin:0; }
  input[type=range]::-webkit-slider-runnable-track { height:6px; border-radius:3px;
    background:linear-gradient(to right, var(--text) var(--p,0%), var(--raise) var(--p,0%)); }
  input[type=range]::-webkit-slider-thumb { -webkit-appearance:none; width:22px; height:22px; border-radius:50%;
    background:#fff; margin-top:-8px; box-shadow:0 1px 4px rgba(0,0,0,.5); }
  .transport { display:flex; align-items:center; justify-content:space-between; margin:10px 0 4px; }
  .ctl { width:54px; height:54px; padding:12px; border-radius:50%; }
  .ctl:active { background:var(--raise); }
  .play { width:80px; height:80px; padding:21px; background:#fff; color:#000; border-radius:50%; }
  .play:active { transform:scale(.94); }
  .skiprow { display:flex; gap:10px; margin-top:16px; }
  .skip { position:relative; flex:1; height:54px; border-radius:14px; overflow:hidden; background:var(--raise);
    font-weight:700; font-size:17px; }
  .skip .fill { position:absolute; top:0; bottom:0; left:0; width:0; background:rgba(255,255,255,.22);
    transition:width 1s linear; }
  .skip span { position:relative; }
  .x { width:54px; height:54px; border-radius:14px; background:var(--raise); font-size:18px; color:var(--dim); }
  .vol { display:flex; align-items:center; gap:12px; margin-top:18px; color:var(--dim); }
  .vol svg { width:22px; height:22px; flex:none; }
  .pills { display:flex; gap:8px; margin-top:18px; flex-wrap:wrap; }
  .pill { flex:1; min-width:30%; height:44px; border-radius:12px; background:var(--raise); font-size:14px;
    font-weight:600; white-space:nowrap; }
  .pill.on { background:var(--accent); }
  .idle { background:var(--card); border-radius:22px; padding:26px 18px; text-align:center; color:var(--dim); }
  .idle b { display:block; color:var(--text); font-size:18px; margin-bottom:4px; }
  h2 { font-size:17px; margin:26px 2px 12px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(96px, 1fr)); gap:12px; }
  .tile { text-align:left; }
  .tile img { width:100%; aspect-ratio:2/3; object-fit:cover; border-radius:10px; background:var(--card); display:block; }
  .tile .t { font-size:13px; margin-top:6px; overflow:hidden; display:-webkit-box; -webkit-line-clamp:2;
    -webkit-box-orient:vertical; }
  .tile .i { font-size:12px; color:var(--dim); }
  .tile:active img { opacity:.7; }
  .toast { position:fixed; left:50%; bottom:calc(env(safe-area-inset-bottom) + 24px); transform:translateX(-50%);
    background:rgba(40,42,48,.95); padding:10px 16px; border-radius:20px; font-size:14px; opacity:0;
    transition:opacity .2s; pointer-events:none; white-space:nowrap; }
  .toast.show { opacity:1; }
</style>
</head>
<body>
<div id="offline" class="banner" hidden>Can't reach Rezka Player. Is the Mac awake and on this Wi-Fi?</div>

<section id="now" class="now" hidden>
  <div class="head">
    <img id="poster" alt="">
    <div><div id="title" class="title"></div><div id="sub" class="sub"></div></div>
  </div>
  <div class="scrub">
    <input id="pos" type="range" min="0" max="1" step="1" value="0" aria-label="Position">
    <div class="times"><span id="cur">0:00</span><span id="left"></span></div>
  </div>
  <div class="transport">
    <button id="prev" class="ctl" aria-label="Previous episode"><svg viewBox="0 0 24 24"><path d="M6 5h2.2v14H6zM19.5 5.2v13.6L9.3 12z"/></svg></button>
    <button id="back" class="ctl" aria-label="Back 15 seconds"><svg viewBox="0 0 24 24"><path d="M12 4.5V1.8L7.2 5.6 12 9.4V6.6a6.4 6.4 0 1 1-6.4 6.4H3.5A8.5 8.5 0 1 0 12 4.5z"/><text x="12" y="16.3" font-size="7" font-weight="700" text-anchor="middle">15</text></svg></button>
    <button id="play" class="play" aria-label="Play or pause"></button>
    <button id="fwd" class="ctl" aria-label="Forward 30 seconds"><svg viewBox="0 0 24 24"><path d="M12 4.5V1.8l4.8 3.8L12 9.4V6.6a6.4 6.4 0 1 0 6.4 6.4h2.1A8.5 8.5 0 1 1 12 4.5z"/><text x="12" y="16.3" font-size="7" font-weight="700" text-anchor="middle">30</text></svg></button>
    <button id="next" class="ctl" aria-label="Next episode"><svg viewBox="0 0 24 24"><path d="M15.8 5H18v14h-2.2zM4.5 5.2 14.7 12 4.5 18.8z"/></svg></button>
  </div>
  <div id="skiprow" class="skiprow" hidden>
    <button id="skip" class="skip"><div id="skipfill" class="fill"></div><span id="skiplabel">Skip Intro</span></button>
    <button id="noskip" class="x" aria-label="Don't skip">✕</button>
  </div>
  <div class="vol">
    <svg viewBox="0 0 24 24"><path d="M4 9.5v5h3.5L12 18.5v-13L7.5 9.5z"/></svg>
    <input id="vol" type="range" min="0" max="1" step="0.02" value="1" aria-label="Volume">
    <svg viewBox="0 0 24 24"><path d="M3 9.5v5h3.5L11 18.5v-13L6.5 9.5zM14 8.3a5 5 0 0 1 0 7.4l-1-1.1a3.5 3.5 0 0 0 0-5.2zM16.3 5.9a8.3 8.3 0 0 1 0 12.2l-1-1.1a6.8 6.8 0 0 0 0-10z"/></svg>
  </div>
  <div class="pills">
    <button id="fs" class="pill">Full screen</button>
    <button id="auto" class="pill">Auto-skip</button>
    <button id="close" class="pill">Close player</button>
  </div>
</section>

<section id="idle" class="idle" hidden><b>Nothing playing</b>Pick something below to start it on the Mac.</section>

<h2 id="cwh" hidden>Continue Watching</h2>
<div id="cw" class="grid"></div>
<div id="toast" class="toast"></div>

<script>
const KEY = new URLSearchParams(location.search).get('k') || '';
const $ = id => document.getElementById(id);
const PLAY = '<svg viewBox="0 0 24 24"><path d="M7 4.5v15l12.5-7.5z"/></svg>';
const PAUSE = '<svg viewBox="0 0 24 24"><path d="M6 4.5h4.2v15H6zM13.8 4.5H18v15h-4.2z"/></svg>';
let state = null, syncedAt = 0, scrubbing = false, volumeAt = 0, cwKey = '';

async function api(path, body) {
  const r = await fetch(path + '?k=' + encodeURIComponent(KEY), body
    ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
    : { cache: 'no-store' });
  if (!r.ok) throw new Error(String(r.status));
  return r.json();
}
async function refresh() {
  try { render(await api('/api/state')); $('offline').hidden = true; }
  catch (e) { $('offline').hidden = false; }
}
async function send(cmd, extra) {
  try { render(await api('/api/cmd', Object.assign({ cmd }, extra || {}))); $('offline').hidden = true; }
  catch (e) { $('offline').hidden = false; }
  setTimeout(refresh, 500);   // again once the player has acted (a seek, an episode change)
}
function clock(t) {
  t = Math.max(0, Math.floor(t || 0));
  const h = Math.floor(t / 3600), m = Math.floor(t % 3600 / 60), s = String(t % 60).padStart(2, '0');
  return h ? h + ':' + String(m).padStart(2, '0') + ':' + s : m + ':' + s;
}
function paint(el) { el.style.setProperty('--p', (100 * (+el.value) / (+el.max || 1)) + '%'); }
function showPosition(t, d) {
  const pos = $('pos'); pos.value = t; paint(pos);
  $('cur').textContent = clock(t);
  $('left').textContent = d > 0 ? '-' + clock(d - t) : '';
}
function toast(text) {
  const el = $('toast'); el.textContent = text; el.classList.add('show');
  clearTimeout(toast.t); toast.t = setTimeout(() => el.classList.remove('show'), 1800);
}
function render(s) {
  state = s; syncedAt = performance.now();
  const n = s.nowPlaying;
  $('now').hidden = !n; $('idle').hidden = !!n;
  if (n) {
    $('title').textContent = n.title;
    $('sub').textContent = [n.episode, n.airplay ? 'AirPlay' : ''].filter(Boolean).join(' · ');
    const img = $('poster');
    if (n.poster && img.getAttribute('src') !== n.poster) img.src = n.poster;
    img.hidden = !n.poster;
    $('play').innerHTML = n.playing ? PAUSE : PLAY;
    $('prev').disabled = !n.canPrevious;
    $('next').disabled = !n.canNext;
    $('pos').max = Math.max(1, Math.floor(n.duration));
    if (!scrubbing) showPosition(n.position, n.duration);
    if (performance.now() - volumeAt > 1500) { $('vol').value = n.volume; paint($('vol')); }
    $('skiprow').hidden = !n.skip;
    if (n.skip) {
      $('skiplabel').textContent = n.skip === 'intro' ? 'Skip Intro' : 'Next Episode';
      $('skipfill').style.width = ((n.skipProgress || 0) * 100) + '%';
    }
    $('auto').textContent = 'Auto-skip ' + (n.autoSkip ? 'on' : 'off');
    $('auto').classList.toggle('on', n.autoSkip);
    $('fs').textContent = n.fullScreen ? 'Exit full screen' : 'Full screen';
  }
  const key = JSON.stringify(s.continueWatching);
  if (key !== cwKey) {
    cwKey = key;
    const cw = $('cw'); cw.innerHTML = '';
    for (const t of s.continueWatching) {
      const b = document.createElement('button'); b.className = 'tile';
      const img = document.createElement('img'); img.loading = 'lazy'; img.alt = '';
      if (t.poster) img.src = t.poster;
      const tt = document.createElement('div'); tt.className = 't'; tt.textContent = t.title;
      const ii = document.createElement('div'); ii.className = 'i'; ii.textContent = t.info || '';
      b.append(img, tt, ii);
      b.onclick = () => { toast('Opening ' + t.title + '…'); send('open', { url: t.url }); };
      cw.append(b);
    }
    $('cwh').hidden = s.continueWatching.length === 0;
  }
}

// Between polls, run the clock forward locally so the scrubber moves smoothly.
setInterval(() => {
  const n = state && state.nowPlaying;
  if (n && n.playing && !scrubbing && n.duration > 0) {
    showPosition(Math.min(n.duration, n.position + (performance.now() - syncedAt) / 1000), n.duration);
  }
}, 250);
setInterval(() => { if (!document.hidden) refresh(); }, 1000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });

$('play').onclick = () => {
  const n = state && state.nowPlaying;
  if (n) { n.playing = !n.playing; $('play').innerHTML = n.playing ? PAUSE : PLAY; }   // feels instant
  send('toggle');
};
$('back').onclick = () => send('seek', { value: -15 });
$('fwd').onclick = () => send('seek', { value: 30 });
$('prev').onclick = () => send('previous');
$('next').onclick = () => send('next');
$('skip').onclick = () => send('skip');
$('noskip').onclick = () => send('cancelSkip');
$('fs').onclick = () => send('fullScreen');
$('auto').onclick = () => send('autoSkip', { on: !(state && state.nowPlaying && state.nowPlaying.autoSkip) });
$('close').onclick = () => send('close');

const pos = $('pos');
pos.addEventListener('input', () => {
  scrubbing = true;
  const n = state && state.nowPlaying;
  if (n) showPosition(+pos.value, n.duration);
});
pos.addEventListener('change', () => {
  const n = state && state.nowPlaying;
  if (n) { n.position = +pos.value; syncedAt = performance.now(); }
  scrubbing = false;
  send('seekTo', { value: +pos.value });
});

const vol = $('vol');
let volTimer = null;
vol.addEventListener('input', () => {
  volumeAt = performance.now(); paint(vol);
  if (!volTimer) volTimer = setTimeout(() => { volTimer = null; send('volume', { value: +vol.value }); }, 120);
});

refresh();
</script>
</body>
</html>
"""#
}
