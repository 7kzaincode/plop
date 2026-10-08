// The island on Linux: a black pill that rises in the bottom-right corner of
// the monitor the pointer is on, above the panel, when something arrives
// from another device while plop's window is not focused, with copy and
// save right on it and the file (or the text) draggable out of it into any
// app. It also says what a global shortcut did. Dart decides what to show
// and does the copying (lib/island.dart); this side only draws, animates,
// and reports clicks, hovers and drags, over the same "plop/island" channel
// and messages as the macOS island (macos/Runner/Island.swift) and the
// Windows one (windows/runner/island.cpp), whose look and timing it follows.
//
// X11 only. It is a popup (override-redirect) window, which the window
// manager neither decorates, nor lists, nor gives focus to: whatever the
// user is typing in keeps the keyboard, and plop's own window stays where
// it was. Wayland gives an app no say in where its windows go, so there
// "available" says no and plop keeps notifications.
//
// The window keeps one size, as big as the pill can get plus room for its
// shadow and its slide; cairo draws the pill inside it, with Pango for the
// text, and an input shape lets clicks outside the pill through. With a
// compositor the window is see-through round the pill and fades with it;
// without one, it is cut to the pill's outline and only slides.

#include "island.h"

#include <cairo.h>
#include <gtk/gtk.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace {

// Sizes in logical pixels; GTK scales them on a HiDPI screen. Rows, header
// and tiles are the macOS island's; the outline is a free-floating rounded
// rectangle, with no notch to grow out of.
constexpr double kWidth = 380.0;
constexpr double kRadius = 16.0;
constexpr double kRowHeight = 52.0;
constexpr double kHeaderHeight = 44.0;
constexpr double kPad = 14.0;
// Above the first row (or the header) and below the last.
constexpr double kTop = 6.0;
constexpr double kBottom = 6.0;
constexpr double kTile = 34.0;
constexpr size_t kMaxRows = 4;
constexpr double kSayHeight = 40.0;
// From the work area's bottom-right corner: above the panel wherever it is
// docked, since the work area leaves it out.
constexpr int kMargin = 12;
// Room round the pill for its soft shadow, inside the window.
constexpr int kShadow = 12;
// How far it rises as it fades in, and sinks as it tucks away.
constexpr int kSlide = 16;
// The window: the biggest pill (a header and four rows), its shadow, and
// room below for it to rise from.
constexpr int kWindowWidth = 380 + 2 * kShadow;
constexpr int kWindowHeight = 6 + 44 + 4 * 52 + 6 + 2 * kShadow + kSlide;

// Drag targets.
constexpr guint kUriTarget = 1;
constexpr guint kTextTarget = 2;

// Colours, as the macOS island's Look.
struct Rgba {
  double r, g, b, a;
};
constexpr Rgba Grey(double v, double a = 1.0) { return Rgba{v, v, v, a}; }
constexpr Rgba kFill = Grey(0.04);  // #0A0A0A, the shelf's canvas
constexpr Rgba kText = Grey(0.93);
constexpr Rgba kDim = Grey(0.56);
constexpr Rgba kFaint = Grey(0.40);
constexpr Rgba kButton = Grey(0.125);
constexpr Rgba kButtonHover = Grey(0.19);
constexpr Rgba kBorder = Grey(1.0, 0.10);
constexpr Rgba kPictureBack = Grey(0.23);
constexpr Rgba kShade = Grey(0.0, 0.035);
constexpr Rgba kWarn = Rgba{0.90, 0.28, 0.30, 1.0};

void Paint(cairo_t* cr, const Rgba& c) {
  cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a);
}

double Now() {
  return static_cast<double>(g_get_monotonic_time()) / 1000.0;
}

// Text for one line: a text's first line can still hold a tab.
std::string OneLine(std::string text) {
  for (char& c : text) {
    if (c == '\r' || c == '\n' || c == '\t') {
      c = ' ';
    }
  }
  return text;
}

FlValue* Find(FlValue* map, const char* key) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(map, key);
}

