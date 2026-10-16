import AppKit
import ProspectCore
import ProspectStage

/// Edit mode's cue editor. It edits the cue standing by: click a cue in the
/// list to edit it. Every change goes through the show controller as one
/// undoable edit.
final class CueEditorPanel: PanelView, NSTextFieldDelegate {
    weak var controller: ShowController?
    var importMedia: (URL, UUID) -> Void = { _, _ in }
    var chooseMedia: (UUID) -> Void = { _ in }
    /// Return or Escape in a field gives the keyboard back to the show keys.
    var finishedEditing: () -> Void = {}

    private(set) var cue: Cue?

    private let heading = Desk.label("", font: Desk.sans(12.5, .semibold), colour: Desk.text)
    private let empty = Desk.label("Nothing is standing by. Add a cue with Add Cue at the top, or click one in the list to edit it.",
                                   font: Desk.sans(12.5), colour: Desk.dim, wraps: true)

    private let numberLabel = Desk.label("Number", font: Desk.sans(12.5), colour: Desk.dim)
    private let number = CueEditorPanel.field(mono: true)
    private let lineLabel = Desk.label("Cue point", font: Desk.sans(12.5), colour: Desk.dim)
    private let line = CueEditorPanel.field(placeholder: "The line or action to wait for")
    private let continueLabel = Desk.label("Continue", font: Desk.sans(12.5), colour: Desk.dim)
    private let continueMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let continueSeconds = CueEditorPanel.field(mono: true)
    private let secondsLabel = Desk.label("seconds", font: Desk.sans(12.5), colour: Desk.dim)

    private let textLabel = Desk.label("", font: Desk.sans(12.5), colour: Desk.dim)
    private let text = CueEditorPanel.field(mono: true)
    private let subLabel = Desk.label("", font: Desk.sans(12.5), colour: Desk.dim)
    private let sub = CueEditorPanel.field(mono: true)
    private let keyLabel = Desk.label("Key", font: Desk.sans(12.5), colour: Desk.dim)
    private let key = CueEditorPanel.field(mono: true)

    private let mediaLabel = Desk.label("", font: Desk.sans(12.5), colour: Desk.dim)
    private let well = MediaWell()
    private let choose = CueEditorPanel.button("Choose\u{2026}")
    private let removeMedia = CueEditorPanel.button("Remove")
    private let atEndLabel = Desk.label("At the end", font: Desk.sans(12.5), colour: Desk.dim)
    private let atEnd = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colourLabel = Desk.label("Colour", font: Desk.sans(12.5), colour: Desk.dim)
    private let colour = NSColorWell(style: .default)

    init() {
        super.init(border: Desk.line, radius: 4)
        for field in [number, line, text, sub, key, continueSeconds] { field.delegate = self }
        // Tab goes down what the cue shows, then where it comes in the book,
        // and round again. AppKit skips hidden fields, so one chain serves
        // every kind of cue.
        let order = [text, sub, key, number, line, continueSeconds]
        for (field, next) in zip(order, order.dropFirst() + [order[0]]) { field.nextKeyView = next }
        for (button, action) in [(choose, #selector(choosePressed)), (removeMedia, #selector(removePressed))] {
            button.target = self
            button.action = action
        }
        continueMode.addItems(withTitles: ["When cued", "After", "When finished, after"])
        // When finished is offered only to a cue that takes time.
        continueMode.autoenablesItems = false
        continueMode.target = self
        continueMode.action = #selector(continueChosen)
        continueMode.refusesFirstResponder = true
        continueMode.toolTip = "When the show moves on to the next cue: on GO, a number of seconds after this cue fires, or a number of seconds after it finishes"
        continueSeconds.alignment = .right
        atEnd.addItems(withTitles: ["Hold the last frame", "Cut to black", "Loop"])
        atEnd.target = self
        atEnd.action = #selector(atEndChosen)
        atEnd.refusesFirstResponder = true
        colour.target = self
        colour.action = #selector(colourChosen)
        well.onDrop = { [weak self] url in
            guard let self, let cue else { return }
            importMedia(url, cue.id)
        }
        let views: [NSView] = [heading, empty, numberLabel, number, lineLabel, line,
                               continueLabel, continueMode, continueSeconds, secondsLabel,
                               textLabel, text, subLabel, sub, keyLabel, key, mediaLabel, well, choose, removeMedia,
                               atEndLabel, atEnd, colourLabel, colour]
        views.forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Dim and italic, plainly a hint, so an empty field never passes for a
    /// filled one.
    private static func hint(_ field: NSTextField, _ text: String) {
        field.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .foregroundColor: Desk.dim.withAlphaComponent(0.7),
            .font: NSFontManager.shared.convert(field.font ?? Desk.sans(12.5), toHaveTrait: .italicFontMask),
        ])
    }

