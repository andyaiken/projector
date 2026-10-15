import CoreGraphics
import ProspectCore
import Testing
@testable import ProspectStage

/// The operator's keys, end to end: playhead, runner, renderer, messages.
@Suite("Show controller")
@MainActor
struct ShowControllerTests {
    final class Clock {
        var time = 100.0
    }

    let clock = Clock()
    let renderer = TitleRenderer(random: SeededRandom(seed: 11), reduceMotion: { true })
    let stage = surface()

    func controller(_ cues: [Cue], hold: Int = 2) -> ShowController {
        var settings = ShowSettings()
        settings.holdTicks = hold
        let clock = self.clock
        let c = ShowController(show: Show(title: "Test", cues: cues, settings: settings),
                               renderers: [.title: renderer], now: { clock.time })
        c.runner.attach(stage)
        return c
    }

    /// Ticks at 60 Hz until nothing needs ticking, or `limit` seconds pass.
    func runUntilIdle(_ c: ShowController, limit: Double = 30) {
        let end = clock.time + limit
        var ticking = true
        c.needsTicks = { ticking = $0 }
        repeat {
            clock.time += 1.0 / 60
            c.tick(at: clock.time)
        } while ticking && clock.time < end
    }

    func onStage() -> String {
        text(of: tree(renderer, on: stage)!.title.runs)
    }

    @Test func spaceFiresTheStandbyCueAndNothingElseDoes() {
        let c = controller([titleCue("THE LOUVRE"), titleCue("SAINT-SULPICE")])
        c.standByNext()
        c.type("1")
        c.commitEntry()
        #expect(c.playhead.live == nil)
        #expect(onStage().isEmpty, "nothing reaches the stage before GO")

        c.go()
        runUntilIdle(c)
        #expect(c.playhead.live == c.show.cues[0].id)
        #expect(onStage() == "THE LOUVRE")
    }

    @Test func theNextCueFiresWhenATitleSetToContinueWhenFinishedSettles() {
        var first = titleCue("TEMPLE CHURCH")
        first.continueMode = .whenFinished
        var second = titleCue("ROSSLYN CHAPEL")
        second.number = "2"
        let c = controller([first, second])
        c.go()
        runUntilIdle(c)
        #expect(c.playhead.live == second.id)
        #expect(onStage() == "ROSSLYN CHAPEL")
        #expect(c.playhead.standby == nil)
    }

    @Test("A timed continue fires the next cue that long after its own cue fired, settled or not")
    func timedContinue() {
        var first = titleCue("TEMPLE CHURCH")
        first.continueMode = .after(ms: 3000)
        var second = titleCue("ROSSLYN CHAPEL")
        second.number = "2"
        let c = controller([first, second])
        var firedAt: Double?
        c.onFire = { [clock] cue in if cue.id == second.id { firedAt = clock.time } }
        let goAt = clock.time
        c.go()
        runUntilIdle(c)
        #expect(c.playhead.live == second.id)
        let at = firedAt ?? 0
        #expect(at >= goAt + 3 && at < goAt + 3 + 1.0 / 30, "three seconds after GO: \(at - goAt)")
    }

    @Test("When finished, then a wait: the next cue fires that long after the cue settles")
    func waitAfterFinishing() throws {
        var first = titleCue("TEMPLE CHURCH")
        first.continueMode = .whenFinished(waitMs: 2000)
        var second = titleCue("ROSSLYN CHAPEL")
        second.number = "2"
        let c = controller([first, second])
        c.go()
        func step() {
            clock.time += 1.0 / 60
            c.tick(at: clock.time)
        }
        var settledAt: Double?
        while settledAt == nil, clock.time < 200 {
            step()
            if !c.runner.isRunning { settledAt = clock.time }
        }
        let settled = try #require(settledAt)
        while clock.time < settled + 1.9 { step() }
        #expect(c.playhead.live == first.id, "finished, and still waiting")
        while clock.time < settled + 2.05 { step() }
        #expect(c.playhead.live == second.id, "two seconds after it finished")
    }

    @Test("Resuming after a crash waits for GO, even on a cue that continues")
    func resumeWaitsForGO() {
        var first = titleCue("TEMPLE CHURCH")
        first.continueMode = .whenFinished
        var second = titleCue("ROSSLYN CHAPEL")
        second.number = "2"
        let c = controller([first, second])
        c.resume(at: first.id)
        runUntilIdle(c)
        #expect(c.playhead.live == first.id && c.playhead.standby == second.id)
    }

    @Test func anUndrawableCueSaysSoAndShowsBlack() {
        let video = Cue(number: "2", content: .video(VideoContent(text: "CRYPTEX", src: "media/cryptex.mov")))
        let c = controller([titleCue("THE LOUVRE"), video])
        c.go()
        runUntilIdle(c)
        c.go()
        #expect(c.message?.hasPrefix("Cue 2 is a video cue") == true)
        runUntilIdle(c)
        #expect(tree(renderer, on: stage)!.root.isHidden)
    }

    @Test func aMissingPictureIsReportedAndTheStageCarriesOn() {
        let image = Cue(number: "2", content: .image(ImageContent(text: "GALLERY", src: "media/gone.jpg")))
        let c = ShowController(show: Show(cues: [image, titleCue("NEXT")]),
                               renderers: [.image: ImageRenderer(), .title: renderer], now: { [clock] in clock.time })
        c.runner.attach(stage)
        c.go()
        #expect(c.message == "Cue 2\u{2019}s image, gone.jpg, is missing from the show, so it is showing its label on black.")
        #expect(c.playhead.standby == c.show.cues[1].id, "the next cue still stands by")
    }

