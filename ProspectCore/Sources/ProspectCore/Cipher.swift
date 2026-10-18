/// The Vigenère machinery behind title cues.
public enum Cipher {
    public static let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// The 45-glyph ring every title character travels around: A to Z, 0 to 9,
    /// eight punctuation marks and the space.
    public static let ring: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/!?[],.- ")

    /// No glyph settles in fewer frames than this. A short shift is padded
    /// with random glyphs first.
    public static let minimumTravel = 16

    /// Drawn for a space that has not settled, so word boundaries stay hidden
    /// during the reveal. A settled space is a real gap.
    public static let spaceMark: Character = "\u{2423}"

    private static let ringPositions: [Character: Int] =
        Dictionary(uniqueKeysWithValues: ring.enumerated().map { ($1, $0) })

    static func ringPosition(_ c: Character) -> Int? {
        ringPositions[c]
    }

    static func letterIndex(_ c: Character) -> Int? {
        guard let i = ringPositions[c], i < alphabet.count else { return nil }
        return i
    }

    /// The key's shifts: upper-cased, everything but A to Z dropped. The key
    /// itself is never displayed; only its length is.
    static func shifts(forKey key: String) -> [Int] {
        key.uppercased().compactMap(letterIndex)
    }

    /// Each ring character moves forward by the next key letter's shift.
    /// Characters outside the ring pass through and do not use up a key letter.
    /// An empty key leaves the text as it is.
    public static func encrypt(_ plain: String, key: String) -> String {
        let shifts = shifts(forKey: key)
        guard !shifts.isEmpty else { return plain }
        var next = 0
        return String(plain.map { c -> Character in
            guard let p = ringPosition(c) else { return c }
            defer { next += 1 }
            return ring[(p + shifts[next % shifts.count]) % ring.count]
        })
    }

    /// The colour of a character `progress` of the way through its travel,
    /// from cold slate to bone, eased so the change gathers in the middle.
    public static func warmth(_ progress: Double) -> RGB {
        let e = progress * progress * (3 - 2 * progress)
        func mix(_ cold: UInt8, _ warm: UInt8) -> UInt8 {
            UInt8(clamping: roundHalfUp(Double(cold) + (Double(warm) - Double(cold)) * e))
        }
        return RGB(
            mix(Palette.slate.r, Palette.bone.r),
            mix(Palette.slate.g, Palette.bone.g),
            mix(Palette.slate.b, Palette.bone.b)
        )
    }
}

/// Expected English letter frequencies, for the histogram under a title.
public enum English {
    /// Percent, A to Z.
    public static let frequencies: [Double] = [
        8.2, 1.5, 2.8, 4.3, 12.7, 2.2, 2.0, 6.1, 7.0, 0.15, 0.77, 4.0, 2.4,
        6.7, 7.5, 1.9, 0.095, 6.0, 6.3, 9.1, 2.8, 0.98, 2.4, 0.15, 2.0, 0.074,
    ]

    /// Each letter's ghost bar, as a percentage of the tallest (E).
    public static let ghostHeights: [Double] = {
        let tallest = frequencies.max()!
        return frequencies.map { $0 / tallest * 100 }
    }()

    /// Chi-squared of letter counts against English. It falls as a title
    /// resolves, which is what makes the readout look like cryptanalysis.
    /// Undefined below two letters.
    public static func chiSquared(_ counts: [Int]) -> Double? {
        precondition(counts.count == 26)
        let total = counts.reduce(0, +)
        guard total >= 2 else { return nil }
        var x = 0.0
        for i in 0..<26 {
            let expected = Double(total) * frequencies[i] / 100
            let d = Double(counts[i]) - expected
            x += (d * d) / expected
        }
        return x
    }

    /// The 26 commonest pairs of neighbouring letters in English words,
    /// commonest first: one for each bar of the histogram.
    public static let digraphs = ["TH", "HE", "IN", "ER", "AN", "RE", "ON", "AT", "EN", "ND", "TI", "ES", "OR",
                                  "TE", "OF", "ED", "IS", "IT", "AL", "AR", "ST", "TO", "NT", "NG", "SE", "HA"]

    /// Percent of all pairs of neighbouring letters, from Peter Norvig's
    /// counts over the Google Books corpus.
    public static let digraphFrequencies: [Double] = [3.56, 3.07, 2.43, 2.05, 1.99, 1.85, 1.76, 1.49, 1.45, 1.35, 1.34, 1.34, 1.28,
                                                       1.20, 1.17, 1.17, 1.13, 1.12, 1.09, 1.07, 1.05, 1.04, 1.04, 0.95, 0.93, 0.93]

    /// Each digraph's ghost bar, as a percentage of the tallest (TH).
    public static let digraphGhostHeights: [Double] = digraphFrequencies.map { $0 / digraphFrequencies[0] * 100 }

    /// How often each of the 26 digraphs comes in some lines of glyphs, and
    /// how many pairs of neighbouring letters there are in all. Anything
    /// that isn't a letter, such as an unsettled space's open box, breaks a
    /// pair, so the counts give word boundaries away no sooner than the
    /// text does.
    public static func digraphCounts(_ lines: [[Character]]) -> (counts: [Int], pairs: Int) {
        var counts = [Int](repeating: 0, count: 26), pairs = 0
        for line in lines {
            for (a, b) in zip(line, line.dropFirst()) where Cipher.letterIndex(a) != nil && Cipher.letterIndex(b) != nil {
                pairs += 1
                if let i = digraphs.firstIndex(of: String(a) + String(b)) { counts[i] += 1 }
            }
        }
        return (counts, pairs)
    }
}
