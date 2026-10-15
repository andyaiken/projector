import CoreGraphics
import Foundation
import Testing
@testable import ProspectCore

private func sampleShow() -> Show {
    var settings = ShowSettings()
    settings.clockMs = 30
    settings.geometry = Geometry(width: 90, height: 80, across: -5, down: 3)
    settings.projector = DisplayIdentity(uuid: "ABC-123", name: "Epson EB-L1100U", vendor: 1234, model: 5678)
    return Show(title: "The Da Vinci Code", cues: [
        Cue(number: "1", line: "LANGDON: \u{201C}\u{2026}the rose line.\u{201D}", content: .title(TitleContent(
            text: "THE LOUVRE", sub: "PARIS", key: "VITRUVIAN", overrides: TitleOverrides(holdTicks: 20, sceneLine: false)))),
        Cue(number: "2", content: .image(ImageContent(text: "THE LOUVRE", src: "media/louvre-gallery.jpg",
            overrides: ImageOverrides(gridColumns: 20, order: .random)))),
        Cue(number: "2.5", continueMode: .whenFinished,
            content: .video(VideoContent(text: "CRYPTEX", sub: "REVEAL", src: "media/cryptex-reveal.mov", atEnd: .black))),
        Cue(number: "P3", content: .blank(BlankContent(text: "WASH", colour: RGB(0x12, 0x34, 0x56)))),
    ], settings: settings)
}

@Suite("show.json")
struct ShowCodingTests {
    @Test func roundTrips() throws {
        let show = sampleShow()
        #expect(try Show(jsonData: show.jsonData()) == show)
    }

    @Test("An image cue's caption, from a show saved before they were dropped, is ignored")
    func oldImageCaptions() throws {
        let json = #"{ "num": "2", "kind": "image", "text": "THE LOUVRE", "sub": "GRAND GALLERY", "src": "" }"#
        let cue = try JSONDecoder().decode(Cue.self, from: Data(json.utf8))
        #expect(cue.text == "THE LOUVRE" && cue.sub.isEmpty)
    }

