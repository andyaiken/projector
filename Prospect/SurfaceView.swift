import AppKit
import ProspectCore
import ProspectStage
import QuartzCore

/// Hosts a stage surface: the projector's, or the console's preview. Runs a
/// display link that follows whichever screen the view is on, and takes the
/// show keys when its window is key.
@MainActor
final class SurfaceView: NSView {
    let surface: SurfaceLayer
    weak var controller: ShowController?
    private var link: CADisplayLink?

    /// Hide the cursor over this view. The projector never shows one.
    var hidesCursor = false {
        didSet { if !hidesCursor { showCursor() } }
    }

    private var cursorHidden = false

    init(role: SurfaceLayer.Role) {
        surface = SurfaceLayer(role: role)
        super.init(frame: .zero)
        // Layer-hosting: the view's layer is the surface itself.
        layer = surface
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        surface.frame = bounds
        controller?.runner.relayout(surface)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        surface.contentsScale = window?.backingScaleFactor ?? 2
        controller?.runner.relayout(surface)
    }

    // MARK: Clock

    /// Runs or pauses this view's display link.
    func setTicking(_ on: Bool) {
        if link == nil, on {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = !on
    }

    @objc private func step(_ link: CADisplayLink) {
        controller?.tick(at: link.targetTimestamp)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let controller, ShowKeys.handle(event, controller: controller) else {
            super.keyDown(with: event)
            return
        }
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard hidesCursor, !cursorHidden else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    override func mouseExited(with event: NSEvent) {
        showCursor()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        showCursor()
    }

    private func showCursor() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }
}

/// The show keys, the same in every window. Returns false only for keys
/// that belong to the menus.
enum ShowKeys {
    @MainActor
    static func handle(_ event: NSEvent, controller: ShowController) -> Bool {
        // Command-key combinations belong to the menus.
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        // Holding a key down must never fire a run of cues. Every other plain
        // key is swallowed, handled or not: an unhandled key makes the Mac
        // beep, and the beep is heard in the room.
        if event.isARepeat { return true }

        switch Int(event.keyCode) {
        case 49: controller.go()                                // space
        case 124, 125, 121: controller.standByNext()            // → ↓ PageDown
        case 123, 126, 116: controller.standByPrevious()        // ← ↑ PageUp
        case 36, 76: controller.commitEntry()                   // Return, Enter
        case 53: controller.clearEntry()                        // Escape
        case 51, 117: controller.deleteBackward()               // Delete, forward delete
        default:
            guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return true }
            switch c {
            case "0"..."9", ".": controller.type(c)
            case "r": controller.rerun()
            case "b": controller.toggleBlackout()
            default: break
            }
        }
        return true
    }
}

/// Connected displays, described for projector placement.
enum Displays {
    static func info(for screen: NSScreen) -> DisplayInfo {
        let id = screen.displayID
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        return DisplayInfo(
            identity: DisplayIdentity(uuid: uuid, name: screen.localizedName,
                                      vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id)),
            frame: screen.frame,
            // The first screen is the one with the menu bar.
            isMain: screen == NSScreen.screens.first
        )
    }

    static func current() -> [DisplayInfo] {
        NSScreen.screens.map(info(for:))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
