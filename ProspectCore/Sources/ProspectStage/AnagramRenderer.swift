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
public final class AnagramRenderer: CueRenderer, ReportsProblems {
    public let isInstant = false
    public var onProblem: ((String) -> Void)?

    private var random: AnyUnitRandom
    private(set) var plan: AnagramPlan?
    private var clockSeconds = 0.044
    private var textScale = 100
    private var family = ""
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
        family = settings.font
        if !family.isEmpty, !StageFont.has(family: family) {
            let name = cue.number.isEmpty ? "This anagram" : "Cue \(cue.number)"
            onProblem?("\(name)\u{2019}s font, \(family), isn\u{2019}t on this Mac, so it shows in \(SettingKey.stageFont) instead.")
        }
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
        let layout = AnagramLayout(size: size, plan: plan, textScale: textScale, family: family)
        tree.layout = layout
        for (piece, layer) in zip(plan.pieces, tree.pieces) {
            layer.bounds = layout.box
            layer.morphs = piece.character != piece.landing
            // Slate as the first phrase has it, bone as the answer does.
            for (face, character, colour) in [(layer.cold, piece.character, Palette.slate), (layer.warm, piece.landing, Palette.bone)] {
                face.contentsScale = surface.contentsScale
                face.frame = layer.bounds
                face.baseline = layout.boxBaseline
                face.runs = [TextRun(text: String(character), font: layout.font, colour: colour.cgColor, x: 0, cell: layout.box.width)]
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
    /// The two faces are different glyphs, as when a letter changes case on
    /// the way, so the slate one goes as the bone one comes. Otherwise the
    /// bone one simply covers it.
    var morphs = false
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
        cold.removeAllAnimations()
        animating = false
        position = point
        warm.opacity = Float(warmth)
        cold.opacity = morphs ? Float(1 - warmth) : 1
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
        var animations = [(move as CAAnimation, self as CALayer, "travel"), (warming, warm, "warm")]
        if morphs {
            let cooling = CABasicAnimation(keyPath: "opacity")
            cooling.fromValue = 1
            cooling.toValue = 0
            animations.append((cooling, cold, "cool"))
            cold.opacity = 0
        }
        for (animation, layer, key) in animations {
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
/// keep their size as they travel. Every line is measured in its own font,
/// so each letter starts and lands where the font sets it, its own width and
/// the kerning between letters included; a monospaced font is one case.
/// Measured in Core Animation's coordinates, from the bottom.
@MainActor
struct AnagramLayout {
    let size: CGSize
    let font: CTFont
    let lineHeight: CGFloat
    /// One letter's layer, with room for any glyph's flourishes.
    let box: CGRect
    /// The baseline, above the bottom of a letter's box.
    let boxBaseline: CGFloat
    /// Each line's width, and the middle of each of its characters from the
    /// line's left edge.
    private let from: [Measured], to: [Measured]

    struct Measured {
        var width: CGFloat
        var centres: [CGFloat]
    }

    init(size: CGSize, plan: AnagramPlan, textScale: Int, family: String = "") {
        self.size = size
        let W = size.width, H = size.height
        let padding = 4 * min(W, H) / 100
        let rows = CGFloat(max(plan.rows, 1))
        // SF Mono is opened out to a decryption's 0.72 em cells; a chosen
        // font gets a little air between its letters.
        let monospaced = family.isEmpty || !StageFont.has(family: family)
        func tracking(_ font: CTFont) -> CGFloat {
            let size = CTFontGetSize(font)
            return monospaced ? TitleLayout.cellEms * size - StageFont.advance(of: font) : 0.04 * size
        }
        let lines = plan.fromLines + plan.toLines
        let reference = StageFont.anagram(family: family, size: 100)
        let widest = lines.map { Self.measure($0, font: reference, tracking: tracking(reference)).width }.max() ?? 0
        // As large as fits the width, with every line of the taller phrase in
        // 70% of the height and no line taller than a decryption's.
        let across = min(W * 0.88, (W - 2 * padding) * 0.9)
        let fit = min(widest > 0 ? across * 100 / widest : H, H * 0.28, H * 0.7 / (rows * 1.3))
        let fontSize = max(9, fit * CGFloat(textScale) / 100)
        let font = StageFont.anagram(family: family, size: fontSize)
        self.font = font
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        lineHeight = max(fontSize * 1.3, (ascent + descent + CTFontGetLeading(font)) * 1.1)
        box = CGRect(x: 0, y: 0, width: fontSize * 2, height: lineHeight * 1.6)
        boxBaseline = (box.height - lineHeight) / 2 + (lineHeight - ((lineHeight - (ascent + descent)) / 2 + ascent))
        let spacing = tracking(font)
        from = plan.fromLines.map { Self.measure($0, font: font, tracking: spacing) }
        to = plan.toLines.map { Self.measure($0, font: font, tracking: spacing) }
    }

    /// A line set in a font, `tracking` points apart: its width, and where
    /// the middle of each character's glyph falls, as Core Text sets them,
    /// kerning and any fallback font included.
    static func measure(_ text: String, font: CTFont, tracking: CGFloat) -> Measured {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var middles: [Int: CGFloat] = [:]
        var right: CGFloat = 0
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: n), positions = [CGPoint](repeating: .zero, count: n)
            var indices = [CFIndex](repeating: 0, count: n), advances = [CGSize](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetStringIndices(run, CFRange(), &indices)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
            CTFontGetAdvancesForGlyphs(runFont, .horizontal, glyphs, &advances, n)
            for k in 0..<n {
                // A glyph's own width, without the tracking set after it.
                if middles[indices[k]] == nil { middles[indices[k]] = positions[k].x + advances[k].width / 2 }
                right = max(right, positions[k].x + advances[k].width)
            }
        }
        var offset = 0, last: CGFloat = 0
        let centres = text.map { c -> CGFloat in
            // A character drawn as part of another's glyph, as in a
            // ligature, shares its middle.
            last = middles[offset] ?? last
            offset += String(c).utf16.count
            return last
        }
        return Measured(width: right, centres: centres)
    }

    /// Where a piece begins: its place in the first phrase, or, for one
    /// that fades in, its place in the second.
    func start(of piece: AnagramPlan.Piece, plan: AnagramPlan) -> CGPoint {
        if let from = piece.from { return centre(of: from, answer: false) }
        if let to = piece.to { return centre(of: to, answer: true) }
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Where a piece ends: its place in the second phrase, or, for one that
    /// fades out, where it stood in the first.
    func end(of piece: AnagramPlan.Piece, plan: AnagramPlan) -> CGPoint {
        if let to = piece.to { return centre(of: to, answer: true) }
        if let from = piece.from { return centre(of: from, answer: false) }
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// The middle of a character in the first phrase, or with `answer`, the
    /// second.
    func centre(of slot: AnagramPlan.Slot, answer: Bool) -> CGPoint {
        let lines = answer ? to : from
        guard lines.indices.contains(slot.line) else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let line = lines[slot.line]
        let x = (size.width - line.width) / 2 + (line.centres.indices.contains(slot.column) ? line.centres[slot.column] : 0)
        let top = (size.height - CGFloat(lines.count) * lineHeight) / 2
        let y = top + (CGFloat(slot.line) + 0.5) * lineHeight
        return CGPoint(x: x, y: size.height - y)
    }

    /// The way from a place in the first phrase to one in the second. The
    /// bow is a third of the distance across, kept between half a line and a
    /// line and a half.
    func arc(from: AnagramPlan.Slot, to: AnagramPlan.Slot, plan: AnagramPlan) -> Arc {
        let a = centre(of: from, answer: false), b = centre(of: to, answer: true)
        let dx = b.x - a.x
        let bow = dx == 0 ? 0 : min(max(abs(dx) / 3, lineHeight / 2), lineHeight * 1.5) * (dx > 0 ? 1 : -1)
        // A quadratic's control point sits twice as far out as its peak.
        let control = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + 2 * bow)
        return Arc(start: a, control: control, end: b)
    }
}
