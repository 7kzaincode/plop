import Cocoa
import FlutterMacOS

// The island: a black pill that drops out of the MacBook's notch (or from
// the top edge of a screen without one) when something arrives from another
// device while plop is not in front, with copy and save right on it, and the
// files draggable out of it. It also says what a global shortcut did. Dart
// decides what to show and does the copying (lib/island.dart); this side only
// draws, animates, and reports clicks, hovers and drags.
//
// It never takes focus: a non-activating panel that cannot become key, whose
// controls take the first click, so whatever the user was typing in keeps
// the keyboard. Hovering holds it open; otherwise it tucks back into the
// notch after a few seconds.
//
// The panel keeps one size, as big as the island can get, and is clear
// outside the island's outline (clicks there go through to what is below);
// only the outline animates, so nothing is clipped or jumps mid-spring.

/// Shapes and colours shared by the views.
private enum Look {
  static let black = NSColor.black
  static let text = NSColor(white: 0.93, alpha: 1)
  static let dim = NSColor(white: 0.56, alpha: 1)
  static let faint = NSColor(white: 0.40, alpha: 1)
  static let button = NSColor(white: 0.13, alpha: 1)
  static let buttonHover = NSColor(white: 0.19, alpha: 1)
  static let border = NSColor(white: 1, alpha: 0.10)
  static let warn = NSColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1)

  /// The concave flare where the island meets the top edge, as the notch's
  /// own corners do.
  static let ear: CGFloat = 10
  static let radius: CGFloat = 22
  static let width: CGFloat = 420
  static let row: CGFloat = 52
  static let header: CGFloat = 44
  static let pad: CGFloat = 14
  static let maxRows = 4
  /// Room under the tallest island for the spring's overshoot.
  static let slack: CGFloat = 24

  /// The island's outline in a flipped (y down) box of [size]: flush with
  /// the top edge, flaring into it at both ends, rounded at the bottom.
  static func outline(_ size: CGSize, x: CGFloat = 0) -> CGPath {
    let w = size.width, h = max(size.height, 0.5), e = ear
    let r = min(radius, h / 2, (w - 2 * e) / 2)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x, y: 0))
    p.addQuadCurve(to: CGPoint(x: x + e, y: min(e, h)), control: CGPoint(x: x + e, y: 0))
    p.addLine(to: CGPoint(x: x + e, y: h - r))
    p.addQuadCurve(to: CGPoint(x: x + e + r, y: h), control: CGPoint(x: x + e, y: h))
    p.addLine(to: CGPoint(x: x + w - e - r, y: h))
    p.addQuadCurve(to: CGPoint(x: x + w - e, y: h - r), control: CGPoint(x: x + w - e, y: h))
    p.addLine(to: CGPoint(x: x + w - e, y: min(e, h)))
    p.addQuadCurve(to: CGPoint(x: x + w, y: 0), control: CGPoint(x: x + w - e, y: 0))
    p.closeSubpath()
    return p
  }

  /// The plop bucket (lib/type_icons.dart bucketPath) in a flipped box.
  static func bucket(_ s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
    p.move(to: pt(0.22, 0.04))
    p.addLine(to: pt(0.78, 0.04))
    p.addCurve(to: pt(0.935, 0.19), control1: pt(0.89, 0.04), control2: pt(0.93, 0.09))
    p.addLine(to: pt(0.975, 0.76))
    p.addCurve(to: pt(0.82, 0.92), control1: pt(0.99, 0.92), control2: pt(0.92, 0.97))
    p.addCurve(to: pt(0.18, 0.92), control1: pt(0.64, 0.84), control2: pt(0.36, 0.84))
    p.addCurve(to: pt(0.025, 0.76), control1: pt(0.08, 0.97), control2: pt(0.01, 0.92))
    p.addLine(to: pt(0.065, 0.19))
    p.addCurve(to: pt(0.22, 0.04), control1: pt(0.07, 0.09), control2: pt(0.11, 0.04))
    p.closeSubpath()
    return p
  }

  static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
  }

  static func mono(_ size: CGFloat) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
  }

  static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Picture thumbnails, decoded once each and off the main thread: a