    private static func field(mono: Bool = false, placeholder: String? = nil) -> NSTextField {
        let field = NSTextField(string: "")
        field.font = mono ? Desk.mono(12.5) : Desk.sans(12.5)
        field.bezelStyle = .roundedBezel
        if let placeholder { hint(field, placeholder) }
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        // Only whole edits go on the undo stack, not keystrokes.
        field.cell?.allowsUndo = false
        return field
    }

    private static func button(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Desk.sans(11.5)
        button.refusesFirstResponder = true
        return button
    }

    // MARK: Showing a cue

    func update(cue: Cue?) {
        self.cue = cue
        let kind = cue?.kind
        empty.isHidden = cue != nil
        for view in [numberLabel, number, lineLabel, line, continueLabel, continueMode, textLabel, text] as [NSView] {
            view.isHidden = cue == nil
        }
        subLabel.isHidden = kind == nil || kind == .blank || kind == .image
        sub.isHidden = subLabel.isHidden
        keyLabel.isHidden = kind != .title
        key.isHidden = keyLabel.isHidden
        for view in [mediaLabel, well, choose, removeMedia] as [NSView] { view.isHidden = kind != .image && kind != .video }
        atEndLabel.isHidden = kind != .video
        atEnd.isHidden = atEndLabel.isHidden
        colourLabel.isHidden = kind != .blank
        colour.isHidden = colourLabel.isHidden
        // Seconds after firing, or after finishing; none for when cued.
        continueSeconds.isHidden = !(cue?.continueMode.continues ?? false)
        secondsLabel.isHidden = continueSeconds.isHidden
        guard let cue else {
            heading.stringValue = "Cue"
            needsLayout = true
            return
        }

        heading.stringValue = "Cue \(cue.number.isEmpty ? "(no number)" : cue.number) \u{2014} \(cue.kind.name)"
        set(number, cue.number)
        set(line, cue.line)
        var continuesWhenFinished = false
        switch cue.continueMode {
        case .whenCued: continueMode.selectItem(at: 0)
        case .after(let ms):
            continueMode.selectItem(at: 1)
            set(continueSeconds, ContinueMode.seconds(ms))
        case .whenFinished(let ms):
            continueMode.selectItem(at: 2)
            set(continueSeconds, ContinueMode.seconds(ms))
            continuesWhenFinished = true
        }
        continueMode.item(at: 2)?.isEnabled = cue.finishes || continuesWhenFinished
        set(text, cue.text)
        set(sub, cue.sub)
        switch cue.content {
        case .title(let c):
            textLabel.stringValue = "Text"
            subLabel.stringValue = "Subtext"
            set(key, c.key)
        case .anagram:
            textLabel.stringValue = "Phrase"
            subLabel.stringValue = "Answer"
        case .image(let c):
            textLabel.stringValue = "Label"
            mediaLabel.stringValue = "Picture"
            well.show(path: c.src, kind: .image, empty: "No picture \u{2014} drop one here")
            removeMedia.isEnabled = !c.src.isEmpty
        case .video(let c):
            textLabel.stringValue = "Label"
            subLabel.stringValue = "Caption"
            mediaLabel.stringValue = "Clip"
            well.show(path: c.src, kind: .video, empty: "No clip \u{2014} drop one here")
            removeMedia.isEnabled = !c.src.isEmpty
            atEnd.selectItem(at: VideoEnd.allCases.firstIndex(of: c.atEnd) ?? 0)
        case .blank(let c):
            textLabel.stringValue = "Label"
            colour.color = NSColor(srgbRed: CGFloat(c.colour.r) / 255, green: CGFloat(c.colour.g) / 255, blue: CGFloat(c.colour.b) / 255, alpha: 1)
        }
        needsLayout = true
    }

    /// Doesn't touch a field while someone is typing in it.
    private func set(_ field: NSTextField, _ value: String) {
        if field.currentEditor() == nil, field.stringValue != value { field.stringValue = value }
    }

