# plop protocol, v1

Every running app is a node. There is no server. Each node serves only the
items it originated, and mirrors other nodes' items locally.

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
  ignored. A `name` longer than 255 characters is cut to that. Control
  characters, bidi embeddings, overrides and isolates (U+202A–202E,
  U+2066–2069) and line or paragraph separators in it are shown and saved
  as `_`, so `fdp.exe` cannot pass for `exe.pdf`, nor `pdf\n.exe` for
  `pdf`. Other invisible marks (LRM, RLM, ALM, zero-width space, word
  joiner, BOM) are dropped; ZWJ and ZWNJ are kept. `mime` is optional and
  defaults to `application/octet-stream`.
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
  fetched on tap. At most 4 eager copies run at once, at most 2 of them
  from any one sender, smallest first. One still running after 30 s plus
  a second per 256 KB is dropped (a tap has no such limit). One that fails
  or is dropped is tried again on later polls, 3 tries in all, after which
  the item is fetched on tap like a large one.
- Items over 100 GB are refused, both locally and from peers.
- A download that has started is allowed to finish after the item expires
  (the origin keeps streaming an open file), so large transfers are not cut
  off. A new `GET` after expiry still gets `404`.
- Mirrored copies are never re-served. Only the origin serves an item.
- Peer gone (mDNS lost event, or 3 failed polls in a row): keep fully copied
  items until their timers end; drop items that were never copied, once
  any transfer of them still running has ended.
- Downloads are written to `<name>.part` and renamed when complete and the
  byte count matches `size`. On any failure (more or fewer bytes, a stall, a
  full disk) the `.part` file is deleted.

## Storage

Each node uses one temp directory, wiped on launch. Owned bytes live at
`<dir>/<originId>/<itemId>/<name>`. A file the user picked on this device is
served from where it is and is never deleted by the app.