/// 48-megapixel HEIC takes a third of a second to decode in full, which the
/// island would otherwise pay on every hover. The file's own embedded
/// thumbnail is used when it has one.
private enum Thumbs {
  private static var cache: [String: NSImage] = [:]
  private static var waiting: [String: [(NSImage) -> Void]] = [:]
  private static let queue = DispatchQueue(label: "plop.island.thumbs", qos: .userInitiated)

  /// The thumbnail if it is decoded; otherwise nil now and [ready] later.
  static func get(_ path: String, ready: @escaping (NSImage) -> Void) -> NSImage? {
    if let image = cache[path] { return image }
    if waiting[path] != nil {
      waiting[path]!.append(ready)
      return nil
    }
    waiting[path] = [ready]
    queue.async {
      let image = decode(path)
      DispatchQueue.main.async {
        let callbacks = waiting.removeValue(forKey: path) ?? []
        guard let image = image else { return }
        cache[path] = image
        callbacks.forEach { $0(image) }
      }
    }
    return nil
  }

  /// Forgets them once the island has tucked away.
  static func clear() { cache.removeAll() }

  private static func decode(_ path: String) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 120,
        ] as CFDictionary)
    else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}

/// One item as Dart describes it.
private struct IslandItem {
  let key: String
  let title: String
  /// Shown instead of [title] while hovered: a text's first line, kept off
  /// the screen until the pointer asks for it.
  let reveal: String?
  let meta: String
  let icon: NSImage?
  let thumb: String?
  let dragFile: String?
  let dragText: String?
  let actions: [String]
  var mark: String?
  var markIsError = false

  init?(_ m: [String: Any]) {
    guard let key = m["key"] as? String, let title = m["title"] as? String else { return nil }
    self.key = key
    self.title = title
    reveal = m["reveal"] as? String
    meta = m["meta"] as? String ?? ""
    if let png = m["icon"] as? FlutterStandardTypedData {
      let image = NSImage(data: png.data)
      image?.size = NSSize(width: 34, height: 34)
      icon = image
    } else {
      icon = nil
    }
    thumb = m["thumb"] as? String
    dragFile = m["dragFile"] as? String
    dragText = m["dragText"] as? String
    actions = m["actions"] as? [String] ?? []
    mark = m["mark"] as? String
    markIsError = m["error"] as? Bool ?? false
  }
}

