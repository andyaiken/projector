import CoreText
import ProspectCore
import QuartzCore
import Testing
@testable import ProspectStage

@Suite("Title layout")
@MainActor
struct TitleLayoutTests {
    func layout(_ titleCount: Int, sceneCount: Int = 5, width: CGFloat = 1920, height: CGFloat = 1080,
                showsScene: Bool = true, histogram: Bool = true, textScale: Int = 100) -> TitleLayout {
        TitleLayout(size: CGSize(width: width, height: height), titleCount: titleCount, sceneCount: sceneCount,
                    showsScene: showsScene, histogram: histogram, textScale: textScale)
    }

    @Test("A long name is sized to 88% of the width, in 0.72 em cells")
    func longNamesFitTheWidth() {
        let l = layout(13)   // SAINT-SULPICE
        #expect(abs(CTFontGetSize(l.titleFont) - 1920 * 0.88 / (13 * 0.72)) < 1e-9)
        #expect(abs(l.titleLine.midX - 960) < 1e-9)
    }

    /// On any ordinary screen shape a name sized to the width wants 88% of
    /// it, more than the cap allows, so long names always close up a little.
    @Test("Past 90% of the padded plate, the cells close up")
    func lineIsCappedInsideThePadding() {
        let l = layout(10)   // THE LOUVRE: 1690 wanted, 90% of 1920 - 8 vmin allowed
        #expect(abs(l.titleLine.width - (1920 - 8 * 10.8) * 0.9) < 1e-9)
        #expect(abs(l.pitch - l.titleLine.width / 10) < 1e-9)
    }

    /// A reference layout, measured from a rendering: a 650 x 364.75 stage
    /// at a vmin of 7.68 px, showing THE LOUVRE / PARIS with the histogram on.
    @Test("Matches a measured reference layout")
    func matchesTheReferenceLayout() {
        let l = TitleLayout(size: CGSize(width: 650, height: 364.75), titleCount: 10, sceneCount: 5,
                            showsScene: true, histogram: true, textScale: 100, vmin: 7.68)
        // The width sets the font size here, so rounding the height to a
        // whole number wouldn't change it.
        #expect(abs(CTFontGetSize(l.titleFont) - 79.4444) < 0.001)
        let measuredCentres: [CGFloat] = [87, 140, 193, 246, 299, 351, 404, 457, 510, 563]
        for (i, measured) in measuredCentres.enumerated() {
            let centre = l.titleLine.minX + l.titleCell(i) + l.pitch / 2
            #expect(abs(centre - measured) <= 1, "cell \(i): \(centre) against \(measured)")
        }
        // The top of the title's line box.
        #expect(abs(l.titleLine.minY - 36) <= 1, "title top \(l.titleLine.minY)")
    }

    @Test("A short name is capped at 28% of the height")
    func shortNamesAreCapped() {
        #expect(abs(CTFontGetSize(layout(1).titleFont) - 1080 * 0.28) < 1e-9)
    }

    @Test("Text size scales the title, and the line never passes 90% of the width")
    func textScale() {
        #expect(abs(CTFontGetSize(layout(10, textScale: 50).titleFont) - 1920 * 0.88 / 7.2 / 2) < 1e-9)
        #expect(abs(layout(10, textScale: 130).titleLine.width - (1920 - 8 * 10.8) * 0.9) < 1e-9)
    }

    @Test("The panel sits at the bottom, and the title centres in what is left")
    func verticalLayout() {
        let with = layout(10), without = layout(10, histogram: false)
        let vmin: CGFloat = 1080 / 100
        // Bars are 15vmin tall, 3.2vmin plus the axis line above the bottom.
        #expect(abs(with.bars.height - 15 * vmin) < 1e-9)
        #expect(abs(1080 - with.axisLine.maxY - 3.2 * vmin) < 1e-9)
        #expect(with.readoutLine.minX == 4 * vmin)
        #expect(abs(with.barWidth * 26 + with.barGap * 25 - (1920 - 8 * vmin)) < 1e-9)
        // With no panel, the block centres in the full height, less padding.
        let block = without.sceneLine.maxY - without.titleLine.minY
        #expect(abs(without.titleLine.minY - (1080 - block) / 2) < 1e-9)
        #expect(with.titleLine.minY < without.titleLine.minY)
    }

