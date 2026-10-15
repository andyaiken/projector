import Testing
@testable import ProspectCore

@Suite("Image tiles, against recorded schedules")
struct TileTests {
    static let cases = (try? Fixtures.load("tiles", as: TilesFixture.self).tiles) ?? []

    @Test func fixturesLoaded() {
        #expect(!Self.cases.isEmpty)
    }

    @Test(arguments: cases)
    func schedule(_ c: TilesFixture.Case) throws {
        let grid = TileGrid(imageWidth: c.width, imageHeight: c.height, columns: c.settings.cols)
        #expect(grid.columns == c.cols)
        #expect(grid.rows == c.rows)

        var random = SeededRandom(seed: c.seed)
        let order = try #require(TileOrder(rawValue: c.settings.order))
        let schedule = TileSchedule(grid: grid, order: order, wave: c.settings.stagger, random: &random)
        #expect(schedule.starts == c.starts)
        #expect(schedule.lastStart == c.lastStart)
        #expect(schedule.settleFrame(flipMs: c.settings.flipMs, clockMs: c.settings.speed) == c.settledAt)
    }

    @Test(arguments: cases)
    func backColours(_ c: TilesFixture.Case) {
        #expect(c.pixels.count == c.cols * c.rows * 4)
        #expect(TileFaces.backColours(rgba: c.pixels).map(\.hex) == c.backColours.map { "#" + $0 })
    }

    @Test func bothOrdersSpanTheSameDuration() {
        let grid = TileGrid(imageWidth: 1600, imageHeight: 900, columns: 12)
        let span = (grid.columns + grid.rows - 2) * 3
        var random = SystemUnitRandom()
        for _ in 0..<20 {
            let diagonal = TileSchedule(grid: grid, order: .diagonal, wave: 3, random: &random)
            let shuffled = TileSchedule(grid: grid, order: .random, wave: 3, random: &random)
            // The same span; only the jitter differs, up to 6 frames against up to 2.
            #expect((span...span + 6).contains(diagonal.lastStart))
            #expect((span...span + 2).contains(shuffled.lastStart))
            #expect(shuffled.starts.allSatisfy { (0...span + 2).contains($0) })
        }
    }
}
