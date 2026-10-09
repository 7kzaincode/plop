# plop protocol, v1

Every running app is a node. There is no server. Each node serves only the
items it originated, and mirrors other nodes' items locally. A desktop node
also serves a web page for browsers (the [web shelf](#web-shelf)), which is
not part of the node-to-node protocol.

## Discovery

mDNS / DNS-SD (Bonjour) service type `_plop._tcp`, advertising the node's HTTP
port. TXT attributes:

| key    | value                                                                 |
|--------|-----------------------------------------------------------------------|
| `id`   | Random node id, generated at launch. A node ignores its own id.       |
| `v`    | Protocol version, `1`. A node ignores services advertising any other value, so a newer version is invisible to v1 nodes unless it also advertises `v=1`. |
| `name` | Human-readable device name, shown as "from" on the shelf.             |
| `ips`  | Comma-separated IPv4 addresses, fallback when the resolved host is unusable. |
| `c`    | Private mode only: the circle hint (below). |
| `pair` | `1` while the node's pairing is open (below). |

A node in [private mode](#private-mode) advertises `v=p1` and `c`, leaves
`name` out unless its pairing is open, and uses `plop-<first 8 digits of
its id>` as its service name rather than its device name. v1 nodes ignore
it, as they ignore any `v` but `1`.

Address choice: resolved IPv4 host addresses first, then `ips`, then routable
IPv6 addresses. IPv6 link-local addresses are skipped (they need a scope id
that URIs do not carry well), and `.local` hostnames are not relied on for
sockets. A node listens on IPv6 and IPv4 both where the host allows it.

A later advertisement carrying a known `id` replaces that peer's addresses and
port. A node may re-register after a suspend (iOS drops the registration),
keeping its id and, when it can, its port.

## HTTP routes

Plain HTTP on the advertised port. Only items this node originated are served.

Every request, on every route, must name the node by address: its `Host`
header is an IP literal (IPv6 in brackets), `localhost` or a name under it,
or a `.local` name, optionally with a port. Anything else gets `421` before
any routing and without the body being read. A web page elsewhere can point
its own domain at a LAN address (DNS rebinding) and the browser then treats
this node as that site; this is what stops it. Nodes always connect by IP.

### `GET /v1/items`

The caller sets `X-Plop-Node: <its node id>`. A node id is a plain token
under the same rule as an item `id` below; a receiver treats a header that
breaks it as absent, on every route. A node remembers when each peer last
reached it; a peer it can reach that never reaches it back is shown as
one-way (usually a firewall on this side). A peer that keeps reaching it
after its own polls of that peer started failing is shown as unreachable
(usually a firewall on that side); one that went quiet both ways at once
has simply gone, a phone locking, say, and is not.

```json
[
  {"id": "9f2c…", "name": "photo.png", "size": 102400,
   "mime": "image/png", "kind": "file", "ttlMs": 87412}
]
```

- Entries are oldest first; a receiver orders its shelf by when it first
  saw each item.
- `id` is 1–64 characters from `A-Z a-z 0-9 _ -` (plop sends 16 hex
  digits). Items with any other id are ignored.
- `size` is 0 to the receiver's cap (100 GB); items outside that are
  ignored. A `name` longer than 255 UTF-16 units is cut to the whole
  characters (grapheme clusters) that fit, never inside an emoji. Control
  characters, bidi embeddings, overrides and isolates (U+202A–202E,
  U+2066–2069) and line or paragraph separators in it are shown and saved
  as `_`, so `fdp.exe` cannot pass for `exe.pdf`, nor `pdf\n.exe` for
  `pdf`. Other invisible marks (LRM, RLM, ALM, zero-width space, word
  joiner, BOM) are dropped; ZWJ and ZWNJ are kept. `mime` is optional and
  defaults to `application/octet-stream`, as does one that is not a plain
  `type/subtype` (letters, digits, `.+_-`); of its parameters only a plain
  `charset` is kept.
- `kind` is `file`, `text` or `folder`. For `text`, the bytes are UTF-8 and
  `name` is a short label (the first line). For `folder`, the bytes are a zip
  of the folder's contents (stored, not compressed) and `name` is the folder
  name. Entries carry a mode of 0755 (folders, and files executable on the
  sender) or 0644; a receiver restores the executable bit and nothing else. A link inside the folder is sent as a
  copy of its target if that is also inside the folder, and left out if it
  leads outside. A receiver writes only plain files and folders: entries that
  are symlinks, or whose path contains `..`, are skipped, and each name
  segment is sanitised as a single file's name is. It refuses a zip with
  compressed entries, or one that unpacks to more than its own size
  (overlapping entries); either is a bomb, since stored content can do
  neither. It refuses encrypted entries too (general-purpose bit 0 in
  either header). Each entry's headers are checked before any of its
  content is read. A node that does not know a kind treats it as `file`.
- `ttlMs` is the time **remaining**, in milliseconds. Never an absolute time:
  clocks on a LAN disagree. The sender picks the lifetime (2 minutes by
  default); it can differ per item. A receiver clamps it to 24 hours, and
  ignores entries with `ttlMs` ≤ 0, which are already expired.
- `ageMs` (optional) is how long ago the sender put the item up, in
  milliseconds, so a receiver can tell something put up just now from
  something that waited while it was asleep or away: copying arrivals to the
  clipboard skips what was already over 30 s old when first seen. Older
  nodes leave it out; a receiver treats it, or a negative or absurd value, as
  unknown.

### `GET /v1/items/{id}`

The item's bytes, with `Content-Length` and `Content-Type`. `404` once expired
or unknown.

### `POST /v1/items/{id}/received`

No body. Sent to an item's origin once the caller holds a complete copy of
it (an eager copy or a save), with `X-Plop-Node: <its node id>`. The origin
records which peers have the item, so the sender can see it arrived. Only
the receiver knows a transfer finished: a sender cannot tell a peer that got
everything from one that hung up. Responds `204`; a node that predates this
route answers `404`, which the caller ignores.

### `POST /v1/changed`

No body. Means "my list changed, re-fetch it". The sender sets header
`X-Plop-Node: <its node id>` so the receiver re-fetches just that peer; without
the header the receiver re-fetches all peers. Responds `204`.

## Sync behaviour

- On peer discovered: fetch its list immediately, then poll every 3 s as a
  fallback (nudges can be lost).
- On local add or expiry: nudge all known peers.
- On receiving an item: start a local timer for `ttlMs`; delete the copy when
  it ends. The timer is not reset by later polls.
- An item that disappears from its origin's list is dropped.
- Items at or under 25 MB are downloaded as soon as they are seen ("eager
  copy"), so they survive the sender's app being suspended. Larger items are
  fetched on tap. At most 4 eager copies run at once, at most 2 of them
  from any one sender, smallest first. One still running after 30 s plus
  a second per 256 KB is dropped (a tap has no such limit). One that fails
  or is dropped is tried again on later polls, 3 tries in all, after which
  the item is fetched on tap like a large one.
- Items over 100 GB are refused, both locally and from peers.
- A download that has started is allowed to finish after the item expires
  (the origin keeps streaming an open file), so large transfers are not cut
  off. A new `GET` after expiry still gets `404`.
- A download someone asked for (a tap, or an eager copy a tap has joined)
  whose body breaks off (15 s without a byte, or the connection closed or
  reset) starts over once, from the first byte, if the receiver's latest
  poll of the origin was answered when it broke off: what stopped was most
  likely the receiver, a phone that put the app in the background, say.
  Otherwise, or if it breaks off again, it fails. A refusal or a wrong
  byte count is never tried again.
- Mirrored copies are never re-served to other nodes. Only the origin serves
  an item over `/v1`. (The web shelf below hands mirrors to browsers; no
  node ever asks it for one.)
- Peer gone (mDNS lost event, or 3 failed polls in a row): keep fully copied
  items until their timers end; drop items that were never copied, once
  any transfer of them still running has ended.
- Downloads are written to `<name>.part` and renamed when complete and the
  byte count matches `size`. On any failure (more or fewer bytes, a stall, a
  full disk) the `.part` file is deleted.

## Storage

Each node uses one temp directory, wiped on launch. Owned bytes live at
`<dir>/<originId>/<itemId>/<name>`. A file the user picked on this device is
served from where it is and is never deleted by the app. When such a file is
gone, or its size or modification time changed since it was added, the item
leaves the shelf the next time it would be listed or served, over `/v1` or
the web shelf, rather than hand out something other than what was shared.

## Web shelf

A one-page web app for devices without plop (iPhones, mostly), on the same
port as `/v1`. Off unless the node enables it: the desktop apps do, phones do
not, and the headless node does with `--web`. A disabled node answers `404`
on all of these routes.

**Port.** The desktop app asks for the port it remembers, else `7567`
(p-l-o-p on a phone keypad), else any free port. It remembers the first port
it serves on and keeps it: a launch that finds that port taken uses another
for that run only, so an address saved on a phone's home screen works again
on the next launch. A remembered value that is not a port (1–65535) counts as
none. The addresses shown are `http://<ipv4>:<port>/` for each address, best
first (private LAN ranges on real interfaces, then other addresses, then VPN,
VM and container interfaces, then 100.64/10, then 169.254/16), and
`http://<host>.local:<port>/` (the name mDNS answers for: on macOS the
Sharing settings' local host name) where other devices can count on it: first
on macOS, first on Linux when a lookup of it from the machine itself finds
one of its addresses, second on Windows under the same check (a Public
network profile can keep other devices' queries out even then), and not at
all otherwise.

**Not part of the protocol.** No node calls these routes, so the rule that
mirrors are never re-served between nodes holds. A browser on this page is a
user of this device, not a peer: it can grab whatever this device's shelf
shows, mirrors included, as a tap in the window could. What it uploads
becomes this node's own item and travels to peers over `/v1` like any other.

### Routes

Every `POST` and `DELETE` (anything but `GET` and `HEAD`) must carry
`X-Plop-Web: 1`, and a request with an `Origin` header must come from
`http://<its Host>`; either failing is `403`, answered without reading the
body. A form or a no-cors `fetch` from another site cannot set a header of
its own, and this server answers no CORS preflight, so other pages a phone
or computer on the LAN visits cannot write here.

| route | answer |
|---|---|
| `GET /` | The page: inline HTML, CSS and JS, nothing fetched from elsewhere. `Cache-Control: max-age=60`. |
| `GET /manifest.webmanifest` | Web app manifest: `plop`, standalone, `#0A0A0A`, one icon at `/icon.png` (1024x1024), `start_url` `/`. |
| `GET /icon.png` | The app icon (a 1x1 black PNG on a node that was given none). |
| `GET /web/shelf` | Every item the node knows, own and mirrored, newest first (see below). |
| `GET /web/items/{originId}/{id}` | The bytes, with `Content-Type`, `Content-Length`, `Content-Security-Policy: sandbox` (nothing served here runs as a page of this origin) and `Content-Disposition: attachment; filename="…"; filename*=UTF-8''…` (a folder's zip as `<name>.zip`, text as `text.txt`). A mirror not copied yet is fetched from its origin first. `404` once gone; `502` if the origin cannot be reached. `HEAD` gives the same headers from what the shelf knows, `Content-Length` being the item's size, and fetches nothing. |
| `POST /web/items?name=<name>` | Raw file body, streamed to disk as this node's own item. `200 {"key": "<originId>/<id>", "token": "<32 hex digits>"}`; the token is what takes it back (the page keeps it in `localStorage`). The name loses C0/C1 controls and Unicode bidi marks (embeddings, overrides, isolates, LRM, RLM, ALM), is trimmed, and is cut to 255 UTF-16 units with an ellipsis before its extension. `400` without a name (or with none left) or for a body that ends short of its `Content-Length`; `413` past 8 GB (or the node's item cap, if lower); `507` past what the page's items still on the shelf may add up to (16 GB, 200 items). Both are answered before any of the body is read when `Content-Length` says so, else where the body crosses the line, and the connection is closed. `408` when the body stalls for 30 s. |
| `POST /web/text` | UTF-8 body, up to 1 MB, as a text item. `200 {"key": …, "token": …}`; `400` if blank; `413` if longer; `507` and `408` as above. |
| `DELETE /web/items/{originId}/{id}` | Takes back an item a browser put up: `X-Plop-Token` must be the token its upload was answered with (`204`). `403` without it or for anything else: a mirror, another browser's upload, or what this device's own user shared. `404` if unknown. |

Everything under `/web/` carries `Cache-Control: no-store`. At most 4
uploads (files and texts together) run at once; past that the answer is
`503` with `Retry-After: 2`, and the page sends two at a time and tries a
refused one again a few times.

`GET /web/shelf` entries:

```json
{"key": "9f2c…/1a7e…", "name": "photo.png", "size": 102400,
 "mime": "image/png", "kind": "file", "ttlMs": 87412, "from": "Zain's MacBook",
 "ready": true, "receivedBy": 1, "text": "…"}
```

`from` is the origin's device name (this node's own name for its own items).
`ready` says whether the bytes are on this node yet; `progress` (0 to 1) is
there while this node copies them over from the origin, which for an item
over the eager-copy size starts only when someone asks for it, and the page
shows such a row as copying. `receivedBy` (own items only) counts the peers
holding a copy. `text` is a ready text item's content when it is at most 64
KB, so the page can copy it inside the tap: on plain HTTP a browser gives the
page no asynchronous clipboard, and the fallback it has works only within the
user's gesture. Inline texts add up to 1 MB per answer at most, newest first;
the page fetches the rest on a tap.

The page takes C0/C1 controls and bidi marks out of `name` and `from` before
showing them, as the upload route does, so a peer cannot make
`invoice<U+202E>fdp.exe` read as `invoiceexe.pdf`; download file names are
cleaned the same way.

### Trust

There is no authentication, as on `/v1` outside private mode (the web
shelf is off while private mode is on), and the web shelf gives anyone who can reach this port on the network
more than `/v1` gives a peer. A browser is not needed for any of it; `curl`
will do.

- **Everyone's items, through this device.** `/v1` serves only a node's own
  items. The web shelf hands out everything this device's shelf shows,
  mirrors included, and copies a mirror over from its origin on request. So
  whatever any plop device on the network shares can be downloaded from a
  desktop by anyone on the LAN, big items nobody has copied yet included.
  The shelf list also carries small texts (up to 64 KB each, 1 MB in all)
  from every device.
- **Writing to this device's disk.** An upload is stored in this device's
  temp folder as its own item until it expires. The limits above bound it:
  8 GB per upload, 16 GB and 200 items from the page on the shelf at once,
  4 uploads at a time, 30 s for a stalled one.
- **Putting items on every device.** What is uploaded travels to every peer
  as this desktop's own item, under its name, and peers copy what is small
  enough at once. A receiver cannot tell it came from a browser.
- **Removing.** Only what a browser uploaded, and only with the token that
  upload was answered with: never what this device's user shared, and
  never a mirror.

What the web shelf does keep out is other web pages that a phone or
computer on the LAN visits. A page cannot reach this port through a domain
of its own (DNS rebinding: the `Host` check answers `421`), cannot write
through a form or a no-cors `fetch` (`X-Plop-Web` and the `Origin` check),
and cannot run script as this page by getting a peer to share an HTML file
(`Content-Security-Policy: sandbox` on every download, and every `mime`
checked before it reaches a header).

Being plain HTTP also means browsers deny the page their secure-context APIs
(share sheet, clipboard, install prompt), so it falls back: text copies
through a selection, images open full-screen to be saved with a long press,
and other files download.

## Private mode

Optional, off by default. Only devices that were paired with each other
see each other, every `/v1` request is signed and every answer sealed.
A node with it off behaves exactly as above. The keys and the maths live
in `packages/core/lib/src/circle.dart`, `pairing.dart` and
`private_link.dart`, which know nothing of the LAN; `private_mode.dart`
carries them over HTTP.

Everything is pure Dart: X25519 from `package:cryptography`, ChaCha20 from
`package:cryptography`, SHA-256 and HMAC-SHA256 from `package:crypto`, and
HKDF-SHA256 (RFC 5869) on top of HMAC. Bodies use ChaCha20 then
HMAC-SHA256 (encrypt-then-MAC) rather than ChaCha20-Poly1305: the
pure-Dart Poly1305 runs at under 40 MB/s, which would cap a transfer below
a good Wi-Fi link; ChaCha20 runs near 135 MB/s and HMAC-SHA256 near
115 MB/s on an M-series Mac, about 60 MB/s per side together. Encoding:
keys and MACs are base64url without padding.

### Keys

- **Device key:** an X25519 key pair made on first launch and kept in
  `private.json` beside the settings (mode 0600 on macOS and Linux; per-user
  app data on Windows; the app sandbox on phones). Its public half, in
  base64url, is the device's id in a circle.
- **Circle:** a random 32-byte key, an `epoch` (bumped on every change; of
  two versions the higher wins) and the members' public keys and names.
  From the key, with HKDF-SHA256 and no salt:
  - `hint` = first 16 hex digits of HMAC-SHA256(key, `plop-circle`);
  - `authKey` = HKDF(key, info `plop auth v1`);
  - `bodyKey` = HKDF(key, info `plop body v1`).

### Discovery

A private node advertises `v=p1` and `c=<hint>` (see Discovery). A node
syncs only with peers whose hint equals its own, or which have none when
it has none: public nodes see public nodes, private ones their circle,
and two circles never meet. A node that switches mode advertises afresh
under its other service name with the same id.

### Signed requests

Every `/v1` request to a private node (lists, bytes, `received`,
`changed`) carries

    X-Plop-Auth: v1.<ms since epoch>.<nonce: 32 hex digits>.<mac>

where `mac` = HMAC-SHA256(authKey, `plop-auth-v1\n<METHOD>\n<path[?query]>\n<X-Plop-Node or empty>\n<ms>\n<nonce>`).
The server answers `401`, without reading the body, if it is missing,
does not verify, is more than 60 s from its own clock either way, or
reuses a nonce it accepted in the last two minutes (it remembers up to
8192). Pairing routes are the one exception, and only while pairing is
open.

### Sealed answers

The answer to a signed request (`GET /v1/items`, `GET /v1/items/{id}`,
`GET /v1/circle`) is a sealed stream, `Content-Type:
application/octet-stream`, with an exact `Content-Length`:

    "PLS1" | salt (16 random bytes) | frame | frame | ... | final frame

The stream's keys are HKDF(bodyKey, salt, info `plop stream v1\n` +
context, 64 bytes): the first 32 for ChaCha20, the last 32 for
HMAC-SHA256. The context is `answer\n<request nonce>\n<METHOD>\n<path>`,
so an answer recorded once cannot be passed off as the answer to another
request. A frame is

    len (4 bytes, big-endian; top bit set on the last frame) | ciphertext (len bytes) | tag (32 bytes)

with at most 64 KiB of plaintext, ChaCha20 with a 12-byte nonce of four
zero bytes and the frame's number (from 0, 8 bytes big-endian), and tag =
HMAC-SHA256(macKey, nonce | 4-byte length of `len` (4) | `len` |
ciphertext). Every frame but the last is full, and the last may be
empty, so `n` bytes seal to `20 + (n div 65536 + 1) * 36 + n`. A reader
checks each tag before passing anything on, refuses a frame over 64 KiB
before reading it, and fails if frames come out of order, if the stream
ends without the last frame, or if anything follows it. A private list is
`{"name": <device name>, "items": [...]}`, since the name is not
advertised. Large files stream through frame by frame; nothing holds more
than a frame.

### Pairing

Both devices open pairing in the settings panel (two minutes, or until
the panel closes): they advertise `pair=1` and their name, and answer
`/v1/pair/*` unsigned. The user picks the other device on one of them,
the initiator A; B responds. JSON bodies, at most 16 KB:

| route | body | answer |
|---|---|---|
| `POST /v1/pair/hello` | `{"v":1,"pk":A,"name":…,"commit":SHA-256("plop pair commit v1"‖pkA‖nA),"circle":bool}` | `200 {"sid":…,"pk":B,"name":…,"nonce":nB,"circle":bool}`; `409` if B is busy with another exchange |
| `POST /v1/pair/reveal` | `{"sid":…,"nonce":nA}` | `204`, or `400` if nA does not match the commit |
| `POST /v1/pair/confirm` | `{"sid":…,"box":…}` | `202` until B's user answers, then `200 {"box":…}` or `403` if they said no |
| `POST /v1/pair/cancel` | `{"sid":…}` | `204`: A's user said no |

Nonces are 16 random bytes. Both sides show `code` = the first four bytes
of SHA-256(`plop pair code v1` ‖ pkA ‖ pkB ‖ nA ‖ nB), big-endian, mod
10⁶, as six digits, and ask the user whether the other screen shows the
same. A committed to nA before seeing nB, and B sent nB before learning
nA, so someone in the middle, who must run the exchange with each side
under its own key, cannot steer either number: the two match by chance
once in a million, and otherwise the users see different numbers.

On "match", A polls `confirm` every second. Each `box` is a sealed box
(below) under HKDF(X25519(A, B), salt nA‖nB, info `plop pair key v1` ‖
pkA ‖ pkB), context `pair confirm a` from A and `pair confirm b` from B,
holding `{"name":…,"circle":<circle or null>}`. The circle comes from A
if A is in one or neither is (A makes one), else from B; it already lists
both. The side that handed it over then sends it to the other members it
can reach (`/v1/circle/update`). When two devices pick each other at
once, the one whose public key sorts lower answers `409` and takes the
other's exchange instead.

A **sealed box** is `"PLB1" | salt (16) | ciphertext | tag (32)`, keys
HKDF(key, salt, info `plop box v1\n` + context, 64 bytes), nonce all zero
(each box has its own keys), tag over the nonce, `PLB1` and the
ciphertext as for a frame.

### Circle routes

Signed with the circle's key whether private mode is on or not; `401`
otherwise.

- `GET /v1/circle`: a sealed answer, `{"pk": <device key>, "epoch": n}`.
- `POST /v1/circle/update` `{"from": pk, "box": …}`: `box` is a sealed box
  under HKDF(X25519(sender, receiver), info `plop member box v1` ‖
  pk_from ‖ pk_to), context `circle update`, holding a circle. Accepted
  (`204`) if `from` is a member, the circle lists the receiver and its
  epoch is higher; `403`/`409` otherwise.
- `POST /v1/circle/leave` `{"from": pk}`: the sender left; it is taken
  off the list (`204`). The key stays: it was trusted, and left on its
  own.

**Forget** makes a new key and epoch without the device, and before
switching to it sends it with `update` to every member it can reach,
sealed to each one's own key (so the forgotten device, which knows the
old circle key, cannot read it even on the wire), signed under the old
key. A member that is off or away then keeps the old key, advertises the
old hint and sees nobody; the settings panel names it, and it has to be
paired again. Two devices that change the circle at the same moment
produce the same epoch, and the first to arrive wins at each member.

### Threat model and limits

Private mode is meant to keep other people on the same network (a café,
an office, a shared flat) from seeing, reading, changing or adding to
what your own devices pass around.

- **Protected:** item lists, names and bytes (encrypted and
  authenticated), who may list, fetch or nudge (signed requests),
  answers replayed or swapped, a body cut short or changed, a man in the
  middle at pairing (numeric comparison), a forgotten device (new key,
  sent sealed to each remaining device).
- **Not hidden:** that plop runs on a device, its addresses and port, its
  per-launch node id, the circle hint (constant for a key: devices of one
  circle can be told apart from other plop users, and recognised from day
  to day), traffic sizes and timing, status codes, and the device name for
  the two minutes pairing is open.
- **Trusted:** every device in the circle holds the same key and can do
  anything any other can, including claim another's node id. There is no
  per-device permission.
- **Not covered:** a device that is itself compromised; a user who taps
  "match" on numbers that differ; clocks more than a minute apart (every
  request is refused; automatic time fixes it); denial of service (anyone
  can still flood the port, or start pairing exchanges while pairing is
  open, though only one runs at a time).
- **Keys at rest** are as safe as the user's account: a plain file, 0600,
  not the OS keychain.

### Remote transports

Nothing in `circle.dart`, `pairing.dart` or `private_link.dart` assumes the
LAN: a request is a method, a path and a node id to sign; an answer is
bytes to seal with the request's nonce; pairing is three messages and a
confirm, each a JSON object. An "anywhere" mode would reuse them through a
rendezvous relay: devices would register under a value derived from the
circle key (as the hint is, with its own HKDF label, so the relay learns
nothing it could use on the LAN), the relay would forward the same signed
requests and sealed streams it cannot open, and pairing could run over it
as is, since the numeric comparison does not depend on the channel being
honest. Only the relay client and the address of a peer change; the key
handling does not.
