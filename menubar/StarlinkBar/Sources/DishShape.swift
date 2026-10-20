import AppKit

/// The dish glyph (tools/dish.svg), used for the menu bar icon and the app icon.
enum DishShape {
    /// The SVG's path data: only M / L / Z commands, viewBox 0 0 800 299.216595.
    static let pathData = "M786.42725,3.12638804e-13 L800,37.1900744 L411.052522,228.076289 L10.0470354,299.216595 L0,264.936326 L786.42725,3.12638804e-13 Z M468.422971,212.036891 L567.388242,299.216595 L505.883286,299.216595 L417.893998,236.254361 L468.422971,212.036891 Z"
    static let viewBox = NSSize(width: 800, height: 299.216595)

    /// The shape scaled to fit `rect`, centered, flipped from SVG (y down) to AppKit (y up).
    static func path(fitting rect: NSRect) -> NSBezierPath {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let ox = rect.midX - viewBox.width * scale / 2
        let oy = rect.midY - viewBox.height * scale / 2
        let path = NSBezierPath()
        var command: Character = "M"
        var numbers: [CGFloat] = []
        func flush() {
            guard numbers.count >= 2 else { return }
            let p = NSPoint(x: ox + numbers[0] * scale, y: oy + (viewBox.height - numbers[1]) * scale)
            if command == "M" { path.move(to: p) } else { path.line(to: p) }
            numbers.removeAll()
        }
        for token in pathData.split(whereSeparator: { $0 == " " || $0 == "," }) {
            if let c = token.first, c.isLetter {
                flush()
                if c == "Z" { path.close() } else { command = c }
                let rest = token.dropFirst()
                if let v = Double(rest) { numbers.append(CGFloat(v)) }
            } else if let v = Double(token) {
                numbers.append(CGFloat(v))
                if numbers.count == 2 { flush() }
            }
        }
        flush()
        return path
    }

    /// Template image for the menu bar (adapts to light/dark menu bars). The profile is thin,
    /// so it's drawn taller than a typical 10 pt glyph to stay legible.
    static func menuBarImage(height: CGFloat = 12) -> NSImage {
        let size = NSSize(width: ceil(height * viewBox.width / viewBox.height), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            path(fitting: rect).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "StarlinkBar"
        return image
    }
}
