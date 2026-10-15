import AppKit
import ProspectCore
import ProspectStage
import UniformTypeIdentifiers

/// A show on disk: the `.prospect` package, opened with standard Open, Save,
/// Duplicate and version history, and autosaved in place.
///
/// The document keeps the file wrapper it read and hands back the same one,
/// with only show.json and the version replaced, so media are never
/// rewritten. In show mode the document is read-only: nothing can change, so
/// nothing is written.
final class ShowDocument: NSDocument {
    static let typeName = "com.andyaiken.prospect.show"

    // `read(from:ofType:)` is declared callable off the main thread, and sets
    // these three. It never is here: documents aren't read concurrently (see
    // `canConcurrentlyReadDocuments`), so NSDocument reads on the main thread,
    // before any window exists.

    /// The show as read, or as handed over by Import. Once the windows exist
    /// the controller holds the live copy.
    nonisolated(unsafe) private var initialShow = Show()
    private var initialWarnings: [String] = []
    nonisolated(unsafe) private var package: FileWrapper?
    /// Imports not saved into the package yet: their path in the package,
    /// and the file they were copied from, which renderers use meanwhile.
    private var pendingMedia: [String: URL] = [:]
    /// New and imported shows are being written, so they start in edit
    /// mode. A show opened from disk always opens in show mode.
    nonisolated(unsafe) private var startsInEditMode = true

    private(set) var controller: ShowController?
    private(set) var console: ConsoleWindowController?
    private(set) var projector: ProjectorManager?
    private var clock: ClockSource?

    override class var autosavesInPlace: Bool { true }

    /// One at a time, on the main thread, which the properties `read` sets
    /// rely on.
    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    /// A new, unsaved show with this sheet.
    convenience init(show: Show, warnings: [String]) {
        self.init()
        fileType = Self.typeName
        initialShow = show
        initialWarnings = warnings
    }

    var show: Show { controller?.show ?? initialShow }

    var projectorIsOpen: Bool { controller?.projector.isOpen ?? false }

