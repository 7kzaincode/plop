import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = .black
    // Setting the content controller resizes the window to the view's
    // default size; keep the frame from MainMenu.xib instead.
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // A small utility window whose title bar melts into the black canvas.
    let background = NSColor(srgbRed: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)
    self.appearance = NSAppearance(named: .darkAqua)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.backgroundColor = background
    self.contentMinSize = NSSize(width: 360, height: 320)
    // Remember size and position, but skip macOS state restoration, which
    // would replay stale frames.
    self.isRestorable = false
    self.setFrameAutosaveName("plop.window")

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
