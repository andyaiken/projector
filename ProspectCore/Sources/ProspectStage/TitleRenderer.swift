import AppKit
import ProspectCore
import QuartzCore

/// Title cues: a place name resolving out of Vigenère ciphertext, with a live
/// letter-frequency histogram beneath it.
///
/// The model works out each frame once (`TitleReveal`); this paints it on
/// every surface.
@MainActor
public final class TitleRenderer: CueRenderer {
    public let isInstant = false

    /// How long a histogram bar takes to reach its new height.
    static let barDuration: CFTimeInterval = 0.11

    private var random: AnyUnitRandom
    private let reduceMotion: () -> Bool

    private var reveal: TitleReveal?
    private var textScale = 100
    /// The frame on screen, kept so a resize or a newly mounted surface can
    /// repaint it.
    private(set) var current: TitleFrame?
    /// The first paint of a cue lands without animation, so the bars appear
    /// at their opening heights instead of travelling there.
    private var fresh = true
    private var trees: [ObjectIdentifier: Tree] = [:]

    /// - Parameters:
    ///   - random: Where the glyphs a character shows before rotating come
    ///     from. Tests pass a seeded generator.
    ///   - reduceMotion: When true, bars jump rather than glide.
    public init(
        random: some UnitRandom = SystemUnitRandom(),
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.random = AnyUnitRandom(random)
        self.reduceMotion = reduceMotion
    }

    /// One surface's layers.
    final class Tree {
        let surface: SurfaceLayer
        let root = StillLayer()
        /// A layer per line of the title.
        var titleLines = [TextLayer()]
        var title: TextLayer { titleLines[0] }
        let scene = TextLayer()
        let panel = StillLayer()
        let readouts = TextLayer()
        let ghosts = (0..<26).map { _ in StillLayer() }
        let bars = (0..<26).map { _ in StillLayer() }
        let axis = TextLayer()
        var layout: TitleLayout?

        init(surface: SurfaceLayer) {
            self.surface = surface
            root.isHidden = true
            root.addSublayer(title)
            root.addSublayer(scene)
            root.addSublayer(panel)
            panel.addSublayer(readouts)
            for ghost in ghosts {
                ghost.backgroundColor = Palette.brass.cgColor(alpha: 0.45)
                panel.addSublayer(ghost)
            }
            for bar in bars {
                bar.backgroundColor = Palette.bone.cgColor(alpha: 0.94)
                bar.anchorPoint = CGPoint(x: 0.5, y: 0)
                panel.addSublayer(bar)
            }
            panel.addSublayer(axis)
        }
    }

    func tree(for surface: SurfaceLayer) -> Tree? {
        trees[ObjectIdentifier(surface)]
    }

    // MARK: CueRenderer

    public func mount(on surface: SurfaceLayer) {
        let tree = Tree(surface: surface)
        trees[ObjectIdentifier(surface)] = tree
        surface.inset.addSublayer(tree.root)
        fit(surface)
    }

    public func unmount(from surface: SurfaceLayer) {
        trees.removeValue(forKey: ObjectIdentifier(surface))?.root.removeFromSuperlayer()
    }

    public func setVisible(_ visible: Bool, on surface: SurfaceLayer) {
        trees[ObjectIdentifier(surface)]?.root.isHidden = !visible
    }

    public func clear(_ surface: SurfaceLayer) {
        reveal = nil
        current = nil
        guard let tree = trees[ObjectIdentifier(surface)] else { return }
        tree.titleLines.forEach { $0.runs = [] }
        tree.scene.runs = []
        tree.readouts.runs = []
        for bar in tree.bars {
            bar.removeAllAnimations()
            bar.bounds.size.height = 0
        }
    }

    public func prepare(_ cue: Cue, defaults: ShowSettings) {
        guard case .title(let content) = cue.content else { return }
        reveal = TitleReveal(cue: content, settings: defaults.resolved(content.overrides), random: &random)
        textScale = defaults.textScale
        current = nil
        fresh = true
        for tree in trees.values { fit(tree.surface) }
    }

    /// Text size is show-wide and only layout, so a title on stage refits
    /// straight away.
    public func settingsChanged(_ defaults: ShowSettings) {
        guard defaults.textScale != textScale else { return }
        textScale = defaults.textScale
        for tree in trees.values { fit(tree.surface) }
    }

