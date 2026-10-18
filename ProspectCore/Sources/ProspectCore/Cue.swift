import Foundation

/// One cue in the sheet. The payload is an enum per kind, so a combination
/// that makes no sense, such as a key on an image cue, can't be represented.
public struct Cue: Identifiable, Equatable, Sendable {
    /// Never shown. Identity for undo, the playhead and the crash record,
    /// since numbers may be duplicated.
    public var id: UUID
    /// The number the DSM writes in the book: an identifier, not a position.
    /// `9.5` and `P12` are both valid.
    public var number: String
    /// The cue point: the spoken line or action the operator waits for.
    public var line: String
    /// What happens after this cue: GO, a timed wait, or this cue finishing.
    public var continueMode: ContinueMode
    /// The cue's own transition in, where it differs from the show's.
    public var transition: TransitionOverrides
    public var content: Content

    public enum Content: Equatable, Sendable {
        case title(TitleContent)
        case anagram(AnagramContent)
        case image(ImageContent)
        case video(VideoContent)
        case blank(BlankContent)
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case title, anagram, image, video, blank

        /// What the operator calls it, as it reads mid-sentence. The raw
        /// value is what show.json stores, and doesn't change with the name.
        public var name: String {
            switch self {
            case .title: "decryption"
            default: rawValue
            }
        }

        /// The name as a menu item or column heading spells it.
        public var heading: String { name.capitalized }
    }

    public init(id: UUID = UUID(), number: String = "", line: String = "", continueMode: ContinueMode = .whenCued,
                transition: TransitionOverrides = .init(), content: Content) {
        self.id = id
        self.number = number
        self.line = line
        self.continueMode = continueMode
        self.transition = transition
        self.content = content
    }

    public var kind: Kind {
        switch content {
        case .title: .title
        case .anagram: .anagram
        case .image: .image
        case .video: .video
        case .blank: .blank
        }
    }

    /// The text on a decryption cue, the first phrase of an anagram; the
    /// label on the others.
    public var text: String {
        get {
            switch content {
            case .title(let c): c.text
            case .anagram(let c): c.text
            case .image(let c): c.text
            case .video(let c): c.text
            case .blank(let c): c.text
            }
        }
        set {
            switch content {
            case .title(var c): c.text = newValue; content = .title(c)
            case .anagram(var c): c.text = newValue; content = .anagram(c)
            case .image(var c): c.text = newValue; content = .image(c)
            case .video(var c): c.text = newValue; content = .video(c)
            case .blank(var c): c.text = newValue; content = .blank(c)
            }
        }
    }

    /// The subtext on a decryption cue, the answer an anagram rearranges
    /// into, the caption on a video cue. Image and blank cues have none.
    public var sub: String {
        get {
            switch content {
            case .title(let c): c.sub
            case .anagram(let c): c.answer
            case .image: ""
            case .video(let c): c.sub
            case .blank: ""
            }
        }
        set {
            switch content {
            case .title(var c): c.sub = newValue; content = .title(c)
            case .anagram(var c): c.answer = newValue; content = .anagram(c)
            case .image: break
            case .video(var c): c.sub = newValue; content = .video(c)
            case .blank: break
            }
        }
    }

    /// Instant cues have nothing to resolve, so they skip the hold.
    public var isInstant: Bool { kind == .blank }
}

public struct TitleContent: Equatable, Sendable {
    /// The text that resolves out of the ciphertext.
    public var text: String
    /// The subtext, on the line beneath it.
    public var sub: String
    /// Drives the ciphertext. Never shown on stage or in the cue list.
    public var key: String
    public var overrides: TitleOverrides

    public init(text: String = "", sub: String = "", key: String = "", overrides: TitleOverrides = .init()) {
        self.text = text
        self.sub = sub
        self.key = key
        self.overrides = overrides
    }
}

public struct AnagramContent: Equatable, Sendable {
    /// The phrase as it first appears.
    public var text: String
    /// The phrase its letters rearrange into.
    public var answer: String
    public var overrides: AnagramOverrides

    public init(text: String = "", answer: String = "", overrides: AnagramOverrides = .init()) {
        self.text = text
        self.answer = answer
        self.overrides = overrides
    }
}

public struct ImageContent: Equatable, Sendable {
    /// The cue's name, and what the stage shows when there is no picture.
    public var text: String
    /// Relative path inside the package. Empty shows the cue's label on black.
    public var src: String
    public var overrides: ImageOverrides

