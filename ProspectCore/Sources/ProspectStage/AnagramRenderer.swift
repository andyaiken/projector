import AppKit
import ProspectCore
import QuartzCore

/// Anagram cues: a phrase whose letters lift out of line and travel to spell
/// another. Letters heading right arc over the line and letters heading left
/// dip under it, so the two streams pass without touching. Each warms from
/// slate to bone on the way, as a decrypting title does.
///
/// The model says which letter goes where and when it sets off
/// (`AnagramPlan`). The clock triggers each letter; the journey itself is a
/// Core Animation path with its own duration, as a tile's flip is, so it runs
/// smoothly between the clock's frames.
@MainActor
public final class AnagramRenderer: CueRenderer {
    public let isInstant = false

    private var random: AnyUnitRandom
    private(set) var plan: AnagramPlan?
    private var clockSeconds = 0.044
    private var textScale = 100
    private var lastFrame: Int?
    /// The first paint of a cue put up finished lands without animating.
    private var fresh = true
    private var trees: [ObjectIdentifier: Tree] = [:]

    /// - Parameter random: The small extra delays on each letter. Tests pass
    ///   a seeded generator.
    public init(random: some UnitRandom = SystemUnitRandom()) {
        self.random = AnyUnitRandom(random)
    }

    /// One surface's layers.
    final class Tree {
        let surface: SurfaceLayer
        let root = StillLayer()
        var pieces: [PieceLayer] = []
        var layout: AnagramLayout?

        init(surface: SurfaceLayer) {
            self.surface = surface
            root.isHidden = true
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
        build(tree)
        fit(surface)
    }

    public func unmount(from surface: SurfaceLayer) {
        trees.removeValue(forKey: ObjectIdentifier(surface))?.root.removeFromSuperlayer()
    }

    public func setVisible(_ visible: Bool, on surface: SurfaceLayer) {
        tree(for: surface)?.root.isHidden = !visible
    }

    public func clear(_ surface: SurfaceLayer) {
        plan = nil
        lastFrame = nil
        guard let tree = tree(for: surface) else { return }
        tree.pieces.forEach { $0.removeFromSuperlayer() }
        tree.pieces = []
    }

    public func prepare(_ cue: Cue, defaults: ShowSettings) {
        guard case .anagram(let content) = cue.content else { return }
        let settings = defaults.resolved(content.overrides)
        plan = AnagramPlan(from: content.text, to: content.answer, wave: settings.waveTicks, random: &random)
        clockSeconds = Double(settings.clockMs) / 1000
        textScale = defaults.textScale
        lastFrame = nil
        fresh = true
        for tree in trees.values {
            build(tree)
            fit(tree.surface)
        }
    }

    /// Text size is show-wide and only layout, so an anagram on stage refits
    /// straight away.
    public func settingsChanged(_ defaults: ShowSettings) {
        guard defaults.textScale != textScale else { return }
        textScale = defaults.textScale
        for tree in trees.values { fit(tree.surface) }
    }

    public func frame(_ f: Int) -> Bool {
        lastFrame = f
        guard let plan else { return true }
        apply(f, animated: !(fresh && f >= plan.duration))
        fresh = false
        return f >= plan.duration
    }

    public func fit(_ surface: SurfaceLayer) {
        guard let tree = tree(for: surface) else { return }
        let size = surface.inset.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        tree.root.frame = CGRect(origin: .zero, size: size)
        guard let plan else { return }
        let layout = AnagramLayout(size: size, plan: plan, textScale: textScale)
        tree.layout = layout
        for (piece, layer) in zip(plan.pieces, tree.pieces) {
            layer.bounds = CGRect(x: 0, y: 0, width: layout.pitch, height: layout.lineHeight)
            for (face, colour) in [(layer.cold, Palette.slate), (layer.warm, Palette.bone)] {
                face.contentsScale = surface.contentsScale
                face.frame = layer.bounds
                face.baseline = layout.lineHeight - layout.baseline
                face.runs = [TextRun(text: String(piece.character), font: layout.font, colour: colour.cgColor, x: 0, cell: layout.pitch)]
            }
        }
        // Anything mid-journey picks up from where the new layout puts it.
        apply(lastFrame ?? -1_000_000, animated: false)
    }

