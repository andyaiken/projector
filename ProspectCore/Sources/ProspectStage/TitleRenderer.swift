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
        let title = TextLayer()
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
        tree.title.runs = []
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
            titleCount: reveal?.titlePlan.characters.count ?? 0,
            sceneCount: reveal?.scenePlan.characters.count ?? 0,
            showsScene: reveal?.showsScene ?? false,
            histogram: reveal?.histogram ?? true,
            textScale: textScale
        )
        tree.layout = layout

        let H = size.height
        let scale = surface.contentsScale
        tree.root.frame = CGRect(origin: .zero, size: size)
        for layer in [tree.title, tree.scene, tree.readouts, tree.axis] { layer.contentsScale = scale }

        tree.title.frame = layout.titleLine.flipped(within: H)
        tree.title.baseline = layout.titleLine.height - layout.titleBaseline
        tree.scene.frame = layout.sceneLine.flipped(within: H)
        tree.scene.baseline = layout.sceneLine.height - layout.sceneBaseline
        tree.scene.isHidden = !(reveal?.showsScene ?? false)

        // The panel's children are placed in the inset's coordinates.
        tree.panel.frame = tree.root.bounds
        tree.panel.isHidden = !(reveal?.histogram ?? true)
        tree.readouts.frame = layout.readoutLine.flipped(within: H)
        tree.readouts.baseline = layout.readoutLine.height - layout.readoutBaseline
        tree.axis.frame = layout.axisLine.flipped(within: H)
        tree.axis.baseline = layout.axisLine.height - layout.axisBaseline
        tree.axis.runs = Cipher.alphabet.enumerated().map { i, letter in
            TextRun(text: String(letter).lowercased(), font: layout.axisFont, colour: Palette.slate.cgColor,
                    x: layout.barX(i), cell: layout.barWidth)
        }

        let barsBottom = H - layout.bars.maxY
        for i in 0..<26 {
            let x = layout.bars.minX + layout.barX(i)
            // The ghost is the 2px top border of a box as tall as English
            // expects; CSS never lets that box be shorter than its border.
            let ghostTop = max(layout.bars.height * English.ghostHeights[i] / 100, 2)
            tree.ghosts[i].frame = CGRect(x: x, y: barsBottom + ghostTop - 2, width: layout.barWidth, height: 2)
            tree.bars[i].bounds = CGRect(x: 0, y: 0, width: layout.barWidth, height: tree.bars[i].bounds.height)
            tree.bars[i].position = CGPoint(x: x + layout.barWidth / 2, y: barsBottom)
        }

        if let current { paint(current, on: tree, animated: false) }
    }

    // MARK: Painting

    private func paint(_ frame: TitleFrame, on tree: Tree, animated: Bool) {
        guard let layout = tree.layout else { return }

        tree.title.runs = frame.title.enumerated().map { i, g in
            TextRun(text: String(g.glyph), font: layout.titleFont, colour: g.colour.cgColor,
                    x: layout.titleCell(i), cell: layout.pitch)
        }
        // The scene line is drawn at 70% opacity, a step behind the place.
        tree.scene.runs = frame.scene.enumerated().map { i, g in
            TextRun(text: String(g.glyph), font: layout.sceneFont, colour: g.colour.cgColor(alpha: 0.7),
                    x: CGFloat(i) * layout.scenePitch)
        }

        guard reveal?.histogram ?? true else { return }
        tree.readouts.runs = readoutRuns(frame, layout: layout)
        for (bar, height) in zip(tree.bars, frame.barHeights) {
            setHeight(of: bar, to: layout.bars.height * height / 100, animated: animated)
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
