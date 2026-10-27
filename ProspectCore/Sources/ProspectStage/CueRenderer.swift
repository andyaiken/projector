import Foundation
import ProspectCore

/// One cue type's painter. Adding a cue type means writing one of these and
/// adding one case to `Cue.Content`; nothing generic changes.
///
/// A renderer paints every surface identically from one frame number.
/// Anything random within a frame is computed once and applied to all of
/// them; two surfaces rolling their own dice visibly disagree.
@MainActor
public protocol CueRenderer: AnyObject {
    /// Skips the hold. Blank cues are instant.
    var isInstant: Bool { get }

    /// Adds this renderer's layers to a surface. Called once per surface. A
    /// surface mounted mid-cue shows the current frame straight away.
    func mount(on surface: SurfaceLayer)

    func unmount(from surface: SurfaceLayer)

    /// Only the active cue's renderer is visible on a surface.
    func setVisible(_ visible: Bool, on surface: SurfaceLayer)

    /// Wipes stale state before a cue loads. Called on every renderer, not
    /// just the incoming one, so nothing held in a hidden layer can surface
    /// when it is shown again.
    func clear(_ surface: SurfaceLayer)

    /// Works out the shared plan for a cue, once.
    func prepare(_ cue: Cue, defaults: ShowSettings)

    /// Paints frame `f` on every surface. True when the cue has settled.
    func frame(_ f: Int) -> Bool

    /// The surface's size or geometry changed.
    func fit(_ surface: SurfaceLayer)

    /// Gets ready for a cue that may fire next, such as decoding its image,
    /// so firing it doesn't wait. Optional.
    func preload(_ cue: Cue, defaults: ShowSettings)

    /// The show's defaults changed while a cue may be on stage. Optional.
    func settingsChanged(_ defaults: ShowSettings)
}

extension CueRenderer {
    public func preload(_ cue: Cue, defaults: ShowSettings) {}
    public func settingsChanged(_ defaults: ShowSettings) {}
}

/// A renderer that can find something wrong while loading a cue, such as a
/// missing image. The console shows what it says; the stage carries on.
@MainActor
public protocol ReportsProblems: AnyObject {
    var onProblem: ((String) -> Void)? { get set }
}

/// A renderer whose cue can stop partway and wait for GO, as an anagram cue's
/// working can. The playhead counts the GOs; the renderer keeps the time.
@MainActor
public protocol WaitsForGO: AnyObject {
    /// Done everything it can by frame `f`, with more to come on GO. The
    /// clock can rest meanwhile.
    func isWaiting(at f: Int) -> Bool
    /// GO on frame `f`: the next part goes then, or as soon as the part
    /// before it has finished.
    func carryOn(at f: Int)
    /// Lets every part go, as when the cue is put up finished.
    func carryOnToEnd()
}

/// How ready a cue that may fire next is.
public enum ArmState: Equatable, Sendable {
    /// Still loading.
    case arming
    /// Loaded, first frame decoded, waiting at the start. GO starts it at once.
    case armed
    /// Can't be played. Says why, for the console.
    case failed(String)
}

/// A renderer that prepares cues ahead of GO and can say how far it has got.
@MainActor
public protocol ArmsCues: AnyObject {
    func armState(for cue: UUID) -> ArmState?
    var onArmStateChange: (() -> Void)? { get set }
}
