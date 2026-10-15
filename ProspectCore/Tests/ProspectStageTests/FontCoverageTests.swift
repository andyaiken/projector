import CoreText
import ProspectCore
import Testing
@testable import ProspectStage

// The title reveal rotates characters in place. A glyph the font lacks is
// drawn from a fallback font of a different width, and the line shivers.
// Here every glyph is checked. Rerun after any macOS update.

@Suite("Stage font coverage")
@MainActor
struct FontCoverageTests {
    @Test("Every glyph a title can show is SF Mono's own, at one advance", arguments: [9.0, 64, 234.67, 400])
    func revealGlyphsShareOneAdvance(size: Double) {
        let coverage = StageFont.coverage(of: StageFont.revealCharacters, in: StageFont.title(size: size))
        #expect(coverage.missing.isEmpty, "No glyph for \(coverage.missing)")
        #expect(coverage.advances.count == 1, "Glyphs of different widths: \(coverage.advances.sorted())")
    }

    @Test("Readouts and the histogram axis are covered too")
    func readoutGlyphsAreCovered() {
        let coverage = StageFont.coverage(of: StageFont.readoutCharacters, in: StageFont.text(size: 24))
        #expect(coverage.missing.isEmpty, "No glyph for \(coverage.missing)")
        #expect(coverage.advances.count == 1, "Glyphs of different widths: \(coverage.advances.sorted())")
    }

    @Test("Title and text faces are monospaced, and the same width")
    func facesAreMonospaced() {
        let title = StageFont.title(size: 100), text = StageFont.text(size: 100)
        #expect(CTFontGetSymbolicTraits(title).contains(.traitMonoSpace))
        #expect(CTFontGetSymbolicTraits(text).contains(.traitMonoSpace))
        #expect(StageFont.advance(of: title) == StageFont.advance(of: text))
    }

    @Test("The ring and the space mark are what the reveal draws")
    func revealCharacters() {
        #expect(StageFont.revealCharacters.count == 46)
        #expect(StageFont.revealCharacters.last == "\u{2423}")
    }
}
