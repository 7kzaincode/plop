#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // lib/window.dart's "plop/window" channel; kept for the life of the app.
  FlMethodChannel* window_channel;
  // Set over that channel once the tray icon is up (lib/tray.dart): closing
  // the window then hides it and plop lives on in the tray, as on macOS.
  // Until then a close quits as it always did, so a desktop without a tray
  // can never be left with plop running and no way back to it.
  gboolean hide_on_close;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// The window's close button: hidden rather than destroyed while plop has a
// tray icon to come back from. Flutter's view hooks this event first and
// asks Dart whether the app may exit (lib/tray.dart answers with a hide while
// the icon is up, and the engine quits on "exit"); this is for a close that
// gets through to the window itself.
static gboolean window_delete_cb(GtkWidget* window, GdkEvent* event,
                                 gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (!self->hide_on_close) {
    return FALSE;  // destroyed as usual, and plop quits with it
  }
  gtk_widget_hide(window);
  return TRUE;
}

// "plop/window" from lib/window.dart: show (from the tray menu or a
// notification), hide, hideOnClose and quit. The taskbar "flash" the Windows
// runner answers has no portable equivalent here, so it is not implemented.
static void window_method_cb(FlMethodChannel* channel, FlMethodCall* call,
                             gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(self));
  GtkWindow* window = windows != nullptr ? GTK_WINDOW(windows->data) : nullptr;
  g_autoptr(FlMethodResponse) response = nullptr;
  gboolean quit = FALSE;
  if (g_strcmp0(method, "show") == 0) {
    // Shows a hidden window too, and unminimizes and raises as the window
    // manager allows (Wayland may only flag it as wanting attention).
    if (window != nullptr) {
      gtk_window_present(window);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "hide") == 0) {
    if (window != nullptr) {
      gtk_widget_hide(GTK_WIDGET(window));
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "hideOnClose") == 0) {
    self->hide_on_close = args != nullptr &&
                          fl_value_get_type(args) == FL_VALUE_TYPE_BOOL &&
                          fl_value_get_bool(args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "quit") == 0) {
    quit = TRUE;
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
  if (quit) {
    // Answered first; the main loop returns once this handler does.
    g_application_quit(G_APPLICATION(self));
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  // A second launch (see my_application_new) lands here in the running copy:
  // bring its window forward instead of adding another. gtk_window_present
  // also shows a window that was hidden into the tray (window_delete_cb).
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows != nullptr) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "plop");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "plop");
  }

  // Compact, like the macOS window, with the same minimum size.
  gtk_window_set_default_size(window, 460, 560);
  gtk_widget_set_size_request(GTK_WIDGET(window), 360, 320);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // The shelf's own canvas (Palette.bg), as the Windows runner paints its
  // caption, so a resize that outruns Flutter's next frame shows no seam.
  gdk_rgba_parse(&background_color, "#0A0A0A");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_cb), self);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "plop/window",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->window_channel,
                                            window_method_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);

  // Dark chrome whatever the desktop's theme, as the Windows runner's dark
  // caption and the macOS window's darkAqua give: the header bar takes the
  // theme's own dark variant (Yaru, Adwaita and Breeze all ship one), so on
  // a stock light Ubuntu it is no longer a white strip over the near-black
  // shelf. Only plop's windows change, not other apps', and the user's
  // theme stays theirs. A window manager's own title bar (X11 outside GNOME,
  // where the runner uses one) is drawn by it and not touched. Here, after
  // the parent's startup has initialised GTK and before any window exists,
  // and once per process: a second launch never gets this far.
  g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme",
               TRUE, nullptr);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // One plop per session: a second launch activates the running copy over
  // D-Bus (my_application_activate presents its window) and exits, instead
  // of starting a second node that wipes this one's scratch folders.
  // PLOP_INSTANCE (see lib/main.dart) opts out, so dev copies can still run
  // side by side; Debug builds are exempt too, so `flutter run` works while
  // an installed plop is open.
  GApplicationFlags flags = G_APPLICATION_NON_UNIQUE;
#ifdef NDEBUG
  if (g_getenv("PLOP_INSTANCE") == nullptr) {
    // G_APPLICATION_DEFAULT_FLAGS by value: the name needs GLib 2.74, and
    // its predecessor is deprecated on newer GLib.
    flags = static_cast<GApplicationFlags>(0);
  }
#endif

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}
