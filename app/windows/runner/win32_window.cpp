#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include <algorithm>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

/// Newer attribute, by value for the same reason.
constexpr DWORD kDwmCaptionColor = 35;  // DWMWA_CAPTION_COLOR, Windows 11

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// Where RememberFrame keeps the window's frame. The installer removes the
// key at uninstall (packaging/windows/plop.iss).
constexpr const wchar_t kFrameKey[] = L"Software\\plop";
constexpr const wchar_t kFrameValue[] = L"window";

// The registry value: the whole window's rect in physical screen pixels,
// and the DPI it had then, so a monitor whose scale has changed since gets
// it rescaled.
struct SavedFrame {
  RECT rect;
  UINT dpi;
};

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  // The remembered frame is in physical pixels already, measured on the
  // monitor it lands on, so the window is created there at that monitor's
  // DPI and no WM_DPICHANGED rescales it again.
  RECT frame{};
  if (!RememberedFrame(&frame)) {
    const POINT target_point = {static_cast<LONG>(origin.x),
                                static_cast<LONG>(origin.y)};
    HMONITOR monitor =
        MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
    UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
    double scale_factor = dpi / 96.0;

    frame = {0, 0, Scale(size.width, scale_factor),
             Scale(size.height, scale_factor)};
    AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
    OffsetRect(&frame, Scale(origin.x, scale_factor) - frame.left,
               Scale(origin.y, scale_factor) - frame.top);
  }

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW, frame.left, frame.top,
      frame.right - frame.left, frame.bottom - frame.top,
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

// static
Win32Window::Point Win32Window::CentredOrigin(const Size& size) {
  // In physical pixels, then back to the logical units Create scales by the
  // same monitor's DPI. The primary monitor's top-left is (0, 0), so the
  // point Create looks its monitor up by stays on it. Clamped at 0, as
  // Point is unsigned: on a small screen at a high scale the window can be
  // taller than the work area.
  RECT work{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  UINT dpi = FlutterDesktopGetDpiForMonitor(
      MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY));
  double scale_factor = dpi / 96.0;
  RECT frame = {0, 0, Scale(size.width, scale_factor),
                Scale(size.height, scale_factor)};
  AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
  LONG x = work.left +
           ((work.right - work.left) - (frame.right - frame.left)) / 2;
  LONG y = work.top +
           ((work.bottom - work.top) - (frame.bottom - frame.top)) / 2;
  return Point(static_cast<unsigned int>(std::max(0L, x) / scale_factor),
               static_cast<unsigned int>(std::max(0L, y) / scale_factor));
}

// static
void Win32Window::RememberFrame(HWND const window) {
  // A minimized or maximized window's rect is not where it should come back
  // as a normal one, so the last frame stays. A window hidden in the tray
  // keeps its rect, which counts.
  if (IsIconic(window) || IsZoomed(window)) {
    return;
  }
  SavedFrame saved{};
  if (!GetWindowRect(window, &saved.rect)) {
    return;
  }
  saved.dpi = FlutterDesktopGetDpiForHWND(window);
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kFrameKey, 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &key,
                      nullptr) != ERROR_SUCCESS) {
    return;
  }
  RegSetValueExW(key, kFrameValue, 0, REG_BINARY,
                 reinterpret_cast<const BYTE*>(&saved),
                 static_cast<DWORD>(sizeof(saved)));
  RegCloseKey(key);
}

