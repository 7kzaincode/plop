import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Closing the window only hides it: the shelf, its server and the global
  // shortcuts keep running. ⌘Q quits.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Clicking the Dock icon brings the window back.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      mainFlutterWindow?.makeKeyAndOrderFront(nil)
    }
    return true
  }

  // ⌘Tab and Mission Control only activate the app, with no reopen event, so
  // bring a closed window back here too. Closing the window does not
  // deactivate the app, so this never fires on close. A minimized (⌘M)
  // window is left alone, as macOS's own ⌘Tab does.
  override func applicationDidBecomeActive(_ notification: Notification) {
    if let w = mainFlutterWindow, !w.isVisible, !w.isMiniaturized {
      w.makeKeyAndOrderFront(nil)
    }
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