/// A panel that floats above the menu bar on every Space, over full-screen
/// apps too, and never becomes key or main.
private final class IslandPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Owns the panel and talks to Dart over "plop/island".
final class Island: NSObject {
  private let channel: FlutterMethodChannel
  private var panel: IslandPanel?
  private var view: IslandView?
  private var tuck: Timer?
  private var dragging = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "plop/island", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "show":
        let items = (args["items"] as? [[String: Any]] ?? []).compactMap(IslandItem.init)
        let count = args["count"] as? Int ?? items.count
        self.show(
          .items(sender: args["sender"] as? String ?? "", items: items, count: count),
          hint: args["hint"] as? String)
      case "say":
        self.show(
          .say(text: args["text"] as? String ?? "", ok: args["ok"] as? Bool ?? true),
          hint: nil)
      case "mark":
        // Answers whether the row was there to take it; Dart says it on its
        // own otherwise.
        guard let key = args["key"] as? String, let view = self.view, self.isUp else {
          return result(false)
        }
        let applied = view.mark(key, args["mark"] as? String, error: args["error"] as? Bool ?? false)
        if applied { self.schedule(after: 1.6) }
        return result(applied)
      case "drop":
        // Gone from the shelf (expired, or taken back) while showing.
        if let key = args["key"] as? String, let view = self.view, self.isUp {
          if view.drop(key) == 0 { self.hide() } else { view.layoutIsland(animated: true) }
        }
      case "hide":
        self.hide()
      default:
        return result(FlutterMethodNotImplemented)
      }
      result(nil)
    }
  }

  /// Showing, or opening; not tucked away or tucking.
  private var isUp: Bool {
    guard let panel = panel, let view = view else { return false }
    return panel.isVisible && !view.tucking
  }

  // MARK: showing and tucking away

  private func show(_ content: IslandView.Content, hint: String?) {
    guard let panel = panel ?? makePanel(), let view = view else { return }
    let wasUp = isUp
    guard place() else { return }
    view.load(content, hint: hint)
    if wasUp {
      view.layoutIsland(animated: true)
    } else {
      panel.orderFrontRegardless()
      view.open()
    }
    view.syncHover()
    announce(content)
    switch content {
    case .say: schedule(after: 2.2)
    case .items(_, _, let count): schedule(after: count > 1 ? 7 : 5)
    }
  }

  /// VoiceOver hears what arrived, never a text's words.
  private func announce(_ content: IslandView.Content) {
    let line: String
    switch content {
    case .say(let text, _): line = text
    case .items(let sender, let items, let count):
      line = count > 1 ? "\(count) from \(sender)" : "\(items.first?.title ?? "") from \(sender)"
    }
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [
        .announcement: line,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }

  private func makePanel() -> IslandPanel? {
    let panel = IslandPanel(
      contentRect: NSRect(x: 0, y: 0, width: Look.width, height: 100),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isMovable = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.isReleasedWhenClosed = false
    panel.appearance = NSAppearance(named: .darkAqua)
    let view = IslandView(frame: panel.contentRect(forFrameRect: panel.frame))
    view.autoresizingMask = [.width, .height]
    view.onAction = { [weak self] key, action in
      self?.channel.invokeMethod("action", arguments: ["key": key, "action": action])
    }
    view.onDrag = { [weak self] active in
      self?.dragging = active
      if !active { self?.schedule(after: 2.5) }
    }
    view.onLeave = { [weak self] in self?.schedule(after: 2.5) }
    panel.contentView = view
    self.panel = panel
    self.view = view
    return panel
  }

  /// Puts the panel, at its one size, at the top of the screen the pointer
  /// is on, centred on the notch if it has one. False with no screen at all
  /// (a Mac mini with no display, mid display change): then nothing shows.
  private func place() -> Bool {
    guard let panel = panel, let view = view else { return false }
    let mouse = NSEvent.mouseLocation
    guard
      let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        ?? NSScreen.main ?? NSScreen.screens.first
    else { return false }
    var notch = CGSize(width: 0, height: 0)
    if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
      let left = screen.auxiliaryTopLeftArea?.width ?? 0
      let right = screen.auxiliaryTopRightArea?.width ?? 0
      notch = CGSize(width: screen.frame.width - left - right, height: screen.safeAreaInsets.top)
    } else {
      // No notch: the island grows down from the top edge over the menu bar.
      notch = CGSize(width: 0, height: max(screen.frame.maxY - screen.visibleFrame.maxY, 24))
    }
    view.notch = notch
    let size = view.panelSize
    let frame = NSRect(
      x: (screen.frame.midX - size.width / 2).rounded(),
      y: screen.frame.maxY - size.height,
      width: size.width, height: size.height)
    if panel.frame != frame { panel.setFrame(frame, display: false) }
    return true
  }

  /// Tucks the island away after [seconds], or later while the pointer is
  /// on it or something is being dragged out of it: the timer asks, rather
  /// than trusting enter and exit events, which a rebuild under a still
  /// pointer can lose.
  private func schedule(after seconds: TimeInterval) {
    tuck?.invalidate()
    tuck = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      guard let self = self else { return }
      if self.dragging || self.view?.pointerInside == true {
        self.schedule(after: 1)
      } else {
        self.hide()
      }
    }
  }

  private func hide() {
    tuck?.invalidate()
    guard let panel = panel, panel.isVisible, let view = view, !view.tucking else { return }
    view.close { [weak self] in
      panel.orderOut(nil)
      Thumbs.clear()
      self?.channel.invokeMethod("hidden", arguments: nil)
    }
  }
}

/// The island's contents: a black outline that springs between the notch's
/// size and the content's, with the rows fading in over it.
private final class IslandView: NSView, NSDraggingSource {
  enum Content {
    case items(sender: String, items: [IslandItem], count: Int)
    case say(text: String, ok: Bool)
  }

