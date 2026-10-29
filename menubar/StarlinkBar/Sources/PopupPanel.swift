import Cocoa

private let PANEL_W: CGFloat = 320
private let PAD: CGFloat = 12
private let CONTENT_W: CGFloat = PANEL_W - 12 - PAD * 2   // card is inset 6 pt on each side

private let GREEN = NSColor(red: 0.25, green: 0.90, blue: 0.50, alpha: 1)
private let RED = NSColor(red: 1.00, green: 0.42, blue: 0.38, alpha: 1)
private let ORANGE = NSColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 1)
private let BLUE = NSColor(red: 0.45, green: 0.65, blue: 1.00, alpha: 1)

/// The dropdown card: borderless panel, hand-drawn dark card (same look as EFStatus / AsanaStatus).
final class PopupPanel: NSPanel {
    private let dotLabel = label("●", size: 9, weight: .semibold, alpha: 0.45)
    private let headerLabel = label("STARLINK", size: 9, weight: .semibold, alpha: 0.45)

    private let calloutStack = NSStackView()   // plan limits, suspension, pending update
    private let bigLabel = label("—", size: 26, weight: .bold, alpha: 1)
    private let bigSubLabel = label("", size: 11, weight: .regular, alpha: 0.5)
    private let sparkline = Sparkline()
    private let statusLine = wrappingLabel(size: 11, weight: .medium, alpha: 0.75)
    private let alertLine = wrappingLabel(size: 11, weight: .medium, alpha: 1)

    private let sectionLabel = label("", size: 9, weight: .semibold, alpha: 0.45)
    // The four readings that aren't the main one: left, two centered, right.
    private let columns: [Column] = [.leading, .centerX, .centerX, .trailing].map { Column(align: $0) }
    private lazy var columnsRow: NSStackView = {
        let row = hstack(columns, spacing: 4, align: .top)
        row.distribution = .equalSpacing  // same gap between columns, first and last flush with the edges
        for c in columns { c.setContentCompressionResistancePriority(.required, for: .horizontal) }
        return row
    }()

    private let outagesTitle = label("OUTAGES TODAY", size: 9, weight: .semibold, alpha: 0.45)
    private let outagesTotal = label("", size: 9, weight: .semibold, alpha: 0.45)
    private let outagesStack = NSStackView()

    private let footerLabel = wrappingLabel(size: 10, weight: .regular, alpha: 0.4)

