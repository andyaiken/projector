import CoreText
import ProspectCore
import QuartzCore
import Testing
@testable import ProspectStage

@Suite("Anagram renderer")
@MainActor
struct AnagramRendererTests {
    let renderer = AnagramRenderer(random: SeededRandom(seed: 3))
    let live = surface()
    let preview = surface(width: 640, height: 360, role: .preview)

    init() {
        renderer.mount(on: live)
        renderer.mount(on: preview)
        renderer.setVisible(true, on: live)
        renderer.setVisible(true, on: preview)
    }

    func louvre() -> Cue {
        Cue(number: "1", content: .anagram(AnagramContent(text: "O, Draconian devil! Oh, lame saint!",
                                                          answer: "Leonardo da Vinci! The Mona Lisa!")))
    }

    func cue(_ anagrams: [Anagram], advance: AnagramAdvance? = nil, pause: Int? = nil) -> Cue {
        Cue(number: "1", content: .anagram(AnagramContent(anagrams: anagrams, overrides: AnagramOverrides(advance: advance, pauseTicks: pause))))
    }

    /// The letters of anagram `t` on a surface, as last painted.
    func pieces(_ t: Int = 0, on surface: SurfaceLayer? = nil) -> [PieceLayer] {
        renderer.tree(for: surface ?? live)?.tracks[t].pieces ?? []
    }

    func currentLayout(on surface: SurfaceLayer? = nil) throws -> AnagramLayout {
        try #require(renderer.tree(for: surface ?? live)?.layout)
    }

    /// Prepares a cue and paints frame `f`: what anagram 0 shows, and its layout.
    func prepared(_ cue: Cue, at f: Int = -10) throws -> (shown: AnagramRenderer.Shown, layout: AnagramLayout) {
        renderer.prepare(cue, defaults: ShowSettings())
        _ = renderer.frame(f)
        return (try #require(renderer.shown(0, at: f)), try currentLayout())
    }

    func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }

    func colour(_ face: TextLayer) -> CGColor? { face.runs.first?.colour }

    @Test("Before anything moves, every letter stands in the first phrase, in slate")
    func waits() throws {
        let (shown, layout) = try prepared(louvre())
        #expect(pieces().count == shown.plan.pieces.count)
        for (piece, layer) in zip(shown.plan.pieces, pieces()) {
            #expect(close(layer.position, layout.start(of: piece, in: shown)))
            #expect(layer.opacity == 1 && layer.after.opacity == 0)
            #expect(colour(layer.before) == Palette.slate.cgColor)
        }
    }

    @Test("Both phrases share one size of type, and each line is centred")
    func layout() throws {
        let (shown, layout) = try prepared(louvre())
        // Draconian's line is the longest, at 19 characters, and sets the size.
        #expect(shown.plan.columns == 19 && shown.plan.rows == 2)
        let first = layout.centre(of: .init(line: 0, column: 0), track: 0, step: 0)
        let last = layout.centre(of: .init(line: 0, column: 18), track: 0, step: 0)
        #expect(abs((first.x + last.x) / 2 - 960) < 0.01, "SF Mono's even cells, centred")
        #expect(abs((last.x - first.x) / 18 - CTFontGetSize(layout.font) * TitleLayout.cellEms) < 0.01, "a decryption's 0.72 em cells")
        let below = layout.centre(of: .init(line: 1, column: 0), track: 0, step: 0)
        #expect(abs(first.y - below.y - layout.lineHeight) < 1e-6, "the second line a line lower")
        #expect(abs((first.y + below.y) / 2 - 540) < 1e-6, "the phrase centred on the stage")
        #expect(last.x - first.x < 1920 * 0.9)
    }

    @Test("A proportional font sets each letter at its own width, and lands it there")
    func proportional() throws {
        guard StageFont.has(family: "Marker Felt") else { return }
        var settings = ShowSettings()
        settings.anagramFont = "Marker Felt"
        renderer.prepare(Cue(content: .anagram(AnagramContent(text: "MILL", answer: "LIMIT LIM"))), defaults: settings)
        let layout = try currentLayout()
        #expect(CTFontCopyFamilyName(layout.font) as String == "Marker Felt")
        let x = (0..<4).map { layout.centre(of: .init(line: 0, column: $0), track: 0, step: 0).x }
        // M is wide and I narrow, so the gaps between their middles differ.
        #expect(abs((x[1] - x[0]) - (x[2] - x[1])) > 2)
        _ = renderer.frame(1_000_000)
        let shown = try #require(renderer.shown(0, at: 1_000_000))
        for (piece, layer) in zip(shown.plan.pieces, pieces()) where piece.to != nil {
            #expect(close(layer.position, layout.end(of: piece, in: shown)))
        }
    }