    @Test func cuesAreFlatWithOnlyTheirKindsFields() throws {
        let json = try JSONSerialization.jsonObject(with: sampleShow().jsonData()) as! [String: Any]
        #expect(json["version"] as? Int == Show.formatVersion)
        let cues = json["cues"] as! [[String: Any]]

        #expect(Set(cues[0].keys) == ["id", "num", "kind", "line", "text", "sub", "key", "overrides"])
        #expect(Set(cues[1].keys) == ["id", "num", "kind", "line", "text", "src", "overrides"], "an image cue has no caption")
        #expect(Set(cues[2].keys) == ["id", "num", "kind", "line", "continue", "text", "sub", "src", "atEnd"],
                "continue only where the cue continues")
        #expect(cues[2]["continue"] as? [String: Double] == ["finished": 0])
        #expect(Set(cues[3].keys) == ["id", "num", "kind", "line", "text", "colour"])
        #expect(cues[3]["colour"] as? String == "#123456")
        let overrides = cues[0]["overrides"] as? [String: Any] ?? [:]
        #expect(Set(overrides.keys) == ["holdTicks", "sceneLine"], "only what the cue overrides")
    }

    @Test func overridesAreOmittedWhenEmpty() throws {
        let show = Show(cues: [Cue(number: "1", content: .title(TitleContent(text: "X")))])
        let text = String(decoding: try show.jsonData(), as: UTF8.self)
        #expect(!text.contains("overrides"))
    }

    @Test func handEditedFilesAreReadLeniently() throws {
        let json = """
        {
          "title": "Repaired",
          "cues": [
            { "kind": "title", "num": 4, "text": "TEMPLE CHURCH" },
            { "kind": "blank", "num": "5", "colour": "rebeccapurple" },
            { "kind": "blank", "num": 9.5, "colour": "not a colour" },
            { "kind": "image", "num": "6", "overrides": { "gridColumns": 99, "clockMs": 1 } },
            { "kind": "video", "num": "7" }
          ],
          "settings": { "holdTicks": 500, "order": "random", "geometry": { "width": 5 } }
        }
        """
        let show = try Show(jsonData: Data(json.utf8))
        #expect(show.title == "Repaired")
        #expect(show.cues.map(\.number) == ["4", "5", "9.5", "6", "7"])
        #expect(Set(show.cues.map(\.id)).count == 5, "missing ids are generated")
        guard case .blank(let purple) = show.cues[1].content, case .blank(let junk) = show.cues[2].content,
              case .image(let image) = show.cues[3].content, case .video(let video) = show.cues[4].content else {
            Issue.record("wrong kinds")
            return
        }
        #expect(purple.colour.hex == "#663399")
        #expect(junk.colour == .black)
        #expect(image.overrides.gridColumns == 28 && image.overrides.clockMs == 18, "clamped to the slider ranges")
        #expect(video.atEnd == .hold && video.src.isEmpty)
        #expect(show.settings.holdTicks == 80)
        #expect(show.settings.order == .random)
        #expect(show.settings.clockMs == 44, "missing settings take their defaults")
        #expect(show.settings.geometry == Geometry(width: 20))
    }

    @Test func refusesNewerFormats() {
        #expect(throws: ShowFormatError.newerVersion(2)) {
            try Show(jsonData: Data(#"{ "version": 2, "cues": [] }"#.utf8))
        }
    }

    @Test func refusesUnknownKinds() {
        #expect(throws: DecodingError.self) {
            try Show(jsonData: Data(#"{ "cues": [ { "kind": "hologram", "num": "1" } ] }"#.utf8))
        }
    }
}

@Suite("Show defaults and overrides")
struct SettingsTests {
    @Test func overridesWinAndTheRestInherit() {
        var defaults = ShowSettings()
        defaults.clockMs = 30
        defaults.histogram = false

        let title = defaults.resolved(TitleOverrides(waveTicks: 7, histogram: true))
        #expect(title == TitleSettings(clockMs: 30, waveTicks: 7, holdTicks: 44, histogram: true, sceneLine: true))

        let image = defaults.resolved(ImageOverrides(holdTicks: 0, order: .random))
        #expect(image == ImageSettings(clockMs: 30, waveTicks: 3, holdTicks: 0, gridColumns: 12, flipMs: 420, order: .random))
    }

    @Test func defaultsAreTheShowsOwn() {
        let s = ShowSettings()
        let numbers: [Int] = [s.clockMs, s.waveTicks, s.holdTicks, s.textScale, s.gridColumns, s.flipMs]
        #expect(numbers == [44, 3, 44, 100, 12, 420])
        #expect(s.histogram && s.sceneLine && s.order == .diagonal)
        #expect(s.geometry == Geometry(width: 100, height: 100, across: 0, down: 0))
    }

    @Test func insetGeometryIsPercentagesOfTheOutput() {
        let output = CGSize(width: 1920, height: 1080)
        #expect(Geometry().insetRect(in: output) == CGRect(origin: .zero, size: output))
        #expect(Geometry(width: 50, height: 50).insetRect(in: output) == CGRect(x: 480, y: 270, width: 960, height: 540))
        #expect(Geometry(width: 50, height: 50, across: 10, down: -10).insetRect(in: output)
            == CGRect(x: 672, y: 162, width: 960, height: 540))
    }

    @Test func cueTimingFollowsOverrides() {
        var defaults = ShowSettings()
        defaults.clockMs = 30
        let title = Cue(content: .title(TitleContent(overrides: TitleOverrides(holdTicks: 10))))
        #expect(title.timing(defaults: defaults) == CueTiming(clockMs: 30, holdTicks: 10, isInstant: false))
        let image = Cue(content: .image(ImageContent(overrides: ImageOverrides(clockMs: 60))))
        #expect(image.timing(defaults: defaults) == CueTiming(clockMs: 60, holdTicks: 44, isInstant: false))
        #expect(Cue(content: .blank(BlankContent())).timing(defaults: defaults).isInstant)
    }

    @Test func displaysAreFoundByUUIDThenModelThenName() {
        let saved = DisplayIdentity(uuid: "U1", name: "Projector", vendor: 1, model: 2)
        let byUUID = [DisplayIdentity(uuid: "U9", name: "Projector", vendor: 1, model: 2), DisplayIdentity(uuid: "U1", name: "Renamed")]
        #expect(saved.bestMatch(in: byUUID) == 1)
        let byModel = [DisplayIdentity(uuid: "U9", name: "Built-in"), DisplayIdentity(uuid: "U8", name: "Other", vendor: 1, model: 2)]
        #expect(saved.bestMatch(in: byModel) == 1)
        let byName = [DisplayIdentity(uuid: "U9", name: "Built-in"), DisplayIdentity(uuid: "U8", name: "Projector")]
        #expect(saved.bestMatch(in: byName) == 1)
        #expect(saved.bestMatch(in: [DisplayIdentity(uuid: "U9", name: "Built-in")]) == nil)
    }
}

