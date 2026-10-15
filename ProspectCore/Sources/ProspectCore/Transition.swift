/// How the stage changes from whatever is on it to a cue.
public enum TransitionStyle: String, Codable, CaseIterable, Sendable {
    /// The old picture goes and the new one appears at once.
    case snap
    /// The old picture fades out to black, then the new one fades in.
    case fade
    // A crossfade, the old and new pictures overlapping, would be a third
    // style; see Transitions in the spec.
}

/// The transition into a cue, once its overrides are applied.
public struct Transition: Equatable, Sendable {
    public var style: TransitionStyle
    /// The length of each fade: out, then in. Unused by a snap.
    public var fadeMs: Int

    public init(style: TransitionStyle, fadeMs: Int) {
        self.style = style
        self.fadeMs = fadeMs
    }

    /// What every cue changes with, unless the show or the cue says otherwise.
    public static let standard = Transition(style: .fade, fadeMs: 500)

    public var fadeSeconds: Double { Double(fadeMs) / 1000 }
}

/// A cue's own values for its transition in. Nil takes the show's default.
public struct TransitionOverrides: Codable, Equatable, Sendable {
    public var style: TransitionStyle?
    public var fadeMs: Int?

    public init(style: TransitionStyle? = nil, fadeMs: Int? = nil) {
        self.style = style
        self.fadeMs = fadeMs
    }

    public var isEmpty: Bool { self == TransitionOverrides() }

    func clamped() -> TransitionOverrides {
        var o = self
        o.fadeMs = fadeMs.map { SettingRange.fadeMs.clamp($0) }
        return o
    }
}

extension Cue {
    /// How the stage changes to this cue, however it got here.
    public func transitionIn(defaults: ShowSettings) -> Transition {
        Transition(style: transition.style ?? defaults.transition, fadeMs: transition.fadeMs ?? defaults.fadeMs)
    }
}
