import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  // Files dropped on the Dock icon (AppDelegate.swift), on the same contract
  // as the Android MainActivity: Dart asks for "initial" once it listens and
  // gets whatever arrived before that (a drop can cold-launch plop, long
  // before Dart has a handler); later drops are pushed as "shared".
  private var share: FlutterMethodChannel?
  private var pendingOpens: [String] = []
  private var dartListening = false

  func open(_ paths: [String]) {
    if dartListening {
      share?.invokeMethod("shared", arguments: ["paths": paths])
    } else {
      pendingOpens += paths
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = .clear

    // Frosted glass behind a transparent Flutter view. Dart paints the canvas
    // at 78% black on top, so text stays legible over any wallpaper.
    let windowFrame = self.frame
    let glass = NSVisualEffectView(frame: self.contentRect(forFrameRect: windowFrame))
    glass.material = .hudWindow
    glass.blendingMode = .behindWindow
    glass.state = .active  // stay glassy while plop is in the background
    let host = NSViewController()
    host.view = glass
    host.addChild(flutterViewController)
    flutterViewController.view.frame = glass.bounds
    flutterViewController.view.autoresizingMask = [.width, .height]
    glass.addSubview(flutterViewController.view)

    // Setting the content controller resizes the window to the view's
    // default size; keep the frame from MainMenu.xib instead.
    self.contentViewController = host
    self.setFrame(windowFrame, display: true)

    // One row of chrome: the content runs under the traffic lights and the
    // Dart top bar lines up with them.
    self.styleMask.insert(.fullSizeContentView)
    self.appearance = NSAppearance(named: .darkAqua)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.isOpaque = false
    self.backgroundColor = .clear
    self.contentMinSize = NSSize(width: 360, height: 320)
    // Remember size and position, but skip macOS state restoration, which
    // would replay stale frames.
    self.isRestorable = false
    self.setFrameAutosaveName("plop.window")

    // The Flutter view now covers the title bar, so it asks for drags and
    // zooms itself.
    let channel = FlutterMethodChannel(
      name: "plop/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let window = self else { return result(nil) }
      switch call.method {
      case "titlebar":
        result(Double(window.frame.height - window.contentLayoutRect.height))
      case "drag":
        if let event = NSApp.currentEvent {
          window.performDrag(with: event)
        }
        result(nil)
      case "zoom":
        window.performZoom(nil)
        result(nil)
      case "show":
        // Something needs the user's eyes while they are in another app (a
        // snip that failed for want of Screen Recording): bring the window
        // back, reopening it if it was closed.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        result(nil)
      case "loginItem":
        if #available(macOS 13.0, *) {
          result(SMAppService.mainApp.status == .enabled)
        } else {
          result(false)
        }
      case "setLoginItem":
        guard #available(macOS 13.0, *) else { return result(false) }
        do {
          if call.arguments as? Bool == true {
            try SMAppService.mainApp.register()
          } else {
            try SMAppService.mainApp.unregister()
          }
          result(SMAppService.mainApp.status == .enabled)
        } catch {
          result(SMAppService.mainApp.status == .enabled)
        }
      case "badge":
        // Things from other devices that landed while plop was closed or
        // behind other windows; lib/window.dart counts them and sends 0 once
        // the window is focused again. AppKit drops the bounce request when
        // plop is already frontmost.
        let args = call.arguments as? [String: Any]
        let count = args?["count"] as? Int ?? 0
        NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
        if args?["fresh"] as? Bool == true {
          NSApp.requestUserAttention(.informationalRequest)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let share = FlutterMethodChannel(
      name: "plop/share", binaryMessenger: flutterViewController.engine.binaryMessenger)
    share.setMethodCallHandler { [weak self] call, result in
      guard let window = self else { return result(nil) }
      guard call.method == "initial" else { return result(FlutterMethodNotImplemented) }
      window.dartListening = true
      result(window.pendingOpens.isEmpty ? nil : ["paths": window.pendingOpens])
      window.pendingOpens = []
    }
    self.share = share

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
