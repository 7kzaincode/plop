// The island on Windows: a black pill that rises in the bottom-right corner
// of the screen the pointer is on, above the taskbar and its clock, when
// something arrives from another device while plop's window is not focused,
// with copy and save right on it and the file (or the text) draggable out
// of it into any app. It also says what a global shortcut did. Dart decides
// what to show and does the copying (lib/island.dart); this side only draws,
// animates, and reports clicks, hovers and drags, over the same
// "plop/island" channel and messages as the macOS island
// (macos/Runner/Island.swift), whose look, timing and hover it follows.
//
// It never takes focus: a topmost tool window (no taskbar button, not in
// Alt+Tab) that is never activated and answers WM_MOUSEACTIVATE with
// MA_NOACTIVATE, so whatever the user is typing in keeps the keyboard and
// plop's own window stays where it was. It is a layered window: Direct2D and
// DirectWrite draw it into a 32-bit bitmap that UpdateLayeredWindow puts on
// screen, so its rounded corners and fades are per pixel, and clicks on its
// clear pixels go through to what is below. Hovering holds it open;
// otherwise it tucks away after a few seconds.
//
// Only system libraries: Direct2D, DirectWrite, WIC and the shell's drag and
// drop, so plop stays as light as it was.

#include <windows.h>

#include "island.h"

#include <d2d1.h>
#include <dwrite.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <ole2.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <windowsx.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <map>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

// Sizes in logical pixels (96 DPI), scaled by the DPI of the monitor the
// pill shows on. Rows, header and tiles are the macOS island's; the outline
// is a free-floating rounded rectangle, with no notch to grow out of.
constexpr float kWidth = 380.0f;
constexpr float kRadius = 16.0f;
constexpr float kRowHeight = 52.0f;
constexpr float kHeaderHeight = 44.0f;
constexpr float kPad = 14.0f;
// Above the first row (or the header) and below the last.
constexpr float kTop = 6.0f;
constexpr float kBottom = 6.0f;
constexpr float kTile = 34.0f;
constexpr size_t kMaxRows = 4;
constexpr float kSayHeight = 40.0f;
// From the work area's bottom-right corner: above the taskbar wherever it
// is docked, since the work area leaves it out.
constexpr float kMargin = 12.0f;
// Room round the pill for its soft shadow, inside the window.
constexpr float kShadow = 12.0f;
// How far it rises as it fades in, and sinks as it tucks away.
constexpr float kSlide = 16.0f;

constexpr wchar_t kClassName[] = L"PLOP_ISLAND";
constexpr UINT_PTR kTuckTimer = 1;
constexpr UINT_PTR kFrameTimer = 2;
// A picture's thumbnail was decoded (lparam: the Thumb, ours to free).
constexpr UINT kThumbReady = WM_APP + 1;

// Colours, as the macOS island's Look.
D2D1_COLOR_F Grey(float v, float a = 1.0f) {
  return D2D1::ColorF(v, v, v, a);
}
const D2D1_COLOR_F kFill = Grey(0.04f);  // #0A0A0A, the shelf's canvas
const D2D1_COLOR_F kText = Grey(0.93f);
const D2D1_COLOR_F kDim = Grey(0.56f);
const D2D1_COLOR_F kFaint = Grey(0.40f);
const D2D1_COLOR_F kButton = Grey(0.125f);
const D2D1_COLOR_F kButtonHover = Grey(0.19f);
const D2D1_COLOR_F kBorder = Grey(1.0f, 0.10f);
const D2D1_COLOR_F kPictureBack = Grey(0.23f);
const D2D1_COLOR_F kWarn = D2D1::ColorF(0.90f, 0.28f, 0.30f);

double Now() {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int size = static_cast<int>(utf8.size());
  const int n = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), size, nullptr, 0);
  std::wstring wide(static_cast<size_t>(std::max(n, 0)), L'\0');
  if (n > 0) {
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), size, wide.data(), n);
  }
  return wide;
}

// Text for one line: a text's first line can still hold a tab, and the
// window's title has no room for a second line.
std::wstring OneLine(std::wstring text) {
  for (wchar_t& c : text) {
    if (c == L'\r' || c == L'\n' || c == L'\t') {
      c = L' ';
    }
  }
  return text;
}

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

bool Has(const EncodableMap& map, const char* key) {
  return std::get_if<std::string>(Find(map, key)) != nullptr;
}

std::string String(const EncodableMap& map, const char* key) {
  const auto* value = std::get_if<std::string>(Find(map, key));
  return value != nullptr ? *value : std::string();
}

bool Bool(const EncodableMap& map, const char* key, bool fallback) {
  const auto* value = std::get_if<bool>(Find(map, key));
  return value != nullptr ? *value : fallback;
}

int64_t Int(const EncodableMap& map, const char* key, int64_t fallback) {
  const EncodableValue* value = Find(map, key);
  if (const auto* int32 = std::get_if<int32_t>(value)) {
    return *int32;
  }
  if (const auto* int64 = std::get_if<int64_t>(value)) {
    return *int64;
  }
  return fallback;
}

// A picture's thumbnail, decoded on a thread of its own: a 48-megapixel
// photo takes a good part of a second to decode in full, which the pill
// would otherwise pay on the UI thread. Premultiplied BGRA, 4 bytes a
// pixel, at most 120 pixels on its long side (as the macOS island's).
struct Thumb {
  std::wstring path;
  UINT width = 0;
  UINT height = 0;
  std::vector<BYTE> pixels;
};

// How to turn a photo upright, from its EXIF orientation (1 to 8). WIC
// rotates (clockwise) before it flips.
WICBitmapTransformOptions Upright(UINT16 orientation) {
  switch (orientation) {
    case 2:
      return WICBitmapTransformFlipHorizontal;
    case 3:
      return WICBitmapTransformRotate180;
    case 4:
      return WICBitmapTransformFlipVertical;
    case 5:
      return static_cast<WICBitmapTransformOptions>(
          WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal);
    case 6:
      return WICBitmapTransformRotate90;
    case 7:
      return static_cast<WICBitmapTransformOptions>(
          WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal);
    case 8:
      return WICBitmapTransformRotate270;
    default:
      return WICBitmapTransformRotate0;
  }
}

