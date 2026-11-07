// The DNS-SD service API (DnsServiceRegister and the rest) is declared only
// for Windows 10 1809 (RS5) targets and later. It is looked up at run time
// all the same (GetProcAddress), so plop still starts on an older Windows,
// which just never claims the name; hence the target is raised here, for
// this file's declarations alone, before any Windows header.
#ifdef _WIN32_WINNT
#undef _WIN32_WINNT
#endif
#define _WIN32_WINNT 0x0A00
#ifdef NTDDI_VERSION
#undef NTDDI_VERSION
#endif
#define NTDDI_VERSION 0x0A000006  // NTDDI_WIN10_RS5

#include "alias.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <windns.h>

#include <atomic>
#include <string>
#include <vector>

namespace {

// Answers come on a thread-pool thread and are posted here, to the
// platform thread the channel lives on: wparam the claim's gen, lparam its
// status.
constexpr UINT kAnswered = WM_APP + 1;
constexpr wchar_t kWindowClass[] = L"PlopAlias";
constexpr wchar_t kHost[] = L"plop.local";
constexpr WORD kPort = 7567;  // lib/'s defaultWebPort

using ConstructFn = decltype(&DnsServiceConstructInstance);
using FreeFn = decltype(&DnsServiceFreeInstance);
using RegisterFn = decltype(&DnsServiceRegister);
using DeRegisterFn = decltype(&DnsServiceDeRegister);

struct Api {
  ConstructFn construct = nullptr;
  FreeFn free = nullptr;
  RegisterFn reg = nullptr;
  DeRegisterFn dereg = nullptr;
};

// dnsapi.dll's service functions, or null before Windows 10 1809. From
// System32 only, never the app's folder.
const Api* LoadApi() {
  static const Api* api = []() -> const Api* {
    HMODULE dll =
        LoadLibraryExW(L"dnsapi.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (dll == nullptr) return nullptr;
    static Api a;
    a.construct = reinterpret_cast<ConstructFn>(
        GetProcAddress(dll, "DnsServiceConstructInstance"));
    a.free = reinterpret_cast<FreeFn>(
        GetProcAddress(dll, "DnsServiceFreeInstance"));
    a.reg =
        reinterpret_cast<RegisterFn>(GetProcAddress(dll, "DnsServiceRegister"));
    a.dereg = reinterpret_cast<DeRegisterFn>(
        GetProcAddress(dll, "DnsServiceDeRegister"));
    if (!a.construct || !a.free || !a.reg || !a.dereg) return nullptr;
    return &a;
  }();
  return api;
}

// "192.168.1.5" as an IP4_ADDRESS (network order in memory), or false.
bool ParseIPv4(const std::string& ip, IP4_ADDRESS* out) {
  unsigned int part[4];
  char tail;
  if (sscanf_s(ip.c_str(), "%u.%u.%u.%u%c", &part[0], &part[1], &part[2],
               &part[3], &tail, 1) != 4) {
    return false;
  }
  for (unsigned int p : part) {
    if (p > 255) return false;
  }
  *out = part[0] | part[1] << 8 | part[2] << 16 | part[3] << 24;
  return true;
}

// One claim of the name: a service instance of plop's own type on this
// PC, whose host name is plop.local at the given address. Windows answers
// for the instance's host name with that address.
struct Registration {
  DNS_SERVICE_REGISTER_REQUEST request = {};
  PDNS_SERVICE_INSTANCE instance = nullptr;
  IP4_ADDRESS ip = 0;
  HWND window = nullptr;
  // Read on the pool thread that answers, set to -1 here once let go.
  std::atomic<int> gen{0};
  ULONGLONG retired_at = 0;
};

// Register and DeRegister both answer through this, on a pool thread. A
// registration's first answer is its fate; whatever comes after it was let
// go is not news (Dart drops a gen it is no longer waiting on anyway).
// PostMessage to a window that is gone just fails.
VOID WINAPI Answered(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE) {
  auto* r = static_cast<Registration*>(context);
  PostMessageW(r->window, kAnswered, static_cast<WPARAM>(r->gen.load()),
               static_cast<LPARAM>(status));
}

}  // namespace

class Alias::Impl {
 public:
  explicit Impl(flutter::BinaryMessenger* messenger)
      : channel_(std::make_unique<flutter::MethodChannel<>>(
            messenger, "plop/alias",
            &flutter::StandardMethodCodec::GetInstance())) {
    WNDCLASSW wc = {};
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kWindowClass;
    RegisterClassW(&wc);  // fails harmlessly if already registered
    window_ = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0,
                              HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
    if (window_ != nullptr) {
      SetWindowLongPtrW(window_, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(this));
    }
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<>& call,
               std::unique_ptr<flutter::MethodResult<>> result) {
          if (call.method_name() == "claim") {
            result->Success();
            Claim(call.arguments());
          } else if (call.method_name() == "release") {
            Release();
            result->Success();
          } else {
            result->NotImplemented();
          }
        });
  }

  // Lets the name go without waiting: plop is quitting (its own quit, a
  // close, or WM_ENDSESSION, which all destroy the window this hangs off),
  // and the deregistration finishes in the DNS client service, not here.
  // What was registered is left allocated, not freed: an answer may yet
  // arrive on a pool thread while the process ends.
  ~Impl() {
    channel_->SetMethodCallHandler(nullptr);
    Release();
    for (auto& r : retired_) {
      (void)r.release();
    }
    if (window_ != nullptr) {
      SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
      DestroyWindow(window_);
    }
  }

  // Dart answers for the name itself on Windows (lib/alias.dart's
  // HostResponder), so it is told to let go; a registration made here, if
  // any, goes too.
  void Suspend() {
    if (current_) {
      int gen = current_->gen;
      Release();
      Report("lost", gen);
    }
    channel_->InvokeMethod("suspend", nullptr);
  }

 private:
  void Claim(const flutter::EncodableValue* args) {
    Release();
    const auto* map = args ? std::get_if<flutter::EncodableMap>(args) : nullptr;
    std::string ip;
    int gen = 0;
    if (map != nullptr) {
      auto i = map->find(flutter::EncodableValue("ip"));
      if (i != map->end()) {
        if (const auto* s = std::get_if<std::string>(&i->second)) ip = *s;
      }
      auto g = map->find(flutter::EncodableValue("gen"));
      if (g != map->end()) {
        if (const auto* n = std::get_if<int32_t>(&g->second)) gen = *n;
        if (const auto* n = std::get_if<int64_t>(&g->second)) {
          gen = static_cast<int>(*n);
        }
      }
    }
    const Api* api = LoadApi();
    if (api == nullptr || window_ == nullptr) {
      return Report("unavailable", gen);
    }
    auto r = std::make_unique<Registration>();
    if (!ParseIPv4(ip, &r->ip)) return Report("lost", gen);
    r->window = window_;
    r->gen = gen;
    // The instance's own name must differ from every other PC's, or the
    // instances would collide too; the host name is what is shared.
    wchar_t computer[MAX_COMPUTERNAME_LENGTH + 1] = L"plop";
    DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
    GetComputerNameW(computer, &size);
    std::wstring name = std::wstring(computer) + L"._plop-web._tcp.local";
    r->instance = api->construct(name.c_str(), kHost, &r->ip, nullptr, kPort,
                                 0, 0, 0, nullptr, nullptr);
    if (r->instance == nullptr) return Report("lost", gen);
    r->request.Version = DNS_QUERY_REQUEST_VERSION1;
    r->request.InterfaceIndex = 0;  // every interface
    r->request.pServiceInstance = r->instance;
    r->request.pRegisterCompletionCallback = Answered;
    r->request.pQueryContext = r.get();
    r->request.unicastEnabled = FALSE;
    if (api->reg(&r->request, nullptr) != DNS_REQUEST_PENDING) {
      api->free(r->instance);
      return Report("lost", gen);
    }
    current_ = std::move(r);
  }

  // Deregisters the current claim, if any. Its Registration is kept a
  // while, as the DNS client may still answer on it, and freed on a later
  // claim once that is long past.
  void Release() {
    const Api* api = LoadApi();
    ULONGLONG now = GetTickCount64();
    for (auto i = retired_.begin(); i != retired_.end();) {
      if (now - (*i)->retired_at > 60000) {
        api->free((*i)->instance);
        i = retired_.erase(i);
      } else {
        ++i;
      }
    }
    if (!current_) return;
    current_->gen = -1;  // whatever it answers from now on is not news
    current_->retired_at = now;
    api->dereg(&current_->request, nullptr);
    retired_.push_back(std::move(current_));
  }

  void Report(const char* state, int gen) {
    channel_->InvokeMethod(
        "state", std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                     {flutter::EncodableValue("state"),
                      flutter::EncodableValue(state)},
                     {flutter::EncodableValue("gen"),
                      flutter::EncodableValue(gen)},
                 }));
  }

  // Windows does not say which: a refused registration is taken to mean
  // the name is someone else's, and Dart asks again later.
  void Answer(int gen, DWORD status) {
    if (!current_ || gen != current_->gen) return;
    Report(status == ERROR_SUCCESS ? "won" : "conflict", gen);
  }

  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
    if (message == kAnswered) {
      auto* self =
          reinterpret_cast<Impl*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
      if (self != nullptr) {
        self->Answer(static_cast<int>(wparam), static_cast<DWORD>(lparam));
      }
      return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  std::unique_ptr<flutter::MethodChannel<>> channel_;
  HWND window_ = nullptr;
  std::unique_ptr<Registration> current_;
  std::vector<std::unique_ptr<Registration>> retired_;
};

Alias::Alias(flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>(messenger)) {}

Alias::~Alias() = default;

void Alias::Suspend() { impl_->Suspend(); }
