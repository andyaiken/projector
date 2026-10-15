import AppKit
import ProspectStage

/// Prospect's settings. Almost nothing belongs here: everything that varies
/// by production is in the show document, so it travels with the show. What
/// is left belongs to the Mac.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let reopen = NSButton(checkboxWithTitle: "Reopen the last show when Prospect starts", target: nil, action: nil)
    private let missing = NSPopUpButton(frame: .zero, pullsDown: false)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isRestorable = false
        super.init(window: window)

        reopen.target = self
        reopen.action = #selector(reopenToggled)
        let reopenNote = Self.note("So the first thing to do on the night is press GO, not find a file.")

        missing.addItems(withTitles: [
            "Open the projector in a window on the console\u{2019}s display",
            "Use another connected display until it returns",
        ])
        missing.target = self
        missing.action = #selector(missingChosen)
        let missingLabel = NSTextField(labelWithString: "When a show\u{2019}s projector display isn\u{2019}t connected:")
        let missingNote = Self.note("Either way, the projector moves to the show\u{2019}s display as soon as it is connected.")

        let footer = Self.note("These belong to this Mac. Everything else is kept with the show.")

        let stack = NSStackView(views: [reopen, reopenNote, missingLabel, missing, missingNote, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(18, after: reopenNote)
        stack.setCustomSpacing(18, after: missingNote)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        // Wide enough for the longest choice and note with room to spare,
        // fixed so the wrapping notes don't decide the width.
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        window.contentView = stack
        window.setContentSize(NSSize(width: Self.width, height: stack.fittingSize.height))
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static let width: CGFloat = 560

    private static func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = width - 48
        return field
    }

    func refresh() {
        let defaults = UserDefaults.standard
        reopen.state = defaults.bool(forKey: Preferences.reopenLastShow) ? .on : .off
        let choice = MissingDisplay(rawValue: defaults.string(forKey: Preferences.missingDisplay) ?? "") ?? .window
        missing.selectItem(at: choice == .window ? 0 : 1)
    }

    @objc private func reopenToggled() {
        UserDefaults.standard.set(reopen.state == .on, forKey: Preferences.reopenLastShow)
    }

    @objc private func missingChosen() {
        let choice: MissingDisplay = missing.indexOfSelectedItem == 0 ? .window : .anotherDisplay
        UserDefaults.standard.set(choice.rawValue, forKey: Preferences.missingDisplay)
    }
}