    private let dividers = [Divider(), Divider(), Divider()]
    private var outagesHeader: NSStackView!

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: PANEL_W, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        buildUI()
    }

    private func buildUI() {
        let root = NSView(frame: contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        contentView = root

        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])

        let headerRow = hstack([dotLabel, headerLabel, spacer()], spacing: 4, align: .centerY)
        let bigRow = hstack([bigLabel, bigSubLabel], spacing: 6, align: .lastBaseline)

        sparkline.translatesAutoresizingMaskIntoConstraints = false
        sparkline.heightAnchor.constraint(equalToConstant: 26).isActive = true

        outagesStack.orientation = .vertical
        outagesStack.alignment = .leading
        outagesStack.spacing = 3
        outagesHeader = hstack([outagesTitle, spacer(), outagesTotal], spacing: 4, align: .centerY)

        calloutStack.orientation = .vertical
        calloutStack.alignment = .leading
        calloutStack.spacing = 4

        let stack = NSStackView(views: [
            headerRow,
            calloutStack,
            bigRow,
            sparkline,
            statusLine,
            alertLine,
            dividers[0],
            sectionLabel,
            columnsRow,
            dividers[1],
            outagesHeader,
            outagesStack,
            dividers[2],
            footerLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: PAD, left: PAD, bottom: PAD, right: PAD)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(8, after: sparkline)
        stack.setCustomSpacing(8, after: calloutStack)
        stack.setCustomSpacing(3, after: sectionLabel)

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for v in [headerRow, calloutStack, sparkline, columnsRow, outagesHeader!, outagesStack] + dividers as [NSView] {
            v.widthAnchor.constraint(equalToConstant: CONTENT_W).isActive = true
        }
        for l in [statusLine, alertLine, footerLabel] {
            l.preferredMaxLayoutWidth = CONTENT_W
        }
    }

    // MARK: - Content

    func update(from m: Monitor) {
        let status = m.status
        // Only on Starlink: what the dish says about the plan, the account or an update.
        showCallouts([.ok, .degraded, .down].contains(status) ? m.service?.callouts ?? [] : [])
        switch status {
        case .notOnStarlink:
            showOffStarlink(m)
        case .unreachable, .starting:
            showNotConnected(m, starting: status == .starting)
        case .ok, .degraded, .down:
            showLive(m, status: status)
        }
        resize()
    }

    private func setHeader(_ text: String, dot: NSColor?, prefix: Bool = true) {
        headerLabel.stringValue = prefix ? "STARLINK · " + text : text
        dotLabel.textColor = dot ?? NSColor.white.withAlphaComponent(0.35)
    }

    private func showLive(_ m: Monitor, status: Monitor.Status) {
        let n = m.now
        switch status {
        case .ok: setHeader("CONNECTED", dot: GREEN)
        case .degraded: setHeader("DEGRADED", dot: ORANGE)
        default: setHeader("NO INTERNET", dot: RED)
        }

        let main = Metric.main
        let r = m.readings
        if status == .down {
            bigLabel.stringValue = "Offline"
            bigLabel.textColor = RED
            let since = n?.downSince.map { Fmt.duration(Date().timeIntervalSince1970 - $0) }
            bigSubLabel.stringValue = since.map { "for \($0)" } ?? ""
        } else {
            showBig(main, r)
        }

        sparkline.points = r.series[main] ?? []
        sparkline.floor = main.chartFloor
        sparkline.maxGap = 10
        sparkline.isHidden = false

        var parts: [String] = []
        if let up = n?.uptimeS { parts.append("Up \(Fmt.ago(up))") }
        parts.append(String(format: "%.2f %% obstructed", (n?.obstructionFraction ?? 0) * 100))
        if status == .down, n?.dishReachable == false { parts = ["The dish isn't responding"] }
        statusLine.stringValue = parts.joined(separator: " · ")
        statusLine.isHidden = false

        var alerts = (n?.alerts ?? []).map(Labels.alert)
        if n?.currentlyObstructed == true { alerts.insert("Obstructed now", at: 0) }
        alertLine.stringValue = alerts.joined(separator: " · ")
        alertLine.textColor = ORANGE
        alertLine.isHidden = alerts.isEmpty

        dividers[0].isHidden = false
        sectionLabel.isHidden = true
        showColumns(r, except: main)

        showOutages(m.outages, title: "OUTAGES TODAY")

        let updated = n.map { Fmt.clock($0.ts) }
        footerLabel.stringValue = updated.map { "Updated \($0)" } ?? ""
        footerLabel.isHidden = updated == nil
        dividers[2].isHidden = footerLabel.isHidden
    }

    /// Off Starlink: the same card, measuring the network the Mac is on instead of the dish.
    private func showOffStarlink(_ m: Monitor) {
        let n = m.network
        let name = (n.connection ?? m.connection ?? "Network").uppercased()
        switch n.state {
        case "down": setHeader(name + " · NO INTERNET", dot: RED, prefix: false)
        case "degraded": setHeader(name + " · DEGRADED", dot: ORANGE, prefix: false)
        default: setHeader(name + " · CONNECTED", dot: GREEN, prefix: false)
        }

        // There's no power reading off Starlink: latency takes its place.
        let main = Metric.main == .power ? .latency : Metric.main
        let r = n.readings
        if n.state == "down" {
            bigLabel.stringValue = "Offline"
            bigLabel.textColor = RED
            bigSubLabel.stringValue = n.downSince.map { "for " + Fmt.duration(Date().timeIntervalSince($0)) } ?? ""
        } else {
            showBig(main, r, missing: "…")
        }

        sparkline.points = r.series[main] ?? []
        sparkline.floor = main.chartFloor
        sparkline.maxGap = NetworkStats.probeEvery * 4  // checks every few seconds, not every second
        sparkline.isHidden = false
        let onFor = Date().timeIntervalSince(n.connectedSince)
        statusLine.stringValue = "Connected for \(onFor < 60 ? "less than a minute" : Fmt.ago(onFor)) · Not on Starlink"
        statusLine.isHidden = false
        alertLine.isHidden = true
        dividers[0].isHidden = false
        sectionLabel.isHidden = true

        showColumns(r, except: main)

        showOutages(n.outages, title: "OUTAGES TODAY")

        if m.lanOverlapsDish {
            footerLabel.stringValue = "This network uses 192.168.100.x, the same addresses as the Starlink dish, so StarlinkBar can't reach it. Changing the router's LAN range fixes it."
        } else if let seen = m.lastSeen {
            let age = Date().timeIntervalSince(seen.date)
            let lat = seen.latencyMs.map { " · \(Int($0.rounded())) ms" } ?? ""
            footerLabel.stringValue = "Last seen on Starlink " + (age < 60 ? "just now" : Fmt.ago(age) + " ago") + lat
        } else {
            footerLabel.stringValue = "Starlink stats appear when you join a Starlink network"
        }
        footerLabel.isHidden = false
        dividers[2].isHidden = false
    }

    private func showNotConnected(_ m: Monitor, starting: Bool) {
        setHeader(starting ? "CONNECTING" : "NOT CONNECTED", dot: nil)
        bigLabel.textColor = .white
        bigLabel.stringValue = starting ? "…" : "—"
        bigSubLabel.stringValue = ""
        sparkline.isHidden = true
        alertLine.isHidden = true
        if starting {
            statusLine.stringValue = "Looking for the dish…"
        } else if m.source == .dish {
            statusLine.stringValue = m.lanOverlapsDish
                ? "This network uses 192.168.100.x, the same addresses as the dish, so it can't be reached."
                : "No internet, and the dish at \(m.dishHost) isn't answering."
        } else {
            statusLine.stringValue = "The collector at \(m.collectorURL.absoluteString) isn't answering."
        }
        statusLine.isHidden = false
        dividers[0].isHidden = starting
        sectionLabel.isHidden = true
        columnsRow.isHidden = true
        showOutages(nil, title: "", hideWhenMissing: true)

        if starting {
            footerLabel.isHidden = true
        } else if m.source == .dish {
            footerLabel.stringValue = "If macOS asked for Local Network access, allow it in System Settings › Privacy & Security › Local Network."
            footerLabel.isHidden = false
        } else {
            footerLabel.stringValue = "Start it with: python3 collector/main.py"
            footerLabel.isHidden = false
        }
        dividers[2].isHidden = true
    }

    private func showCallouts(_ callouts: [ServiceState.Callout]) {
        for v in calloutStack.arrangedSubviews { calloutStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for c in callouts {
            let color: NSColor
            switch c.level {
            case .problem: color = RED
            case .warning: color = ORANGE
            case .info: color = BLUE
            }
            calloutStack.addArrangedSubview(CalloutView(c.text, color: color))
        }
        calloutStack.isHidden = callouts.isEmpty
    }

    /// The main reading, big, with its 30-second average next to it.
    private func showBig(_ main: Metric, _ r: Readings, missing: String = "—") {
        bigLabel.textColor = .white
        bigLabel.stringValue = r.value[main].map { main.text($0) } ?? missing
        bigSubLabel.stringValue = r.average[main].map { "avg " + main.text($0) } ?? ""
    }

    /// Every reading except the main one, as title / value / unit.
    private func showColumns(_ r: Readings, except main: Metric) {
        for (column, metric) in zip(columns, Metric.allCases.filter { $0 != main }) {
            let v = r.value[metric]
            var color = NSColor.white
            if metric == .download { color = GREEN }
            if metric == .loss, (v ?? 0) > 2 { color = ORANGE }
            column.set(metric.title, metric.format(v), metric.unit, color: color)
        }
        columnsRow.alphaValue = 1
        columnsRow.isHidden = false
    }

    private func showOutages(_ o: Outages?, title: String, hideWhenMissing: Bool = false) {
        for v in outagesStack.arrangedSubviews { outagesStack.removeArrangedSubview(v); v.removeFromSuperview() }
        let hidden = hideWhenMissing && o == nil
        outagesHeader.isHidden = hidden
        outagesStack.isHidden = hidden
        dividers[1].isHidden = hidden || columnsRow.isHidden
        guard !hidden else { return }

        outagesTitle.stringValue = title
        if let o {
            outagesTotal.stringValue = o.count == 0 ? "" : "\(o.count) · \(Fmt.duration(o.totalS))"
            if o.items.isEmpty {
                outagesStack.addArrangedSubview(row("No outages today", nil))
            }
            for it in o.items.prefix(3) {
                let cause = Labels.causes[it.cause] ?? it.cause
                outagesStack.addArrangedSubview(row("\(Fmt.clock(it.startTs))  \(cause)", Fmt.duration(it.durationS)))
            }
            if o.items.count > 3 {
                let more = label("and \(o.items.count - 3) more", size: 11, weight: .regular, alpha: 0.4)
                outagesStack.addArrangedSubview(more)
            }
        } else {
            outagesTotal.stringValue = ""
            outagesStack.addArrangedSubview(row("Loading…", nil))
        }
    }

    private func row(_ name: String, _ value: String?) -> NSStackView {
        let nameLabel = label(name, size: 11, weight: .regular, alpha: 0.75)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let valueLabel = label(value ?? "", size: 11, weight: .medium, alpha: 0.5)
        let r = hstack([nameLabel, spacer(), valueLabel], spacing: 4, align: .centerY)
        r.widthAnchor.constraint(equalToConstant: CONTENT_W).isActive = true
        return r
    }

    private func resize() {
        contentView?.layoutSubtreeIfNeeded()
        let fit = contentView!.fittingSize
        let top = frame.maxY
        setContentSize(NSSize(width: PANEL_W, height: fit.height))
        // Grow/shrink downwards so the card stays pinned under the menu bar.
        if isVisible { setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top)) }
    }
}

