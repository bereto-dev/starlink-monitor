import Cocoa

/// About window, same layout as the other menu bar apps (name + version, blurb, links).
final class AboutWindow: NSWindow {
    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "About StarlinkBar"
        isReleasedWhenClosed = false
        center()
        buildUI()
    }

    private func buildUI() {
        let root = NSView(frame: contentView!.bounds)
        contentView = root

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let appName = NSTextField(labelWithString: "StarlinkBar v\(version)")
        appName.font = .boldSystemFont(ofSize: 20)

        let appSub = body(
            "Keeps an eye on your Starlink connection from the menu bar: latency, packet loss, throughput, obstruction and today's outages, with a heads-up when the connection drops.")

        let howHeader = sectionHeader("How it works")
        let howBody = body(
            "It reads the dish on your local network directly, the same way the Starlink app does. It's read-only: it only asks for status and history and never sends commands to the dish.")

        let linksHeader = sectionHeader("Links")
        let updatesBtn = linkButton(title: "🔄  Check for Updates", url: StatusBarController.updatesURL)
        let sourceBtn = linkButton(title: "💻  Source on GitHub", url: StatusBarController.repoURL)

        let footnote = NSTextField(labelWithString: "Not affiliated with SpaceX or Starlink.")
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [
            icon, appName, appSub,
            div(),
            howHeader, howBody,
            div(),
            linksHeader, updatesBtn, sourceBtn,
            footnote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.setCustomSpacing(14, after: sourceBtn)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])

        root.layoutSubtreeIfNeeded()
        setContentSize(NSSize(width: 380, height: stack.fittingSize.height))
    }

    private func body(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: 12)
        f.textColor = .secondaryLabelColor
        f.widthAnchor.constraint(equalToConstant: 332).isActive = true
        return f
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text.uppercased())
        f.font = .systemFont(ofSize: 10, weight: .semibold)
        f.textColor = .tertiaryLabelColor
        return f
    }

    private func div() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.widthAnchor.constraint(equalToConstant: 332).isActive = true
        return v
    }

    private func linkButton(title: String, url: URL) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        b.bezelStyle = .inline
        b.isBordered = false
        b.font = .systemFont(ofSize: 12)
        b.contentTintColor = .linkColor
        b.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
        return b
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let s = sender.identifier?.rawValue, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
}
