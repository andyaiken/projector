import Foundation

/// One move of an anagram, from one step to the next, worked out once when
/// the cue loads: both laid out in lines, which character of the first lands
/// where in the second, and when each one moves. A plain anagram is one move,
/// from its phrase to its answer; `AnagramCuePlan` strings moves together.
///
/// Characters are matched in reading order, whatever their case: the first
/// A of the first phrase goes to the first A of the second, and so on, so no
/// two of the same letter cross. A letter that changes case on the way, as
/// the l of "lame" does becoming the L of "Leonardo", lands as the second
/// phrase has it. When both phrases are the same words or numbers in a new
/// order, as 13-3-2-21-1-1-8-5 and 1-1-2-3-5-8-13-21 are, each word moves
/// whole instead. A character only one phrase has, such as a comma, fades out
/// of the first or into the second.
public struct AnagramPlan: Equatable, Sendable {
    /// A character's place in a laid-out phrase.
    public struct Slot: Hashable, Sendable {
        public var line: Int
        public var column: Int

        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
    }

    /// One character on stage.
    public struct Piece: Equatable, Sendable {
        /// As the first phrase has it, or for one that fades in, the second.
        public var character: Character
        /// As the second phrase has it, where it lands.
        public var landing: Character
        /// Where it starts; nil when it fades in.
        public var from: Slot?
        /// Where it lands; nil when it fades out.
        public var to: Slot?
        /// The frame it sets off, or starts to fade.
        public var start: Int

        public var travels: Bool { from != nil && to != nil }
    }

    /// Frames each journey takes, and each fade.
    public static let travelFrames = 24
    public static let fadeFrames = 12
    /// The latest the last piece sets off, before any jitter: early enough
    /// that it has gone before the first one lands.
    static let departures = travelFrames - 4

    public let fromLines: [String]
    public let toLines: [String]
    public let pieces: [Piece]
    /// Whole words and numbers move as units, not letter by letter.
    public let movesWholeWords: Bool
    /// The frame by which everything has landed.
    public let duration: Int

    /// - Parameters:
    ///   - wave: Frames between one character, or word, setting off and the
    ///     next, in the first phrase's reading order. The departures close up
    ///     to fit within a journey, so every piece has left before the first
    ///     lands and nothing lands on a letter still waiting to go.
    ///   - random: Gives each up to two frames of extra delay.
    public init(from: String, to: String, wave: Int, random: inout some UnitRandom) {
        self.init(fromLines: Self.lines(from), toLines: Self.lines(to), wave: wave, random: &random)
    }

    /// From one set of lines to another, laid out already, as a step of
    /// working is with its unused letters on a line of their own.
    public init(fromLines: [String], toLines: [String], wave: Int, random: inout some UnitRandom) {
        self.fromLines = fromLines
        self.toLines = toLines
        let source = Self.characters(fromLines), target = Self.characters(toLines)
        let sourceWords = Self.words(fromLines), targetWords = Self.words(toLines)
        movesWholeWords = sourceWords.count > 1 && sourceWords.map(\.key).sorted() == targetWords.map(\.key).sorted()

        // Each source character's partner in the target, if it has one.
        var partner: [Slot: Slot] = [:]
        if movesWholeWords {
            for (s, t) in Self.match(sourceWords, targetWords, by: \.key) {
                for (a, b) in zip(s.slots, t.slots) { partner[a] = b }
            }
            let inWords = Set(sourceWords.flatMap(\.slots)), inTargetWords = Set(targetWords.flatMap(\.slots))
            let others = source.filter { !inWords.contains($0.slot) }, targetOthers = target.filter { !inTargetWords.contains($0.slot) }
            for (s, t) in Self.match(others, targetOthers, by: \.key) { partner[s.slot] = t.slot }
        } else {
            for (s, t) in Self.match(source, target, by: \.key) { partner[s.slot] = t.slot }
        }
        let landing = Dictionary(uniqueKeysWithValues: target.map { ($0.slot, $0.character) })

        // Everything leaves in reading order, a word at a time when words
        // move whole, otherwise a character at a time.
        var leader: [Slot: Slot] = [:]
        if movesWholeWords {
            for word in sourceWords { for slot in word.slots { leader[slot] = word.slots[0] } }
        }
        var groups: [Slot] = []
        for c in source where !groups.contains(leader[c.slot] ?? c.slot) { groups.append(leader[c.slot] ?? c.slot) }
        let spread = min(max(0, wave) * max(groups.count - 1, 0), Self.departures)
        var starts: [Slot: Int] = [:]
        for (n, key) in groups.enumerated() {
            let fraction = groups.count > 1 ? Double(n) / Double(groups.count - 1) : 0
            starts[key] = roundHalfUp(fraction * Double(spread)) + random.below(3)
        }
        var pieces = source.map { c in
            let to = partner[c.slot]
            return Piece(character: c.character, landing: to.flatMap { landing[$0] } ?? c.character, from: c.slot, to: to,
                         start: starts[leader[c.slot] ?? c.slot] ?? 0)
        }
        let landed = pieces.map { $0.start + ($0.travels ? Self.travelFrames : Self.fadeFrames) }.max() ?? 0

        // What only the second phrase has fades in as the last pieces land.
        let arrived = Set(partner.values)
        let fadeIn = max(0, landed - Self.fadeFrames)
        for c in target where !arrived.contains(c.slot) {
            pieces.append(Piece(character: c.character, landing: c.character, from: nil, to: c.slot, start: fadeIn))
        }
        self.pieces = pieces
        duration = pieces.isEmpty ? 0 : max(landed, fadeIn + Self.fadeFrames)
    }

