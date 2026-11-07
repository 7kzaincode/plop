import AppKit
import FlutterMacOS
import dnssd

/// lib/alias.dart's "plop/alias": answers for plop.local with this Mac's
/// LAN address, so a phone's home-screen icon saved with that name opens
/// the shelf here while no other computer of the user's has it.
///
/// One A record, registered through mDNSResponder as unique: it probes the
/// network first, and when another computer answers for the name already
/// (or later claims it and wins the tie-break) the callback says
/// NameConflict and the record is dropped, never renamed. Dart then lets go
/// and asks again later; see lib/alias.dart for that loop. mDNSResponder
/// does the work, so this runs inside the App Sandbox with the network
/// entitlements plop already has, as Bonjour registration always has. It
/// also answers for the record after a wake, re-probing first, and drops
/// it with a goodbye when the connection closes: on release, and when plop
/// quits, however it quits, and when the Mac goes to sleep: a sleeping Mac
/// can't serve the shelf, and without the goodbye phones would keep the
/// name pointing at it (and a sleep proxy would answer for it) while
/// another computer could have it.
final class Alias {
  private let channel: FlutterMethodChannel
  private var connection: DNSServiceRef?
  private var gen = 0

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "plop/alias", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let alias = self else { return result(nil) }
      switch call.method {
      case "claim":
        let args = call.arguments as? [String: Any]
        guard let ip = args?["ip"] as? String, let gen = args?["gen"] as? Int else {
          return result(FlutterError(code: "args", message: "ip and gen", details: nil))
        }
        result(nil)
        alias.claim(ip: ip, gen: gen)
      case "release":
        alias.release()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.letGoForSleep() }
  }

  /// Drops the record and tells Dart it is lost, which asks again a little
  /// after the wake (and waits, if another computer took it meanwhile).
  private func letGoForSleep() {
    guard connection != nil else { return }
    let held = gen
    release()
    channel.invokeMethod("state", arguments: ["state": "lost", "gen": held])
  }

  /// Registers the record on a connection of its own, replacing any
  /// earlier one, with its answers on the main queue (where the channel
  /// lives, and where the connection is deallocated, as the API wants).
  private func claim(ip: String, gen: Int) {
    release()
    self.gen = gen
    var addr = in_addr()
    guard inet_pton(AF_INET, ip, &addr) == 1 else { return report("lost") }
    var made: DNSServiceRef?
    guard DNSServiceCreateConnection(&made) == kDNSServiceErr_NoError, let conn = made else {
      return report("unavailable")  // no mDNSResponder to talk to
    }
    connection = conn
    DNSServiceSetDispatchQueue(conn, .main)
    var record: DNSRecordRef?
    let context = Unmanaged.passUnretained(self).toOpaque()
    let err = withUnsafeBytes(of: &addr) { bytes in
      DNSServiceRegisterRecord(
        conn, &record, DNSServiceFlags(kDNSServiceFlagsUnique), 0, "plop.local.",
        UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), UInt16(bytes.count),
        bytes.baseAddress, 120, Alias.answered, context)
    }
    if err != kDNSServiceErr_NoError {
      release()
      self.gen = gen
      report(err == kDNSServiceErr_NameConflict ? "conflict" : "lost")
    }
  }

  /// Closing the connection drops its record and sends the goodbye that
  /// lets another computer take the name at once.
  private func release() {
    gen += 1  // an answer still queued for the old record is not news
    if let conn = connection {
      DNSServiceRefDeallocate(conn)
      connection = nil
    }
  }

  private func report(_ state: String) {
    channel.invokeMethod("state", arguments: ["state": state, "gen": gen])
  }

  /// The record's fate: probed and announced, or a conflict (now or after
  /// a wake), or mDNSResponder gone (the connection with it). The Alias
  /// lives as long as the window, so the unretained context stays good;
  /// once released, the connection and its callbacks are gone.
  private static let answered: DNSServiceRegisterRecordReply = { _, _, _, err, context in
    guard let context else { return }
    let alias = Unmanaged<Alias>.fromOpaque(context).takeUnretainedValue()
    alias.report(
      err == kDNSServiceErr_NoError
        ? "won" : err == kDNSServiceErr_NameConflict ? "conflict" : "lost")
  }
}
