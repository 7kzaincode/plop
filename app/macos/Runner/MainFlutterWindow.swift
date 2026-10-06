import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