    public init(text: String = "", src: String = "", overrides: ImageOverrides = .init()) {
        self.text = text
        self.src = src
        self.overrides = overrides
    }
}

public struct VideoContent: Equatable, Sendable {
    public var text: String
    /// The caption.
    public var sub: String
    /// Relative path inside the package. Empty is a sheet problem.
    public var src: String
    public var atEnd: VideoEnd

    public init(text: String = "", sub: String = "", src: String = "", atEnd: VideoEnd = .hold) {
        self.text = text
        self.sub = sub
        self.src = src
        self.atEnd = atEnd
    }
}

/// What a video cue does on reaching the end of its clip. Audio is always
/// muted, so there is no setting for it.
public enum VideoEnd: String, Codable, Sendable, CaseIterable {
    /// Freeze on the last frame. The cue settles here.
    case hold
    /// Cut to black, as a blank cue. The cue settles here.
    case black
    /// Repeat until the next cue fires. The cue never settles.
    case loop
}

public struct BlankContent: Equatable, Sendable {
    public var text: String
    public var colour: RGB

    public init(text: String = "BLANK", colour: RGB = .black) {
        self.text = text
        self.colour = colour
    }
}

// MARK: - Per-cue overrides

/// A title cue's own values for settings the show holds defaults for. Nil
/// inherits the show's default.
public struct TitleOverrides: Codable, Equatable, Sendable {
    public var clockMs: Int?
    public var waveTicks: Int?
    public var holdTicks: Int?
    public var histogram: Bool?
    public var sceneLine: Bool?
    public var letters: TitleLetters?
    public var bars: TitleBars?

    public init(clockMs: Int? = nil, waveTicks: Int? = nil, holdTicks: Int? = nil, histogram: Bool? = nil, sceneLine: Bool? = nil,
                letters: TitleLetters? = nil, bars: TitleBars? = nil) {
        self.clockMs = clockMs
        self.waveTicks = waveTicks
        self.holdTicks = holdTicks
        self.histogram = histogram
        self.sceneLine = sceneLine
        self.letters = letters
        self.bars = bars
    }

    public var isEmpty: Bool { self == TitleOverrides() }

    func clamped() -> TitleOverrides {
        var o = self
        o.clockMs = clockMs.map { SettingRange.clockMs.clamp($0) }
        o.waveTicks = waveTicks.map { SettingRange.waveTicks.clamp($0) }
        o.holdTicks = holdTicks.map { SettingRange.holdTicks.clamp($0) }
        return o
    }
}

/// An anagram cue's own values for settings the show holds defaults for. Nil
/// inherits the show's default.
public struct AnagramOverrides: Codable, Equatable, Sendable {
    public var clockMs: Int?
    public var waveTicks: Int?
    public var holdTicks: Int?
    /// A font family's name. Empty is the stage's own type.
    public var font: String?

    public init(clockMs: Int? = nil, waveTicks: Int? = nil, holdTicks: Int? = nil, font: String? = nil) {
        self.clockMs = clockMs
        self.waveTicks = waveTicks
        self.holdTicks = holdTicks
        self.font = font
    }

    public var isEmpty: Bool { self == AnagramOverrides() }

    func clamped() -> AnagramOverrides {
        var o = self
        o.clockMs = clockMs.map { SettingRange.clockMs.clamp($0) }
        o.waveTicks = waveTicks.map { SettingRange.waveTicks.clamp($0) }
        o.holdTicks = holdTicks.map { SettingRange.holdTicks.clamp($0) }
        return o
    }
}

/// An image cue's own values for settings the show holds defaults for. Nil
/// inherits the show's default.
public struct ImageOverrides: Codable, Equatable, Sendable {
    public var clockMs: Int?
    public var waveTicks: Int?
    public var holdTicks: Int?
    public var gridColumns: Int?
    public var flipMs: Int?
    public var order: TileOrder?
    public var reveal: TileReveal?

    public init(clockMs: Int? = nil, waveTicks: Int? = nil, holdTicks: Int? = nil, gridColumns: Int? = nil, flipMs: Int? = nil,
                order: TileOrder? = nil, reveal: TileReveal? = nil) {
        self.clockMs = clockMs
        self.waveTicks = waveTicks
        self.holdTicks = holdTicks
        self.gridColumns = gridColumns
        self.flipMs = flipMs
        self.order = order
        self.reveal = reveal
    }

