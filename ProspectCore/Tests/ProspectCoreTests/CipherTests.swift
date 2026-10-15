import Testing
@testable import ProspectCore

@Suite("Cipher, against recorded outputs")
struct CipherTests {
    let fixture: CipherFixture

    init() throws {
        fixture = try Fixtures.load("cipher")
    }

    @Test func ringAndFrequencies() {
        #expect(String(Cipher.ring) == fixture.ring)
        #expect(Cipher.ring.count == 45)
        #expect(English.frequencies == fixture.english)
        #expect(English.ghostHeights == fixture.ghostHeights)
    }

    @Test func encrypt() {
        for c in fixture.encrypt {
            #expect(Cipher.encrypt(c.plain, key: c.key) == c.cipher, "\"\(c.plain)\" with key \"\(c.key)\"")
        }
    }

    @Test func warmth() {
        for c in fixture.warmth {
            #expect(Cipher.warmth(c.t).hex == "#" + c.colour, "t = \(c.t)")
        }
        #expect(Cipher.warmth(0) == Palette.slate)
        #expect(Cipher.warmth(1) == Palette.bone)
    }

    @Test func chiSquared() {
        for c in fixture.chiSquared {
            let chi = English.chiSquared(c.counts)
            #expect(chi == c.chi, "\(c.counts)")
            #expect(chi.map { fixedDecimal($0, digits: 1) } == c.text)
        }
    }

    @Test func toFixedRoundsTiesUp() {
        for c in fixture.toFixed {
            #expect(fixedDecimal(c.value, digits: 1) == c.text, "\(c.value)")
        }
        #expect(fixedDecimal(-0.04, digits: 1) == "-0.0")
        #expect(fixedDecimal(9.96, digits: 1) == "10.0")
        #expect(fixedDecimal(2.5, digits: 0) == "3")
    }
}

@Suite("Random sources, against recorded outputs")
struct RandomTests {
    @Test func seededRandomRepeatsItsSequence() throws {
        let fixture = try Fixtures.load("random", as: RandomFixture.self)
        for sequence in fixture.lcg {
            var lcg = SeededRandom(seed: sequence.seed)
            #expect((0..<sequence.values.count).map { _ in lcg.next() } == sequence.values, "seed \(sequence.seed)")
        }
    }


    @Test func systemRandomStaysInRange() {
        var random = SystemUnitRandom()
        for _ in 0..<1000 {
            let v = random.next()
            #expect(v >= 0 && v < 1)
        }
    }
}