    // MARK: Reading and writing

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        initialShow = try ShowPackage.read(fileWrapper)
        package = fileWrapper
        startsInEditMode = false
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let wrapper = try ShowPackage.updated(package, with: show)
        package = wrapper
        return wrapper
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        // Show mode never writes the document. Nothing can change in show
        // mode, and pending edits are saved on the way in, so there is
        // normally nothing to save; this only stops a save of a clean show.
        if controller?.mode == .show, !isDocumentEdited, !hasUnautosavedChanges,
           saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation {
            completionHandler(nil)
            return
        }
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, saveOperation != .saveToOperation { self?.refreshPackage(from: url) }
            completionHandler(error)
        }
    }

    /// After a save, the wrapper is read back from where it was written, so
    /// its media refer to the package rather than to the files they were
    /// imported from, and the next save links them instead of copying.
    private func refreshPackage(from url: URL) {
        guard let saved = try? FileWrapper(url: url, options: []) else { return }
        package = saved
        pendingMedia.removeAll()
    }

    /// Where a cue's media path is on disk right now.
    func mediaURL(_ path: String) -> URL? {
        if let pending = pendingMedia[path] { return pending }
        guard let base = fileURL ?? autosavedContentsFileURL else { return nil }
        return base.appendingPathComponent(path)
    }

    // MARK: Windows

    override func makeWindowControllers() {
        let media: (String) -> URL? = { [weak self] path in self?.mediaURL(path) }
        let controller = ShowController(
            show: initialShow, warnings: initialWarnings, mode: startsInEditMode ? .edit : .show,
            renderers: [
                .title: TitleRenderer(),
                .image: ImageRenderer(media: media),
                .video: VideoRenderer(media: media),
                .blank: BlankRenderer(),
            ]
        )
        self.controller = controller
        if initialShow.cues.isEmpty {
            controller.say("Add a cue to begin, with Add Cue at the top or from the Edit menu.")
        }

        // addWindowController sets the console's document. Setting it first
        // makes AppKit treat the console as already added, and the show is
        // left owning no windows, so showWindows puts nothing on screen.
        let console = ConsoleWindowController(controller: controller)
        console.importMedia = { [weak self] url, cue in self?.importMedia(from: url, into: cue) }
        console.chooseMedia = { [weak self] cue in self?.chooseMedia(for: cue) }
        addWindowController(console)
        self.console = console

        let projector = ProjectorManager(controller: controller)
        projector.console = console.window
        self.projector = projector
        let clock = ClockSource(projector: projector.view, preview: console.preview)
        self.clock = clock

        controller.changed = { [weak console] in console?.setNeedsRefresh() }
        controller.needsTicks = { [weak clock] on in clock?.ticking = on }
        projector.onChange = { [weak clock, weak projector] in clock?.projectorVisible = projector?.isVisible ?? false }
        console.openProjector = { [weak projector] in projector?.open() }
        console.setMode = { [weak self] editing in
            if editing { self?.enterEditMode() } else { self?.enterShowMode() }
        }
        console.screenChanged = { [weak projector] in projector?.displaysChanged() }
        controller.onEdit = { [weak self] before, name in self?.registerUndo(back: before, name: name) }
        controller.onFire = { [weak self] cue in
            // Untitled shows have nowhere to be reopened from.
            guard let url = self?.fileURL else { return }
            CrashRecords.write(CrashRecord(show: url, cue: cue.id, cueNumber: cue.number, firedAt: Date()))
        }
    }

    /// Closing a show is a clean stop, so there is nothing to resume.
    override func close() {
        projector?.close()
        CrashRecords.clear()
        super.close()
    }

    // MARK: Undo

    /// Every edit is undone by putting the whole sheet back, and redone the
    /// same way.
    private func registerUndo(back show: Show, name: String) {
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.restore(show, name: name) }
        }
        undoManager?.setActionName(name)
    }

    private func restore(_ show: Show, name: String) {
        guard let controller else { return }
        let current = controller.show
        controller.restore(show)
        registerUndo(back: current, name: name)
    }

    // MARK: Modes

    /// Pending edits are saved before the show locks, because nothing is
    /// written in show mode.
    func enterShowMode() {
        guard let controller, controller.mode == .edit else { return }
        if hasUnautosavedChanges {
            autosave(withImplicitCancellability: false) { _ in }
        }
        controller.enterShowMode()
    }

    func enterEditMode() {
        controller?.enterEditMode()
    }

    // MARK: Media

    /// Copies a picture or clip into the show and gives it to a cue. The
    /// original can then be moved or deleted without breaking the show.
    func importMedia(from url: URL, into cueID: UUID) {
        guard let controller, controller.mode == .edit, let cue = controller.show[cueID] else { return }
        guard Self.accepts(url, for: cue.kind) else {
            controller.say("\(url.lastPathComponent) isn\u{2019}t \(cue.kind == .video ? "a clip" : "a picture") this cue can use.")
            return
        }
        do {
            let package = try ShowPackage.updated(self.package, with: controller.show)
            self.package = package
            let path = try ShowPackage.importMedia(from: url, into: package)
            pendingMedia[path] = url
            controller.updateCue(cueID, cue.kind == .video ? "Set Clip" : "Set Picture") { cue in
                switch cue.content {
                case .image(var c): c.src = path; cue.content = .image(c)
                case .video(var c): c.src = path; cue.content = .video(c)
                default: break
                }
            }
        } catch {
            controller.say("\(url.lastPathComponent) couldn\u{2019}t be copied into the show.")
        }
    }

    static func accepts(_ url: URL, for kind: Cue.Kind) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        switch kind {
        case .image: return type.conforms(to: .image)
        case .video: return type.conforms(to: .movie)
        default: return false
        }
    }

    func chooseMedia(for cueID: UUID) {
        guard let window = console?.window, let cue = controller?.show[cueID] else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = cue.kind == .video ? [.movie] : [.image]
        panel.message = cue.kind == .video ? "Choose a clip for cue \(cue.number)." : "Choose a picture for cue \(cue.number)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.importMedia(from: url, into: cueID) }
        }
    }

    /// Remove Unused Media: files no cue refers to, after a confirmation.
    @objc func removeUnusedMedia(_ sender: Any?) {
        guard let controller, controller.mode == .edit, let window = console?.window,
              let package = try? ShowPackage.updated(package, with: controller.show) else { return }
        self.package = package
        let unused = ShowPackage.unusedMedia(in: package, show: controller.show)
        let alert = NSAlert()
        guard !unused.isEmpty else {
            alert.messageText = "Every picture and clip in the show is used by a cue."
            alert.beginSheetModal(for: window)
            return
        }
        alert.messageText = "Remove \(unused.count) unused file\(unused.count == 1 ? "" : "s") from the show?"
        alert.informativeText = unused.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            + "\n\nEarlier versions of the show keep them, in File \u{203A} Revert To."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                ShowPackage.removeMedia(unused, from: package)
                for path in unused { self.pendingMedia.removeValue(forKey: path) }
                self.updateChangeCount(.changeDone)
                controller.say("Removed \(unused.count) unused file\(unused.count == 1 ? "" : "s").")
            }
        }
    }

    // MARK: Cue sheet

    /// The title printed at the head of every page: the show's own, or the
    /// file's name if it hasn't one.
    var sheetTitle: String { show.title.isEmpty ? displayName : show.title }

    /// Print Cue Sheet: the print panel, with the layout chosen in it. The
    /// panel is a sheet on the console, never on the projector.
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        return CueSheetPrinting.operation(for: show, title: sheetTitle, layout: .dsm, printInfo: info)
    }

    /// Export Cue Sheet as PDF: a save panel with the layout and paper, and
    /// no print panel.
    @objc func exportCueSheet(_ sender: Any?) {
        guard let window = console?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(sheetTitle) cue sheet.pdf"
        let layout = NSPopUpButton(frame: .zero, pullsDown: false)
        layout.addItems(withTitles: CueSheet.Layout.allCases.map(\.name))
        let paper = NSPopUpButton(frame: .zero, pullsDown: false)
        paper.addItems(withTitles: ["A4", "US Letter"])
        // Start from whichever the Mac's printing defaults to.
        paper.selectItem(at: abs(NSPrintInfo.shared.paperSize.width - CueSheetView.letter.width) < 1 ? 1 : 0)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Layout:"), layout], [NSTextField(labelWithString: "Paper:"), paper]])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 80))
        grid.frame = accessory.bounds.insetBy(dx: 20, dy: 12)
        accessory.addSubview(grid)
        panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let chosen = CueSheet.Layout.allCases[layout.indexOfSelectedItem]
                let size = paper.indexOfSelectedItem == 1 ? CueSheetView.letter : CueSheetView.a4
                let ok = CueSheetPrinting.exportPDF(for: self.show, title: self.sheetTitle, layout: chosen, paper: size, to: url)
                self.controller?.say(ok ? "Saved the cue sheet as \(url.lastPathComponent)." : "The cue sheet couldn\u{2019}t be saved.")
            }
        }
    }

    // MARK: Menus

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let editing = controller?.mode == .edit
        switch item.action {
        case #selector(save(_:)), #selector(removeUnusedMedia(_:)):
            return editing && super.validateUserInterfaceItem(item)
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
