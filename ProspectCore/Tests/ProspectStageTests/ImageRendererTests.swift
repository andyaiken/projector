import AppKit
import ProspectCore
import QuartzCore
import Testing
@testable import ProspectStage

/// A 400 x 200 picture in quadrants, as seen: red top-left, green top-right,
/// blue bottom-left, white bottom-right. Written to a temporary folder.
private let media: URL = {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProspectStageTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // A bitmap context measures from the bottom.
    for (rect, rgb) in [
        (CGRect(x: 0, y: 100, width: 200, height: 100), (1.0, 0.0, 0.0)),
        (CGRect(x: 200, y: 100, width: 200, height: 100), (0.0, 1.0, 0.0)),
        (CGRect(x: 0, y: 0, width: 200, height: 100), (0.0, 0.0, 1.0)),
        (CGRect(x: 200, y: 0, width: 200, height: 100), (1.0, 1.0, 1.0)),
    ] {
        ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        ctx.fill(rect)
    }
    let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    try! png.write(to: folder.appendingPathComponent("quadrants.png"))
    try! Data("not a picture".utf8).write(to: folder.appendingPathComponent("broken.png"))
    return folder
}()

private func imageCue(_ src: String, columns: Int = 4, order: TileOrder = .diagonal, text: String = "THE LOUVRE") -> Cue {
    Cue(number: "2", content: .image(ImageContent(text: text, src: src,
                                                   overrides: ImageOverrides(gridColumns: columns, order: order))))
}

@Suite("Image renderer")
@MainActor
struct ImageRendererTests {
    let renderer = ImageRenderer(media: { media.appendingPathComponent($0) }, random: SeededRandom(seed: 21))
    let live = surface(width: 960, height: 540)
    var problems: [String] = []

    init() {
        renderer.mount(on: live)
        renderer.setVisible(true, on: live)
    }