    @Test("The scene line is centred, tracked out by 0.26 em")
    func sceneLine() {
        let l = layout(10, sceneCount: 5)
        let size = CTFontGetSize(l.sceneFont)
        #expect(abs(size - max(7, CTFontGetSize(l.titleFont) * 0.17)) < 1e-9)
        #expect(abs(l.scenePitch - (StageFont.advance(of: l.sceneFont) + 0.26 * size)) < 1e-9)
        #expect(abs(l.sceneLine.midX - 960) < 1e-9)
        #expect(l.sceneLine.minY > l.titleLine.maxY)
    }

    @Test("Bars are never shorter than 44 points")
    func barsHaveAFloor() {
        #expect(layout(4, width: 320, height: 180).bars.height == 44)
    }
}

@Suite("Title renderer")
@MainActor
struct TitleRendererTests {
    @Test("Every surface shows exactly the model's frame")
    func surfacesMatchTheModel() {
        let renderer = TitleRenderer(random: SeededRandom(seed: 7), reduceMotion: { true })
        let live = surface(), preview = surface(width: 640, height: 360, role: .preview)
        renderer.mount(on: live)
        renderer.mount(on: preview)
        let cue = titleCue("THE LOUVRE", sub: "PARIS", key: "VITRUVIAN")
        renderer.prepare(cue, defaults: ShowSettings())

        // The same seed, through the model alone.
        var random = SeededRandom(seed: 7)
        guard case .title(let content) = cue.content else { return }
        let reveal = TitleReveal(cue: content, settings: ShowSettings().resolved(content.overrides), random: &random)

        var f = -44
        while true {
            let expected = reveal.frame(f, random: &random)
            let settled = renderer.frame(f)
            #expect(settled == expected.isSettled)
            for s in [live, preview] {
                let t = tree(renderer, on: s)!
                #expect(text(of: t.title.runs) == String(expected.title.map(\.glyph)), "frame \(f)")
                #expect(t.title.runs.map(\.colour) == expected.title.map(\.colour.cgColor))
                #expect(text(of: t.scene.runs) == String(expected.scene.map(\.glyph)))
                let barsHeight = t.layout!.bars.height
                // Core Animation keeps geometry at slightly less than double precision.
                let heights = zip(t.bars, expected.barHeights).map { abs($0.bounds.height - barsHeight * $1 / 100) }
                #expect(heights.allSatisfy { $0 < 1e-4 }, "frame \(f) bars")
            }
            if TickClock.hasSettled(rendererDone: settled, frame: f) { break }
            f += 1
        }
        let t = tree(renderer, on: live)!
        #expect(text(of: t.title.runs) == "THE LOUVRE")
        #expect(text(of: t.readouts.runs).hasPrefix("solved10/10key length9"))
    }

    @Test("The first paint lands without animation; later bars glide")
    func firstPaintIsStill() {
        let renderer = TitleRenderer(random: SeededRandom(seed: 3), reduceMotion: { false })
        let s = surface()
        renderer.mount(on: s)
        renderer.prepare(titleCue("SAINT-SULPICE", sub: "PARIS"), defaults: ShowSettings())
        _ = renderer.frame(-44)
        let bars = tree(renderer, on: s)!.bars
        #expect(bars.allSatisfy { $0.animation(forKey: "height") == nil })
        for f in 0..<40 { _ = renderer.frame(f) }
        #expect(bars.contains { $0.animation(forKey: "height") != nil })
    }

    @Test("Reduced motion stops the bars gliding")
    func reducedMotion() {
        let renderer = TitleRenderer(random: SeededRandom(seed: 3), reduceMotion: { true })
        let s = surface()
        renderer.mount(on: s)
        renderer.prepare(titleCue("SAINT-SULPICE", sub: "PARIS"), defaults: ShowSettings())
        for f in -44..<40 { _ = renderer.frame(f) }
        #expect(tree(renderer, on: s)!.bars.allSatisfy { $0.animation(forKey: "height") == nil })
    }