  var onAction: ((String, String) -> Void)?
  var onDrag: ((Bool) -> Void)?
  var onLeave: (() -> Void)?
  var notch = CGSize(width: 0, height: 32)
  private(set) var tucking = false

  private var content = Content.say(text: "", ok: true)
  private var hint: String?
  /// Several items open into their rows while the pointer is on them.
  private var expanded = false
  private let shape = CAShapeLayer()
  private let body = FlippedView()
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    shape.fillColor = Look.black.cgColor
    layer?.addSublayer(shape)
    body.wantsLayer = true
    addSubview(body)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // MARK: sizes

  private var islandWidth: CGFloat { max(Look.width, notch.width + 2 * Look.ear + 120) }

  /// As big as the island gets, plus room for the spring to overshoot.
  var panelSize: CGSize {
    CGSize(
      width: islandWidth,
      height: notch.height + Look.header + CGFloat(Look.maxRows) * Look.row + 8 + Look.slack)
  }

  /// The island's size for what it shows now.
  private var target: CGSize {
    let top = notch.height
    switch content {
    case .say:
      return CGSize(width: max(320, notch.width + 2 * Look.ear + 80), height: top + 34)
    case .items(_, let items, let count):
      if count == 1 { return CGSize(width: islandWidth, height: top + Look.row + 10) }
      let rows = expanded ? CGFloat(min(items.count, Look.maxRows)) * Look.row : 0
      return CGSize(width: islandWidth, height: top + Look.header + rows + 8)
    }
  }

  /// Where the island sits in the panel: centred, at the top.
  private var islandRect: CGRect {
    let t = target
    return CGRect(x: ((bounds.width - t.width) / 2).rounded(), y: 0, width: t.width, height: t.height)
  }

  private var islandPath: CGPath {
    let r = islandRect
    return Look.outline(r.size, x: r.minX)
  }

  /// The notch-sized outline the island grows out of and tucks back into.
  private var notchPath: CGPath {
    let w = notch.width > 0 ? notch.width + 2 * Look.ear : 160
    let h = notch.width > 0 ? notch.height : 1
    return Look.outline(CGSize(width: w, height: h), x: ((bounds.width - w) / 2).rounded())
  }

  var pointerInside: Bool {
    guard let window = window, window.isVisible else { return false }
    let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return islandRect.contains(p)
  }

  // MARK: hover

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = tracking { removeTrackingArea(t) }
    let t = NSTrackingArea(
      rect: islandRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
    addTrackingArea(t)
    tracking = t
  }

  override func mouseEntered(with event: NSEvent) { hoverChanged(true) }
  override func mouseExited(with event: NSEvent) { hoverChanged(false) }

