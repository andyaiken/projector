import Foundation
import Testing
@testable import ProspectCore

@Suite("Setting keys")
struct SettingKeyTests {
    @Test("Every setting reads and writes the show's default")
    func defaults() {
        var s = ShowSettings()
        let values: [SettingKey: SettingValue] = [
            .clock: .number(30), .wave: .number(5), .hold: .number(10), .textScale: .number(80),
            .histogram: .flag(false), .sceneLine: .flag(false), .grid: .number(20), .flip: .number(600), .order: .order(.random),
        ]
        for (key, value) in values { key.set(value, in: &s) }
        for (key, value) in values { #expect(key.value(in: s) == value, "\(key)") }
        #expect(s.clockMs == 30 && s.gridColumns == 20 && s.order == .random)
    }

    @Test("Values snap to the slider's range and step")
    func snapping() {
        #expect(SettingKey.clock.snapped(.number(31)) == .number(32), "18, 20 ... 30, 32")
        #expect(SettingKey.clock.snapped(.number(500)) == .number(110))
        #expect(SettingKey.flip.snapped(.number(400)) == .number(390), "150, 180 ... 390, 420")
        #expect(SettingKey.grid.snapped(.number(2)) == .number(4))
        #expect(SettingKey.histogram.snapped(.flag(true)) == .flag(true))
    }

    @Test("A title cue overrides its timing and title settings, and can be put back")
    func titleOverrides() {
        var cue = Cue(content: .title(TitleContent(text: "THE LOUVRE")))
        var defaults = ShowSettings()
        defaults.holdTicks = 20
        #expect(SettingKey.hold.effective(for: cue, defaults: defaults) == (.number(20), false))

        SettingKey.hold.setOverride(.number(4), in: &cue)
        SettingKey.sceneLine.setOverride(.flag(false), in: &cue)
        SettingKey.grid.setOverride(.number(20), in: &cue)
        #expect(SettingKey.hold.effective(for: cue, defaults: defaults) == (.number(4), true))
        #expect(SettingKey.sceneLine.override(in: cue) == .flag(false))
        #expect(SettingKey.grid.override(in: cue) == nil, "a title has no grid")
        guard case .title(let c) = cue.content else { return }
        #expect(c.overrides == TitleOverrides(holdTicks: 4, sceneLine: false))

        SettingKey.hold.setOverride(nil, in: &cue)
        #expect(SettingKey.hold.effective(for: cue, defaults: defaults) == (.number(20), false))
    }

    @Test("An image cue overrides its timing and grid settings")
    func imageOverrides() {
        var cue = Cue(content: .image(ImageContent(text: "GALLERY")))
        SettingKey.order.setOverride(.order(.random), in: &cue)
        SettingKey.flip.setOverride(.number(605), in: &cue)
        SettingKey.histogram.setOverride(.flag(false), in: &cue)
        guard case .image(let c) = cue.content else { return }
        #expect(c.overrides == ImageOverrides(flipMs: 600, order: .random), "snapped, and no histogram on an image")
    }

    @Test("Which settings apply to which cues")
    func applicability() {
        #expect(SettingKey.allCases.filter { $0.applies(to: .title) } == [.clock, .wave, .hold, .histogram, .sceneLine, .letters, .bars, .transition, .fade])
        #expect(SettingKey.allCases.filter { $0.applies(to: .image) } == [.clock, .wave, .hold, .grid, .flip, .order, .reveal, .transition, .fade])
        #expect(SettingKey.allCases.filter { $0.applies(to: .video) } == [.transition, .fade], "every cue has a transition in")
        #expect(SettingKey.allCases.filter { $0.applies(to: .blank) } == [.transition, .fade])
        #expect(SettingKey.groups.flatMap(\.keys) == SettingKey.allCases, "the panels show every setting once")
    }

    @Test("Values read as the console writes them")
    func formatting() {
        #expect(SettingKey.clock.format(.number(44)) == "44 ms")
        #expect(SettingKey.hold.format(.number(0)) == "none")
        #expect(SettingKey.textScale.format(.number(100)) == "100%")
        #expect(SettingKey.grid.format(.number(12)) == "12 wide")
        #expect(SettingKey.histogram.format(.flag(true)) == "on")
        #expect(SettingKey.order.format(.order(.diagonal)) == "diagonal sweep")
        #expect(SettingKey.order.format(.order(.spiral)) == "golden spiral")
        #expect(SettingKey.order.choice(at: 2) == .order(.spiral) && SettingKey.order.choiceIndex(of: .order(.spiral)) == 2)
    }

    @Test("Every setting explains itself, and a hold says how long it lasts")
    func explanations() {
        #expect(SettingKey.allCases.allSatisfy { !$0.help.isEmpty })
        #expect(SettingKey.timingExplanation.contains("Clock") && SettingKey.timingExplanation.contains("hold")
                && SettingKey.timingExplanation.contains("wave"))
        #expect(SettingKey.holdLength(holdTicks: 44, clockMs: 44) == "1.9 s")
        #expect(SettingKey.holdLength(holdTicks: 10, clockMs: 100) == "1.0 s")
        #expect(SettingKey.holdLength(holdTicks: 0, clockMs: 44) == nil, "no hold, nothing to time")
    }

    @Test("Letters: cycling or dials, a show default any decryption cue can override")
    func letters() throws {
        #expect(ShowSettings().letters == .cycle)
        #expect(SettingKey.letters.format(.letters(.dials)) == "dials")
        #expect(SettingKey.letters.choice(at: 1) == .letters(.dials) && SettingKey.letters.choiceIndex(of: .letters(.dials)) == 1)
        var cue = Cue(content: .title(TitleContent(text: "ROSSLYN")))
        SettingKey.letters.setOverride(.letters(.dials), in: &cue)
        guard case .title(let content) = cue.content else { return }
        #expect(ShowSettings().resolved(content.overrides).letters == .dials)
        let back = try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(cue))
        #expect(SettingKey.letters.override(in: back) == .letters(.dials))
        #expect(!SettingKey.letters.applies(to: .image) && !SettingKey.letters.applies(to: .anagram))
        var s = ShowSettings()
        SettingKey.letters.set(.letters(.dials), in: &s)
        #expect(try JSONDecoder().decode(ShowSettings.self, from: JSONEncoder().encode(s)).letters == .dials)
    }

    @Test("Reveal by: flipping or sharpening, a show default any image cue can override")
    func revealBy() throws {
        #expect(ShowSettings().reveal == .flip)
        #expect(SettingKey.reveal.format(.reveal(.sharpen)) == "sharpening")
        #expect(SettingKey.reveal.choice(at: 1) == .reveal(.sharpen))
        var cue = Cue(content: .image(ImageContent(text: "GALLERY")))
        SettingKey.reveal.setOverride(.reveal(.sharpen), in: &cue)
        guard case .image(let content) = cue.content else { return }
        #expect(ShowSettings().resolved(content.overrides).reveal == .sharpen)
        let back = try JSONDecoder().decode(Cue.self, from: try JSONEncoder().encode(cue))
        #expect(SettingKey.reveal.override(in: back) == .reveal(.sharpen))
        #expect(!SettingKey.reveal.applies(to: .title))
    }
}