    @Test("A hand-drawn font, in flight and landed")
    func handDrawn() throws {
        guard StageFont.has(family: "Noteworthy") else { return }
        var settings = ShowSettings()
        settings.anagramFont = "Noteworthy"
        renderer.prepare(louvre(), defaults: settings)
        _ = renderer.frame(22)
        let late = surface()
        renderer.mount(on: late)
        renderer.setVisible(true, on: late)
        render(late).save("anagram-hand-midway")
        _ = renderer.frame(1_000_000)
        render(late).save("anagram-hand-landed")
        #expect(pieces(on: late).allSatisfy { $0.animationKeys() == nil })
        // A letter that changed case shows only its new form.
        let shown = try #require(renderer.shown(0, at: 1_000_000))
        for (piece, layer) in zip(shown.plan.pieces, pieces(on: late)) where piece.travels {
            #expect(layer.before.opacity == (piece.character == piece.landing ? 1 : 0), "\(piece.character) to \(piece.landing)")
        }
    }

    @Test("A font this Mac doesn't have falls back to SF Mono, and says so")
    func missingFont() throws {
        var said: [String] = []
        renderer.onProblem = { said.append($0) }
        var settings = ShowSettings()
        settings.anagramFont = "No Such Hand"
        renderer.prepare(Cue(number: "7", content: .anagram(AnagramContent(text: "RATS", answer: "STAR"))), defaults: settings)
        #expect(said == ["Cue 7\u{2019}s font, No Such Hand, isn\u{2019}t on this Mac, so it shows in SF Mono instead."])
        #expect(CTFontCopyFamilyName(try currentLayout().font) as String == CTFontCopyFamilyName(StageFont.title(size: 12)) as String)
    }

    @Test("A letter heading right bows over the line; one heading left dips under it")
    func arcs() throws {
        let (shown, layout) = try prepared(louvre())
        let arcs = shown.plan.pieces.compactMap { p in p.from.flatMap { f in p.to.map { layout.arc(from: f, to: $0, in: shown) } } }
        let right = try #require(arcs.first { $0.end.x - $0.start.x > layout.lineHeight })
        let left = try #require(arcs.first { $0.end.x - $0.start.x < -layout.lineHeight })
        #expect(right.control.y > (right.start.y + right.end.y) / 2, "up, in Core Animation's coordinates")
        #expect(left.control.y < (left.start.y + left.end.y) / 2)
        #expect(close(right.point(at: 0), right.start) && close(right.point(at: 1), right.end))
    }

    @Test("A letter sets off as an animation along its arc, and lands in bone")
    func travels() throws {
        let (shown, layout) = try prepared(louvre())
        let first = shown.plan.pieces[0]
        _ = renderer.frame(first.start)
        let layer = pieces()[0]
        let move = try #require(layer.animation(forKey: "travel") as? CAKeyframeAnimation)
        #expect(abs(move.duration - Double(AnagramPlan.travelFrames) * 0.044) < 1e-9, "its own duration, on the cue's clock")
        #expect(layer.after.animation(forKey: "arrive") != nil, "warming as it goes")
        #expect(layer.animation(forKey: "dim") == nil, "nothing dims on a plain anagram")
        #expect(close(layer.position, layout.end(of: first, in: shown)), "headed for its place in the answer")
        // Later frames leave a journey in flight alone.
        _ = renderer.frame(first.start + 3)
        #expect(layer.animation(forKey: "travel") === move || layer.animation(forKey: "travel") != nil)

        #expect(renderer.frame(shown.plan.duration), "settled once the last letter lands")
        for (piece, layer) in zip(shown.plan.pieces, pieces()) {
            #expect(layer.animationKeys() == nil)
            #expect(close(layer.position, layout.end(of: piece, in: shown)))
            #expect(layer.opacity == (piece.to == nil ? 0 : 1), "the commas gone")
            #expect(layer.after.opacity == 1 && colour(layer.after) == Palette.bone.cgColor)
        }
    }

    @Test("A cue put up finished lands without animating")
    func settledLandsStill() throws {
        _ = try prepared(louvre())
        #expect(renderer.frame(1_000_000))
        #expect(pieces().allSatisfy { $0.animationKeys() == nil && $0.after.animationKeys() == nil })
        #expect(pieces().count == renderer.shown(0, at: 1_000_000)?.plan.pieces.count)
    }