@Suite("Sheet problems")
struct SheetIssueTests {
    @Test func everyProblemIsFlaggedByNumber() {
        let loop = Cue(number: "7", continueMode: .whenFinished, content: .video(VideoContent(text: "LOOP", src: "media/loop.mov", atEnd: .loop)))
        let show = Show(cues: [
            Cue(number: "1", content: .blank(BlankContent())),
            Cue(number: "2", content: .video(VideoContent(text: "CLIPLESS"))),
            loop,
            Cue(number: "8", content: .title(TitleContent(text: "AFTER LOOP", key: "KEY"))),
            Cue(number: "", content: .title(TitleContent(text: "UNNUMBERED", key: "KEY"))),
            Cue(number: "2", continueMode: .after(ms: 2000), content: .blank(BlankContent())),
        ])
        let issues = show.issues
        #expect(issues == [
            .duplicateNumber("2", cues: [show.cues[1].id, show.cues[5].id]),
            .videoWithoutClip(cue: show.cues[1].id),
            .neverFinishes(cue: loop.id),
            .missingNumber(cue: show.cues[4].id),
            .continuesPastEnd(cue: show.cues[5].id),
        ])
        let messages = issues.map(show.message(for:))
        #expect(messages[0] == "Cue number 2 is used 2 times. A called number must be unambiguous.")
        #expect(messages[2] == "Cue 7 loops and never finishes, so the show won\u{2019}t continue from it by itself.")
        #expect(messages[3] == "The decryption cue \u{201C}UNNUMBERED\u{201D} has no number.")
        #expect(messages[4] == "Cue 2 is set to continue, but it is the last cue, so there is nothing to continue to.")
    }

    @Test func aCleanSheetHasNoProblems() {
        let show = Show(cues: [
            Cue(number: "1", continueMode: .whenFinished, content: .video(VideoContent(text: "CLIP", src: "media/a.mov", atEnd: .hold))),
            Cue(number: "2", content: .title(TitleContent(text: "NEXT", key: "KEY"))),
        ])
        #expect(show.issues.isEmpty)
    }

    @Test("A decryption needs text, and a key to encrypt it with")
    func unfinishedDecryptions() {
        let show = Show(cues: [
            Cue(number: "1", content: .title(TitleContent())),
            Cue(number: "2", content: .title(TitleContent(text: "THE LOUVRE"))),
            Cue(number: "", content: .title(TitleContent(key: "KEY"))),
        ])
        #expect(show.issues == [
            .decryptionWithoutPlace(cue: show.cues[0].id),
            .decryptionWithoutKey(cue: show.cues[1].id),
            .missingNumber(cue: show.cues[2].id),
            .decryptionWithoutPlace(cue: show.cues[2].id),
        ])
        #expect(show.issues.map(show.message(for:)) == [
            "Cue 1 has no text, so nothing will appear.",
            "Cue 2 has no key, so its text isn\u{2019}t encrypted.",
            "An unnumbered decryption cue has no number.",
            "An unnumbered decryption cue has no text, so nothing will appear.",
        ])
    }
}

@Suite("Tick clock")
struct TickClockTests {
    @Test func framesAreTicksNotRefreshes() {
        let clock = TickClock(start: 100, tickMs: 44, holdTicks: 44, isInstant: false)
        #expect(clock.frame(at: 100) == -44)
        #expect(clock.frame(at: 100.0439) == -44)
        #expect(clock.frame(at: 100.044) == -43)
        #expect(clock.frame(at: 100 + 0.044 * 44) == 0)
        #expect(clock.frame(at: 99) == -44, "time before the start is the first frame")
        // Refresh rate doesn't matter: sampling at 60 Hz or 120 Hz reads the same frames.
        let at60 = (0...120).map { clock.frame(at: 100 + Double($0) / 60) }
        let at120 = (0...240).map { clock.frame(at: 100 + Double($0) / 120) }
        #expect(at60.last == at120.last)
    }

    @Test func instantCuesSkipTheHold() {
        #expect(TickClock(start: 0, tickMs: 44, holdTicks: 44, isInstant: true).frame(at: 0) == 0)
        #expect(TickClock(start: 0, tickMs: 0, holdTicks: 0, isInstant: false).tickMs == 1)
    }

    @Test func nothingSettlesDuringTheHold() {
        #expect(!TickClock.hasSettled(rendererDone: true, frame: -1))
        #expect(TickClock.hasSettled(rendererDone: true, frame: 0))
        #expect(!TickClock.hasSettled(rendererDone: false, frame: 10))
    }
}