bool Has(FlValue* map, const char* key) {
  FlValue* value = Find(map, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING;
}

std::string String(FlValue* map, const char* key) {
  return Has(map, key) ? std::string(fl_value_get_string(Find(map, key)))
                       : std::string();
}

bool Flag(FlValue* map, const char* key, bool fallback) {
  FlValue* value = Find(map, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL
             ? fl_value_get_bool(value)
             : fallback;
}

int64_t Int(FlValue* map, const char* key, int64_t fallback) {
  FlValue* value = Find(map, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_INT
             ? fl_value_get_int(value)
             : fallback;
}

std::shared_ptr<GdkPixbuf> Own(GdkPixbuf* pixbuf) {
  return pixbuf != nullptr ? std::shared_ptr<GdkPixbuf>(pixbuf, g_object_unref)
                           : nullptr;
}

// A type tile's PNG, as Dart drew it.
std::shared_ptr<GdkPixbuf> DecodePng(const uint8_t* data, size_t length) {
  GdkPixbufLoader* loader = gdk_pixbuf_loader_new();
  const gboolean written =
      gdk_pixbuf_loader_write(loader, data, length, nullptr);
  const gboolean closed = gdk_pixbuf_loader_close(loader, nullptr);
  GdkPixbuf* loaded =
      written && closed ? gdk_pixbuf_loader_get_pixbuf(loader) : nullptr;
  // The loader's own reference goes with it.
  GdkPixbuf* pixbuf =
      loaded != nullptr ? GDK_PIXBUF(g_object_ref(loaded)) : nullptr;
  g_object_unref(loader);
  return Own(pixbuf);
}

// The thread's body: a picture's thumbnail, at most 120 pixels on its long
// side (as the macOS island's) and turned upright, decoded off the main
// thread: a 48-megapixel photo takes a good part of a second in full.
// gdk-pixbuf decodes a JPEG at the smaller size to begin with.
void DecodeThumb(GTask* task, gpointer source, gpointer data,
                 GCancellable* cancellable) {
  GError* error = nullptr;
  GdkPixbuf* scaled = gdk_pixbuf_new_from_file_at_scale(
      static_cast<const char*>(data), 120, 120, TRUE, &error);
  if (scaled == nullptr) {
    g_task_return_error(task, error);
    return;
  }
  GdkPixbuf* upright = gdk_pixbuf_apply_embedded_orientation(scaled);
  g_object_unref(scaled);
  g_task_return_pointer(task, upright, g_object_unref);
}

void RoundedRect(cairo_t* cr, double x, double y, double w, double h,
                 double r) {
  r = std::max(0.0, std::min(r, std::min(w, h) / 2.0));
  cairo_new_sub_path(cr);
  cairo_arc(cr, x + w - r, y + r, r, -G_PI / 2.0, 0.0);
  cairo_arc(cr, x + w - r, y + h - r, r, 0.0, G_PI / 2.0);
  cairo_arc(cr, x + r, y + h - r, r, G_PI / 2.0, G_PI);
  cairo_arc(cr, x + r, y + r, r, G_PI, 3.0 * G_PI / 2.0);
  cairo_close_path(cr);
}

// The plop bucket (lib/type_icons.dart bucketPath), |size| wide at (x, y):
// the tiles' shape, and a picture's.
void Bucket(cairo_t* cr, double size, double x, double y) {
  auto px = [&](double v) { return x + v * size; };
  auto py = [&](double v) { return y + v * size; };
  cairo_new_path(cr);
  cairo_move_to(cr, px(0.22), py(0.04));
  cairo_line_to(cr, px(0.78), py(0.04));
  cairo_curve_to(cr, px(0.89), py(0.04), px(0.93), py(0.09), px(0.935),
                 py(0.19));
  cairo_line_to(cr, px(0.975), py(0.76));
  cairo_curve_to(cr, px(0.99), py(0.92), px(0.92), py(0.97), px(0.82),
                 py(0.92));
  cairo_curve_to(cr, px(0.64), py(0.84), px(0.36), py(0.84), px(0.18),
                 py(0.92));
  cairo_curve_to(cr, px(0.08), py(0.97), px(0.01), py(0.92), px(0.025),
                 py(0.76));
  cairo_line_to(cr, px(0.065), py(0.19));
  cairo_curve_to(cr, px(0.07), py(0.09), px(0.11), py(0.04), px(0.22),
                 py(0.04));
  cairo_close_path(cr);
}

// A value easing from |from| to |to| over |length| milliseconds from
// |start|: out (fast, then settling) for what opens, in for what tucks.
struct Tween {
  double from;
  double to;
  double start;
  double length;
  bool ease_in;

  double At(double now) const {
    if (length <= 0.0 || now >= start + length) {
      return to;
    }
    const double t = std::max(0.0, (now - start) / length);
    const double e = ease_in ? t * t * t : 1.0 - std::pow(1.0 - t, 3.0);
    return from + (to - from) * e;
  }

  bool Done(double now) const { return now >= start + length; }
};

// Defined at the end of the file, after gdkx.h, whose Xlib macros (Bool,
// Status, None) would otherwise reach everything here.
bool OnX11();

}  // namespace

class Island {
 public:
  explicit Island(FlBinaryMessenger* messenger);
  ~Island();

  Island(const Island&) = delete;
  Island& operator=(const Island&) = delete;

 private:
  enum class Kind { kSay, kItems };

  // One item as Dart describes it.
  struct Item {
    std::string key;
    std::string title;
    // Shown in place of the title while its row is hovered: a text's first
    // line, kept off the screen until the pointer asks for it.
    std::string reveal;
    bool has_reveal = false;
    std::string meta;
    std::shared_ptr<GdkPixbuf> icon;
    std::string thumb;
    std::string drag_file;
    std::string drag_text;
    bool has_drag_text = false;
    std::vector<std::string> actions;
    std::string mark;
    bool has_mark = false;
    bool mark_error = false;
  };

  // Rows and buttons as laid out, in logical pixels: a row's from the
  // pill's top-left corner, a button's from its row's.
  struct Box {
    double x;
    double y;
    double w;
    double h;

    bool Contains(double px, double py) const {
      return px >= x && px < x + w && py >= y && py < y + h;
    }
  };
  struct Button {
    Box box;
    std::string action;
  };
  struct Row {
    size_t item = 0;
    double y = 0.0;
    double text_x = 0.0;
    double text_w = 0.0;
    std::string line;
    std::vector<Button> buttons;
  };
  struct Hit {
    int row = -1;
    int button = -1;
  };

  // GTK and the channel call in here.
  static void OnMethod(FlMethodChannel* channel, FlMethodCall* call,
                       gpointer data);
  static gboolean OnDraw(GtkWidget* widget, cairo_t* cr, gpointer data);
  static gboolean OnMotion(GtkWidget* widget, GdkEventMotion* event,
                           gpointer data);
  static gboolean OnCrossing(GtkWidget* widget, GdkEventCrossing* event,
                             gpointer data);
  static gboolean OnPress(GtkWidget* widget, GdkEventButton* event,
                          gpointer data);
  static gboolean OnRelease(GtkWidget* widget, GdkEventButton* event,
                            gpointer data);
  static void OnDragBegin(GtkWidget* widget, GdkDragContext* context,
                          gpointer data);
  static void OnDragDataGet(GtkWidget* widget, GdkDragContext* context,
                            GtkSelectionData* selection, guint info,
                            guint time, gpointer data);
  static void OnDragEnd(GtkWidget* widget, GdkDragContext* context,
                        gpointer data);
  static gboolean OnTuck(gpointer data);
  static gboolean OnFrame(gpointer data);
  static void OnThumb(GObject* source, GAsyncResult* result, gpointer data);

  void Handle(FlMethodCall* call);
  void Respond(FlMethodCall* call, FlValue* result);

  // Showing and tucking away.
  bool EnsureWindow();
  bool Place();
  void Show();
  void Hide();
  void Tucked();
  void CancelClose();
  bool IsUp() const { return visible_ && !tucking_; }
  void Schedule(guint milliseconds);
  void Tuck();
  void Announce();
  bool Mark(const std::string& key, bool has_mark, const std::string& mark,
            bool error);
  void Drop(const std::string& key);

  // Hover, clicks and drags.
  bool Pointer(double* x, double* y) const;
  bool PointerInside() const;
  void SyncHover();
  void Hover(bool inside, Hit hit);
  void HoverChanged(bool inside);
  Hit HitTest(double x, double y) const;
  void Move(double x, double y, GdkEvent* event);
  void Down(double x, double y);
  void Up(double x, double y);
  void StartDrag(GdkEvent* event, double x, double y);
  void Send(const std::string& key, const std::string& action);

  // Layout and animation.
  double Left() const;
  double Top() const;
  void Relayout();
  Row LayRow(size_t index, double y);
  void Resize();
  void Animate();
  bool Step();
  void UpdateShape();

  // Drawing.
  void Draw(cairo_t* cr);
  void DrawPill(cairo_t* cr, double x, double y, double w, double h);
  void DrawHeader(cairo_t* cr, double x, double y);
  void DrawRow(cairo_t* cr, size_t index, double x, double y);
  void DrawTile(cairo_t* cr, const Item& item, double x, double y,
                double size, double ring);
  PangoLayout* Layout(const std::string& text,
                      const PangoFontDescription* font);
  void Text(cairo_t* cr, const std::string& text,
            const PangoFontDescription* font, double x, double y, double w,
            double h, const Rgba& color, PangoEllipsizeMode ellipsize,
            PangoAlignment align);
  double Measure(const std::string& text, const PangoFontDescription* font);
  std::string SayLine() const;
  GdkPixbuf* ThumbFor(const std::string& path);
  void Thumbnailed(const std::string& path, GdkPixbuf* pixbuf);

  FlMethodChannel* channel_ = nullptr;
  bool available_ = false;
  GtkWidget* window_ = nullptr;
  bool composited_ = false;
  PangoFontDescription* title_font_ = nullptr;
  PangoFontDescription* mono_font_ = nullptr;
  PangoFontDescription* button_font_ = nullptr;

  // What it shows.
  Kind kind_ = Kind::kSay;
  std::string say_text_;
  bool say_ok_ = true;
  std::string sender_;
  std::vector<Item> items_;
  size_t count_ = 0;
  std::vector<Row> rows_;
  double target_w_ = kWidth;
  double target_h_ = kSayHeight;

  // How far along: the pill's size and presence (0 gone, 1 in place) as
  // they ease.
  double width_ = kWidth;
  double height_ = kSayHeight;
  double presence_ = 0.0;
  Tween presence_tween_ = {0.0, 0.0, 0.0, 0.0, false};
  Tween width_tween_ = {kWidth, kWidth, 0.0, 0.0, false};
  Tween height_tween_ = {kSayHeight, kSayHeight, 0.0, 0.0, false};
  guint frame_source_ = 0;
  guint tuck_source_ = 0;
  // The desktop's animations off: no slide, no easing of its size.
  bool calm_ = false;

  bool visible_ = false;
  bool tucking_ = false;
  bool dragging_ = false;
  // The pointer is on the pill; several items open into their rows then.
  bool expanded_ = false;
  int hover_row_ = -1;
  int hover_button_ = -1;
  int pressed_row_ = -1;
  int pressed_button_ = -1;
  double down_x_ = 0.0;
  double down_y_ = 0.0;
  // What the drag running now hands over.
  Item drag_item_;

  std::map<std::string, std::shared_ptr<GdkPixbuf>> thumbs_;
  std::set<std::string> decoding_;
};

namespace {

// The one island, for thumbnails that finish decoding after it is gone
// (plop quitting).
Island* g_island = nullptr;

}  // namespace

Island::Island(FlBinaryMessenger* messenger) {
  g_island = this;
  available_ = OnX11();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel_ = fl_method_channel_new(messenger, "plop/island",
                                   FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel_, OnMethod, this, nullptr);

  // The desktop's own interface font, at the macOS island's sizes.
  g_autofree gchar* ui = nullptr;
  g_object_get(gtk_settings_get_default(), "gtk-font-name", &ui, nullptr);
  title_font_ = pango_font_description_from_string(ui != nullptr ? ui : "Sans");
  pango_font_description_unset_fields(title_font_, PANGO_FONT_MASK_SIZE);
  pango_font_description_set_absolute_size(title_font_, 13 * PANGO_SCALE);
  pango_font_description_set_weight(title_font_, PANGO_WEIGHT_SEMIBOLD);
  button_font_ = pango_font_description_copy(title_font_);
  pango_font_description_set_absolute_size(button_font_, 12 * PANGO_SCALE);
  pango_font_description_set_weight(button_font_, PANGO_WEIGHT_MEDIUM);
  mono_font_ = pango_font_description_from_string("Monospace");
  pango_font_description_set_absolute_size(mono_font_, 11 * PANGO_SCALE);
}

Island::~Island() {
  g_island = nullptr;
  if (tuck_source_ != 0) {
    g_source_remove(tuck_source_);
  }
  if (frame_source_ != 0) {
    g_source_remove(frame_source_);
  }
  fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr,
                                            nullptr);
  g_clear_object(&channel_);
  if (window_ != nullptr) {
    gtk_widget_destroy(window_);
  }
  pango_font_description_free(title_font_);
  pango_font_description_free(button_font_);
  pango_font_description_free(mono_font_);
}

void Island::OnMethod(FlMethodChannel* channel, FlMethodCall* call,
                      gpointer data) {
  static_cast<Island*>(data)->Handle(call);
}

// Answers |call| with |result|, which it takes.
void Island::Respond(FlMethodCall* call, FlValue* result) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  fl_method_call_respond(call, response, nullptr);
  if (result != nullptr) {
    fl_value_unref(result);
  }
}