    @Test("Every surface shows the same letters in the same places, at its own size")
    func surfacesAgree() throws {
        _ = try prepared(louvre())
        _ = renderer.frame(1_000_000)
        let shown = try #require(renderer.shown(0, at: 1_000_000))
        let smallLayout = try currentLayout(on: preview)
        for (i, piece) in shown.plan.pieces.enumerated() where piece.to != nil {
            let big = pieces()[i].position, little = pieces(on: preview)[i].position
            #expect(close(little, smallLayout.end(of: piece, in: shown)))
            #expect(abs(big.x / 1920 - little.x / 640) < 0.01 && abs(big.y / 1080 - little.y / 360) < 0.01)
        }
    }

    @Test("A surface mounted mid-cue shows the letters partway, placed by hand")
    func mountedMidway() throws {
        let f = 22
        let (shown, _) = try prepared(louvre(), at: f)
        let late = surface()
        renderer.mount(on: late)
        renderer.setVisible(true, on: late)
        let layout = try currentLayout(on: late)
        let plan = shown.plan
        let moving = try #require(plan.pieces.indices.first { plan.pieces[$0].travels && (0.3...0.7).contains(plan.progress(of: plan.pieces[$0], at: f)) })
        let piece = plan.pieces[moving]
        let arc = layout.arc(from: piece.from!, to: piece.to!, in: shown)
        #expect(close(pieces(on: late)[moving].position, arc.point(at: plan.progress(of: piece, at: f))))
        #expect(pieces(on: late)[moving].animationKeys() == nil)
        render(late).save("anagram-midway")
    }

    // MARK: Several anagrams

    @Test("Several anagrams stack down the stage, and each waits until the one before is solved and a pause has passed")
    func several() throws {
        let rats = Anagram(text: "RATS", answer: "STAR"), listen = Anagram(text: "LISTEN", answer: "SILENT")
        renderer.prepare(cue([rats, listen], pause: 10), defaults: ShowSettings())
        let plan = try #require(renderer.plan)
        let first = plan.tracks[0].moves[0], second = plan.tracks[1].moves[0]
        #expect(second.offset == first.plan.duration + 10)
        #expect(plan.parts == [second.offset + second.plan.duration])

        _ = renderer.frame(second.offset - 1)
        let layout = try currentLayout()
        let solving = try #require(renderer.shown(1, at: second.offset - 1))
        for (piece, layer) in zip(solving.plan.pieces, pieces(1)) {
            #expect(close(layer.position, layout.start(of: piece, in: solving)) && layer.animationKeys() == nil, "LISTEN still waits")
        }
        let top = layout.centre(of: .init(line: 0, column: 0), track: 0, step: 0)
        let bottom = layout.centre(of: .init(line: 0, column: 0), track: 1, step: 0)
        #expect(top.y > bottom.y, "the first above the second")
        #expect(abs((top.y + bottom.y) / 2 - 540) < 1e-6, "the stack centred on the stage")
        #expect(abs(top.y - bottom.y - layout.lineHeight * (1 + AnagramLayout.gap)) < 1e-6)

        // Its first letter goes within a couple of frames, as the dice fall.
        _ = renderer.frame(second.offset + (second.plan.pieces.map(\.start).min() ?? 0))
        #expect(pieces(1).contains { $0.animation(forKey: "travel") != nil }, "LISTEN sets off")
        #expect(!renderer.frame(plan.parts[0] - 1) && renderer.frame(plan.parts[0]))
        render(live).save("anagram-several")
    }

    // MARK: Working

