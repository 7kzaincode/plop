import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'item.dart';
import 'plop_node.dart';
import 'shelf_store.dart';

/// Port the app asks for first: p-l-o-p on a phone keypad, so the address a
/// phone has to type is one worth remembering. Any free port when taken.
const defaultWebPort = 7567;

/// A one-page web shelf for devices without the app (iPhones, mostly),
/// served on the node's own port once [enabled]. The page lists everything
/// this node knows, own items and mirrors alike, hands any of it out
/// through this node, and takes uploads as this node's own items.
///
/// plop peers never call these routes, so the /v1 rule that mirrors are not
/// re-served still holds between nodes: a phone on this page is a user of
/// this device, not a peer, and what it grabs comes off this device's shelf
/// the way a tap in the window would.
class WebHost {
  WebHost(this.node);

  final PlopNode node;

  /// Off until the app turns it on; a disabled host answers 404 to all of
  /// its routes, so a bare node looks like it always did.
  bool enabled = false;

  /// The PNG behind /icon.png: the app's icon. A black pixel until set.
  Uint8List iconPng = _blackPixel;

  /// Text items up to this size travel inline in the shelf list, so a tap
  /// can copy them without a fetch first: on plain http a browser offers no
  /// async clipboard, and the fallback it does have only works inside the
  /// tap itself.
  static const maxInlineText = 64 * 1024;

  /// Longest text /web/text takes; it is read into memory whole.
  static const maxTextBytes = 1 << 20;

  final _texts = <String, String>{}; // key -> body of a ready text item

  /// Answers one request to a path outside /v1. Always closes the response.
  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    try {
      await _route(req);
    } catch (_) {
      // Whatever already went out stays; what can still be said is 500.
      try {
        res.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
    }
    try {
      await res.close();
    } catch (_) {}
  }