    // MARK: Editing

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let cue, let controller else { return }
        let value = field.stringValue
        switch field {
        case number:
            controller.updateCue(cue.id, "Change Cue Number") { $0.number = value.trimmingCharacters(in: .whitespaces) }
        case line:
            controller.updateCue(cue.id, "Change Cue Point") { $0.line = value }
        case text:
            let name = switch cue.kind {
            case .title: "Change Text"
            case .anagram: "Change Phrase"
            default: "Change Label"
            }
            controller.updateCue(cue.id, name) { $0.text = value }
        case sub:
            let name = switch cue.kind {
            case .title: "Change Subtext"
            case .anagram: "Change Answer"
            default: "Change Caption"
            }
            controller.updateCue(cue.id, name) { $0.sub = value }
        case key:
            controller.updateCue(cue.id, "Change Key") { cue in
                if case .title(var c) = cue.content { c.key = value; cue.content = .title(c) }
            }
        case continueSeconds:
            // To a tenth of a second, up to an hour. Anything unreadable is
            // put back as it was.
            guard let seconds = Double(value.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)),
                  seconds.isFinite else {
                update(cue: cue)
                return
            }
            let ms = min(max(0, Int((seconds * 10).rounded()) * 100), ContinueMode.longest)
            controller.updateCue(cue.id, "Change Continue Wait") { cue in
                switch cue.continueMode {
                case .whenFinished: cue.continueMode = .whenFinished(waitMs: ms)
                default: cue.continueMode = .after(ms: ms)
                }
            }
        default:
            break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finishedEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Put the field back as it was, then leave it.
            if let field = control as? NSTextField { field.abortEditing() }
            update(cue: cue)
            finishedEditing()
            return true
        default:
            return false
        }
    }

    /// A wait after firing starts at five seconds, a wait after finishing
    /// at none; choosing the one already set changes nothing.
    @objc private func continueChosen() {
        guard let cue else { return }
        let mode: ContinueMode
        switch (continueMode.indexOfSelectedItem, cue.continueMode) {
        case (1, .after), (2, .whenFinished), (0, .whenCued): return
        case (1, _): mode = .after(ms: 5000)
        case (2, _): mode = .whenFinished(waitMs: 0)
        default: mode = .whenCued
        }
        controller?.updateCue(cue.id, "Change Continue") { $0.continueMode = mode }
    }

    @objc private func atEndChosen() {
        guard let cue else { return }
        let end = VideoEnd.allCases[atEnd.indexOfSelectedItem]
        controller?.updateCue(cue.id, "Change End Behaviour") { cue in
            if case .video(var c) = cue.content { c.atEnd = end; cue.content = .video(c) }
        }
    }

    @objc private func colourChosen() {
        guard let cue, let srgb = colour.color.usingColorSpace(.sRGB) else { return }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(clamping: Int((v * 255).rounded())) }
        let rgb = RGB(byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
        controller?.updateCue(cue.id, "Change Colour") { cue in
            if case .blank(var c) = cue.content { c.colour = rgb; cue.content = .blank(c) }
        }
    }

    @objc private func choosePressed() { if let cue { chooseMedia(cue.id) } }

    /// Leaves the file in the show, where an undo expects it.
    @objc private func removePressed() {
        guard let cue else { return }
        controller?.updateCue(cue.id, cue.kind == .video ? "Remove Clip" : "Remove Picture") { cue in
            switch cue.content {
            case .image(var c): c.src = ""; cue.content = .image(c)
            case .video(var c): c.src = ""; cue.content = .video(c)
            default: break
            }
        }
    }

    #if DEBUG
    /// The fields Tab visits from the first, in order, for checking the
    /// key view loop without a keyboard.
    var tabStops: [String] {
        let names: [NSView: String] = [text: "text", sub: "sub", key: "key", number: "number", line: "line", continueSeconds: "seconds"]
        var stops = [names[text] ?? "?"]
        var view: NSView? = text.nextValidKeyView
        while let v = view, v !== text, stops.count < 10 {
            stops.append(names[v] ?? "?")
            view = v.nextValidKeyView
        }
        return stops
    }
    #endif

    // MARK: Layout

    /// The header and the taller column: a video cue's four rows.
    var preferredHeight: CGFloat { 15 + 36 + 4 * 32 + 15 }

    override func layout() {
        super.layout()
        let x: CGFloat = 16, inner = bounds.width - 32, labelWidth: CGFloat = 76
        var y: CGFloat = 15
        heading.frame = NSRect(x: x, y: y + 3, width: inner, height: 18)
        y += 36
        empty.frame = NSRect(x: x, y: y, width: inner, height: 40)

        let gap: CGFloat = 24
        let leftWidth = ((inner - gap) * 0.55).rounded()
        let rightX = x + leftWidth + gap, rightWidth = inner - leftWidth - gap
        func row(_ label: NSTextField, _ control: NSView, x rowX: CGFloat, y rowY: CGFloat, width: CGFloat, controlWidth: CGFloat? = nil) {
            label.frame = NSRect(x: rowX, y: rowY + 3, width: labelWidth - 6, height: 18)
            control.frame = NSRect(x: rowX + labelWidth, y: rowY, width: controlWidth ?? width - labelWidth, height: 24)
        }

        // Left: what the cue shows.
        var ly = y
        func left(_ label: NSTextField, _ control: NSView, controlWidth: CGFloat? = nil) {
            row(label, control, x: x, y: ly, width: leftWidth, controlWidth: controlWidth)
            ly += 32
        }
        left(textLabel, text)
        if !sub.isHidden { left(subLabel, sub) }
        if !key.isHidden { left(keyLabel, key) }
        if !well.isHidden {
            mediaLabel.frame = NSRect(x: x, y: ly + 3, width: labelWidth - 6, height: 18)
            let buttons = choose.fittingSize.width + removeMedia.fittingSize.width + 12
            well.frame = NSRect(x: x + labelWidth, y: ly, width: leftWidth - labelWidth - buttons - 8, height: 24)
            choose.frame = NSRect(x: well.frame.maxX + 8, y: ly, width: choose.fittingSize.width, height: 24)
            removeMedia.frame = NSRect(x: choose.frame.maxX + 4, y: ly, width: removeMedia.fittingSize.width, height: 24)
            ly += 32
        }
        if !atEnd.isHidden { left(atEndLabel, atEnd, controlWidth: min(220, leftWidth - labelWidth)) }
        if !colour.isHidden { left(colourLabel, colour, controlWidth: 60) }

        // Right: where it comes in the book.
        row(numberLabel, number, x: rightX, y: y, width: rightWidth, controlWidth: min(140, rightWidth - labelWidth))
        row(lineLabel, line, x: rightX, y: y + 32, width: rightWidth)
        let continueY = y + 64
        continueLabel.frame = NSRect(x: rightX, y: continueY + 3, width: labelWidth - 6, height: 18)
        let popupWidth = max(110, min(170, rightWidth - labelWidth - 124))
        continueMode.frame = NSRect(x: rightX + labelWidth, y: continueY, width: popupWidth, height: 24)
        continueSeconds.frame = NSRect(x: continueMode.frame.maxX + 8, y: continueY, width: 56, height: 24)
        secondsLabel.frame = NSRect(x: continueSeconds.frame.maxX + 6, y: continueY + 3, width: 70, height: 18)
    }
}

