import AppKit
import ProspectCore
import QuartzCore

/// Anagram cues: phrases whose letters lift out of line and travel to spell
/// others. Letters heading right arc over the line and letters heading left
/// dip under it, so the two streams pass without touching. Each warms from
/// slate to bone as it lands in the answer, as a decrypting title does.
///
/// A cue can hold several anagrams, stacked, solved one after another, and
/// each can show working on the way: steps that may be partial or wrong.
/// Working stays slate, and the letters a step doesn't use dim on a line
/// beneath it until a later step takes them up.
///
/// The model says which letter goes where and when it sets off
/// (`AnagramCuePlan`). The clock triggers each letter; the journey itself is
/// a Core Animation path with its own duration, as a tile's flip is, so it
/// runs smoothly between the clock's frames.
@MainActor
public final class AnagramRenderer: CueRenderer, ReportsProblems, WaitsForGO {
    public let isInstant = false
    public var onProblem: ((String) -> Void)?

    private var random: AnyUnitRandom
    private(set) var plan: AnagramCuePlan?
    /// When each part of the cue starts, as GO lets them go.
    private(set) var timeline = AnagramCuePlan.Timeline(parts: [0])
    private var clockSeconds = 0.044
    private var textScale = 100
    private var family = ""
    private(set) var lastFrame: Int?
    /// The first paint of a cue put up finished lands without animating.
    private var fresh = true
    private var trees: [ObjectIdentifier: Tree] = [:]

    /// How bright a letter is on the line of those a step leaves unused.
    static let dimmed = 0.4

    /// - Parameter random: The small extra delays on each letter. Tests pass
    ///   a seeded generator.
    public init(random: some UnitRandom = SystemUnitRandom()) {
        self.random = AnyUnitRandom(random)
    }

    /// One surface's layers.
    final class Tree {
        let surface: SurfaceLayer
        let root = StillLayer()
        /// Each anagram's letters.
        var tracks: [TrackLayers] = []
        var layout: AnagramLayout?

        init(surface: SurfaceLayer) {
            self.surface = surface
            root.isHidden = true
        }
    }

    /// One anagram's letters on a surface, built for the move it is showing
    /// and built again when the next sets off. The two meet exactly: a move's
    /// letters land where the next one's stand waiting.
    final class TrackLayers {
        var shown: Shown?
        var pieces: [PieceLayer] = []
    }

    /// What one anagram shows: a move from one of its steps to the next, or
    /// where it stands when the cue doesn't solve it.
    struct Shown: Equatable {
        var track: Int
        /// Nil for an anagram standing still.
        var move: Int?
        var plan: AnagramPlan
        /// The steps it goes from and to.
        var from: Int
        var to: Int
        /// Into the answer, so the letters warm to bone.
        var warms: Bool
        /// The frame it set off, or nil while it waits for GO or stands still.
        var start: Int?
        /// Standing still, solved already: in bone from the start.
        var solvedAlready = false
    }

    func tree(for surface: SurfaceLayer) -> Tree? {
        trees[ObjectIdentifier(surface)]
    }

    /// What anagram `t` shows on frame `f`.
    func shown(_ t: Int, at f: Int) -> Shown? {
        guard let plan, plan.tracks.indices.contains(t) else { return nil }
        let track = plan.tracks[t]
        guard let (index, start) = plan.shown(track, at: f, timeline: timeline) else {
            return Shown(track: t, move: nil, plan: track.still, from: 0, to: 0, warms: false, start: nil, solvedAlready: track.solvedAlready)
        }
        let move = track.moves[index]
        return Shown(track: t, move: index, plan: move.plan, from: index, to: index + 1, warms: move.warms, start: start)
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
        timeline = .init(parts: [0])
        lastFrame = nil
        guard let tree = tree(for: surface) else { return }
        for track in tree.tracks { track.pieces.forEach { $0.removeFromSuperlayer() } }
        tree.tracks = []
    }

    public func prepare(_ cue: Cue, defaults: ShowSettings) {
        guard case .anagram(let content) = cue.content else { return }
        let settings = defaults.resolved(content.overrides)
        let plan = AnagramCuePlan(content.anagrams, wave: settings.waveTicks, pause: settings.pauseTicks, advance: settings.advance,
                                  random: &random)
        self.plan = plan
        timeline = .init(parts: plan.parts)
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
        guard plan != nil else { return true }
        let finished = timeline.isFinished(at: f)
        apply(f, animated: !(fresh && finished))
        fresh = false
        return finished
    }

