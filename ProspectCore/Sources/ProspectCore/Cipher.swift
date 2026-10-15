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
}
