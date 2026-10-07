#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <shobjidl.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // plop's AppUserModelID, the one its Start menu shortcut carries
  // (packaging/windows/plop.iss), set before any window as Windows requires:
  // the running window groups with a pinned plop on the taskbar, and
  // notifications (lib/notify.dart) are shown as plop's.
  ::SetCurrentProcessExplicitAppUserModelID(L"plop");

  // One plop per session: launching it again (Start menu, the installer's
  // "Open plop") brings the running window forward instead of starting a
  // second node. PLOP_INSTANCE (see lib/main.dart) opts out, so dev copies
  // can still run side by side; Debug builds are exempt too, so `flutter run`
  // works while an installed plop is open.
#ifndef _DEBUG
  if (::GetEnvironmentVariableW(L"PLOP_INSTANCE", nullptr, 0) == 0) {
    ::CreateMutexW(nullptr, FALSE, L"Local\\dev.plop.plop");  // held until exit
    if (::GetLastError() == ERROR_ALREADY_EXISTS) {
      // Window class from win32_window.cpp, title from below.
      HWND running = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"plop");
      if (running) {
        // Hidden in the tray (win32_window.cpp WM_CLOSE), minimized, or
        // just behind other windows: the same steps as its own "show".
        if (!::IsWindowVisible(running)) {
          ::ShowWindow(running, SW_SHOW);
        }
        if (::IsIconic(running)) {
          ::ShowWindow(running, SW_RESTORE);
        }
        ::SetForegroundWindow(running);
      }
      return EXIT_SUCCESS;
    }
  }
#endif

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Compact, like the macOS window: 460x560 of content.
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(460, 560);
  if (!window.Create(L"plop", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
