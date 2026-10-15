import CoreGraphics
import ProspectCore

/// A connected display, as far as projector placement cares.
public struct DisplayInfo: Equatable, Sendable {
    public var identity: DisplayIdentity
    /// In global screen coordinates.
    public var frame: CGRect
    /// The display with the menu bar, where notification banners appear.
    public var isMain: Bool

    public init(identity: DisplayIdentity, frame: CGRect, isMain: Bool) {
        self.identity = identity
        self.frame = frame
        self.isMain = isMain
    }
}

/// What to do when a show names a projector display that isn't connected.
/// A preference of the Mac, not of the show.
public enum MissingDisplay: String, CaseIterable, Sendable {
    /// Open in a window on the console's display. The default.
    case window
    /// Go full-screen on another connected display until the show's returns.
    case anotherDisplay
}

/// Where the projector window is, and why. Worked out here from the
/// connected displays, so every rule can be tested without a projector; the
/// app only applies the result.
public enum ProjectorState: Equatable, Sendable {
    case closed
    /// Covering the whole of a display.
    case fullScreen(DisplayInfo)
    /// Covering another display while the show's own is missing, by
    /// preference. Moves to the show's display when that is connected.
    case standIn(DisplayInfo, for: DisplayIdentity)
    /// In an ordinary window on the console's display.
    case windowed(WindowedReason)
    /// Was full-screen, and its display has gone: a knocked cable. The window
    /// is hidden rather than moved, so nothing lands on the console, and it
    /// comes back full-screen when the display does.
    case waiting(for: DisplayIdentity)

    public enum WindowedReason: Equatable, Sendable {
        /// Only the console's display is connected.
        case noSecondDisplay
        /// The show names a display that isn't connected.
        case displayMissing(DisplayIdentity)
    }

    /// True whenever the projector is open, even while its display is away.
    public var isOpen: Bool { self != .closed }

    /// The display the window covers, when it covers one.
    public var display: DisplayInfo? {
        switch self {
        case .fullScreen(let d), .standIn(let d, _): d
        case .closed, .windowed, .waiting: nil
        }
    }

    /// Where the projector opens: on the display the show names if it is
    /// connected, failing that on the first display that isn't the console's,
    /// and failing that in a window. A show naming a display that isn't
    /// connected opens in a window, not on some other display, unless the
    /// Mac's preference says to stand in on another.
    public static func opening(saved: DisplayIdentity?, displays: [DisplayInfo], console: DisplayIdentity?,
                               whenMissing: MissingDisplay = .window) -> ProjectorState {
        let candidates = projectorCandidates(displays, console: console)
        if let saved {
            if let i = saved.bestMatch(in: candidates.map(\.identity)) { return .fullScreen(candidates[i]) }
            if whenMissing == .anotherDisplay, let other = candidates.first { return .standIn(other, for: saved) }
            return .windowed(.displayMissing(saved))
        }
        if let first = candidates.first { return .fullScreen(first) }
        return .windowed(.noSecondDisplay)
    }

    /// What becomes of the projector when displays come or go. A display
    /// that disappears leaves it waiting; one that returns, or a missing one
    /// that arrives, takes it full-screen again.
    public func afterDisplaysChanged(_ displays: [DisplayInfo], console: DisplayIdentity?) -> ProjectorState {
        let candidates = Self.projectorCandidates(displays, console: console)
        func find(_ id: DisplayIdentity) -> DisplayInfo? {
            id.bestMatch(in: candidates.map(\.identity)).map { candidates[$0] }
        }
        switch self {
        case .closed, .windowed(.noSecondDisplay):
            return self
        case .fullScreen(let display):
            return find(display.identity).map(ProjectorState.fullScreen) ?? .waiting(for: display.identity)
        case .waiting(let id), .windowed(.displayMissing(let id)):
            return find(id).map(ProjectorState.fullScreen) ?? self
        case .standIn(let display, let missing):
            if let back = find(missing) { return .fullScreen(back) }
            if let still = find(display.identity) { return .standIn(still, for: missing) }
            return .waiting(for: missing)
        }
    }

    /// Displays the projector may go full-screen on: any but the console's,
    /// since covering the console would leave the operator blind.
    static func projectorCandidates(_ displays: [DisplayInfo], console: DisplayIdentity?) -> [DisplayInfo] {
        guard let console, let i = console.bestMatch(in: displays.map(\.identity)) else { return displays }
        return displays.enumerated().filter { $0.offset != i }.map(\.element)
    }

    // MARK: What the console says

    /// The header lamp.
    public var lamp: String {
        switch self {
        case .closed: "Projector closed"
        case .fullScreen(let d): "Projector live on \(d.identity.name)"
        case .standIn(let d, _): "Projector live on \(d.identity.name), standing in"
        case .windowed: "Projector in a window"
        case .waiting: "Projector display disconnected"
        }
    }

    /// A warning the console keeps showing for as long as it applies.
    public var warning: String? {
        switch self {
        case .closed:
            return nil
        case .fullScreen(let d):
            return d.isMain
                ? "The projector\u{2019}s display, \(d.identity.name), is the main display, so notification banners would appear on it. Make the console\u{2019}s display the main one in System Settings \u{203A} Displays."
                : nil
        case .standIn(let d, let missing):
            return "The show\u{2019}s projector display, \(missing.name), isn\u{2019}t connected, so the projector is on \(d.identity.name) instead. It moves to \(missing.name) as soon as that is connected."
        case .windowed(.noSecondDisplay):
            return "Only one display is connected, so the projector is in a window on this screen."
        case .windowed(.displayMissing(let id)):
            return "The show\u{2019}s projector display, \(id.name), isn\u{2019}t connected, so the projector is in a window on this screen. It moves to \(id.name) as soon as that is connected."
        case .waiting(let id):
            return "The projector display, \(id.name), has disconnected. Carry on: cues still fire, and the picture comes back on \(id.name) as soon as it reconnects."
        }
    }
}
