import Foundation

/// The order an image cue's tiles flip in.
public enum TileOrder: String, Codable, Sendable, CaseIterable {
    /// From the top-left corner to the bottom-right.
    case diagonal
    /// Shuffled, with starts paced evenly across the same span as the sweep.
    case random
    /// Out along a golden spiral: the grid cut into squares the way a
    /// Fibonacci rectangle is, and the spiral traced from the smallest out to
    /// the largest. See `SpiralSquare`.
    case spiral
}

/// How a tile shows its part of the picture when its turn comes.
public enum TileReveal: String, Codable, Sendable, CaseIterable {
    /// It turns over, from its flat colour to the picture.
    case flip
    /// It sharpens: its part of the picture in one block, then 2 x 2, 3 x 3,
    /// 5 x 5, 8 x 8 and on through the Fibonacci numbers, until it is the
    /// picture.
    case sharpen
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
        case .spiral:
            // Each square holds a quarter turn as long as its side, so pacing
            // by the spiral's length traces the curve at one speed. Tiles the
            // hand reaches together start together.
            var along = [Double](repeating: 0, count: total)
            var travelled = 0.0
            for square in SpiralSquare.cut(columns: grid.columns, rows: grid.rows).reversed() {
                for row in square.y..<square.y + square.side {
                    for column in square.x..<square.x + square.side {
                        let outward = 1 - square.turn(column: column, row: row)
                        along[row * grid.columns + column] = travelled + outward * Double(square.side)
                    }
                }
                travelled += Double(square.side)
            }
            // From the first tile to the last across the whole span.
            let first = along.min() ?? 0, last = along.max() ?? 0
            for i in 0..<total {
                let fraction = last > first ? (along[i] - first) / (last - first) : 1
                starts[i] = roundHalfUp(fraction * Double(span)) + random.below(3)
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

/// One square of a spiral order, and the quarter turn of the spiral inside
/// it.
///
/// The grid is cut the way a Fibonacci rectangle is: the largest square off
/// one side, then the largest off the next side round, clockwise, and so on
/// until nothing is left. An 8 x 5 grid gives squares of 5, 3, 2, 1 and 1.
/// The spiral turns a quarter in each square, about the corner where the
/// square meets the rest, and passes from each square straight into the
/// next. A grid whose sides are not neighbouring Fibonacci numbers still
/// cuts cleanly, but now and then the spiral has to skip a side.
public struct SpiralSquare: Equatable, Sendable {
    public enum Side: Sendable, CaseIterable {
        case left, top, right, bottom
    }

    /// The top-left tile and the side, in tiles.
    public let x: Int, y: Int, side: Int
    /// The side of what was left that it was cut from.
    public let cut: Side

    public init(x: Int, y: Int, side: Int, cut: Side) {
        self.x = x
        self.y = y
        self.side = side
        self.cut = cut
    }

    /// The squares, largest first, as the spiral passes through them going
    /// inward.
    public static func cut(columns: Int, rows: Int) -> [SpiralSquare] {
        let sides = Side.allCases
        var x = 0, y = 0, w = columns, h = rows
        var next = w >= h ? 0 : 1
        var squares: [SpiralSquare] = []
        while w > 0, h > 0 {
            // A square fits off the left or right only while what is left is
            // at least as wide as it is tall; off the top or bottom, as tall.
            while [.left, .right].contains(sides[next]) ? w < h : h < w {
                next = (next + 1) % 4
            }
            let s = min(w, h)
            switch sides[next] {
            case .left:
                squares.append(SpiralSquare(x: x, y: y, side: s, cut: .left))
                x += s
                w -= s
            case .top:
                squares.append(SpiralSquare(x: x, y: y, side: s, cut: .top))
                y += s
                h -= s
            case .right:
                squares.append(SpiralSquare(x: x + w - s, y: y, side: s, cut: .right))
                w -= s
            case .bottom:
                squares.append(SpiralSquare(x: x, y: y + h - s, side: s, cut: .bottom))
                h -= s
            }
            next = (next + 1) % 4
        }
        return squares
    }

    /// How far through this square's quarter turn the spiral is, from 0 to
    /// 1, when it passes the middle of tile (column, row), going inward.
    public func turn(column: Int, row: Int) -> Double {
        let s = Double(side), left = Double(x), top = Double(y)
        // The corner it turns about, and the directions it sets off from and
        // arrives at, with rows counting down.
        let (cx, cy, from, to): (Double, Double, (Double, Double), (Double, Double)) = switch cut {
        case .left: (left + s, top + s, (-1, 0), (0, -1))
        case .top: (left, top + s, (0, -1), (1, 0))
        case .right: (left, top, (1, 0), (0, 1))
        case .bottom: (left + s, top, (0, 1), (-1, 0))
        }
        let dx = Double(column) + 0.5 - cx, dy = Double(row) + 0.5 - cy
        return atan2(dx * to.0 + dy * to.1, dx * from.0 + dy * from.1) / (.pi / 2)
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
