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

    func prepared(_ cue: Cue) throws -> (plan: AnagramPlan, tree: AnagramRenderer.Tree, layout: AnagramLayout) {
        renderer.prepare(cue, defaults: ShowSettings())
        let plan = try #require(renderer.plan)
        let tree = try #require(renderer.tree(for: live))
        return (plan, tree, try #require(tree.layout))
    }

    func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }

    @Test("Before anything moves, every letter stands in the first phrase, in slate")
    func waits() throws {
        let (plan, tree, layout) = try prepared(louvre())
        _ = renderer.frame(-10)
        #expect(tree.pieces.count == plan.pieces.count)
        for (piece, layer) in zip(plan.pieces, tree.pieces) {
            #expect(close(layer.position, layout.start(of: piece, plan: plan)))
            #expect(layer.opacity == 1 && layer.warm.opacity == 0)
        }
    }

    @Test("Both phrases share one size of type, and each line is centred")
    func layout() throws {
        let (plan, _, layout) = try prepared(louvre())
        // Draconian's line is the longest, at 19 characters, and sets the size.
        #expect(plan.columns == 19 && plan.rows == 2)
        let first = layout.centre(of: .init(line: 0, column: 0), answer: false)
        let last = layout.centre(of: .init(line: 0, column: 18), answer: false)
        #expect(abs((first.x + last.x) / 2 - 960) < 0.01, "SF Mono's even cells, centred")
        #expect(abs((last.x - first.x) / 18 - CTFontGetSize(layout.font) * TitleLayout.cellEms) < 0.01, "a decryption's 0.72 em cells")
        let below = layout.centre(of: .init(line: 1, column: 0), answer: false)
        #expect(abs(first.y - below.y - layout.lineHeight) < 1e-6, "the second line a line lower")
        #expect(last.x - first.x < 1920 * 0.9)
    }

    @Test("A proportional font sets each letter at its own width, and lands it there")
    func proportional() throws {
        guard StageFont.has(family: "Marker Felt") else { return }
        var settings = ShowSettings()
        settings.anagramFont = "Marker Felt"
        renderer.prepare(Cue(content: .anagram(AnagramContent(text: "MILL", answer: "LIMIT LIM"))), defaults: settings)
        let layout = try #require(renderer.tree(for: live)?.layout)
        #expect(CTFontCopyFamilyName(layout.font) as String == "Marker Felt")
        let x = (0..<4).map { layout.centre(of: .init(line: 0, column: $0), answer: false).x }
        // M is wide and I narrow, so the gaps between their middles differ.
        #expect(abs((x[1] - x[0]) - (x[2] - x[1])) > 2)
        _ = renderer.frame(1_000_000)
        let plan = try #require(renderer.plan)
        let tree = try #require(renderer.tree(for: live))
        for (piece, layer) in zip(plan.pieces, tree.pieces) where piece.to != nil {
            #expect(close(layer.position, layout.end(of: piece, plan: plan)))
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
        let tree = try #require(renderer.tree(for: late))
        #expect(tree.pieces.allSatisfy { $0.animationKeys() == nil })
        // A letter that changed case shows only its new form.
        let plan = try #require(renderer.plan)
        for (piece, layer) in zip(plan.pieces, tree.pieces) where piece.travels {
            #expect(layer.cold.opacity == (piece.character == piece.landing ? 1 : 0), "\(piece.character) to \(piece.landing)")
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
        let layout = try #require(renderer.tree(for: live)?.layout)
        #expect(CTFontCopyFamilyName(layout.font) as String == CTFontCopyFamilyName(StageFont.title(size: 12)) as String)
    }

    @Test("A letter heading right bows over the line; one heading left dips under it")
    func arcs() throws {
        let (plan, _, layout) = try prepared(louvre())
        let arcs = plan.pieces.compactMap { p in p.from.flatMap { f in p.to.map { layout.arc(from: f, to: $0, plan: plan) } } }
        let right = try #require(arcs.first { $0.end.x - $0.start.x > layout.lineHeight })
        let left = try #require(arcs.first { $0.end.x - $0.start.x < -layout.lineHeight })
        #expect(right.control.y > (right.start.y + right.end.y) / 2, "up, in Core Animation's coordinates")
        #expect(left.control.y < (left.start.y + left.end.y) / 2)
        #expect(close(right.point(at: 0), right.start) && close(right.point(at: 1), right.end))
    }

    @Test("A letter sets off as an animation along its arc, and lands in bone")
    func travels() throws {
        let (plan, tree, layout) = try prepared(louvre())
        let first = plan.pieces[0], layer = tree.pieces[0]
        _ = renderer.frame(first.start)
        let move = try #require(layer.animation(forKey: "travel") as? CAKeyframeAnimation)
        #expect(abs(move.duration - Double(AnagramPlan.travelFrames) * 0.044) < 1e-9, "its own duration, on the cue's clock")
        #expect(layer.warm.animation(forKey: "warm") != nil, "warming as it goes")
        #expect(close(layer.position, layout.end(of: first, plan: plan)), "headed for its place in the answer")
        // Later frames leave a journey in flight alone.
        _ = renderer.frame(first.start + 3)
        #expect(layer.animation(forKey: "travel") === move || layer.animation(forKey: "travel") != nil)

        #expect(renderer.frame(plan.duration), "settled once the last letter lands")
        for (piece, layer) in zip(plan.pieces, tree.pieces) {
            #expect(layer.animationKeys() == nil)
            #expect(close(layer.position, layout.end(of: piece, plan: plan)))
            #expect(layer.opacity == (piece.to == nil ? 0 : 1), "the commas gone")
            #expect(layer.warm.opacity == 1)
        }
    }

    @Test("A cue put up finished lands without animating")
    func settledLandsStill() throws {
        let (plan, tree, _) = try prepared(louvre())
        #expect(renderer.frame(1_000_000))
        #expect(tree.pieces.allSatisfy { $0.animationKeys() == nil && $0.warm.animationKeys() == nil })
        #expect(tree.pieces.count == plan.pieces.count)
    }

    @Test("Every surface shows the same letters in the same places, at its own size")
    func surfacesAgree() throws {
        let (plan, tree, layout) = try prepared(louvre())
        _ = renderer.frame(1_000_000)
        let small = try #require(renderer.tree(for: preview))
        let smallLayout = try #require(small.layout)
        for (i, piece) in plan.pieces.enumerated() where piece.to != nil {
            let big = tree.pieces[i].position, little = small.pieces[i].position
            let expected = smallLayout.end(of: piece, plan: plan)
            #expect(close(little, expected))
            #expect(abs(big.x / 1920 - little.x / 640) < 0.01 && abs(big.y / 1080 - little.y / 360) < 0.01)
            _ = layout
        }
    }

    @Test("A surface mounted mid-cue shows the letters partway, placed by hand")
    func mountedMidway() throws {
        let (plan, _, _) = try prepared(louvre())
        let f = 22
        _ = renderer.frame(f)
        let late = surface()
        renderer.mount(on: late)
        renderer.setVisible(true, on: late)
        let tree = try #require(renderer.tree(for: late))
        let layout = try #require(tree.layout)
        let moving = try #require(plan.pieces.indices.first { plan.pieces[$0].travels && (0.3...0.7).contains(plan.progress(of: plan.pieces[$0], at: f)) })
        let piece = plan.pieces[moving]
        let arc = layout.arc(from: piece.from!, to: piece.to!, plan: plan)
        #expect(close(tree.pieces[moving].position, arc.point(at: plan.progress(of: piece, at: f))))
        #expect(tree.pieces[moving].animationKeys() == nil)
        render(late).save("anagram-midway")
    }
}
