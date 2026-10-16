import AppKit
import ProspectCore
import ProspectStage

/// One setting: a label, its control, the value as it reads, and in a cue's
/// settings a Reset that puts it back on the show's default.
final class SettingRow: NSView {
    let key: SettingKey
    private let label: NSTextField
    private let value = Desk.label("", font: Desk.mono(12), colour: Desk.dim)
    private var slider: NSSlider?
    private var toggle: NSButton?
    private var popup: NSPopUpButton?
    private let reset: NSButton?

    /// The new value, and whether it came from a control still being moved.
    var onChange: (SettingValue, _ continuous: Bool) -> Void = { _, _ in }
    var onReset: () -> Void = {}

    init(key: SettingKey, resettable: Bool) {
        self.key = key
        label = Desk.label(key.label, font: Desk.sans(12.5), colour: Desk.dim)
        reset = resettable ? NSButton(title: "Reset", target: nil, action: nil) : nil
        super.init(frame: .zero)
        addSubview(label)
        value.alignment = .right
        addSubview(value)

        switch key.control {
        case .slider(let range, _):
            let slider = NSSlider(value: Double(range.lowerBound), minValue: Double(range.lowerBound), maxValue: Double(range.upperBound),
                                  target: self, action: #selector(slid(_:)))
            slider.isContinuous = true
            // Never takes the keyboard, or the arrows would move it instead
            // of the standby cue.
            slider.refusesFirstResponder = true
            addSubview(slider)
            self.slider = slider
        case .toggle:
            let toggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            toggle.refusesFirstResponder = true
            addSubview(toggle)
            self.toggle = toggle
        case .choice(let options):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: options)
            popup.target = self
            popup.action = #selector(chosen(_:))
            popup.refusesFirstResponder = true
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            addSubview(popup)
            self.popup = popup
        }
        for view in [label, value, slider, toggle, popup].compactMap({ $0 as NSView? }) { view.toolTip = key.help }
        if let reset {
            reset.bezelStyle = .rounded
            reset.controlSize = .small
            reset.font = Desk.sans(11)
            reset.refusesFirstResponder = true
            reset.target = self
            reset.action = #selector(resetPressed)
            reset.toolTip = "Use the show\u{2019}s default"
            addSubview(reset)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameter overridden: In a cue's settings, whether the cue sets this
    ///   value itself: shown in brass with a Reset. Nil for show defaults.
    func show(_ v: SettingValue, overridden: Bool?) {
        switch v {
        case .number(let n): slider?.integerValue = n
        case .flag(let on): toggle?.state = on ? .on : .off
        case .order, .reveal, .letters, .style: popup?.selectItem(at: key.choiceIndex(of: v) ?? 0)
        }
        value.stringValue = key.format(v)
        value.textColor = overridden == true ? Desk.brass : (overridden == false ? Desk.dim : Desk.text)
        label.textColor = overridden == true ? Desk.brass : Desk.dim
        reset?.isHidden = overridden != true
    }

    /// A second reading after the value, as a hold's length in seconds.
    func annotate(_ extra: String?) {
        guard let extra else { return }
        value.stringValue += " \u{00B7} " + extra
    }

    @objc private func slid(_ sender: NSSlider) {
        let snapped = key.snapped(.number(sender.integerValue))
        if case .number(let n) = snapped { sender.integerValue = n }
        value.stringValue = key.format(snapped)
        onChange(snapped, true)
    }

    @objc private func toggled(_ sender: NSButton) {
        onChange(.flag(sender.state == .on), false)
    }

    @objc private func chosen(_ sender: NSPopUpButton) {
        guard let value = key.choice(at: sender.indexOfSelectedItem) else { return }
        onChange(value, false)
    }

    /// Off where the setting has no effect, as a fade time on a snap.
    var isEnabled = true {
        didSet {
            slider?.isEnabled = isEnabled
            toggle?.isEnabled = isEnabled
            popup?.isEnabled = isEnabled
            alphaValue = isEnabled ? 1 : 0.45
        }
    }

    @objc private func resetPressed() {
        onReset()
    }

    static let height: CGFloat = 28

    override func layout() {
        super.layout()
        let w = bounds.width, labelWidth: CGFloat = 76, resetWidth: CGFloat = reset == nil ? 0 : 56
        // A popup shows its own value, so it takes the value's space too.
        let valueWidth: CGFloat = popup == nil ? 80 : 0
        value.isHidden = popup != nil
        label.frame = NSRect(x: 0, y: 5, width: labelWidth - 6, height: 18)
        let controlX = labelWidth, controlWidth = max(40, w - labelWidth - valueWidth - resetWidth - 8)
        slider?.frame = NSRect(x: controlX, y: 2, width: controlWidth, height: 24)
        toggle?.frame = NSRect(x: controlX, y: 4, width: 22, height: 20)
        popup?.frame = NSRect(x: controlX, y: 1, width: min(controlWidth, 180), height: 24)
        value.frame = NSRect(x: controlX + controlWidth + 4, y: 5, width: valueWidth, height: 18)
        reset?.frame = NSRect(x: w - resetWidth + 4, y: 2, width: resetWidth - 4, height: 24)
    }

    override var isFlipped: Bool { true }
}

/// Edit mode's show panel: the title printed on the cue sheet, then the
/// show's defaults in groups, three to a line: timing, decryption cues and
/// image cues, then transitions. Every cue that doesn't set its own value
/// runs with these.
final class ShowDefaultsPanel: PanelView, NSTextFieldDelegate {
    private let titleLabel = Desk.label("Title", font: Desk.sans(12.5), colour: Desk.dim)
    private let title = NSTextField(string: "")
    private let titleNote = Desk.label("Printed at the head of every page of the cue sheet.", font: Desk.sans(12), colour: Desk.dim)
    private let note = Desk.label("Every cue runs with these unless it sets its own, in Cue Settings. Changes show on the cue on stage at once, finished, except transitions, which take effect when the stage next changes cue; R runs it again.",
                                  font: Desk.sans(12), colour: Desk.dim, wraps: true)
    private var groups: [(heading: NSTextField, rows: [SettingRow])] = []
    private let timingHeading = Desk.label("How timing works", font: Desk.sans(12, .semibold), colour: Desk.dim)
    private let timingNote = Desk.label(SettingKey.timingExplanation, font: Desk.sans(12), colour: Desk.dim, wraps: true)

    var onChange: (SettingKey, SettingValue, Bool) -> Void = { _, _, _ in }
    var onTitleChange: (String) -> Void = { _ in }
    /// Return or Escape in the title gives the keyboard back to the show keys.
    var finishedEditing: () -> Void = {}

    init() {
        super.init(border: Desk.line, radius: 4)
        title.font = Desk.sans(12.5)
        title.bezelStyle = .roundedBezel
        title.usesSingleLineMode = true
        title.cell?.allowsUndo = false
        title.delegate = self
        for view in [titleLabel, title, titleNote, note, timingHeading, timingNote] as [NSView] { addSubview(view) }
        for group in SettingKey.groups {
            let title = Desk.label(group.name, font: Desk.sans(12, .semibold), colour: Desk.dim)
            addSubview(title)
            let rows = group.keys.map { key -> SettingRow in
                let row = SettingRow(key: key, resettable: false)
                row.onChange = { [weak self] value, continuous in self?.onChange(key, value, continuous) }
                addSubview(row)
                return row
            }
            groups.append((title, rows))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameter fallback: What prints when the title is empty: the
    ///   document's name. Shown as the field's hint.
    func update(title text: String, fallback: String, settings: ShowSettings) {
        if title.currentEditor() == nil, title.stringValue != text { title.stringValue = text }
        title.placeholderAttributedString = NSAttributedString(string: "\(fallback) (the file\u{2019}s name)", attributes: [
            .foregroundColor: Desk.dim.withAlphaComponent(0.7),
            .font: NSFontManager.shared.convert(Desk.sans(12.5), toHaveTrait: .italicFontMask),
        ])
        for row in groups.flatMap(\.rows) {
            row.show(row.key.value(in: settings), overridden: nil)
            if row.key == .fade { row.isEnabled = settings.transition == .fade }
            if row.key == .hold { row.annotate(SettingKey.holdLength(holdTicks: settings.holdTicks, clockMs: settings.clockMs)) }
        }
    }

    /// Room for the title, every group, and the note.
    var preferredHeight: CGFloat {
        Self.groupsTop + SettingGroups.height(of: groups.map(\.rows.count)) + 6 + 36 + 12
    }

    private static let groupsTop: CGFloat = 60

    func controlTextDidEndEditing(_ notification: Notification) {
        onTitleChange(title.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finishedEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            title.abortEditing()
            finishedEditing()
            return true
        default:
            return false
        }
    }

    override func layout() {
        super.layout()
        let x: CGFloat = 16, inner = bounds.width - 32, gap: CGFloat = 24
        titleLabel.frame = NSRect(x: x, y: 19, width: 78, height: 18)
        let titleWidth = min(360, inner - 84)
        title.frame = NSRect(x: x + 84, y: 16, width: titleWidth, height: 24)
        titleNote.frame = NSRect(x: x + 84 + titleWidth + 12, y: 19, width: max(0, inner - 96 - titleWidth), height: 18)
        let bottom = SettingGroups.layout(groups, x: x, y: Self.groupsTop, width: inner, gap: gap)
        note.frame = NSRect(x: x, y: bottom + 6, width: inner, height: Desk.height(of: note, width: inner))
        // Beside Transitions, in the second line's empty columns.
        let columnWidth = (inner - gap * 2) / 3
        let firstLineRows = CGFloat(groups.prefix(SettingGroups.perLine).map(\.rows.count).max() ?? 0)
        let secondLine = Self.groupsTop + SettingGroups.headingHeight + firstLineRows * SettingGroups.rowPitch + SettingGroups.lineGap
        let noteX = x + columnWidth + gap, noteWidth = columnWidth * 2 + gap
        timingHeading.frame = NSRect(x: noteX, y: secondLine, width: noteWidth, height: 16)
        timingNote.frame = NSRect(x: noteX, y: secondLine + SettingGroups.headingHeight, width: noteWidth,
                                  height: Desk.height(of: timingNote, width: noteWidth))
    }
}

/// Edit mode's settings for the cue standing by: what it runs with, the
/// values it sets itself in brass, and a Reset for each of those.
final class CueSettingsPanel: PanelView {
    private let heading = Desk.label("Cue settings", font: Desk.sans(12.5, .semibold), colour: Desk.text)
    private let note = Desk.label("", font: Desk.sans(12), colour: Desk.dim, wraps: true)
    private var groups: [(heading: NSTextField, rows: [SettingRow])] = []
    private var rows: [SettingRow] { groups.flatMap(\.rows) }
    private var shownKind: Cue.Kind?

    var onChange: (SettingKey, SettingValue?, Bool) -> Void = { _, _, _ in }

    init() {
        super.init(border: Desk.line, radius: 4)
        addSubview(heading)
        addSubview(note)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(cue: Cue?, defaults: ShowSettings) {
        let kind = cue?.kind
        if kind != shownKind {
            for group in groups {
                group.heading.removeFromSuperview()
                group.rows.forEach { $0.removeFromSuperview() }
            }
            // The show's groups, keeping only what this kind of cue can set.
            groups = SettingKey.groups.compactMap { group in
                let keys = group.keys.filter { key in kind.map(key.applies(to:)) ?? false }
                guard !keys.isEmpty else { return nil }
                let heading = Desk.label(group.name, font: Desk.sans(12, .semibold), colour: Desk.dim)
                addSubview(heading)
                let rows = keys.map { key -> SettingRow in
                    let row = SettingRow(key: key, resettable: true)
                    row.onChange = { [weak self] value, continuous in self?.onChange(key, value, continuous) }
                    row.onReset = { [weak self] in self?.onChange(key, nil, false) }
                    addSubview(row)
                    return row
                }
                return (heading, rows)
            }
            shownKind = kind
            needsLayout = true
        }
        guard let cue else {
            heading.stringValue = "Cue settings"
            note.stringValue = "Nothing is standing by. Click a cue in the list to see the settings it runs with."
            return
        }
        heading.stringValue = "Cue \(cue.number.isEmpty ? "(no number)" : cue.number) settings \u{2014} \(cue.kind.name)"
        switch cue.kind {
        case .video:
            note.stringValue = "A video plays on its own clock from GO, so it has only its transition in to set. Its end behaviour is in the Cue tab."
        case .blank:
            note.stringValue = "A blank is instant, so it has only its transition in to set. Its colour is in the Cue tab."
        case .title, .anagram, .image:
            note.stringValue = SettingKey.timingExplanation + " Values in brass are set for this cue; the rest come from the Show tab. Reset puts a value back on the default."
        }
        let timing = cue.timing(defaults: defaults)
        for row in rows {
            let (value, overridden) = row.key.effective(for: cue, defaults: defaults)
            row.show(value, overridden: overridden)
            if row.key == .fade { row.isEnabled = cue.transitionIn(defaults: defaults).style == .fade }
            if row.key == .hold { row.annotate(SettingKey.holdLength(holdTicks: timing.holdTicks, clockMs: timing.clockMs)) }
        }
    }

    /// Room for the most a cue can set, an image cue's groups, and the note.
    var preferredHeight: CGFloat {
        46 + SettingGroups.height(of: [3, 4, 2]) + 10 + 54 + 12
    }

    override func layout() {
        super.layout()
        let x: CGFloat = 16, inner = bounds.width - 32, gap: CGFloat = 24
        heading.frame = NSRect(x: x, y: 15, width: inner, height: 18)
        let bottom = groups.isEmpty ? 46 : SettingGroups.layout(groups, x: x, y: 46, width: inner, gap: gap) + 10
        note.frame = NSRect(x: x, y: bottom, width: inner, height: Desk.height(of: note, width: inner))
    }
}

/// Groups of settings, each a heading over its rows, laid out three to a
/// line in equal columns, so every panel lines them up the same way.
@MainActor
enum SettingGroups {
    static let perLine = 3
    static let headingHeight: CGFloat = 22
    static let rowPitch = SettingRow.height + 4
    static let lineGap: CGFloat = 12

    /// The height of groups with these numbers of rows.
    static func height(of rowCounts: [Int]) -> CGFloat {
        let lines = stride(from: 0, to: rowCounts.count, by: perLine).map { rowCounts[$0..<min($0 + perLine, rowCounts.count)] }
        return lines.map { headingHeight + CGFloat($0.max() ?? 0) * rowPitch }.reduce(0, +)
            + CGFloat(max(0, lines.count - 1)) * lineGap
    }

    /// Lays the groups out from `y`, and returns where they end.
    static func layout(_ groups: [(heading: NSTextField, rows: [SettingRow])], x: CGFloat, y: CGFloat, width: CGFloat, gap: CGFloat) -> CGFloat {
        let columnWidth = (width - gap * CGFloat(perLine - 1)) / CGFloat(perLine)
        var lineTop = y
        for start in stride(from: 0, to: groups.count, by: perLine) {
            let line = groups[start..<min(start + perLine, groups.count)]
            for (i, group) in line.enumerated() {
                let cx = x + CGFloat(i) * (columnWidth + gap)
                group.heading.frame = NSRect(x: cx, y: lineTop, width: columnWidth, height: 16)
                for (r, row) in group.rows.enumerated() {
                    row.frame = NSRect(x: cx, y: lineTop + headingHeight + CGFloat(r) * rowPitch, width: columnWidth, height: SettingRow.height)
                }
            }
            lineTop += headingHeight + CGFloat(line.map(\.rows.count).max() ?? 0) * rowPitch + lineGap
        }
        return lineTop - lineGap
    }
}
