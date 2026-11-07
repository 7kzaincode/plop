import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Closing the window only hides it: the shelf, its server and the global
  // shortcuts keep running. ⌘Q quits.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Quitting is never refused on macOS (lib/tray.dart's onExitRequested
  // says exit here), so say so at once. FlutterAppDelegate answers every
  // request "cancel" while it asks Dart, then quits a moment later; to a
  // restart, shut down or log out that "cancel" is final ("plop canceled
  // restart"), and to AppleScript's quit an error.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return .terminateNow
  }

  // Clicking the Dock icon brings the window back. Whether the window
  // itself is up, not AppKit's flag, which can count the island's panel.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if let w = mainFlutterWindow, !w.isVisible {
      w.makeKeyAndOrderFront(nil)
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

  // Files dropped on the Dock icon go on the shelf, so the window never has
  // to be open to add something (Info.plist declares the document type).
  // Launch Services grants the sandbox access to files opened this way. The
  // drop activates the app, so applicationDidBecomeActive above shows the
  // window with the new row. Anything else (plop registers no URL schemes)
  // goes to FlutterAppDelegate, which hands it to plugins.
  override func application(_ application: NSApplication, open urls: [URL]) {
    let paths = urls.filter(\.isFileURL).map(\.path)
    if !paths.isEmpty {
      (mainFlutterWindow as? MainFlutterWindow)?.open(paths)
    }
    let rest = urls.filter { !$0.isFileURL }
    if !rest.isEmpty {
      super.application(application, open: rest)
    }
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
