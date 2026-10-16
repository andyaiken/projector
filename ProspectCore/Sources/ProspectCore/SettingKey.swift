/// A value of one setting.
public enum SettingValue: Equatable, Sendable {
    case number(Int)
    case flag(Bool)
    case order(TileOrder)
    case reveal(TileReveal)
    case letters(TitleLetters)
    case style(TransitionStyle)
}

/// Every setting a show holds a default for, and that a cue may override.
/// One definition serves the show-default panels, the cue editor's overrides
/// and the printed sheet: its range and step, how it reads, and where it
/// lives in the model.
public enum SettingKey: String, CaseIterable, Sendable {
    case clock, wave, hold, textScale, histogram, sceneLine, letters, grid, flip, order, reveal, transition, fade

    /// What a title cue can override.
    public static let title: [SettingKey] = [.clock, .wave, .hold, .histogram, .sceneLine, .letters]
    /// What an anagram cue can override.
    public static let anagram: [SettingKey] = [.clock, .wave, .hold]
    /// What an image cue can override.
    public static let image: [SettingKey] = [.clock, .wave, .hold, .grid, .flip, .order, .reveal]
    /// The transition into a cue, which every cue can override.
    public static let transitions: [SettingKey] = [.transition, .fade]
    /// The show-default panels, in their groups.
    public static let groups: [(name: String, keys: [SettingKey])] = [
        ("Timing", [.clock, .wave, .hold]),
        ("Decryption cues", [.textScale, .histogram, .sceneLine, .letters]),
        ("Image cues", [.grid, .flip, .order, .reveal]),
        ("Transitions", transitions),
    ]

    public var label: String {
        switch self {
        case .clock: "Clock"
        case .wave: "Wave"
        case .hold: "Hold"
        case .textScale: "Text size"
        case .histogram: "Histogram"
        case .sceneLine: "Subtext"
        case .letters: "Letters"
        case .grid: "Grid"
        case .flip: "Flip"
        case .order: "Order"
        case .reveal: "Reveal by"
        case .transition: "Transition"
        case .fade: "Fade"
        }
    }

    /// What the setting does, in a sentence or two, for the panels to show
    /// on hover.
    public var help: String {
        switch self {
        case .clock: "How long each step of the cue takes. Every other timing is counted in these steps, so a shorter clock runs the whole cue faster."
        case .wave: "How many steps apart neighbouring letters, or diagonals of tiles, start to move. None moves them all together."
        case .hold: "How many steps the cue shows its opening state, the ciphertext, the first phrase or the colour blocks, before it starts to resolve."
        case .textScale: "The size of decryption and anagram text, as a share of the largest that fits."
        case .histogram: "The letter-frequency bars and readouts beneath the text."
        case .sceneLine: "The smaller line of text beneath the main one."
        case .letters: "How each letter finds its way home: cycling through random glyphs and rolling back into place, or spinning on a dial, like a cryptex's, and settling."
        case .grid: "How many tiles across the picture is cut into."
        case .flip: "How long each tile takes to show its part of the picture: to turn over, or to sharpen."
        case .order: "Whether the tiles go in a sweep from the top left, in a random order, or out along a golden spiral, square by Fibonacci square."
        case .reveal: "How each tile shows its part of the picture: turning over, or sharpening through finer and finer blocks, 1, 2, 3, 5, 8 across and on."
        case .transition: "How the stage changes to this cue: a fade through black, or a snap."
        case .fade: "How long each half of a fade takes: out, then in."
        }
    }

    /// How long a hold lasts, at the clock it runs with. Nil for no hold.
    public static func holdLength(holdTicks: Int, clockMs: Int) -> String? {
        holdTicks == 0 ? nil : fixedDecimal(Double(holdTicks * clockMs) / 1000, digits: 1) + " s"
    }

    /// Clock, wave and hold together, for the panels to show beside them.
    public static let timingExplanation = "Timing is counted in steps of the clock. Clock is how long a step takes; hold is how many steps a cue shows its ciphertext, first phrase or colour blocks before it starts to resolve; wave is how many steps apart neighbouring letters, or diagonals of tiles, start."

    public enum Control: Equatable, Sendable {
        case slider(ClosedRange<Int>, step: Int)
        case toggle
        case choice([String])
    }