// static
bool Win32Window::RememberedFrame(RECT* frame) {
  SavedFrame saved{};
  DWORD size = static_cast<DWORD>(sizeof(saved));
  if (RegGetValueW(HKEY_CURRENT_USER, kFrameKey, kFrameValue,
                   RRF_RT_REG_BINARY, nullptr, &saved,
                   &size) != ERROR_SUCCESS ||
      size != sizeof(saved) || saved.dpi == 0) {
    return false;
  }
  RECT rect = saved.rect;
  if (rect.right <= rect.left || rect.bottom <= rect.top) {
    return false;
  }
  // The middle of the title bar, where the window is dragged from, must be
  // on a monitor: one that was unplugged or rearranged since (a laptop off
  // its dock) must not leave plop off-screen, so it is centred again.
  POINT grip = {rect.left + (rect.right - rect.left) / 2,
                rect.top + MulDiv(16, saved.dpi, 96)};
  HMONITOR monitor = MonitorFromPoint(grip, MONITOR_DEFAULTTONULL);
  if (!monitor) {
    return false;
  }
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  if (dpi != saved.dpi) {
    rect.right = rect.left + MulDiv(rect.right - rect.left, dpi, saved.dpi);
    rect.bottom = rect.top + MulDiv(rect.bottom - rect.top, dpi, saved.dpi);
  }
  *frame = rect;
  return true;
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_CLOSE:
      // With the tray icon up, closing only hides the window: the shelf,
      // its server and the shortcuts keep running, as on macOS. The engine
      // sees the message first and, this being the process's only
      // top-level window, asks Dart whether the app may exit (lib/tray.dart
      // answers with a hide while the icon is up); it sends the close again
      // on "exit", which is how Quit() ends plop. This hide is for a close
      // the engine lets through without asking, should another top-level
      // window ever exist. The window is hidden, never destroyed: the tray
      // icon belongs to it.
      if (hide_on_close_ && !quitting_) {
        ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;  // DefWindowProc destroys the window

    case WM_QUERYENDSESSION:
      // Windows logging off or shutting down, or an installer's Restart
      // Manager asking plop.exe to close so it can be replaced (lparam
      // ENDSESSION_CLOSEAPP): plop agrees, and quits on WM_ENDSESSION.
      return TRUE;

    case WM_ENDSESSION:
      // Quit for real, past hide_on_close_: hidden in the tray, plop would
      // only be killed, and an upgrade would find its files in use. Not by
      // way of WM_CLOSE, which the engine would put to Dart, and Dart would
      // answer with a hide. Destroying the window ends the message loop.
      if (wparam) {
        quitting_ = true;
        DestroyWindow(hwnd);
      }
      return 0;

    case WM_EXITSIZEMOVE:
      // A drag or resize just ended. Kept now, not only at exit: plop is
      // rarely quit, mostly hidden in the tray until the PC shuts down,
      // and an upgrade may have to end it by force.
      RememberFrame(hwnd);
      break;

    case WM_DESTROY:
      // Quitting, or the session ending (WM_ENDSESSION destroys the window
      // too), which catches a move made from the keyboard (Win+arrows).
      RememberFrame(hwnd);
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_GETMINMAXINFO: {
      // Keep at least 360x320 of content, as on macOS (contentMinSize).
      UINT dpi = FlutterDesktopGetDpiForHWND(hwnd);
      RECT frame = {0, 0, MulDiv(360, dpi, 96), MulDiv(320, dpi, 96)};
      AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = frame.right - frame.left;
      info->ptMinTrackSize.y = frame.bottom - frame.top;
      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::SetHideOnClose(bool hide_on_close) {
  hide_on_close_ = hide_on_close;
}

void Win32Window::ShowAndFocus() {
  if (!window_handle_) {
    return;
  }
  if (!IsWindowVisible(window_handle_)) {
    ShowWindow(window_handle_, SW_SHOW);  // hidden in the tray
  }
  if (IsIconic(window_handle_)) {
    ShowWindow(window_handle_, SW_RESTORE);
  }
  SetForegroundWindow(window_handle_);
}

void Win32Window::Quit() {
  quitting_ = true;
  if (window_handle_) {
    PostMessage(window_handle_, WM_CLOSE, 0, 0);
  } else {
    PostQuitMessage(0);
  }
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  BOOL dark = TRUE;
  DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark,
                        sizeof(dark));

  // Paint the caption the canvas colour (Palette.bg) so the title bar blends
  // into the window, as on macOS. Windows 10 ignores it and keeps the plain
  // dark caption from above.
  COLORREF caption = RGB(10, 10, 10);
  DwmSetWindowAttribute(window, kDwmCaptionColor, &caption, sizeof(caption));
}