/// Where a picture or clip is dropped: shows the file a cue has, and takes
/// a new one from Finder.
final class MediaWell: NSView {
    var onDrop: (URL) -> Void = { _ in }
    private var kind = Cue.Kind.image
    private var text = ""
    private var hasFile = false
    private var targeted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(path: String, kind: Cue.Kind, empty: String) {
        self.kind = kind
        hasFile = !path.isEmpty
        text = hasFile ? (path as NSString).lastPathComponent : empty
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        (targeted ? Desk.raised : Desk.sunk).setFill()
        path.fill()
        (targeted ? Desk.brass : Desk.lineBright).setStroke()
        path.setLineDash([3, 3], count: 2, phase: 0)
        path.stroke()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let attributed = NSAttributedString(string: text, attributes: [
            .font: hasFile ? Desk.mono(12) : Desk.sans(12), .foregroundColor: hasFile ? Desk.text : Desk.dim, .paragraphStyle: style,
        ])
        let size = attributed.size()
        attributed.draw(in: NSRect(x: 10, y: (bounds.height - size.height) / 2, width: bounds.width - 20, height: size.height))
    }

    private func droppedURL(_ info: any NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let url = urls?.first, ShowDocument.accepts(url, for: kind) else { return nil }
        return url
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        targeted = droppedURL(sender) != nil
        return targeted ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        targeted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        targeted = false
        guard let url = droppedURL(sender) else { return false }
        onDrop(url)
        return true
    }
}