// Fills |thumb| from its file, or leaves it empty: a format Windows has no
// codec for (HEIC without the store's extension) keeps the type's tile.
void Decode(IWICImagingFactory* wic, Thumb* thumb) {
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  UINT width = 0;
  UINT height = 0;
  if (FAILED(wic->CreateDecoderFromFilename(
          thumb->path.c_str(), nullptr, GENERIC_READ,
          WICDecodeMetadataCacheOnDemand, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame)) ||
      FAILED(frame->GetSize(&width, &height)) || width == 0 || height == 0) {
    return;
  }
  UINT16 orientation = 1;
  ComPtr<IWICMetadataQueryReader> reader;
  if (SUCCEEDED(frame->GetMetadataQueryReader(&reader))) {
    // The photo metadata policy covers JPEG, TIFF and HEIF alike; the
    // JPEG path is the fallback for a codec that knows no policies.
    for (const wchar_t* query :
         {L"System.Photo.Orientation", L"/app1/ifd/{ushort=274}"}) {
      PROPVARIANT value;
      PropVariantInit(&value);
      const bool found =
          SUCCEEDED(reader->GetMetadataByName(query, &value)) &&
          value.vt == VT_UI2;
      if (found) {
        orientation = value.uiVal;
      }
      PropVariantClear(&value);
      if (found) {
        break;
      }
    }
  }
  const double k = std::min(1.0, 120.0 / std::max(width, height));
  const UINT w = std::max(1u, static_cast<UINT>(std::lround(width * k)));
  const UINT h = std::max(1u, static_cast<UINT>(std::lround(height * k)));
  ComPtr<IWICBitmapScaler> scaler;
  if (FAILED(wic->CreateBitmapScaler(&scaler)) ||
      FAILED(scaler->Initialize(frame.Get(), w, h,
                                WICBitmapInterpolationModeFant))) {
    return;
  }
  ComPtr<IWICBitmapSource> source = scaler;
  const WICBitmapTransformOptions upright = Upright(orientation);
  ComPtr<IWICBitmapFlipRotator> rotator;
  if (upright != WICBitmapTransformRotate0 &&
      SUCCEEDED(wic->CreateBitmapFlipRotator(&rotator)) &&
      SUCCEEDED(rotator->Initialize(source.Get(), upright))) {
    source = rotator;
  }
  ComPtr<IWICFormatConverter> converter;
  UINT out_w = 0;
  UINT out_h = 0;
  if (FAILED(wic->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(source.Get(), GUID_WICPixelFormat32bppPBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeMedianCut)) ||
      FAILED(converter->GetSize(&out_w, &out_h))) {
    return;
  }
  std::vector<BYTE> pixels(static_cast<size_t>(out_w) * out_h * 4);
  if (FAILED(converter->CopyPixels(nullptr, out_w * 4,
                                   static_cast<UINT>(pixels.size()),
                                   pixels.data()))) {
    return;
  }
  thumb->width = out_w;
  thumb->height = out_h;
  thumb->pixels = std::move(pixels);
}

// The thread's body: decodes |path| and posts the result to |window|,
// which frees it; if the window is gone by then, it is freed here.
void DecodeThumb(HWND window, std::wstring path) {
  auto thumb = std::make_unique<Thumb>();
  thumb->path = std::move(path);
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  {
    ComPtr<IWICImagingFactory> wic;
    if (SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                   CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic)))) {
      Decode(wic.Get(), thumb.get());
    }
  }
  if (SUCCEEDED(com)) {
    CoUninitialize();
  }
  if (PostMessageW(window, kThumbReady, 0,
                   reinterpret_cast<LPARAM>(thumb.get()))) {
    (void)thumb.release();
  }
}

// The plop bucket (lib/type_icons.dart bucketPath), |size| wide at (x, y):
// the tiles' shape, and a picture's.
ComPtr<ID2D1PathGeometry> Bucket(ID2D1Factory* factory, float size, float x,
                                 float y) {
  ComPtr<ID2D1PathGeometry> path;
  ComPtr<ID2D1GeometrySink> sink;
  if (FAILED(factory->CreatePathGeometry(&path)) ||
      FAILED(path->Open(&sink))) {
    return nullptr;
  }
  auto pt = [&](float px, float py) {
    return D2D1::Point2F(x + px * size, y + py * size);
  };
  auto curve = [&](float x1, float y1, float x2, float y2, float x3,
                   float y3) {
    sink->AddBezier(D2D1::BezierSegment(pt(x1, y1), pt(x2, y2), pt(x3, y3)));
  };
  sink->BeginFigure(pt(0.22f, 0.04f), D2D1_FIGURE_BEGIN_FILLED);
  sink->AddLine(pt(0.78f, 0.04f));
  curve(0.89f, 0.04f, 0.93f, 0.09f, 0.935f, 0.19f);
  sink->AddLine(pt(0.975f, 0.76f));
  curve(0.99f, 0.92f, 0.92f, 0.97f, 0.82f, 0.92f);
  curve(0.64f, 0.84f, 0.36f, 0.84f, 0.18f, 0.92f);
  curve(0.08f, 0.97f, 0.01f, 0.92f, 0.025f, 0.76f);
  sink->AddLine(pt(0.065f, 0.19f));
  curve(0.07f, 0.09f, 0.11f, 0.04f, 0.22f, 0.04f);
  sink->EndFigure(D2D1_FIGURE_END_CLOSED);
  if (FAILED(sink->Close())) {
    return nullptr;
  }
  return path;
}

// A value easing from |from| to |to| over |length| milliseconds from
// |start|: out (fast, then settling) for what opens, in for what tucks.
struct Tween {
  float from = 0.0f;
  float to = 0.0f;
  double start = 0.0;
  double length = 0.0;
  bool ease_in = false;

  float At(double now) const {
    if (length <= 0.0 || now >= start + length) {
      return to;
    }
    const double t = std::max(0.0, (now - start) / length);
    const double e = ease_in ? t * t * t : 1.0 - std::pow(1.0 - t, 3.0);
    return from + static_cast<float>((to - from) * e);
  }

  bool Done(double now) const { return now >= start + length; }
};

}  // namespace

class Island::Pill {
 public:
  explicit Pill(flutter::BinaryMessenger* messenger);
  ~Pill();

 private:
  enum class Kind { kSay, kItems };

  // One item as Dart describes it.
  struct Item {
    std::string key;
    std::wstring title;
    // Shown in place of the title while its row is hovered: a text's first
    // line, kept off the screen until the pointer asks for it.
    std::wstring reveal;
    bool has_reveal = false;
    std::wstring meta;
    ComPtr<IWICBitmapSource> icon;
    std::wstring thumb;
    std::wstring drag_file;
    std::wstring drag_text;
    bool has_drag_text = false;
    std::vector<std::string> actions;
    std::wstring mark;
    bool has_mark = false;
    bool mark_error = false;
  };

  // Rows and buttons as laid out, in logical pixels: a row's from the
  // pill's top-left corner, a button's from its row's.
  struct Box {
    float x = 0.0f;
    float y = 0.0f;
    float w = 0.0f;
    float h = 0.0f;

    bool Contains(float px, float py) const {
      return px >= x && px < x + w && py >= y && py < y + h;
    }
  };
  struct Button {
    Box box;
    std::string action;
    std::wstring label;
  };
  struct Row {
    size_t item = 0;
    float y = 0.0f;
    float text_x = 0.0f;
    float text_w = 0.0f;
    std::wstring title;
    std::wstring reveal;
    std::wstring line;
    std::vector<Button> buttons;
  };
  struct Hit {
    int row = -1;
    int button = -1;
  };

  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  LRESULT Message(HWND window, UINT message, WPARAM wparam, LPARAM lparam);

  void Handle(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result);

  // Showing and tucking away.
  bool EnsureWindow();
  bool Place();
  void Show();
  void Hide();
  void Tucked();
  void CancelClose();
  bool IsUp() const { return visible_ && !tucking_; }
  void Schedule(UINT milliseconds);
  void OnTuck();
  void Announce();
  bool Mark(const std::string& key, bool has_mark, const std::wstring& mark,
            bool error);
  void Drop(const std::string& key);

  // Hover, clicks and drags.
  bool PointerInside() const;
  void SyncHover();
  void Hover(bool inside, Hit hit);
  void HoverChanged(bool inside);
  Hit HitTest(float x, float y) const;
  void OnMove(int x, int y);
  void OnDown(int x, int y);
  void OnUp(int x, int y);
  void StartDrag();
  void Send(const std::string& key, const std::string& action);

  // Layout and animation.
  void Relayout();
  Row LayRow(size_t index, float y);
  void Resize();
  void Animate();
  void Step();