  Future<void> _route(HttpRequest req) async {
    final res = req.response;
    switch ((req.method, req.uri.pathSegments)) {
      case ('GET', []):
        res.headers
          ..contentType = ContentType.html
          ..set(HttpHeaders.cacheControlHeader, 'max-age=60');
        res.write(
          _page.replaceAll('{{name}}', htmlEscape.convert(node.store.nodeName)),
        );
      case ('GET', ['manifest.webmanifest']):
        res.headers
          ..contentType = ContentType(
            'application',
            'manifest+json',
            charset: 'utf-8',
          )
          ..set(HttpHeaders.cacheControlHeader, 'max-age=3600');
        res.write(jsonEncode(_manifest));
      case ('GET', ['icon.png']):
        res.headers
          ..contentType = ContentType('image', 'png')
          ..set(HttpHeaders.cacheControlHeader, 'max-age=86400');
        res.contentLength = iconPng.length;
        res.add(iconPng);
      case ('GET', ['web', 'shelf']):
        _noStore(res);
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(await _shelf()));
      case ('GET', ['web', 'items', final origin, final id]):
        await _download(req, itemKey(origin, id));
      case ('POST', ['web', 'items']):
        await _upload(req);
      case ('POST', ['web', 'text']):
        await _text(req);
      case ('DELETE', ['web', 'items', final origin, final id]):
        _noStore(res);
        final item = node.store[itemKey(origin, id)];
        if (item == null) {
          res.statusCode = HttpStatus.notFound;
        } else if (item.originId != node.id) {
          res.statusCode = HttpStatus.forbidden; // only the sender removes
        } else {
          node.remove(item.key);
          res.statusCode = HttpStatus.noContent;
        }
      default:
        res.statusCode = HttpStatus.notFound;
    }
  }

  static void _noStore(HttpResponse res) =>
      res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');

  /// Every item this node knows, newest first, with a text item's body
  /// inline while it is small and already here.
  Future<List<Map<String, Object>>> _shelf() async {
    final items = node.items;
    final live = {for (final i in items) i.key};
    _texts.removeWhere((k, _) => !live.contains(k));
    final out = <Map<String, Object>>[];
    for (final i in items) {
      final text = await _textOf(i);
      out.add({
        'key': i.key,
        'name': i.name,
        'size': i.size,
        'mime': i.mime,
        'kind': i.kind.name,
        'ttlMs': i.remaining.inMilliseconds,
        'from': i.originName,
        'ready': i.isReady,
        if (i.originId == node.id) 'receivedBy': i.receivedBy.length,
        'text': ?text,
      });
    }
    return out;
  }

  Future<String?> _textOf(ShelfItem i) async {
    if (i.kind != ItemKind.text || !i.isReady || i.size > maxInlineText) {
      return null;
    }
    try {
      return _texts[i.key] ??= await File(i.path!).readAsString();
    } catch (_) {
      return null; // expired between the listing and the read
    }
  }

  Future<void> _download(HttpRequest req, String key) async {
    final res = req.response;
    _noStore(res);
    if (node.store[key] == null) {
      res.statusCode = HttpStatus.notFound;
      return;
    }
    final String path;
    try {
      path = await node.fetch(key); // a mirror not copied yet is copied now
    } catch (_) {
      // Expired meanwhile, or its sender cannot be reached.
      res.statusCode = node.store[key] == null
          ? HttpStatus.notFound
          : HttpStatus.badGateway;
      return;
    }
    final item = node.store[key];
    final file = File(path);
    if (item == null || !await file.exists()) {
      res.statusCode = HttpStatus.notFound;
      return;
    }
    res.headers
      ..contentType = ContentType.parse(item.mime)
      ..set('content-disposition', _attachment(transferName(item)));
    res.contentLength = await file.length();
    await file.openRead().pipe(res);
  }

  Future<void> _upload(HttpRequest req) async {
    final res = req.response;
    _noStore(res);
    final body = _body(req);
    final name = req.uri.queryParameters['name']?.trim() ?? '';
    if (name.isEmpty) {
      res.statusCode = HttpStatus.badRequest;
      return;
    }
    final length = req.contentLength; // -1 when chunked
    try {
      final item = await node.store.addStream(
        body,
        name,
        expectedSize: length < 0 ? null : length,
      );
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'key': item.key}));
    } on ItemTooLargeException {
      // The rest of the body stays unread; see _body.
      res.statusCode = HttpStatus.requestEntityTooLarge;
    } on FormatException {
      res.statusCode = HttpStatus.badRequest; // ended short of its length
    }
  }

  Future<void> _text(HttpRequest req) async {
    final res = req.response;
    _noStore(res);
    final body = _body(req);
    if (req.contentLength > maxTextBytes) {
      res.statusCode = HttpStatus.requestEntityTooLarge;
      return;
    }
    final buf = BytesBuilder(copy: false);
    await for (final chunk in body) {
      buf.add(chunk);
      if (buf.length > maxTextBytes) {
        res.statusCode = HttpStatus.requestEntityTooLarge;
        return;
      }
    }
    final text = utf8.decode(buf.takeBytes(), allowMalformed: true);
    if (text.trim().isEmpty) {
      res.statusCode = HttpStatus.badRequest;
      return;
    }
    final item = await node.addText(text);
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({'key': item.key}));
  }

  /// [req]'s body, for a reader that may stop early. It is claimed at once
  /// and paused: dart:io reads a body nobody has claimed to its end before
  /// it lets any answer out, so a 413 for a 100 GB upload would first take
  /// the 100 GB. Cancelling only pauses it as well: a cancelled body
  /// destroys the connection on the spot, answer or no answer, while a
  /// paused one goes with the connection once the answer is out (a body
  /// left unread is never kept alive).
  static Stream<List<int>> _body(HttpRequest req) {
    final c = StreamController<List<int>>();
    final sub = req.listen(c.add, onError: c.addError, onDone: c.close)
      ..pause();
    c
      ..onListen = sub.resume
      ..onPause = sub.pause
      ..onResume = sub.resume
      ..onCancel = sub.pause;
    return c.stream;
  }
}

