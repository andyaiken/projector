import CoreGraphics
import Foundation

/// A show: the cue sheet and everything that travels with it. Encoded as
/// show.json inside the `.prospect` package.
public struct Show: Equatable, Sendable {
    /// Bumped when show.json changes shape, so an old file can be migrated
    /// rather than misread.
    public static let formatVersion = 1

    /// For the window and the printed cue sheet header.
    public var title: String
    public var cues: [Cue]
    public var settings: ShowSettings

    public init(title: String = "", cues: [Cue] = [], settings: ShowSettings = .init()) {
        self.title = title
        self.cues = cues
        self.settings = settings
    }

    public func index(of id: UUID) -> Int? {
        cues.firstIndex { $0.id == id }
    }

    public subscript(id: UUID) -> Cue? {
        index(of: id).map { cues[$0] }
    }
}

public enum ShowFormatError: Error, Equatable {
    /// Written by a later version of the app. Refused rather than misread.
    case newerVersion(Int)
}

extension Show: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, title, cues, settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.formatVersion
        guard version <= Self.formatVersion else { throw ShowFormatError.newerVersion(version) }
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cues = try c.decodeIfPresent([Cue].self, forKey: .cues) ?? []
        settings = try c.decodeIfPresent(ShowSettings.self, forKey: .settings) ?? .init()
        try migrateFollows(from: c)
    }

    /// Shows saved before Continue marked the cue that fired by itself, with
    /// `follows`. That becomes Continue on the cue before it: when finished,
    /// or at once after a blank, which has nothing to finish. A looping clip
    /// keeps "when finished", which never comes, as a follow never did.
    private mutating func migrateFollows(from c: KeyedDecodingContainer<CodingKeys>) throws {
        struct Legacy: Decodable { let follows: Bool? }
        let legacy = try c.decodeIfPresent([Legacy].self, forKey: .cues) ?? []
        for (i, flag) in legacy.enumerated() where i > 0 && i < cues.count && flag.follows == true {
            guard cues[i - 1].continueMode == .whenCued else { continue }
            cues[i - 1].continueMode = cues[i - 1].kind == .blank ? .after(ms: 0) : .whenFinished
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(title, forKey: .title)
        try c.encode(cues, forKey: .cues)
        try c.encode(settings, forKey: .settings)
    }

    /// show.json as written to disk: pretty-printed with sorted keys, so a
    /// change diffs as a change.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Show.self, from: jsonData)
    }
}

// MARK: - Settings

/// The show's defaults for every per-cue setting, plus what is show-wide.
public struct ShowSettings: Equatable, Sendable {
    /// Milliseconds per frame of the cue clock.
    public var clockMs = 44
    /// Frames between successive characters, or diagonal tile steps.
    public var waveTicks = 3
    /// Frames a cue holds its opening state before it starts to resolve.
    public var holdTicks = 44
    public var histogram = true
    public var sceneLine = true
    public var letters = TitleLetters.cycle
    public var bars = TitleBars.letters
    public var gridColumns = 12
    public var flipMs = 420
    public var order = TileOrder.diagonal
    public var reveal = TileReveal.flip
    /// The font family anagram letters are set in. Empty is the stage's own
    /// type, SF Mono.
    public var anagramFont = ""
    /// How the stage changes to each cue, and how long each fade takes.
    public var transition = Transition.standard.style
    public var fadeMs = Transition.standard.fadeMs

    /// Title text size, percent. Show-wide.
    public var textScale = 100
    /// Show-wide.
    public var geometry = Geometry()
    /// The display the projector window last ran on.
    public var projector: DisplayIdentity?

    public init() {}

    public func resolved(_ o: TitleOverrides) -> TitleSettings {
        TitleSettings(
            clockMs: o.clockMs ?? clockMs,
            waveTicks: o.waveTicks ?? waveTicks,
            holdTicks: o.holdTicks ?? holdTicks,
            histogram: o.histogram ?? histogram,
            sceneLine: o.sceneLine ?? sceneLine,
            letters: o.letters ?? letters,
            bars: o.bars ?? bars
        )
    }

    public func resolved(_ o: AnagramOverrides) -> AnagramSettings {
        AnagramSettings(clockMs: o.clockMs ?? clockMs, waveTicks: o.waveTicks ?? waveTicks, holdTicks: o.holdTicks ?? holdTicks,
                        font: o.font ?? anagramFont)
    }

    public func resolved(_ o: ImageOverrides) -> ImageSettings {
        ImageSettings(
            clockMs: o.clockMs ?? clockMs,
            waveTicks: o.waveTicks ?? waveTicks,
            holdTicks: o.holdTicks ?? holdTicks,
            gridColumns: o.gridColumns ?? gridColumns,
            flipMs: o.flipMs ?? flipMs,
            order: o.order ?? order,
            reveal: o.reveal ?? reveal
        )
    }
}

