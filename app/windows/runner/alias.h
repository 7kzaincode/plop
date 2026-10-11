#ifndef RUNNER_ALIAS_H_
#define RUNNER_ALIAS_H_

#include <flutter/binary_messenger.h>

#include <memory>

// lib/alias.dart's "plop/alias" on Windows (alias.cpp): answers for
// plop.local with this PC's LAN address through the system's own mDNS
// responder, so a phone's home-screen icon saved with that name opens the
// shelf here while no other computer of the user's has it. Windows 10 1809
// and later; on older Windows the channel says "unavailable" and phones
// keep the PC's own address. Owned by the FlutterWindow and gone before its
// engine is; going, it lets the name go.
class Alias {
 public:
  explicit Alias(flutter::BinaryMessenger* messenger);
  ~Alias();

  Alias(const Alias&) = delete;
  Alias& operator=(const Alias&) = delete;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_ALIAS_H_
