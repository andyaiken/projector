import Foundation
import Testing
@testable import ProspectCore

/// Draws nothing but zero, so starts come out exact.
struct Still: UnitRandom {
    mutating func next() -> Double { 0 }
}

@Suite("Anagrams")
struct AnagramTests {
    static let louvre = (from: "O, Draconian devil! Oh, lame saint!", to: "Leonardo da Vinci! The Mona Lisa!")
    static let fibonacci = (from: "13-3-2-21-1-1-8-5", to: "1-1-2-3-5-8-13-21")

    func plan(_ phrases: (from: String, to: String), wave: Int = 3) -> AnagramPlan {
        var still = Still()
        return AnagramPlan(from: phrases.from, to: phrases.to, wave: wave, random: &still)
    }

    @Test("A long phrase splits at the space nearest its middle, as the book sets it")
    func lines() {
        #expect(AnagramPlan.lines(Self.louvre.from) == ["O, Draconian devil!", "Oh, lame saint!"])
        #expect(AnagramPlan.lines(Self.louvre.to) == ["Leonardo da Vinci!", "The Mona Lisa!"])
        #expect(AnagramPlan.lines("  so dark   the con of man ") == ["so dark the con of man"], "short enough for one line, as typed")
        #expect(AnagramPlan.lines("") == [])
    }

    @Test("Every letter of an exact anagram travels; punctuation only one phrase has fades")
    func everyLetterTravels() {
        let p = plan(Self.louvre)
        #expect(!p.movesWholeWords)
        #expect(p.pieces.count == 30, "26 letters, two commas and two exclamation marks")
        #expect(p.pieces.filter { $0.travels }.count == 28)
        #expect(p.pieces.filter { $0.to == nil }.map(\.character) == [",", ","])
        #expect(p.pieces.allSatisfy { $0.from != nil }, "nothing to fade in")
        #expect(AnagramPlan.leftovers(from: Self.louvre.from, to: Self.louvre.to) == ("", ""))
    }

    @Test("Like letters keep their order, so no two of them cross")
    func likeLettersKeepOrder() {
        let p = plan(Self.louvre)
        func reading(_ s: AnagramPlan.Slot) -> Int { s.line * 100 + s.column }
        for letter in Set(p.pieces.map { $0.character.uppercased() }) {
            let targets = p.pieces.filter { $0.character.uppercased() == letter && $0.travels }.compactMap(\.to).map(reading)
            #expect(targets == targets.sorted(), "\(letter)")
        }
        // The first A of the puzzle, in Draconian, lands in Leonardo.
        let a = p.pieces.first { $0.character == "a" }
        #expect(a?.from == .init(line: 0, column: 5) && a?.to == .init(line: 0, column: 4))
    }

    @Test("Letters match whatever their case, and land as the answer has them")
    func caseChanges() {
        let p = plan(Self.louvre)
        // The l of devil is the first l, so it becomes the L of Leonardo.
        let l = p.pieces.first { $0.from == .init(line: 0, column: 17) }
        #expect(l?.character == "l" && l?.landing == "L" && l?.to == .init(line: 0, column: 0))
        #expect(p.pieces.filter { $0.travels }.allSatisfy { $0.character.uppercased() == $0.landing.uppercased() })
    }

    @Test("Numbers in a new order move whole: 13 travels as 13")
    func wholeNumbers() {
        let p = plan(Self.fibonacci)
        #expect(p.movesWholeWords)
        func piece(at column: Int) -> AnagramPlan.Piece? { p.pieces.first { $0.from == .init(line: 0, column: column) } }
        // 13 heads for the end, 21 for the very end, and the two 1s to the front.
        #expect(piece(at: 0)?.to?.column == 12 && piece(at: 1)?.to?.column == 13)
        #expect(piece(at: 7)?.to?.column == 15 && piece(at: 8)?.to?.column == 16)
        #expect(piece(at: 10)?.to?.column == 0 && piece(at: 12)?.to?.column == 2)
        #expect(piece(at: 0)?.start == piece(at: 1)?.start, "both digits set off together")
        #expect(p.pieces.allSatisfy { $0.travels }, "the dashes swap places too")
    }

    @Test("Pieces set off in reading order, a wave apart, closing up so all have gone before the first lands")
    func timing() {
        let short = plan((from: "RATS", to: "STAR"), wave: 3)
        #expect(short.pieces.map(\.start) == [0, 3, 6, 9], "a wave apart when they fit")
        #expect(short.duration == 9 + AnagramPlan.travelFrames)
        let long = plan(Self.louvre, wave: 3)
        let starts = long.pieces.map(\.start)
        #expect(starts == starts.sorted() && starts.first == 0)
        #expect(starts.last! < AnagramPlan.travelFrames, "the last leaves before the first lands")
        #expect(long.duration == starts.last! + AnagramPlan.travelFrames)
        #expect(plan(Self.louvre, wave: 0).pieces.allSatisfy { $0.start == 0 }, "no wave: all at once")
        let whole = plan(Self.fibonacci, wave: 3)
        // Eight numbers and seven dashes: fifteen departures.
        #expect(Set(whole.pieces.map(\.start)).count == 15)
    }