  /// After a rebuild or a resize the pointer may be on the island with no
  /// event to say so (a tracking area added under it reports no entry).
  func syncHover() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if self.pointerInside != self.expanded { self.hoverChanged(self.pointerInside) }
    }
  }

  private func hoverChanged(_ inside: Bool) {
    let reopening = inside && tucking
    if reopening { cancelClose() }
    let changed = expanded != inside
    expanded = inside
    // A single row looks the same either way (its own hover reveals text).
    if reopening || (changed && count > 1) { layoutIsland(animated: true) }
    if !inside { onLeave?() }
  }

  /// Clicks outside the island's outline go through.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard islandPath.contains(local) else { return nil }
    return super.hitTest(point) ?? self
  }

  // MARK: content

  func load(_ content: Content, hint: String?) {
    self.content = content
    self.hint = hint
    expanded = false
  }

  /// Puts [mark] on [key]'s row; false when that row isn't showing.
  func mark(_ key: String, _ mark: String?, error: Bool) -> Bool {
    guard case .items(let sender, var items, let count) = content,
      let i = items.firstIndex(where: { $0.key == key })
    else { return false }
    items[i].mark = mark
    items[i].markIsError = error
    content = .items(sender: sender, items: items, count: count)
    rebuild()
    return true
  }

  /// Takes [key] off; answers how many are left.
  func drop(_ key: String) -> Int {
    guard case .items(let sender, var items, let count) = content else { return 0 }
    let before = items.count
    items.removeAll { $0.key == key }
    content = .items(sender: sender, items: items, count: max(count - (before - items.count), items.count))
    return items.count
  }

  private var items: [IslandItem] {
    if case .items(_, let items, _) = content { return items }
    return []
  }

  private var count: Int {
    if case .items(_, _, let count) = content { return count }
    return 0
  }

  /// One item shows as its row; several show as a line saying how many,
  /// opening into their rows (up to four) on hover.
  private var showsRows: Bool { count == 1 || (count > 1 && expanded) }

  // MARK: animation

  func layoutIsland(animated: Bool) {
    body.frame = islandRect
    rebuild()
    updateTrackingAreas()
    morph(to: islandPath, animated: animated)
  }

  func open() {
    tucking = false
    shape.removeAllAnimations()
    shape.path = notchPath
    body.frame = islandRect
    rebuild()
    updateTrackingAreas()
    body.alphaValue = 0
    morph(to: islandPath, animated: true)
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.25
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      body.animator().alphaValue = 1
    }
  }

  /// The pointer came back while it was tucking away: it stays.
  private func cancelClose() {
    tucking = false
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.15
      body.animator().alphaValue = 1
    }
  }

  func close(_ done: @escaping () -> Void) {
    tucking = true
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.12
      body.animator().alphaValue = 0
    }
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      // Not if it was opened again meanwhile.
      guard let self = self, self.tucking else { return }
      self.tucking = false
      done()
    }
    morph(to: notchPath, animated: true, spring: false)
    CATransaction.commit()
  }

  private func morph(to path: CGPath, animated: Bool, spring: Bool = true) {
    let from = shape.presentation()?.path ?? shape.path
    shape.path = path
    guard animated, let from = from else { return }
    let a: CABasicAnimation
    if Look.reduceMotion {
      a = CABasicAnimation(keyPath: "path")
      a.duration = 0.12
    } else if spring {
      let s = CASpringAnimation(keyPath: "path")
      s.damping = 22
      s.stiffness = 260
      s.mass = 1
      s.duration = s.settlingDuration
      a = s
    } else {
      a = CABasicAnimation(keyPath: "path")
      a.duration = 0.22
      a.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.9, 0.6)
    }
    a.fromValue = from
    a.toValue = path
    shape.add(a, forKey: "path")
  }

  // MARK: layout

  private func rebuild() {
    body.subviews.forEach { $0.removeFromSuperview() }
    let width = body.bounds.width
    let inset = Look.ear + Look.pad
    var y = notch.height
    switch content {
    case .say(let text, let ok):
      let label = Label(
        (ok ? "✓  " : "✕  ") + text, font: Look.font(13, .medium), color: ok ? Look.text : Look.warn)
      label.alignment = .center
      label.frame = NSRect(x: inset, y: y + 7, width: width - 2 * inset, height: 18)
      body.addSubview(label)
    case .items(let sender, let items, let count):
      if count > 1 {
        addHeader(sender: sender, count: count, y: y, width: width, inset: inset)
        y += Look.header
      }
      if showsRows {
        for item in items.prefix(Look.maxRows) {
          let row = RowView(item: item, sender: count == 1 ? sender : nil, hint: hint)
          row.frame = NSRect(x: Look.ear, y: y, width: width - 2 * Look.ear, height: Look.row)
          row.onAction = { [weak self] key, action in self?.onAction?(key, action) }
          row.onDrag = { [weak self] active in self?.onDrag?(active) }
          body.addSubview(row)
          y += Look.row
        }
      }
    }
  }

  private func addHeader(sender: String, count: Int, y: CGFloat, width: CGFloat, inset: CGFloat) {
    var x = inset
    for item in items.prefix(3).reversed() {
      let icon = IconView(item: item, size: 24, ringed: true)
      icon.frame = NSRect(x: x - 2, y: y + 8, width: 28, height: 28)
      body.addSubview(icon)
      x += 14
    }
    x += 18
    let title = Label("\(count) from \(sender)", font: Look.font(13, .medium), color: Look.text)
    title.lineBreakMode = .byTruncatingTail
    title.frame = NSRect(x: x, y: y + 13, width: width - x - inset - 60, height: 18)
    body.addSubview(title)
    if !expanded {
      let more = Label("hover", font: Look.mono(11), color: Look.faint)
      more.alignment = .right
      more.frame = NSRect(x: width - inset - 60, y: y + 15, width: 60, height: 16)
      body.addSubview(more)
    }
  }

  // MARK: dragging (rows start it)

  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation { .copy }

  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    onDrag?(false)
  }
}