    @Test("Working stays slate, with the letters it doesn't use dimmed on a line beneath; the answer lands in bone")
    func working() throws {
        let anagram = Anagram(text: "O, Draconian devil!", working: ["LEONARDO"], answer: "Leonardo da Vinci!")
        renderer.prepare(cue([anagram]), defaults: ShowSettings())
        let plan = try #require(renderer.plan)
        let into = plan.tracks[0].moves[0], out = plan.tracks[0].moves[1]

        // LEONARDO has landed, and the pause before the answer is running.
        let resting = into.plan.duration + 1
        _ = renderer.frame(resting)
        let shown = try #require(renderer.shown(0, at: resting))
        #expect(shown.move == 0 && !shown.warms)
        let dimmed = zip(shown.plan.pieces, pieces()).filter { $0.0.to?.line == 1 }.map(\.1)
        #expect(dimmed.count == 7 && dimmed.allSatisfy { abs($0.opacity - Float(AnagramRenderer.dimmed)) < 1e-6 })
        #expect(zip(shown.plan.pieces, pieces()).filter { $0.0.to?.line == 0 }.allSatisfy { $0.1.opacity == 1 })
        #expect(pieces().allSatisfy { colour($0.after) == Palette.slate.cgColor }, "working never looks solved")
        render(live).save("anagram-working")

        // The answer sets off: its letters stand where LEONARDO's landed, the
        // dimmed ones still dim, and brighten as they rise.
        let start = into.plan.duration + ShowSettings().pauseTicks
        #expect(out.offset == start)
        _ = renderer.frame(start - 1)
        let before = Dictionary(uniqueKeysWithValues: zip(shown.plan.pieces, pieces()).compactMap { p, l in p.to.map { ($0, l.position) } })
        _ = renderer.frame(start)
        let answer = try #require(renderer.shown(0, at: start))
        #expect(answer.move == 1 && answer.warms)
        for (piece, layer) in zip(answer.plan.pieces, pieces()) {
            guard let from = piece.from else { continue }
            if piece.start > 0 { #expect(close(layer.position, before[from]!), "taking over exactly where the last move left it") }
            if from.line == 1, piece.start > 0 { #expect(abs(layer.opacity - Float(AnagramRenderer.dimmed)) < 1e-6) }
        }
        let rising = try #require(answer.plan.pieces.indices.first { answer.plan.pieces[$0].from?.line == 1 })
        _ = renderer.frame(start + answer.plan.pieces[rising].start)
        #expect(pieces()[rising].animation(forKey: "dim") != nil, "brightening on the way up")

        #expect(renderer.frame(start + out.plan.duration))
        #expect(pieces().allSatisfy { colour($0.after) == Palette.bone.cgColor && $0.opacity == 1 })
        render(live).save("anagram-working-solved")
    }

    // MARK: GO

    @Test("Each step on GO: the cue waits, and GO carries it on")
    func eachStepOnGO() throws {
        renderer.prepare(cue([Anagram(text: "RATS", working: ["TSAR"], answer: "STAR")], advance: .eachStep), defaults: ShowSettings())
        let plan = try #require(renderer.plan)
        #expect(!renderer.frame(0) && renderer.isWaiting(at: 0), "nothing moves before the first GO")
        #expect(renderer.shown(0, at: 50)?.start == nil)
        renderer.carryOn(at: 50)
        #expect(!renderer.isWaiting(at: 50) && renderer.shown(0, at: 50)?.start == 50)
        _ = renderer.frame(50)
        #expect(pieces().contains { $0.animation(forKey: "travel") != nil })
        let landed = 50 + plan.parts[1]
        #expect(!renderer.isWaiting(at: landed - 1) && renderer.isWaiting(at: landed))
        // A GO before the step has landed waits for it.
        renderer.carryOn(at: landed - 5)
        #expect(renderer.shown(0, at: landed)?.move == 1 && renderer.shown(0, at: landed)?.start == landed)
        #expect(!renderer.frame(landed + plan.parts[2] - 1) && renderer.frame(landed + plan.parts[2]))
    }

    @Test("Put up finished, a cue that waits for GO shows every anagram solved")
    func finishedWithoutGO() throws {
        renderer.prepare(cue([Anagram(text: "RATS", working: ["TSAR"], answer: "STAR"), Anagram(text: "LISTEN", answer: "SILENT")],
                             advance: .eachAnagram), defaults: ShowSettings())
        renderer.carryOnToEnd()
        #expect(renderer.frame(1_000_000))
        for t in 0..<2 {
            #expect(renderer.shown(t, at: 1_000_000)?.warms == true)
            #expect(pieces(t).allSatisfy { $0.animationKeys() == nil && colour($0.after) == Palette.bone.cgColor })
        }
    }

    @Test("One line alone stands solved, in bone; an ignored anagram stands jumbled, in slate; the cue goes straight to the next")
    func skipped() throws {
        let anagrams = [Anagram(text: "Leonardo da Vinci!"), Anagram(text: "Oh, lame saint!", answer: "The Mona Lisa!", ignored: true),
                        Anagram(text: "RATS", answer: "STAR")]
        renderer.prepare(cue(anagrams), defaults: ShowSettings())
        let plan = try #require(renderer.plan)
        #expect(plan.tracks[2].moves[0].offset == 0, "RATS goes first")
        _ = renderer.frame(1)
        let layout = try currentLayout()
        for (t, expected) in [(0, Palette.bone), (1, Palette.slate)] {
            let shown = try #require(renderer.shown(t, at: 1_000))
            #expect(shown.move == nil)
            for (piece, layer) in zip(shown.plan.pieces, pieces(t)) {
                #expect(close(layer.position, layout.start(of: piece, in: shown)) && layer.opacity == 1)
                #expect(colour(layer.before) == expected.cgColor && layer.after.opacity == 0)
            }
        }
        #expect(pieces(1).count == "Ohlamesaint".count + 2, "the phrase, not the answer")
        _ = renderer.frame(plan.parts[0])
        render(live).save("anagram-skipped")
    }
}
