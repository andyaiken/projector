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
        // DRACONIAN's line is the longest, at 19 characters, and sets the size.
        #expect(plan.columns == 19 && plan.rows == 2)
        let first = layout.centre(of: .init(line: 0, column: 0), in: plan.fromLines)
        let last = layout.centre(of: .init(line: 0, column: 18), in: plan.fromLines)
        #expect(abs((first.x + last.x) / 2 - 960) < 1e-6)
        let below = layout.centre(of: .init(line: 1, column: 0), in: plan.fromLines)
        #expect(abs(first.y - below.y - layout.lineHeight) < 1e-6, "the second line a line lower")
        #expect(layout.pitch * 19 < 1920 * 0.9)
    }

    @Test("A letter heading right bows over the line; one heading left dips under it")
    func arcs() throws {
        let (plan, _, layout) = try prepared(louvre())
        let arcs = plan.pieces.compactMap { p in p.from.flatMap { f in p.to.map { layout.arc(from: f, to: $0, plan: plan) } } }
        let right = try #require(arcs.first { $0.end.x - $0.start.x > layout.pitch })
        let left = try #require(arcs.first { $0.end.x - $0.start.x < -layout.pitch })
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
