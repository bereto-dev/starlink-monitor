import Cocoa

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildAppMenu()
        controller = StatusBarController(monitor: Monitor())
        // Daily update checks (Sparkle). Not in snapshot mode: that one renders and quits.
        if !CommandLine.arguments.contains("--snapshot") { Updater.shared.start() }
        // Debug: `StarlinkBar --check-for-updates` runs a user-initiated update check right away.
        if CommandLine.arguments.contains("--check-for-updates") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Updater.shared.checkForUpdates() }
        }

        // Debug: `StarlinkBar --snapshot out.png` renders the popup card to a PNG and quits.
        // Wait a few seconds first (override with `-snapshotDelay N`) so the data has loaded.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let delay = UserDefaults.standard.double(forKey: "snapshotDelay")
            DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 4)) { [controller] in
                controller?.writeSnapshot(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
    }

    /// A minimal Edit menu so Cmd+C/V/A work in the Settings text fields.
    private func buildAppMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        NSApp.mainMenu = mainMenu
    }
}