void Island::Handle(FlMethodCall* call) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (g_strcmp0(method, "available") == 0) {
    // Only X11 lets a window be put in the corner above the panel.
    Respond(call, fl_value_new_bool(available_));
  } else if (g_strcmp0(method, "show") == 0) {
    std::vector<Item> items;
    FlValue* list = Find(args, "items");
    const size_t n = list != nullptr &&
                             fl_value_get_type(list) == FL_VALUE_TYPE_LIST
                         ? fl_value_get_length(list)
                         : 0;
    for (size_t i = 0; i < n; ++i) {
      FlValue* m = fl_value_get_list_value(list, i);
      if (String(m, "key").empty()) {
        continue;
      }
      Item item;
      item.key = String(m, "key");
      item.title = String(m, "title");
      item.has_reveal = Has(m, "reveal");
      item.reveal = String(m, "reveal");
      item.meta = String(m, "meta");
      FlValue* png = Find(m, "icon");
      if (png != nullptr &&
          fl_value_get_type(png) == FL_VALUE_TYPE_UINT8_LIST) {
        item.icon = DecodePng(fl_value_get_uint8_list(png),
                              fl_value_get_length(png));
      }
      item.thumb = String(m, "thumb");
      item.drag_file = String(m, "dragFile");
      item.has_drag_text = Has(m, "dragText");
      item.drag_text = String(m, "dragText");
      FlValue* actions = Find(m, "actions");
      if (actions != nullptr &&
          fl_value_get_type(actions) == FL_VALUE_TYPE_LIST) {
        for (size_t a = 0; a < fl_value_get_length(actions); ++a) {
          FlValue* action = fl_value_get_list_value(actions, a);
          if (fl_value_get_type(action) == FL_VALUE_TYPE_STRING) {
            item.actions.push_back(fl_value_get_string(action));
          }
        }
      }
      item.has_mark = Has(m, "mark");
      item.mark = String(m, "mark");
      item.mark_error = Flag(m, "error", false);
      items.push_back(item);
    }
    if (!items.empty()) {
      kind_ = Kind::kItems;
      sender_ = String(args, "sender");
      items_ = items;
      const int64_t count = std::max<int64_t>(Int(args, "count", 0), 0);
      count_ = std::max(static_cast<size_t>(count), items_.size());
      Show();
    }
    Respond(call, nullptr);
  } else if (g_strcmp0(method, "say") == 0) {
    kind_ = Kind::kSay;
    say_text_ = String(args, "text");
    say_ok_ = Flag(args, "ok", true);
    items_.clear();
    count_ = 0;
    Show();
    Respond(call, nullptr);
  } else if (g_strcmp0(method, "mark") == 0) {
    // Answers whether the row was there to take it; Dart says it on its
    // own otherwise.
    const bool applied = Mark(String(args, "key"), Has(args, "mark"),
                              String(args, "mark"), Flag(args, "error", false));
    Respond(call, fl_value_new_bool(applied));
  } else if (g_strcmp0(method, "drop") == 0) {
    // Gone from the shelf (expired, or taken back) while showing.
    Drop(String(args, "key"));
    Respond(call, nullptr);
  } else if (g_strcmp0(method, "hide") == 0) {
    Hide();
    Respond(call, nullptr);
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
  }
}