// MARK: - Helpers

private func label(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    f.font = .systemFont(ofSize: size, weight: weight)
    f.textColor = NSColor.white.withAlphaComponent(alpha)
    return f
}

private func wrappingLabel(size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: "")
    f.font = .systemFont(ofSize: size, weight: weight)
    f.textColor = NSColor.white.withAlphaComponent(alpha)
    return f
}

private func hstack(_ views: [NSView], spacing: CGFloat, align: NSLayoutConstraint.Attribute) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    switch align {
    case .lastBaseline: s.alignment = .lastBaseline
    case .top: s.alignment = .top
    default: s.alignment = .centerY
    }
    s.spacing = spacing
    return s
}

private func spacer() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return v
}

/// Small uppercase title, bold value and its unit on three lines (DOWNLOAD / 1.8 / Mbps),
/// so four of them fit side by side.
private final class Column: NSStackView {
    private let title = label("", size: 9, weight: .semibold, alpha: 0.45)
    private let value = label("—", size: 13, weight: .bold, alpha: 1)
    private let unit = label("", size: 10, weight: .regular, alpha: 0.5)

    convenience init(align: NSLayoutConstraint.Attribute) {
        self.init(frame: .zero)
        orientation = .vertical
        alignment = align
        spacing = 1
        addArrangedSubview(title)
        addArrangedSubview(value)
        addArrangedSubview(unit)
    }

