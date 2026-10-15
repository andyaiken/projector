import AppKit
import IOKit.pwr_mgt
import ProspectCore
import ProspectStage
import UniformTypeIdentifiers

@main
@MainActor
enum ProspectMain {
    static let delegate = AppDelegate()

    static func main() {
        // The first document controller made becomes the shared one.
        _ = DocumentController()
        let app = ProspectApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

/// Quit asks about a live projector before anything else happens. Left to
/// AppKit, Quit saves and closes the show, and the projector with it, before
/// it asks the app delegate whether to quit at all, which is too late to ask.
final class ProspectApplication: NSApplication {
    override func terminate(_ sender: Any?) {
        guard let delegate = delegate as? AppDelegate else {
            super.terminate(sender)
            return
        }
        delegate.confirmQuit { quit in
            if quit { super.terminate(sender) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let displaySleep = DisplaySleepGuard()
    private var preferences: PreferencesWindowController?
    private var askingToQuit = false

    private var documents: DocumentController { NSDocumentController.shared as! DocumentController }
    /// The one show open, if any.
    private var current: ShowDocument? { documents.current }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            Preferences.reopenLastShow: true,
            Preferences.missingDisplay: MissingDisplay.window.rawValue,
        ])
        NSApp.mainMenu = MainMenu.build(displayMenuDelegate: self)

        #if DEBUG
        if let directory = UserDefaults.standard.string(forKey: "ProspectSnapshot") {
            Snapshots.run(to: directory)
            return
        }
        if let directory = UserDefaults.standard.string(forKey: "ProspectDocumentCheck") {
            DocumentCheck.run(in: directory)
            return
        }
        #endif

        // A quiet scene can run twenty minutes between cues, well inside any
        // sleep timer, so the display is kept awake whenever a show is open.
        displaySleep.hold(reason: "Prospect has a show open")
        // After any show Finder asked to open has been opened.
        DispatchQueue.main.async { self.openFirstShow() }
        NSApp.activate()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    /// The operator's first action on the night should be GO, not finding a
    /// file: after a crash, the show that was running, offering to resume;
    /// otherwise the most recent show; otherwise a new one.
    private func openFirstShow() {
        if let record = CrashRecords.read(), FileManager.default.fileExists(atPath: record.show.path) {
            documents.openDocument(withContentsOf: record.show, display: true) { [weak self] document, _, _ in
                MainActor.assumeIsolated {
                    guard let document = document as? ShowDocument else {
                        self?.documents.newDocument(nil)
                        return
                    }
                    self?.offerResume(record, in: document)
                }
            }
            return
        }
        guard documents.documents.isEmpty else { return }
        if UserDefaults.standard.bool(forKey: Preferences.reopenLastShow),
           let url = documents.recentDocumentURLs.first, FileManager.default.fileExists(atPath: url.path) {
            documents.openDocument(withContentsOf: url, display: true) { [weak self] document, _, _ in
                if document == nil { MainActor.assumeIsolated { self?.documents.newDocument(nil) } }
            }
        } else {
            documents.newDocument(nil)
        }
    }

    /// Resume puts the last fired cue straight back on the projector,
    /// finished, and stands by the next.
    private func offerResume(_ record: CrashRecord, in document: ShowDocument) {
        guard let window = document.console?.window, let controller = document.controller else { return }
        let cue = controller.show[record.cue] ?? controller.show.index(ofNumber: record.cueNumber).map { controller.show.cues[$0] }
        guard let cue else { return }
        let alert = NSAlert()
        alert.messageText = "Prospect stopped unexpectedly during the show."
        alert.informativeText = "The last cue fired was cue \(cue.number). Resuming puts it straight back on the projector, finished, and stands by the next."
        alert.addButton(withTitle: "Resume at Cue \(cue.number)")
        alert.addButton(withTitle: "Start from the Top")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                document.projector?.open()
                controller.resume(at: cue.id)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        displaySleep.release()
        CrashRecords.clear()
    }

    /// Windows come and go while one show replaces another. Quitting follows
    /// the show instead: see DocumentController.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// While the projector is live, Quit asks first, on the console, before
    /// the show is saved or closed. Cancel is the default, so a reflexive
    /// Return doesn't quit, and Escape cancels.
    func confirmQuit(_ then: @escaping (Bool) -> Void) {
        guard let document = current, document.projectorIsOpen, let window = document.console?.window,
              let controller = document.controller else {
            then(true)
            return
        }
        // A second Quit while the sheet is up is the same question.
        guard !askingToQuit else { return }
        askingToQuit = true
        let alert = NSAlert()
        alert.messageText = "Quit while the projector is live?"
        let live = controller.playhead.live.flatMap { controller.show[$0] }
        alert.informativeText = live.map { "Cue \($0.number) stays on the projector until Prospect quits." }
            ?? "Quitting takes the projector window away."
        alert.addButton(withTitle: "Cancel")
        let quit = alert.addButton(withTitle: "Quit")
        quit.hasDestructiveAction = true
        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.askingToQuit = false
                then(response == .alertSecondButtonReturn)
            }
        }
    }

    // MARK: Settings

    @objc func showSettings(_ sender: Any?) {
        let preferences = self.preferences ?? PreferencesWindowController()
        self.preferences = preferences
        preferences.refresh()
        preferences.showWindow(nil)
    }

    // MARK: Edit

    @objc func addTitleCue(_ sender: Any?) { current?.controller?.addCue(.title) }
    @objc func addImageCue(_ sender: Any?) { current?.controller?.addCue(.image) }
    @objc func addVideoCue(_ sender: Any?) { current?.controller?.addCue(.video) }
    @objc func addBlankCue(_ sender: Any?) { current?.controller?.addCue(.blank) }
    @objc func renumberAllCues(_ sender: Any?) { current?.console?.confirmRenumber() }

    // MARK: Show

    @objc func enterShowMode(_ sender: Any?) { current?.enterShowMode() }
    @objc func enterEditMode(_ sender: Any?) { current?.enterEditMode() }

    @objc func toggleProjector(_ sender: Any?) {
        guard let projector = current?.projector else { return }
        if projector.state.isOpen { projector.close() } else { projector.open() }
    }

    @objc func chooseProjectorDisplay(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayIdentity else { return }
        current?.projector?.choose(display)
    }

    @objc func toggleBlackout(_ sender: Any?) { current?.controller?.toggleBlackout() }

    // MARK: Window

    @objc func showConsole(_ sender: Any?) { current?.showWindows() }
    @objc func showProjector(_ sender: Any?) {
        if let projector = current?.projector, !projector.state.isOpen { projector.open() }
    }

    // MARK: Menus

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let controller = current?.controller
        let editing = controller?.mode == .edit
        switch item.action {
        case #selector(addTitleCue(_:)), #selector(addImageCue(_:)), #selector(addVideoCue(_:)), #selector(addBlankCue(_:)):
            return editing
        case #selector(renumberAllCues(_:)):
            return editing && controller?.show.cues.isEmpty == false
        case #selector(enterShowMode(_:)): return controller != nil && editing
        case #selector(enterEditMode(_:)): return controller != nil && !editing
        case #selector(toggleProjector(_:)):
            item.title = current?.projector?.state.isOpen == true ? "Close Projector" : "Open Projector"
            return controller != nil
        case #selector(toggleBlackout(_:)):
            item.state = controller?.playhead.blackout == true ? .on : .off
            return controller != nil
        case #selector(chooseProjectorDisplay(_:)):
            return item.representedObject != nil
        case #selector(showConsole(_:)), #selector(showProjector(_:)):
            return controller != nil
        default:
            return true
        }
    }

