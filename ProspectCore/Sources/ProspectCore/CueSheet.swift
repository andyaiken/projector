import Foundation

/// The printed cue sheet, row by row: drawn from the same model the show
/// runs from, so the sheet can't disagree with what fires.
///
/// Two layouts. The DSM's carries cue points, for transcribing into the
/// prompt book. The operator's carries the settings each cue runs with, for
/// writing down what was dialled in on the rig and restoring it if a show is
/// ever lost.
public struct CueSheet: Equatable, Sendable {
    public enum Layout: String, CaseIterable, Sendable {
        /// Cue points, for the prompt book.
        case dsm
        /// Settings, for the projection operator. No cue points.
        case operatorSettings

        public var name: String {
            switch self {
            case .dsm: "DSM: cue points"
            case .operatorSettings: "Operator: settings"
            }
        }
    }

    public struct Setting: Equatable, Sendable {
        public var name: String
        public var value: String
        /// Set on this cue rather than taken from the show's defaults.
        public var overridden: Bool
    }

    public struct Row: Equatable, Sendable {
        /// As set: an identifier, not a position.
        public var number: String
        /// Title, Image, Video or Blank.
        public var type: String
        /// Fired by the cue before it continuing, not by GO. Printed as AUTO,
        /// so the DSM doesn't call it.
        public var auto: Bool
        /// The main line first: place and city, label and caption, or the
        /// blank's label and colour.
        public var content: [String]
        /// Empty when none is set, so the gap is obvious and gets filled in.
        public var cuePoint: String
        /// What the cue runs with. Empty in the DSM layout.
        public var settings: [Setting]
    }

    public let title: String
    public let layout: Layout
    public let rows: [Row]

    /// Whether any value on the sheet is set for its cue, so the key to the
    /// marking is worth printing.
    public var hasOverrides: Bool {
        rows.contains { $0.settings.contains(where: \.overridden) }
    }

    public init(show: Show, title: String, layout: Layout) {
        self.title = title
        self.layout = layout
        rows = show.cues.enumerated().map { i, cue in
            Row(
                number: cue.number,
                type: cue.kind.heading,
                auto: i > 0 && show.cues[i - 1].continueMode.continues,
                content: Self.content(of: cue, defaults: show.settings),
                cuePoint: layout == .dsm ? cue.line.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                settings: layout == .operatorSettings ? Self.settings(of: cue, defaults: show.settings) : []
            )
        }
    }

    private static func content(of cue: Cue, defaults: ShowSettings) -> [String] {
        let lines: [String]
        switch cue.content {
        case .title(let c): lines = [c.text, c.sub]
        case .anagram(let c): lines = anagramLines(c, advance: defaults.resolved(c.overrides).advance)
        case .image(let c): lines = [c.text]
        case .video(let c): lines = [c.text, c.sub]
        case .blank(let c): lines = [c.text, c.colour.hex.uppercased()]
        }
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Each anagram's phrase, its working after an ellipsis, and its answer
    /// after an arrow. Where the cue waits for GO partway, the line GO brings
    /// on starts GO, so the DSM can see every GO the cue takes. One the cue
    /// doesn't solve is the one line it shows, saying so.
    static func anagramLines(_ c: AnagramContent, advance: AnagramAdvance) -> [String] {
        c.anagrams.flatMap { a -> [String] in
            if a.isSolvedAlready { return [a.steps[0] + " (solved)"] }
            if a.ignored { return [(a.steps.first ?? "") + " (ignored)"] }
            let goes = a.steps.count > 1 && advance != .byItself
            let phrase = (goes && advance == .eachAnagram ? "GO " : "") + a.text
            let working = a.working.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { (goes && advance == .eachStep ? "GO " : "") + "\u{2026} " + $0 }
            let answer = a.answer.isEmpty ? "" : (goes && advance == .eachStep ? "GO " : "") + "\u{2192} " + a.answer
            return [phrase] + working + [answer]
        }
    }

    private static func settings(of cue: Cue, defaults: ShowSettings) -> [Setting] {
        func file(_ path: String, none: String) -> String { path.isEmpty ? none : (path as NSString).lastPathComponent }
        // Worded as the console words them, from the same definitions.
        func timing(_ keys: [SettingKey]) -> [Setting] {
            keys.map { key in
                let (value, overridden) = key.effective(for: cue, defaults: defaults)
                var reading = key.format(value)
                // A hold also in seconds, as the panels show it.
                let t = cue.timing(defaults: defaults)
                if key == .hold, let length = SettingKey.holdLength(holdTicks: t.holdTicks, clockMs: t.clockMs) {
                    reading += " \u{00B7} " + length
                }
                if key == .pause, case .number(let ticks) = value, let length = SettingKey.holdLength(holdTicks: ticks, clockMs: t.clockMs) {
                    reading += " \u{00B7} " + length
                }
                return Setting(name: key.label, value: reading, overridden: overridden)
            }
        }

        // Every cue's transition in, with its fade time only where it fades.
        let fades = cue.transitionIn(defaults: defaults).style == .fade
        let transition = timing(fades ? SettingKey.transitions : [.transition])

        // When the show moves on from here by itself.
        let continues = cue.continueMode.continues
            ? [Setting(name: "Continue", value: cue.continueMode.summary, overridden: false)] : []

        return own(cue, file: file, timing: timing) + transition + continues
    }

    private static func own(_ cue: Cue, file: (String, String) -> String, timing: ([SettingKey]) -> [Setting]) -> [Setting] {
        switch cue.content {
        case .title:
            return timing(SettingKey.title)
        case .anagram:
            return timing(SettingKey.anagram)
        case .image(let c):
            return timing(SettingKey.image) + [Setting(name: "Picture", value: file(c.src, "none"), overridden: false)]
        case .video(let c):
            let end = switch c.atEnd {
            case .hold: "hold the last frame"
            case .black: "cut to black"
            case .loop: "loop"
            }
            return [
                Setting(name: "At the end", value: end, overridden: false),
                Setting(name: "Clip", value: file(c.src, "none"), overridden: false),
            ]
        case .blank(let c):
            return [Setting(name: "Colour", value: c.colour.hex.uppercased(), overridden: false)]
        }
    }
}
