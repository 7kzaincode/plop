# Plan

## v1 milestones

1. Toolchain and repo
2. Core package (`packages/core`): shelf store, node server/client, sync engine, tests
3. Desktop app with Bonjour discovery and the one-screen UI
4. Android
5. macOS and iOS
6. Polish: paste, clipboard copy for images/files, expiry animation, icon, device name
7. Packaging (signed builds only when asked)

## After v1

1. **Room code and TLS.** Today anyone on the LAN running the app can grab
   anything on the shelf, and traffic is unencrypted HTTP. Fine at home, not
   elsewhere. Add an optional room code (shared secret that filters peers and
   authenticates requests) and TLS between nodes.
2. Relay server, for networks with client isolation (campus and guest Wi-Fi)
   where device-to-device traffic is blocked.
3. Re-serving mirrors, so an item survives its sender leaving.

## Known limits, by design

- A phone only sees the shelf while the app is in the foreground.
- Networks with client isolation block this entirely.
- No encryption or access control in v1 (see above).
