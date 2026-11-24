import AppKit
import SwiftUI

@MainActor
final class DaymarkDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = WorkspaceStore()
    var status: NSStatusItem?
    var window: NSWindow?
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Daymark", action: #selector(showBoard), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Daymark", action: #selector(terminate), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        status?.menu = menu

        let appMenu = NSMenu()
        let app = NSMenuItem()
        let appSubmenu = NSMenu()
        let appQuit = NSMenuItem(title: "Quit Daymark", action: #selector(terminate), keyEquivalent: "q")
        appQuit.target = self
        appSubmenu.addItem(appQuit)
        app.submenu = appSubmenu
        appMenu.addItem(app)
        let edit = NSMenuItem()
        let editSubmenu = NSMenu(title: "Edit")
        for (label, key, action) in [("Cut", "x", "cut:"), ("Copy", "c", "copy:"), ("Paste", "v", "paste:"), ("Select All", "a", "selectAll:")] {
            editSubmenu.addItem(withTitle: label, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = editSubmenu
        appMenu.addItem(edit)
        NSApp.mainMenu = appMenu

        updateStatus()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(updateStatus), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Help first launch discover the menu item; subsequent launches stay in the bar.
        if !store.workspace.settings.onboardingComplete { showBoard() }
    }

    @objc private func updateStatus() {
        guard let button = status?.button else { return }
        let state = store.workspace.settings
        if state.onboardingComplete, let moment = Schedule.current(store.blocks, at: .now) {
            let label = store.label(moment.block.colour)
            let minutes = (moment.seconds + 59) / 60
            button.title = " \(String(label.prefix(17))) · \(minutes)m"
            button.toolTip = "\(label) until \(Schedule.clock(moment.block.end))"
        } else {
            button.title = " Daymark"
            button.toolTip = state.onboardingComplete ? "No active focus block" : "Set up Daymark"
        }
        button.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Daymark")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(button.toolTip ?? "Daymark")
    }

    @objc private func showBoard() {
        if window == nil {
            let board = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 690),
                                 styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                 backing: .buffered, defer: false)
            board.title = "Daymark"
            board.isReleasedWhenClosed = false
            board.minSize = NSSize(width: 540, height: 460)
            board.contentViewController = NSHostingController(rootView: Board(store: store))
            board.setFrameAutosaveName("DaymarkNativeBoard")
            if !board.setFrameUsingName("DaymarkNativeBoard") { board.center() }
            board.delegate = self
            window = board
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func terminate() { NSApp.terminate(nil) }
}

@main
struct DaymarkApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do { try SelfTest.run(); print("Daymark native self-test passed."); exit(0) }
            catch { fputs("Daymark native self-test failed: \(error)\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = DaymarkDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
