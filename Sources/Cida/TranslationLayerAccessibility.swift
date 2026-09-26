import AppKit
import ApplicationServices

/// A node of another application's accessibility tree. The attributes the layer rules read
/// are fetched in one message the first time any of them is asked for; children and parent
/// are fetched when asked. Instances are cheap and not shared across threads.
final class AccessibilityLayerNode: LayerNode, @unchecked Sendable {
  let element: AXUIElement

  init(_ element: AXUIElement) {
    self.element = element
  }

  private struct Snapshot {
    var role = ""
    var subrole: String?
    var textValue: String?
    var frame: CGRect?
    var domClasses: [String] = []
    var identifier: String?
  }

  private lazy var snapshot: Snapshot = fetchSnapshot()

  var role: String { snapshot.role }
  var subrole: String? { snapshot.subrole }
  var frame: CGRect? { snapshot.frame }
  var textValue: String? { snapshot.textValue }
  var domClasses: [String] { snapshot.domClasses }
  var identifier: String? { snapshot.identifier }

  var children: [AccessibilityLayerNode] {
    (copy(kAXChildrenAttribute) as? [AXUIElement] ?? []).map(AccessibilityLayerNode.init)
  }

  var parent: AccessibilityLayerNode? {
    guard let value = copy(kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return nil
    }
    return AccessibilityLayerNode(value as! AXUIElement)
  }

  var url: URL? {
    let value = copy("AXURL")
    if let url = value as? URL { return url }
    if let text = value as? String { return URL(string: text) }
    return nil
  }

  func bounds(ofCharacters range: NSRange) -> CGRect? {
    var cfRange = CFRange(location: range.location, length: range.length)
    guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
    var value: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
      let value, CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    var rect = CGRect.zero
    return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
  }

  /// The window this node belongs to.
  var window: AccessibilityLayerNode? {
    guard let value = copy(kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return nil
    }
    return AccessibilityLayerNode(value as! AXUIElement)
  }

  func perform(_ action: String) {
    AXUIElementPerformAction(element, action as CFString)
  }

  func isSameElement(as other: AccessibilityLayerNode) -> Bool {
    CFEqual(element, other.element)
  }

  private func copy(_ attribute: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  private func fetchSnapshot() -> Snapshot {
    let names = [
      kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXPositionAttribute,
      kAXSizeAttribute, "AXDOMClassList", kAXIdentifierAttribute, "AXDOMIdentifier",
    ]
    var values: CFArray?
    AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
    let array = (values as? [AnyObject]) ?? []
    func value(_ index: Int) -> AnyObject? {
      guard index < array.count else { return nil }
      let item = array[index]
      // Missing attributes come back as AXValue errors.
      if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError {
        return nil
      }
      return item
    }
    var snapshot = Snapshot()
    snapshot.role = value(0) as? String ?? ""
    snapshot.subrole = value(1) as? String
    snapshot.textValue = value(2) as? String
    if let position = value(3), let size = value(4),
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    {
      var point = CGPoint.zero
      var extent = CGSize.zero
      AXValueGetValue(position as! AXValue, .cgPoint, &point)
      AXValueGetValue(size as! AXValue, .cgSize, &extent)
      snapshot.frame = CGRect(origin: point, size: extent)
    }
    snapshot.domClasses = value(5) as? [String] ?? []
    let identifier = value(6) as? String ?? value(7) as? String
    snapshot.identifier = identifier?.isEmpty == false ? identifier : nil
    return snapshot
  }
}

/// An application as the layer sees it: its accessibility root, and turning on the
/// accessibility tree that Chromium and Electron only build for clients that ask.
struct LayerApplication: @unchecked Sendable {
  let processIdentifier: pid_t
  let bundleIdentifier: String
  let name: String
  let element: AXUIElement

  init?(_ application: NSRunningApplication) {
    guard let bundleIdentifier = application.bundleIdentifier else { return nil }
    processIdentifier = application.processIdentifier
    self.bundleIdentifier = bundleIdentifier
    name = application.localizedName ?? bundleIdentifier
    element = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(element, 0.5)
  }