    public func frame(_ f: Int) -> Bool {
        guard let reveal else { return true }
        let frame = reveal.frame(f, random: &random)
        current = frame
        let animated = !fresh && !reduceMotion()
        for tree in trees.values { paint(frame, on: tree, animated: animated) }
        fresh = false
        return frame.isSettled
    }

    public func fit(_ surface: SurfaceLayer) {
        guard let tree = trees[ObjectIdentifier(surface)] else { return }
        let size = surface.inset.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let layout = TitleLayout(
            size: size,
            titleLines: reveal?.titleLines.map(\.count) ?? [0],
            sceneCount: reveal?.scenePlan.characters.count ?? 0,
            showsScene: reveal?.showsScene ?? false,
            histogram: reveal?.histogram ?? true,
            textScale: textScale
        )
        tree.layout = layout

        let H = size.height
        let scale = surface.contentsScale
        tree.root.frame = CGRect(origin: .zero, size: size)
        // One text layer for each line of the title.
        while tree.titleLines.count < layout.titleLines.count {
            let line = TextLayer()
            tree.root.insertSublayer(line, above: tree.titleLines.last)
            tree.titleLines.append(line)
        }
        while tree.titleLines.count > layout.titleLines.count { tree.titleLines.removeLast().removeFromSuperlayer() }
        for layer in tree.titleLines + [tree.scene, tree.readouts, tree.axis] { layer.contentsScale = scale }

        for (line, rect) in zip(tree.titleLines, layout.titleLines) {
            line.frame = rect.flipped(within: H)
            line.baseline = rect.height - layout.titleBaseline
        }
        tree.scene.frame = layout.sceneLine.flipped(within: H)
        tree.scene.baseline = layout.sceneLine.height - layout.sceneBaseline
        // Letters on dials roll through a window the height of their line,
        // softened at its top and bottom edges.
        let dials = reveal?.letters == .dials
        for line in tree.titleLines { line.mask = dials ? Self.window(line.bounds) : nil }
        tree.scene.mask = dials ? Self.window(tree.scene.bounds) : nil
        tree.scene.isHidden = !(reveal?.showsScene ?? false)

        // The panel's children are placed in the inset's coordinates.
        tree.panel.frame = tree.root.bounds
        tree.panel.isHidden = !(reveal?.histogram ?? true)
        tree.readouts.frame = layout.readoutLine.flipped(within: H)
        tree.readouts.baseline = layout.readoutLine.height - layout.readoutBaseline
        tree.axis.frame = layout.axisLine.flipped(within: H)
        tree.axis.baseline = layout.axisLine.height - layout.axisBaseline
        // A to Z, or the 26 commonest digraphs, each over its expected share.
        let digraphs = reveal?.bars == .digraphs
        let labels = digraphs ? English.digraphs : Cipher.alphabet.map(String.init)
        let ghostHeights = digraphs ? English.digraphGhostHeights : English.ghostHeights
        tree.axis.runs = labels.enumerated().map { i, label in
            TextRun(text: label.lowercased(), font: layout.axisFont, colour: Palette.slate.cgColor,
                    x: layout.barX(i), cell: layout.barWidth)
        }

        let barsBottom = H - layout.bars.maxY
        for i in 0..<26 {
            let x = layout.bars.minX + layout.barX(i)
            // The ghost is the 2px top border of a box as tall as English
            // expects; CSS never lets that box be shorter than its border.
            let ghostTop = max(layout.bars.height * ghostHeights[i] / 100, 2)
            tree.ghosts[i].frame = CGRect(x: x, y: barsBottom + ghostTop - 2, width: layout.barWidth, height: 2)
            tree.bars[i].bounds = CGRect(x: 0, y: 0, width: layout.barWidth, height: tree.bars[i].bounds.height)
            tree.bars[i].position = CGPoint(x: x + layout.barWidth / 2, y: barsBottom)
        }

        if let current { paint(current, on: tree, animated: false) }
    }

    // MARK: Painting

