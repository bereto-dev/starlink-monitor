import Cocoa
import Combine

/// Owns the status item, the popup card, the context menu and the Settings/About windows.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: Monitor
    private var popup: PopupPanel?
    private var settingsWin: SettingsWindow?
    private var aboutWin: AboutWindow?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var changes: AnyCancellable?
    private var renderScheduled = false

    static let repoURL = URL(string: "https://github.com/bereto-dev/starlink-monitor")!
    static let releasesURL = URL(string: "https://github.com/bereto-dev/starlink-monitor/releases/latest")!

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()

        if let btn = statusItem.button {
            btn.image = Self.statusBarIcon()
            btn.imagePosition = .imageLeft
            btn.action = #selector(statusItemClicked)
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Monitor publishes several properties per poll; coalesce them into one render.
        changes = monitor.objectWillChange.sink { [weak self] _ in self?.scheduleRender() }

        // A display being unplugged/replugged can leave the popup on a screen arrangement that
        // no longer exists, with no other way to dismiss it. Just close it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopup() }
        }

        render()
    }

    /// The dish while monitoring Starlink.
    private static let dishIcon = DishShape.menuBarImage()

    /// An antenna while the Mac is on another network (not a signal glyph: it would look like the system Wi‑Fi icon).
    private static let genericIcon: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let img = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "Network")?
            .withSymbolConfiguration(config)
        img?.isTemplate = true
        return img
    }()

    private static func statusBarIcon() -> NSImage? { dishIcon }

    // MARK: - Rendering

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.renderScheduled = false
                self?.render()
            }
        }
    }

    private func render() {
        updateStatusItem()
        if let p = popup, p.isVisible { p.update(from: monitor) }
    }

    private func updateStatusItem() {
        guard let btn = statusItem.button else { return }
        let status = monitor.status
        let offStarlink = status == .notOnStarlink
        let icon = offStarlink ? (Self.genericIcon ?? Self.dishIcon) : Self.dishIcon
        if btn.image !== icon { btn.image = icon }
        // Dimmed icon when there's nothing to measure (no connection at all, or still starting).
        btn.appearsDisabled = [.unreachable, .starting].contains(status)

        let display = UserDefaults.standard.string(forKey: "barDisplay") ?? "latency"
        var text = ""
        if offStarlink {
            // The same readout, for the network the Mac is on.
            let n = monitor.network
            if n.state == "down" {
                text = "offline"
            } else if display == "latency" {
                text = n.latencyMs.map { "\(Int($0.rounded())) ms" } ?? ""
            } else if display == "download" {
                text = n.downBps.map { "\(Fmt.mbps($0)) Mbps" } ?? ""
            }
        } else if status == .down {
            text = "offline"
        } else if [.ok, .degraded].contains(status), let n = monitor.now {
            switch display {
            case "latency": text = n.latencyMs.map { "\(Int($0.rounded())) ms" } ?? ""
            case "download": text = "\(Fmt.mbps(n.downBps)) Mbps"
            default: text = ""
            }
        }
        let title = text.isEmpty ? "" : " " + text
        if btn.title != title { btn.title = title }
    }

    // MARK: - Popup

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            closePopup()
            showContextMenu()
            return
        }
        if let p = popup, p.isVisible {
            closePopup()
        } else {
            openPopup()
        }
    }

    private func openPopup() {
        guard let btn = statusItem.button, let btnWindow = btn.window,
              let screen = btnWindow.screen ?? NSScreen.main else { return }

        if popup == nil {
            popup = PopupPanel()
        }
        guard let popup else { return }
        popup.update(from: monitor)

        let btnFrame = btnWindow.convertToScreen(btn.frame)
        let panelW = popup.frame.width
        // The visible card is inset 6 pt inside the panel, so lift the panel by that much to keep
        // the visible gap to the menu bar at `visualGap`.
        let visualGap: CGFloat = 4
        let cardTopInset: CGFloat = 6
        var x = btnFrame.midX - panelW / 2
        x = min(x, screen.visibleFrame.maxX - panelW - 8)
        x = max(x, screen.visibleFrame.minX + 8)
        popup.setFrameTopLeftPoint(NSPoint(x: x, y: btnFrame.minY - visualGap + cardTopInset))
        popup.orderFrontRegardless()

        // Clicks in other apps (global) or in our own other windows (local) dismiss the popup.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopup() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Ignore clicks on the popup and on the status item: the button's own action
                // toggles, and closing here first would make it reopen immediately.
                if event.window !== self.popup && event.window !== self.statusItem.button?.window {
                    self.closePopup()
                }
            }
            return event
        }
    }

    private func closePopup() {
        popup?.orderOut(nil)
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
    }

    // MARK: - Context menu

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(item("Refresh Now", #selector(refreshNow), "r"))
        if monitor.source == .collector {
            menu.addItem(item("Open Starlink Dashboard", #selector(openDashboard), ""))
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), ","))
        menu.addItem(item("About StarlinkBar", #selector(showAbout), ""))
        menu.addItem(item("Check for Updates", #selector(openUpdates), ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit StarlinkBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func refreshNow() {
        Task { await monitor.refreshNow() }
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(monitor.collectorURL.appendingPathComponent("sl-dashboard/"))
    }

    @objc private func openUpdates() {
        NSWorkspace.shared.open(Self.releasesURL)
    }

    @objc private func showSettings() {
        if settingsWin == nil {
            let w = SettingsWindow(monitor: monitor)
            w.onChange = { [weak self] in self?.render() }
            settingsWin = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWin?.center()
        settingsWin?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout() {
        if aboutWin == nil { aboutWin = AboutWindow() }
        NSApp.activate(ignoringOtherApps: true)
        aboutWin?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Debug snapshot

    func writeSnapshot(to url: URL) {
        let p = popup ?? PopupPanel()
        p.update(from: monitor)
        guard let view = p.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)

        // `-snapshotWindows YES` also renders Settings and About next to it.
        guard UserDefaults.standard.bool(forKey: "snapshotWindows") else { return }
        let dir = url.deletingLastPathComponent()
        for (name, window) in [("settings", SettingsWindow(monitor: monitor) as NSWindow), ("about", AboutWindow())] {
            guard let v = window.contentView?.superview ?? window.contentView,
                  let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: r)
            try? r.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