private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class Label: NSTextField {
  init(_ text: String, font: NSFont, color: NSColor) {
    super.init(frame: .zero)
    stringValue = text
    self.font = font
    textColor = color
    isBezeled = false
    drawsBackground = false
    isEditable = false
    isSelectable = false
    lineBreakMode = .byTruncatingMiddle
    cell?.truncatesLastVisibleLine = true
    maximumNumberOfLines = 1
  }

  required init?(coder: NSCoder) { fatalError() }

  // Clicks fall through to the row, which drags and opens.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The type tile Dart drew, or the picture itself in the bucket's shape.
private final class IconView: NSView {
  private let item: IslandItem
  private let size: CGFloat
  /// A black margin round the tile, so tiles stacked in a header read as
  /// separate ones.
  private let ring: CGFloat
  private var picture: NSImage?

  init(item: IslandItem, size: CGFloat, ringed: Bool = false) {
    self.item = item
    self.size = size
    ring = ringed ? 2 : 0
    super.init(frame: NSRect(x: 0, y: 0, width: size + 2 * ring, height: size + 2 * ring))
    if let path = item.thumb {
      picture = Thumbs.get(path) { [weak self] image in
        self?.picture = image
        self?.needsDisplay = true
      }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    if ring > 0 {
      ctx.addPath(Look.bucket(size + 2 * ring))
      ctx.setFillColor(Look.black.cgColor)
      ctx.fillPath()
      ctx.translateBy(x: ring, y: ring)
    }
    let box = NSRect(x: 0, y: 0, width: size, height: size)
    if let picture = picture {
      ctx.saveGState()
      ctx.addPath(Look.bucket(size))
      ctx.clip()
      NSColor(white: 0.23, alpha: 1).setFill()
      box.fill()
      // Aspect fill, centred.
      let s = picture.size
      let k = max(size / max(s.width, 1), size / max(s.height, 1))
      let w = s.width * k, h = s.height * k
      picture.draw(
        in: NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      ctx.restoreGState()
    } else if let icon = item.icon {
      icon.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
  }
}

/// Hover for views rebuilt under a still pointer: a tracking area added
/// there reports no entry, so they look for themselves.
private protocol Hovering: NSView {
  func hover(_ inside: Bool)
}

extension Hovering {
  func trackHover(_ old: NSTrackingArea?) -> NSTrackingArea {
    if let t = old { removeTrackingArea(t) }
    let t = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(t)
    if let window = window, window.isVisible {
      let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
      if bounds.contains(p) { hover(true) }
    }
    return t
  }
}

/// One item: its tile, its name and where it came from, its buttons. The
/// row itself drags the file (or the text) out into any app.
private final class RowView: NSView, Hovering {
  var onAction: ((String, String) -> Void)?
  var onDrag: ((Bool) -> Void)?
  private let item: IslandItem
  private var down: NSPoint?
  private var title: Label!
  private var line: Label!
  private var buttons: [IslandButton] = []
  private var tracking: NSTrackingArea?

  init(item: IslandItem, sender: String?, hint: String?) {
    self.item = item
    super.init(frame: .zero)
    let icon = IconView(item: item, size: 34)
    icon.frame = NSRect(x: Look.pad, y: 9, width: 34, height: 34)
    addSubview(icon)
    title = Label(item.title, font: Look.font(13, .medium), color: Look.text)
    addSubview(title)
    // Size and sender, as the shelf's rows put them; a long device name is
    // what gets cut, from the end.
    let meta = [item.meta, sender ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    line = Label(
      item.mark ?? meta, font: Look.mono(11),
      color: item.markIsError ? Look.warn : item.mark != nil ? Look.text : Look.dim)
    line.lineBreakMode = .byTruncatingTail
    addSubview(line)
    let done = item.mark != nil && !item.markIsError
    for action in item.actions {
      let b = IslandButton(title: action, dim: done)
      if action == "copy", let hint = hint { b.toolTip = "copy · \(hint) grabs the newest" }
      b.onClick = { [weak self] in
        guard let self = self else { return }
        self.onAction?(self.item.key, action)
      }
      buttons.append(b)
      addSubview(b)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// Buttons at the right edge, the name and its line taking what is left.
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    var right = newSize.width - Look.pad
    for b in buttons.reversed() {
      let w = b.intrinsicContentSize.width
      right -= w
      b.frame = NSRect(x: right, y: 12, width: w, height: 28)
      right -= 6
    }
    let x: CGFloat = Look.pad + 34 + 12
    let w = max(right - 6 - x, 40)
    title.frame = NSRect(x: x, y: 8, width: w, height: 18)
    line.frame = NSRect(x: x, y: 28, width: w, height: 15)
  }

  // Hovering the row shows a text's first line; it stays off screen until
  // asked for.
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    tracking = trackHover(tracking)
  }

  func hover(_ inside: Bool) {
    title.stringValue = inside ? item.reveal ?? item.title : item.title
  }

  override func mouseEntered(with event: NSEvent) { hover(true) }
  override func mouseExited(with event: NSEvent) { hover(false) }

  override func mouseDown(with event: NSEvent) {
    down = event.locationInWindow
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = down else { return }
    let p = event.locationInWindow
    guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
    down = nil
    let writer: NSPasteboardWriting
    if let path = item.dragFile {
      writer = URL(fileURLWithPath: path) as NSURL
    } else if let text = item.dragText {
      writer = text as NSString
    } else {
      return
    }
    let drag = NSDraggingItem(pasteboardWriter: writer)
    let image = item.icon ?? NSImage(size: NSSize(width: 34, height: 34))
    drag.setDraggingFrame(NSRect(x: Look.pad, y: 9, width: 34, height: 34), contents: image)
    guard let source = superview?.superview as? IslandView else { return }
    onDrag?(true)
    beginDraggingSession(with: [drag], event: event, source: source)
  }

  override func mouseUp(with event: NSEvent) {
    if down != nil { onAction?(item.key, "open") }
    down = nil
  }

  // VoiceOver: the row reads as its title and line; its buttons press.
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .group }
  override func accessibilityLabel() -> String? { "\(item.title), \(line.stringValue)" }
}

/// A small dark pill with a word on it, clickable in a window that never
/// becomes key.
private final class IslandButton: NSView, Hovering {
  var onClick: (() -> Void)?
  private let title: String
  private let dim: Bool
  private var lit = false
  private var pressed = false
  private var tracking: NSTrackingArea?

  init(title: String, dim: Bool) {
    self.title = title
    self.dim = dim
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private var attributes: [NSAttributedString.Key: Any] {
    [.font: Look.font(12, .medium), .foregroundColor: dim ? Look.dim : Look.text]
  }

  override var intrinsicContentSize: NSSize {
    let w = (title as NSString).size(withAttributes: attributes).width
    return NSSize(width: ceil(w) + 24, height: 28)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    tracking = trackHover(tracking)
  }

  func hover(_ inside: Bool) {
    lit = inside
    needsDisplay = true
  }

  override func mouseEntered(with event: NSEvent) { hover(true) }
  override func mouseExited(with event: NSEvent) { hover(false) }

  override func mouseDown(with event: NSEvent) {
    pressed = true
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    pressed = false
    needsDisplay = true
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityLabel() -> String? { title }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    let r = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
    (pressed ? Look.border : lit ? Look.buttonHover : Look.button).setFill()
    path.fill()
    Look.border.setStroke()
    path.lineWidth = 1
    path.stroke()
    let s = (title as NSString).size(withAttributes: attributes)
    (title as NSString).draw(
      at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2),
      withAttributes: attributes)
  }
}
