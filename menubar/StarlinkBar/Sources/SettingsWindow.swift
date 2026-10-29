import Cocoa
import ServiceManagement

private let WIN_W: CGFloat = 440

/// Settings window. Every control applies immediately (no Save button).
@MainActor
final class SettingsWindow: NSWindow, NSTextFieldDelegate {
    var onChange: (() -> Void)?

    private let monitor: Monitor
    private let mainPopup = NSPopUpButton()
    private let menuBarCheck = NSButton(checkboxWithTitle: "Also show it in the menu bar", target: nil, action: nil)
    private let outagesCheck = NSButton(checkboxWithTitle: "Outages longer than 10 seconds", target: nil, action: nil)
    private let latencyCheck = NSButton(checkboxWithTitle: "High latency (over 80 ms for 5 minutes)", target: nil, action: nil)
    private let packetLossCheck = NSButton(checkboxWithTitle: "High packet loss (slow but not offline)", target: nil, action: nil)
    private let updatesNotifyCheck = NSButton(checkboxWithTitle: "The dish restarting for an update", target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "Open StarlinkBar at login", target: nil, action: nil)
    private let sourcePopup = NSPopUpButton()
    private let addressLabel = NSTextField(labelWithString: "")
    private let addressField = NSTextField()
    private let sourceHelp = NSTextField(wrappingLabelWithString: "")
    private let loginError = NSTextField(wrappingLabelWithString: "")
    private let updatesCheck = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)

    private var defaults: UserDefaults { .standard }

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: WIN_W, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "StarlinkBar Settings"
        isReleasedWhenClosed = false
        buildUI()
        load()
        center()
    }

    private func buildUI() {
        let root = NSView(frame: contentView!.bounds)
        contentView = root

        mainPopup.addItems(withTitles: Metric.allCases.map(\.name))
        mainPopup.target = self
        mainPopup.action = #selector(mainChanged)
        menuBarCheck.target = self
        menuBarCheck.action = #selector(mainChanged)

        for c in [outagesCheck, latencyCheck, packetLossCheck, updatesNotifyCheck] {
            c.target = self
            c.action = #selector(notificationsChanged)
        }
        updatesCheck.target = self
        updatesCheck.action = #selector(updatesChanged)
        loginCheck.target = self
        loginCheck.action = #selector(loginChanged)

        let testBtn = NSButton(title: "Send a test notification", target: self, action: #selector(sendTest))
        testBtn.bezelStyle = .inline
        testBtn.isBordered = false
        testBtn.font = .systemFont(ofSize: 12)
        testBtn.contentTintColor = .linkColor

        sourcePopup.addItems(withTitles: ["Starlink dish (direct)", "Collector"])
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)

        addressField.delegate = self
        addressField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        addressField.widthAnchor.constraint(equalToConstant: 230).isActive = true

        for f in [sourceHelp, loginError] {
            f.font = .systemFont(ofSize: 11)
            f.textColor = .secondaryLabelColor
            f.preferredMaxLayoutWidth = WIN_W - 48 - 130
        }
        loginError.textColor = .systemRed

        let mainHelp = NSTextField(wrappingLabelWithString: "The big number and chart in the popup. Power use is only measured on Starlink; on other networks latency shows instead.")
        mainHelp.font = .systemFont(ofSize: 11)
        mainHelp.textColor = .secondaryLabelColor
        mainHelp.preferredMaxLayoutWidth = WIN_W - 48 - 130
        let mainReading = vstack([mainPopup, menuBarCheck, mainHelp], spacing: 6)
        let notifications = vstack([outagesCheck, packetLossCheck, updatesNotifyCheck, latencyCheck, testBtn], spacing: 6)
        let login = vstack([loginCheck, loginError], spacing: 4)
        let address = vstack([addressField, sourceHelp], spacing: 4)

        let grid = NSGridView(views: [
            [rowLabel("Main reading"), mainReading],
            [rowLabel("Notify me about"), notifications],
            [rowLabel("Startup"), login],
            [rowLabel("Updates"), updatesCheck],
            [rowLabel("Data source"), sourcePopup],
            [addressLabel, address],
        ])
        addressLabel.font = .systemFont(ofSize: 13)
        addressLabel.alignment = .right
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 118
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
        ])
        root.layoutSubtreeIfNeeded()
        setContentSize(NSSize(width: WIN_W, height: grid.fittingSize.height + 48))
    }

    private func rowLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 13)
        f.alignment = .right
        return f
    }

    private func vstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    // MARK: - Load / apply

    private func load() {
        mainPopup.selectItem(at: Metric.allCases.firstIndex(of: Metric.main) ?? 0)
        menuBarCheck.state = Metric.showInMenuBar ? .on : .off
        outagesCheck.state = (defaults.object(forKey: "notifyOutages") as? Bool ?? true) ? .on : .off
        latencyCheck.state = defaults.bool(forKey: "notifyHighLatency") ? .on : .off
        packetLossCheck.state = (defaults.object(forKey: "notifyPacketLoss") as? Bool ?? true) ? .on : .off
        updatesNotifyCheck.state = (defaults.object(forKey: "notifyUpdates") as? Bool ?? true) ? .on : .off
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginError.isHidden = true
        updatesCheck.state = Updater.shared.automaticallyChecks ? .on : .off
        sourcePopup.selectItem(at: monitor.source == .dish ? 0 : 1)
        showAddress()
    }

    private func showAddress() {
        if monitor.source == .dish {
            addressLabel.stringValue = "Dish address"
            addressField.placeholderString = Monitor.defaultDishHost
            addressField.stringValue = defaults.string(forKey: "dishHost") ?? Monitor.defaultDishHost
            sourceHelp.stringValue = "StarlinkBar reads the dish on your network directly. The address is the same on every Starlink install, whatever your router's address is."
        } else {
            addressLabel.stringValue = "Collector URL"
            addressField.placeholderString = Monitor.defaultCollectorURL
            addressField.stringValue = defaults.string(forKey: "collectorURL") ?? Monitor.defaultCollectorURL
            sourceHelp.stringValue = "Reads from the optional Python collector, which keeps long-term history and serves the Starlink Dashboard."
        }
    }

    @objc private func mainChanged() {
        let main = Metric.allCases[mainPopup.indexOfSelectedItem]
        if main == .power, Metric.main != .power { monitor.refreshAll() }  // power comes from the history: fetch it now
        Metric.main = main
        Metric.showInMenuBar = menuBarCheck.state == .on
        onChange?()
    }

    @objc private func notificationsChanged() {
        defaults.set(outagesCheck.state == .on, forKey: "notifyOutages")
        defaults.set(latencyCheck.state == .on, forKey: "notifyHighLatency")
        defaults.set(packetLossCheck.state == .on, forKey: "notifyPacketLoss")
        defaults.set(updatesNotifyCheck.state == .on, forKey: "notifyUpdates")
    }

    @objc private func sendTest() {
        monitor.sendTestNotification()
    }

    @objc private func loginChanged() {
        do {
            if loginCheck.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError.isHidden = true
        } catch {
            loginError.stringValue = "Couldn't change this: \(error.localizedDescription) Moving StarlinkBar to Applications usually fixes it."
            loginError.isHidden = false
            loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func updatesChanged() {
        Updater.shared.automaticallyChecks = updatesCheck.state == .on
    }

    @objc private func sourceChanged() {
        let source: Monitor.Source = sourcePopup.indexOfSelectedItem == 0 ? .dish : .collector
        guard source != monitor.source else { return }
        defaults.set(source.rawValue, forKey: "source")
        showAddress()
        monitor.reset()
        onChange?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let value = addressField.stringValue.trimmingCharacters(in: .whitespaces)
        let key = monitor.source == .dish ? "dishHost" : "collectorURL"
        if value.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
        showAddress()
        monitor.reset()
        onChange?()
    }
}