    /// Prepares a cue and waits for its picture, decoded in the background.
    func prepare(_ cue: Cue, defaults: ShowSettings = ShowSettings()) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            renderer.onReady = { [renderer] in
                renderer.onReady = nil
                done.resume()
            }
            renderer.prepare(cue, defaults: defaults)
        }
    }

    @Test("A picture is decoded off the main thread and cut into tiles")
    func tilesTheImage() async throws {
        await prepare(imageCue("quadrants.png"))
        let plan = try #require(renderer.plan)
        #expect(plan.schedule.grid.columns == 4 && plan.schedule.grid.rows == 2, "4 across, rows to keep tiles square")
        let tiles = try #require(renderer.tree(for: live)?.tiles)
        #expect(tiles.count == 8)
        // The grid fits 90% of the picture area at the image's 2:1 shape.
        #expect(renderer.tree(for: live)?.grid.frame == CGRect(x: 48, y: 54, width: 864, height: 432))
    }

    @Test("Each tile's front shows its own part of the picture")
    func frontsShowTheirShare() async throws {
        await prepare(imageCue("quadrants.png"))
        let tiles = try #require(renderer.tree(for: live)?.tiles)
        // Tiles run row by row from the top left: 0-1 red, 2-3 green, 4-5 blue, 6-7 white.
        let expected: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (255, 0, 0), (0, 255, 0), (0, 255, 0),
                                                 (0, 0, 255), (0, 0, 255), (255, 255, 255), (255, 255, 255)]
        for (i, tile) in tiles.enumerated() {
            let p = centrePixel(of: tile.front)
            #expect(p.0 == expected[i].0 && p.1 == expected[i].1 && p.2 == expected[i].2, "tile \(i): \(p)")
        }
    }

    @Test("Each tile's back is the average colour behind it, pulled toward the slate")
    func backsAreAverages() async throws {
        await prepare(imageCue("quadrants.png"))
        let backs = try #require(renderer.plan?.backColours)
        let red = TileFaces.backColours(rgba: [255, 0, 0, 255])[0], white = TileFaces.backColours(rgba: [255, 255, 255, 255])[0]
        #expect(backs[0] == red && backs[7] == white)
        #expect(renderer.tree(for: live)?.tiles[0].back.backgroundColor == red.cgColor)
    }

    @Test("Tiles turn on schedule, and the cue settles when the last flip has had time")
    func flipsOnSchedule() async throws {
        var defaults = ShowSettings()
        defaults.flipMs = 420
        defaults.clockMs = 44
        await prepare(imageCue("quadrants.png"), defaults: defaults)
        let plan = try #require(renderer.plan)
        let tiles = try #require(renderer.tree(for: live)?.tiles)
        #expect(plan.flipFrames == 10, "420 ms at 44 ms a frame, rounded up")

        #expect(!renderer.frame(-10))
        #expect(tiles.allSatisfy { $0.state == .waiting && $0.front.isHidden })
        let first = plan.schedule.starts.min()!
        _ = renderer.frame(first)
        let turning = tiles.indices.filter { plan.schedule.starts[$0] <= first }
        #expect(turning.allSatisfy { tiles[$0].state == .flipping && tiles[$0].animation(forKey: "flip") != nil })
        #expect(!renderer.frame(plan.settleFrame - 1))
        #expect(renderer.frame(plan.settleFrame))
        #expect(tiles.allSatisfy { $0.state == .done && $0.back.isHidden && !$0.front.isHidden })
    }

    @Test("A cue put up finished lands without animating")
    func settledLandsStill() async throws {
        await prepare(imageCue("quadrants.png"))
        #expect(renderer.frame(StageRunner.settledFrame))
        let tiles = try #require(renderer.tree(for: live)?.tiles)
        #expect(tiles.allSatisfy { $0.state == .done && $0.animation(forKey: "flip") == nil })
    }

    @Test("A missing picture falls back to the label on black, and says so")
    func missingFile() async throws {
        var messages: [String] = []
        renderer.onProblem = { messages.append($0) }
        await prepare(imageCue("not-there.jpg"))
        let plan = try #require(renderer.plan)
        #expect(abs(Double(plan.image.width) / Double(plan.image.height) - 16.0 / 9) < 0.01, "a 16:9 picture of the label")
        #expect(messages == ["Cue 2\u{2019}s image, not-there.jpg, is missing from the show, so it is showing its label on black."])
    }

    @Test("A picture that won't decode falls back too")
    func brokenFile() async throws {
        var messages: [String] = []
        renderer.onProblem = { messages.append($0) }
        await prepare(imageCue("broken.png"))
        #expect(renderer.plan != nil)
        #expect(messages.first?.contains("couldn\u{2019}t be read") == true)
    }

    @Test("A cue with no picture shows its label without complaint")
    func labelByDesign() async throws {
        var messages: [String] = []
        renderer.onProblem = { messages.append($0) }
        await prepare(imageCue(""))
        #expect(renderer.plan?.schedule.grid.rows == 2, "4 across a 16:9 picture")
        #expect(messages.isEmpty)
    }

    @Test("A preloaded picture is ready the moment the cue fires")
    func preloadIsInstant() async throws {
        let cue = imageCue("quadrants.png")
        await prepare(cue)   // decoded and cached once
        renderer.clear(live)
        renderer.prepare(cue, defaults: ShowSettings())
        #expect(renderer.plan != nil, "no wait the second time")
    }

    @Test("Clearing takes the tiles away and drops a load still in flight")
    func clearing() async throws {
        await prepare(imageCue("quadrants.png"))
        renderer.clear(live)
        #expect(renderer.tree(for: live)?.tiles.isEmpty == true)
        #expect(renderer.plan == nil)
        #expect(!renderer.frame(100), "nothing prepared, nothing settled")
    }

    @Test("Every surface turns the same tiles on the same frame")
    func surfacesAgree() async throws {
        let preview = surface(width: 320, height: 180, role: .preview)
        renderer.mount(on: preview)
        await prepare(imageCue("quadrants.png", order: .random))
        let plan = try #require(renderer.plan)
        _ = renderer.frame(plan.schedule.starts.sorted()[3])
        let a = renderer.tree(for: live)!.tiles.map(\.state), b = renderer.tree(for: preview)!.tiles.map(\.state)
        #expect(a == b)
        #expect(a.contains(.flipping) && a.contains(.waiting))
    }

    @Test("Tiles meet exactly, on whole pixels, with no gaps between them")
    func tilesMeetExactly() async throws {
        let odd = surface(width: 1001, height: 563)
        renderer.mount(on: odd)
        await prepare(imageCue("", columns: 12))
        let tiles = try #require(renderer.tree(for: odd)?.tiles)
        let grid = try #require(renderer.plan?.schedule.grid)
        for (i, tile) in tiles.enumerated() {
            let f = tile.frame
            #expect(f.minX == f.minX.rounded() && f.maxX == f.maxX.rounded() && f.minY == f.minY.rounded(), "tile \(i): \(f)")
            if i % grid.columns < grid.columns - 1 {
                #expect(f.maxX == tiles[i + 1].frame.minX, "tile \(i) meets its right neighbour")
            }
            if i + grid.columns < tiles.count {
                #expect(f.minY == tiles[i + grid.columns].frame.maxY, "tile \(i) meets the tile below")
            }
        }
    }

    @Test("Content rectangles count rows from the top")
    func contentsRects() {
        let grid = TileGrid(imageWidth: 400, imageHeight: 200, columns: 4)
        #expect(ImageRenderer.contentsRect(column: 0, row: 0, of: grid) == CGRect(x: 0, y: 0.5, width: 0.25, height: 0.5))
        #expect(ImageRenderer.contentsRect(column: 3, row: 1, of: grid) == CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5))
    }

    /// Renders one face on its own, flat, and reads its middle pixel.
    private func centrePixel(of face: CALayer) -> (UInt8, UInt8, UInt8) {
        let flat = CALayer()
        flat.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        flat.contents = face.contents
        flat.contentsRect = face.contentsRect
        let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        flat.render(in: ctx)
        let d = ctx.data!.assumingMemoryBound(to: UInt8.self), i = (10 * 20 + 10) * 4
        return (d[i], d[i + 1], d[i + 2])
    }
}