    /// The slider ranges and steps.
    public var control: Control {
        switch self {
        case .clock: .slider(SettingRange.clockMs, step: 2)
        case .wave: .slider(SettingRange.waveTicks, step: 1)
        case .hold: .slider(SettingRange.holdTicks, step: 2)
        case .textScale: .slider(SettingRange.textScale, step: 2)
        case .grid: .slider(SettingRange.gridColumns, step: 1)
        case .flip: .slider(SettingRange.flipMs, step: 30)
        case .histogram, .sceneLine: .toggle
        case .order: .choice(["Diagonal sweep", "Random", "Golden spiral"])
        case .reveal: .choice(["Flipping", "Sharpening"])
        case .letters: .choice(["Cycling", "Dials"])
        case .transition: .choice(["Fade through black", "Snap"])
        case .fade: .slider(SettingRange.fadeMs, step: 100)
        }
    }

    /// For a choice, the value at each place in its menu.
    public func choice(at index: Int) -> SettingValue? {
        switch self {
        case .order: [SettingValue.order(.diagonal), .order(.random), .order(.spiral)][safe: index]
        case .reveal: [SettingValue.reveal(.flip), .reveal(.sharpen)][safe: index]
        case .letters: [SettingValue.letters(.cycle), .letters(.dials)][safe: index]
        case .transition: [SettingValue.style(.fade), .style(.snap)][safe: index]
        default: nil
        }
    }

    /// For a choice, where a value sits in its menu.
    public func choiceIndex(of value: SettingValue) -> Int? {
        guard case .choice(let options) = control else { return nil }
        return options.indices.first { choice(at: $0) == value }
    }

    /// How a value reads beside its control.
    public func format(_ value: SettingValue) -> String {
        switch (self, value) {
        case (.clock, .number(let n)), (.flip, .number(let n)): "\(n) ms"
        case (.wave, .number(let n)), (.hold, .number(let n)): n == 0 ? "none" : "\(n)"
        case (.textScale, .number(let n)): "\(n)%"
        case (.fade, .number(let n)): fixedDecimal(Double(n) / 1000, digits: 1) + " s"
        case (.grid, .number(let n)): "\(n) wide"
        case (_, .flag(let on)): on ? "on" : "off"
        case (_, .order(.diagonal)): "diagonal sweep"
        case (_, .order(.random)): "random"
        case (_, .order(.spiral)): "golden spiral"
        case (_, .reveal(let reveal)): reveal == .flip ? "flipping" : "sharpening"
        case (_, .letters(let letters)): letters == .cycle ? "cycling" : "dials"
        case (_, .style(let style)): style == .fade ? "fade through black" : "snap"
        case (_, .number(let n)): "\(n)"
        }
    }

    /// The nearest allowed value: inside the range and on a step.
    public func snapped(_ value: SettingValue) -> SettingValue {
        guard case .number(let n) = value, case .slider(let range, let step) = control else { return value }
        let stepped = range.lowerBound + Int((Double(n - range.lowerBound) / Double(step)).rounded()) * step
        return .number(range.clamp(stepped))
    }

    // MARK: Show defaults

    public func value(in s: ShowSettings) -> SettingValue {
        switch self {
        case .clock: .number(s.clockMs)
        case .wave: .number(s.waveTicks)
        case .hold: .number(s.holdTicks)
        case .textScale: .number(s.textScale)
        case .histogram: .flag(s.histogram)
        case .sceneLine: .flag(s.sceneLine)
        case .letters: .letters(s.letters)
        case .grid: .number(s.gridColumns)
        case .flip: .number(s.flipMs)
        case .order: .order(s.order)
        case .reveal: .reveal(s.reveal)
        case .transition: .style(s.transition)
        case .fade: .number(s.fadeMs)
        }
    }

    public func set(_ value: SettingValue, in s: inout ShowSettings) {
        switch (self, snapped(value)) {
        case (.clock, .number(let n)): s.clockMs = n
        case (.wave, .number(let n)): s.waveTicks = n
        case (.hold, .number(let n)): s.holdTicks = n
        case (.textScale, .number(let n)): s.textScale = n
        case (.histogram, .flag(let on)): s.histogram = on
        case (.sceneLine, .flag(let on)): s.sceneLine = on
        case (.letters, .letters(let letters)): s.letters = letters
        case (.grid, .number(let n)): s.gridColumns = n
        case (.flip, .number(let n)): s.flipMs = n
        case (.order, .order(let order)): s.order = order
        case (.reveal, .reveal(let reveal)): s.reveal = reveal
        case (.transition, .style(let style)): s.transition = style
        case (.fade, .number(let n)): s.fadeMs = n
        default: break
        }
    }