    @Test("Clearing leaves nothing behind for the next cue")
    func clearWipes() {
        let renderer = TitleRenderer(random: SeededRandom(seed: 1), reduceMotion: { true })
        let s = surface()
        renderer.mount(on: s)
        renderer.prepare(titleCue("TEMPLE CHURCH", sub: "LONDON"), defaults: ShowSettings())
        for f in 0..<30 { _ = renderer.frame(f) }
        renderer.clear(s)
        let t = tree(renderer, on: s)!
        #expect(t.title.runs.isEmpty && t.scene.runs.isEmpty && t.readouts.runs.isEmpty)
        #expect(t.bars.allSatisfy { $0.bounds.height == 0 })
        #expect(renderer.frame(0), "nothing prepared counts as settled")
    }

    @Test("Per-cue overrides switch the histogram and scene line off")
    func overrides() {
        let renderer = TitleRenderer(random: SeededRandom(seed: 1), reduceMotion: { true })
        let s = surface()
        renderer.mount(on: s)
        renderer.prepare(titleCue("ROSSLYN CHAPEL", sub: "MIDLOTHIAN",
                                  overrides: TitleOverrides(histogram: false, sceneLine: false)), defaults: ShowSettings())
        _ = renderer.frame(0)
        let t = tree(renderer, on: s)!
        #expect(t.panel.isHidden)
        #expect(t.scene.isHidden && t.scene.runs.isEmpty)
    }

    @Test("Letters on dials roll through their windows, then settle alone")
    func dials() throws {
        let renderer = TitleRenderer(random: SeededRandom(seed: 5), reduceMotion: { true })
        let s = surface()
        renderer.mount(on: s)
        renderer.setVisible(true, on: s)
        renderer.prepare(titleCue("SOFIA", sub: "THE CRYPTEX", key: "APPLE", overrides: TitleOverrides(letters: .dials)),
                         defaults: ShowSettings())
        let t = try #require(tree(renderer, on: s))
        let layout = try #require(t.layout)
        #expect(abs(t.title.frame.height - layout.titleLine.height) < 1e-6 && t.title.mask != nil, "a window the height of the line")
        _ = renderer.frame(-10)
        #expect(text(of: t.title.runs).count == 5 && t.title.runs.allSatisfy { $0.dy == 0 }, "at rest, the ciphertext alone")
        _ = renderer.frame(12)
        #expect(t.title.runs.count > 5, "glyphs on their way in and out as well as letters")
        #expect(t.title.runs.contains { $0.dy > 0 } && t.title.runs.contains { $0.dy < 0 })
        render(s).save("title-dials-turning")
        _ = renderer.frame(1_000)
        #expect(text(of: t.title.runs) == "SOFIA" && t.title.runs.allSatisfy { $0.dy == 0 })
        render(s).save("title-dials-settled")
    }

    @Test("A surface mounted mid-cue shows the current frame at once")
    func lateMount() {
        let renderer = TitleRenderer(random: SeededRandom(seed: 2), reduceMotion: { true })
        let first = surface()
        renderer.mount(on: first)
        renderer.prepare(titleCue("WESTMINSTER ABBEY", sub: "LONDON"), defaults: ShowSettings())
        for f in -44..<200 { _ = renderer.frame(f) }
        let late = surface(width: 800, height: 450)
        renderer.mount(on: late)
        #expect(text(of: tree(renderer, on: late)!.title.runs) == "WESTMINSTER ABBEY")
    }

    @Test("Nothing lights the output outside the cue")
    func outputStaysBlack() {
        let renderer = TitleRenderer(random: SeededRandom(seed: 4), reduceMotion: { true })
        let s = surface(width: 960, height: 540, geometry: Geometry(width: 60, height: 60, across: 10))
        s.updateInset()
        renderer.mount(on: s)
        renderer.setVisible(true, on: s)
        renderer.prepare(titleCue("CHATEAU VILLETTE", sub: "VERSAILLES"), defaults: ShowSettings())
        _ = renderer.frame(-44)
        render(s).save("title-opening")
        for f in 0..<200 { _ = renderer.frame(f) }
        let bitmap = render(s)
        bitmap.save("title-settled")

        let inset = s.geometry.insetRect(in: s.bounds.size)
        var lit = 0, litOutside = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where !bitmap.isBlack(x: x, y: y) {
                lit += 1
                if !inset.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { litOutside += 1 }
            }
        }
        #expect(lit > 1000, "the title should have drawn something")
        #expect(litOutside == 0)
        #expect(bitmap.isBlack(x: 0, y: 0))
    }
}
