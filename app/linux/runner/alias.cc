#include "alias.h"

#include <gio/gio.h>

// Avahi's D-Bus API, as avahi-daemon serves it (avahi-common/defs.h has the
// numbers): an entry group holds records, is committed, and says how that
// went with StateChanged. One A record, plop.local at the claimed address,
// published unique: Avahi probes first, and when another computer answers
// for the name the group goes to COLLISION rather than to a renamed one.
// NO_REVERSE leaves out the address's PTR record, which this machine's own
// host name already holds and which would collide with itself.
//
// Avahi frees a client's groups when its D-Bus connection closes, so the
// name goes when plop does, however it quits; alias_free lets it go first.

namespace {

constexpr char kAvahi[] = "org.freedesktop.Avahi";
constexpr char kServer[] = "org.freedesktop.Avahi.Server";
constexpr char kGroup[] = "org.freedesktop.Avahi.EntryGroup";
constexpr gint32 kIfaceUnspec = -1;
constexpr gint32 kProtoUnspec = -1;
constexpr guint32 kNoReverse = 1 << 4;  // AVAHI_PUBLISH_NO_REVERSE
constexpr gint32 kEstablished = 2;      // AVAHI_ENTRY_GROUP_ESTABLISHED
constexpr gint32 kCollision = 3;        // AVAHI_ENTRY_GROUP_COLLISION

}  // namespace

struct Claim;

class Alias {
 public:
  FlMethodChannel* channel = nullptr;
  Claim* current = nullptr;
};

// One claim, from getting the bus to Avahi's answer. Counted: the Alias
// holds it while it is current, and each call in flight and the signal
// subscription hold it too, so a claim let go mid-way is freed once the
// last of them has come back. |owner| is cleared when it is let go, after
// which nothing it hears is news.
struct Claim {
  Alias* owner;
  gint64 gen;
  gchar* ip;
  GDBusConnection* bus;
  gchar* path;  // the entry group's object, once Avahi made one
  guint signal;
  GCancellable* cancel;
  int refs;
};

static Claim* claim_ref(Claim* c) {
  c->refs++;
  return c;
}

static void claim_unref(gpointer data) {
  Claim* c = static_cast<Claim*>(data);
  if (--c->refs > 0) return;
  g_free(c->ip);
  g_free(c->path);
  g_clear_object(&c->bus);
  g_clear_object(&c->cancel);
  g_free(c);
}

static void report(Alias* self, gint64 gen, const gchar* state) {
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "state", fl_value_new_string(state));
  fl_value_set_string_take(args, "gen", fl_value_new_int(gen));
  fl_method_channel_invoke_method(self->channel, "state", args, nullptr,
                                  nullptr, nullptr);
}

// Collision errors from Avahi itself (a name this machine already uses),
// else anything that went wrong on the way: Dart asks again later.
static const gchar* failure(GError* error) {
  g_autofree gchar* remote = g_dbus_error_get_remote_error(error);
  return remote != nullptr && g_str_has_suffix(remote, "CollisionError")
             ? "conflict"
             : "lost";
}

// Lets the current claim go: Avahi drops the group and says goodbye for
// its record, and another computer may take the name at once.
static void release(Alias* self) {
  Claim* c = self->current;
  if (c == nullptr) return;
  self->current = nullptr;
  c->owner = nullptr;
  g_cancellable_cancel(c->cancel);
  if (c->signal != 0) {
    g_dbus_connection_signal_unsubscribe(c->bus, c->signal);
    c->signal = 0;
  }
  if (c->path != nullptr) {
    g_dbus_connection_call(c->bus, kAvahi, c->path, kGroup, "Free", nullptr,
                           nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
                           nullptr, nullptr);
  }
  claim_unref(c);
}

static void state_cb(GDBusConnection* bus, const gchar* sender,
                     const gchar* path, const gchar* iface,
                     const gchar* signal, GVariant* params,
                     gpointer user_data) {
  Claim* c = static_cast<Claim*>(user_data);
  if (c->owner == nullptr) return;
  gint32 state = 0;
  const gchar* error = nullptr;
  g_variant_get(params, "(i&s)", &state, &error);
  if (state == kEstablished) {
    report(c->owner, c->gen, "won");
  } else if (state == kCollision) {
    report(c->owner, c->gen, "conflict");
  } else if (state > kCollision) {  // FAILURE
    report(c->owner, c->gen, "lost");
  }
}