    public func fit(_ surface: SurfaceLayer) {
        guard let tree = tree(for: surface) else { return }
        let size = surface.inset.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        tree.root.frame = CGRect(origin: .zero, size: size)
        guard let plan else { return }
        let layout = AnagramLayout(size: size, plan: plan, textScale: textScale, family: family)
        tree.layout = layout
        for track in tree.tracks {
            guard let shown = track.shown else { continue }
            for (piece, layer) in zip(shown.plan.pieces, track.pieces) { dress(layer, as: piece, in: shown, layout: layout, scale: surface.contentsScale) }
        }
        // Anything mid-journey picks up from where the new layout puts it.
        apply(lastFrame ?? -1_000_000, animated: false)
    }

    // MARK: WaitsForGO

    public func isWaiting(at f: Int) -> Bool {
        plan != nil && timeline.isWaiting(at: f)
    }

    public func carryOn(at f: Int) {
        timeline.carryOn(at: f)
    }

    public func carryOnToEnd() {
        timeline.carryOnToEnd()
    }

    // MARK: Pieces

    private func build(_ tree: Tree) {
        for track in tree.tracks { track.pieces.forEach { $0.removeFromSuperlayer() } }
        tree.tracks = (plan?.tracks ?? []).map { _ in TrackLayers() }
    }

    /// Lays out a letter's two faces: as it stands before the move, in slate,
    /// and as it lands, in bone if it lands in the answer. One solved already
    /// stands in bone.
    private func dress(_ layer: PieceLayer, as piece: AnagramPlan.Piece, in shown: Shown, layout: AnagramLayout, scale: CGFloat) {
        layer.bounds = layout.box
        layer.morphs = piece.character != piece.landing
        let leaving = shown.solvedAlready ? Palette.bone : Palette.slate
        let landing = shown.warms || shown.solvedAlready ? Palette.bone : Palette.slate
        for (face, character, colour) in [(layer.before, piece.character, leaving), (layer.after, piece.landing, landing)] {
            face.contentsScale = scale
            face.frame = layer.bounds
            face.baseline = layout.boxBaseline
            face.runs = [TextRun(text: String(character), font: layout.font, colour: colour.cgColor, x: 0, cell: layout.box.width)]
        }
    }

    private func apply(_ f: Int, animated: Bool) {
        guard let plan else { return }
        for tree in trees.values {
            guard let layout = tree.layout else { continue }
            for (t, layers) in tree.tracks.enumerated() {
                guard let shown = shown(t, at: f) else { continue }
                // A new move sets off: its letters take over from the last's,
                // standing exactly where those landed.
                if layers.shown == nil || layers.shown?.move != shown.move {
                    layers.pieces.forEach { $0.removeFromSuperlayer() }
                    layers.pieces = shown.plan.pieces.map { piece in
                        let layer = PieceLayer()
                        dress(layer, as: piece, in: shown, layout: layout, scale: tree.surface.contentsScale)
                        tree.root.addSublayer(layer)
                        return layer
                    }
                }
                layers.shown = shown
                let steps = plan.tracks[t].steps
                // Frames since the move set off; long before, while it waits.
                let local = shown.start.map { f - $0 } ?? -1_000_000
                for (piece, layer) in zip(shown.plan.pieces, layers.pieces) {
                    place(layer, piece, at: local, in: shown, steps: steps, layout: layout, animated: animated)
                }
            }
        }
    }

    private func place(_ layer: PieceLayer, _ piece: AnagramPlan.Piece, at f: Int, in shown: Shown, steps: [AnagramCuePlan.Step],
                       layout: AnagramLayout, animated: Bool) {
        let p = shown.plan.progress(of: piece, at: f)
        let length = Double(piece.travels ? AnagramPlan.travelFrames : AnagramPlan.fadeFrames) * clockSeconds
        let elapsed = Double(f - piece.start) * clockSeconds
        // Full brightness, or dimmed among the letters a step leaves unused.
        let leaving = piece.from.map { steps[shown.from].isDim($0) ? Self.dimmed : 1 } ?? 0
        let arriving = piece.to.map { steps[shown.to].isDim($0) ? Self.dimmed : 1 } ?? 0
        if p >= 1 {
            layer.land(at: layout.end(of: piece, in: shown), opacity: arriving)
        } else if f < piece.start {
            layer.wait(at: layout.start(of: piece, in: shown), opacity: leaving, faded: piece.from == nil)
        } else if piece.travels, let from = piece.from, let to = piece.to {
            let path = layout.arc(from: from, to: to, in: shown)
            if animated {
                layer.travel(along: path, from: leaving, to: arriving, elapsed: elapsed, duration: length)
            } else {
                layer.step(to: path.point(at: p), progress: p, opacity: leaving + (arriving - leaving) * p)
            }
        } else {
            // Fading out where it began, or in where it lands.
            let point = layout.start(of: piece, in: shown)
            let fadingIn = piece.from == nil
            if animated {
                layer.fade(in: fadingIn, at: point, to: fadingIn ? arriving : leaving, elapsed: elapsed, duration: length)
            } else {
                layer.step(to: point, progress: fadingIn ? 1 : 0, opacity: fadingIn ? arriving * p : leaving * (1 - p))
            }
        }
    }
}

