/// How one character of a title travels from its ciphertext glyph home to its
/// plaintext one.
public struct Travel: Equatable, Sendable {
    public var plain: Character
    public var cipher: Character
    /// False for characters outside the ring, which stand still from the start.
    public var moves: Bool
    /// Ring positions from the ciphertext glyph back to the plaintext one.
    public var steps: Int
    /// Frames of random glyphs before rotating, so that every character moves
    /// for at least `Cipher.minimumTravel` frames.
    public var pad: Int
    /// The frame the character starts moving.
    public var start: Int

    var total: Int { pad + steps }
}

/// What one character shows on one frame.
public struct GlyphState: Equatable, Sendable {
    public var glyph: Character
    /// 0 before the character moves, 1 once it is home.
    public var progress: Double
    /// On a dial, where it stands on the ring, fractions and all: 12.5 is
    /// halfway between M and N. `glyph` is the nearest. Nil off a dial, and
    /// for characters outside the ring.
    public var dial: Double?

    init(glyph: Character, progress: Double, dial: Double? = nil) {
        self.glyph = glyph
        self.progress = progress
        self.dial = dial
    }

    public var isSettled: Bool { progress >= 1 }

    /// Settled characters are bone, which is also where the warming ends.
    public var colour: RGB { Cipher.warmth(min(progress, 1)) }
}

/// The per-character travel plan for a line of text: worked out once when the
/// cue loads, then asked for each frame.
public struct TravelPlan: Equatable, Sendable {
    public var characters: [Travel]
    /// The frame by which every moving character is home.
    public var duration: Int
    /// Letters in the cleaned key; the one thing about the key that is shown.
    public var keyLength: Int

    /// - Parameters:
    ///   - wave: Frames between one character's start and the next.
    ///   - random: Gives each character up to eight frames of extra delay.
    public init(text: String, key: String, wave: Int, random: inout some UnitRandom) {
        let plain = text.uppercased()
        let shifts = Cipher.shifts(forKey: key)
        var nextShift = 0
        var characters: [Travel] = []
        var duration = 0

        for (i, p) in plain.enumerated() {
            var travel = Travel(plain: p, cipher: p, moves: false, steps: 0, pad: 0, start: 0)
            if let position = Cipher.ringPosition(p) {
                let shift = shifts.isEmpty ? 0 : shifts[nextShift % shifts.count]
                nextShift += 1
                travel.cipher = Cipher.ring[(position + shift) % Cipher.ring.count]
                travel.moves = true
                travel.steps = shift
                travel.pad = max(0, Cipher.minimumTravel - shift)
            }
            // Every character takes a roll, moving or not, so the draws stay
            // in the same order whatever the text.
            travel.start = i * wave + random.below(9)
            if travel.moves {
                duration = max(duration, travel.start + travel.total)
            }
            characters.append(travel)
        }

        self.characters = characters
        self.duration = duration
        self.keyLength = shifts.count
    }

    /// Every character on a dial on frame `f`. A dial turns backwards a full
    /// turn and its shift, fast at first and slowing to settle on its letter,
    /// over the same frames the character would otherwise take. Nothing
    /// random: a dial passes through every glyph between.
    public func dials(_ f: Int) -> [GlyphState] {
        let n = Double(Cipher.ring.count)
        return characters.map { c in
            guard c.moves, let from = Cipher.ringPosition(c.cipher) else { return GlyphState(glyph: c.plain, progress: 1) }
            let t = f - c.start
            let x = min(max(Double(t) / Double(c.total), 0), 1)
            // Eased out, cubically: a spin that winds down.
            let left = 1 - x
            let turned = (Double(c.steps) + n) * (1 - left * left * left)
            let position = (Double(from) - turned).truncatingRemainder(dividingBy: n)
            let dial = position < 0 ? position + n : position
            let nearest = Cipher.ring[Int(dial.rounded()) % Cipher.ring.count]
            let home = t >= c.total
            return GlyphState(
                glyph: home ? c.plain : (nearest == " " ? Cipher.spaceMark : nearest),
                progress: x,
                dial: home ? Double(Cipher.ringPosition(c.plain) ?? 0) : dial
            )
        }
    }

    /// Every character's glyph on frame `f`. A character still in its padding
    /// shows a random glyph, so the frame is computed once and shared by every
    /// surface, never once per surface.
    public func frame(_ f: Int, random: inout some UnitRandom) -> [GlyphState] {
        characters.map { c in
            guard c.moves else { return GlyphState(glyph: c.plain, progress: 1) }
            let t = f - c.start
            if t >= c.total { return GlyphState(glyph: c.plain, progress: 1) }

            let glyph: Character
            if t <= 0 {
                glyph = c.cipher
            } else if t < c.pad {
                glyph = Cipher.ring[random.below(Cipher.ring.count)]
            } else {
                let n = Cipher.ring.count
                let home = Cipher.ringPosition(c.cipher)! - (t - c.pad)
                glyph = Cipher.ring[(home % n + n) % n]
            }
            return GlyphState(
                glyph: glyph == " " ? Cipher.spaceMark : glyph,
                progress: t <= 0 ? 0 : Double(t) / Double(c.total)
            )
        }
    }
}
