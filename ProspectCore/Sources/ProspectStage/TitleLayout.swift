import CoreText
import Foundation

/// Where everything in a decryption cue goes on a surface of a given size,
/// measured from the top; rectangles are converted when they are applied to
/// layers.
///
/// Sizes are in `vmin`, a hundredth of the inset's shorter side, so the
/// layout scales with the projection area. Tests can pass a different vmin
/// to lay out against another reference size.
@MainActor
struct TitleLayout {
    /// Each title character gets a cell this many ems wide, a little wider
    /// than SF Mono's advance, which opens the tracking.
    static let cellEms: CGFloat = 0.72

    let size: CGSize

    // The place name: one glyph per cell, on one line or, when it is long,
    // on several, every cell the same size.
    let titleFont: CTFont
    let titleLines: [CGRect]
    let titleBaseline: CGFloat
    let pitch: CGFloat

    /// The title's first line, and for most titles its only one.
    var titleLine: CGRect { titleLines[0] }

    // The scene line: tracked out by a quarter of an em.
    let sceneFont: CTFont
    let sceneLine: CGRect
    let sceneBaseline: CGFloat
    let scenePitch: CGFloat

    // The frequency panel beneath.
    let readoutFont: CTFont
    let readoutAdvance: CGFloat
    let readoutLine: CGRect
    let readoutBaseline: CGFloat
    let bars: CGRect
    let barWidth: CGFloat
    let barGap: CGFloat
    let axisFont: CTFont
    let axisLine: CGRect
    let axisBaseline: CGFloat

    init(size: CGSize, titleCount: Int, sceneCount: Int, showsScene: Bool, histogram: Bool, textScale: Int, vmin: CGFloat? = nil) {
        self.init(size: size, titleLines: [titleCount], sceneCount: sceneCount, showsScene: showsScene, histogram: histogram,
                  textScale: textScale, vmin: vmin)
    }

    /// - Parameter titleLines: How many characters each line of the title
    ///   has.
    init(size: CGSize, titleLines lengths: [Int], sceneCount: Int, showsScene: Bool, histogram: Bool, textScale: Int, vmin: CGFloat? = nil) {
        self.size = size
        let W = size.width, H = size.height
        let vmin = vmin ?? min(W, H) / 100
        let padding = 4 * vmin
        let lengths = lengths.isEmpty ? [0] : lengths
        let n = CGFloat(max(lengths.max() ?? 0, 1)), rows = CGFloat(lengths.count)

        // Title size: the largest that fits its longest line in 88% of the
        // width, capped at 28% of the height, and with several lines at 62%
        // for all of them; then scaled by the show's text size. A line is
        // never wider than 90% of the plate inside its padding; past that the
        // cells close up.
        let fontSize = max(9, min(W * 0.88 / (n * Self.cellEms), H * 0.28, H * 0.62 / (rows * 1.05)) * CGFloat(textScale) / 100)
        let columnWidth = min((n * fontSize * Self.cellEms).rounded(), (W - 2 * padding) * 0.9)
        pitch = columnWidth / n
        titleFont = StageFont.title(size: fontSize)
        let titleLineHeight = fontSize * 1.05
        titleBaseline = Self.baseline(of: titleFont, inLineOf: titleLineHeight)

        let sceneSize = max(7, fontSize * 0.17)
        sceneFont = StageFont.text(size: sceneSize)
        scenePitch = StageFont.advance(of: sceneFont) + sceneSize * 0.26
        let sceneLineHeight = StageFont.normalLineHeight(of: sceneFont)
        sceneBaseline = Self.baseline(of: sceneFont, inLineOf: sceneLineHeight)
        let sceneGap = sceneSize * 1.5

        readoutFont = StageFont.text(size: max(7, H * 0.022))
        readoutAdvance = StageFont.advance(of: readoutFont)
        let readoutLineHeight = StageFont.normalLineHeight(of: readoutFont)
        readoutBaseline = Self.baseline(of: readoutFont, inLineOf: readoutLineHeight)
        axisFont = StageFont.text(size: max(6, H * 0.018))
        let axisLineHeight = StageFont.normalLineHeight(of: axisFont)
        axisBaseline = Self.baseline(of: axisFont, inLineOf: axisLineHeight)

        // The frequency panel sits at the bottom, at its natural height.
        let barsHeight = max(15 * vmin, 44)
        let panelHeight = readoutLineHeight + 1.5 * vmin + barsHeight + 0.7 * vmin + axisLineHeight + 3.2 * vmin
        let panelTop = histogram ? H - panelHeight : H
        let panelWidth = W - 2 * padding
        readoutLine = CGRect(x: padding, y: panelTop, width: panelWidth, height: readoutLineHeight)
        bars = CGRect(x: padding, y: readoutLine.maxY + 1.5 * vmin, width: panelWidth, height: barsHeight)
        axisLine = CGRect(x: padding, y: bars.maxY + 0.7 * vmin, width: panelWidth, height: axisLineHeight)
        barGap = 0.3 * vmin
        barWidth = (panelWidth - 25 * barGap) / 26

        // The plate takes the rest, and centres the title and scene line in it.
        let plate = CGRect(x: 0, y: 0, width: W, height: panelTop).insetBy(dx: padding, dy: padding)
        let lineGap = fontSize * 0.12
        let titleHeight = rows * titleLineHeight + (rows - 1) * lineGap
        let blockHeight = titleHeight + (showsScene ? sceneGap + sceneLineHeight : 0)
        let blockTop = plate.minY + (plate.height - blockHeight) / 2
        let pitch = self.pitch
        titleLines = lengths.enumerated().map { k, length in
            let width = CGFloat(max(length, 1)) * pitch
            return CGRect(x: (W - width) / 2, y: blockTop + CGFloat(k) * (titleLineHeight + lineGap), width: width, height: titleLineHeight)
        }
        let sceneWidth = CGFloat(sceneCount) * scenePitch
        sceneLine = CGRect(x: (W - sceneWidth) / 2, y: titleLines[titleLines.count - 1].maxY + sceneGap, width: sceneWidth,
                           height: sceneLineHeight)
    }

    /// The left edge of title cell `i`, within the title line.
    func titleCell(_ i: Int) -> CGFloat { CGFloat(i) * pitch }

    /// The left edge of histogram bar `i`, within the bars.
    func barX(_ i: Int) -> CGFloat { CGFloat(i) * (barWidth + barGap) }

    /// Where CSS puts the baseline in a line box, measured from its top:
    /// half the leading above the ascent.
    private static func baseline(of font: CTFont, inLineOf height: CGFloat) -> CGFloat {
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        return (height - (ascent + descent)) / 2 + ascent
    }
}
