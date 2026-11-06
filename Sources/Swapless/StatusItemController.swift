import AppKit

/// The menu-bar item: the icon only, plus a dot when needed (owner call 5).
@MainActor
final class StatusItemController {
    let item: NSStatusItem
    private var dotShown = false

    init(menu: NSMenu) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Icons.plain()
        item.button?.toolTip = "Swapless"
        item.menu = menu
    }

    func setDot(_ on: Bool) {
        guard on != dotShown else { return }
        dotShown = on
        item.button?.image = on ? Icons.dot() : Icons.plain()
    }
}

/// The SF Symbol `memorychip` as a template image; the dot variant adds a 4 pt circle drawn
/// top-right, still a template image.
@MainActor
enum Icons {
    static func plain() -> NSImage {
        let img = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Swapless")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        img.isTemplate = true
        return img
    }

    static func dot() -> NSImage {
        let base = plain()
        let size = base.size.width > 0 ? base.size : NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let d: CGFloat = 4
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Swapless (needs attention)"
        return img
    }

    /// Renders an image once (the rig's menu cycles cover the icons too).
    static func render(_ img: NSImage) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep, let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        img.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
    }
}
