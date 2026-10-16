import AppKit
import ProspectCore
import ProspectStage

/// The desk palette, for everything around the stage.
enum Desk {
    static let colour = rgb(0x14, 0x16, 0x1B)
    static let raised = rgb(0x1B, 0x1E, 0x25)
    static let sunk = rgb(0x0C, 0x0E, 0x12)
    static let line = rgb(0x27, 0x2C, 0x35)
    static let lineBright = rgb(0x3A, 0x41, 0x4E)
    static let text = rgb(0xCF, 0xD4, 0xDE)
    static let dim = rgb(0x76, 0x7E, 0x8D)
    static let brass = rgb(0xC8, 0xA2, 0x4A)
    static let live = rgb(0x6F, 0xB5, 0x8A)

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    @MainActor
    static func label(_ text: String = "", font: NSFont = sans(12.5), colour: NSColor = Desk.text, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = font
        field.textColor = colour
        field.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        return field
    }

    /// The height a label needs at a width.
    @MainActor
    static func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        guard !field.stringValue.isEmpty else { return 0 }
        return ceil(field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height)
    }
}

/// A plain view with a fill, and optionally a border.
class PanelView: NSView {
    init(fill: NSColor? = nil, border: NSColor? = nil, radius: CGFloat = 0) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill?.cgColor
        layer?.borderColor = border?.cgColor
        layer?.borderWidth = border == nil ? 0 : 1
        layer?.cornerRadius = radius
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
}

// MARK: - Header

/// GO. Brass, and the biggest thing in the window. It never takes keyboard
/// focus, so Space can't press it as well as firing through the show keys.
final class GoButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = "GO"
        refusesFirstResponder = true
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        if isEnabled {
            (isHighlighted ? Desk.rgb(0xD6, 0xB0, 0x58) : Desk.brass).setFill()
            path.fill()
        } else {
            Desk.line.setStroke()
            path.stroke()
        }
        let text = NSAttributedString(string: "GO", attributes: [
            .font: Desk.sans(14, .semibold),
            .foregroundColor: isEnabled ? Desk.rgb(0x15, 0x12, 0x0B) : Desk.dim,
            .kern: 2.2,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2 + 1.1, y: (bounds.height - size.height) / 2))
    }
}

/// Show or edit: two segments in the desk's own colours, with whichever is
/// on in brass. Clicked, never keyed: it doesn't take the keyboard, so Space
/// can't flip it.
final class ModeSwitch: NSControl {
    var isEditing = false {
        didSet { if isEditing != oldValue { needsDisplay = true } }
    }

    private static let labels = ["SHOW", "EDIT"]
    private static let font = Desk.sans(10.5, .semibold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        refusesFirstResponder = true
        focusRingType = .none
        toolTip = "Show mode locks the cue sheet; edit mode unlocks it"
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Mode")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 104, height: 22) }
    override var fittingSize: NSSize { intrinsicContentSize }

    override func mouseDown(with event: NSEvent) {
        let editing = convert(event.locationInWindow, from: nil).x >= bounds.midX
        guard editing != isEditing else { return }
        isEditing = editing
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        Desk.sunk.setFill()
        outline.fill()
        Desk.line.setStroke()
        outline.stroke()

        let half = box.width / 2
        let selected = NSRect(x: box.minX + (isEditing ? half : 0), y: box.minY, width: half, height: box.height).insetBy(dx: 2, dy: 2)
        Desk.brass.setFill()
        NSBezierPath(roundedRect: selected, xRadius: 3, yRadius: 3).fill()

        for (i, label) in Self.labels.enumerated() {
            let on = (i == 1) == isEditing
            let colour = on ? Desk.rgb(0x15, 0x12, 0x0B) : Desk.dim
            let text = NSAttributedString(string: label, attributes: [.font: Self.font, .foregroundColor: colour, .kern: 0.8])
            let size = text.size()
            text.draw(at: NSPoint(x: box.minX + CGFloat(i) * half + (half - size.width) / 2 + 0.4, y: (bounds.height - size.height) / 2))
        }
    }
}

final class HeaderView: PanelView {
    let wordmark = Desk.label("Prospect", font: Desk.mono(14), colour: Desk.text)
    /// Show or edit, chosen here or from the Show menu. Never by a key: a
    /// key that unlocked the sheet mid-performance would be a liability.
    let mode = ModeSwitch(frame: .zero)
    /// Edit mode only: a new cue of any kind, after the one standing by.
    let addCue = NSPopUpButton(frame: .zero, pullsDown: true)
    let lampDot = PanelView(radius: 3.5)
    let lamp = Desk.label("", font: Desk.sans(12.5), colour: Desk.dim)
    let openProjector = NSButton(title: "Open Projector", target: nil, action: nil)
    let separator = PanelView(fill: Desk.line)
    let go = GoButton(frame: .zero)

