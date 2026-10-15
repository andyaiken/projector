import ProspectCore
import QuartzCore

/// Anywhere cues are painted: the projector's output, or the console's live
/// preview. Renderers never know which, except that a surface carries its
/// role for the one renderer that needs it.
///
/// A surface is a black layer filling the output, holding an inset layer
/// sized by the show's percentage geometry. Renderers mount into the inset
/// and measure it, never the output. Everything outside the inset stays
/// black, because anything else is light spilling onto the set.
public final class SurfaceLayer: StillLayer {
    public enum Role: Sendable {
        case live
        case preview
    }

    public let role: Role
    /// Where the picture lands. Renderers add their layers here.
    public let inset = StillLayer()

    public var geometry = Geometry() {
        didSet { updateInset() }
    }

    /// A focusing aid: a frame round the inset and a cross through its
    /// centre, in brass. Only ever on in edit mode.
    public var showsGuides = false {
        didSet { guides.isHidden = !showsGuides }
    }

    private let guides = GuidesLayer()

    /// Black over the picture while one cue gives way to the next: clear at
    /// 0, black at 1. Separate from blackout, which fades the inset itself.
    public var curtain = 0.0 {
        didSet { curtainLayer.opacity = Float(curtain) }
    }

    private let curtainLayer = StillLayer()

    /// How long blackout takes to fade.
    public static let blackoutDuration: CFTimeInterval = 0.4

    public init(role: Role) {
        self.role = role
        super.init()
        backgroundColor = CGColor(gray: 0, alpha: 1)
        masksToBounds = true
        inset.masksToBounds = true
        addSublayer(inset)
        // Above anything a renderer adds, however its layers are stacked in
        // depth, with the guides above that.
        curtainLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        curtainLayer.opacity = 0
        curtainLayer.zPosition = 1000
        inset.addSublayer(curtainLayer)
        guides.isHidden = true
        guides.zPosition = 2000
        inset.addSublayer(guides)
    }

    override public init(layer: Any) {
        role = (layer as? SurfaceLayer)?.role ?? .preview
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Places the inset within the output by the geometry. Call after the
    /// surface's bounds change.
    public func updateInset() {
        inset.frame = geometry.insetRect(in: bounds.size).flipped(within: bounds.height)
        curtainLayer.frame = inset.bounds
        guides.frame = inset.bounds
        guides.layoutLines()
    }

    /// Fades the picture out or back in. The output stays black either way.
    public func setBlackout(_ on: Bool, animated: Bool) {
        let target: Float = on ? 0 : 1
        guard inset.opacity != target else { return }
        let from = inset.presentation()?.opacity ?? inset.opacity
        inset.opacity = target
        guard animated else {
            inset.removeAnimation(forKey: "blackout")
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = target
        fade.duration = Self.blackoutDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        inset.add(fade, forKey: "blackout")
    }
}

/// The alignment guides: a 1-point frame, and lines through the centre.
final class GuidesLayer: StillLayer {
    private let horizontal = StillLayer()
    private let vertical = StillLayer()

    override init() {
        super.init()
        borderColor = Palette.brass.cgColor(alpha: 0.55)
        borderWidth = 1
        for line in [horizontal, vertical] {
            line.backgroundColor = Palette.brass.cgColor(alpha: 0.3)
            addSublayer(line)
        }
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutLines() {
        let line: CGFloat = 1
        vertical.frame = CGRect(x: bounds.midX - line / 2, y: 0, width: line, height: bounds.height)
        horizontal.frame = CGRect(x: 0, y: bounds.midY - line / 2, width: bounds.width, height: line)
    }
}