    // MARK: Overrides

    /// Whether a cue of this kind can override this setting.
    public func applies(to kind: Cue.Kind) -> Bool {
        if Self.transitions.contains(self) { return true }
        return switch kind {
        case .title: Self.title.contains(self)
        case .anagram: Self.anagram.contains(self)
        case .image: Self.image.contains(self)
        case .video, .blank: false
        }
    }

    /// The cue's own value, or nil where it takes the show's default.
    public func override(in cue: Cue) -> SettingValue? {
        // The transition in belongs to the cue, not to its kind's content.
        switch self {
        case .transition: return cue.transition.style.map(SettingValue.style)
        case .fade: return cue.transition.fadeMs.map(SettingValue.number)
        default: break
        }
        switch cue.content {
        case .title(let c):
            let o = c.overrides
            switch self {
            case .clock: return o.clockMs.map(SettingValue.number)
            case .wave: return o.waveTicks.map(SettingValue.number)
            case .hold: return o.holdTicks.map(SettingValue.number)
            case .histogram: return o.histogram.map(SettingValue.flag)
            case .sceneLine: return o.sceneLine.map(SettingValue.flag)
            case .letters: return o.letters.map(SettingValue.letters)
            default: return nil
            }
        case .anagram(let c):
            let o = c.overrides
            switch self {
            case .clock: return o.clockMs.map(SettingValue.number)
            case .wave: return o.waveTicks.map(SettingValue.number)
            case .hold: return o.holdTicks.map(SettingValue.number)
            default: return nil
            }
        case .image(let c):
            let o = c.overrides
            switch self {
            case .clock: return o.clockMs.map(SettingValue.number)
            case .wave: return o.waveTicks.map(SettingValue.number)
            case .hold: return o.holdTicks.map(SettingValue.number)
            case .grid: return o.gridColumns.map(SettingValue.number)
            case .flip: return o.flipMs.map(SettingValue.number)
            case .order: return o.order.map(SettingValue.order)
            case .reveal: return o.reveal.map(SettingValue.reveal)
            default: return nil
            }
        case .video, .blank:
            return nil
        }
    }

    /// Sets the cue's own value, or with nil puts it back on the show's
    /// default. Does nothing for settings the cue's kind doesn't have.
    public func setOverride(_ value: SettingValue?, in cue: inout Cue) {
        let value = value.map(snapped)
        func number() -> Int? { if case .number(let n) = value { n } else { nil } }
        func flag() -> Bool? { if case .flag(let on) = value { on } else { nil } }
        func order() -> TileOrder? { if case .order(let o) = value { o } else { nil } }
        func reveal() -> TileReveal? { if case .reveal(let r) = value { r } else { nil } }
        func letters() -> TitleLetters? { if case .letters(let l) = value { l } else { nil } }
        func style() -> TransitionStyle? { if case .style(let s) = value { s } else { nil } }
        switch self {
        case .transition:
            cue.transition.style = style()
            return
        case .fade:
            cue.transition.fadeMs = number()
            return
        default: break
        }
        switch cue.content {
        case .title(var c):
            switch self {
            case .clock: c.overrides.clockMs = number()
            case .wave: c.overrides.waveTicks = number()
            case .hold: c.overrides.holdTicks = number()
            case .histogram: c.overrides.histogram = flag()
            case .sceneLine: c.overrides.sceneLine = flag()
            case .letters: c.overrides.letters = letters()
            default: return
            }
            cue.content = .title(c)
        case .anagram(var c):
            switch self {
            case .clock: c.overrides.clockMs = number()
            case .wave: c.overrides.waveTicks = number()
            case .hold: c.overrides.holdTicks = number()
            default: return
            }
            cue.content = .anagram(c)
        case .image(var c):
            switch self {
            case .clock: c.overrides.clockMs = number()
            case .wave: c.overrides.waveTicks = number()
            case .hold: c.overrides.holdTicks = number()
            case .grid: c.overrides.gridColumns = number()
            case .flip: c.overrides.flipMs = number()
            case .order: c.overrides.order = order()
            case .reveal: c.overrides.reveal = reveal()
            default: return
            }
            cue.content = .image(c)
        case .video, .blank:
            return
        }
    }

    /// What the cue runs with: its own value if it has one, otherwise the
    /// show's default.
    public func effective(for cue: Cue, defaults: ShowSettings) -> (value: SettingValue, overridden: Bool) {
        if let own = override(in: cue) { return (own, true) }
        return (value(in: defaults), false)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
