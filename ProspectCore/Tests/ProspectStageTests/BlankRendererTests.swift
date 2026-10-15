import ProspectCore
import QuartzCore
import Testing
@testable import ProspectStage

@Suite("Blank renderer")
@MainActor
struct BlankRendererTests {
    let renderer = BlankRenderer()
    let runner: StageRunner
    let live = surface(width: 320, height: 180, geometry: Geometry(width: 50, height: 50))

    init() {
        runner = StageRunner(renderers: [.blank: renderer])
        runner.geometry = Geometry(width: 50, height: 50)
        runner.attach(live)
    }

    func blank(_ colour: RGB) -> Cue {
        Cue(number: "3", content: .blank(BlankContent(text: "WASH", colour: colour)))
    }

    @Test("A blank cue fills the picture, and only the picture, at once")
    func fillsTheInsetInstantly() {
        let cue = blank(RGB(0x12, 0x34, 0x56))
        runner.load(cue, defaults: ShowSettings(), presentation: .run, at: 0)
        #expect(!runner.isRunning, "instant: no hold, settled on its first frame")
        #expect(runner.tick(at: 0.001) == cue.id)

        let bitmap = render(live)
        let centre = bitmap.pixel(x: 160, y: 90)
        #expect(centre.r == 0x12 && centre.g == 0x34 && centre.b == 0x56)
        #expect(bitmap.isBlack(x: 10, y: 10), "outside the inset stays black")
    }

    @Test("Black by default, and cleared to black between cues")
    func clearsToBlack() {
        runner.load(blank(RGB(200, 0, 0)), defaults: ShowSettings(), presentation: .run, at: 0)
        renderer.clear(live)
        #expect(renderer.fill(for: live)?.backgroundColor == RGB.black.cgColor)
        #expect(Cue(content: .blank(BlankContent())).isInstant)
    }

    @Test("A surface mounted mid-cue shows the colour")
    func lateMount() {
        runner.load(blank(RGB(0, 80, 0)), defaults: ShowSettings(), presentation: .run, at: 0)
        let late = surface(width: 160, height: 90)
        runner.attach(late)
        #expect(renderer.fill(for: late)?.backgroundColor == RGB(0, 80, 0).cgColor)
        #expect(renderer.fill(for: late)?.isHidden == false)
    }
}