    public var isEmpty: Bool { self == ImageOverrides() }

    func clamped() -> ImageOverrides {
        var o = self
        o.clockMs = clockMs.map { SettingRange.clockMs.clamp($0) }
        o.waveTicks = waveTicks.map { SettingRange.waveTicks.clamp($0) }
        o.holdTicks = holdTicks.map { SettingRange.holdTicks.clamp($0) }
        o.gridColumns = gridColumns.map { SettingRange.gridColumns.clamp($0) }
        o.flipMs = flipMs.map { SettingRange.flipMs.clamp($0) }
        return o
    }
}

// MARK: - Coding

// show.json keeps cues flat, with `kind` saying which fields apply, so it
// reads and repairs by hand. Decoding is lenient about anything missing.
extension Cue: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, num, kind, line, continueMode = "continue", transition, text, sub, key, answer, src, colour, atEnd, overrides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        number = try Self.decodeNumber(c)
        line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
        continueMode = try c.decodeIfPresent(ContinueMode.self, forKey: .continueMode) ?? .whenCued
        transition = (try c.decodeIfPresent(TransitionOverrides.self, forKey: .transition) ?? .init()).clamped()

        let text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        let sub = try c.decodeIfPresent(String.self, forKey: .sub) ?? ""
        let src = try c.decodeIfPresent(String.self, forKey: .src) ?? ""

        switch try c.decode(Kind.self, forKey: .kind) {
        case .title:
            content = .title(TitleContent(
                text: text,
                sub: sub,
                key: try c.decodeIfPresent(String.self, forKey: .key) ?? "",
                overrides: (try c.decodeIfPresent(TitleOverrides.self, forKey: .overrides) ?? .init()).clamped()
            ))
        case .anagram:
            content = .anagram(AnagramContent(
                text: text,
                answer: try c.decodeIfPresent(String.self, forKey: .answer) ?? "",
                overrides: (try c.decodeIfPresent(AnagramOverrides.self, forKey: .overrides) ?? .init()).clamped()
            ))
        case .image:
            content = .image(ImageContent(
                text: text,
                src: src,
                overrides: (try c.decodeIfPresent(ImageOverrides.self, forKey: .overrides) ?? .init()).clamped()
            ))
        case .video:
            content = .video(VideoContent(
                text: text,
                sub: sub,
                src: src,
                atEnd: try c.decodeIfPresent(VideoEnd.self, forKey: .atEnd) ?? .hold
            ))
        case .blank:
            content = .blank(BlankContent(
                text: text,
                colour: try c.decodeIfPresent(RGB.self, forKey: .colour) ?? .black
            ))
        }
    }

    /// A number typed by hand as `4` rather than `"4"` is still a number.
    private static func decodeNumber(_ c: KeyedDecodingContainer<CodingKeys>) throws -> String {
        if let s = try? c.decodeIfPresent(String.self, forKey: .num) { return s }
        if let i = try? c.decodeIfPresent(Int.self, forKey: .num) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: .num) { return String(d) }
        return ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(number, forKey: .num)
        try c.encode(kind, forKey: .kind)
        try c.encode(line, forKey: .line)
        if continueMode != .whenCued { try c.encode(continueMode, forKey: .continueMode) }
        if !transition.isEmpty { try c.encode(transition, forKey: .transition) }
        try c.encode(text, forKey: .text)
        switch content {
        case .title(let t):
            try c.encode(t.sub, forKey: .sub)
            try c.encode(t.key, forKey: .key)
            if !t.overrides.isEmpty { try c.encode(t.overrides, forKey: .overrides) }
        case .anagram(let a):
            try c.encode(a.answer, forKey: .answer)
            if !a.overrides.isEmpty { try c.encode(a.overrides, forKey: .overrides) }
        case .image(let i):
            try c.encode(i.src, forKey: .src)
            if !i.overrides.isEmpty { try c.encode(i.overrides, forKey: .overrides) }
        case .video(let v):
            try c.encode(v.sub, forKey: .sub)
            try c.encode(v.src, forKey: .src)
            try c.encode(v.atEnd, forKey: .atEnd)
        case .blank(let b):
            try c.encode(b.colour, forKey: .colour)
        }
    }
}