    func set(_ t: String, _ v: String, _ u: String, color: NSColor) {
        title.stringValue = t
        value.stringValue = v
        value.textColor = color
        unit.stringValue = u
    }
}

// MARK: - Card, divider, sparkline

private final class CardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 0.97).setFill()
        path.fill()
    }
}

/// A tinted box with one line of explanation (limit, suspension, update).
private final class CalloutView: NSView {
    private let color: NSColor

    init(_ text: String, color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let l = wrappingLabel(size: 11, weight: .medium, alpha: 1)
        l.stringValue = text
        l.textColor = color
        l.preferredMaxLayoutWidth = CONTENT_W - 16
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: CONTENT_W),
            l.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            l.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

private final class Divider: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: -1, height: 1) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.1).setFill()
        bounds.fill()
    }
}

/// Last 15 minutes of the main reading, drawn by hand (takes the place of the other apps' progress bar).
private final class Sparkline: NSView {
    var points: [Point] = [] { didSet { needsDisplay = true } }
    var maxGap: TimeInterval = 10   // break the line when samples are further apart than this
    var floor: Double = 40 { didSet { needsDisplay = true } }   // smallest top of the scale

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSColor.white.withAlphaComponent(0.04).setFill()
        bg.fill()

        let now = Date()
        let start = now.addingTimeInterval(-900)
        let visible = points.filter { $0.date >= start }
        guard visible.count > 1 else { return }
        let maxV = max(visible.map(\.value).max() ?? 1, floor) * 1.1
        let inset: CGFloat = 3
        let h = bounds.height - inset * 2
        func pt(_ p: Point) -> NSPoint {
            NSPoint(x: CGFloat(p.date.timeIntervalSince(start) / 900) * bounds.width,
                    y: inset + CGFloat(min(p.value, maxV) / maxV) * h)
        }

        let line = NSBezierPath()
        line.lineWidth = 1.2
        line.lineJoinStyle = .round
        var prev: Point?
        for p in visible {
            // Break the line across gaps in the data (outages, app asleep).
            if let q = prev, p.date.timeIntervalSince(q.date) <= maxGap { line.line(to: pt(p)) } else { line.move(to: pt(p)) }
            prev = p
        }
        NSColor.white.withAlphaComponent(0.7).setStroke()
        line.stroke()
    }
}