    init() {
        super.init(fill: Desk.raised)
        wordmark.attributedStringValue = Self.wordmarkText(Self.name.map { ($0, 1) })
        wordmark.setAccessibilityLabel(Self.name)
        openProjector.bezelStyle = .rounded
        openProjector.refusesFirstResponder = true
        // A pull-down's first item is its title; the kinds follow.
        addCue.addItems(withTitles: ["Add Cue"] + Cue.Kind.allCases.map(\.heading))
        addCue.controlSize = .small
        addCue.font = Desk.sans(11.5)
        addCue.refusesFirstResponder = true
        addCue.toolTip = "Adds a cue after the one standing by"
        for view in [wordmark, mode, addCue, lampDot, lamp, openProjector, separator, go] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(mode editing: Bool, lamp text: String, live: Bool, warn: Bool, projectorOpen: Bool, goEnabled: Bool, goTip: String) {
        mode.isEditing = editing
        addCue.isHidden = !editing
        lamp.stringValue = text
        lamp.textColor = live ? Desk.live : (warn ? Desk.brass : Desk.dim)
        lampDot.layer?.backgroundColor = (live ? Desk.live : (warn ? Desk.brass : Desk.lineBright)).cgColor
        lampDot.layer?.shadowColor = Desk.live.cgColor
        lampDot.layer?.shadowOpacity = live ? 0.9 : 0
        lampDot.layer?.shadowRadius = 3.5
        lampDot.layer?.shadowOffset = .zero
        openProjector.isHidden = projectorOpen
        go.isEnabled = goEnabled
        go.toolTip = goTip
        go.needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        func centre(_ v: NSView, x: CGFloat, width: CGFloat? = nil) {
            let size = v.fittingSize
            v.frame = NSRect(x: x, y: ((h - size.height) / 2).rounded(), width: width ?? size.width, height: size.height)
        }
        centre(wordmark, x: 16)
        centre(mode, x: wordmark.frame.maxX + 16)
        if !addCue.isHidden { centre(addCue, x: mode.frame.maxX + 12) }

        go.frame = NSRect(x: bounds.width - 16 - 104, y: (h - 36) / 2, width: 104, height: 36)
        separator.frame = NSRect(x: go.frame.minX - 15, y: (h - 26) / 2, width: 1, height: 26)
        var right = separator.frame.minX - 14
        if !openProjector.isHidden {
            let width = openProjector.fittingSize.width
            centre(openProjector, x: right - width)
            right = openProjector.frame.minX - 14
        }
        let lampWidth = lamp.fittingSize.width
        centre(lamp, x: right - lampWidth)
        lampDot.frame = NSRect(x: lamp.frame.minX - 14, y: (h - 7) / 2, width: 7, height: 7)
    }

    // MARK: The wordmark

    private static let name = "PROSPECT"
    /// Frames of ciphertext before any letter moves, and how long a frame is.
    private static let hold = 20
    private static let frameSeconds: TimeInterval = 0.05

    private var reveal: TravelPlan?
    private var revealFrame = 0
    private var revealRandom = SystemUnitRandom()
    private var revealTimer: Timer?

    /// Decrypts the wordmark the way a title cue decrypts on stage: a moment
    /// of ciphertext, then each letter cycling home, warming as it goes.
    /// Not at all under reduced motion.
    func decryptWordmark() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        startReveal(at: -Self.hold)
        let timer = Timer(timeInterval: Self.frameSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showReveal(at: (self?.revealFrame ?? 0) + 1) }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private func startReveal(at frame: Int) {
        revealTimer?.invalidate()
        revealTimer = nil
        // The key never shows, on stage or here. Its shifts, 5, 8, 1, 13, 13,
        // 0, 2, 2, 8, are mostly Fibonacci numbers, for anyone who looks.
        reveal = TravelPlan(text: Self.name, key: "FIBONACCI", wave: 3, random: &revealRandom)
        showReveal(at: frame)
    }

    /// Frames up to 0 are the ciphertext; from the plan's duration on, the
    /// name itself, and the reveal is over.
    private func showReveal(at frame: Int) {
        guard let plan = reveal else { return }
        revealFrame = frame
        wordmark.attributedStringValue = Self.wordmarkText(plan.frame(max(0, frame), random: &revealRandom).map { ($0.glyph, $0.progress) })
        if frame >= plan.duration {
            revealTimer?.invalidate()
            revealTimer = nil
            reveal = nil
        }
    }

    /// The glyphs in the wordmark's own case, each coloured by how far home
    /// it is: from the ciphertext's slate to the desk's text colour, eased as
    /// the stage's warming is.
    private static func wordmarkText(_ glyphs: [(glyph: Character, progress: Double)]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (glyph, letter) in zip(glyphs, name) {
            let p = min(max(glyph.progress, 0), 1), e = p * p * (3 - 2 * p)
            func mix(_ cold: UInt8, _ warm: Int) -> Int { Int((Double(cold) + (Double(warm) - Double(cold)) * e).rounded()) }
            let colour = Desk.rgb(mix(Palette.slate.r, 0xCF), mix(Palette.slate.g, 0xD4), mix(Palette.slate.b, 0xDE))
            let shown = letter.isLowercase ? String(glyph.glyph).lowercased() : String(glyph.glyph)
            text.append(NSAttributedString(string: shown, attributes: [.font: Desk.mono(14), .foregroundColor: colour, .kern: 1.4]))
        }
        return text
    }

    #if DEBUG
    /// The wordmark held on one frame of a fresh reveal, for snapshots.
    func holdWordmark(atFrame frame: Int) {
        startReveal(at: frame)
    }
    #endif
}

// MARK: - Standby

/// What GO fires next, large; what is on screen, small.
final class StandbyPanel: PanelView {
    private let standingBy = Desk.label("Standing by", font: Desk.sans(11.5), colour: Desk.dim)
    private let number = Desk.label("\u{2014}", font: Desk.mono(30), colour: Desk.brass)
    private let name = Desk.label("\u{2014}", font: Desk.mono(13), colour: Desk.text)
    private let arm = Desk.label("", font: Desk.sans(11.5, .medium), colour: Desk.dim)
    private let cuePointBox = PanelView(fill: Desk.raised)
    private let cuePointBar = PanelView(fill: Desk.brass)
    private let cuePoint = Desk.label("", font: Desk.sans(13), colour: Desk.text, wraps: true)
    private let divider = PanelView(fill: Desk.line)
    private let onScreen = Desk.label("On screen", font: Desk.sans(11.5), colour: Desk.dim)
    private let liveNumber = Desk.label("\u{2014}", font: Desk.mono(17), colour: Desk.dim)
    private let liveName = Desk.label("\u{2014}", font: Desk.mono(12), colour: Desk.dim)

