import Testing
@testable import ProspectCore

@Suite("Cue sheet rows")
struct CueSheetTests {
    let show: Show = {
        var settings = ShowSettings()
        settings.holdTicks = 0
        return Show(title: "The Da Vinci Code", cues: [
            Cue(number: "1", line: "LANGDON: \u{201C}\u{2026}the rose line.\u{201D}",
                content: .title(TitleContent(text: "THE LOUVRE", sub: "PARIS", key: "VITRUVIAN", overrides: TitleOverrides(clockMs: 30)))),
            Cue(number: "2", continueMode: .whenFinished, content: .image(ImageContent(text: "THE LOUVRE", src: "media/gallery.jpg",
                                                         overrides: ImageOverrides(gridColumns: 20, order: .random)))),
            Cue(number: "2.5", content: .video(VideoContent(text: "CRYPTEX", sub: "", src: "", atEnd: .black))),
            Cue(number: "P3", line: "   ", transition: TransitionOverrides(style: .snap),
                content: .blank(BlankContent(text: "BLANK", colour: RGB(0x12, 0xab, 0x56)))),
        ], settings: settings)
    }()

    @Test("The DSM's layout: number, type, content and cue point, in running order")
    func dsm() {
        let sheet = CueSheet(show: show, title: "The Da Vinci Code", layout: .dsm)
        #expect(sheet.rows.map(\.number) == ["1", "2", "2.5", "P3"])
        #expect(sheet.rows.map(\.type) == ["Decryption", "Image", "Video", "Blank"])
        #expect(sheet.rows[0].content == ["THE LOUVRE", "PARIS"])
        #expect(sheet.rows[2].content == ["CRYPTEX"], "an empty caption leaves no blank line")
        #expect(sheet.rows[3].content == ["BLANK", "#12AB56"], "a blank shows its colour")
        #expect(sheet.rows[0].cuePoint.hasPrefix("LANGDON"))
        #expect(sheet.rows[1].cuePoint == "", "no cue point prints an empty cell, not a dash")
        #expect(sheet.rows[3].cuePoint == "", "blank space counts as none")
        #expect(sheet.rows.allSatisfy { $0.settings.isEmpty })
    }

    @Test("A cue the one before it continues into is marked AUTO, so it isn't called")
    func auto() {
        let rows = CueSheet(show: show, title: "", layout: .dsm).rows
        #expect(rows.map(\.auto) == [false, false, true, false])
    }

    @Test("The operator's layout: the settings each cue runs with, overrides marked, no cue points")
    func operatorLayout() {
        let sheet = CueSheet(show: show, title: "", layout: .operatorSettings)
        #expect(sheet.rows.allSatisfy { $0.cuePoint.isEmpty })
        let title = sheet.rows[0].settings
        // In the console's order: Clock, Wave, Hold.
        #expect(title.map(\.name) == ["Clock", "Wave", "Hold", "Histogram", "Subtext", "Transition", "Fade"])
        #expect(title.map(\.value) == ["30 ms", "3", "none", "on", "on", "fade through black", "0.5 s"])
        #expect(title.map(\.overridden) == [true, false, false, false, false, false, false])
        let image = sheet.rows[1].settings
        #expect(image.map(\.name) == ["Clock", "Wave", "Hold", "Grid", "Flip", "Order", "Reveal by", "Picture", "Transition", "Fade", "Continue"])
        #expect(image.last == .init(name: "Continue", value: "when finished", overridden: false))
        #expect(image.first { $0.name == "Grid" } == .init(name: "Grid", value: "20 wide", overridden: true))
        #expect(image.first { $0.name == "Order" }?.value == "random")
        #expect(image.first { $0.name == "Picture" }?.value == "gallery.jpg")
        #expect(sheet.rows[2].settings.map(\.value) == ["cut to black", "none", "fade through black", "0.5 s"])
        // A snap has no fade time to print, and is marked as the cue's own.
        #expect(sheet.rows[3].settings == [.init(name: "Colour", value: "#12AB56", overridden: false),
                                           .init(name: "Transition", value: "snap", overridden: true)])
        #expect(sheet.hasOverrides)
        #expect(!CueSheet(show: Show(cues: [Cue(content: .blank(BlankContent()))]), title: "", layout: .operatorSettings).hasOverrides)
    }
}