    // MARK: Pieces

    private func build(_ tree: Tree) {
        tree.pieces.forEach { $0.removeFromSuperlayer() }
        tree.pieces = (plan?.pieces ?? []).map { _ in
            let layer = PieceLayer()
            tree.root.addSublayer(layer)
            return layer
        }
    }

    private func apply(_ f: Int, animated: Bool) {
        guard let plan else { return }
        for tree in trees.values {
            guard let layout = tree.layout else { continue }
            for (piece, layer) in zip(plan.pieces, tree.pieces) {
                let p = plan.progress(of: piece, at: f)
                let length = Double(piece.travels ? AnagramPlan.travelFrames : AnagramPlan.fadeFrames) * clockSeconds
                let elapsed = Double(f - piece.start) * clockSeconds
                if p >= 1 {
                    layer.land(at: layout.end(of: piece, plan: plan), shown: piece.to != nil)
                } else if f < piece.start {
                    layer.wait(at: layout.start(of: piece, plan: plan), shown: piece.from != nil)
                } else if piece.travels, let from = piece.from, let to = piece.to {
                    let path = layout.arc(from: from, to: to, plan: plan)
                    if animated {
                        layer.travel(along: path, elapsed: elapsed, duration: length)
                    } else {
                        layer.step(to: path.point(at: p), warmth: p)
                    }
                } else {
                    // Fading out where it began, or in where it lands.
                    let point = layout.start(of: piece, plan: plan)
                    let fadingIn = piece.from == nil
                    if animated {
                        layer.fade(in: fadingIn, at: point, elapsed: elapsed, duration: length)
                    } else {
                        layer.step(to: point, warmth: fadingIn ? 1 : 0, opacity: fadingIn ? p : 1 - p)
                    }
                }
            }
        }
    }
}

/// One character on stage: its slate face, with a bone face over it that
/// comes up as it travels.
final class PieceLayer: StillLayer {
    let cold = TextLayer()
    let warm = TextLayer()
    /// Set while a journey or fade is running as an animation, so later
    /// frames leave it be.
    private(set) var animating = false

    override init() {
        super.init()
        addSublayer(cold)
        addSublayer(warm)
        warm.opacity = 0
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// In its first place, not moving yet.
    func wait(at point: CGPoint, shown: Bool) {
        settle(at: point, warmth: shown ? 0 : 1, opacity: shown ? 1 : 0)
    }

    /// In its last place, or gone if it faded out.
    func land(at point: CGPoint, shown: Bool) {
        settle(at: point, warmth: 1, opacity: shown ? 1 : 0)
    }

    /// Partway, placed by hand: before a journey's animation can run, as
    /// when a surface is mounted mid-cue.
    func step(to point: CGPoint, warmth: Double, opacity: Double = 1) {
        settle(at: point, warmth: warmth, opacity: opacity)
    }

    private func settle(at point: CGPoint, warmth: Double, opacity: Double) {
        removeAllAnimations()
        warm.removeAllAnimations()
        animating = false
        position = point
        warm.opacity = Float(warmth)
        self.opacity = Float(opacity)
    }

    /// Sets off along its arc, already `elapsed` seconds in if the clock has
    /// run on since it was due.
    func travel(along arc: Arc, elapsed: Double, duration: Double) {
        guard !animating else { return }
        animating = true
        let begin = convertTime(CACurrentMediaTime(), from: nil) - max(0, elapsed)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = arc.path
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let warming = CABasicAnimation(keyPath: "opacity")
        warming.fromValue = 0
        warming.toValue = 1
        for (animation, layer, key) in [(move as CAAnimation, self as CALayer, "travel"), (warming, warm, "warm")] {
            animation.beginTime = begin
            animation.duration = duration
            animation.fillMode = .backwards
            layer.add(animation, forKey: key)
        }
        opacity = 1
        position = arc.end
        warm.opacity = 1
    }

    /// Fades out where it stands, or in where it lands.
    func fade(in fadingIn: Bool, at point: CGPoint, elapsed: Double, duration: Double) {
        guard !animating else { return }
        animating = true
        position = point
        warm.opacity = fadingIn ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fadingIn ? 0 : 1
        fade.toValue = fadingIn ? 1 : 0
        fade.beginTime = convertTime(CACurrentMediaTime(), from: nil) - max(0, elapsed)
        fade.duration = duration
        fade.fillMode = .backwards
        add(fade, forKey: "fade")
        opacity = fadingIn ? 1 : 0
    }
}

/// A letter's way from one place to another: a quadratic curve that bows
/// up when it heads right and down when it heads left.
struct Arc {
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint

    var path: CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    /// Where the letter is when it is `p` of the way through its time,
    /// eased in and out as the animation is.
    func point(at p: Double) -> CGPoint {
        let t = CGFloat(p * p * (3 - 2 * p)), u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
    }
}

/// Where an anagram's letters go on a surface: both phrases in one size of
/// type, each line centred, each phrase centred on the stage, so the letters
/// keep their size as they travel. Measured in Core Animation's coordinates,
/// from the bottom.
@MainActor
struct AnagramLayout {
    let size: CGSize
    let font: CTFont
    /// The width of one character's cell, and the height of a line.
    let pitch: CGFloat
    let lineHeight: CGFloat
    /// The baseline, from the top of a line.
    let baseline: CGFloat

    init(size: CGSize, plan: AnagramPlan, textScale: Int) {
        self.size = size
        let W = size.width, H = size.height
        let padding = 4 * min(W, H) / 100
        let n = CGFloat(max(plan.columns, 1)), rows = CGFloat(max(plan.rows, 1))
        // As large as fits 88% of the width, with every line of the taller
        // phrase in 70% of the height and no line taller than a decryption's.
        let fit = min(W * 0.88 / (n * TitleLayout.cellEms), H * 0.28, H * 0.7 / (rows * 1.3))
        let fontSize = max(9, fit * CGFloat(textScale) / 100)
        font = StageFont.title(size: fontSize)
        pitch = min(fontSize * TitleLayout.cellEms, (W - 2 * padding) * 0.9 / n)
        lineHeight = fontSize * 1.3
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        baseline = (lineHeight - (ascent + descent)) / 2 + ascent
    }

    /// Where a piece begins: its place in the first phrase, or, for one
    /// that fades in, its place in the second.
    func start(of piece: AnagramPlan.Piece, plan: AnagramPlan) -> CGPoint {
        if let from = piece.from { return centre(of: from, in: plan.fromLines) }
        if let to = piece.to { return centre(of: to, in: plan.toLines) }
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Where a piece ends: its place in the second phrase, or, for one that
    /// fades out, where it stood in the first.
    func end(of piece: AnagramPlan.Piece, plan: AnagramPlan) -> CGPoint {
        if let to = piece.to { return centre(of: to, in: plan.toLines) }
        if let from = piece.from { return centre(of: from, in: plan.fromLines) }
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    func centre(of slot: AnagramPlan.Slot, in lines: [String]) -> CGPoint {
        let length = CGFloat(lines.indices.contains(slot.line) ? lines[slot.line].count : 0)
        let x = (size.width - length * pitch) / 2 + (CGFloat(slot.column) + 0.5) * pitch
        let top = (size.height - CGFloat(lines.count) * lineHeight) / 2
        let y = top + (CGFloat(slot.line) + 0.5) * lineHeight
        return CGPoint(x: x, y: size.height - y)
    }

    /// The way from a place in the first phrase to one in the second. The
    /// bow is a third of the distance across, kept between half a line and a
    /// line and a half.
    func arc(from: AnagramPlan.Slot, to: AnagramPlan.Slot, plan: AnagramPlan) -> Arc {
        let a = centre(of: from, in: plan.fromLines), b = centre(of: to, in: plan.toLines)
        let dx = b.x - a.x
        let bow = dx == 0 ? 0 : min(max(abs(dx) / 3, lineHeight / 2), lineHeight * 1.5) * (dx > 0 ? 1 : -1)
        // A quadratic's control point sits twice as far out as its peak.
        let control = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + 2 * bow)
        return Arc(start: a, control: control, end: b)
    }
}