/// The settings a title cue runs with, once its overrides are applied.
public struct TitleSettings: Equatable, Sendable {
    public var clockMs: Int
    public var waveTicks: Int
    public var holdTicks: Int
    public var histogram: Bool
    public var sceneLine: Bool
    public var letters: TitleLetters
    public var bars: TitleBars

    public init(clockMs: Int, waveTicks: Int, holdTicks: Int, histogram: Bool, sceneLine: Bool, letters: TitleLetters = .cycle,
                bars: TitleBars = .letters) {
        self.clockMs = clockMs
        self.waveTicks = waveTicks
        self.holdTicks = holdTicks
        self.histogram = histogram
        self.sceneLine = sceneLine
        self.letters = letters
        self.bars = bars
    }
}

/// The settings an anagram cue runs with, once its overrides are applied.
public struct AnagramSettings: Equatable, Sendable {
    public var clockMs: Int
    public var waveTicks: Int
    public var holdTicks: Int
    /// A font family's name. Empty is the stage's own type.
    public var font: String

    public init(clockMs: Int, waveTicks: Int, holdTicks: Int, font: String = "") {
        self.clockMs = clockMs
        self.waveTicks = waveTicks
        self.holdTicks = holdTicks
        self.font = font
    }
}

/// The settings an image cue runs with, once its overrides are applied.
public struct ImageSettings: Equatable, Sendable {
    public var clockMs: Int
    public var waveTicks: Int
    public var holdTicks: Int
    public var gridColumns: Int
    public var flipMs: Int
    public var order: TileOrder
    public var reveal: TileReveal

    public init(clockMs: Int, waveTicks: Int, holdTicks: Int, gridColumns: Int, flipMs: Int, order: TileOrder, reveal: TileReveal = .flip) {
        self.clockMs = clockMs
        self.waveTicks = waveTicks
        self.holdTicks = holdTicks
        self.gridColumns = gridColumns
        self.flipMs = flipMs
        self.order = order
        self.reveal = reveal
    }
}

/// How a cue's clock runs: the tick length, and how many ticks it holds its
/// opening state before resolving.
public struct CueTiming: Equatable, Sendable {
    public var clockMs: Int
    public var holdTicks: Int
    /// Nothing to resolve, so no hold.
    public var isInstant: Bool
}

extension Cue {
    public func timing(defaults: ShowSettings) -> CueTiming {
        switch content {
        case .title(let c):
            let s = defaults.resolved(c.overrides)
            return CueTiming(clockMs: s.clockMs, holdTicks: s.holdTicks, isInstant: false)
        case .anagram(let c):
            let s = defaults.resolved(c.overrides)
            return CueTiming(clockMs: s.clockMs, holdTicks: s.holdTicks, isInstant: false)
        case .image(let c):
            let s = defaults.resolved(c.overrides)
            return CueTiming(clockMs: s.clockMs, holdTicks: s.holdTicks, isInstant: false)
        case .video, .blank:
            // A video plays on its own clock from GO, and a blank is instant.
            return CueTiming(clockMs: defaults.clockMs, holdTicks: 0, isInstant: true)
        }
    }
}

/// The ranges the sliders allow. Values from a file are clamped to them.
public enum SettingRange {
    public static let clockMs = 18...110
    public static let waveTicks = 0...10
    public static let holdTicks = 0...80
    public static let textScale = 40...130
    public static let gridColumns = 4...28
    public static let flipMs = 150...1200
    public static let fadeMs = 100...3000
    public static let geometrySize = 20...100
    public static let geometryOffset = -40...40
}

extension ClosedRange where Bound == Int {
    func clamp(_ v: Int) -> Int { Swift.min(Swift.max(v, lowerBound), upperBound) }
}

