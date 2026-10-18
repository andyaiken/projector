import Foundation
import Testing
@testable import ProspectCore

@Suite("Long decryptions: lines and digraphs")
struct DigraphTests {
    static let keystone = "THE KEYSTONE IS UNDER THE SIGN OF THE ROSE"

    @Test("A long text splits at the space nearest its middle; the space it breaks at is on neither line")
    func lines() {
        let text = Array(Self.keystone)
        let ranges = TextLines.ranges(Self.keystone)
        #expect(ranges.map { String(text[$0]) } == ["THE KEYSTONE IS UNDER", "THE SIGN OF THE ROSE"])
        #expect(TextLines.ranges("THE LOUVRE") == [0..<10], "short enough for one line")
        #expect(TextLines.ranges(String(repeating: "X", count: 40)) == [0..<40], "nowhere to break")
        #expect(TextLines.ranges("") == [])
    }

    @Test("A decryption's lines come from its text, in capitals")
    func revealLines() {
        var random = SeededRandom(seed: 1)
        let settings = TitleSettings(clockMs: 44, waveTicks: 3, holdTicks: 44, histogram: true, sceneLine: false)
        let reveal = TitleReveal(text: Self.keystone.lowercased(), scene: "", key: "ROSE", settings: settings, random: &random)
        #expect(reveal.titleLines == [0..<21, 22..<42])
    }

    @Test("Digraphs are counted between neighbouring letters only")
    func counting() {
        let (counts, pairs) = English.digraphCounts([Array("THE TH\u{2423}E"), Array("THE")])
        let th = English.digraphs.firstIndex(of: "TH")!, he = English.digraphs.firstIndex(of: "HE")!
        // THE gives TH and HE; TH gives TH; the open box breaks H from E.
        #expect(counts[th] == 3 && counts[he] == 2 && pairs == 5)
    }

    @Test("Digraph bars count pairs in the text as it reads, scaled against the settled text")
    func digraphBars() {
        var random = SeededRandom(seed: 2)
        var settings = TitleSettings(clockMs: 44, waveTicks: 3, holdTicks: 44, histogram: true, sceneLine: false)
        settings.bars = .digraphs
        let reveal = TitleReveal(text: Self.keystone, scene: "", key: "ROSE", settings: settings, random: &random)
        #expect(reveal.digraphScale == 3, "THE three times: TH and HE thrice each")
        let settled = reveal.frame(1_000, random: &random)
        let th = English.digraphs.firstIndex(of: "TH")!
        #expect(settled.barHeights[th] == 100)
        #expect(settled.chiSquared == English.chiSquared(settled.letterCounts), "chi-squared stays on letters")
        let ciphertext = reveal.frame(-10, random: &random)
        #expect(ciphertext.barHeights.reduce(0, +) < settled.barHeights.reduce(0, +), "few English pairs in ciphertext")
        #expect(settled.letterCounts.reduce(0, +) == Self.keystone.count(where: \.isLetter), "letters still counted")
    }

    @Test("Bars: letters or digraphs, a show default any decryption cue can override")
    func setting() throws {
        #expect(ShowSettings().bars == .letters)
        #expect(SettingKey.bars.format(.bars(.digraphs)) == "digraphs")
        #expect(SettingKey.bars.choice(at: 1) == .bars(.digraphs) && SettingKey.bars.choiceIndex(of: .bars(.digraphs)) == 1)
        var cue = Cue(content: .title(TitleContent(text: Self.keystone)))
        SettingKey.bars.setOverride(.bars(.digraphs), in: &cue)
        let back = try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(cue))
        #expect(SettingKey.bars.override(in: back) == .bars(.digraphs))
        var s = ShowSettings()
        SettingKey.bars.set(.bars(.digraphs), in: &s)
        #expect(try JSONDecoder().decode(ShowSettings.self, from: JSONEncoder().encode(s)).bars == .digraphs)
        #expect(!SettingKey.bars.applies(to: .anagram) && !SettingKey.bars.applies(to: .image))
    }
}
