import AppKit
import ProspectCore
import ProspectStage

/// Owns the projector window and keeps it where `ProjectorState` says it
/// belongs as displays come and go. The rules are in `ProjectorState`; this
/// only applies them.
@MainActor
final class ProjectorManager {
    let controller: ShowController
    let view = SurfaceView(role: .live)
    private var fullScreenWindow: ProjectorWindow?
    private var windowedWindow: NSWindow?

    /// The console's window, which the projector must never cover.
    weak var console: NSWindow?

    /// Called after the projector moves, opens or closes.
    var onChange: () -> Void = {}

    init(controller: ShowController) {
        self.controller = controller
        view.controller = controller
        // Handled on the next turn of the run loop, not while AppKit is still
        // rearranging displays: moving windows then breaks its transactions.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.displaysChanged() }
        }
    }

    var state: ProjectorState { controller.projector }

    /// Open Projector: on the show's display if it's connected, else on any
    /// display but the console's, else in a window.
    func open() {
        let whenMissing = MissingDisplay(rawValue: UserDefaults.standard.string(forKey: Preferences.missingDisplay) ?? "") ?? .window
        let opening = ProjectorState.opening(saved: controller.show.settings.projector,
                                             displays: Displays.current(), console: consoleDisplay, whenMissing: whenMissing)
        if case .fullScreen(let display) = opening, controller.show.settings.projector == nil {
            controller.setProjectorDisplay(display.identity)
        }
        apply(opening)
    }

    func close() {
        apply(.closed)
    }

    /// Choose Projector Display. Kept with the show; the projector moves
    /// there now if it's open.
    func choose(_ display: DisplayIdentity) {
        controller.setProjectorDisplay(display)
        if state.isOpen { open() }
    }

    /// Displays plugged or unplugged, rearranged, or the console moved onto
    /// another display.
    func displaysChanged() {
        apply(state.afterDisplaysChanged(Displays.current(), console: consoleDisplay))
    }

    var consoleDisplay: DisplayIdentity? {
        console?.screen.map { Displays.info(for: $0).identity }
    }

    /// The projector is on screen somewhere, so its display link can drive
    /// the clock.
    var isVisible: Bool {
        switch state {
        case .fullScreen, .standIn, .windowed: true
        case .closed, .waiting: false
        }
    }

    // MARK: Windows

    private func apply(_ new: ProjectorState) {
        let wasOpen = state.isOpen
        switch new {
        case .closed:
            fullScreenWindow?.orderOut(nil)
            windowedWindow?.orderOut(nil)
        case .fullScreen(let display), .standIn(let display, _):
            windowedWindow?.orderOut(nil)
            let window = fullScreenWindow ?? makeFullScreenWindow()
            fullScreenWindow = window
            window.contentView = view
            window.setFrame(display.frame, display: true)
            // In front, but never key: the console keeps the keyboard.
            window.orderFrontRegardless()
        case .windowed:
            fullScreenWindow?.orderOut(nil)
            let window = windowedWindow ?? makeWindowedWindow()
            windowedWindow = window
            if window.contentView !== view { window.contentView = view }
            if !window.isVisible {
                window.orderFront(nil)
                console?.makeKeyAndOrderFront(nil)
            }
        case .waiting:
            // Hidden, not moved: macOS would otherwise put the window on a
            // remaining display, over the console. Everything keeps running.
            fullScreenWindow?.orderOut(nil)
            windowedWindow?.orderOut(nil)
        }

        if new.isOpen, !wasOpen {
            controller.runner.attach(view.surface)
        } else if !new.isOpen, wasOpen {
            controller.runner.detach(view.surface)
        }
        view.hidesCursor = new.display != nil
        view.needsLayout = true
        controller.setProjector(new)
        onChange()
    }

    /// Borderless, black, above everything including that display's menu bar
    /// and Dock, out of Mission Control and Spaces, and immovable.
    private func makeFullScreenWindow() -> ProjectorWindow {
        let window = ProjectorWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isMovable = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        // Hide Prospect must not uncover the desktop on the projector.
        window.canHide = false
        window.isRestorable = false
        window.title = "Projector"
        return window
    }

    /// The fallback: an ordinary window on the console's display.
    private func makeWindowedWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Projector"
        window.isRestorable = false
        window.backgroundColor = .black
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ProjectorWindowed")
        if !window.setFrameUsingName("ProjectorWindowed") {
            if let screen = console?.screen {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 480, y: screen.visibleFrame.midY - 270))
            } else {
                window.center()
            }
        }
        return window
    }
}

/// A borderless window that can still take the keyboard if it's clicked, so
/// the show keys work there too.
final class ProjectorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