    /// Choose Projector Display: every connected display by name. The
    /// console's own display is listed but can't be chosen.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let console = current?.projector?.consoleDisplay
        let chosen = current?.show.settings.projector
        let displays = Displays.current()
        for display in displays {
            let isConsole = console.map { display.identity.bestMatch(in: [$0]) != nil } ?? false
            let item = NSMenuItem(title: display.identity.name + (isConsole ? " \u{2014} the console\u{2019}s display" : ""),
                                  action: #selector(chooseProjectorDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = isConsole ? nil : display.identity
            if let chosen, chosen.bestMatch(in: [display.identity]) != nil { item.state = .on }
            menu.addItem(item)
        }
        if displays.count < 2 {
            menu.addItem(.separator())
            let note = NSMenuItem(title: "Connect the projector to choose it here", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
    }
}

enum Preferences {
    /// Open the most recent show on launch. On unless turned off.
    static let reopenLastShow = "ReopenLastShow"
    /// What the projector does when a show's display isn't connected: a
    /// `MissingDisplay` raw value. A window unless set otherwise.
    static let missingDisplay = "MissingProjectorDisplay"
}

/// Where the crash record lives: outside any document, in Application Support.
enum CrashRecords {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Prospect")
            .appendingPathComponent("LastCue.json")
    }

    static func write(_ record: CrashRecord) { try? record.write(to: url) }
    static func read() -> CrashRecord? { CrashRecord.read(from: url) }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}

/// Which display link drives the cue clock: the projector's while it is on
/// screen, so frames land on its refresh, and the console preview's while it
/// isn't, so cues keep running through a knocked cable.
@MainActor
final class ClockSource {
    private let projector: SurfaceView
    private let preview: SurfaceView