    /// Lines standing still: every character in its place, going nowhere. An
    /// anagram with no answer yet shows its phrase this way.
    public static func still(_ lines: [String]) -> AnagramPlan {
        var none = NoDice()
        return AnagramPlan(fromLines: lines, toLines: lines, wave: 0, random: &none)
    }

    private struct NoDice: UnitRandom {
        mutating func next() -> Double { 0 }
    }

    /// How far a piece has got on frame `f`, from 0 to 1: along its journey,
    /// or through its fade.
    public func progress(of piece: Piece, at f: Int) -> Double {
        let length = piece.travels ? Self.travelFrames : Self.fadeFrames
        return min(max(Double(f - piece.start) / Double(length), 0), 1)
    }

    /// The most characters on any line of either phrase, and the most lines.
    public var columns: Int { (fromLines + toLines).map(\.count).max() ?? 0 }
    public var rows: Int { max(fromLines.count, toLines.count) }

    // MARK: Laying out

    /// A phrase as typed, its spaces closed up to one, in lines as
    /// `TextLines` splits them.
    public static func lines(_ phrase: String) -> [String] {
        let line = phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let characters = Array(line)
        return TextLines.ranges(line).map { String(characters[$0]) }
    }

    private struct Placed {
        var character: Character
        var slot: Slot
        /// What it is matched by: the same letter in either case.
        var key: String { character.uppercased() }
    }

    private struct Word {
        var text: String
        var slots: [Slot]
        var key: String { text.uppercased() }
    }

    /// Every character but the spaces, in reading order.
    private static func characters(_ lines: [String]) -> [Placed] {
        lines.enumerated().flatMap { line, text in
            text.enumerated().compactMap { column, c in
                c == " " ? nil : Placed(character: c, slot: Slot(line: line, column: column))
            }
        }
    }

    /// Runs of letters and digits, in reading order.
    private static func words(_ lines: [String]) -> [Word] {
        var words: [Word] = []
        for (line, text) in lines.enumerated() {
            var current: Word?
            for (column, c) in text.enumerated() {
                if c.isLetter || c.isNumber {
                    current = Word(text: (current?.text ?? "") + String(c), slots: (current?.slots ?? []) + [Slot(line: line, column: column)])
                } else if let word = current {
                    words.append(word)
                    current = nil
                }
            }
            if let current { words.append(current) }
        }
        return words
    }

    /// Pairs each item with the next unclaimed item of the same key, in
    /// order, so that like never crosses like.
    private static func match<T, K: Hashable>(_ source: [T], _ target: [T], by key: (T) -> K) -> [(T, T)] {
        var waiting: [K: [T]] = [:]
        for t in target { waiting[key(t), default: []].append(t) }
        var pairs: [(T, T)] = []
        for s in source {
            guard var queue = waiting[key(s)], !queue.isEmpty else { continue }
            pairs.append((s, queue.removeFirst()))
            waiting[key(s)] = queue
        }
        return pairs
    }

    /// The letters and digits one phrase has that the other lacks, each in
    /// alphabetical order. Punctuation and spaces may differ freely.
    public static func leftovers(from: String, to: String) -> (extra: String, missing: String) {
        func letters(_ s: String) -> [Character] { s.uppercased().filter { $0.isLetter || $0.isNumber }.sorted() }
        var extra: [Character] = [], spare = letters(to)
        for c in letters(from) {
            if let i = spare.firstIndex(of: c) { spare.remove(at: i) } else { extra.append(c) }
        }
        return (String(extra), String(spare))
    }
}