/// One character on stage: its face as it stands before a move, with its face
/// as it lands over it, which comes up as it travels.
final class PieceLayer: StillLayer {
    /// Slate.
    let before = TextLayer()
    /// Bone when it lands in the answer; slate in working.
    let after = TextLayer()
    /// The two faces are different glyphs, as when a letter changes case on
    /// the way, so the first goes as the second comes. Otherwise the second
    /// simply covers it.
    var morphs = false
    /// Set while a journey or fade is running as an animation, so later
    /// frames leave it be.
    private(set) var animating = false

    override init() {
        super.init()
        addSublayer(before)
        addSublayer(after)
        after.opacity = 0
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// In its first place, not moving yet. One that will fade in waits
    /// unseen, in its landing face.
    func wait(at point: CGPoint, opacity: Double, faded: Bool) {
        settle(at: point, progress: faded ? 1 : 0, opacity: opacity)
    }

    /// In its last place, or gone if it faded out.
    func land(at point: CGPoint, opacity: Double) {
        settle(at: point, progress: 1, opacity: opacity)
    }

    /// Partway, placed by hand: before a journey's animation can run, as
    /// when a surface is mounted mid-cue.
    func step(to point: CGPoint, progress: Double, opacity: Double) {
        settle(at: point, progress: progress, opacity: opacity)
    }

    private func settle(at point: CGPoint, progress: Double, opacity: Double) {
        removeAllAnimations()
        after.removeAllAnimations()
        before.removeAllAnimations()
        animating = false
        position = point
        after.opacity = Float(progress)
        before.opacity = morphs ? Float(1 - progress) : 1
        self.opacity = Float(opacity)
    }

    /// Sets off along its arc, already `elapsed` seconds in if the clock has
    /// run on since it was due, brightening or dimming on the way if it is
    /// joining or leaving the unused letters.
    func travel(along arc: Arc, from leaving: Double, to arriving: Double, elapsed: Double, duration: Double) {
        guard !animating else { return }
        animating = true
        let begin = convertTime(CACurrentMediaTime(), from: nil) - max(0, elapsed)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = arc.path
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let arrive = CABasicAnimation(keyPath: "opacity")
        arrive.fromValue = 0
        arrive.toValue = 1
        var animations = [(move as CAAnimation, self as CALayer, "travel"), (arrive, after, "arrive")]
        if morphs {
            let leave = CABasicAnimation(keyPath: "opacity")
            leave.fromValue = 1
            leave.toValue = 0
            animations.append((leave, before, "leave"))
            before.opacity = 0
        }
        if leaving != arriving {
            let dim = CABasicAnimation(keyPath: "opacity")
            dim.fromValue = leaving
            dim.toValue = arriving
            animations.append((dim, self, "dim"))
        }
        for (animation, layer, key) in animations {
            animation.beginTime = begin
            animation.duration = duration
            animation.fillMode = .backwards
            layer.add(animation, forKey: key)
        }
        opacity = Float(arriving)
        position = arc.end
        after.opacity = 1
    }

    /// Fades out where it stands, or in where it lands, to `opacity`.
    func fade(in fadingIn: Bool, at point: CGPoint, to opacity: Double, elapsed: Double, duration: Double) {
        guard !animating else { return }
        animating = true
        position = point
        after.opacity = fadingIn ? 1 : 0
        before.opacity = fadingIn && morphs ? 0 : 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fadingIn ? 0 : opacity
        fade.toValue = fadingIn ? opacity : 0
        fade.beginTime = convertTime(CACurrentMediaTime(), from: nil) - max(0, elapsed)
        fade.duration = duration
        fade.fillMode = .backwards
        add(fade, forKey: "fade")
        self.opacity = fadingIn ? Float(opacity) : 0
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

/// Where an anagram cue's letters go on a surface: every step of every
/// anagram in one size of type, so the letters keep their size as they
/// travel. The anagrams stack down the stage, each in a block with room for
/// its longest step, and each step's lines are centred in its block, so a
/// lone anagram's phrase and answer are each centred on the stage. Every
/// line is measured in its own font, so each letter starts and lands where
/// the font sets it, its own width and the kerning between letters included;
/// a monospaced font is one case. Measured in Core Animation's coordinates,
/// from the bottom.
@MainActor
struct AnagramLayout {
    let size: CGSize
    let font: CTFont
    let lineHeight: CGFloat
    /// One letter's layer, with room for any glyph's flourishes.
    let box: CGRect
    /// The baseline, above the bottom of a letter's box.
    let boxBaseline: CGFloat
    /// Every line of every step of every anagram: its width, and the middle
    /// of each of its characters from the line's left edge.
    private let steps: [[[Measured]]]
    /// Where each anagram's block begins, from the top, and how many lines
    /// it has room for.
    private let blocks: [(top: CGFloat, rows: Int)]

    /// Room between one anagram and the next, in lines.
    static let gap: CGFloat = 0.75

    struct Measured {
        var width: CGFloat
        var centres: [CGFloat]
    }

    init(size: CGSize, plan: AnagramCuePlan, textScale: Int, family: String = "") {
        self.size = size
        let W = size.width, H = size.height
        let padding = 4 * min(W, H) / 100
        let blockRows = plan.tracks.map { $0.steps.map(\.lines.count).max() ?? 0 }
        let rows = CGFloat(max(blockRows.reduce(0, +), 1)) + Self.gap * CGFloat(max(0, plan.tracks.count - 1))
        // SF Mono is opened out to a decryption's 0.72 em cells; a chosen
        // font gets a little air between its letters.
        let monospaced = family.isEmpty || !StageFont.has(family: family)
        func tracking(_ font: CTFont) -> CGFloat {
            let size = CTFontGetSize(font)
            return monospaced ? TitleLayout.cellEms * size - StageFont.advance(of: font) : 0.04 * size
        }
        let lines = plan.tracks.flatMap { $0.steps.flatMap(\.lines) }
        let reference = StageFont.anagram(family: family, size: 100)
        let widest = lines.map { Self.measure($0, font: reference, tracking: tracking(reference)).width }.max() ?? 0
        // As large as fits the width, with every line of every block in 70%
        // of the height and no line taller than a decryption's.
        let across = min(W * 0.88, (W - 2 * padding) * 0.9)
        let fit = min(widest > 0 ? across * 100 / widest : H, H * 0.28, H * 0.7 / (rows * 1.3))
        let fontSize = max(9, fit * CGFloat(textScale) / 100)
        let font = StageFont.anagram(family: family, size: fontSize)
        self.font = font
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = max(fontSize * 1.3, (ascent + descent + CTFontGetLeading(font)) * 1.1)
        self.lineHeight = lineHeight
        box = CGRect(x: 0, y: 0, width: fontSize * 2, height: lineHeight * 1.6)
        boxBaseline = (box.height - lineHeight) / 2 + (lineHeight - ((lineHeight - (ascent + descent)) / 2 + ascent))
        let spacing = tracking(font)
        steps = plan.tracks.map { $0.steps.map { $0.lines.map { Self.measure($0, font: font, tracking: spacing) } } }
        var top = (H - rows * lineHeight) / 2
        blocks = blockRows.map { n in
            defer { top += (CGFloat(n) + Self.gap) * lineHeight }
            return (top, n)
        }
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

    /// Where a piece begins: its place in the step it leaves, or, for one
    /// that fades in, its place in the step it lands in.
    func start(of piece: AnagramPlan.Piece, in shown: AnagramRenderer.Shown) -> CGPoint {
        if let from = piece.from { return centre(of: from, track: shown.track, step: shown.from) }
        if let to = piece.to { return centre(of: to, track: shown.track, step: shown.to) }
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Where a piece ends: its place in the step it lands in, or, for one
    /// that fades out, where it stood.
    func end(of piece: AnagramPlan.Piece, in shown: AnagramRenderer.Shown) -> CGPoint {
        if let to = piece.to { return centre(of: to, track: shown.track, step: shown.to) }
        if let from = piece.from { return centre(of: from, track: shown.track, step: shown.from) }
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// The middle of a character in one step of one anagram.
    func centre(of slot: AnagramPlan.Slot, track: Int, step: Int) -> CGPoint {
        guard steps.indices.contains(track), steps[track].indices.contains(step), steps[track][step].indices.contains(slot.line) else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let lines = steps[track][step], line = lines[slot.line], block = blocks[track]
        let x = (size.width - line.width) / 2 + (line.centres.indices.contains(slot.column) ? line.centres[slot.column] : 0)
        let top = block.top + CGFloat(block.rows - lines.count) * lineHeight / 2
        let y = top + (CGFloat(slot.line) + 0.5) * lineHeight
        return CGPoint(x: x, y: size.height - y)
    }

    /// The way from a place in one step to a place in the next. The bow is a
    /// third of the distance across, kept between half a line and a line and
    /// a half.
    func arc(from: AnagramPlan.Slot, to: AnagramPlan.Slot, in shown: AnagramRenderer.Shown) -> Arc {
        let a = centre(of: from, track: shown.track, step: shown.from), b = centre(of: to, track: shown.track, step: shown.to)
        let dx = b.x - a.x
        let bow = dx == 0 ? 0 : min(max(abs(dx) / 3, lineHeight / 2), lineHeight * 1.5) * (dx > 0 ? 1 : -1)
        // A quadratic's control point sits twice as far out as its peak.
        let control = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + 2 * bow)
        return Arc(start: a, control: control, end: b)
    }
}