static void committed_cb(GObject* source, GAsyncResult* result,
                         gpointer user_data) {
  Claim* c = static_cast<Claim*>(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (reply == nullptr && c->owner != nullptr) {
    report(c->owner, c->gen, failure(error));
  }
  claim_unref(c);
}

static void added_cb(GObject* source, GAsyncResult* result,
                     gpointer user_data) {
  Claim* c = static_cast<Claim*>(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (c->owner != nullptr) {
    if (reply == nullptr) {
      report(c->owner, c->gen, failure(error));
    } else {
      g_dbus_connection_call(c->bus, kAvahi, c->path, kGroup, "Commit",
                             nullptr, nullptr, G_DBUS_CALL_FLAGS_NONE, -1,
                             c->cancel, committed_cb, claim_ref(c));
    }
  }
  claim_unref(c);
}

static void group_cb(GObject* source, GAsyncResult* result,
                     gpointer user_data) {
  Claim* c = static_cast<Claim*>(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (reply != nullptr) {
    g_variant_get(reply, "(o)", &c->path);
  }
  if (c->owner == nullptr) {
    // Let go while Avahi made the group: it goes unused.
    if (c->path != nullptr) {
      g_dbus_connection_call(c->bus, kAvahi, c->path, kGroup, "Free", nullptr,
                             nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
                             nullptr, nullptr);
    }
  } else if (reply == nullptr) {
    // Avahi is not running (it is never started for this): the machine's
    // own address will do.
    report(c->owner, c->gen, "unavailable");
  } else {
    c->signal = g_dbus_connection_signal_subscribe(
        c->bus, kAvahi, kGroup, "StateChanged", c->path, nullptr,
        G_DBUS_SIGNAL_FLAGS_NONE, state_cb, claim_ref(c), claim_unref);
    g_dbus_connection_call(
        c->bus, kAvahi, c->path, kGroup, "AddAddress",
        g_variant_new("(iiuss)", kIfaceUnspec, kProtoUnspec, kNoReverse,
                      "plop.local", c->ip),
        nullptr, G_DBUS_CALL_FLAGS_NONE, -1, c->cancel, added_cb,
        claim_ref(c));
  }
  claim_unref(c);
}

static void bus_cb(GObject* source, GAsyncResult* result, gpointer user_data) {
  Claim* c = static_cast<Claim*>(user_data);
  g_autoptr(GError) error = nullptr;
  c->bus = g_bus_get_finish(result, &error);
  if (c->owner != nullptr) {
    if (c->bus == nullptr) {
      report(c->owner, c->gen, "unavailable");  // no system bus at all
    } else {
      g_dbus_connection_call(c->bus, kAvahi, "/", kServer, "EntryGroupNew",
                             nullptr, G_VARIANT_TYPE("(o)"),
                             G_DBUS_CALL_FLAGS_NO_AUTO_START, -1, c->cancel,
                             group_cb, claim_ref(c));
    }
  }
  claim_unref(c);
}

static void claim(Alias* self, const gchar* ip, gint64 gen) {
  release(self);
  Claim* c = g_new0(Claim, 1);
  c->owner = self;
  c->gen = gen;
  c->ip = g_strdup(ip);
  c->cancel = g_cancellable_new();
  c->refs = 1;  // the Alias's, until release
  self->current = c;
  g_bus_get(G_BUS_TYPE_SYSTEM, c->cancel, bus_cb, claim_ref(c));
}

static void method_cb(FlMethodChannel* channel, FlMethodCall* call,
                      gpointer user_data) {
  Alias* self = static_cast<Alias*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (g_strcmp0(method, "claim") == 0) {
    FlValue* ip = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                      ? fl_value_lookup_string(args, "ip")
                      : nullptr;
    FlValue* gen = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                       ? fl_value_lookup_string(args, "gen")
                       : nullptr;
    if (ip == nullptr || fl_value_get_type(ip) != FL_VALUE_TYPE_STRING ||
        gen == nullptr || fl_value_get_type(gen) != FL_VALUE_TYPE_INT) {
      fl_method_call_respond_error(call, "args", "ip and gen", nullptr,
                                   nullptr);
      return;
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
    claim(self, fl_value_get_string(ip), fl_value_get_int(gen));
  } else if (g_strcmp0(method, "release") == 0) {
    release(self);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

Alias* alias_new(FlBinaryMessenger* messenger) {
  Alias* self = new Alias();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(messenger, "plop/alias",
                                        FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_cb, self,
                                            nullptr);
  return self;
}

void alias_free(Alias* self) {
  if (self == nullptr) return;
  release(self);
  fl_method_channel_set_method_call_handler(self->channel, nullptr, nullptr,
                                            nullptr);
  g_clear_object(&self->channel);
  delete self;
}
