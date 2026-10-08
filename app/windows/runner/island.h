#ifndef RUNNER_ISLAND_H_
#define RUNNER_ISLAND_H_

#include <flutter/binary_messenger.h>

#include <memory>

// The island on Windows: the black pill lib/island.dart shows in the
// bottom-right corner, above the taskbar, when something arrives from
// another device while plop's window is not focused (island.cpp). It answers
// the "plop/island" channel on |messenger| with the same messages as the
// macOS island (macos/Runner/Island.swift). Owned by the FlutterWindow and
// gone before its engine is.
class Island {
 public:
  explicit Island(flutter::BinaryMessenger* messenger);
  ~Island();

  Island(const Island&) = delete;
  Island& operator=(const Island&) = delete;

 private:
  class Pill;
  std::unique_ptr<Pill> pill_;
};

#endif  // RUNNER_ISLAND_H_
