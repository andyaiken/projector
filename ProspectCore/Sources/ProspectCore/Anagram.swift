import Foundation

/// An anagram cue, worked out once when it loads: both phrases laid out in
/// lines, which character of the first lands where in the second, and when
/// each one moves.
///
/// Characters are matched in reading order: the first A of the first phrase
/// goes to the first A of the second, and so on, so no two of the same
/// letter cross. When both phrases are the same words or numbers in a new
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
        public var character: Character
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
    /// A phrase longer than this splits into lines.
    public static let lineLength = 24

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
        fromLines = Self.lines(from)
        toLines = Self.lines(to)
        let source = Self.characters(fromLines), target = Self.characters(toLines)
        let sourceWords = Self.words(fromLines), targetWords = Self.words(toLines)
        movesWholeWords = sourceWords.count > 1 && sourceWords.map(\.text).sorted() == targetWords.map(\.text).sorted()

        // Each source character's partner in the target, if it has one.
        var partner: [Slot: Slot] = [:]
        if movesWholeWords {
            for (s, t) in Self.match(sourceWords, targetWords, by: \.text) {
                for (a, b) in zip(s.slots, t.slots) { partner[a] = b }
            }
            let inWords = Set(sourceWords.flatMap(\.slots)), inTargetWords = Set(targetWords.flatMap(\.slots))
            let others = source.filter { !inWords.contains($0.slot) }, targetOthers = target.filter { !inTargetWords.contains($0.slot) }
            for (s, t) in Self.match(others, targetOthers, by: \.character) { partner[s.slot] = t.slot }
        } else {
            for (s, t) in Self.match(source, target, by: \.character) { partner[s.slot] = t.slot }
        }

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
            Piece(character: c.character, from: c.slot, to: partner[c.slot], start: starts[leader[c.slot] ?? c.slot] ?? 0)
        }
        let landed = pieces.map { $0.start + ($0.travels ? Self.travelFrames : Self.fadeFrames) }.max() ?? 0

        // What only the second phrase has fades in as the last pieces land.
        let arrived = Set(partner.values)
        let fadeIn = max(0, landed - Self.fadeFrames)
        for c in target where !arrived.contains(c.slot) {
            pieces.append(Piece(character: c.character, from: nil, to: c.slot, start: fadeIn))
        }
        self.pieces = pieces
        duration = pieces.isEmpty ? 0 : max(landed, fadeIn + Self.fadeFrames)
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

    /// A phrase in capitals, on one line or, past `lineLength` characters,
    /// split at the space nearest the middle, and again if a half is still
    /// too long.
    public static func lines(_ phrase: String) -> [String] {
        let words = phrase.uppercased().split(whereSeparator: \.isWhitespace)
        return split(words.joined(separator: " "))
    }

    private static func split(_ line: String) -> [String] {
        guard line.count > lineLength else { return line.isEmpty ? [] : [line] }
        let characters = Array(line)
        let middle = Double(characters.count - 1) / 2
        let spaces = characters.indices.filter { characters[$0] == " " }
        guard let at = spaces.min(by: { abs(Double($0) - middle) < abs(Double($1) - middle) }) else { return [line] }
        return split(String(characters[..<at])) + split(String(characters[(at + 1)...]))
    }

    private struct Placed {
        var character: Character
        var slot: Slot
    }

    private struct Word {
        var text: String
        var slots: [Slot]
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
