import Testing
@testable import ProspectCore

/// Fails the test if anything rolls a die.
struct NoDice: UnitRandom {
    mutating func next() -> Double {
        Issue.record("a dial rolled a die")
        return 0
    }
}

@Suite("Letters on dials")
struct DialTests {
    func plan(_ text: String = "SOFIA", key: String = "SANGREAL", wave: Int = 3) -> TravelPlan {
        var random = SeededRandom(seed: 9)
        return TravelPlan(text: text, key: key, wave: wave, random: &random)
    }

    @Test("Before it moves a dial shows the ciphertext; once home, the letter")
    func endsMatch() {
        let p = plan()
        let before = p.dials(-1), after = p.dials(p.duration)
        for (c, (b, a)) in zip(p.characters, zip(before, after)) {
            #expect(b.glyph == c.cipher && b.dial == Double(Cipher.ringPosition(c.cipher)!) && b.progress == 0)
            #expect(a.glyph == c.plain && a.dial == Double(Cipher.ringPosition(c.plain)!) && a.isSettled)
        }
    }

    @Test("A dial only ever turns backwards, a full turn and its shift, slowing as it goes")
    func turnsBackwards() {
        let p = plan()
        let n = Double(Cipher.ring.count)
        for (i, c) in p.characters.enumerated() {
            var turned = 0.0, steps: [Double] = []
            var last = p.dials(c.start)[i].dial!
            for f in c.start + 1...c.start + c.total {
                let now = p.dials(f)[i].dial!
                var step = last - now
                if step < 0 { step += n }
                steps.append(step)
                turned += step
                last = now
            }
            #expect(abs(turned - (Double(c.steps) + n)) < 1e-9, "\(c.plain): one turn and its shift")
            #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 >= $1 - 1e-9 }, "\(c.plain): never speeding up")
        }
    }

    @Test("Dials settle on the same frame cycling glyphs do, and roll no dice")
    func sameTimingNoDice() {
        let cycling = TitleSettings(clockMs: 44, waveTicks: 3, holdTicks: 44, histogram: true, sceneLine: true)
        var dials = cycling
        dials.letters = .dials
        var seeded = SeededRandom(seed: 4), alsoSeeded = SeededRandom(seed: 4)
        let a = TitleReveal(text: "SOFIA", scene: "THE CRYPTEX", key: "APPLE", settings: cycling, random: &seeded)
        let b = TitleReveal(text: "SOFIA", scene: "THE CRYPTEX", key: "APPLE", settings: dials, random: &alsoSeeded)
        #expect(a.titlePlan == b.titlePlan, "the same plan either way")
        var noDice = NoDice()
        for f in -5...200 {
            #expect(a.frame(f, random: &seeded).isSettled == b.frame(f, random: &noDice).isSettled, "frame \(f)")
        }
        #expect(b.frame(200, random: &noDice).title.map(\.glyph) == Array("SOFIA"))
    }

    @Test("Characters outside the ring stand still, off any dial")
    func outsideTheRing() {
        let p = plan("SOFIA\u{2019}S", key: "APPLE")
        let apostrophe = p.dials(5)[5]
        #expect(apostrophe.glyph == "\u{2019}" && apostrophe.dial == nil && apostrophe.isSettled)
    }
}
