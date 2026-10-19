import AppKit

/// The dish glyph (tools/dish.svg), used for the menu bar icon and the app icon.
enum DishShape {
    /// The SVG's path data: only M / L / Z commands, viewBox 0 0 221.420897 86.5815804.
    static let pathData = "M2.00808772,9.45295827 L0,16.587071 L125.728192,86.5815804 L219.207118,72.0795467 L221.420897,65.3198233 L97.8546919,0 L2.00808772,9.45295827 Z M64.6036004,74.3628771 L80.8754741,74.3628771 L102.29113,70.7610455 L81.8754741,59.1398368 L64.6036004,74.3628771 Z"
    static let viewBox = NSSize(width: 221.420897, height: 86.5815804)

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

    /// Template image for the menu bar (adapts to light/dark menu bars).
    static func menuBarImage(height: CGFloat = 10) -> NSImage {
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