    var ticking = false { didSet { update() } }
    var projectorVisible = false { didSet { update() } }

    init(projector: SurfaceView, preview: SurfaceView) {
        self.projector = projector
        self.preview = preview
    }

    private func update() {
        projector.setTicking(ticking && projectorVisible)
        preview.setTicking(ticking && !projectorVisible)
    }
}

/// Keeps the displays awake.
final class DisplaySleepGuard {
    private var assertion = IOPMAssertionID(0)
    private var held = false

    func hold(reason: String) {
        guard !held else { return }
        held = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertion
        ) == kIOReturnSuccess
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertion)
        held = false
    }
}

/// The menu bar. It adds what macOS users look for and nothing that
/// duplicates a show control: GO has no menu item and no key equivalent
/// beyond the spacebar, and changing mode has no key equivalent at all.
enum MainMenu {
    @MainActor
    static func build(displayMenuDelegate: NSMenuDelegate) -> NSMenu {
        let bar = NSMenu()

        let app = submenu(of: bar, titled: "Prospect")
        app.addItem(withTitle: "About Prospect", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings\u{2026}", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Prospect", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Prospect", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(of: bar, titled: "File")
        file.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Open\u{2026}", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        // The document controller fills the menu holding Clear Menu.
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save\u{2026}", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let duplicate = file.addItem(withTitle: "Duplicate", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "s")
        duplicate.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Rename\u{2026}", action: #selector(NSDocument.rename(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Move To\u{2026}", action: #selector(NSDocument.move(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Revert to Saved", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Browse All Versions\u{2026}", action: #selector(NSDocument.browseVersions(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Print Cue Sheet\u{2026}", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")
        let export = file.addItem(withTitle: "Export Cue Sheet as PDF\u{2026}", action: #selector(ShowDocument.exportCueSheet(_:)), keyEquivalent: "p")
        export.keyEquivalentModifierMask = [.command, .option]
        file.addItem(.separator())
        file.addItem(withTitle: "Remove Unused Media\u{2026}", action: #selector(ShowDocument.removeUnusedMedia(_:)), keyEquivalent: "")

        let edit = submenu(of: bar, titled: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Add Decryption Cue", action: #selector(AppDelegate.addTitleCue(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Add Image Cue", action: #selector(AppDelegate.addImageCue(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Add Video Cue", action: #selector(AppDelegate.addVideoCue(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Add Blank Cue", action: #selector(AppDelegate.addBlankCue(_:)), keyEquivalent: "")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Renumber All Cues\u{2026}", action: #selector(AppDelegate.renumberAllCues(_:)), keyEquivalent: "")

        let show = submenu(of: bar, titled: "Show")
        show.addItem(withTitle: "Enter Show Mode", action: #selector(AppDelegate.enterShowMode(_:)), keyEquivalent: "")
        show.addItem(withTitle: "Enter Edit Mode", action: #selector(AppDelegate.enterEditMode(_:)), keyEquivalent: "")
        show.addItem(.separator())
        show.addItem(withTitle: "Open Projector", action: #selector(AppDelegate.toggleProjector(_:)), keyEquivalent: "")
        let choose = NSMenuItem(title: "Choose Projector Display", action: nil, keyEquivalent: "")
        let displays = NSMenu(title: "Choose Projector Display")
        displays.delegate = displayMenuDelegate
        choose.submenu = displays
        show.addItem(choose)
        show.addItem(.separator())
        // Blackout's key is B, with the other show keys.
        show.addItem(withTitle: "Blackout", action: #selector(AppDelegate.toggleBlackout(_:)), keyEquivalent: "")

        let window = submenu(of: bar, titled: "Window")
        window.addItem(withTitle: "Console", action: #selector(AppDelegate.showConsole(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Projector", action: #selector(AppDelegate.showProjector(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return bar
    }

    @MainActor
    private static func submenu(of bar: NSMenu, titled title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        bar.addItem(item)
        return menu
    }
}
