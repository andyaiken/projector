import ProspectCore
import QuartzCore

/// Blank cues: a flat colour across the picture, black unless the cue says
/// otherwise. Instant, so it skips the hold.
///
/// Not the same thing as blackout. Blackout is an override the operator
/// toggles back when something has gone wrong; a blank cue is a planned
/// point in the sheet that GO advances into like any other.
@MainActor
public final class BlankRenderer: CueRenderer {
    public let isInstant = true
    private var colour = RGB.black
    private var fills: [ObjectIdentifier: StillLayer] = [:]

    public init() {}

    func fill(for surface: SurfaceLayer) -> StillLayer? {
        fills[ObjectIdentifier(surface)]
    }

    public func mount(on surface: SurfaceLayer) {
        let fill = StillLayer()
        fill.isHidden = true
        fill.backgroundColor = colour.cgColor
        fills[ObjectIdentifier(surface)] = fill
        surface.inset.addSublayer(fill)
        fit(surface)
    }

    public func unmount(from surface: SurfaceLayer) {
        fills.removeValue(forKey: ObjectIdentifier(surface))?.removeFromSuperlayer()
    }

    public func setVisible(_ visible: Bool, on surface: SurfaceLayer) {
        fill(for: surface)?.isHidden = !visible
    }

    public func clear(_ surface: SurfaceLayer) {
        colour = .black
        fill(for: surface)?.backgroundColor = colour.cgColor
    }

    public func prepare(_ cue: Cue, defaults: ShowSettings) {
        guard case .blank(let content) = cue.content else { return }
        colour = content.colour
        for fill in fills.values { fill.backgroundColor = colour.cgColor }
    }

    public func frame(_ f: Int) -> Bool {
        true
    }

    public func fit(_ surface: SurfaceLayer) {
        fill(for: surface)?.frame = surface.inset.bounds
    }
}