  /// Electron answers `AXManualAccessibility`; Chrome ignores it and builds its tree for
  /// `AXEnhancedUserInterface`, which is only set on Chromium browsers because it slows down
  /// window animations in some native apps. The tree takes about two seconds to appear.
  func enableAccessibilityTree() {
    let manual = AXUIElementSetAttributeValue(
      element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    if manual != .success, Self.isChromiumBrowser(pid: processIdentifier) {
      AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
  }

  /// Chromium ships its renderer as a "… Helper (Renderer).app"; Chrome keeps it inside
  /// its versioned framework, a few folders down.
  static func isChromiumBrowser(pid: pid_t) -> Bool {
    guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
    let frameworks = url.appendingPathComponent("Contents/Frameworks")
    guard
      let enumerator = FileManager.default.enumerator(
        at: frameworks, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else {
      return false
    }
    for case let item as URL in enumerator {
      if item.lastPathComponent.hasSuffix("Helper (Renderer).app") { return true }
      if item.pathExtension == "app" || enumerator.level > 5 { enumerator.skipDescendants() }
    }
    return false
  }

  var windows: [AccessibilityLayerNode] {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
      let elements = value as? [AXUIElement]
    else {
      return []
    }
    return elements.map(AccessibilityLayerNode.init).filter { $0.role == LayerRole.window }
  }

  /// The deepest element at a screen point (top-left origin).
  func element(at point: CGPoint) -> AccessibilityLayerNode? {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(element, Float(point.x), Float(point.y), &hit) == .success,
      let hit
    else {
      return nil
    }
    return AccessibilityLayerNode(hit)
  }
}

/// On-screen windows from the window server, front to back, in top-left screen points.
struct LayerWindowInfo: Equatable, Sendable {
  let number: CGWindowID
  let ownerPID: pid_t
  let bounds: CGRect
  let layer: Int
  var ownerName = ""

  static func onScreen() -> [LayerWindowInfo] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { entry in
      guard let number = entry[kCGWindowNumber as String] as? CGWindowID,
        let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
        let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
      else {
        return nil
      }
      let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
      guard alpha > 0 else { return nil }
      return LayerWindowInfo(
        number: number, ownerPID: pid, bounds: bounds,
        layer: entry[kCGWindowLayer as String] as? Int ?? 0,
        ownerName: entry[kCGWindowOwnerName as String] as? String ?? "")
    }
  }

  /// The application window under a point, skipping Cida's own windows, anything above the
  /// normal window level (menu bar, Dock, notifications) and whole-display overlays.
  static func applicationWindow(
    at point: CGPoint, in windows: [LayerWindowInfo], displays: [CGRect] = displayFrames
  ) -> LayerWindowInfo? {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    return windows.first {
      $0.ownerPID != ownPID && $0.layer == 0 && $0.bounds.contains(point)
        && !isDisplayOverlay($0, displays: displays)
    }
  }

  static func isDisplayOverlay(_ info: LayerWindowInfo, displays: [CGRect]) -> Bool {
    displays.contains {
      abs($0.minX - info.bounds.minX) < 1 && abs($0.minY - info.bounds.minY) < 1
        && abs($0.width - info.bounds.width) < 1 && abs($0.height - info.bounds.height) < 1
    }
  }

  /// What covers `window` from the front: the windows above it, Cida's excluded. A window
  /// exactly the size of a whole display, menu bar included, is a transparent overlay (a
  /// recording or automation shield): a real app in full screen has a Space of its own, and a
  /// zoomed window leaves the menu bar.
  static func occluders(
    of window: CGWindowID, in windows: [LayerWindowInfo], displays: [CGRect] = displayFrames
  ) -> [LayerWindowInfo] {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    var covering: [LayerWindowInfo] = []
    for info in windows {
      if info.number == window { return covering }
      guard info.ownerPID != ownPID, info.layer >= 0, info.layer < 1_000 else { continue }
      if !isDisplayOverlay(info, displays: displays) { covering.append(info) }
    }
    return covering
  }

  /// Every display's frame in top-left screen points.
  static var displayFrames: [CGRect] {
    NSScreen.screens.map { screen in
      CGRect(
        x: screen.frame.minX, y: LayerScreenGeometry.primaryHeight - screen.frame.maxY,
        width: screen.frame.width, height: screen.frame.height)
    }
  }
}

/// Screen geometry: AX and the window server measure from the top-left of the primary
/// display, AppKit from its bottom-left.
enum LayerScreenGeometry {
  static var primaryHeight: CGFloat {
    NSScreen.screens.first?.frame.height ?? 0
  }

  static func appKitRect(fromTopLeft rect: CGRect) -> CGRect {
    CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
  }

  static func topLeftPoint(fromAppKit point: CGPoint) -> CGPoint {
    CGPoint(x: point.x, y: primaryHeight - point.y)
  }
}
