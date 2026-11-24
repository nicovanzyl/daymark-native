import AppKit
import SwiftUI

@MainActor
final class MenuBarStatus {
    private enum Dot: Equatable {
        case idle
        case active(NSColor)
    }

    private var lastDot: Dot?

    static func countdown(seconds: Int, locale: Locale = .autoupdatingCurrent) -> (title: String, spoken: String) {
        let minutes = (seconds + 59) / 60
        let remaining = Duration.seconds(minutes * 60)
        return (
            remaining.formatted(.units(allowed: [.hours, .minutes], width: .narrow).locale(locale)),
            remaining.formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(locale))
        )
    }

    func update(_ button: NSStatusBarButton, store: WorkspaceStore, at date: Date) {
        let configured = !store.workspace.needsSetup
        let moment = configured ? Schedule.current(store.blocks, at: date) : nil
        let indicator: Dot
        if let moment {
            let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            indicator = .active(NSColor(DaymarkPalette(dark: dark).block(moment.block.colour)))
            let countdown = Self.countdown(seconds: moment.seconds)
            let label = store.label(moment.block.colour)
            button.title = countdown.title
            button.imagePosition = .imageLeading
            button.toolTip = "\(label) until \(Schedule.clock(moment.block.end))"
            button.setAccessibilityValue("\(label), \(countdown.spoken) remaining")
        } else {
            indicator = .idle
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = configured ? "No active focus block" : "Set up Daymark"
            button.setAccessibilityValue(button.toolTip)
        }

        if indicator != lastDot {
            let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { bounds in
                let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
                if case let .active(fill) = indicator {
                    fill.setFill()
                    dot.fill()
                } else {
                    NSColor.black.setStroke()
                    dot.lineWidth = 1.5
                    dot.stroke()
                }
                return true
            }
            image.isTemplate = indicator == .idle
            button.image = image
            lastDot = indicator
        }
    }
}

@MainActor
final class DaymarkDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = WorkspaceStore()
    private let popover = NSPopover()
    private let menuBarStatus = MenuBarStatus()
    private var status: NSStatusItem?
    private var initialPresentation: _Concurrency.Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status = item
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Daymark")
        }

        let board = Board(store: store) { [weak self] in self?.popover.performClose(nil) }
        let host = NSHostingController(rootView: board)
        host.sizingOptions = []
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

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
        // Help first launch discover the menu item; subsequent launches stay in the bar.
        if store.workspace.needsSetup {
            initialPresentation = _Concurrency.Task { @MainActor in
                // A newly registered status item can have a zero-height window for its first layout passes.
                for _ in 0..<60 {
                    guard !_Concurrency.Task.isCancelled, store.workspace.needsSetup else { return }
                    if let anchor = status?.button?.window, anchor.screen != nil, !anchor.frame.isEmpty {
                        showBoard()
                        if popover.isShown { return }
                    }
                    do { try await _Concurrency.Task.sleep(for: .milliseconds(75)) } catch { return }
                }
            }
        }
    }

    @objc private func updateStatus() {
        guard let button = status?.button else { return }
        menuBarStatus.update(button, store: store, at: .now)
    }

    @objc private func statusItemClicked(_ button: NSStatusBarButton) {
        initialPresentation?.cancel()
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            let menu = NSMenu()
            let quit = menu.addItem(withTitle: "Quit Daymark", action: #selector(terminate), keyEquivalent: "q")
            quit.target = self
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showBoard()
        }
    }

    private func showBoard() {
        guard let button = status?.button, let screen = button.window?.screen ?? NSScreen.main else { return }
        let available = screen.visibleFrame.size
        popover.contentSize = NSSize(width: min(520, available.width - 24),
                                     height: min(580, available.height - 32))
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }

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
