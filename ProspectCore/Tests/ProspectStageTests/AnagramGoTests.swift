import ProspectCore
import Testing
@testable import ProspectStage

/// An anagram cue that waits for GO partway, end to end: playhead, runner,
/// renderer and the clock.
@Suite("Anagram cues on GO")
@MainActor
struct AnagramGoTests {
    final class Clock {
        var time = 100.0
    }

    let clock = Clock()
    let anagrams = AnagramRenderer(random: SeededRandom(seed: 5))
    let titles = TitleRenderer(random: SeededRandom(seed: 11), reduceMotion: { true })
    let stage = surface()

    func controller(_ cues: [Cue]) -> ShowController {
        var settings = ShowSettings()
        settings.holdTicks = 2
        settings.transition = .snap
        let clock = self.clock
        let c = ShowController(show: Show(title: "Test", cues: cues, settings: settings),
                               renderers: [.anagram: anagrams, .title: titles], now: { clock.time })
        c.runner.attach(stage)
        return c
    }

    /// Ticks at 60 Hz until nothing needs ticking, or `limit` seconds pass.
    /// Returns whether the clock came to rest.
    @discardableResult
    func runUntilIdle(_ c: ShowController, limit: Double = 30) -> Bool {
        let end = clock.time + limit
        var ticking = true
        c.needsTicks = { ticking = $0 }
        repeat {
            clock.time += 1.0 / 60
            c.tick(at: clock.time)
        } while ticking && clock.time < end
        return !ticking
    }

    func stepped(_ number: String, continues: ContinueMode = .whenCued) -> Cue {
        Cue(number: number, continueMode: continues, content: .anagram(AnagramContent(
            anagrams: [Anagram(text: "RATS", working: ["TSAR"], answer: "STAR")],
            overrides: AnagramOverrides(advance: .eachStep))))
    }

    @Test("Space carries a waiting cue on, step by step, and fires the next cue only after its last")
    func spaceCarriesOn() {
        let c = controller([stepped("1"), titleCue("NEXT")])
        let anagram = c.show.cues[0].id, next = c.show.cues[1].id
        c.go()
        #expect(runUntilIdle(c), "waiting for GO, the clock rests")
        #expect(c.standingByGoPoint == ShowController.StandingByGoPoint(cue: c.show.cues[0], point: GoPoint(unit: .step, text: "TSAR"),
                                                                        number: 1, count: 2))
        #expect(c.standingByCue?.id == anagram && c.playhead.standby == next)
        #expect(anagrams.moveShown(0) == nil, "nothing has moved")

        c.go()
        #expect(c.playhead.live == anagram, "the same cue, carried on")
        #expect(runUntilIdle(c))
        #expect(anagrams.moveShown(0) == 0 && c.standingByGoPoint?.number == 2)

        c.go()
        #expect(runUntilIdle(c))
        #expect(anagrams.moveShown(0) == 1 && c.standingByGoPoint == nil)
        #expect(c.standingByCue?.id == next)
        c.go()
        #expect(c.playhead.live == next)
    }

    @Test("→ skips the rest of the working to fire the next cue")
    func skipAhead() {
        let c = controller([stepped("1"), titleCue("NEXT")])
        c.go()
        runUntilIdle(c)
        c.standByNext()
        #expect(c.standingByGoPoint == nil)
        c.go()
        #expect(c.playhead.live == c.show.cues[1].id)
    }

    @Test("A cue set to continue when finished continues only once its last GO has run")
    func continuesWhenFinished() {
        let c = controller([stepped("1", continues: .whenFinished), titleCue("NEXT")])
        c.go()
        runUntilIdle(c)
        #expect(c.playhead.live == c.show.cues[0].id, "waiting isn't finishing")
        c.go()
        runUntilIdle(c)
        #expect(c.playhead.live == c.show.cues[0].id)
        c.go()
        runUntilIdle(c)
        #expect(c.playhead.live == c.show.cues[1].id, "on by itself once the answer lands")
    }

    @Test("Edited on stage, the cue shows finished and waits for no more GOs; R brings them back")
    func editAndRerun() {
        let c = controller([stepped("1"), titleCue("NEXT")])
        c.enterEditMode()
        c.go()
        runUntilIdle(c)
        c.updateCue(c.show.cues[0].id, "Change Number") { $0.number = "1.1" }
        #expect(c.standingByGoPoint == nil && anagrams.moveShown(0) == 1)
        c.rerun()
        #expect(c.standingByGoPoint?.number == 1)
    }
}

extension AnagramRenderer {
    /// The move anagram `t` shows at the frame last painted: nil before its
    /// first sets off.
    func moveShown(_ t: Int) -> Int? {
        guard let f = lastFrame, let shown = shown(t, at: f), shown.start.map({ $0 <= f }) == true else { return nil }
        return shown.move
    }
}