@Suite("Label painting")
@MainActor
struct LabelPaintingTests {
    let font = StageFont.title(size: 26)

    /// The picture's pixels, for reading back.
    func pixels(_ image: CGImage) -> (width: Int, data: [UInt8]) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, data)
    }

    /// The columns any part of the label reaches, and the brightest pixel.
    func ink(_ image: CGImage) -> (columns: ClosedRange<Int>?, brightest: UInt8) {
        let (w, data) = pixels(image)
        var low = Int.max, high = Int.min, brightest: UInt8 = 0
        for i in stride(from: 0, to: data.count, by: 4) where data[i] > 40 {
            let x = (i / 4) % w
            low = min(low, x); high = max(high, x); brightest = max(brightest, data[i])
        }
        return (low <= high ? low...high : nil, brightest)
    }

    @Test("No picture shows the label, centred, in bone on black")
    func labelOnBlack() throws {
        let image = try #require(LabelPainter.image("THE LOUVRE", width: 1600, height: 900, font: font))
        let (w, data) = pixels(image)
        #expect(data[0] == 0 && data[1] == 0 && data[2] == 0, "black in the corner")
        #expect(data[(450 * w + 2) * 4] == 0, "and at the edge")
        let (columns, brightest) = ink(image)
        let reach = try #require(columns)
        #expect(abs((reach.lowerBound + reach.upperBound) / 2 - 800) <= 8, "centred: \(reach)")
        #expect(brightest >= Palette.bone.r - 4, "bone where the letters are")
    }

    @Test("A long label is narrowed to fit, and an empty one leaves plain black")
    func fitting() throws {
        let long = try #require(LabelPainter.image(String(repeating: "CHATEAU VILLETTE ", count: 4), width: 1600, height: 900, font: font))
        let reach = try #require(ink(long).columns)
        #expect(reach.lowerBound >= 70 && reach.upperBound <= 1530, "inside the picture: \(reach)")
        let empty = try #require(LabelPainter.image("  ", width: 800, height: 450, font: font))
        #expect(ink(empty).columns == nil)
    }

    @Test("The same label paints the same picture, at any size")
    func deterministic() throws {
        let a = try #require(LabelPainter.image("THE LOUVRE", width: 800, height: 450, font: font))
        let b = try #require(LabelPainter.image("THE LOUVRE", width: 800, height: 450, font: font))
        #expect(a.dataProvider?.data == b.dataProvider?.data)
        #expect(try #require(LabelPainter.image("THE LOUVRE", width: 3200, height: 1800, font: font)).width == 3200)
    }
}
