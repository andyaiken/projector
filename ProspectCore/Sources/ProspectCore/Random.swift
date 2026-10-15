/// A source of uniform values in `0..<1`.
///
/// The model takes one wherever it rolls dice: character start times, the
/// glyphs a character shows before it rotates, and tile order. On stage that
/// is `SystemUnitRandom`. In tests it is `SeededRandom`, which gives the same
/// sequence for the same seed, so results compare exactly.
public protocol UnitRandom {
    mutating func next() -> Double
}

extension UnitRandom {
    /// A whole number from 0 up to, but not including, `n`.
    mutating func below(_ n: Int) -> Int {
        Int((next() * Double(n)).rounded(.down))
    }
}

/// A 32-bit linear congruential generator: the same sequence for the same
/// seed, so tests can compare results exactly.
public struct SeededRandom: UnitRandom, Sendable {
    private var state: UInt32

    public init(seed: UInt32) {
        state = seed
    }

    public mutating func next() -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state) / 4_294_967_296
    }
}

/// The system's generator, for use on stage.
public struct SystemUnitRandom: UnitRandom {
    private var generator = SystemRandomNumberGenerator()

    public init() {}

    public mutating func next() -> Double {
        Double.random(in: 0..<1, using: &generator)
    }
}

/// Any source, boxed, for code that is handed its source at run time.
public struct AnyUnitRandom: UnitRandom {
    private var base: any UnitRandom

    public init(_ base: some UnitRandom) {
        self.base = base
    }

    public mutating func next() -> Double {
        base.next()
    }
}