  // Drawing.
  bool EnsureTarget();
  bool EnsureSurface(int width, int height);
  void Render();
  void DrawPill(float x, float y, float w, float h);
  void DrawHeader(float x, float y);
  void DrawRow(size_t index, float x, float y);
  void DrawTile(const Item& item, float x, float y, float size, float ring);
  void Text(const std::wstring& text, IDWriteTextFormat* format, float x,
            float y, float w, float h, const D2D1_COLOR_F& color);
  float Measure(const std::wstring& text, IDWriteTextFormat* format);
  std::wstring Fit(const std::wstring& text, IDWriteTextFormat* format,
                   float width);
  std::wstring SayLine() const;
  ComPtr<IDWriteTextFormat> Format(const std::wstring& family,
                                   DWRITE_FONT_WEIGHT weight, float size,
                                   DWRITE_TEXT_ALIGNMENT align);
  std::wstring Family(std::initializer_list<const wchar_t*> names);
  ComPtr<IWICBitmapSource> DecodePng(const std::vector<uint8_t>& png);
  const Thumb* ThumbFor(const std::wstring& path);
  void OnThumb(Thumb* thumb);

  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  HWND window_ = nullptr;
  bool ole_ = false;

  ComPtr<ID2D1Factory> d2d_;
  ComPtr<IDWriteFactory> dwrite_;
  ComPtr<IWICImagingFactory> wic_;
  ComPtr<ID2D1DCRenderTarget> target_;
  ComPtr<ID2D1SolidColorBrush> brush_;
  ComPtr<IDWriteTextFormat> title_format_;
  ComPtr<IDWriteTextFormat> mono_format_;
  ComPtr<IDWriteTextFormat> mono_right_format_;
  ComPtr<IDWriteTextFormat> button_format_;
  ComPtr<IDWriteTextFormat> say_format_;

  // The bitmap UpdateLayeredWindow takes, grown to the biggest the pill has
  // been at this DPI.
  HDC memory_dc_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  HGDIOBJ old_bitmap_ = nullptr;
  int bitmap_w_ = 0;
  int bitmap_h_ = 0;

  // What it shows.
  Kind kind_ = Kind::kSay;
  std::wstring say_text_;
  bool say_ok_ = true;
  std::wstring sender_;
  std::vector<Item> items_;
  size_t count_ = 0;
  std::vector<Row> rows_;
  float target_w_ = kWidth;
  float target_h_ = kSayHeight;

  // Where, and how far along: the work area and scale of the monitor it
  // shows on, the window's top-left corner in physical pixels, and the
  // pill's size and presence (0 gone, 1 in place) as they ease.
  RECT work_ = {0, 0, 0, 0};
  float scale_ = 1.0f;
  int window_x_ = 0;
  int window_y_ = 0;
  float width_ = kWidth;
  float height_ = kSayHeight;
  float presence_ = 0.0f;
  Tween presence_tween_;
  Tween width_tween_;
  Tween height_tween_;
  bool animating_ = false;
  // Windows' "Animation effects" off: no slide, no easing of its size.
  bool calm_ = false;

  bool visible_ = false;
  bool tucking_ = false;
  bool dragging_ = false;
  bool tracking_ = false;
  // The pointer is on the pill; several items open into their rows then.
  bool expanded_ = false;
  int hover_row_ = -1;
  int hover_button_ = -1;
  int pressed_row_ = -1;
  int pressed_button_ = -1;
  POINT down_ = {0, 0};

  std::map<std::wstring, std::unique_ptr<Thumb>> thumbs_;
  std::set<std::wstring> decoding_;
};

Island::Pill::Pill(flutter::BinaryMessenger* messenger) {
  // Dragging out needs OLE on this thread, beyond the COM main.cpp sets up.
  ole_ = SUCCEEDED(OleInitialize(nullptr));
  D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d_.GetAddressOf());
  DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                      reinterpret_cast<IUnknown**>(dwrite_.GetAddressOf()));
  CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                   IID_PPV_ARGS(&wic_));
  if (dwrite_) {
    // Windows 11's own type where it has it, Windows 10's otherwise.
    const std::wstring ui = Family({L"Segoe UI Variable Text", L"Segoe UI"});
    const std::wstring mono = Family({L"Cascadia Mono", L"Consolas"});
    title_format_ = Format(ui, DWRITE_FONT_WEIGHT_SEMI_BOLD, 13.0f,
                           DWRITE_TEXT_ALIGNMENT_LEADING);
    mono_format_ = Format(mono, DWRITE_FONT_WEIGHT_NORMAL, 11.0f,
                          DWRITE_TEXT_ALIGNMENT_LEADING);
    mono_right_format_ = Format(mono, DWRITE_FONT_WEIGHT_NORMAL, 11.0f,
                                DWRITE_TEXT_ALIGNMENT_TRAILING);
    button_format_ = Format(ui, DWRITE_FONT_WEIGHT_SEMI_BOLD, 12.0f,
                            DWRITE_TEXT_ALIGNMENT_CENTER);
    say_format_ = Format(ui, DWRITE_FONT_WEIGHT_SEMI_BOLD, 13.0f,
                         DWRITE_TEXT_ALIGNMENT_CENTER);
  }

  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "plop/island", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        Handle(call, std::move(result));
      });
}

Island::Pill::~Pill() {
  channel_->SetMethodCallHandler(nullptr);
  if (window_) {
    SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
    DestroyWindow(window_);
  }
  if (memory_dc_) {
    SelectObject(memory_dc_, old_bitmap_);
    DeleteDC(memory_dc_);
  }
  if (bitmap_) {
    DeleteObject(bitmap_);
  }
  if (ole_) {
    OleUninitialize();
  }
}

