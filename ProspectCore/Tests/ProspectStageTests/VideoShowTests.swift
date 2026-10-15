import ProspectCore
import QuartzCore
import Testing
@testable import ProspectStage

/// Video cues through the whole show: arming ahead of GO, and continuing.
@Suite("Video in the show", .serialized)
@MainActor
struct VideoShowTests {
    let titles = TitleRenderer(reduceMotion: { true })
    let stage = surface(width: 640, height: 360)

    func controller(_ cues: [Cue]) -> ShowController {
        var settings = ShowSettings()
        settings.holdTicks = 0
        let c = ShowController(show: Show(cues: cues, settings: settings), renderers: [
            .title: titles,
            .video: VideoRenderer(media: { TestClips.folder.appendingPathComponent($0) }),
        ])
        c.runner.attach(stage)
        return c
    }

    /// Ticks the show in real time, as the display link would.
    func run(_ c: ShowController, until condition: () -> Bool, within seconds: Double = 6) async -> Bool {
        await eventually(within: seconds) {
            c.tick(at: CACurrentMediaTime())
            return condition()
        }
    }

    @Test("The video standing by is armed while the cue before it runs")
    func armsAheadOfGo() async throws {
        let clip = try await TestClips.clip("ahead.mov", seconds: 0.5)
        var video = videoCue(clip)
        video.number = "2"
        let c = controller([titleCue("THE LOUVRE"), video])
        c.go()
        #expect(c.playhead.standby == video.id)
        #expect(c.standbyArmState != nil)
        #expect(await run(c) { c.standbyArmState == .armed }, "armed before anyone presses GO")
        c.go()
        #expect(c.playhead.live == video.id)
    }

    @Test("A clip set to continue when finished fires the next cue as it ends")
    func continuesFromTheClip() async throws {
        let clip = try await TestClips.clip("handoff.mov", seconds: 0.4)
        var title = titleCue("TEMPLE CHURCH")
        title.number = "8"
        var video = videoCue(clip)
        video.continueMode = .whenFinished
        let c = controller([video, title])
        #expect(await run(c) { c.standbyArmState == .armed })
        c.go()
        #expect(c.playhead.live == video.id)
        #expect(await run(c) { c.playhead.live == title.id }, "the title came after the clip without GO")
        #expect(c.playhead.standby == nil)
    }

    @Test("A missing clip goes to black, says so, and the show still continues")
    func missingClipStillContinues() async {
        var title = titleCue("TEMPLE CHURCH")
        title.number = "8"
        var video = videoCue("media/gone.mov")
        video.continueMode = .whenFinished
        let c = controller([video, title])
        #expect(c.standbyArmState.map { if case .failed = $0 { true } else { false } } == true)
        c.go()
        #expect(c.message == "Cue 7\u{2019}s clip, gone.mov, is missing from the show, so it will go to black.")
        #expect(await run(c) { c.playhead.live == title.id })
    }

    @Test("Standby panel says nothing about cues that aren't video")
    func onlyVideoHasAnArmState() {
        let c = controller([titleCue("THE LOUVRE")])
        #expect(c.standbyArmState == nil)
    }
}
