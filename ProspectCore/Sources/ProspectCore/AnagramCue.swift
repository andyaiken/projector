import Foundation

/// One anagram on an anagram cue: the phrase that appears, any working, and
/// the answer its letters rearrange into.
public struct Anagram: Equatable, Sendable {
    /// The phrase as it first appears.
    public var text: String
    /// Steps on the way to the answer, as someone working it out might try
    /// them: partial, or wrong. Only the phrase and the answer have to be an
    /// anagram of each other.
    public var working: [String]
    /// The phrase its letters rearrange into.
    public var answer: String
    /// Left as it stands, its phrase jumbled, and skipped when the cue
    /// solves its anagrams.
    public var ignored: Bool

    public init(text: String = "", working: [String] = [], answer: String = "", ignored: Bool = false) {
        self.text = text
        self.working = working
        self.answer = answer
        self.ignored = ignored
    }

    /// What it shows, in order: the phrase, the working, then the answer.
    /// Blank ones are left out.
    public var steps: [String] {
        ([text] + working + [answer]).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// One line and nothing to move to: solved already, and shown solved.
    public var isSolvedAlready: Bool { steps.count == 1 }

    /// Whether the cue solves it on stage. One that is ignored, or solved
    /// already, stands still from the start and takes no turn.
    public var isSolvedOnStage: Bool { !ignored && steps.count > 1 }

    // MARK: The Cue tab's text box

    /// What starts the first line of an ignored anagram's paragraph.
    public static let ignoreMark: Character = "~"

    /// The anagrams as the Cue tab writes them: a paragraph each, the phrase
    /// on its first line, the answer on its last and any working between,
    /// with a blank line before the next. An ignored one starts with `~`.
    public static func paragraphs(_ anagrams: [Anagram]) -> String {
        anagrams.map { a in
            let lines = [a.text] + a.working + (a.answer.isEmpty ? [] : [a.answer])
            return (a.ignored ? "\(ignoreMark) " : "") + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// The text box read back. A paragraph of one line is an anagram solved
    /// already.
    public static func anagrams(fromParagraphs text: String) -> [Anagram] {
        var anagrams: [Anagram] = [], lines: [String] = []
        func finish() {
            guard var first = lines.first else { return }
            let ignored = first.first == ignoreMark
            if ignored { first = first.dropFirst().trimmingCharacters(in: .whitespaces) }
            anagrams.append(Anagram(text: first, working: Array(lines.dropFirst().dropLast()), answer: lines.count > 1 ? lines[lines.count - 1] : "",
                                    ignored: ignored))
            lines = []
        }
        // A Character's newline test takes \r\n as one break, not two.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { finish() } else { lines.append(trimmed) }
        }
        finish()
        return anagrams
    }
}

/// In show.json, each anagram is `{"text": …, "working": […], "answer": …}`,
/// with no working key when there is none, and `"ignored": true` only on one
/// that is.
extension Anagram: Codable {
    private enum CodingKeys: String, CodingKey {
        case text, working, answer, ignored
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        working = try c.decodeIfPresent([String].self, forKey: .working) ?? []
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        if !working.isEmpty { try c.encode(working, forKey: .working) }
        try c.encode(answer, forKey: .answer)
        if ignored { try c.encode(true, forKey: .ignored) }
    }
}

/// How an anagram cue moves on from each step to the next.
public enum AnagramAdvance: String, Codable, Sendable, CaseIterable {
    /// Each step follows a pause after the one before lands, and each
    /// anagram a pause after the one before is solved.
    case byItself = "itself"
    /// Each anagram waits for GO, the first included; its working then runs
    /// on by itself.
    case eachAnagram = "anagram"
    /// Every step waits for GO, the first included.
    case eachStep = "step"
}

/// A place partway through a cue where it waits for GO, as an anagram cue's
/// working can. GO carries the cue on rather than firing the next one.
public struct GoPoint: Equatable, Sendable {
    public enum Unit: String, Sendable {
        case anagram, step
    }

    /// What it is the GO for: an anagram's turn, or a step of one.
    public var unit: Unit
    /// What GO brings on: the anagram whose turn it is, or the step it
    /// moves to.
    public var text: String

    public init(unit: Unit, text: String) {
        self.unit = unit
        self.text = text
    }
}

extension AnagramContent {
    /// Where the cue waits for GO, in order. None when it moves on by itself.
    /// An anagram the cue doesn't solve has no turn to wait for.
    public func goPoints(_ advance: AnagramAdvance) -> [GoPoint] {
        let solved = anagrams.filter(\.isSolvedOnStage)
        return switch advance {
        case .byItself: []
        case .eachAnagram: solved.map { GoPoint(unit: .anagram, text: $0.steps[0]) }
        case .eachStep: solved.flatMap { $0.steps.dropFirst().map { GoPoint(unit: .step, text: $0) } }
        }
    }
}

extension Cue {
    /// Where this cue waits for GO partway, with the settings it runs with.
    /// Only anagram cues ever do.
    public func goPoints(defaults: ShowSettings) -> [GoPoint] {
        guard case .anagram(let c) = content else { return [] }
        return c.goPoints(defaults.resolved(c.overrides).advance)
    }
}

/// An anagram cue, worked out once when it loads: each anagram's steps as
/// they stand on stage, the moves between them, and when each move sets off.
///
/// The anagrams stand together from the start and are solved one after
/// another, but for any ignored, which keep their phrase jumbled, and any of
/// one line, solved already. Each move is an `AnagramPlan` from one step to
/// the next. Letters
/// a step of working doesn't use aren't lost: they dim, and gather on a line
/// beneath it in the order they stood, until a later step takes them up. The
/// answer takes what it needs and lets the rest fade, as a move always has.
///
/// The cue runs in parts. The first starts when the cue's hold ends; each
/// after it waits for GO, as the cue's advance says. Within a part, each move
/// sets off a pause after the one before it lands.
public struct AnagramCuePlan: Equatable, Sendable {
    /// One step as it stands on stage.
    public struct Step: Equatable, Sendable {
        /// The step's own lines, then any it leaves unused, dimmed.
        public var lines: [String]
        /// Where the dimmed lines begin: `lines.count` when there are none.
        public var dimFrom: Int

        public func isDim(_ slot: AnagramPlan.Slot) -> Bool {
            slot.line >= dimFrom
        }
    }

    /// From one step to the next.
    public struct Move: Equatable, Sendable {
        public var plan: AnagramPlan
        /// The part of the cue it belongs to.
        public var part: Int
        /// Frames after its part starts that it sets off.
        public var offset: Int
        /// Into the answer, so its letters warm to bone as they land.
        /// Working stays slate, so a wrong guess never looks solved.
        public var warms: Bool
    }

    /// One anagram.
    public struct Track: Equatable, Sendable {
        /// The phrase, each step of working, then the answer.
        public var steps: [Step]
        /// Each move goes from the step at its index to the next.
        public var moves: [Move]
        /// The phrase standing still, for an anagram the cue doesn't solve.
        public var still: AnagramPlan
        /// Solved already, so it stands in bone from the start.
        public var solvedAlready: Bool
    }

    public let tracks: [Track]
    /// The frames each part takes, from its start until its last move lands.
    /// A cue that waits for GO from the start has nothing in its first part.
    public let parts: [Int]

    /// - Parameters:
    ///   - wave: As for a single move.
    ///   - pause: Frames each step rests, landed, before the next sets off.
    ///   - random: Each move's small extra delays, drawn in order.
    public init(_ anagrams: [Anagram], wave: Int, pause: Int, advance: AnagramAdvance, random: inout some UnitRandom) {
        var tracks: [Track] = [], parts = [0], filled = [false]
        for anagram in anagrams {
            // One the cue doesn't solve shows only where it stands.
            let steps = Self.steps(anagram.isSolvedOnStage ? anagram.steps : Array(anagram.steps.prefix(1)))
            guard !steps.isEmpty else { continue }
            var moves: [Move] = []
            for k in steps.indices.dropLast() {
                let plan = AnagramPlan(fromLines: steps[k].lines, toLines: steps[k + 1].lines, wave: wave, random: &random)
                if advance == .eachStep || (advance == .eachAnagram && k == 0) {
                    parts.append(0)
                    filled.append(false)
                }
                let part = parts.count - 1
                let offset = filled[part] ? parts[part] + max(0, pause) : 0
                parts[part] = offset + plan.duration
                filled[part] = true
                moves.append(Move(plan: plan, part: part, offset: offset, warms: k + 1 == steps.count - 1))
            }
            tracks.append(Track(steps: steps, moves: moves, still: .still(steps[0].lines), solvedAlready: anagram.isSolvedAlready))
        }
        self.tracks = tracks
        self.parts = parts
    }

    /// The steps as they stand on stage. Working carries beneath it, dimmed,
    /// every letter of the step before that it doesn't use. The phrase and
    /// the answer stand alone.
    static func steps(_ texts: [String]) -> [Step] {
        var steps: [Step] = []
        for (k, text) in texts.enumerated() {
            let own = AnagramPlan.lines(text)
            guard k > 0, k < texts.count - 1 else {
                steps.append(Step(lines: own, dimFrom: own.count))
                continue
            }
            let spare = unused(by: text, from: steps[k - 1].lines)
            let dim = spare.isEmpty ? [] : AnagramPlan.lines(spare.map(String.init).joined(separator: " "))
            steps.append(Step(lines: own + dim, dimFrom: own.count))
        }
        return steps
    }

    /// The letters and digits of `lines` that `text` doesn't use, in the
    /// order they stand. A step uses the first of each letter it has, in
    /// reading order and whatever its case, as a move matches them, so these
    /// are exactly the letters a move sends to the dimmed line.
    static func unused(by text: String, from lines: [String]) -> [Character] {
        func counts(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var spare = lines.joined(separator: " ").filter(counts)
        for c in text.filter(counts) {
            if let i = spare.firstIndex(where: { $0.uppercased() == c.uppercased() }) { spare.remove(at: i) }
        }
        return Array(spare)
    }
}

extension AnagramCuePlan {
    /// When each part of a cue starts, as GO lets them go. The first starts
    /// on frame 0, when the hold ends.
    public struct Timeline: Equatable, Sendable {
        public private(set) var starts = [0]
        public let parts: [Int]

        public init(parts: [Int]) {
            self.parts = parts
        }

        /// Whether any part still waits for GO.
        public var hasPartsLeft: Bool { starts.count < parts.count }

        /// When the parts let go so far have all finished.
        private var end: Int { starts[starts.count - 1] + parts[starts.count - 1] }

        /// Done everything it can by frame `f`, with more still to come on GO.
        public func isWaiting(at f: Int) -> Bool {
            hasPartsLeft && f >= end
        }

        /// Every part has run, and the last has landed.
        public func isFinished(at f: Int) -> Bool {
            !hasPartsLeft && f >= end
        }

        /// GO on frame `f`: the next part starts then, or as soon as the part
        /// before it has finished, if that is later, so nothing jumps.
        public mutating func carryOn(at f: Int) {
            guard hasPartsLeft else { return }
            starts.append(max(f, end))
        }

        /// Every part let go, each straight after the one before, as when the
        /// cue is put up finished.
        public mutating func carryOnToEnd() {
            while hasPartsLeft { starts.append(end) }
        }

        /// The frame a move sets off; nil while its part waits for GO.
        public func start(of move: Move) -> Int? {
            starts.indices.contains(move.part) ? starts[move.part] + move.offset : nil
        }
    }

    /// Which of a track's moves is on stage on frame `f`: the latest to have
    /// set off, or the first, waiting to go. Nil for an anagram that stands
    /// still.
    public func shown(_ track: Track, at f: Int, timeline: Timeline) -> (index: Int, start: Int?)? {
        guard !track.moves.isEmpty else { return nil }
        let started = track.moves.indices.last { timeline.start(of: track.moves[$0]).map { $0 <= f } ?? false }
        let index = started ?? 0
        return (index, timeline.start(of: track.moves[index]))
    }
}
