#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // lib/window.dart's window channel. "flash" asks for a taskbar flash when
  // something from another device lands while plop is in the background
  // and the island is not there to say so;
  // FLASHW_TIMERNOFG flashes until the window comes to the foreground, so
  // nothing has to clear it. "show", "hide", "hideOnClose" and "quit" are
  // the tray icon's (lib/tray.dart): the window lives on hidden once the
  // icon is up, and comes back from its menu or a notification.
  // The messenger keeps the handler; the channel object itself can go.
  flutter::MethodChannel<> channel(
      flutter_controller_->engine()->messenger(), "plop/window",
      &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        const std::string& method = call.method_name();
        if (method == "flash") {
          FLASHWINFO info = {sizeof(info), GetHandle(),
                             FLASHW_TRAY | FLASHW_TIMERNOFG, 0, 0};
          ::FlashWindowEx(&info);
          result->Success();
        } else if (method == "show") {
          ShowAndFocus();
          result->Success();
        } else if (method == "hide") {
          ::ShowWindow(GetHandle(), SW_HIDE);
          result->Success();
        } else if (method == "hideOnClose") {
          const bool* on = std::get_if<bool>(call.arguments());
          SetHideOnClose(on != nullptr && *on);
          result->Success();
        } else if (method == "quit") {
          result->Success();
          Quit();
        } else {
          result->NotImplemented();
        }
      });

  // lib/island.dart's "plop/island": the pill above the taskbar that says
  // what arrived while this window is away, in place of a notification.
  island_ =
      std::make_unique<Island>(flutter_controller_->engine()->messenger());
  // lib/alias.dart's "plop/alias": plop.local for phones (alias.cpp).
  alias_ = std::make_unique<Alias>(flutter_controller_->engine()->messenger());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Before the engine their channels answer on. The alias lets plop.local
  // go here: every way out (quit, close, WM_ENDSESSION) destroys the
  // window, and it does not wait for the answer.
  island_ = nullptr;
  alias_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_POWERBROADCAST:
      // Only the top-level window hears this, not the alias's own
      // message-only one.
      if (wparam == PBT_APMSUSPEND && alias_) alias_->Suspend();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
