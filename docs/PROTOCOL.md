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
one-way (usually a firewall on this side).

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
  ignored. A `name` longer than 255 characters is cut to that. `mime` is
  optional and defaults to `application/octet-stream`, as does one that is
  not a plain `type/subtype` (letters, digits, `.+_-`); of its parameters
  only a plain `charset` is kept.
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
  neither. A node that does not know a kind treats it as `file`.
- `ttlMs` is the time **remaining**, in milliseconds. Never an absolute time:
  clocks on a LAN disagree. The sender picks the lifetime (2 minutes by
  default); it can differ per item. A receiver clamps it to 24 hours, and
  ignores entries with `ttlMs` ≤ 0, which are already expired.

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
  fetched on tap.
- Items over 100 GB are refused, both locally and from peers.
- A download that has started is allowed to finish after the item expires
  (the origin keeps streaming an open file), so large transfers are not cut
  off. A new `GET` after expiry still gets `404`.
- Mirrored copies are never re-served to other nodes. Only the origin serves
  an item over `/v1`. (The web shelf below hands mirrors to browsers; no
  node ever asks it for one.)
- Peer gone (mDNS lost event, or 3 failed polls in a row): keep fully copied
  items until their timers end; drop items that were never copied.
- Downloads are written to `<name>.part` and renamed when complete and the
  byte count matches `size`. On any failure (more or fewer bytes, a stall, a
  full disk) the `.part` file is deleted.

## Storage

Each node uses one temp directory, wiped on launch. Owned bytes live at
`<dir>/<originId>/<itemId>/<name>`. A file the user picked on this device is
served from where it is and is never deleted by the app.

## Web shelf

A one-page web app for devices without plop (iPhones, mostly), on the same
port as `/v1`. Off unless the node enables it: the desktop apps do, phones do
not, and the headless node does with `--web`. A disabled node answers `404`
on all of these routes.

**Port.** The desktop app asks for the port it had last time, else `7567`
(p-l-o-p on a phone keypad), else any free port, and remembers what it got,
so an address saved on a phone's home screen keeps working. The address
shown is `http://<host>.local:<port>/` (the name mDNS answers for: on macOS
the Sharing settings' local host name), then `http://<ipv4>:<port>/` for
each address, for browsers that do not resolve `.local`.

**Not part of the protocol.** No node calls these routes, so the rule that
mirrors are never re-served between nodes holds. A browser on this page is a
user of this device, not a peer: it can grab whatever this device's shelf
shows, mirrors included, as a tap in the window could. What it uploads
becomes this node's own item and travels to peers over `/v1` like any other.

### Routes

| route | answer |
|---|---|
| `GET /` | The page: inline HTML, CSS and JS, nothing fetched from elsewhere. `Cache-Control: max-age=60`. |
| `GET /manifest.webmanifest` | Web app manifest: `plop`, standalone, `#0A0A0A`, icons at `/icon.png`, `start_url` `/`. |
| `GET /icon.png` | The app icon (a 1x1 black PNG on a node that was given none). |
| `GET /web/shelf` | Every item the node knows, own and mirrored, newest first (see below). |
| `GET /web/items/{originId}/{id}` | The bytes, with `Content-Type`, `Content-Length`, `Content-Security-Policy: sandbox` (nothing served here runs as a page of this origin) and `Content-Disposition: attachment; filename="…"; filename*=UTF-8''…` (a folder's zip as `<name>.zip`, text as `text.txt`). A mirror not copied yet is fetched from its origin first. `404` once gone; `502` if the origin cannot be reached. |
| `POST /web/items?name=<name>` | Raw file body, streamed to disk as this node's own item. `200 {"key": "<originId>/<id>"}`. `400` without a name or for a body that ends short of its `Content-Length`; `413` past the node's item cap (100 GB), before any of the body is read when `Content-Length` says so, else where the body crosses it, and the connection is closed. |
| `POST /web/text` | UTF-8 body, up to 1 MB, as a text item. `200 {"key": …}`; `400` if blank; `413` if longer. |
| `DELETE /web/items/{originId}/{id}` | Removes one of this node's own items (`204`); `403` for a mirror, `404` if unknown. |

Everything under `/web/` carries `Cache-Control: no-store`.

`GET /web/shelf` entries:

```json
{"key": "9f2c…/1a7e…", "name": "photo.png", "size": 102400,
 "mime": "image/png", "kind": "file", "ttlMs": 87412, "from": "Zain's MacBook",
 "ready": true, "receivedBy": 1, "text": "…"}
```

`from` is the origin's device name (this node's own name for its own items).
`ready` says whether the bytes are on this node yet. `receivedBy` (own items
only) counts the peers holding a copy. `text` is a ready text item's content
when it is at most 64 KB, so the page can copy it inside the tap: on plain
HTTP a browser gives the page no asynchronous clipboard, and the fallback it
has works only within the user's gesture.

### Trust

The same LAN trust as nodes: anyone on the network who can open the page
can download everything on this device's shelf and upload to it, just as
anyone running plop can. Like `/v1` it is plain HTTP without authentication
(see PLAN.md, "Room code and TLS"). Being plain HTTP also means browsers deny
the page their secure-context APIs (share sheet, clipboard, install prompt),
so it falls back: text copies through a selection, images open full-screen to
be saved with a long press, and other files download.
