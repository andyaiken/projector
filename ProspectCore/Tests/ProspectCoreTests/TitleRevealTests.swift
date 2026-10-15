import Testing
@testable import ProspectCore

private func expect(_ plan: TravelPlan, matches fixture: PlanFixture, _ label: String) {
    #expect(plan.duration == fixture.duration, "\(label): duration")
    #expect(plan.keyLength == fixture.keyLen, "\(label): key length")
    #expect(plan.characters.count == fixture.chars.count, "\(label): characters")
    for (travel, expected) in zip(plan.characters, fixture.chars) {
        #expect(String(travel.plain) == expected.p, "\(label): plain")
        #expect(String(travel.cipher) == expected.c, "\(label): cipher")
        #expect(travel.moves == expected.moves, "\(label): moves")
        #expect(travel.steps == expected.steps, "\(label): steps")
        #expect(travel.pad == expected.pad, "\(label): pad")
        #expect(travel.start == expected.start, "\(label): start")
    }
}

/// A painted line against recorded spans: glyphs, then colours, where
/// an empty colour means the span fell back to bone because it had settled.
private func expect(_ glyphs: [GlyphState], text: String, colours: [String], _ label: String) {
    #expect(String(glyphs.map(\.glyph)) == text, "\(label)")
    #expect(glyphs.count == colours.count, "\(label): colour count")
    for (g, colour) in zip(glyphs, colours) {
        if colour.isEmpty {
            #expect(g.isSettled && g.colour == Palette.bone, "\(label): settled glyph \(g.glyph)")
        } else {
            #expect(!g.isSettled && g.colour.hex == "#" + colour, "\(label): glyph \(g.glyph)")
        }
    }
}

@Suite("Decryption reveal, against recorded runs")
struct TitleRevealTests {
    static let plans = (try? Fixtures.load("plans", as: PlansFixture.self).plans) ?? []
    static let runs = (try? Fixtures.load("title-runs", as: TitleRunsFixture.self).runs) ?? []

    @Test func fixturesLoaded() {
        #expect(!Self.plans.isEmpty)
        #expect(!Self.runs.isEmpty)
    }

    @Test(arguments: plans)
    func travelPlan(_ c: PlansFixture.Case) {
        var random = SeededRandom(seed: c.seed)
        let plan = TravelPlan(text: c.text, key: c.key, wave: c.stagger, random: &random)
        expect(plan, matches: c.plan, c.testDescription)
    }

    /// Every frame of a whole cue, from the start of its hold until it
    /// settles, painted as the recording has it.
    @Test(arguments: runs)
    func wholeCue(_ run: TitleRunsFixture.Run) {
        let settings = TitleSettings(
            clockMs: run.settings.speed,
            waveTicks: run.settings.stagger,
            holdTicks: run.settings.hold,
            histogram: run.settings.hist,
            sceneLine: run.settings.sub
        )
        var random = SeededRandom(seed: run.seed)
        let reveal = TitleReveal(text: run.cue.text, scene: run.cue.sub, key: run.cue.key, settings: settings, random: &random)

        expect(reveal.titlePlan, matches: run.titlePlan, "title plan")
        expect(reveal.scenePlan, matches: run.subPlan, "scene plan")
        #expect(reveal.histogramScale == run.histMax)
        #expect(reveal.showsScene == run.subShown)
        #expect(reveal.histogram == run.histogramShown)

        #expect(run.frames.first?.f == -settings.holdTicks)
        for (n, expected) in run.frames.enumerated() {
            let frame = reveal.frame(expected.f, random: &random)
            let label = "frame \(expected.f)"

            expect(frame.title, text: expected.title, colours: expected.titleColours, label + " title")
            if reveal.sceneLine {
                expect(frame.scene, text: expected.sub, colours: expected.subColours, label + " scene")
            } else {
                #expect(frame.scene.isEmpty && expected.sub.isEmpty, "\(label): scene line off")
            }

            if reveal.histogram {
                #expect(frame.barHeights == expected.bars, "\(label): bars")
                #expect(frame.solvedText == expected.solved, "\(label): solved")
                #expect(frame.keyLengthText == expected.keyLength, "\(label): key length")
                #expect(frame.chiSquaredText == expected.chi, "\(label): chi-squared")
            } else {
                #expect(expected.bars.allSatisfy { $0 == 0 } && expected.chi == "\u{2014}", "\(label): histogram off")
            }

            #expect(frame.isSettled == expected.done, "\(label): done")
            let last = n == run.frames.count - 1
            #expect(TickClock.hasSettled(rendererDone: frame.isSettled, frame: expected.f) == last, "\(label): settles")
        }
    }

    @Test func unsettledSpacesShowTheMarker() {
        var random = SeededRandom(seed: 9)
        let plan = TravelPlan(text: "A B", key: "Z", wave: 0, random: &random)
        let opening = plan.frame(0, random: &random)
        #expect(!opening.contains { $0.glyph == " " })
        let settled = plan.frame(plan.duration, random: &random)
        #expect(String(settled.map(\.glyph)) == "A B")
    }
}