/// `attachment; filename="…"; filename*=UTF-8''…`: the plain form for old
/// browsers, with anything outside printable ASCII replaced, and the
/// RFC 5987 form every current one reads, which keeps the real name.
String _attachment(String name) {
  // By code point, so an emoji (two UTF-16 units) becomes one `_`.
  final plain = name.replaceAll(
    RegExp(r'[^\x20-\x7e]|["\\]', unicode: true),
    '_',
  );
  // encodeComponent leaves `!'()*` alone; 5987 wants them encoded.
  final star = Uri.encodeComponent(name).replaceAllMapped(
    RegExp(r"[!'()*]"),
    (m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}',
  );
  return "attachment; filename=\"$plain\"; filename*=UTF-8''$star";
}

const _manifest = {
  'name': 'plop',
  'short_name': 'plop',
  'start_url': '/',
  'display': 'standalone',
  'background_color': '#0A0A0A',
  'theme_color': '#0A0A0A',
  'icons': [
    {'src': '/icon.png', 'sizes': '512x512', 'type': 'image/png'},
    {'src': '/icon.png', 'sizes': '1024x1024', 'type': 'image/png'},
  ],
};

/// A 1x1 black PNG, for a host that was never handed the app's icon.
final _blackPixel = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xde, 0x00, 0x00, 0x00, //
  0x0c, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x60, 0x60, 0x00, //
  0x00, 0x00, 0x04, 0x00, 0x01, 0xc8, 0xea, 0xeb, 0xf9, 0x00, 0x00, 0x00, //
  0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

