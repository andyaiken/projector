/// How a decryption's letters find their way home.
public enum TitleLetters: String, Codable, Sendable, CaseIterable {
    /// A burst of random glyphs, then rolling back through the ring, each in
    /// its place.
    case cycle
    /// Each on a dial, as a cryptex's letters are: it spins a full turn and
    /// its shift, slowing to settle on the letter.
    case dials
}

/// A title cue, prepared: the travel plans for the place name and the scene
/// line, and the scale the histogram is drawn against.
public struct TitleReveal: Sendable {
    public let titlePlan: TravelPlan
    public let scenePlan: TravelPlan
    /// The scene line is switched on for this cue, whether or not it has one.
    public let sceneLine: Bool
    public let histogram: Bool
    public let letters: TitleLetters
    /// The tallest letter count in the settled text. Bars are scaled against
    /// this rather than the current frame, so they don't jump as glyphs cycle.
    public let histogramScale: Int

    /// The scene line is drawn only when it is switched on and there is one.
    public var showsScene: Bool { sceneLine && !scenePlan.characters.isEmpty }

    public init(
        text: String,
        scene: String,
        key: String,
        settings: TitleSettings,
        random: inout some UnitRandom
    ) {
        // Both lines are planned even with the scene line off, which keeps
        // the random draws in the same order.
        titlePlan = TravelPlan(text: text, key: key, wave: settings.waveTicks, random: &random)
        scenePlan = TravelPlan(text: scene, key: key, wave: settings.waveTicks, random: &random)
        sceneLine = settings.sceneLine
        histogram = settings.histogram
        letters = settings.letters

        var counts = [Int](repeating: 0, count: 26)
        let settled = text.uppercased() + (settings.sceneLine ? scene.uppercased() : "")
        for c in settled {
            if let i = Cipher.letterIndex(c) { counts[i] += 1 }
        }
        histogramScale = max(counts.max()!, 1)
    }

    public init(cue: TitleContent, settings: TitleSettings, random: inout some UnitRandom) {
        self.init(text: cue.text, scene: cue.sub, key: cue.key, settings: settings, random: &random)
    }

    /// Everything the cue paints on frame `f`.
    public func frame(_ f: Int, random: inout some UnitRandom) -> TitleFrame {
        let title: [GlyphState], scene: [GlyphState]
        switch letters {
        case .cycle:
            title = titlePlan.frame(f, random: &random)
            scene = sceneLine ? scenePlan.frame(f, random: &random) : []
        case .dials:
            title = titlePlan.dials(f)
            scene = sceneLine ? scenePlan.dials(f) : []
        }

        var counts = [Int](repeating: 0, count: 26)
        for g in title + scene {
            if let i = Cipher.letterIndex(g.glyph) { counts[i] += 1 }
        }
        let bars = counts.map { min(100, Double($0) / Double(histogramScale) * 100) }

        return TitleFrame(
            title: title,
            scene: scene,
            letterCounts: counts,
            barHeights: bars,
            solved: title.count(where: \.isSettled),
            keyLength: titlePlan.keyLength,
            chiSquared: English.chiSquared(counts),
            isSettled: (title + scene).allSatisfy(\.isSettled)
        )
    }
}

/// Everything a title cue paints on one frame. Computed once per frame and
/// applied to every surface.
public struct TitleFrame: Equatable, Sendable {
    public var title: [GlyphState]
    /// Empty when the scene line is switched off.
    public var scene: [GlyphState]
    /// A to Z, counted across both lines as they currently read.
    public var letterCounts: [Int]
    /// Percent of the histogram's height, capped at 100.
    public var barHeights: [Double]
    /// Title characters that are home. The scene line doesn't count.
    public var solved: Int
    public var keyLength: Int
    public var chiSquared: Double?
    /// Every character on both lines is home.
    public var isSettled: Bool

    public var solvedText: String { "\(solved)/\(title.count)" }
    public var keyLengthText: String { keyLength > 0 ? String(keyLength) : "\u{2014}" }
    public var chiSquaredText: String { chiSquared.map { fixedDecimal($0, digits: 1) } ?? "\u{2014}" }
}