    init() {
        super.init(fill: Desk.sunk)
        name.alignment = .right
        liveName.alignment = .right
        cuePointBox.addSubview(cuePointBar)
        cuePointBox.addSubview(cuePoint)
        arm.alignment = .right
        for view in [standingBy, number, name, arm, cuePointBox, divider, onScreen, liveNumber, liveName] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// For a video cue standing by: whether it is armed, said plainly.
    func update(standby: Cue?, live: Cue?, entry: String, arm armState: ArmState?) {
        switch armState {
        case .armed:
            arm.stringValue = "Video armed"
            arm.textColor = Desk.live
        case .arming:
            arm.stringValue = "Video loading \u{2014} not armed yet"
            arm.textColor = Desk.brass
        case .failed:
            arm.stringValue = "No clip \u{2014} this cue goes to black"
            arm.textColor = Desk.brass
        case nil:
            arm.stringValue = ""
        }
        if !entry.isEmpty {
            standingBy.stringValue = "Go to \u{2014} Return stands it by, Escape clears"
            number.stringValue = entry + "\u{2581}"
            name.stringValue = ""
        } else {
            standingBy.stringValue = "Standing by"
            number.stringValue = standby?.number ?? "\u{2014}"
            name.stringValue = standby.map { $0.text.isEmpty ? "\u{2014}" : $0.text } ?? "end of sheet"
        }
        let line = standby?.line.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cuePoint.stringValue = !line.isEmpty ? line : (standby == nil ? "Nothing to stand by for" : "No cue point set")
        cuePoint.textColor = line.isEmpty ? Desk.dim : Desk.text
        cuePoint.font = line.isEmpty ? NSFontManager.shared.convert(Desk.sans(13), toHaveTrait: .italicFontMask) : Desk.sans(13)
        cuePointBar.layer?.backgroundColor = (line.isEmpty ? Desk.line : Desk.brass).cgColor
        liveNumber.stringValue = live?.number ?? "\u{2014}"
        liveName.stringValue = live?.text ?? "\u{2014}"
        needsLayout = true
    }

    /// The height the panel needs at a width.
    func height(width: CGFloat) -> CGFloat {
        let inner = width - 32
        return 15 + 16 + 2 + 36 + 10 + (arm.stringValue.isEmpty ? 0 : 18)
            + (Desk.height(of: cuePoint, width: inner - 22) + 18) + 12 + 1 + 12 + 16 + 2 + 22 + 15
    }

    override func layout() {
        super.layout()
        let x: CGFloat = 16, inner = bounds.width - 32
        var y: CGFloat = 15
        standingBy.frame = NSRect(x: x, y: y, width: inner, height: 16); y += 18
        number.frame = NSRect(x: x, y: y, width: inner * 0.5, height: 36)
        name.frame = NSRect(x: x + inner * 0.35, y: y + 14, width: inner * 0.65, height: 18); y += 46
        arm.isHidden = arm.stringValue.isEmpty
        if !arm.isHidden {
            arm.frame = NSRect(x: x, y: y - 6, width: inner, height: 16)
            y += 18
        }
        let textHeight = Desk.height(of: cuePoint, width: inner - 22)
        cuePointBox.frame = NSRect(x: x, y: y, width: inner, height: textHeight + 18)
        cuePointBar.frame = NSRect(x: 0, y: 0, width: 2, height: textHeight + 18)
        cuePoint.frame = NSRect(x: 11, y: 9, width: inner - 22, height: textHeight); y += textHeight + 18 + 12
        divider.frame = NSRect(x: x, y: y, width: inner, height: 1); y += 13
        onScreen.frame = NSRect(x: x, y: y, width: inner, height: 16); y += 18
        liveNumber.frame = NSRect(x: x, y: y, width: inner * 0.4, height: 22)
        liveName.frame = NSRect(x: x + inner * 0.3, y: y + 4, width: inner * 0.7, height: 16)
    }
}

// MARK: - Cue list

/// One row: number, a glyph for the kind, the name, and beneath it the
/// subtitle and the cue point. The live cue sits on a raised background; the
/// standby cue has a brass number and a brass bar. A transition in that isn't
/// the show's default is noted in brass along the top, between this cue and
/// the one before.
final class CueRowView: NSView {
    let cue: Cue
    let transitionNote: String?
    var isStandby = false { didSet { if isStandby != oldValue { needsDisplay = true } } }
    var isLive = false { didSet { if isLive != oldValue { needsDisplay = true } } }
    var hasIssue = false
    /// In edit mode, a picture or clip dropped on an image or video row goes
    /// to that cue.
    var acceptsMedia = false
    /// Edit mode: a delete button and a grip to drag the row by, at the right.
    var isEditing = false {
        didSet {
            guard isEditing != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Dimmed while it's being dragged to a new place.
    var isLifted = false { didSet { alphaValue = isLifted ? 0.45 : 1 } }
    private var targeted = false { didSet { needsDisplay = true } }
    var onClick: (UUID) -> Void = { _ in }
    var onDrop: (URL, UUID) -> Void = { _, _ in }
    var onDelete: (UUID) -> Void = { _ in }
    /// The grip was pressed: the list takes the drag from here.
    var onGrip: (CueRowView, NSEvent) -> Void = { _, _ in }

    init(cue: Cue, transitionNote: String? = nil) {
        self.cue = cue
        self.transitionNote = transitionNote
        super.init(frame: .zero)
        let continues = cue.continueMode.continues ? "Continues " + cue.continueMode.summary : nil
        toolTip = [cue.line.isEmpty ? nil : cue.line, continues].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
        if cue.kind == .image || cue.kind == .video { registerForDraggedTypes([.fileURL]) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// At the right of the row, for a cue that moves on by itself: a down
    /// arrow if it continues when finished, whatever the wait after, or the
    /// moment it fires; a clock if it continues a while after it fires.
    static func continueSymbol(_ mode: ContinueMode) -> String? {
        switch mode {
        case .whenCued: nil
        case .whenFinished, .after(0): "arrow.down"
        case .after: "clock"
        }
    }

    static func kindGlyph(_ kind: Cue.Kind) -> String {
        switch kind {
        case .title: "\u{2261}"
        case .image: "\u{25A6}"
        case .video: "\u{25B6}"
        case .blank: "\u{25A1}"
        }
    }

    var subtitle: String {
        switch cue.content {
        case .title(let c): c.sub
        case .image(let c): c.src.isEmpty ? "no picture" : ""
        case .video(let c): [c.sub, c.atEnd == .hold ? "" : c.atEnd.rawValue].filter { !$0.isEmpty }.joined(separator: "   ")
        case .blank(let c): c.colour.hex
        }
    }

    /// What the cue list says about a cue's own transition in, if it has one.
    static func transitionNote(for cue: Cue, defaults: ShowSettings) -> String? {
        guard !cue.transition.isEmpty else { return nil }
        let transition = cue.transitionIn(defaults: defaults)
        return transition.style == .snap ? "snap" : "fade " + SettingKey.fade.format(.number(transition.fadeMs))
    }

    private static let noteHeight: CGFloat = 14

    /// The middle of the cue's own lines, below any transition note. The
    /// number and kind on the left, and every mark and control on the right,
    /// centre on it, so they line up however many lines the row has.
    private var middleY: CGFloat { ((transitionNote == nil ? 0 : Self.noteHeight) + bounds.height) / 2 }
    /// The whole height of the row's right edge, so it's easy to take hold of.
    var gripRect: NSRect { NSRect(x: bounds.width - 26, y: 0, width: 26, height: bounds.height) }
    var deleteRect: NSRect { NSRect(x: bounds.width - 48, y: middleY - 11, width: 22, height: 22) }
    /// A mark's place at the right, centred on the middle.
    private func markRect(x: CGFloat) -> NSRect { NSRect(x: x, y: middleY - 8, width: 14, height: 16) }
    /// The room the edit-mode controls take at the right.
    private var controlsWidth: CGFloat { isEditing ? 48 : 0 }

    /// A system symbol, drawn the right way up in this top-down view.
    private func drawSymbol(_ name: String, _ colour: NSColor, centredIn rect: NSRect, size: CGFloat = 11) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))) else { return }
        let s = image.size
        image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func resetCursorRects() {
        if isEditing { addCursorRect(gripRect, cursor: .openHand) }
    }

    var preferredHeight: CGFloat {
        16 + 18 + (subtitle.isEmpty ? 0 : 17) + (cue.line.isEmpty ? 0 : 17) + (transitionNote == nil ? 0 : Self.noteHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        if targeted {
            let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            Desk.raised.setFill()
            path.fill()
            Desk.brass.setStroke()
            path.stroke()
        } else if isLive {
            let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            Desk.raised.setFill()
            path.fill()
            Desk.lineBright.setStroke()
            path.stroke()
        }
        if isStandby {
            Desk.brass.setFill()
            NSRect(x: 0, y: 6, width: 2, height: bounds.height - 12).fill()
        }

        func draw(_ text: String, _ font: NSFont, _ colour: NSColor, x: CGFloat, y: CGFloat, width: CGFloat, align: NSTextAlignment = .left, kern: CGFloat = 0) {
            let style = NSMutableParagraphStyle()
            style.alignment = align
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: colour, .paragraphStyle: style, .kern: kern,
            ]).draw(in: NSRect(x: x, y: y, width: width, height: 18))
        }

        var y: CGFloat = 8
        if let transitionNote {
            draw("\u{2193} " + transitionNote, Desk.sans(10.5), Desk.brass, x: 78, y: 3, width: bounds.width - 88)
            y += Self.noteHeight
        }
        // Text boxes are 18 high, with the glyphs sitting a point low in them.
        let leftY = middleY - 9 - 1
        draw(cue.number, Desk.mono(12), isStandby ? Desk.brass : Desk.dim, x: 8, y: leftY, width: 40, align: .right)
        draw(Self.kindGlyph(cue.kind), Desk.mono(11), Desk.dim, x: 56, y: leftY, width: 14)
        // At the right: in edit mode the grip and delete; then how the cue
        // continues, then any problem.
        if isEditing {
            drawSymbol("line.3.horizontal", Desk.dim, centredIn: NSRect(x: gripRect.minX, y: middleY - 11, width: gripRect.width, height: 22))
            drawSymbol("trash", Desk.dim, centredIn: deleteRect, size: 10.5)
        }
        let symbol = Self.continueSymbol(cue.continueMode)
        let marks = CGFloat((symbol == nil ? 0 : 1) + (hasIssue ? 1 : 0))
        let textX: CGFloat = 78, textWidth = bounds.width - textX - 10 - marks * 18 - controlsWidth
        draw(cue.text.isEmpty ? "\u{2014}" : cue.text, Desk.mono(13), Desk.text, x: textX, y: y, width: textWidth, kern: 0.65)
        var markX = bounds.width - 22 - controlsWidth
        if let symbol {
            drawSymbol(symbol, isStandby ? Desk.brass : Desk.dim, centredIn: markRect(x: markX))
            markX -= 18
        }
        if hasIssue {
            draw("!", Desk.mono(13, .bold), Desk.brass, x: markX + 2, y: middleY - 9 - 1, width: 12)
        }
        y += 18
        if !subtitle.isEmpty {
            draw(subtitle, Desk.sans(11.5), Desk.dim, x: textX, y: y, width: textWidth)
            y += 17
        }
        if !cue.line.isEmpty {
            let italic = NSFontManager.shared.convert(Desk.sans(11.5), toHaveTrait: .italicFontMask)
            draw(cue.line, italic, Desk.dim, x: textX, y: y, width: textWidth)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isEditing, deleteRect.contains(point) {
            onDelete(cue.id)
            return
        }
        if isEditing, gripRect.contains(point) {
            onGrip(self, event)
            return
        }
        onClick(cue.id)
    }

    private func droppedURL(_ info: any NSDraggingInfo) -> URL? {
        guard acceptsMedia else { return nil }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let url = urls?.first, ShowDocument.accepts(url, for: cue.kind) else { return nil }
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
        onDrop(url, cue.id)
        return true
    }
}

final class CueListView: NSScrollView {
    private let document = PanelView()
    private var rows: [CueRowView] = []
    private var shown: [Cue] = []
    private var shownNotes: [String?] = []
    var onClick: (UUID) -> Void = { _ in }
    var onDrop: (URL, UUID) -> Void = { _, _ in }
    var onDelete: (UUID) -> Void = { _ in }
    /// A row dragged to a new place: the cue, and how far it moved.
    var onMove: (UUID, Int) -> Void = { _, _ in }
    /// Where a dragged row will land.
    private let insertion = PanelView(fill: Desk.brass)

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        documentView = document
        insertion.isHidden = true
        document.addSubview(insertion)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(cues: [Cue], defaults: ShowSettings, standby: UUID?, live: UUID?, issues: Set<UUID>, editing: Bool) {
        let notes = cues.map { CueRowView.transitionNote(for: $0, defaults: defaults) }
        if cues != shown || notes != shownNotes {
            rows.forEach { $0.removeFromSuperview() }
            rows = zip(cues, notes).map { cue, note in
                let row = CueRowView(cue: cue, transitionNote: note)
                row.onClick = { [weak self] in self?.onClick($0) }
                row.onDrop = { [weak self] url, id in self?.onDrop(url, id) }
                row.onDelete = { [weak self] in self?.onDelete($0) }
                row.onGrip = { [weak self] row, event in self?.drag(row, from: event) }
                document.addSubview(row, positioned: .below, relativeTo: insertion)
                return row
            }
            shown = cues
            shownNotes = notes
            needsLayout = true
        }
        for row in rows {
            row.isStandby = row.cue.id == standby
            row.isLive = row.cue.id == live
            row.hasIssue = issues.contains(row.cue.id)
            row.acceptsMedia = editing
            row.isEditing = editing
        }
        layoutRows()
        // Keep the standby row in view, and the live row with it if both fit.
        if let standbyRow = rows.first(where: \.isStandby) {
            var target = standbyRow.frame
            if let liveRow = rows.first(where: \.isLive), target.union(liveRow.frame).height + 48 <= contentSize.height {
                target = target.union(liveRow.frame)
            }
            document.scrollToVisible(target.insetBy(dx: 0, dy: -24))
        }
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    // MARK: Reordering

    /// Follows the pointer from a row's grip until the button comes up,
    /// showing where the row will land, then moves the cue there.
    private func drag(_ row: CueRowView, from event: NSEvent) {
        guard let window, let from = rows.firstIndex(where: { $0 === row }) else { return }
        row.isLifted = true
        NSCursor.closedHand.push()
        var landed: Int?
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { event, stop in
            guard let event, event.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            document.autoscroll(with: event)
            let landing = slot(at: document.convert(event.locationInWindow, from: nil).y)
            landed = landing
            showInsertion(at: landing)
        }
        NSCursor.pop()
        row.isLifted = false
        insertion.isHidden = true
        guard let landed else { return }
        let offset = Self.offset(moving: from, toSlot: landed)
        if offset != 0 { onMove(row.cue.id, offset) }
    }

    /// Where a dragged row would go: before the first row whose middle is
    /// below the pointer, or at the end.
    private func slot(at y: CGFloat) -> Int {
        rows.firstIndex { y < $0.frame.midY } ?? rows.count
    }

    /// How far a cue moves to land in a slot, the slots counted before it
    /// is lifted out: dropping it just above or below itself moves it
    /// nowhere.
    static func offset(moving from: Int, toSlot slot: Int) -> Int {
        slot > from ? slot - from - 1 : slot - from
    }

    private func showInsertion(at slot: Int) {
        let y = slot < rows.count ? rows[slot].frame.minY - 2.5 : (rows.last.map { $0.frame.maxY + 0.5 } ?? 0)
        insertion.frame = NSRect(x: 6, y: y, width: document.bounds.width - 12, height: 2)
        insertion.isHidden = false
    }

    private func layoutRows() {
        let width = contentSize.width
        var y: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: row.preferredHeight)
            y += row.preferredHeight + 3
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y, contentSize.height))
    }
}

// MARK: - Warnings

/// A warning that stays until it no longer applies: brass-edged, on the
/// right, above the preview.
final class WarningBox: PanelView {
    private let bar = PanelView(fill: Desk.brass)
    let text = Desk.label("", font: Desk.sans(12.5), colour: Desk.text, wraps: true)