    private func paint(_ frame: TitleFrame, on tree: Tree, animated: Bool) {
        guard let layout = tree.layout else { return }

        // Each line of the title in its own layer; the space a long title
        // wraps at is drawn on neither.
        let lines = reveal?.titleLines ?? [0..<frame.title.count]
        for (layer, range) in zip(tree.titleLines, lines) {
            layer.runs = range.clamped(to: frame.title.indices).enumerated().flatMap { column, i in
                Self.runs(for: frame.title[i], font: layout.titleFont, alpha: 1, x: layout.titleCell(column), cell: layout.pitch,
                          row: layout.titleLine.height)
            }
        }
        // The scene line is drawn at 70% opacity, a step behind the place.
        tree.scene.runs = frame.scene.enumerated().flatMap { i, g in
            Self.runs(for: g, font: layout.sceneFont, alpha: 0.7, x: CGFloat(i) * layout.scenePitch, cell: nil,
                      row: layout.sceneLine.height)
        }

        guard reveal?.histogram ?? true else { return }
        tree.readouts.runs = readoutRuns(frame, layout: layout)
        for (bar, height) in zip(tree.bars, frame.barHeights) {
            setHeight(of: bar, to: layout.bars.height * height / 100, animated: animated)
        }
    }

    /// A line's window for letters on dials: clear at the very top and
    /// bottom, whole through the middle.
    static func window(_ bounds: CGRect) -> CALayer {
        let mask = CAGradientLayer()
        mask.frame = bounds
        mask.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)]
        mask.locations = [0, 0.12, 0.88, 1]
        mask.actions = ["bounds": NSNull(), "position": NSNull()]
        return mask
    }

    /// One character: its glyph, or, on a dial, the glyphs in its window, a
    /// line apart, so one rolls out as the next rolls in, a little dimmer
    /// the further from the middle. A dial at rest shows only its own.
    static func runs(for g: GlyphState, font: CTFont, alpha: CGFloat, x: CGFloat, cell: CGFloat?, row: CGFloat) -> [TextRun] {
        guard let dial = g.dial else {
            return [TextRun(text: String(g.glyph), font: font, colour: g.colour.cgColor(alpha: alpha), x: x, cell: cell)]
        }
        let n = Cipher.ring.count
        let base = Int(dial.rounded(.down))
        return (base...base + 1).compactMap { i in
            // Below the window for a glyph further round the ring: A sits
            // above B, as on a drum read from the front.
            let offset = CGFloat(Double(i) - dial)
            guard abs(offset) < 1 else { return nil }
            let weight = 1 - 0.5 * abs(offset)
            let glyph = Cipher.ring[((i % n) + n) % n]
            let text = g.isSettled && abs(offset) < 0.5 ? String(g.glyph) : String(glyph == " " ? Cipher.spaceMark : glyph)
            return TextRun(text: text, font: font, colour: g.colour.cgColor(alpha: alpha * weight), x: x, cell: cell, dy: -offset * row)
        }
    }

    /// Three label-and-value pairs, centred as a row: labels in slate, values
    /// in bone at 85%. Every character is one advance wide, so widths are
    /// counted rather than measured.
    private func readoutRuns(_ frame: TitleFrame, layout: TitleLayout) -> [TextRun] {
        let em = CTFontGetSize(layout.readoutFont)
        let pairs = [
            ("solved", frame.solvedText),
            ("key length", frame.keyLengthText),
            ("\u{03C7}\u{00B2}", frame.chiSquaredText),
        ]
        func width(_ s: String) -> CGFloat { CGFloat(s.count) * layout.readoutAdvance }
        let total = pairs.reduce(0) { $0 + width($1.0) + 0.6 * em + width($1.1) } + 2 * 2.4 * em
        var x = (layout.readoutLine.width - total) / 2
        var runs: [TextRun] = []
        for (label, value) in pairs {
            runs.append(TextRun(text: label, font: layout.readoutFont, colour: Palette.slate.cgColor, x: x))
            x += width(label) + 0.6 * em
            runs.append(TextRun(text: value, font: layout.readoutFont, colour: Palette.bone.cgColor(alpha: 0.85), x: x))
            x += width(value) + 2.4 * em
        }
        return runs
    }

    /// Bars glide to each new height over 110 ms, linearly, picking up from
    /// wherever they are. With frames every 44 ms they are always chasing,
    /// which is the look.
    private func setHeight(of bar: CALayer, to height: CGFloat, animated: Bool) {
        // A bar already at, or already gliding to, this height carries on.
        guard height != bar.bounds.height else { return }
        let from = bar.presentation()?.bounds.height ?? bar.bounds.height
        bar.bounds.size.height = height
        guard animated, from != height else {
            bar.removeAnimation(forKey: "height")
            return
        }
        let glide = CABasicAnimation(keyPath: "bounds.size.height")
        glide.fromValue = from
        glide.toValue = height
        glide.duration = Self.barDuration
        glide.timingFunction = CAMediaTimingFunction(name: .linear)
        bar.add(glide, forKey: "height")
    }
}