void Island::Pill::Handle(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  static const EncodableMap kNone;
  const auto* map = std::get_if<EncodableMap>(call.arguments());
  const EncodableMap& args = map != nullptr ? *map : kNone;
  const std::string& method = call.method_name();
  if (method == "available") {
    // Windows can always put a window above the taskbar.
    result->Success(EncodableValue(true));
  } else if (method == "show") {
    std::vector<Item> items;
    if (const auto* list = std::get_if<EncodableList>(Find(args, "items"))) {
      for (const EncodableValue& entry : *list) {
        const auto* m = std::get_if<EncodableMap>(&entry);
        if (m == nullptr || String(*m, "key").empty()) {
          continue;
        }
        Item item;
        item.key = String(*m, "key");
        item.title = Wide(String(*m, "title"));
        item.has_reveal = Has(*m, "reveal");
        item.reveal = Wide(String(*m, "reveal"));
        item.meta = Wide(String(*m, "meta"));
        if (const auto* png =
                std::get_if<std::vector<uint8_t>>(Find(*m, "icon"))) {
          item.icon = DecodePng(*png);
        }
        item.thumb = Wide(String(*m, "thumb"));
        item.drag_file = Wide(String(*m, "dragFile"));
        item.has_drag_text = Has(*m, "dragText");
        item.drag_text = Wide(String(*m, "dragText"));
        if (const auto* actions =
                std::get_if<EncodableList>(Find(*m, "actions"))) {
          for (const EncodableValue& action : *actions) {
            if (const auto* name = std::get_if<std::string>(&action)) {
              item.actions.push_back(*name);
            }
          }
        }
        item.has_mark = Has(*m, "mark");
        item.mark = Wide(String(*m, "mark"));
        item.mark_error = Bool(*m, "error", false);
        items.push_back(std::move(item));
      }
    }
    if (!items.empty()) {
      kind_ = Kind::kItems;
      sender_ = Wide(String(args, "sender"));
      items_ = std::move(items);
      const int64_t count = std::max<int64_t>(Int(args, "count", 0), 0);
      count_ = std::max(static_cast<size_t>(count), items_.size());
      Show();
    }
    result->Success();
  } else if (method == "say") {
    kind_ = Kind::kSay;
    say_text_ = Wide(String(args, "text"));
    say_ok_ = Bool(args, "ok", true);
    items_.clear();
    count_ = 0;
    Show();
    result->Success();
  } else if (method == "mark") {
    // Answers whether the row was there to take it; Dart says it on its
    // own otherwise.
    const bool applied = Mark(String(args, "key"), Has(args, "mark"),
                              Wide(String(args, "mark")),
                              Bool(args, "error", false));
    result->Success(EncodableValue(applied));
  } else if (method == "drop") {
    // Gone from the shelf (expired, or taken back) while showing.
    Drop(String(args, "key"));
    result->Success();
  } else if (method == "hide") {
    Hide();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

// MARK: showing and tucking away

bool Island::Pill::EnsureWindow() {
  if (window_) {
    return true;
  }
  if (!d2d_ || !dwrite_ || !title_format_) {
    return false;
  }
  WNDCLASSEXW wc = {};
  wc.cbSize = static_cast<UINT>(sizeof(wc));
  wc.lpfnWndProc = WndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.lpszClassName = kClassName;
  RegisterClassExW(&wc);  // fails harmlessly once registered
  // Created on first use, so a plop that never shows the pill has no
  // second top-level window. No owner: an owned window hides with its
  // owner when that is minimized, and plop's window often is.
  window_ = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED,
      kClassName, L"plop", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
      wc.hInstance, this);
  return window_ != nullptr;
}

LRESULT CALLBACK Island::Pill::WndProc(HWND window, UINT message,
                                       WPARAM wparam, LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  } else if (auto* pill = reinterpret_cast<Pill*>(
                 GetWindowLongPtrW(window, GWLP_USERDATA))) {
    return pill->Message(window, message, wparam, lparam);
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

LRESULT Island::Pill::Message(HWND window, UINT message, WPARAM wparam,
                              LPARAM lparam) {
  switch (message) {
    case WM_MOUSEACTIVATE:
      // A click goes to the pill without taking focus from the app the
      // user is in.
      return MA_NOACTIVATE;
    case WM_MOUSEMOVE:
      OnMove(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      return 0;
    case WM_MOUSELEAVE:
      tracking_ = false;
      if (!dragging_ && pressed_row_ < 0) {
        Hover(false, Hit{});
      }
      return 0;
    case WM_LBUTTONDOWN:
      OnDown(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      return 0;
    case WM_LBUTTONUP:
      OnUp(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      return 0;
    case WM_CAPTURECHANGED:
      // Taken away mid-press (a window popping up): nothing is pressed.
      if (!dragging_ && pressed_row_ >= 0 &&
          reinterpret_cast<HWND>(lparam) != window) {
        pressed_row_ = -1;
        pressed_button_ = -1;
        if (visible_) {
          Render();
        }
      }
      return 0;
    case WM_TIMER:
      if (wparam == kTuckTimer) {
        OnTuck();
      } else if (wparam == kFrameTimer) {
        Step();
      }
      return 0;
    case kThumbReady:
      OnThumb(reinterpret_cast<Thumb*>(lparam));
      return 0;
    case WM_DPICHANGED:
      // Placed and scaled at each show, by the monitor it shows on; the
      // suggested rect would only move it.
      return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

// Finds the monitor the pointer is on, as the macOS island does, and takes
// its work area (the screen less the taskbar, wherever that is) and scale.
bool Island::Pill::Place() {
  POINT cursor = {0, 0};
  GetCursorPos(&cursor);
  HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info = {};
  info.cbSize = static_cast<DWORD>(sizeof(info));
  if (!monitor || !GetMonitorInfoW(monitor, &info)) {
    return false;
  }
  work_ = info.rcWork;
  scale_ = static_cast<float>(FlutterDesktopGetDpiForMonitor(monitor)) / 96.0f;
  if (scale_ <= 0.0f) {
    scale_ = 1.0f;
  }
  return true;
}

void Island::Pill::Show() {
  if (!EnsureWindow()) {
    return;
  }
  BOOL animations = TRUE;
  SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animations, 0);
  calm_ = animations == FALSE;
  expanded_ = false;
  hover_row_ = -1;
  hover_button_ = -1;
  pressed_row_ = -1;
  pressed_button_ = -1;
  Relayout();
  const double now = Now();
  if (IsUp()) {
    Resize();
  } else if (visible_) {
    // Tucking away: it comes back where it is.
    tucking_ = false;
    presence_tween_ = {presence_, 1.0f, now, calm_ ? 0.0 : 150.0, false};
    Resize();
  } else {
    if (!Place()) {
      return;
    }
    width_ = target_w_;
    height_ = target_h_;
    width_tween_ = {width_, width_, now, 0.0, false};
    height_tween_ = {height_, height_, now, 0.0, false};
    presence_ = 0.0f;
    presence_tween_ = {0.0f, 1.0f, now, calm_ ? 120.0 : 220.0, false};
    visible_ = true;
    tucking_ = false;
    // Drawn clear first, so showing it flashes nothing.
    Render();
    ShowWindow(window_, SW_SHOWNOACTIVATE);
    SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    Animate();
  }
  SyncHover();
  Announce();
  Schedule(kind_ == Kind::kSay ? 2200u : count_ > 1 ? 7000u : 5000u);
}

// What a screen reader finds as the window's name: what arrived, never a
// text's words, as the macOS island announces it.
void Island::Pill::Announce() {
  std::wstring line;
  if (kind_ == Kind::kSay) {
    line = say_text_;
  } else if (count_ > 1) {
    line = std::to_wstring(count_) + L" from " + sender_;
  } else if (!items_.empty()) {
    line = items_.front().title + L" from " + sender_;
  }
  SetWindowTextW(window_, OneLine(line).c_str());
}

// Tucks the pill away after |milliseconds|, or later while the pointer is
// on it or something is being dragged out of it: the timer asks, rather
// than trusting enter and leave messages, which a pill resized under a
// still pointer can miss.
void Island::Pill::Schedule(UINT milliseconds) {
  if (window_) {
    SetTimer(window_, kTuckTimer, milliseconds, nullptr);
  }
}

void Island::Pill::OnTuck() {
  KillTimer(window_, kTuckTimer);
  if (dragging_ || PointerInside()) {
    Schedule(1000);
  } else {
    Hide();
  }
}

void Island::Pill::Hide() {
  if (!window_) {
    return;
  }
  KillTimer(window_, kTuckTimer);
  if (!visible_ || tucking_) {
    return;
  }
  tucking_ = true;
  presence_tween_ = {presence_, 0.0f, Now(), calm_ ? 120.0 : 180.0, true};
  Animate();
}

// Faded out: off the screen, and Dart told, so the next arrival starts a
// new pill.
void Island::Pill::Tucked() {
  tucking_ = false;
  visible_ = false;
  expanded_ = false;
  hover_row_ = -1;
  hover_button_ = -1;
  // A window hidden under the pointer may never hear it leave: the next
  // show asks to be told again.
  tracking_ = false;
  ShowWindow(window_, SW_HIDE);
  thumbs_.clear();
  channel_->InvokeMethod("hidden", nullptr);
}

// The pointer came back while it was tucking away: it stays.
void Island::Pill::CancelClose() {
  tucking_ = false;
  presence_tween_ = {presence_, 1.0f, Now(), calm_ ? 0.0 : 150.0, false};
  Animate();
}

bool Island::Pill::Mark(const std::string& key, bool has_mark,
                        const std::wstring& mark, bool error) {
  if (!IsUp() || kind_ != Kind::kItems) {
    return false;
  }
  for (Item& item : items_) {
    if (item.key != key) {
      continue;
    }
    item.has_mark = has_mark;
    item.mark = mark;
    item.mark_error = error;
    Relayout();
    Render();
    Schedule(1600);
    return true;
  }
  return false;
}

void Island::Pill::Drop(const std::string& key) {
  if (!IsUp() || kind_ != Kind::kItems) {
    return;
  }
  const size_t before = items_.size();
  items_.erase(std::remove_if(items_.begin(), items_.end(),
                              [&](const Item& i) { return i.key == key; }),
               items_.end());
  const size_t gone = before - items_.size();
  count_ = std::max(count_ > gone ? count_ - gone : 0, items_.size());
  if (items_.empty()) {
    Hide();
    return;
  }
  hover_row_ = -1;
  hover_button_ = -1;
  pressed_row_ = -1;
  pressed_button_ = -1;
  Relayout();
  Resize();
  SyncHover();
}

// MARK: hover, clicks and drags

bool Island::Pill::PointerInside() const {
  if (!visible_) {
    return false;
  }
  POINT cursor = {0, 0};
  GetCursorPos(&cursor);
  const float x = static_cast<float>(cursor.x - window_x_) / scale_ - kShadow;
  const float y = static_cast<float>(cursor.y - window_y_) / scale_ - kShadow;
  return x >= 0.0f && y >= 0.0f && x < width_ && y < height_;
}

// After a show or a resize the pointer may be on the pill, or on another
// row of it, with no message to say so yet.
void Island::Pill::SyncHover() {
  if (!visible_) {
    return;
  }
  POINT cursor = {0, 0};
  GetCursorPos(&cursor);
  const float x = static_cast<float>(cursor.x - window_x_) / scale_ - kShadow;
  const float y = static_cast<float>(cursor.y - window_y_) / scale_ - kShadow;
  Hover(PointerInside(), HitTest(x, y));
}

void Island::Pill::Hover(bool inside, Hit hit) {
  const bool moved = hit.row != hover_row_ || hit.button != hover_button_;
  hover_row_ = hit.row;
  hover_button_ = hit.button;
  if (inside != expanded_) {
    HoverChanged(inside);
  }
  if (moved && visible_) {
    Render();
  }
}

void Island::Pill::HoverChanged(bool inside) {
  const bool reopening = inside && tucking_;
  if (reopening) {
    CancelClose();
  }
  const bool changed = expanded_ != inside;
  expanded_ = inside;
  // A single row looks the same either way (its own hover reveals text).
  if (reopening || (changed && count_ > 1)) {
    Relayout();
    Resize();
  }
  if (!inside) {
    Schedule(2500);
  }
}

Island::Pill::Hit Island::Pill::HitTest(float x, float y) const {
  Hit hit;
  if (x < 0.0f || y < 0.0f || x >= width_ || y >= height_) {
    return hit;
  }
  for (size_t r = 0; r < rows_.size(); ++r) {
    const Row& row = rows_[r];
    if (y < row.y || y >= row.y + kRowHeight) {
      continue;
    }
    hit.row = static_cast<int>(r);
    for (size_t b = 0; b < row.buttons.size(); ++b) {
      if (row.buttons[b].box.Contains(x, y - row.y)) {
        hit.button = static_cast<int>(b);
      }
    }
    break;
  }
  return hit;
}

void Island::Pill::OnMove(int x, int y) {
  if (!tracking_) {
    TRACKMOUSEEVENT track = {};
    track.cbSize = static_cast<DWORD>(sizeof(track));
    track.dwFlags = TME_LEAVE;
    track.hwndTrack = window_;
    tracking_ = TrackMouseEvent(&track) != FALSE;
  }
  // A row pressed and pulled far enough drags its file or text out.
  if (pressed_row_ >= 0 && pressed_button_ < 0 && !dragging_ &&
      (std::abs(x - down_.x) > GetSystemMetrics(SM_CXDRAG) ||
       std::abs(y - down_.y) > GetSystemMetrics(SM_CYDRAG))) {
    StartDrag();
    return;
  }
  const float lx = static_cast<float>(x) / scale_ - kShadow;
  const float ly = static_cast<float>(y) / scale_ - kShadow;
  const bool inside = lx >= 0.0f && ly >= 0.0f && lx < width_ && ly < height_;
  Hover(inside, HitTest(lx, ly));
}

void Island::Pill::OnDown(int x, int y) {
  const float lx = static_cast<float>(x) / scale_ - kShadow;
  const float ly = static_cast<float>(y) / scale_ - kShadow;
  const Hit hit = HitTest(lx, ly);
  if (hit.row < 0) {
    return;
  }
  pressed_row_ = hit.row;
  pressed_button_ = hit.button;
  down_ = {x, y};
  SetCapture(window_);
  Render();
}

void Island::Pill::OnUp(int x, int y) {
  const int row = pressed_row_;
  const int button = pressed_button_;
  pressed_row_ = -1;
  pressed_button_ = -1;
  if (GetCapture() == window_) {
    ReleaseCapture();
  }
  if (row < 0 || static_cast<size_t>(row) >= rows_.size()) {
    return;
  }
  const Row& pressed = rows_[static_cast<size_t>(row)];
  const std::string key = items_[pressed.item].key;
  if (button < 0) {
    // A click on the row, not dragged: the shelf, or where it was saved.
    Send(key, "open");
  } else if (static_cast<size_t>(button) < pressed.buttons.size()) {
    const float lx = static_cast<float>(x) / scale_ - kShadow;
    const float ly = static_cast<float>(y) / scale_ - kShadow;
    const Hit hit = HitTest(lx, ly);
    if (hit.row == row && hit.button == button) {
      Send(key, pressed.buttons[static_cast<size_t>(button)].action);
    }
  }
  if (visible_) {
    Render();
  }
}

// Drags the pressed row's file (as Explorer would hand it over, so any app
// that takes files from Explorer takes it) or its text, copying, never
// moving: the file is the shelf's. The drag runs its own loop until the
// drop; the tuck timer keeps asking meanwhile, and waits.
void Island::Pill::StartDrag() {
  const int row = pressed_row_;
  pressed_row_ = -1;
  pressed_button_ = -1;
  if (GetCapture() == window_) {
    ReleaseCapture();
  }
  if (row < 0 || static_cast<size_t>(row) >= rows_.size()) {
    return;
  }
  const Item& item = items_[rows_[static_cast<size_t>(row)].item];
  ComPtr<IDataObject> data;
  if (!item.drag_file.empty()) {
    ComPtr<IShellItem> file;
    if (SUCCEEDED(SHCreateItemFromParsingName(item.drag_file.c_str(), nullptr,
                                              IID_PPV_ARGS(&file)))) {
      file->BindToHandler(nullptr, BHID_DataObject, IID_PPV_ARGS(&data));
    }
  } else if (item.has_drag_text &&
             SUCCEEDED(SHCreateDataObject(nullptr, 0, nullptr, nullptr,
                                          IID_PPV_ARGS(&data)))) {
    const std::wstring& text = item.drag_text;
    const size_t bytes = (text.size() + 1) * sizeof(wchar_t);
    HGLOBAL global = GlobalAlloc(GMEM_MOVEABLE, bytes);
    void* memory = global ? GlobalLock(global) : nullptr;
    if (memory == nullptr) {
      if (global) {
        GlobalFree(global);
      }
      return;
    }
    std::memcpy(memory, text.c_str(), bytes);
    GlobalUnlock(global);
    FORMATETC format = {CF_UNICODETEXT, nullptr, DVASPECT_CONTENT, -1,
                        TYMED_HGLOBAL};
    STGMEDIUM medium = {};
    medium.tymed = TYMED_HGLOBAL;
    medium.hGlobal = global;
    if (FAILED(data->SetData(&format, &medium, TRUE))) {
      GlobalFree(global);
      return;
    }
  }
  if (!data) {
    return;
  }
  dragging_ = true;
  if (visible_) {
    Render();
  }
  DWORD effect = DROPEFFECT_NONE;
  SHDoDragDrop(window_, data.Get(), nullptr, DROPEFFECT_COPY, &effect);
  dragging_ = false;
  Schedule(2500);
  SyncHover();
}

void Island::Pill::Send(const std::string& key, const std::string& action) {
  channel_->InvokeMethod(
      "action", std::make_unique<EncodableValue>(EncodableMap{
                    {EncodableValue("key"), EncodableValue(key)},
                    {EncodableValue("action"), EncodableValue(action)},
                }));
}

// MARK: layout and animation

// One item shows as its row; several show as a line saying how many,
// opening into their rows (up to four) on hover. Sizes the pill for that.
void Island::Pill::Relayout() {
  rows_.clear();
  if (kind_ == Kind::kSay) {
    const float text = std::ceil(Measure(SayLine(), say_format_.Get()));
    target_w_ = std::clamp(text + 48.0f, 200.0f, kWidth);
    target_h_ = kSayHeight;
  } else {
    target_w_ = kWidth;
    float y = kTop;
    if (count_ > 1) {
      y += kHeaderHeight;
    }
    if (count_ == 1 || expanded_) {
      const size_t n = std::min(items_.size(), kMaxRows);
      for (size_t i = 0; i < n; ++i) {
        rows_.push_back(LayRow(i, y));
        y += kRowHeight;
      }
    }
    target_h_ = y + kBottom;
  }
  if (hover_row_ >= static_cast<int>(rows_.size())) {
    hover_row_ = -1;
    hover_button_ = -1;
  }
  if (pressed_row_ >= static_cast<int>(rows_.size())) {
    pressed_row_ = -1;
    pressed_button_ = -1;
  }
}

// Buttons at the right edge, copy then save; the name and its line take
// what is left.
Island::Pill::Row Island::Pill::LayRow(size_t index, float y) {
  const Item& item = items_[index];
  Row row;
  row.item = index;
  row.y = y;
  float right = kWidth - kPad;
  for (auto it = item.actions.rbegin(); it != item.actions.rend(); ++it) {
    Button button;
    button.action = *it;
    button.label = Wide(*it);
    const float w =
        std::ceil(Measure(button.label, button_format_.Get())) + 24.0f;
    right -= w;
    button.box = {right, 12.0f, w, 28.0f};
    row.buttons.insert(row.buttons.begin(), button);
    right -= 6.0f;
  }
  row.text_x = kPad + kTile + 12.0f;
  row.text_w = std::max(right - 6.0f - row.text_x, 40.0f);
  // Names lose their middle, keeping the extension, as the shelf's do.
  row.title = Fit(OneLine(item.title), title_format_.Get(), row.text_w);
  row.reveal = item.has_reveal
                   ? Fit(OneLine(item.reveal), title_format_.Get(), row.text_w)
                   : row.title;
  // Size and sender, as the shelf's rows put them; a long device name is
  // what gets cut, from the end.
  std::wstring line = item.meta;
  if (count_ == 1 && !sender_.empty()) {
    line = line.empty() ? sender_ : line + L" \u00B7 " + sender_;
  }
  row.line = OneLine(line);
  return row;
}

// Eases the pill to the size its contents want now; it stays anchored at
// its bottom-right corner, so it grows up and to the left.
void Island::Pill::Resize() {
  const double now = Now();
  const double length = calm_ ? 0.0 : 200.0;
  width_tween_ = {width_, target_w_, now, length, false};
  height_tween_ = {height_, target_h_, now, length, false};
  Animate();
}

void Island::Pill::Animate() {
  if (!window_) {
    return;
  }
  if (!animating_) {
    SetTimer(window_, kFrameTimer, 15, nullptr);
    animating_ = true;
  }
  Step();
}

void Island::Pill::Step() {
  const double now = Now();
  presence_ = presence_tween_.At(now);
  width_ = width_tween_.At(now);
  height_ = height_tween_.At(now);
  if (visible_) {
    Render();
  }
  if (!presence_tween_.Done(now) || !width_tween_.Done(now) ||
      !height_tween_.Done(now)) {
    return;
  }
  KillTimer(window_, kFrameTimer);
  animating_ = false;
  if (tucking_ && visible_) {
    Tucked();
  }
}

// MARK: drawing

bool Island::Pill::EnsureTarget() {
  if (target_) {
    return true;
  }
  // Premultiplied BGRA, which is what UpdateLayeredWindow takes.
  const D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
      D2D1_RENDER_TARGET_TYPE_DEFAULT,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_PREMULTIPLIED));
  if (FAILED(d2d_->CreateDCRenderTarget(&props, &target_))) {
    return false;
  }
  // ClearType needs an opaque background to blend into; the pill's pixels
  // are see-through at its edges and while it fades.
  target_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  brush_.Reset();
  if (FAILED(target_->CreateSolidColorBrush(kText, &brush_))) {
    target_.Reset();
    return false;
  }
  return true;
}

bool Island::Pill::EnsureSurface(int width, int height) {
  if (memory_dc_ && bitmap_w_ >= width && bitmap_h_ >= height) {
    return true;
  }
  const int w = std::max(width, bitmap_w_);
  const int h = std::max(height, bitmap_h_);
  BITMAPINFO info = {};
  info.bmiHeader.biSize = static_cast<DWORD>(sizeof(BITMAPINFOHEADER));
  info.bmiHeader.biWidth = w;
  info.bmiHeader.biHeight = -h;  // top-down
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP bitmap =
      CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!bitmap) {
    return false;
  }
  if (!memory_dc_) {
    memory_dc_ = CreateCompatibleDC(nullptr);
    if (!memory_dc_) {
      DeleteObject(bitmap);
      return false;
    }
  }
  HGDIOBJ old = SelectObject(memory_dc_, bitmap);
  if (bitmap_) {
    DeleteObject(bitmap_);
  } else {
    old_bitmap_ = old;
  }
  bitmap_ = bitmap;
  bitmap_w_ = w;
  bitmap_h_ = h;
  return true;
}

// Draws the pill as it is now and puts it on screen: its bottom-right
// corner kMargin in from the work area's, lower by however far it has
// still to rise, and as opaque as it is present.
void Island::Pill::Render() {
  if (!window_ || !EnsureTarget()) {
    return;
  }
  const float s = scale_;
  const int window_w =
      static_cast<int>(std::ceil((width_ + 2.0f * kShadow) * s));
  const int window_h =
      static_cast<int>(std::ceil((height_ + 2.0f * kShadow) * s));
  if (!EnsureSurface(window_w, window_h)) {
    return;
  }
  const float lift = calm_ ? 0.0f : kSlide * (1.0f - presence_);
  const float right = static_cast<float>(work_.right) - kMargin * s;
  const float bottom = static_cast<float>(work_.bottom) - (kMargin - lift) * s;
  window_x_ = static_cast<int>(std::lround(right - (width_ + kShadow) * s));
  window_y_ = static_cast<int>(std::lround(bottom - (height_ + kShadow) * s));

  const RECT bound = {0, 0, window_w, window_h};
  if (FAILED(target_->BindDC(memory_dc_, &bound))) {
    return;
  }
  // Drawn in logical pixels; the target scales them to the monitor's.
  target_->SetDpi(96.0f * s, 96.0f * s);
  target_->BeginDraw();
  target_->SetTransform(D2D1::Matrix3x2F::Identity());
  target_->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  DrawPill(kShadow, kShadow, width_, height_);
  if (target_->EndDraw() == D2DERR_RECREATE_TARGET) {
    // The device went away (a driver update, say); the next frame makes a
    // new target.
    brush_.Reset();
    target_.Reset();
    return;
  }
  POINT position = {window_x_, window_y_};
  SIZE size = {window_w, window_h};
  POINT origin = {0, 0};
  BLENDFUNCTION blend = {};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = static_cast<BYTE>(
      std::lround(255.0f * std::clamp(presence_, 0.0f, 1.0f)));
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(window_, nullptr, &position, &size, memory_dc_, &origin,
                      0, &blend, ULW_ALPHA);
}

void Island::Pill::DrawPill(float x, float y, float w, float h) {
  // A soft shadow: rings of faint black, wider and fainter outwards, a
  // little low, as a flyout's.
  for (int i = 6; i >= 1; --i) {
    const float g = 1.5f * static_cast<float>(i);
    brush_->SetColor(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.035f));
    target_->FillRoundedRectangle(
        D2D1::RoundedRect(D2D1::RectF(x - g, y - g + 2.0f, x + w + g,
                                      y + h + g + 2.0f),
                          kRadius + g, kRadius + g),
        brush_.Get());
  }
  const float r = std::min(kRadius, h / 2.0f);
  const D2D1_ROUNDED_RECT shape =
      D2D1::RoundedRect(D2D1::RectF(x, y, x + w, y + h), r, r);
  brush_->SetColor(kFill);
  target_->FillRoundedRectangle(shape, brush_.Get());

  // What it shows, laid out for its full size from its top-left corner and
  // cut to its outline while that eases to it.
  ComPtr<ID2D1RoundedRectangleGeometry> clip;
  ComPtr<ID2D1Layer> layer;
  const bool clipped =
      SUCCEEDED(d2d_->CreateRoundedRectangleGeometry(shape, &clip)) &&
      SUCCEEDED(target_->CreateLayer(&layer));
  if (clipped) {
    target_->PushLayer(D2D1::LayerParameters(D2D1::InfiniteRect(), clip.Get()),
                       layer.Get());
  }
  if (kind_ == Kind::kSay) {
    Text(SayLine(), say_format_.Get(), x + 16.0f, y, w - 32.0f, h,
         say_ok_ ? kText : kWarn);
  } else {
    if (count_ > 1) {
      DrawHeader(x, y + kTop);
    }
    for (size_t i = 0; i < rows_.size(); ++i) {
      DrawRow(i, x, y + rows_[i].y);
    }
  }
  if (clipped) {
    target_->PopLayer();
  }

  brush_->SetColor(kBorder);
  target_->DrawRoundedRectangle(
      D2D1::RoundedRect(
          D2D1::RectF(x + 0.5f, y + 0.5f, x + w - 0.5f, y + h - 0.5f),
          std::max(r - 0.5f, 0.0f), std::max(r - 0.5f, 0.0f)),
      brush_.Get(), 1.0f);
}

// "3 from Zain's iPhone", after the first three tiles stacked, the first on
// top; "hover" at the right until the pointer opens the rows.
void Island::Pill::DrawHeader(float x, float y) {
  const size_t stacked = std::min<size_t>(items_.size(), 3);
  float left = x + kPad;
  for (size_t i = stacked; i-- > 0;) {
    DrawTile(items_[i], left, y + 10.0f, 24.0f, 2.0f);
    left += 14.0f;
  }
  left += 18.0f;
  const std::wstring title = std::to_wstring(count_) + L" from " + sender_;
  Text(OneLine(title), title_format_.Get(), left, y + 13.0f,
       std::max(x + kWidth - left - kPad - 60.0f, 20.0f), 18.0f, kText);
  if (!expanded_) {
    Text(L"hover", mono_right_format_.Get(), x + kWidth - kPad - 60.0f,
         y + 15.0f, 60.0f, 16.0f, kFaint);
  }
}

// One item: its tile, its name and line, its buttons.
void Island::Pill::DrawRow(size_t index, float x, float y) {
  const Row& row = rows_[index];
  const Item& item = items_[row.item];
  const bool hovered = hover_row_ == static_cast<int>(index);
  DrawTile(item, x + kPad, y + 9.0f, kTile, 0.0f);
  Text(hovered ? row.reveal : row.title, title_format_.Get(), x + row.text_x,
       y + 8.0f, row.text_w, 18.0f, kText);
  const D2D1_COLOR_F& line_color =
      item.mark_error ? kWarn : item.has_mark ? kText : kDim;
  Text(item.has_mark ? OneLine(item.mark) : row.line, mono_format_.Get(),
       x + row.text_x, y + 28.0f, row.text_w, 15.0f, line_color);
  // Copied or saved: its buttons step back.
  const bool done = item.has_mark && !item.mark_error;
  for (size_t b = 0; b < row.buttons.size(); ++b) {
    const Button& button = row.buttons[b];
    const bool pressed = pressed_row_ == static_cast<int>(index) &&
                         pressed_button_ == static_cast<int>(b);
    const bool lit = hovered && hover_button_ == static_cast<int>(b);
    const float bx = x + button.box.x;
    const float by = y + button.box.y;
    const D2D1_ROUNDED_RECT pill = D2D1::RoundedRect(
        D2D1::RectF(bx + 0.5f, by + 0.5f, bx + button.box.w - 0.5f,
                    by + button.box.h - 0.5f),
        8.0f, 8.0f);
    brush_->SetColor(pressed ? kBorder : lit ? kButtonHover : kButton);
    target_->FillRoundedRectangle(pill, brush_.Get());
    brush_->SetColor(kBorder);
    target_->DrawRoundedRectangle(pill, brush_.Get(), 1.0f);
    Text(button.label, button_format_.Get(), bx, by, button.box.w,
         button.box.h, done ? kDim : kText);
  }
}

// The type tile Dart drew, or the picture itself in the bucket's shape;
// with |ring|, a margin of the pill's own black round it, so tiles stacked
// in the header read as separate ones.
void Island::Pill::DrawTile(const Item& item, float x, float y, float size,
                            float ring) {
  if (ring > 0.0f) {
    ComPtr<ID2D1PathGeometry> back =
        Bucket(d2d_.Get(), size + 2.0f * ring, x - ring, y - ring);
    if (back) {
      brush_->SetColor(kFill);
      target_->FillGeometry(back.Get(), brush_.Get());
    }
  }
  const Thumb* thumb = item.thumb.empty() ? nullptr : ThumbFor(item.thumb);
  if (thumb != nullptr) {
    ComPtr<ID2D1PathGeometry> bucket = Bucket(d2d_.Get(), size, x, y);
    ComPtr<ID2D1Bitmap> picture;
    ComPtr<ID2D1BitmapBrush> fill;
    if (bucket &&
        SUCCEEDED(target_->CreateBitmap(
            D2D1::SizeU(thumb->width, thumb->height), thumb->pixels.data(),
            thumb->width * 4,
            D2D1::BitmapProperties(D2D1::PixelFormat(
                DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED)),
            &picture)) &&
        SUCCEEDED(target_->CreateBitmapBrush(picture.Get(), &fill))) {
      brush_->SetColor(kPictureBack);
      target_->FillGeometry(bucket.Get(), brush_.Get());
      // Aspect fill, centred.
      const D2D1_SIZE_F p = picture->GetSize();
      const float k = std::max(size / std::max(p.width, 1.0f),
                               size / std::max(p.height, 1.0f));
      fill->SetInterpolationMode(D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
      fill->SetTransform(
          D2D1::Matrix3x2F::Scale(k, k) *
          D2D1::Matrix3x2F::Translation(x + (size - p.width * k) / 2.0f,
                                        y + (size - p.height * k) / 2.0f));
      target_->FillGeometry(bucket.Get(), fill.Get());
      return;
    }
  }
  ComPtr<ID2D1Bitmap> icon;
  if (item.icon && SUCCEEDED(target_->CreateBitmapFromWicBitmap(
                       item.icon.Get(), nullptr, &icon))) {
    target_->DrawBitmap(icon.Get(), D2D1::RectF(x, y, x + size, y + size));
  }
}

void Island::Pill::Text(const std::wstring& text, IDWriteTextFormat* format,
                        float x, float y, float w, float h,
                        const D2D1_COLOR_F& color) {
  if (format == nullptr || text.empty()) {
    return;
  }
  brush_->SetColor(color);
  target_->DrawText(text.c_str(), static_cast<UINT32>(text.size()), format,
                    D2D1::RectF(x, y, x + w, y + h), brush_.Get(),
                    D2D1_DRAW_TEXT_OPTIONS_CLIP);
}

float Island::Pill::Measure(const std::wstring& text,
                            IDWriteTextFormat* format) {
  ComPtr<IDWriteTextLayout> layout;
  DWRITE_TEXT_METRICS metrics = {};
  if (format == nullptr ||
      FAILED(dwrite_->CreateTextLayout(text.c_str(),
                                       static_cast<UINT32>(text.size()),
                                       format, 10000.0f, 100.0f, &layout)) ||
      FAILED(layout->GetMetrics(&metrics))) {
    return 0.0f;
  }
  return metrics.widthIncludingTrailingWhitespace;
}

// |text| cut in the middle to fit |width|, keeping its start and its end
// (a file's extension), never between the halves of a surrogate pair.
std::wstring Island::Pill::Fit(const std::wstring& text,
                               IDWriteTextFormat* format, float width) {
  if (Measure(text, format) <= width) {
    return text;
  }
  auto middle = [&](size_t keep) {
    size_t head = (keep + 1) / 2;
    size_t from = text.size() - keep / 2;
    if (head > 0 && IS_HIGH_SURROGATE(text[head - 1])) {
      --head;
    }
    if (from < text.size() && IS_LOW_SURROGATE(text[from])) {
      ++from;
    }
    return text.substr(0, head) + L"\u2026" + text.substr(from);
  };
  size_t low = 0;
  size_t high = text.size();
  while (low < high) {
    const size_t keep = (low + high + 1) / 2;
    if (Measure(middle(keep), format) <= width) {
      low = keep;
    } else {
      high = keep - 1;
    }
  }
  return middle(low);
}

std::wstring Island::Pill::SayLine() const {
  return (say_ok_ ? L"\u2713  " : L"\u2715  ") + OneLine(say_text_);
}

// One line, no wrapping, an ellipsis where it runs out of room.
ComPtr<IDWriteTextFormat> Island::Pill::Format(const std::wstring& family,
                                               DWRITE_FONT_WEIGHT weight,
                                               float size,
                                               DWRITE_TEXT_ALIGNMENT align) {
  ComPtr<IDWriteTextFormat> format;
  if (FAILED(dwrite_->CreateTextFormat(
          family.c_str(), nullptr, weight, DWRITE_FONT_STYLE_NORMAL,
          DWRITE_FONT_STRETCH_NORMAL, size, L"en-us", &format))) {
    return nullptr;
  }
  format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
  format->SetTextAlignment(align);
  format->SetParagraphAlignment(align == DWRITE_TEXT_ALIGNMENT_CENTER
                                    ? DWRITE_PARAGRAPH_ALIGNMENT_CENTER
                                    : DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
  ComPtr<IDWriteInlineObject> ellipsis;
  if (SUCCEEDED(dwrite_->CreateEllipsisTrimmingSign(format.Get(), &ellipsis))) {
    const DWRITE_TRIMMING trimming = {DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0,
                                      0};
    format->SetTrimming(&trimming, ellipsis.Get());
  }
  return format;
}

// The first of |names| this PC has, else the last.
std::wstring Island::Pill::Family(
    std::initializer_list<const wchar_t*> names) {
  ComPtr<IDWriteFontCollection> fonts;
  if (SUCCEEDED(dwrite_->GetSystemFontCollection(&fonts))) {
    for (const wchar_t* name : names) {
      UINT32 index = 0;
      BOOL exists = FALSE;
      if (SUCCEEDED(fonts->FindFamilyName(name, &index, &exists)) && exists) {
        return name;
      }
    }
  }
  return *(names.end() - 1);
}

// A type tile's PNG, decoded now, while its bytes are still there.
ComPtr<IWICBitmapSource> Island::Pill::DecodePng(
    const std::vector<uint8_t>& png) {
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICFormatConverter> converter;
  ComPtr<IWICBitmap> bitmap;
  if (!wic_ || png.empty() || FAILED(wic_->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(const_cast<BYTE*>(png.data()),
                                          static_cast<DWORD>(png.size()))) ||
      FAILED(wic_->CreateDecoderFromStream(stream.Get(), nullptr,
                                           WICDecodeMetadataCacheOnDemand,
                                           &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame)) ||
      FAILED(wic_->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeMedianCut)) ||
      FAILED(wic_->CreateBitmapFromSource(converter.Get(),
                                          WICBitmapCacheOnLoad, &bitmap))) {
    return nullptr;
  }
  return bitmap;
}

// The thumbnail if it is decoded; otherwise null now and a redraw later.
// One that failed is not tried again until the pill has tucked away.
const Thumb* Island::Pill::ThumbFor(const std::wstring& path) {
  auto found = thumbs_.find(path);
  if (found != thumbs_.end()) {
    return found->second.get();
  }
  if (window_ && decoding_.insert(path).second) {
    std::thread(DecodeThumb, window_, path).detach();
  }
  return nullptr;
}

void Island::Pill::OnThumb(Thumb* raw) {
  std::unique_ptr<Thumb> thumb(raw);
  const std::wstring path = thumb->path;
  decoding_.erase(path);
  if (thumb->pixels.empty()) {
    thumb.reset();
  }
  thumbs_[path] = std::move(thumb);
  if (visible_) {
    Render();
  }
}

Island::Island(flutter::BinaryMessenger* messenger)
    : pill_(std::make_unique<Pill>(messenger)) {}

Island::~Island() = default;