// MARK: showing and tucking away

bool Island::EnsureWindow() {
  if (window_ != nullptr) {
    return true;
  }
  if (!available_) {
    return false;
  }
  // Created on first use. A popup: override-redirect, so no decorations,
  // no taskbar or pager entry, never focused; the hints say the same to
  // anything that reads them.
  window_ = gtk_window_new(GTK_WINDOW_POPUP);
  GtkWindow* window = GTK_WINDOW(window_);
  gtk_window_set_type_hint(window, GDK_WINDOW_TYPE_HINT_NOTIFICATION);
  gtk_window_set_keep_above(window, TRUE);
  gtk_window_set_accept_focus(window, FALSE);
  gtk_window_set_focus_on_map(window, FALSE);
  gtk_window_set_skip_taskbar_hint(window, TRUE);
  gtk_window_set_skip_pager_hint(window, TRUE);
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_resizable(window, FALSE);
  gtk_window_set_title(window, "plop");
  gtk_widget_set_app_paintable(window_, TRUE);
  GdkScreen* screen = gtk_widget_get_screen(window_);
  GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
  composited_ = visual != nullptr && gdk_screen_is_composited(screen);
  if (composited_) {
    gtk_widget_set_visual(window_, visual);
  }
  gtk_widget_set_size_request(window_, kWindowWidth, kWindowHeight);
  gtk_window_resize(window, kWindowWidth, kWindowHeight);
  gtk_widget_add_events(window_, GDK_POINTER_MOTION_MASK |
                                     GDK_BUTTON_PRESS_MASK |
                                     GDK_BUTTON_RELEASE_MASK |
                                     GDK_ENTER_NOTIFY_MASK |
                                     GDK_LEAVE_NOTIFY_MASK);
  g_signal_connect(window_, "draw", G_CALLBACK(OnDraw), this);
  g_signal_connect(window_, "motion-notify-event", G_CALLBACK(OnMotion), this);
  g_signal_connect(window_, "enter-notify-event", G_CALLBACK(OnCrossing),
                   this);
  g_signal_connect(window_, "leave-notify-event", G_CALLBACK(OnCrossing),
                   this);
  g_signal_connect(window_, "button-press-event", G_CALLBACK(OnPress), this);
  g_signal_connect(window_, "button-release-event", G_CALLBACK(OnRelease),
                   this);
  g_signal_connect(window_, "drag-begin", G_CALLBACK(OnDragBegin), this);
  g_signal_connect(window_, "drag-data-get", G_CALLBACK(OnDragDataGet), this);
  g_signal_connect(window_, "drag-end", G_CALLBACK(OnDragEnd), this);
  gtk_widget_realize(window_);
  return true;
}

// Puts the window at the bottom-right of the work area (the monitor less
// its panels, wherever they are) of the monitor the pointer is on, as the
// macOS island takes the pointer's screen.
bool Island::Place() {
  GdkDisplay* display = gtk_widget_get_display(window_);
  GdkSeat* seat = gdk_display_get_default_seat(display);
  GdkDevice* pointer = seat != nullptr ? gdk_seat_get_pointer(seat) : nullptr;
  int x = 0;
  int y = 0;
  if (pointer != nullptr) {
    gdk_device_get_position(pointer, nullptr, &x, &y);
  }
  GdkMonitor* monitor = gdk_display_get_monitor_at_point(display, x, y);
  if (monitor == nullptr) {
    monitor = gdk_display_get_primary_monitor(display);
  }
  if (monitor == nullptr) {
    return false;
  }
  GdkRectangle work = {0, 0, 0, 0};
  gdk_monitor_get_workarea(monitor, &work);
  gtk_window_move(GTK_WINDOW(window_),
                  work.x + work.width - kMargin + kShadow - kWindowWidth,
                  work.y + work.height - kMargin + kShadow + kSlide -
                      kWindowHeight);
  return true;
}

void Island::Show() {
  if (!EnsureWindow()) {
    return;
  }
  gboolean animations = TRUE;
  g_object_get(gtk_settings_get_default(), "gtk-enable-animations",
               &animations, nullptr);
  calm_ = !animations;
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
    presence_tween_ = {presence_, 1.0, now, calm_ ? 0.0 : 150.0, false};
    Resize();
  } else {
    if (!Place()) {
      return;
    }
    width_ = target_w_;
    height_ = target_h_;
    width_tween_ = {width_, width_, now, 0.0, false};
    height_tween_ = {height_, height_, now, 0.0, false};
    presence_ = 0.0;
    presence_tween_ = {0.0, 1.0, now, calm_ ? 120.0 : 220.0, false};
    visible_ = true;
    tucking_ = false;
    UpdateShape();
    gtk_widget_show(window_);
    Animate();
  }
  // Above whatever was raised since it was mapped.
  GdkWindow* window = gtk_widget_get_window(window_);
  if (window != nullptr) {
    gdk_window_raise(window);
  }
  SyncHover();
  Announce();
  Schedule(kind_ == Kind::kSay ? 2200 : count_ > 1 ? 7000 : 5000);
}