    init() {
        super.init(fill: Desk.raised)
        addSubview(bar)
        addSubview(text)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func height(width: CGFloat) -> CGFloat {
        Desk.height(of: text, width: width - 24) + 20
    }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: 0, width: 2, height: bounds.height)
        text.frame = NSRect(x: 12, y: 10, width: bounds.width - 24, height: bounds.height - 20)
    }
}

// MARK: - Projection area

/// Edit mode's geometry controls: width, height and offsets as percentages
/// of the projector output, alignment guides, and a reset.
final class GeometryPanel: PanelView {
    private let heading = Desk.label("Projection area", font: Desk.sans(12.5, .semibold), colour: Desk.text)
    private var rows: [(label: NSTextField, slider: NSSlider, value: NSTextField)] = []
    let guides = NSButton(checkboxWithTitle: "Alignment guides", target: nil, action: nil)
    let fill = NSButton(title: "Fill the Output", target: nil, action: nil)
    private let note = Desk.label(
        "Percentages of the projector output, so they hold if the resolution changes. Guides switch themselves off in show mode.",
        font: Desk.sans(12), colour: Desk.dim, wraps: true)

    var onChange: (Geometry) -> Void = { _ in }
    private var geometry = Geometry()

    init() {
        super.init(border: Desk.line, radius: 4)
        addSubview(heading)
        let specs: [(String, ClosedRange<Int>)] = [
            ("Width", SettingRange.geometrySize), ("Height", SettingRange.geometrySize),
            ("Across", SettingRange.geometryOffset), ("Down", SettingRange.geometryOffset),
        ]
        for (name, range) in specs {
            let label = Desk.label(name, font: Desk.sans(12.5), colour: Desk.dim)
            let slider = NSSlider(value: 0, minValue: Double(range.lowerBound), maxValue: Double(range.upperBound),
                                  target: self, action: #selector(sliderMoved(_:)))
            // Sliders never take the keyboard, or the arrow keys would move
            // them instead of the standby cue.
            slider.refusesFirstResponder = true
            slider.isContinuous = true
            let value = Desk.label("", font: Desk.mono(12), colour: Desk.dim)
            value.alignment = .right
            for view in [label, slider, value] as [NSView] { addSubview(view) }
            rows.append((label, slider, value))
        }
        guides.refusesFirstResponder = true
        fill.refusesFirstResponder = true
        fill.bezelStyle = .rounded
        fill.target = self
        fill.action = #selector(fillOutput)
        for view in [guides, fill, note] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(geometry: Geometry, guidesOn: Bool) {
        self.geometry = geometry
        let values = [geometry.width, geometry.height, geometry.across, geometry.down]
        for (i, row) in rows.enumerated() {
            row.slider.integerValue = values[i]
            row.value.stringValue = i < 2 ? "\(values[i])%" : String(format: "%+d%%", values[i]).replacingOccurrences(of: "+0", with: "0")
        }
        guides.state = guidesOn ? .on : .off
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let i = rows.firstIndex(where: { $0.slider === sender }) else { return }
        var g = geometry
        switch i {
        case 0: g.width = sender.integerValue
        case 1: g.height = sender.integerValue
        case 2: g.across = sender.integerValue
        default: g.down = sender.integerValue
        }
        onChange(g)
    }

    @objc private func fillOutput() {
        onChange(Geometry())
    }

    var preferredHeight: CGFloat {
        15 + 18 + 11 + CGFloat(rows.count) * 31 + 6 + 28 + 10 + 34 + 15
    }

    override func layout() {
        super.layout()
        let x: CGFloat = 16, inner = bounds.width - 32
        var y: CGFloat = 15
        heading.frame = NSRect(x: x, y: y, width: inner, height: 18); y += 29
        for row in rows {
            row.label.frame = NSRect(x: x, y: y + 3, width: 84, height: 18)
            row.slider.frame = NSRect(x: x + 92, y: y, width: inner - 92 - 64, height: 24)
            row.value.frame = NSRect(x: x + inner - 56, y: y + 3, width: 56, height: 18)
            y += 31
        }
        y += 6
        guides.frame = NSRect(x: x, y: y + 4, width: guides.fittingSize.width, height: 20)
        let fillWidth = fill.fittingSize.width
        fill.frame = NSRect(x: guides.frame.maxX + 16, y: y, width: fillWidth, height: 28)
        y += 38
        note.frame = NSRect(x: x, y: y, width: inner, height: Desk.height(of: note, width: inner))
    }
}

// MARK: - Key bar

/// The keyboard reference along the bottom.
final class KeyBar: PanelView {
    private let keys: [(String, String)] = [
        ("Space", "Fire the standby cue"),
        ("\u{2190} \u{2192}", "Stand by previous, next"),
        ("0\u{2013}9 \u{21A9}", "Go to a cue number"),
        ("R", "Run again"),
        ("B", "Blackout"),
    ]

    init() {
        super.init(fill: Desk.raised)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Desk.line.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        var x: CGFloat = 16
        let midY = bounds.height / 2
        for (key, meaning) in keys {
            let keyText = NSAttributedString(string: key, attributes: [.font: Desk.mono(12), .foregroundColor: Desk.brass])
            let keySize = keyText.size()
            let cap = NSRect(x: x, y: midY - 10, width: keySize.width + 14, height: 20)
            let path = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            Desk.sunk.setFill()
            path.fill()
            Desk.line.setStroke()
            path.stroke()
            keyText.draw(at: NSPoint(x: cap.minX + 7, y: midY - keySize.height / 2))
            let meaningText = NSAttributedString(string: meaning, attributes: [.font: Desk.sans(12.5), .foregroundColor: Desk.dim])
            let meaningSize = meaningText.size()
            meaningText.draw(at: NSPoint(x: cap.maxX + 7, y: midY - meaningSize.height / 2))
            x = cap.maxX + 7 + meaningSize.width + 22
        }
        let trail = NSAttributedString(string: "These work in the projector window too.",
                                       attributes: [.font: Desk.sans(12.5), .foregroundColor: Desk.dim])
        let trailSize = trail.size()
        if bounds.width - 16 - trailSize.width > x {
            trail.draw(at: NSPoint(x: bounds.width - 16 - trailSize.width, y: midY - trailSize.height / 2))
        }
    }
}

extension String {
    /// Nil for an empty string, as a tooltip with nothing to say.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
