#ifndef RUNNER_ALIAS_H_
#define RUNNER_ALIAS_H_

#include <flutter_linux/flutter_linux.h>

// lib/alias.dart's "plop/alias" on Linux (alias.cc): answers for plop.local
// with this machine's LAN address through Avahi, over D-Bus with GDBus (part
// of GLib, which GTK brings), so a phone's home-screen icon saved with that
// name opens the shelf here while no other computer of the user's has it.
// Without Avahi running the channel says "unavailable" and phones keep the
// machine's own address.
class Alias;

// Starts answering the channel on |messenger|. Free with alias_free, which
// lets the name go.
Alias* alias_new(FlBinaryMessenger* messenger);

void alias_free(Alias* alias);

#endif  // RUNNER_ALIAS_H_
