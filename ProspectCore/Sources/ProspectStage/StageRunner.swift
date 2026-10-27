import Foundation
import ProspectCore
import QuartzCore

/// Runs cues on the surfaces: loads a cue into its renderer, drives the
/// renderer from the cue clock, and says when the cue settles.
///
/// It owns no timer. Whoever hosts it calls `tick(at:)` from a display link,
/// with that link's timestamps, so frames are painted on the display's own
/// refresh and the runner can be tested without one.
@MainActor
public final class StageRunner {
    public private(set) var surfaces: [SurfaceLayer] = []
    private let renderers: [Cue.Kind: any CueRenderer]

    /// The cue on stage, if any.
    public private(set) var cue: Cue?
    private var clock: TickClock?
    private var lastFrame: Int?
    private var settlePending = false

    /// True while the live cue is still resolving.
    public private(set) var isRunning = false

    /// False once there is nothing left to paint or report, so the host can
    /// pause its display link until the next cue.
    public var needsTicks: Bool { isRunning || settlePending || change != nil }

    /// A change of cue under way: the curtain coming down over the old cue,
    /// or going up on the new one.
    private struct Change {
        enum Phase { case out, into }
        var phase: Phase
        /// When this phase began, and where the curtain was then.
        var start: Double
        var from: Double
        /// A whole fade's length. A fade that begins partway takes less.
        var seconds: Double
        /// The cue waiting for the curtain to come down.
        var next: (cue: Cue, defaults: ShowSettings)?
    }

    private var change: Change?

    /// The curtain on every surface: 0 is the picture, 1 is black.
    private var curtain = 0.0 {
        didSet { for s in surfaces { s.curtain = curtain } }
    }

    /// Whether a change of cue is still fading.
    public var isChanging: Bool { change != nil }

    /// When the cue on stage started its clock.
    var startedAt: Double? { clock?.start }

    public var blackout = false {
        didSet { for s in surfaces { s.setBlackout(blackout, animated: true) } }
    }

    /// Where the picture lands, on every surface alike.
    public var geometry = Geometry() {
        didSet {
            guard geometry != oldValue else { return }
            for s in surfaces {
                s.geometry = geometry
                relayout(s)
            }
        }
    }

    public var showsGuides = false {
        didSet { for s in surfaces { s.showsGuides = showsGuides } }
    }

    public init(renderers: [Cue.Kind: any CueRenderer]) {
        self.renderers = renderers
    }

    /// The kinds this runner can paint. Others show black.
    public var kinds: Set<Cue.Kind> { Set(renderers.keys) }

    // MARK: Surfaces

    public func attach(_ surface: SurfaceLayer) {
        guard !surfaces.contains(where: { $0 === surface }) else { return }
        surfaces.append(surface)
        surface.geometry = geometry
        surface.showsGuides = showsGuides
        surface.updateInset()
        surface.setBlackout(blackout, animated: false)
        surface.curtain = curtain
        for (kind, renderer) in renderers {
            renderer.mount(on: surface)
            renderer.setVisible(kind == cue?.kind, on: surface)
        }
    }

    public func detach(_ surface: SurfaceLayer) {
        surfaces.removeAll { $0 === surface }
        for renderer in renderers.values { renderer.unmount(from: surface) }
    }

    /// Call when a surface's size or geometry changes.
    public func relayout(_ surface: SurfaceLayer) {
        surface.updateInset()
        if let kind = cue?.kind { renderers[kind]?.fit(surface) }
    }

    // MARK: Cues

    /// Changes to a cue by its transition: at once for a snap; for a fade,
    /// down to black and up on the cue, whose clock starts as it appears.
    public func change(to cue: Cue, defaults: ShowSettings, transition: Transition, at time: Double) {
        switch transition.style {
        case .snap:
            load(cue, defaults: defaults, presentation: .run, at: time)
        case .fade:
            if self.cue == nil {
                // Nothing to fade out, so straight up from black.
                curtain = 1
                bringUp(cue, defaults: defaults, at: time, seconds: transition.fadeSeconds)
            } else {
                // Down from wherever the curtain is, so nothing flashes up:
                // a fade out carries on, and a fade in turns round.
                change = Change(phase: .out, start: time, from: curtain, seconds: transition.fadeSeconds,
                                next: (cue, defaults))
            }
        }
        // A crossfade would be a third style: a second deck of renderers would
        // take the new cue while this one fades, and the two would swap.
    }

    /// Puts a cue on stage at once, with no transition. `.run` starts it from
    /// its hold; `.settled` puts it up finished, with nothing animating, as
    /// when resuming after a crash.
    public func load(_ cue: Cue, defaults: ShowSettings, presentation: Playhead.Fire.Presentation, at time: Double) {
        change = nil
        curtain = 0
        put(cue, defaults: defaults, presentation: presentation, at: time)
    }

    private func bringUp(_ cue: Cue, defaults: ShowSettings, at time: Double, seconds: Double) {
        put(cue, defaults: defaults, presentation: .run, at: time)
        change = Change(phase: .into, start: time, from: curtain, seconds: seconds)
    }

