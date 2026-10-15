import AppKit
import ProspectCore

/// One show open at a time: opening or creating another closes the current
/// one first, asking if its projector is live. A show that won't open is
/// refused untouched, with an offer to restore an earlier version.
///
/// Prospect runs only while a show is open. Closing the console quits, and
/// so does anything else that leaves no show open, such as a show that won't
/// open after the one before it has closed.
final class DocumentController: NSDocumentController {
    var current: ShowDocument? { documents.first as? ShowDocument }

    /// Opens under way. While there is one, having no show is only for a
    /// moment.
    private var opening = 0

    override func newDocument(_ sender: Any?) {
        replaceCurrent { super.newDocument(sender) }
    }

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        if let current, current.fileURL?.standardizedFileURL == url.standardizedFileURL {
            current.showWindows()
            completionHandler(current, true, nil)
            return
        }
        replaceCurrent {
            // The document controller lives as long as the app, so holding
            // it here is fine.
            self.opening += 1
            super.openDocument(withContentsOf: url, display: displayDocument) { document, wasOpen, error in
                MainActor.assumeIsolated {
                    self.opening -= 1
                    guard let error else {
                        completionHandler(document, wasOpen, error)
                        return
                    }
                    self.offerRecovery(for: url, after: error)
                    // Handled here; a cancelled error isn't presented again.
                    completionHandler(nil, false, CocoaError(.userCancelled))
                    self.quitIfNoShow()
                }
            }
        }
    }

    override func removeDocument(_ document: NSDocument) {
        super.removeDocument(document)
        quitIfNoShow()
    }

    /// Checked a moment later, so a show replacing the one that closed has
    /// time to arrive.
    private func quitIfNoShow() {
        DispatchQueue.main.async { [self] in
            guard documents.isEmpty, opening == 0 else { return }
            NSApp.terminate(nil)
        }
    }

    /// Closes the open show, saving it, then carries on. While its projector
    /// is live, asks first, on the console.
    func replaceCurrent(_ then: @escaping () -> Void) {
        guard let current else {
            then()
            return
        }
        let close = {
            current.autosave(withImplicitCancellability: false) { _ in
                MainActor.assumeIsolated {
                    current.close()
                    then()
                }
            }
        }
        guard current.projectorIsOpen, let window = current.console?.window else {
            close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close \u{201C}\(current.displayName ?? "this show")\u{201D} while the projector is live?"
        alert.informativeText = "Only one show is open at a time. Its projector window closes with it."
        alert.addButton(withTitle: "Cancel")
        let closeButton = alert.addButton(withTitle: "Close Show")
        closeButton.hasDestructiveAction = true
        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            MainActor.assumeIsolated { close() }
        }
    }

    // MARK: Recovery

    /// The package is left as it was. If macOS has kept earlier versions of
    /// it, one can be put back; the damaged copy is kept beside it.
    private func offerRecovery(for url: URL, after error: any Error) {
        let name = url.deletingPathExtension().lastPathComponent
        let versions = (NSFileVersion.otherVersionsOfItem(at: url) ?? [])
            .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch error {
        case ShowPackage.ReadError.newerVersion:
            alert.messageText = "\u{201C}\(name)\u{201D} was saved by a newer version of Prospect."
            alert.informativeText = "It hasn\u{2019}t been changed. Open it with the version of Prospect that saved it."
            alert.runModal()
            return
        default:
            alert.messageText = "\u{201C}\(name)\u{201D} can\u{2019}t be opened: its cue sheet is damaged."
        }
        guard !versions.isEmpty else {
            alert.informativeText = "It hasn\u{2019}t been changed. There are no earlier versions of it on this Mac, so restore it from a backup."
            alert.runModal()
            return
        }
        alert.informativeText = "It hasn\u{2019}t been changed. macOS kept earlier versions while it was being edited; restoring one keeps the damaged copy beside it."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        for version in versions {
            picker.addItem(withTitle: version.modificationDate.map(formatter.string(from:)) ?? "Unknown date")
        }
        alert.accessoryView = picker
        alert.addButton(withTitle: "Restore This Version")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let version = versions[picker.indexOfSelectedItem]
        do {
            let damaged = url.deletingLastPathComponent()
                .appendingPathComponent("\(name) (damaged).\(url.pathExtension)")
            try? FileManager.default.removeItem(at: damaged)
            try FileManager.default.copyItem(at: url, to: damaged)
            try version.replaceItem(at: url, options: [])
            openDocument(withContentsOf: url, display: true) { _, _, _ in }
        } catch {
            let failed = NSAlert(error: error)
            failed.runModal()
        }
    }
}