// The page. One file, no build step, nothing fetched from outside the LAN.
// Served over plain http, so the browser gives it no secure-context APIs
// (navigator.share, navigator.clipboard, install prompts): copying goes
// through execCommand inside the tap, images open full-screen to be held
// and saved, other files download, and share() is used only where a
// browser does offer it. `{{name}}` is this device's name.
const _page = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#0A0A0A">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="plop">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/icon.png">
<link rel="icon" href="/icon.png">
<title>plop · {{name}}</title>
<style>
:root{--bg:#0a0a0a;--text:#ededed;--dim:#a1a1a1;--faint:#7a7a7a;--line:rgba(255,255,255,.08);--border:rgba(255,255,255,.14);--pressed:rgba(255,255,255,.09);--warn:#e5484d}
*{box-sizing:border-box;margin:0;padding:0}
html,body{background:var(--bg);color:var(--text);font:16px/1.3 ui-monospace,"SF Mono",Menlo,monospace;-webkit-text-size-adjust:100%;-webkit-tap-highlight-color:transparent}
body{min-height:100vh;min-height:100dvh;display:flex;flex-direction:column;padding:0 env(safe-area-inset-right) 0 env(safe-area-inset-left)}
button{font:inherit;color:inherit;background:none;border:0;cursor:pointer;touch-action:manipulation}
header{display:flex;align-items:center;gap:8px;padding:calc(12px + env(safe-area-inset-top)) 16px 12px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:1}
h1{font-size:16px;font-weight:500;flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
h1 span{color:var(--dim);font-weight:400}
.off h1 span{color:var(--warn)}
.btn{padding:6px 12px;border:1px solid var(--border);border-radius:6px;line-height:1.2;white-space:nowrap}
.btn:active{background:var(--pressed)}
#list{flex:1;display:flex;flex-direction:column}
.row{flex:none;display:flex;align-items:center;gap:12px;padding:14px 12px 14px 16px;position:relative;cursor:pointer;user-select:none;-webkit-user-select:none}
.row:active{background:var(--pressed)}
.main{flex:1;min-width:0}
.name{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.meta{font-size:13px;color:var(--dim);margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.time{color:var(--dim);font-variant-numeric:tabular-nums;min-width:48px;text-align:right}
.time.ending{color:var(--warn)}
.x{color:var(--dim);font-size:20px;line-height:1;padding:8px 10px;margin:-8px -4px}
.x:active{color:var(--text)}
.bar{position:absolute;left:0;right:0;bottom:0;height:1px;background:var(--line)}
.bar i{display:block;height:1px;width:100%;background:var(--faint);transition:width 1s linear}
.bar.live i{background:var(--text);transition:none}
.empty{flex:1;display:flex;align-items:center;justify-content:center;text-align:center;color:var(--faint);font-size:13px;line-height:1.7;padding:32px}
#hint{display:none;align-items:center;gap:8px;margin-top:auto;padding:12px 12px calc(12px + env(safe-area-inset-bottom)) 16px;border-top:1px solid var(--line);color:var(--dim);font-size:13px}
#hint.on{display:flex}
#hint span{flex:1}
#hint b{color:var(--text);font-weight:400}
#toast{position:fixed;left:50%;bottom:calc(24px + env(safe-area-inset-bottom));transform:translateX(-50%);max-width:calc(100vw - 32px);padding:8px 12px;background:#161616;border:1px solid #2a2a2a;border-radius:8px;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;opacity:0;transition:opacity .15s;pointer-events:none;z-index:3}
#toast.on{opacity:1}
#sheet,#view{display:none;position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:2}
#sheet.on{display:flex;align-items:flex-end;justify-content:center}
#sheet form{width:100%;max-width:560px;padding:16px 16px calc(16px + env(safe-area-inset-bottom));background:#111;border:1px solid #2a2a2a;border-bottom:0;border-radius:12px 12px 0 0;display:flex;flex-direction:column;gap:12px}
textarea{width:100%;min-height:120px;padding:10px;font:inherit;color:var(--text);background:var(--bg);border:1px solid var(--border);border-radius:6px;resize:none;outline:none}
textarea:focus{border-color:var(--dim)}
.actions{display:flex;justify-content:flex-end;gap:8px}
.ghost{color:var(--dim);padding:6px 12px}
#sheet.show .btn{display:none}
#view.on{display:flex;flex-direction:column;background:var(--bg)}
#view img{flex:1;min-height:0;width:100%;object-fit:contain;padding:calc(16px + env(safe-area-inset-top)) 16px 16px}
#view .foot{display:flex;align-items:center;gap:12px;padding:12px 16px calc(16px + env(safe-area-inset-bottom));color:var(--dim);font-size:13px}
#view .foot span{flex:1}
input[type=file]{display:none}
</style>
</head>
<body>
<header>
<h1>plop <span>· {{name}}</span></h1>
<button class="btn" id="install" hidden>install</button>
<button class="btn" id="paste">paste</button>
<button class="btn" id="add" aria-label="add files">+</button>
<input type="file" id="file" multiple>
</header>
<div id="list"></div>
<div id="hint"><span>add plop to your home screen: <b>share ▸ add to home screen</b></span><button class="x" id="hintx" aria-label="dismiss">×</button></div>
<div id="sheet"><form id="textform"><textarea id="text" placeholder="paste or type, then plop"></textarea><div class="actions"><button type="button" class="ghost" id="cancel">cancel</button><button type="submit" class="btn">plop</button></div></form></div>
<div id="view"><img id="pic" alt=""><div class="foot"><span>press and hold the picture to save it</span><button class="ghost" id="dl">download</button><button class="ghost" id="close">close</button></div></div>
<div id="toast"></div>
<script>
'use strict';
const $ = id => document.getElementById(id);
const list = $('list'), sheet = $('sheet'), ta = $('text'), view = $('view');
const store = {
  get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
};
// Items this browser put up, by key, with when: they get a × here, and a
// key is forgotten only once the shelf has gone a while without it.
const mine = new Map(Object.entries(JSON.parse(store.get('plop.mine') || '{}')));
const seen = new Map();  // key -> {expires, total}: countdowns between polls
const blobs = new Map(); // key -> Blob fetched for share(), kept for a retry
let items = [], uploads = [], seq = 0, sig = '', polling = false, again = false, pollTimer, toastTimer, viewing;

const esc = s => String(s).replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'})[c]);
const saveMine = () => store.set('plop.mine', JSON.stringify(Object.fromEntries(mine)));
const url = it => '/web/items/' + it.key;
const fileName = it => it.kind === 'folder' ? it.name + '.zip' : it.kind === 'text' ? 'text.txt' : it.name;
const isImage = it => it.kind === 'file' && /^image\//.test(it.mime);
const canShare = f => !!(navigator.share && navigator.canShare && navigator.canShare({files: [f]}));

function size(n) {
  const u = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  while (n >= 1024 && i < 3) { n /= 1024; i++; }
  return (i === 0 || n >= 10 ? Math.round(n) : n.toFixed(1)) + ' ' + u[i];
}
function clock(ms) {
  const s = Math.max(0, Math.ceil(ms / 1000));
  if (s >= 3600) return Math.floor(s / 3600) + 'h' + String(Math.floor(s % 3600 / 60)).padStart(2, '0');
  return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
}
function toast(msg) {
  const el = $('toast');
  el.textContent = msg;
  el.classList.add('on');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('on'), Math.max(1800, 1800 + 40 * (msg.length - 20)));
}

// ------------------------------------------------------------- the shelf

async function poll() {
  if (polling) { again = true; return; }
  clearTimeout(pollTimer);
  if (document.hidden) return; // resumed by visibilitychange
  polling = true;
  try {
    const r = await fetch('/web/shelf', {cache: 'no-store'});
    if (!r.ok) throw new Error(r.status);
    items = await r.json();
    const now = Date.now(), live = new Set();
    for (const it of items) {
      live.add(it.key);
      const s = seen.get(it.key) || {total: it.ttlMs};
      s.expires = now + it.ttlMs;
      seen.set(it.key, s);
    }
    for (const k of [...seen.keys()]) if (!live.has(k)) { seen.delete(k); blobs.delete(k); }
    for (const [k, t] of mine) if (!live.has(k) && now - t > 10000) mine.delete(k);
    saveMine();
    document.body.classList.remove('off');
    render();
  } catch (e) {
    document.body.classList.add('off');
  }
  polling = false;
  if (again) { again = false; return poll(); }
  pollTimer = setTimeout(poll, 2000);
}
document.addEventListener('visibilitychange', () => { if (!document.hidden) poll(); });
addEventListener('pageshow', poll);

function frac(key) {
  const s = seen.get(key);
  return s && s.total ? Math.max(0, Math.min(1, (s.expires - Date.now()) / s.total)) : 0;
}
// Rebuilds the rows only when the shelf itself changed, so a tap never
// lands on a row that was swapped out under it; tick() keeps the clocks.
function render() {
  const next = JSON.stringify([uploads.map(u => u.id), items.map(it => [it.key, it.name, it.from, mine.has(it.key)])]);
  if (next === sig) return tick();
  sig = next;
  const rows = [];
  for (const u of uploads) {
    rows.push('<div class="row" data-up="' + u.id + '"><div class="main"><div class="name">' + esc(u.name) +
      '</div><div class="meta">' + size(u.size) + ' · uploading</div></div><div class="time">' + u.pct +
      '%</div><div class="bar live"><i style="width:' + u.pct + '%"></i></div></div>');
  }
  for (const it of items) {
    const meta = [it.kind === 'text' ? null : size(it.size), mine.has(it.key) ? 'you' : it.from].filter(Boolean).join(' · ');
    rows.push('<div class="row" data-key="' + esc(it.key) + '"><div class="main"><div class="name">' + esc(it.name) +
      '</div><div class="meta">' + esc(meta) + '</div></div>' +
      (mine.has(it.key) ? '<button class="x" data-x="' + esc(it.key) + '" aria-label="remove">×</button>' : '') +
      '<div class="time"></div><div class="bar"><i></i></div></div>');
  }
  list.innerHTML = rows.length ? rows.join('') :
    '<div class="empty">nothing here yet<br>add something or drop it on any device with plop</div>';
  tick();
}
function tick() {
  const now = Date.now();
  for (const el of list.querySelectorAll('[data-key]')) {
    const s = seen.get(el.dataset.key);
    if (!s) continue;
    const left = s.expires - now, t = el.querySelector('.time'), bar = el.querySelector('.bar');
    t.textContent = clock(left);
    t.classList.toggle('ending', left < 10000);
    if (!bar.classList.contains('live')) bar.firstChild.style.width = frac(el.dataset.key) * 100 + '%';
  }
}
setInterval(tick, 1000);

list.addEventListener('click', e => {
  const x = e.target.closest('[data-x]');
  if (x) return remove(x.dataset.x);
  const row = e.target.closest('[data-key]');
  if (row) grab(row.dataset.key);
});

// ------------------------------------------------------------- grabbing

async function grab(key) {
  const it = items.find(i => i.key === key);
  if (!it) return;
  if (it.kind === 'text') return copyText(it);
  const name = fileName(it);
  if (canShare(new File([], name, {type: it.mime}))) {
    let blob = blobs.get(key);
    if (!blob) {
      try { blob = await fetchBlob(it); } catch (e) { return toast("couldn't fetch " + it.name); }
      blobs.set(key, blob);
    }
    try {
      await navigator.share({files: [new File([blob], name, {type: it.mime})]});
    } catch (e) {
      // The tap's permission can run out while a big item downloads; the
      // bytes are kept, so the next tap shares right away.
      if (e.name !== 'AbortError') toast('ready · tap again to share');
    }
  } else if (isImage(it)) {
    show(it);
  } else {
    download(it);
  }
}
async function fetchBlob(it) {
  const r = await fetch(url(it));
  if (!r.ok) throw new Error(r.status);
  if (!r.body) return r.blob();
  const bar = list.querySelector('[data-key="' + CSS.escape(it.key) + '"] .bar');
  const total = +r.headers.get('content-length') || it.size, reader = r.body.getReader(), chunks = [];
  let got = 0;
  if (bar) bar.classList.add('live');
  try {
    for (;;) {
      const {done, value} = await reader.read();
      if (done) break;
      chunks.push(value);
      got += value.length;
      if (bar && total) bar.firstChild.style.width = got / total * 100 + '%';
    }
  } finally {
    if (bar) bar.classList.remove('live');
  }
  return new Blob(chunks, {type: it.mime});
}
function download(it) {
  const a = document.createElement('a');
  a.href = url(it);
  a.download = fileName(it);
  document.body.appendChild(a);
  a.click();
  a.remove();
}
// Full screen, where a long press offers to save it to the photo library.
function show(it) {
  viewing = it;
  $('pic').src = url(it);
  view.classList.add('on');
}
function closeView() { view.classList.remove('on'); $('pic').removeAttribute('src'); viewing = null; }
$('close').onclick = closeView;
$('dl').onclick = () => { if (viewing) download(viewing); };

// Copies inside the tap when the text came with the list; the clipboard
// API, where a browser gives it to a plain http page, and execCommand,
// which the rest take only from inside a user gesture.
function copyNow(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(() => toast('copied'), () => copyLegacy(text) ? toast('copied') : showSheet(text, true));
    return;
  }
  copyLegacy(text) ? toast('copied') : showSheet(text, true);
}
function copyLegacy(text) {
  const el = document.createElement('textarea');
  el.value = text;
  el.setAttribute('readonly', '');
  el.style.cssText = 'position:fixed;top:0;left:0;opacity:0;font-size:16px';
  document.body.appendChild(el);
  el.focus();
  el.select();
  el.setSelectionRange(0, text.length);
  let ok = false;
  try { ok = document.execCommand('copy'); } catch (e) {}
  el.remove();
  return ok;
}
async function copyText(it) {
  if (typeof it.text === 'string') return copyNow(it.text);
  try {
    const r = await fetch(url(it));
    if (!r.ok) throw new Error(r.status);
    copyNow(await r.text());
  } catch (e) {
    toast("couldn't fetch that");
  }
}

// ------------------------------------------------------------- adding

$('add').onclick = () => $('file').click();
$('file').onchange = () => { for (const f of $('file').files) upload(f); $('file').value = ''; };
addEventListener('dragover', e => e.preventDefault());
addEventListener('drop', e => { e.preventDefault(); for (const f of e.dataTransfer.files) upload(f); });
addEventListener('paste', e => {
  if (sheet.classList.contains('on')) return;
  const files = [...e.clipboardData.files];
  if (files.length) { e.preventDefault(); files.forEach(upload); return; }
  const t = e.clipboardData.getData('text');
  if (t.trim()) { e.preventDefault(); sendText(t); }
});
addEventListener('keydown', e => { if (e.key === 'Escape') { closeSheet(); closeView(); } });

// XHR rather than fetch: only XHR reports upload progress.
function upload(file) {
  const u = {id: ++seq, name: file.name || 'file', size: file.size, pct: 0};
  uploads.push(u);
  render();
  const x = new XMLHttpRequest();
  x.open('POST', '/web/items?name=' + encodeURIComponent(u.name));
  x.upload.onprogress = e => {
    if (!e.lengthComputable) return;
    u.pct = Math.round(e.loaded / e.total * 100);
    const el = list.querySelector('[data-up="' + u.id + '"]');
    if (el) {
      el.querySelector('.time').textContent = u.pct + '%';
      el.querySelector('.bar i').style.width = u.pct + '%';
    }
  };
  const done = () => { uploads = uploads.filter(v => v !== u); render(); };
  x.onload = () => {
    done();
    if (x.status !== 200) return toast(x.status === 413 ? u.name + ' is too big' : "couldn't upload " + u.name);
    try { mine.set(JSON.parse(x.responseText).key, Date.now()); saveMine(); } catch (e) {}
    poll();
  };
  x.onerror = () => { done(); toast("couldn't upload " + u.name); };
  x.send(file);
}
async function sendText(t) {
  if (!t.trim()) return;
  closeSheet();
  try {
    const r = await fetch('/web/text', {method: 'POST', headers: {'content-type': 'text/plain;charset=utf-8'}, body: t});
    if (!r.ok) throw new Error(r.status);
    mine.set((await r.json()).key, Date.now());
    saveMine();
    poll();
  } catch (e) {
    toast("couldn't send that");
  }
}
async function remove(key) {
  const r = await fetch('/web/items/' + key, {method: 'DELETE'}).catch(() => null);
  if (!r || !r.ok) return toast("couldn't remove that");
  mine.delete(key);
  saveMine();
  items = items.filter(i => i.key !== key);
  seen.delete(key);
  render();
  poll();
}

// The clipboard is read where the browser allows (it asks first); the
// sheet is for everywhere else. In the sheet a paste plops at once, as the
// button says; typed text waits for "plop".
function showSheet(text, readonly) {
  ta.value = text || '';
  ta.readOnly = !!readonly;
  sheet.classList.toggle('show', !!readonly);
  $('cancel').textContent = readonly ? 'done' : 'cancel';
  sheet.classList.add('on');
  ta.focus();
  if (readonly) ta.select();
}
function closeSheet() { sheet.classList.remove('on'); ta.value = ''; }
$('cancel').onclick = closeSheet;
sheet.onclick = e => { if (e.target === sheet) closeSheet(); };
$('textform').onsubmit = e => { e.preventDefault(); if (!ta.readOnly) sendText(ta.value); };
ta.addEventListener('paste', () => {
  if (ta.readOnly || ta.value) return;
  setTimeout(() => sendText(ta.value), 0);
});
$('paste').onclick = () => {
  const read = navigator.clipboard && navigator.clipboard.readText ? navigator.clipboard.readText() : Promise.reject();
  read.then(t => t && t.trim() ? sendText(t) : showSheet(''), () => showSheet(''));
};

// ------------------------------------------------------------- home screen

const ios = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const standalone = navigator.standalone || matchMedia('(display-mode: standalone)').matches;
if (ios && !standalone && !store.get('plop.hint')) $('hint').classList.add('on');
$('hintx').onclick = () => { $('hint').classList.remove('on'); store.set('plop.hint', '1'); };
let installEvt;
addEventListener('beforeinstallprompt', e => { e.preventDefault(); installEvt = e; $('install').hidden = false; });
$('install').onclick = () => { if (installEvt) installEvt.prompt(); installEvt = null; $('install').hidden = true; };

render();
poll();
</script>
</body>
</html>
''';
