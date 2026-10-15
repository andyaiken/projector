/// The order an image cue's tiles flip in.
public enum TileOrder: String, Codable, Sendable, CaseIterable {
    /// From the top-left corner to the bottom-right.
    case diagonal
    /// Shuffled, with starts paced evenly across the same span as the sweep.
    case random
}

/// The tile grid for an image: as many columns as set, and as many rows as
/// keep the tiles near square.
public struct TileGrid: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    /// Width over height. An image whose size is unknown is taken as 16:9.
    public let aspect: Double

    public var count: Int { columns * rows }

    public init(imageWidth: Double, imageHeight: Double, columns: Int) {
        aspect = (imageWidth == 0 ? 16 : imageWidth) / (imageHeight == 0 ? 9 : imageHeight)
        self.columns = max(2, columns)
        rows = max(2, roundHalfUp(Double(self.columns) / aspect))
    }
}

/// When each tile of an image cue starts to flip. Computed once per cue and
/// shared, so every surface flips the same tiles on the same frame.
public struct TileSchedule: Equatable, Sendable {
    public let grid: TileGrid
    /// Start frame per tile, row by row from the top left.
    public let starts: [Int]
    public let lastStart: Int

    /// - Parameters:
    ///   - wave: Frames per diagonal step. Below 1 counts as 1.
    ///   - random: Jitters the starts, and shuffles the random order.
    public init(grid: TileGrid, order: TileOrder, wave: Int, random: inout some UnitRandom) {
        let step = max(1, wave)
        let total = grid.count
        // Both orders run over the same span, so switching between them
        // doesn't change how long the cue takes.
        let span = roundHalfUp(Double((grid.columns + grid.rows - 2) * step))
        var starts = [Int](repeating: 0, count: total)

        switch order {
        case .random:
            // Shuffle the order, then pace the starts evenly. Independent
            // random starts look like rainfall, with clumps and stragglers.
            var order = Array(0..<total)
            for a in stride(from: total - 1, to: 0, by: -1) {
                order.swapAt(a, random.below(a + 1))
            }
            for n in 0..<total {
                let fraction = total > 1 ? Double(n) / Double(total - 1) : 1
                starts[order[n]] = roundHalfUp(fraction * Double(span)) + random.below(3)
            }
        case .diagonal:
            for y in 0..<grid.rows {
                for x in 0..<grid.columns {
                    starts[y * grid.columns + x] = roundHalfUp(Double((x + y) * step)) + random.below(7)
                }
            }
        }

        self.grid = grid
        self.starts = starts
        self.lastStart = max(0, starts.max() ?? 0)
    }

    /// The first frame on which the cue has settled: the last tile has
    /// started and had its flip duration to finish. The flip itself is an
    /// animation; the clock only triggers each tile.
    public func settleFrame(flipMs: Int, clockMs: Int) -> Int {
        lastStart + Int((Double(flipMs) / Double(max(1, clockMs))).rounded(.up))
    }
}

/// The colours the unflipped tiles show.
public enum TileFaces {
    /// One average colour per tile, from an image drawn at a whole multiple
    /// of the grid's size: every pixel in a tile's block counts equally.
    ///
    /// - Returns: Four bytes per tile, row by row from the top left.
    public static func blockAverages(rgba: [UInt8], width: Int, height: Int, columns: Int, rows: Int) -> [UInt8] {
        precondition(rgba.count == width * height * 4 && width % columns == 0 && height % rows == 0)
        let bw = width / columns, bh = height / rows
        var out = [UInt8](repeating: 0, count: columns * rows * 4)
        for ty in 0..<rows {
            for tx in 0..<columns {
                var sum = [Int](repeating: 0, count: 4)
                for y in ty * bh..<(ty + 1) * bh {
                    for x in tx * bw..<(tx + 1) * bw {
                        let i = (y * width + x) * 4
                        for c in 0..<4 { sum[c] += Int(rgba[i + c]) }
                    }
                }
                let n = bw * bh, o = (ty * columns + tx) * 4
                for c in 0..<4 { out[o + c] = UInt8((sum[c] + n / 2) / n) }
            }
        }
        return out
    }

    /// Each tile's back face: the average colour of the image behind it,
    /// pulled two-thirds of the way toward the cold slate, so the opening
    /// state hints at the composition without giving away the detail.
    ///
    /// - Parameter rgba: The image drawn at exactly the grid's dimensions,
    ///   four bytes per pixel, so each pixel is one tile's average.
    public static func backColours(rgba: [UInt8]) -> [RGB] {
        stride(from: 0, to: rgba.count - 3, by: 4).map { i in
            func pull(_ channel: UInt8, _ slate: UInt8) -> UInt8 {
                UInt8(clamping: roundHalfUp(Double(channel) * 0.34 + Double(slate) * 0.66))
            }
            return RGB(
                pull(rgba[i], Palette.slate.r),
                pull(rgba[i + 1], Palette.slate.g),
                pull(rgba[i + 2], Palette.slate.b)
            )
        }
    }
}