    private func put(_ cue: Cue, defaults: ShowSettings, presentation: Playhead.Fire.Presentation, at time: Double) {
        // Every renderer is wiped on every surface, not just the incoming one.
        for (kind, renderer) in renderers {
            for surface in surfaces {
                renderer.clear(surface)
                renderer.setVisible(kind == cue.kind, on: surface)
            }
        }
        self.cue = cue
        lastFrame = nil

        guard let renderer = renderers[cue.kind] else {
            // Nothing can paint this kind yet, so the stage shows black and
            // the cue counts as settled at once.
            clock = nil
            isRunning = false
            settlePending = true
            return
        }

        renderer.prepare(cue, defaults: defaults)
        for surface in surfaces { renderer.fit(surface) }

        let timing = cue.timing(defaults: defaults)
        clock = TickClock(start: time, tickMs: timing.clockMs, holdTicks: timing.holdTicks,
                          isInstant: renderer.isInstant || timing.isInstant)

        switch presentation {
        case .settled:
            (renderer as? WaitsForGO)?.carryOnToEnd()
            _ = renderer.frame(Self.settledFrame)
            lastFrame = Self.settledFrame
            isRunning = false
            settlePending = true
        case .run, .carryOn:
            isRunning = true
            settlePending = false
            paint(at: time)
        }
    }

    /// GO while the cue on stage waits partway: it carries on from now, or
    /// once whatever it is still doing has finished.
    public func carryOn(at time: Double) {
        guard let cue, let clock, let renderer = renderers[cue.kind] as? WaitsForGO else { return }
        renderer.carryOn(at: clock.frame(at: time))
        isRunning = true
        lastFrame = nil
        paint(at: time)
    }

    /// The show's defaults changed. Most take effect when a cue next runs;
    /// renderers apply what can change on stage, such as text size.
    public func settingsChanged(_ defaults: ShowSettings) {
        for renderer in renderers.values { renderer.settingsChanged(defaults) }
    }

    /// How ready a cue is, if its renderer prepares cues ahead of GO.
    public func armState(for cue: Cue) -> ArmState? {
        (renderers[cue.kind] as? ArmsCues)?.armState(for: cue.id)
    }

    /// Gets a cue that may fire next ready, so firing it doesn't wait.
    public func preload(_ cue: Cue, defaults: ShowSettings) {
        renderers[cue.kind]?.preload(cue, defaults: defaults)
    }

    /// Shows an edited cue finished, at once, without counting as the cue
    /// settling: a redraw in edit mode, or a resume, must never set off a continue.
    public func redraw(_ cue: Cue, defaults: ShowSettings, at time: Double) {
        load(cue, defaults: defaults, presentation: .settled, at: time)
        settlePending = false
    }

    /// Takes everything off stage, as when another show is opened.
    public func unload() {
        change = nil
        curtain = 0
        for renderer in renderers.values {
            for surface in surfaces {
                renderer.clear(surface)
                renderer.setVisible(false, on: surface)
            }
        }
        cue = nil
        clock = nil
        lastFrame = nil
        isRunning = false
        settlePending = false
    }

    /// Advances the live cue to `time`. Returns the cue's id on the tick it
    /// settles, once; nil otherwise.
    public func tick(at time: Double) -> UUID? {
        advanceChange(to: time)
        if isRunning { paint(at: time) }
        // A cue on its way off doesn't settle: nothing should continue from it now.
        if change?.phase == .out { settlePending = false }
        guard settlePending, let cue else { return nil }
        settlePending = false
        return cue.id
    }

    private func advanceChange(to time: Double) {
        guard let change else { return }
        switch change.phase {
        case .out:
            let length = change.seconds * (1 - change.from)
            let done = length > 0 ? min(1, max(0, (time - change.start) / length)) : 1
            curtain = change.from + (1 - change.from) * Self.ease(done)
            guard done >= 1, let next = change.next else { return }
            // In the dark: the next cue goes up from the moment it went black.
            bringUp(next.cue, defaults: next.defaults, at: change.start + length, seconds: change.seconds)
            advanceChange(to: time)
        case .into:
            let length = change.seconds * change.from
            let done = length > 0 ? min(1, max(0, (time - change.start) / length)) : 1
            curtain = change.from * (1 - Self.ease(done))
            if done >= 1 { self.change = nil }
        }
    }

    /// Slow at each end, so a fade neither jumps off nor lands hard.
    static func ease(_ t: Double) -> Double {
        t * t * (3 - 2 * t)
    }

    /// Far enough on that any cue has finished.
    static let settledFrame = 1_000_000

    private func paint(at time: Double) {
        guard let cue, let clock, let renderer = renderers[cue.kind] else { return }
        let f = clock.frame(at: time)
        guard f != lastFrame else { return }
        lastFrame = f
        let done = renderer.frame(f)
        if TickClock.hasSettled(rendererDone: done, frame: f) {
            isRunning = false
            settlePending = true
        } else if f >= 0, (renderer as? WaitsForGO)?.isWaiting(at: f) == true {
            // Nothing more until GO, so the clock can rest. The cue hasn't
            // finished, so nothing continues from it.
            isRunning = false
        }
    }
}