    @Test func theDefaultsDrawEveryKindOfCue() {
        #expect(ShowController(show: Show()).runner.kinds == Set(Cue.Kind.allCases))
    }

    @Test func aVideoWithNoClipSaysSoInTheStandbyPanelByDefault() {
        let video = Cue(number: "2", content: .video(VideoContent(text: "CRYPTEX", src: "media/cryptex.mov")))
        let c = ShowController(show: Show(cues: [video]))
        guard case .failed = c.standbyArmState else {
            Issue.record("expected the default video renderer to report the missing clip, got \(String(describing: c.standbyArmState))")
            return
        }
    }

    @Test func messagesNameCuesByNumber() {
        let c = controller([titleCue("THE LOUVRE")])
        for ch in "44" { c.type(ch) }
        c.commitEntry()
        #expect(c.message == "No cue is numbered 44.")
        c.rerun()
        #expect(c.message == "Nothing is on stage yet.")
        c.go()
        runUntilIdle(c)
        c.go()
        #expect(c.message == "End of the cue sheet. Press R to run the live cue again.")
    }

    @Test func blackoutAndOpeningAnotherShow() {
        let c = controller([titleCue("THE LOUVRE")])
        c.go()
        c.toggleBlackout()
        #expect(stage.inset.opacity == 0)
        c.open(Show(title: "Other", cues: [titleCue("ELSEWHERE")]))
        #expect(stage.inset.opacity == 1, "a new show starts with blackout off")
        #expect(c.playhead.live == nil)
        #expect(tree(renderer, on: stage)!.root.isHidden)
    }

    @Test func importWarningsAndSheetProblemsAreTheOpeningMessage() {
        let dup = [titleCue("A"), titleCue("B")]   // both numbered 1
        let c = controller(dup)
        #expect(c.message == "Cue number 1 is used 2 times. A called number must be unambiguous.")
        let d = ShowController(show: Show(), warnings: ["first", "second"], renderers: [:])
        #expect(d.message == "first (and 1 more)")
    }
}

@Suite("Show and edit modes")
@MainActor
struct ModeTests {
    let preview = surface(width: 640, height: 360, role: .preview)
    let live = surface()

    func controller() -> ShowController {
        let c = ShowController(show: Show(cues: [titleCue("THE LOUVRE")]), renderers: [.title: TitleRenderer(reduceMotion: { true })])
        c.runner.attach(live)
        c.runner.attach(preview)
        return c
    }

    @Test func showsOpenInShowModeWithEverythingLocked() {
        let c = controller()
        #expect(c.mode == .show)
        c.showsGuides = true
        c.setGeometry(Geometry(width: 50))
        #expect(!c.showsGuides)
        #expect(c.show.settings.geometry == Geometry())
    }

    @Test func geometryMovesEverySurface() {
        let c = controller()
        c.enterEditMode()
        c.setGeometry(Geometry(width: 50, height: 50))
        #expect(c.show.settings.geometry == Geometry(width: 50, height: 50))
        #expect(live.inset.frame == CGRect(x: 480, y: 270, width: 960, height: 540))
        #expect(preview.inset.frame == CGRect(x: 160, y: 90, width: 320, height: 180))
    }

    @Test func guidesSwitchOffInShowMode() {
        let c = controller()
        c.enterEditMode()
        c.showsGuides = true
        #expect(live.showsGuides && preview.showsGuides)
        c.enterShowMode()
        #expect(!live.showsGuides && !preview.showsGuides)
        #expect(c.message == "Show mode. The cue sheet and settings are locked.")
    }

    @Test func guidesAreDrawnOnlyWhenOn() {
        let c = controller()
        c.enterEditMode()
        #expect(lit(render(live)) == 0, "nothing on stage yet")
        c.showsGuides = true
        #expect(lit(render(live)) > 0)
        c.enterShowMode()
        #expect(lit(render(live)) == 0)
    }

    @Test func openingAShowReturnsToShowMode() {
        let c = controller()
        c.enterEditMode()
        c.showsGuides = true
        c.open(Show(cues: [titleCue("ELSEWHERE")], settings: { var s = ShowSettings(); s.geometry = Geometry(width: 80); return s }()))
        #expect(c.mode == .show && !live.showsGuides)
        #expect(live.geometry == Geometry(width: 80))
    }

    @Test func choosingAProjectorDisplayIsAllowedInShowMode() {
        let c = controller()
        let epson = DisplayIdentity(uuid: "E", name: "EPSON PJ")
        c.setProjectorDisplay(epson)
        #expect(c.show.settings.projector == epson)
    }

    private func lit(_ bitmap: Bitmap) -> Int {
        var count = 0
        for y in stride(from: 0, to: bitmap.height, by: 1) {
            for x in stride(from: 0, to: bitmap.width, by: 1) where !bitmap.isBlack(x: x, y: y) { count += 1 }
        }
        return count
    }
}

@Suite("Standing by from the console")
@MainActor
struct ConsoleStandbyTests {
    @Test func listClicksAndTheGoToField() {
        var p12 = titleCue("PRESET")
        p12.number = "P12"
        let cues = [titleCue("THE LOUVRE"), p12]
        let c = ShowController(show: Show(cues: cues), renderers: [:])
        c.standBy(cues[1].id)
        #expect(c.playhead.standby == cues[1].id)
        c.standBy(number: " p12 ")
        #expect(c.playhead.standby == cues[1].id && c.message == nil)
        c.standBy(number: "P99")
        #expect(c.message == "No cue is numbered P99.")
        #expect(c.playhead.live == nil, "standing by never fires")
    }
}
