import AppKit
import ServiceManagement

/// The app icon's tilted window and horizon, as a template image so macOS can tint it.
func menuBarIcon() -> NSImage {
  let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
    // Traced from the 1024-point app icon, then scaled to fit.
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: (x - 60) * 18 / 940, y: (y - 40) * 18 / 940) }
    let corners = [p(240, 300), p(785, 160), p(785, 690), p(240, 830)]
    let window = NSBezierPath()
    window.move(to: NSPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2))
    for i in 1...4 { window.appendArc(from: corners[i % 4], to: corners[(i + 1) % 4], radius: 1.6) }
    window.close(); window.fill()
    let horizon = NSBezierPath()
    horizon.move(to: p(100, 945)); horizon.line(to: p(960, 735))
    horizon.lineWidth = 1.25; horizon.lineCapStyle = .round; horizon.stroke()
    return true
  }
  image.isTemplate = true
  image.accessibilityDescription = "Janela"
  return image
}

/// Shown only while Janela has a Dock icon. Text fields also need Edit for copy and paste.
func appMainMenu() -> NSMenu {
  let main = NSMenu()
  let app = NSMenu(), edit = NSMenu(title: "Edit")
  app.addItem(withTitle: "Quit Janela", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
  edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
  edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
  edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
  main.addItem(withTitle: "Janela", action: nil, keyEquivalent: "").submenu = app
  main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
  return main
}

enum LoginItem {
  static var isOn: Bool { SMAppService.mainApp.status == .enabled }

  static func set(_ on: Bool) {
    if on == isOn { return }
    let item = SMAppService.mainApp
    do { if on { try item.register() } else { try item.unregister() } } catch {}
    if on, item.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
  }
}