extension ShowSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case clockMs, waveTicks, holdTicks, histogram, sceneLine, letters, bars, gridColumns, flipMs, order
        case reveal, anagramFont, transition, fadeMs, textScale, geometry, projector
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShowSettings()
        func int(_ key: CodingKeys, _ fallback: Int, _ range: ClosedRange<Int>) throws -> Int {
            range.clamp(try c.decodeIfPresent(Int.self, forKey: key) ?? fallback)
        }
        clockMs = try int(.clockMs, d.clockMs, SettingRange.clockMs)
        waveTicks = try int(.waveTicks, d.waveTicks, SettingRange.waveTicks)
        holdTicks = try int(.holdTicks, d.holdTicks, SettingRange.holdTicks)
        histogram = try c.decodeIfPresent(Bool.self, forKey: .histogram) ?? d.histogram
        sceneLine = try c.decodeIfPresent(Bool.self, forKey: .sceneLine) ?? d.sceneLine
        letters = try c.decodeIfPresent(TitleLetters.self, forKey: .letters) ?? d.letters
        bars = try c.decodeIfPresent(TitleBars.self, forKey: .bars) ?? d.bars
        gridColumns = try int(.gridColumns, d.gridColumns, SettingRange.gridColumns)
        flipMs = try int(.flipMs, d.flipMs, SettingRange.flipMs)
        order = try c.decodeIfPresent(TileOrder.self, forKey: .order) ?? d.order
        reveal = try c.decodeIfPresent(TileReveal.self, forKey: .reveal) ?? d.reveal
        anagramFont = try c.decodeIfPresent(String.self, forKey: .anagramFont) ?? d.anagramFont
        transition = try c.decodeIfPresent(TransitionStyle.self, forKey: .transition) ?? d.transition
        fadeMs = try int(.fadeMs, d.fadeMs, SettingRange.fadeMs)
        textScale = try int(.textScale, d.textScale, SettingRange.textScale)
        geometry = try c.decodeIfPresent(Geometry.self, forKey: .geometry) ?? d.geometry
        projector = try c.decodeIfPresent(DisplayIdentity.self, forKey: .projector)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clockMs, forKey: .clockMs)
        try c.encode(waveTicks, forKey: .waveTicks)
        try c.encode(holdTicks, forKey: .holdTicks)
        try c.encode(histogram, forKey: .histogram)
        try c.encode(sceneLine, forKey: .sceneLine)
        try c.encode(letters, forKey: .letters)
        try c.encode(bars, forKey: .bars)
        try c.encode(gridColumns, forKey: .gridColumns)
        try c.encode(flipMs, forKey: .flipMs)
        try c.encode(order, forKey: .order)
        try c.encode(reveal, forKey: .reveal)
        try c.encode(anagramFont, forKey: .anagramFont)
        try c.encode(transition, forKey: .transition)
        try c.encode(fadeMs, forKey: .fadeMs)
        try c.encode(textScale, forKey: .textScale)
        try c.encode(geometry, forKey: .geometry)
        try c.encodeIfPresent(projector, forKey: .projector)
    }
}

/// Where the picture lands within the projector output, as percentages of
/// it, so it holds if the resolution changes.
public struct Geometry: Equatable, Sendable {
    public var width = 100
    public var height = 100
    /// Offset from centre; positive is right.
    public var across = 0
    /// Offset from centre; positive is down.
    public var down = 0

    public init(width: Int = 100, height: Int = 100, across: Int = 0, down: Int = 0) {
        self.width = width
        self.height = height
        self.across = across
        self.down = down
    }
}

extension Geometry {
    /// The part of an output of `size` the picture lands on, with a top-left
    /// origin: centred, then offset, all in percentages of the output.
    public func insetRect(in size: CGSize) -> CGRect {
        let w = CGFloat(width) / 100, h = CGFloat(height) / 100
        return CGRect(
            x: ((1 - w) / 2 + CGFloat(across) / 100) * size.width,
            y: ((1 - h) / 2 + CGFloat(down) / 100) * size.height,
            width: w * size.width,
            height: h * size.height
        )
    }
}

extension Geometry: Codable {
    private enum CodingKeys: String, CodingKey { case width, height, across, down }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = SettingRange.geometrySize.clamp(try c.decodeIfPresent(Int.self, forKey: .width) ?? 100)
        height = SettingRange.geometrySize.clamp(try c.decodeIfPresent(Int.self, forKey: .height) ?? 100)
        across = SettingRange.geometryOffset.clamp(try c.decodeIfPresent(Int.self, forKey: .across) ?? 0)
        down = SettingRange.geometryOffset.clamp(try c.decodeIfPresent(Int.self, forKey: .down) ?? 0)
    }
}

/// Enough about a display to find it again. `CGDirectDisplayID` is not
/// stored, because it can change when a cable is replugged.
public struct DisplayIdentity: Codable, Equatable, Sendable {
    /// From `CGDisplayCreateUUIDFromDisplayID`.
    public var uuid: String?
    public var name: String
    public var vendor: UInt32?
    public var model: UInt32?

    public init(uuid: String? = nil, name: String, vendor: UInt32? = nil, model: UInt32? = nil) {
        self.uuid = uuid
        self.name = name
        self.vendor = vendor
        self.model = model
    }

    /// The connected display that is this one: the same UUID, failing that
    /// the same vendor and model, failing that the same name.
    public func bestMatch(in candidates: [DisplayIdentity]) -> Int? {
        if let uuid, let i = candidates.firstIndex(where: { $0.uuid == uuid }) { return i }
        if let vendor, let model,
           let i = candidates.firstIndex(where: { $0.vendor == vendor && $0.model == model }) { return i }
        return candidates.firstIndex { $0.name == name }
    }
}