    @Test("Letters only the answer has fade in as the last pieces land")
    func notAnExactAnagram() {
        let p = plan((from: "ABC", to: "ABD"), wave: 2)
        #expect(AnagramPlan.leftovers(from: "ABC", to: "ABD") == ("C", "D"))
        let c = p.pieces.first { $0.character == "C" }, d = p.pieces.first { $0.character == "D" }
        #expect(c?.to == nil && c?.start == 4)
        #expect(d?.from == nil && d?.to == .init(line: 0, column: 2))
        // B, the last to travel, lands at 2 + 24; D finishes fading in then.
        #expect(p.duration == 26 && d?.start == 26 - AnagramPlan.fadeFrames)
    }

    @Test("Progress runs from 0 at the start to 1 at the landing")
    func progress() {
        let p = plan(Self.louvre)
        let first = p.pieces[0]
        #expect(p.progress(of: first, at: -5) == 0)
        #expect(p.progress(of: first, at: 12) == 0.5)
        #expect(p.progress(of: first, at: 100) == 1)
        let comma = p.pieces[1]
        #expect(p.progress(of: comma, at: comma.start + AnagramPlan.fadeFrames / 2) == 0.5, "fades take half as long")
    }

    @Test("An anagram cue keeps both phrases and its overrides in show.json")
    func roundTrips() throws {
        let cue = Cue(number: "4", content: .anagram(AnagramContent(text: Self.louvre.from, answer: Self.louvre.to,
                                                                    overrides: AnagramOverrides(waveTicks: 2))))
        let data = try JSONEncoder().encode(cue)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"kind\":\"anagram\"") && json.contains("\"answer\""))
        #expect(try JSONDecoder().decode(Cue.self, from: data) == cue)
        #expect(cue.sub == Self.louvre.to, "the answer is the cue's second line")
        #expect(cue.finishes && !cue.isInstant)
    }

    @Test("Font: the stage's own type unless a family is named, for the show or for one cue")
    func font() throws {
        #expect(ShowSettings().anagramFont == "")
        #expect(SettingKey.font.format(.font("")) == "SF Mono" && SettingKey.font.format(.font("Marker Felt")) == "Marker Felt")
        var cue = Cue(content: .anagram(AnagramContent(text: "A", answer: "A")))
        SettingKey.font.setOverride(.font("Noteworthy"), in: &cue)
        guard case .anagram(let content) = cue.content else { return }
        #expect(ShowSettings().resolved(content.overrides).font == "Noteworthy")
        let back = try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(cue))
        #expect(SettingKey.font.override(in: back) == .font("Noteworthy"))
        var s = ShowSettings()
        SettingKey.font.set(.font("Chalkboard SE"), in: &s)
        #expect(try JSONDecoder().decode(ShowSettings.self, from: JSONEncoder().encode(s)).anagramFont == "Chalkboard SE")
        #expect(!SettingKey.font.applies(to: .title))
    }

    @Test("An anagram overrides the timing, and runs on its own clock")
    func settings() {
        #expect(SettingKey.allCases.filter { $0.applies(to: .anagram) } == [.clock, .wave, .hold, .advance, .pause, .font, .transition, .fade])
        var cue = Cue(content: .anagram(AnagramContent(text: "A", answer: "A")))
        SettingKey.hold.setOverride(.number(10), in: &cue)
        #expect(cue.timing(defaults: ShowSettings()) == CueTiming(clockMs: 44, holdTicks: 10, isInstant: false))
    }

    @Test("The sheet flags an anagram that isn't exact, or is missing a phrase")
    func issues() {
        let off = Cue(number: "1", content: .anagram(AnagramContent(text: "Listen", answer: "Silent!")))
        let wrong = Cue(number: "2", content: .anagram(AnagramContent(text: "Rose", answer: "Ores line")))
        let alone = Cue(number: "3", content: .anagram(AnagramContent(text: "Rose", answer: " ")))
        let show = Show(title: "T", cues: [off, wrong, alone])
        #expect(show.issues == [
            .anagramLettersDiffer(cue: wrong.id, anagram: 0, extra: "", missing: "EILN"),
        ], "punctuation may differ freely, and one line alone is solved already")
        #expect(show.message(for: show.issues[0]) ==
            "Cue 2 isn\u{2019}t an exact anagram: only the answer has E I L N. Those letters fade instead of moving.")
    }

    @Test("The printed sheet shows the phrase and what it becomes")
    func sheet() {
        let cue = Cue(number: "4", content: .anagram(AnagramContent(text: "SO DARK THE CON OF MAN", answer: "MADONNA OF THE ROCKS")))
        let show = Show(title: "T", cues: [cue])
        let dsm = CueSheet(show: show, title: "T", layout: .dsm)
        #expect(dsm.rows[0].type == "Anagram")
        #expect(dsm.rows[0].content == ["SO DARK THE CON OF MAN", "\u{2192} MADONNA OF THE ROCKS"])
        let settings = CueSheet(show: show, title: "T", layout: .operatorSettings).rows[0].settings
        #expect(settings.map(\.name) == ["Clock", "Wave", "Hold", "Advance", "Pause", "Font", "Transition", "Fade"])
        #expect(settings[3].value == "by itself" && settings[4].value == "44 \u{00B7} 1.9 s", "a pause in seconds, as a hold")
        #expect(settings[5].value == "SF Mono", "the stage's own type, by name")
    }
}
