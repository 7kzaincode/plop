#ifndef RUNNER_ISLAND_H_
#define RUNNER_ISLAND_H_

#include <flutter_linux/flutter_linux.h>

// The island on Linux: the black pill lib/island.dart shows in the
// bottom-right corner, above the panel, when something arrives from another
// device while plop's window is not focused (island.cc). It answers the
// "plop/island" channel with the same messages as the macOS island
// (macos/Runner/Island.swift); under Wayland it answers "available" with
// false and shows nothing, and plop keeps notifications there.
class Island;

// Starts answering the channel on |messenger|. Free with island_free.
Island* island_new(FlBinaryMessenger* messenger);

void island_free(Island* island);

#endif  // RUNNER_ISLAND_H_