// What a screen reader finds as the window's name: what arrived, never a
// text's words, as the macOS island announces it.
void Island::Announce() {
  std::string line;
  if (kind_ == Kind::kSay) {
    line = say_text_;
  } else if (count_ > 1) {
    line = std::to_string(count_) + " from " + sender_;
  } else if (!items_.empty()) {
    line = items_.front().title + " from " + sender_;
  }
  line = OneLine(line);
  gtk_window_set_title(GTK_WINDOW(window_), line.c_str());
  atk_object_set_name(gtk_widget_get_accessible(window_), line.c_str());
}

// Tucks the pill away after |milliseconds|, or later while the pointer is
// on it or something is being dragged out of it: the timer asks, rather
// than trusting enter and leave events, which a pill resized under a still
// pointer can miss.
void Island::Schedule(guint milliseconds) {
  if (tuck_source_ != 0) {
    g_source_remove(tuck_source_);
  }
  tuck_source_ = g_timeout_add(milliseconds, OnTuck, this);
}

gboolean Island::OnTuck(gpointer data) {
  auto* self = static_cast<Island*>(data);
  self->tuck_source_ = 0;
  self->Tuck();
  return G_SOURCE_REMOVE;
}

void Island::Tuck() {
  if (dragging_ || PointerInside()) {
    Schedule(1000);
  } else {
    Hide();
  }
}

void Island::Hide() {
  if (tuck_source_ != 0) {
    g_source_remove(tuck_source_);
    tuck_source_ = 0;
  }
  if (!visible_ || tucking_) {
    return;
  }
  tucking_ = true;
  presence_tween_ = {presence_, 0.0, Now(), calm_ ? 120.0 : 180.0, true};
  Animate();
}

// Faded out: off the screen, and Dart told, so the next arrival starts a
// new pill.
void Island::Tucked() {
  tucking_ = false;
  visible_ = false;
  expanded_ = false;
  hover_row_ = -1;
  hover_button_ = -1;
  gtk_widget_hide(window_);
  thumbs_.clear();
  fl_method_channel_invoke_method(channel_, "hidden", nullptr, nullptr,
                                  nullptr, nullptr);
}

// The pointer came back while it was tucking away: it stays.
void Island::CancelClose() {
  tucking_ = false;
  presence_tween_ = {presence_, 1.0, Now(), calm_ ? 0.0 : 150.0, false};
  Animate();
}

bool Island::Mark(const std::string& key, bool has_mark,
                  const std::string& mark, bool error) {
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
    gtk_widget_queue_draw(window_);
    Schedule(1600);
    return true;
  }
  return false;
}

