import Foundation

/// What the operator is driving: the cue on stage, the cue GO will fire, and
/// any cue number being typed.
///
/// Only `go`, a continue, `rerun` and `resume` put anything on stage, and each
/// returns a `Fire` for the app to act on. Everything else only moves the
/// standby cue. Cues are tracked by `id`, so editing the sheet can't make the
/// playhead point at a different cue.
public struct Playhead: Equatable, Sendable {
    /// The cue on stage. Nil until the first GO.
    public private(set) var live: UUID?
    /// The cue GO will fire. Nil at the end of the sheet, or when it's empty.
    public private(set) var standby: UUID?
    /// Digits typed toward a cue number, shown in the standby panel.
    public private(set) var entry = ""
    /// The override the operator toggles when something has gone wrong. It
    /// stays on across cues until toggled back.
    public var blackout = false

    /// The longest number the keypad entry accepts.
    public static let entryLimit = 8

    /// A show opens with nothing on stage and its first cue standing by.
    public init(show: Show) {
        standby = show.cues.first?.id
    }

    public struct Fire: Equatable, Sendable {
        public enum Presentation: Equatable, Sendable {
            /// From the start: hold, then resolve.
            case run
            /// Straight to the finished state. Used to resume after a crash.
            case settled
        }

        public let cue: UUID
        public let presentation: Presentation
        /// Fired by the cue before it continuing, not by the operator.
        public let automatic: Bool
    }

    // MARK: Firing

    /// GO: fire the standby cue, and stand by the one after it. Any entry in
    /// progress is discarded. Nil at the end of the sheet.
    public mutating func go(in show: Show) -> Fire? {
        entry = ""
        guard let id = standby, show.index(of: id) != nil else { return nil }
        return fire(id, in: show, presentation: .run, automatic: false)
    }

    /// Call when the live cue settles. If it continues when finished with
    /// no wait, the next cue in the sheet fires now; a wait is timed by
    /// whoever keeps the clock, from this moment. A settle from a cue that is
    /// no longer live is ignored.
    public mutating func liveCueSettled(_ id: UUID, in show: Show) -> Fire? {
        guard let cue = show[id], cue.continueMode == .whenFinished(waitMs: 0) else { return nil }
        return continueAfter(id, in: show)
    }

    /// The show moves on by itself from `id`, as its Continue says: the next
    /// cue in the sheet fires. Nil if `id` is no longer live, or is last.
    public mutating func continueAfter(_ id: UUID, in show: Show) -> Fire? {
        guard id == live, let i = show.index(of: id), i + 1 < show.cues.count else { return nil }
        return fire(show.cues[i + 1].id, in: show, presentation: .run, automatic: true)
    }

    /// R: run the live cue again from the start. The standby cue is unchanged.
    public func rerun() -> Fire? {
        live.map { Fire(cue: $0, presentation: .run, automatic: false) }
    }

    /// After a crash: put `id` up in its finished state and stand by the next.
    public mutating func resume(at id: UUID, in show: Show) -> Fire? {
        guard show.index(of: id) != nil else { return nil }
        entry = ""
        return fire(id, in: show, presentation: .settled, automatic: false)
    }

    private mutating func fire(_ id: UUID, in show: Show, presentation: Fire.Presentation, automatic: Bool) -> Fire {
        live = id
        standby = show.index(of: id).flatMap { i in i + 1 < show.cues.count ? show.cues[i + 1].id : nil }
        return Fire(cue: id, presentation: presentation, automatic: automatic)
    }

    // MARK: Standing by

    /// → ↓ PageDown. From the last cue this reaches the end of the sheet.
    public mutating func standByNext(in show: Show) {
        entry = ""
        guard let id = standby, let i = show.index(of: id) else { return }
        standby = i + 1 < show.cues.count ? show.cues[i + 1].id : nil
    }

    /// ← ↑ PageUp. From the end of the sheet this reaches the last cue.
    public mutating func standByPrevious(in show: Show) {
        entry = ""
        guard let id = standby, let i = show.index(of: id) else {
            standby = show.cues.last?.id
            return
        }
        standby = show.cues[max(0, i - 1)].id
    }

    /// A click on the cue list.
    public mutating func standBy(_ id: UUID) {
        entry = ""
        standby = id
    }

    /// The Go-to field, which also reaches numbers with letters in them.
    /// False if no cue has that number.
    public mutating func standBy(number: String, in show: Show) -> Bool {
        guard let i = show.index(ofNumber: number) else { return false }
        standBy(show.cues[i].id)
        return true
    }

    // MARK: Keypad entry

    /// 0–9 and `.`. Anything else is ignored.
    public mutating func type(_ c: Character) {
        guard c.isASCII, c.isNumber || c == ".", entry.count < Self.entryLimit else { return }
        entry.append(c)
    }

    /// Backspace.
    public mutating func deleteBackward() {
        if !entry.isEmpty { entry.removeLast() }
    }

    /// Escape.
    public mutating func clearEntry() {
        entry = ""
    }

    public enum EntryResult: Equatable, Sendable {
        case empty
        case stoodBy(UUID)
        case noSuchCue(String)
    }

    /// Return: stand by the cue whose number was typed. The entry clears
    /// either way.
    public mutating func commitEntry(in show: Show) -> EntryResult {
        let typed = entry
        entry = ""
        guard !typed.isEmpty else { return .empty }
        guard let i = show.index(ofNumber: typed) else { return .noSuchCue(typed) }
        standby = show.cues[i].id
        return .stoodBy(show.cues[i].id)
    }

    // MARK: Video arming

    /// The cues that could fire next: the standby cue, and the cue after the
    /// live one if the live one continues. Video cues among them should be
    /// armed now, not when the live cue settles.
    public func cuesThatMayFireNext(in show: Show) -> [UUID] {
        var ids: [UUID] = []
        if let live, let i = show.index(of: live), i + 1 < show.cues.count, show.cues[i].continueMode.continues {
            ids.append(show.cues[i + 1].id)
        }
        if let standby, show.index(of: standby) != nil, !ids.contains(standby) {
            ids.append(standby)
        }
        return ids
    }

    // MARK: Edits

    /// After the sheet has been edited: if the standby cue was deleted, stand
    /// by whichever cue now occupies its place. If the live cue was deleted,
    /// nothing is live; the stage takes it off.
    public mutating func reconcile(from old: Show, to new: Show) {
        if let id = live, new.index(of: id) == nil { live = nil }
        guard let id = standby, new.index(of: id) == nil else { return }
        guard let oldIndex = old.index(of: id) else {
            standby = new.cues.first?.id
            return
        }
        // The first surviving cue at or after the deleted one's place.
        standby = old.cues[oldIndex...].lazy.compactMap { new[$0.id]?.id }.first
    }
}
