import ProspectCore
import QuartzCore
import Testing
@testable import ProspectStage

@Suite("Stage runner")
@MainActor
struct StageRunnerTests {
    let renderer = TitleRenderer(random: SeededRandom(seed: 5), reduceMotion: { true })
    let runner: StageRunner
    let live = surface()

    init() {
        runner = StageRunner(renderers: [.title: renderer])
        runner.attach(live)
    }

    @Test("A cue settles after its hold and its reveal, on the tick clock")
    func settlesOnTheClock() throws {
        var defaults = ShowSettings()
        defaults.holdTicks = 4
        let cue = titleCue("THE LOUVRE", sub: "PARIS", key: "VITRUVIAN")

        // The renderer's first draws are the plans, so the same seed gives
        // the same plans here.
        var random = SeededRandom(seed: 5)
        guard case .title(let content) = cue.content else { return }
        let reveal = TitleReveal(cue: content, settings: defaults.resolved(content.overrides), random: &random)
        let settleFrame = max(reveal.titlePlan.duration, reveal.scenePlan.duration)
        let expected = 10 + Double(settleFrame + 4) * 0.044

        runner.load(cue, defaults: defaults, presentation: .run, at: 10)
        #expect(runner.isRunning)

        // Tick at 60 Hz until it settles.
        var t = 10.0
        var settledAt: Double?
        while t < 20, settledAt == nil {
            t += 1.0 / 60
            if let id = runner.tick(at: t) {
                #expect(id == cue.id)
                settledAt = t
            }
        }
        let at = try #require(settledAt)
        #expect(at >= expected - 0.0001 && at < expected + 1.0 / 60 + 0.0001)
        #expect(!runner.isRunning)
        #expect(runner.tick(at: t + 1) == nil, "a cue settles once")
        #expect(text(of: tree(renderer, on: live)!.title.runs) == "THE LOUVRE")
    }

    @Test("The first frame is painted when the cue loads, not on the next tick")
    func paintsImmediately() {
        runner.load(titleCue("THE LOUVRE"), defaults: ShowSettings(), presentation: .run, at: 0)
        #expect(tree(renderer, on: live)!.title.runs.count == 10)
        #expect(!tree(renderer, on: live)!.root.isHidden)
    }

    @Test("A cue nothing can paint yet shows black and settles at once")
    func unpaintableKindsShowBlack() {
        runner.load(titleCue("THE LOUVRE"), defaults: ShowSettings(), presentation: .run, at: 0)
        let image = Cue(number: "2", content: .image(ImageContent(text: "THE LOUVRE")))
        runner.load(image, defaults: ShowSettings(), presentation: .run, at: 1)
        #expect(tree(renderer, on: live)!.root.isHidden)
        #expect(tree(renderer, on: live)!.title.runs.isEmpty)
        #expect(runner.tick(at: 1.01) == image.id)
    }

    @Test("Resuming puts a cue up finished, with nothing to run")
    func settledPresentation() {
        let cue = titleCue("TEMPLE CHURCH", sub: "LONDON")
        runner.load(cue, defaults: ShowSettings(), presentation: .settled, at: 0)
        #expect(!runner.isRunning)
        #expect(text(of: tree(renderer, on: live)!.title.runs) == "TEMPLE CHURCH")
        #expect(runner.tick(at: 0.01) == cue.id)
    }

    @Test("Blackout fades the picture; the output stays black")
    func blackout() {
        runner.blackout = true
        #expect(live.inset.opacity == 0)
        #expect(live.backgroundColor == CGColor(gray: 0, alpha: 1))
        let late = surface()
        runner.attach(late)
        #expect(late.inset.opacity == 0, "a surface attached during blackout is blacked out too")
        runner.blackout = false
        #expect(live.inset.opacity == 1 && late.inset.opacity == 1)
    }

    @Test("Geometry changes move the inset and refit the cue")
    func relayout() {
        runner.load(titleCue("ROSSLYN CHAPEL"), defaults: ShowSettings(), presentation: .run, at: 0)
        live.geometry = Geometry(width: 50, height: 50)
        runner.relayout(live)
        #expect(live.inset.frame == CGRect(x: 480, y: 270, width: 960, height: 540))
        #expect(tree(renderer, on: live)!.layout!.size == CGSize(width: 960, height: 540))
    }

    @Test("Detaching a surface takes its layers away")
    func detach() {
        runner.load(titleCue("THE LOUVRE"), defaults: ShowSettings(), presentation: .run, at: 0)
        runner.detach(live)
        // Only the surface's own layers remain: its curtain and its guides.
        #expect(live.inset.sublayers?.count == 2)
        #expect(live.inset.sublayers?.contains { $0 is GuidesLayer } == true)
        #expect(tree(renderer, on: live) == nil)
    }
}
