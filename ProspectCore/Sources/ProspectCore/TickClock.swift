/// Turns elapsed time into a cue's frame number.
///
/// A frame is one tick of the cue's clock setting, not one display refresh.
/// The display link asks for the frame on every refresh, and the number
/// advances by however many ticks have passed. So the projector's refresh
/// rate doesn't change how long a cue takes.
public struct TickClock: Equatable, Sendable {
    /// Seconds, on the display link's timebase, when the cue fired.
    public let start: Double
    public let tickMs: Int
    /// The frame painted when the cue fires: minus the hold, so resolving
    /// begins at frame 0, or 0 for an instant cue, which skips the hold.
    public let firstFrame: Int

    public init(start: Double, tickMs: Int, holdTicks: Int, isInstant: Bool) {
        self.start = start
        self.tickMs = max(1, tickMs)
        self.firstFrame = isInstant ? 0 : -holdTicks
    }

    public func frame(at time: Double) -> Int {
        // A microsecond of slack, so a timestamp landing exactly on a tick
        // isn't counted as the frame before it.
        let elapsedMs = max(0, time - start) * 1000 + 0.001
        return firstFrame + Int((elapsedMs / Double(tickMs)).rounded(.down))
    }

    /// A cue has settled once its renderer reports done on a frame at or
    /// after 0: nothing settles during the hold.
    public static func hasSettled(rendererDone: Bool, frame: Int) -> Bool {
        rendererDone && frame >= 0
    }
}
