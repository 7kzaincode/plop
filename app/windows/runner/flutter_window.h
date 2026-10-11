#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "alias.h"
#include "island.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The pill arrivals show on while this window is away (island.cpp); it
  // talks to the engine, so it goes first.
  std::unique_ptr<Island> island_;

  // plop.local while no other computer has it (alias.cpp); also talks to
  // the engine, and lets the name go as the window is destroyed, however
  // plop quits.
  std::unique_ptr<Alias> alias_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