void Island::Drop(const std::string& key) {
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

// Where the pointer is, from the pill's top-left corner.
bool Island::Pointer(double* x, double* y) const {
  GdkWindow* window =
      window_ != nullptr ? gtk_widget_get_window(window_) : nullptr;
  GdkDisplay* display =
      window != nullptr ? gdk_window_get_display(window) : nullptr;
  GdkSeat* seat =
      display != nullptr ? gdk_display_get_default_seat(display) : nullptr;
  GdkDevice* pointer = seat != nullptr ? gdk_seat_get_pointer(seat) : nullptr;
  if (pointer == nullptr) {
    return false;
  }
  int px = 0;
  int py = 0;
  gdk_window_get_device_position(window, pointer, &px, &py, nullptr);
  *x = px - Left();
  *y = py - Top();
  return true;
}

bool Island::PointerInside() const {
  double x = 0.0;
  double y = 0.0;
  return visible_ && Pointer(&x, &y) && x >= 0.0 && y >= 0.0 && x < width_ &&
         y < height_;
}

// After a show or a resize the pointer may be on the pill, or on another
// row of it, with no event to say so yet.
void Island::SyncHover() {
  double x = 0.0;
  double y = 0.0;
  if (!visible_ || !Pointer(&x, &y)) {
    return;
  }
  Hover(PointerInside(), HitTest(x, y));
}

void Island::Hover(bool inside, Hit hit) {
  const bool moved = hit.row != hover_row_ || hit.button != hover_button_;
  hover_row_ = hit.row;
  hover_button_ = hit.button;
  if (inside != expanded_) {
    HoverChanged(inside);
  }
  if (moved && visible_) {
    gtk_widget_queue_draw(window_);
  }
}

void Island::HoverChanged(bool inside) {
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

Island::Hit Island::HitTest(double x, double y) const {
  Hit hit;
  if (x < 0.0 || y < 0.0 || x >= width_ || y >= height_) {
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

gboolean Island::OnMotion(GtkWidget* widget, GdkEventMotion* event,
                          gpointer data) {
  static_cast<Island*>(data)->Move(event->x, event->y,
                                   reinterpret_cast<GdkEvent*>(event));
  return TRUE;
}

gboolean Island::OnCrossing(GtkWidget* widget, GdkEventCrossing* event,
                            gpointer data) {
  auto* self = static_cast<Island*>(data);
  if (event->type == GDK_LEAVE_NOTIFY && event->mode == GDK_CROSSING_NORMAL) {
    // Off the pill: its edge can still count as on it by the numbers.
    // Not while a row is held, which keeps the pointer's events coming.
    if (!self->dragging_ && self->pressed_row_ < 0) {
      self->Hover(false, Hit{});
    }
  } else {
    self->Move(event->x, event->y, nullptr);
  }
  return FALSE;
}

gboolean Island::OnPress(GtkWidget* widget, GdkEventButton* event,
                         gpointer data) {
  if (event->type == GDK_BUTTON_PRESS && event->button == 1) {
    static_cast<Island*>(data)->Down(event->x, event->y);
  }
  return TRUE;
}

gboolean Island::OnRelease(GtkWidget* widget, GdkEventButton* event,
                           gpointer data) {
  if (event->button == 1) {
    static_cast<Island*>(data)->Up(event->x, event->y);
  }
  return TRUE;
}

// |x| and |y| from the window's top-left corner, as GTK gives them.
void Island::Move(double x, double y, GdkEvent* event) {
  // A row pressed and pulled far enough drags its file or text out.
  if (pressed_row_ >= 0 && pressed_button_ < 0 && !dragging_ &&
      event != nullptr &&
      gtk_drag_check_threshold(window_, static_cast<int>(down_x_),
                               static_cast<int>(down_y_),
                               static_cast<int>(x), static_cast<int>(y))) {
    StartDrag(event, x, y);
    return;
  }
  if (dragging_) {
    return;
  }
  const double lx = x - Left();
  const double ly = y - Top();
  const bool inside =
      lx >= 0.0 && ly >= 0.0 && lx < width_ && ly < height_ && visible_;
  Hover(inside, HitTest(lx, ly));
}

void Island::Down(double x, double y) {
  const Hit hit = HitTest(x - Left(), y - Top());
  if (hit.row < 0) {
    return;
  }
  pressed_row_ = hit.row;
  pressed_button_ = hit.button;
  down_x_ = x;
  down_y_ = y;
  gtk_widget_queue_draw(window_);
}

void Island::Up(double x, double y) {
  const int row = pressed_row_;
  const int button = pressed_button_;
  pressed_row_ = -1;
  pressed_button_ = -1;
  if (row < 0 || static_cast<size_t>(row) >= rows_.size()) {
    return;
  }
  const Row& pressed = rows_[static_cast<size_t>(row)];
  const std::string key = items_[pressed.item].key;
  if (button < 0) {
    // A click on the row, not dragged: the shelf, or where it was saved.
    Send(key, "open");
  } else if (static_cast<size_t>(button) < pressed.buttons.size()) {
    const Hit hit = HitTest(x - Left(), y - Top());
    if (hit.row == row && hit.button == button) {
      Send(key, pressed.buttons[static_cast<size_t>(button)].action);
    }
  }
  if (visible_) {
    gtk_widget_queue_draw(window_);
  }
}

// Drags the pressed row's file (as a file URI, which file managers copy
// from and most apps take) or its text, copying, never moving: the file is
// the shelf's. The tuck timer keeps asking meanwhile, and waits.
void Island::StartDrag(GdkEvent* event, double x, double y) {
  const int row = pressed_row_;
  pressed_row_ = -1;
  pressed_button_ = -1;
  if (row < 0 || static_cast<size_t>(row) >= rows_.size()) {
    return;
  }
  const Item& item = items_[rows_[static_cast<size_t>(row)].item];
  GtkTargetList* targets = gtk_target_list_new(nullptr, 0);
  if (!item.drag_file.empty()) {
    gtk_target_list_add_uri_targets(targets, kUriTarget);
  } else if (item.has_drag_text) {
    gtk_target_list_add_text_targets(targets, kTextTarget);
  } else {
    gtk_target_list_unref(targets);
    return;
  }
  drag_item_ = item;
  dragging_ = true;
  GdkDragContext* context = gtk_drag_begin_with_coordinates(
      window_, targets, GDK_ACTION_COPY, 1, event, static_cast<int>(x),
      static_cast<int>(y));
  gtk_target_list_unref(targets);
  if (context == nullptr) {
    dragging_ = false;
  }
  gtk_widget_queue_draw(window_);
}

// The dragged item's tile under the pointer.
void Island::OnDragBegin(GtkWidget* widget, GdkDragContext* context,
                         gpointer data) {
  auto* self = static_cast<Island*>(data);
  GdkWindow* window = gtk_widget_get_window(widget);
  if (window == nullptr) {
    return;
  }
  const int size = static_cast<int>(kTile);
  cairo_surface_t* surface = gdk_window_create_similar_image_surface(
      window, CAIRO_FORMAT_ARGB32, size, size, 0);
  cairo_t* cr = cairo_create(surface);
  self->DrawTile(cr, self->drag_item_, 0.0, 0.0, kTile, 0.0);
  cairo_destroy(cr);
  gtk_drag_set_icon_surface(context, surface);
  cairo_surface_destroy(surface);
}

void Island::OnDragDataGet(GtkWidget* widget, GdkDragContext* context,
                           GtkSelectionData* selection, guint info,
                           guint time, gpointer data) {
  auto* self = static_cast<Island*>(data);
  const Item& item = self->drag_item_;
  if (info == kUriTarget && !item.drag_file.empty()) {
    gchar* uri = g_filename_to_uri(item.drag_file.c_str(), nullptr, nullptr);
    if (uri != nullptr) {
      gchar* uris[] = {uri, nullptr};
      gtk_selection_data_set_uris(selection, uris);
      g_free(uri);
    }
  } else if (info == kTextTarget) {
    gtk_selection_data_set_text(selection, item.drag_text.c_str(), -1);
  }
}

void Island::OnDragEnd(GtkWidget* widget, GdkDragContext* context,
                       gpointer data) {
  auto* self = static_cast<Island*>(data);
  self->dragging_ = false;
  self->Schedule(2500);
  self->SyncHover();
}

void Island::Send(const std::string& key, const std::string& action) {
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "key", fl_value_new_string(key.c_str()));
  fl_value_set_string_take(args, "action",
                           fl_value_new_string(action.c_str()));
  fl_method_channel_invoke_method(channel_, "action", args, nullptr, nullptr,
                                  nullptr);
}

// MARK: layout and animation

// The pill's top-left corner in the window: its bottom-right corner sits
// kShadow in from the window's, lower by however far it has still to rise.
double Island::Left() const {
  return kWindowWidth - kShadow - width_;
}

double Island::Top() const {
  const double lift = calm_ ? 0.0 : kSlide * (1.0 - presence_);
  return kWindowHeight - kShadow - kSlide + lift - height_;
}

// One item shows as its row; several show as a line saying how many,
// opening into their rows (up to four) on hover. Sizes the pill for that.
void Island::Relayout() {
  rows_.clear();
  if (kind_ == Kind::kSay) {
    const double text = std::ceil(Measure(SayLine(), title_font_));
    target_w_ = std::max(200.0, std::min(text + 48.0, kWidth));
    target_h_ = kSayHeight;
  } else {
    target_w_ = kWidth;
    double y = kTop;
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
Island::Row Island::LayRow(size_t index, double y) {
  const Item& item = items_[index];
  Row row;
  row.item = index;
  row.y = y;
  double right = kWidth - kPad;
  for (auto it = item.actions.rbegin(); it != item.actions.rend(); ++it) {
    const double w = std::ceil(Measure(*it, button_font_)) + 24.0;
    right -= w;
    row.buttons.insert(row.buttons.begin(),
                       Button{Box{right, 12.0, w, 28.0}, *it});
    right -= 6.0;
  }
  row.text_x = kPad + kTile + 12.0;
  row.text_w = std::max(right - 6.0 - row.text_x, 40.0);
  // Size and sender, as the shelf's rows put them; a long device name is
  // what gets cut, from the end.
  std::string line = item.meta;
  if (count_ == 1 && !sender_.empty()) {
    line = line.empty() ? sender_ : line + " · " + sender_;
  }
  row.line = OneLine(line);
  return row;
}

// Eases the pill to the size its contents want now; it stays anchored at
// its bottom-right corner, so it grows up and to the left.
void Island::Resize() {
  const double now = Now();
  const double length = calm_ ? 0.0 : 200.0;
  width_tween_ = {width_, target_w_, now, length, false};
  height_tween_ = {height_, target_h_, now, length, false};
  Animate();
}

void Island::Animate() {
  if (!Step()) {
    if (frame_source_ != 0) {
      g_source_remove(frame_source_);
      frame_source_ = 0;
    }
    return;
  }
  if (frame_source_ == 0) {
    frame_source_ = g_timeout_add(16, OnFrame, this);
  }
}

gboolean Island::OnFrame(gpointer data) {
  auto* self = static_cast<Island*>(data);
  if (self->Step()) {
    return G_SOURCE_CONTINUE;
  }
  self->frame_source_ = 0;
  return G_SOURCE_REMOVE;
}

// One frame; false once nothing is easing any more.
bool Island::Step() {
  const double now = Now();
  presence_ = presence_tween_.At(now);
  width_ = width_tween_.At(now);
  height_ = height_tween_.At(now);
  if (visible_) {
    UpdateShape();
    gtk_widget_queue_draw(window_);
  }
  if (!presence_tween_.Done(now) || !width_tween_.Done(now) ||
      !height_tween_.Done(now)) {
    return true;
  }
  if (tucking_ && visible_) {
    Tucked();
  }
  return false;
}

// Clicks land on the pill and go through everywhere else in the window;
// without a compositor the window is cut to the pill too, as nothing
// round it could be see-through.
void Island::UpdateShape() {
  cairo_surface_t* mask =
      cairo_image_surface_create(CAIRO_FORMAT_A1, kWindowWidth, kWindowHeight);
  cairo_t* cr = cairo_create(mask);
  RoundedRect(cr, Left(), Top(), width_, height_, kRadius);
  cairo_fill(cr);
  cairo_destroy(cr);
  cairo_region_t* region = gdk_cairo_region_create_from_surface(mask);
  cairo_surface_destroy(mask);
  gtk_widget_input_shape_combine_region(window_, region);
  if (!composited_) {
    gtk_widget_shape_combine_region(window_, region);
  }
  cairo_region_destroy(region);
}

// MARK: drawing

gboolean Island::OnDraw(GtkWidget* widget, cairo_t* cr, gpointer data) {
  static_cast<Island*>(data)->Draw(cr);
  return TRUE;
}

void Island::Draw(cairo_t* cr) {
  cairo_save(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.0);
  cairo_paint(cr);
  cairo_restore(cr);
  if (!visible_) {
    return;
  }
  if (composited_) {
    // Drawn whole, then laid down as opaque as it is present.
    cairo_push_group(cr);
    DrawPill(cr, Left(), Top(), width_, height_);
    cairo_pop_group_to_source(cr);
    cairo_paint_with_alpha(cr, std::max(0.0, std::min(presence_, 1.0)));
  } else {
    DrawPill(cr, Left(), Top(), width_, height_);
  }
}

void Island::DrawPill(cairo_t* cr, double x, double y, double w, double h) {
  if (composited_) {
    // A soft shadow: rings of faint black, wider and fainter outwards, a
    // little low.
    for (int i = 6; i >= 1; --i) {
      const double g = 1.5 * i;
      RoundedRect(cr, x - g, y - g + 2.0, w + 2.0 * g, h + 2.0 * g,
                  kRadius + g);
      Paint(cr, kShade);
      cairo_fill(cr);
    }
  }
  const double r = std::min(kRadius, h / 2.0);
  RoundedRect(cr, x, y, w, h, r);
  Paint(cr, kFill);
  cairo_fill(cr);

  // What it shows, laid out for its full size from its top-left corner and
  // cut to its outline while that eases to it.
  cairo_save(cr);
  RoundedRect(cr, x, y, w, h, r);
  cairo_clip(cr);
  if (kind_ == Kind::kSay) {
    Text(cr, SayLine(), title_font_, x + 16.0, y, w - 32.0, h,
         say_ok_ ? kText : kWarn, PANGO_ELLIPSIZE_END, PANGO_ALIGN_CENTER);
  } else {
    if (count_ > 1) {
      DrawHeader(cr, x, y + kTop);
    }
    for (size_t i = 0; i < rows_.size(); ++i) {
      DrawRow(cr, i, x, y + rows_[i].y);
    }
  }
  cairo_restore(cr);

  RoundedRect(cr, x + 0.5, y + 0.5, w - 1.0, h - 1.0, std::max(r - 0.5, 0.0));
  Paint(cr, kBorder);
  cairo_set_line_width(cr, 1.0);
  cairo_stroke(cr);
}

// "3 from Zain's iPhone", after the first three tiles stacked, the first on
// top; "hover" at the right until the pointer opens the rows.
void Island::DrawHeader(cairo_t* cr, double x, double y) {
  const size_t stacked = std::min<size_t>(items_.size(), 3);
  double left = x + kPad;
  for (size_t i = stacked; i-- > 0;) {
    DrawTile(cr, items_[i], left, y + 10.0, 24.0, 2.0);
    left += 14.0;
  }
  left += 18.0;
  Text(cr, OneLine(std::to_string(count_) + " from " + sender_), title_font_,
       left, y + 13.0, std::max(x + kWidth - left - kPad - 60.0, 20.0), 18.0,
       kText, PANGO_ELLIPSIZE_END, PANGO_ALIGN_LEFT);
  if (!expanded_) {
    Text(cr, "hover", mono_font_, x + kWidth - kPad - 60.0, y + 15.0, 60.0,
         16.0, kFaint, PANGO_ELLIPSIZE_END, PANGO_ALIGN_RIGHT);
  }
}

// One item: its tile, its name and line, its buttons.
void Island::DrawRow(cairo_t* cr, size_t index, double x, double y) {
  const Row& row = rows_[index];
  const Item& item = items_[row.item];
  const bool hovered = hover_row_ == static_cast<int>(index);
  DrawTile(cr, item, x + kPad, y + 9.0, kTile, 0.0);
  // Names lose their middle, keeping the extension, as the shelf's do.
  const std::string& title =
      hovered && item.has_reveal ? item.reveal : item.title;
  Text(cr, OneLine(title), title_font_, x + row.text_x, y + 8.0, row.text_w,
       18.0, kText, PANGO_ELLIPSIZE_MIDDLE, PANGO_ALIGN_LEFT);
  const Rgba& line_color =
      item.mark_error ? kWarn : item.has_mark ? kText : kDim;
  Text(cr, item.has_mark ? OneLine(item.mark) : row.line, mono_font_,
       x + row.text_x, y + 28.0, row.text_w, 15.0, line_color,
       PANGO_ELLIPSIZE_END, PANGO_ALIGN_LEFT);
  // Copied or saved: its buttons step back.
  const bool done = item.has_mark && !item.mark_error;
  for (size_t b = 0; b < row.buttons.size(); ++b) {
    const Button& button = row.buttons[b];
    const bool pressed = pressed_row_ == static_cast<int>(index) &&
                         pressed_button_ == static_cast<int>(b);
    const bool lit = hovered && hover_button_ == static_cast<int>(b);
    const double bx = x + button.box.x;
    const double by = y + button.box.y;
    RoundedRect(cr, bx + 0.5, by + 0.5, button.box.w - 1.0, button.box.h - 1.0,
                8.0);
    Paint(cr, pressed ? kBorder : lit ? kButtonHover : kButton);
    cairo_fill_preserve(cr);
    Paint(cr, kBorder);
    cairo_set_line_width(cr, 1.0);
    cairo_stroke(cr);
    Text(cr, button.action, button_font_, bx, by, button.box.w, button.box.h,
         done ? kDim : kText, PANGO_ELLIPSIZE_NONE, PANGO_ALIGN_CENTER);
  }
}

// The type tile Dart drew, or the picture itself in the bucket's shape;
// with |ring|, a margin of the pill's own black round it, so tiles stacked
// in the header read as separate ones.
void Island::DrawTile(cairo_t* cr, const Item& item, double x, double y,
                      double size, double ring) {
  if (ring > 0.0) {
    Bucket(cr, size + 2.0 * ring, x - ring, y - ring);
    Paint(cr, kFill);
    cairo_fill(cr);
  }
  GdkPixbuf* picture = item.thumb.empty() ? nullptr : ThumbFor(item.thumb);
  GdkPixbuf* image = picture != nullptr ? picture : item.icon.get();
  if (image == nullptr) {
    return;
  }
  const double w = std::max(gdk_pixbuf_get_width(image), 1);
  const double h = std::max(gdk_pixbuf_get_height(image), 1);
  cairo_save(cr);
  if (picture != nullptr) {
    Bucket(cr, size, x, y);
    cairo_clip(cr);
    Paint(cr, kPictureBack);
    cairo_paint(cr);
    // Aspect fill, centred.
    const double k = std::max(size / w, size / h);
    cairo_translate(cr, x + (size - w * k) / 2.0, y + (size - h * k) / 2.0);
    cairo_scale(cr, k, k);
  } else {
    cairo_translate(cr, x, y);
    cairo_scale(cr, size / w, size / h);
  }
  gdk_cairo_set_source_pixbuf(cr, image, 0.0, 0.0);
  cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
  cairo_paint(cr);
  cairo_restore(cr);
}

// One line of |text|, never wrapped.
PangoLayout* Island::Layout(const std::string& text,
                            const PangoFontDescription* font) {
  PangoLayout* layout = gtk_widget_create_pango_layout(window_, nullptr);
  pango_layout_set_font_description(layout, font);
  pango_layout_set_single_paragraph_mode(layout, TRUE);
  pango_layout_set_text(layout, text.c_str(), -1);
  return layout;
}

// |text| in the box at (x, y), centred on its height, cut with an ellipsis
// where it runs out of room.
void Island::Text(cairo_t* cr, const std::string& text,
                  const PangoFontDescription* font, double x, double y,
                  double w, double h, const Rgba& color,
                  PangoEllipsizeMode ellipsize, PangoAlignment align) {
  if (text.empty() || w <= 0.0) {
    return;
  }
  PangoLayout* layout = Layout(text, font);
  pango_layout_set_width(layout, static_cast<int>(w * PANGO_SCALE));
  pango_layout_set_ellipsize(layout, ellipsize);
  pango_layout_set_alignment(layout, align);
  int lw = 0;
  int lh = 0;
  pango_layout_get_pixel_size(layout, &lw, &lh);
  Paint(cr, color);
  cairo_move_to(cr, x, y + (h - lh) / 2.0);
  pango_cairo_show_layout(cr, layout);
  g_object_unref(layout);
}

double Island::Measure(const std::string& text,
                       const PangoFontDescription* font) {
  if (window_ == nullptr) {
    return 0.0;
  }
  PangoLayout* layout = Layout(text, font);
  int w = 0;
  int h = 0;
  pango_layout_get_pixel_size(layout, &w, &h);
  g_object_unref(layout);
  return w;
}

std::string Island::SayLine() const {
  return (say_ok_ ? "✓  " : "✕  ") + OneLine(say_text_);
}

// The thumbnail if it is decoded; otherwise null now and a redraw later.
// One that failed is not tried again until the pill has tucked away.
GdkPixbuf* Island::ThumbFor(const std::string& path) {
  auto found = thumbs_.find(path);
  if (found != thumbs_.end()) {
    return found->second.get();
  }
  if (decoding_.insert(path).second) {
    GTask* task = g_task_new(nullptr, nullptr, OnThumb, nullptr);
    g_task_set_task_data(task, g_strdup(path.c_str()), g_free);
    g_task_run_in_thread(task, DecodeThumb);
    g_object_unref(task);
  }
  return nullptr;
}

void Island::OnThumb(GObject* source, GAsyncResult* result, gpointer data) {
  GTask* task = G_TASK(result);
  const std::string path(static_cast<const char*>(g_task_get_task_data(task)));
  auto* pixbuf =
      static_cast<GdkPixbuf*>(g_task_propagate_pointer(task, nullptr));
  if (g_island == nullptr) {
    if (pixbuf != nullptr) {
      g_object_unref(pixbuf);
    }
    return;
  }
  g_island->Thumbnailed(path, pixbuf);
}

void Island::Thumbnailed(const std::string& path, GdkPixbuf* pixbuf) {
  decoding_.erase(path);
  thumbs_[path] = Own(pixbuf);
  if (visible_) {
    gtk_widget_queue_draw(window_);
  }
}

Island* island_new(FlBinaryMessenger* messenger) {
  return new Island(messenger);
}

void island_free(Island* island) {
  delete island;
}

// Last, for the reason at its declaration.
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

namespace {

bool OnX11() {
#ifdef GDK_WINDOWING_X11
  return GDK_IS_X11_DISPLAY(gdk_display_get_default());
#else
  return false;
#endif
}

}  // namespace
